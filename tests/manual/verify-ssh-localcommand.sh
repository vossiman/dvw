#!/usr/bin/env bash
# Verify the assumption _dvw_ssh_session is built on: that OpenSSH's
# LocalCommand hook is a trustworthy "this attempt authenticated" signal.
#
# NOT part of tests/bats/run.sh — it needs sudo to run a throwaway sshd, so it
# cannot go in the normal suite. Run it by hand when touching the reconnect
# loop, or when moving to a new OpenSSH major version.
#
#   bash tests/manual/verify-ssh-localcommand.sh
#
# It stands up an sshd on 127.0.0.1:22222 in a temp dir, exercises every case
# the loop distinguishes, and tears everything down. Expected: passed=11 failed=0.
#
# The two results the loop depends on:
#   - established then TRANSPORT cut -> marker present WITH exit 255 (reconnect)
#   - auth / host key / unreachable  -> marker absent (do not reconnect)
# And the limitation that makes _dvw_ssh_master_alive necessary:
#   - a connection riding an existing master does NOT fire the hook
set -u

USER_AT="$(id -un)@127.0.0.1"

T=$(mktemp -d)
PORT=22222
RELAY=22333
DEADPORT=22223
rm -rf "$T"; mkdir -p "$T"
trap 'sudo pkill -f "sshd -f $T" 2>/dev/null; rm -rf "$T"' EXIT

ssh-keygen -q -t ed25519 -f "$T/hostkey" -N ''
ssh-keygen -q -t ed25519 -f "$T/clientkey" -N ''
cp "$T/clientkey.pub" "$T/authorized_keys"
chmod 600 "$T/authorized_keys" "$T/hostkey"

cat > "$T/sshd_config" <<EOF
Port $PORT
ListenAddress 127.0.0.1
HostKey $T/hostkey
AuthorizedKeysFile $T/authorized_keys
StrictModes no
UsePAM yes
KbdInteractiveAuthentication no
PasswordAuthentication no
PidFile $T/sshd.pid
LogLevel ERROR
EOF

sudo /usr/sbin/sshd -f "$T/sshd_config" || { echo "could not start sshd"; exit 1; }
sleep 1
ss -ltn | grep -q ":$PORT " || { echo "sshd not listening"; exit 1; }

MARK="$T/marker"
BASE=(-i "$T/clientkey" -o StrictHostKeyChecking=no -o UserKnownHostsFile="$T/known"
      -o BatchMode=yes -o PermitLocalCommand=yes -o LocalCommand="/usr/bin/touch $MARK")

pass=0 fail=0
check() { # name expected_marker actual_marker rc
  local name="$1" want="$2" got="$3" rc="$4"
  if [[ "$want" == "$got" ]]; then
    printf 'PASS  %-46s marker=%-3s rc=%s\n' "$name" "$got" "$rc"; pass=$((pass+1))
  else
    printf 'FAIL  %-46s marker=%-3s (wanted %s) rc=%s\n' "$name" "$got" "$want" "$rc"; fail=$((fail+1))
  fi
}
marker() { [[ -e "$MARK" ]] && echo yes || echo no; }

# 1. established session, clean exit
rm -f "$MARK"
ssh "${BASE[@]}" -p "$PORT" -t "$USER_AT" true >/dev/null 2>&1; rc=$?
check "established, clean exit" yes "$(marker)" "$rc"

# 2. established session, remote command fails
rm -f "$MARK"
ssh "${BASE[@]}" -p "$PORT" -t "$USER_AT" 'exit 7' >/dev/null 2>&1; rc=$?
check "established, remote exit 7" yes "$(marker)" "$rc"

# 3. established session killed mid-run == a dropped transport (the case that
#    matters most: the marker must survive an abrupt 255).
rm -f "$MARK"
( ssh "${BASE[@]}" -p "$PORT" -t "$USER_AT" 'sleep 30' >/dev/null 2>&1; echo $? > "$T/rc3" ) &
sshpid=$!
sleep 2
sudo pkill -f "sshd -f $T" 2>/dev/null   # yank the server out from under it
wait "$sshpid" 2>/dev/null
rc=$(cat "$T/rc3" 2>/dev/null || echo "?")
check "established, server closed gracefully" yes "$(marker)" "$rc"
echo "      ^ rc 0: a graceful close is not a drop; the loop returns, as it should"

sudo /usr/sbin/sshd -f "$T/sshd_config"; sleep 1   # bring it back for 4-6

# 3b. A REAL transport loss: reach sshd through a killable TCP relay and kill
#     the relay mid-session. Killing sshd itself is a graceful channel close
#     (case 3, rc 0); cutting the transport is what produces the 255 the
#     reconnect loop keys on. The marker must survive it.
rm -f "$MARK"
python3 "$(dirname "$0")/tcprelay.py" "$RELAY" "$PORT" & relay=$!
sleep 1
( ssh "${BASE[@]}" -p "$RELAY" -o ServerAliveInterval=1 -o ServerAliveCountMax=2 \
      -t "$USER_AT" 'sleep 30' >/dev/null 2>&1; echo $? > "$T/rc3b" ) &
sshpid=$!
sleep 3
kill -9 "$relay" 2>/dev/null                   # cut the wire
wait "$sshpid" 2>/dev/null
rc=$(cat "$T/rc3b" 2>/dev/null || echo "?")
check "established then TRANSPORT cut" yes "$(marker)" "$rc"
if [[ "$rc" == 255 ]]; then
  echo "      ^ marker=yes AND rc=255 -> exactly the reconnect case"
else
  echo "      ^ NOTE: wanted rc 255 for a transport cut, got $rc"
fi

# 4. auth failure: wrong key
rm -f "$MARK"
ssh -i "$T/hostkey" -o StrictHostKeyChecking=no -o UserKnownHostsFile="$T/known" \
    -o BatchMode=yes -o PermitLocalCommand=yes -o LocalCommand="/usr/bin/touch $MARK" \
    -p "$PORT" -t "$USER_AT" true >/dev/null 2>&1; rc=$?
check "auth failure (wrong key)" no "$(marker)" "$rc"

# 5. nothing listening
rm -f "$MARK"
ssh "${BASE[@]}" -o ConnectTimeout=2 -p "$DEADPORT" -t "$USER_AT" true >/dev/null 2>&1; rc=$?
check "host unreachable" no "$(marker)" "$rc"

# 6. host key verification failure
rm -f "$MARK"
printf '[127.0.0.1]:%s %s\n' "$PORT" "$(cut -d' ' -f1-2 "$T/clientkey.pub")" > "$T/badknown"
ssh -i "$T/clientkey" -o UserKnownHostsFile="$T/badknown" -o StrictHostKeyChecking=yes \
    -o BatchMode=yes -o PermitLocalCommand=yes -o LocalCommand="/usr/bin/touch $MARK" \
    -p "$PORT" -t "$USER_AT" true >/dev/null 2>&1; rc=$?
check "host key verification failure" no "$(marker)" "$rc"

# 7. Multiplexed connect. dvw's own blueprint sets ControlMaster auto +
#    ControlPersist, so a reconnect within the persist window rides an existing
#    master. If the hook only fired for the master, a real session would look
#    un-established and the loop would refuse to reconnect.
CP="/tmp/dvwcm-%r@%h:%p"   # short: unix sockets cap near 108 chars
MUX=(-o ControlMaster=auto -o ControlPath="$CP" -o ControlPersist=30)
rm -f "$MARK"
ssh "${BASE[@]}" "${MUX[@]}" -p "$PORT" -t "$USER_AT" true >/dev/null 2>&1; rc=$?
check "multiplexed: first connect (is the master)" yes "$(marker)" "$rc"
rm -f "$MARK"
ssh "${BASE[@]}" "${MUX[@]}" -p "$PORT" -t "$USER_AT" true >/dev/null 2>&1; rc=$?
# KNOWN: the hook does not fire when a connection rides an existing master.
# This is why a live master (-O check, below) is the second establishment signal.
check "multiplexed: second connect does NOT fire hook" no "$(marker)" "$rc"
# 8/9. `ssh -O check` as the mux-case establishment signal: a live master is
#      itself proof that authentication to this host works.
if ssh "${BASE[@]}" "${MUX[@]}" -O check -p "$PORT" "$USER_AT" >/dev/null 2>&1
then live=alive; else live=dead; fi
check "-O check with a live master (exit 0 = alive)" alive "$live" 0
ssh "${BASE[@]}" "${MUX[@]}" -O exit -p "$PORT" "$USER_AT" >/dev/null 2>&1
if ssh "${BASE[@]}" "${MUX[@]}" -O check -p "$PORT" "$USER_AT" >/dev/null 2>&1
then live=alive; else live=dead; fi
check "-O check after master exits (nonzero = dead)" dead "$live" 0

echo
echo "passed=$pass failed=$fail"
[[ $fail -eq 0 ]]
