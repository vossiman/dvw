#!/usr/bin/env bats
# cmd_pull: argv contract, running/catalog gates, transfer shape, subpath
# recreation, size cap, --all, collisions, --dry-run. ssh is stubbed on PATH
# and dispatches on the remote command (find = listing, cat = transfer);
# resolution and alias registration are stubbed at the function boundary.

bats_require_minimum_version 1.5.0

# fzf must be UNREACHABLE: every test here either names files or uses --all,
# and a real fzf would block on a tty that bats doesn't provide.
setup_file() {
  load "lib/sanitized-path.bash"
  sanitized_bin_init "$BATS_FILE_TMPDIR/sanitized-bin" fzf
}

setup() {
  TMPDIR=$(mktemp -d)
  export TMPDIR
  export HOME="$TMPDIR"
  STUB_BIN="$TMPDIR/stubbin"
  mkdir -p "$STUB_BIN"
  export PATH="$STUB_BIN:$SANITIZED_BIN"
  # One line per transfer: the remote path the stub was asked to cat.
  XFER_LOG="$TMPDIR/xfer-log"; : > "$XFER_LOG"
  export XFER_LOG
  DEST="$TMPDIR/dest"; mkdir -p "$DEST"
}

teardown() { rm -rf "$TMPDIR"; }

# Install the ssh stub.
#   $1 — printf FORMAT for the listing. Records are separated with \x00: a NUL
#        payload cannot travel through $( ) (which strips NUL bytes), so the
#        format string is embedded in the stub and expanded there.
#   $2 — exit code for the LISTING call only (transfers use $XFER_RC).
# The stub dispatches on the remote command, the same way the real container
# would: `find …` is a listing, `cat -- …` is a transfer.
_stub_ssh() {
  local rc="${2:-0}"
  cat > "$STUB_BIN/ssh" <<EOF
#!/usr/bin/env bash
cmd="\${@: -1}"
if [[ "\$cmd" == *find* ]]; then
  printf '${1:-}'
  exit $rc
fi
# transfer: record the quoted remote path, emit deterministic content
printf '%s\n' "\${cmd#cat -- }" >> "$XFER_LOG"
[[ "\${XFER_RC:-0}" == 0 ]] || exit "\$XFER_RC"
printf 'PULLED'
EOF
  chmod +x "$STUB_BIN/ssh"
}

_load() {
  ERRS="$TMPDIR/errs"; : > "$ERRS"
  ui_error() { printf '%s\n' "$1" >> "$ERRS"; }
  ui_info() { printf '%s\n' "$1" >> "$ERRS"; }
  ui_status_ok() { printf 'OK: %s\n' "$1"; }
  ui_status_warn() { printf '%s\n' "$1" >> "$ERRS"; }
  ui_action() { :; }
  _dvw_log_action() { :; }
  source "$DVW_ROOT/lib/connect.sh"
  source "$DVW_ROOT/lib/push.sh"
  source "$DVW_ROOT/lib/pull.sh"
  _dvw_push_resolve_target() { printf 'stubws\n'; }
  _dvw_ws_container_state() { echo yes; }
  _dvw_ensure_ssh_alias() { return 0; }
  _dvw_ensure_local_devpod_state() { return 0; }
}

LISTING='12\treport.pdf\x00345\tsub/deep.txt\x00'

# Run cmd_pull in a fresh shell with the boundary stubs re-applied, feeding $1
# to stdin. Needed for the collision tests: bats' `run` gives the function a
# stdin it cannot prompt on.
_pull_with_input() {
  local input="$1"; shift
  local args=""
  local a; for a in "$@"; do args+=" $(printf '%q' "$a")"; done
  env DVW_ASSUME_TTY=1 XFER_RC="${XFER_RC:-0}" bash -c "
    source '$DVW_ROOT/lib/connect.sh'; source '$DVW_ROOT/lib/push.sh'; source '$DVW_ROOT/lib/pull.sh'
    _dvw_push_resolve_target() { printf 'stubws\n'; }
    _dvw_ws_container_state() { echo yes; }
    _dvw_ensure_ssh_alias() { return 0; }
    _dvw_ensure_local_devpod_state() { return 0; }
    cd '$DEST';  printf '%b' '$input' | cmd_pull$args"
}

@test "explicit file: transfers from /workspaces/<ws>/out/<path>" {
  _load
  _stub_ssh "$LISTING"
  cd "$DEST"
  run cmd_pull report.pdf
  [ "$status" -eq 0 ]
  run grep -qx '/workspaces/stubws/out/report.pdf' "$XFER_LOG"
  [ "$status" -eq 0 ]
  [ "$(cat "$DEST/report.pdf")" = "PULLED" ]
}

@test "subpaths are recreated locally, not flattened" {
  _load
  _stub_ssh "$LISTING"
  cd "$DEST"
  run cmd_pull sub/deep.txt
  [ "$status" -eq 0 ]
  [ -f "$DEST/sub/deep.txt" ]
  [ ! -f "$DEST/deep.txt" ]
}

@test "--all pulls every listed file without a picker" {
  _load
  _stub_ssh "$LISTING"
  cd "$DEST"
  run cmd_pull --all
  [ "$status" -eq 0 ]
  [ -f "$DEST/report.pdf" ]
  [ -f "$DEST/sub/deep.txt" ]
}

@test "explicit file not present in out/ is an error naming it" {
  _load
  _stub_ssh "$LISTING"
  cd "$DEST"
  run cmd_pull nope.bin
  [ "$status" -ne 0 ]
  [ ! -s "$XFER_LOG" ]
  run grep -q 'nope.bin' "$ERRS"
  [ "$status" -eq 0 ]
}

@test "missing out dir is an explanatory error, not a crash" {
  _load
  _stub_ssh "" 3
  cd "$DEST"
  run cmd_pull --all
  [ "$status" -ne 0 ]
  [ ! -s "$XFER_LOG" ]
  run grep -q 'outbox' "$ERRS"
  [ "$status" -eq 0 ]
}

@test "empty out dir says so instead of opening an empty picker" {
  _load
  _stub_ssh ""
  cd "$DEST"
  run cmd_pull
  [ "$status" -ne 0 ]
  run grep -qi 'nothing' "$ERRS"
  [ "$status" -eq 0 ]
}

@test "ssh failure while listing is reported, not read as empty" {
  _load
  _stub_ssh "" 255
  cd "$DEST"
  run cmd_pull --all
  [ "$status" -ne 0 ]
  [ ! -s "$XFER_LOG" ]
  run grep -qi 'unreachable' "$ERRS"
  [ "$status" -eq 0 ]
}

@test "stopped workspace is refused before anything touches the alias" {
  _load
  _dvw_ws_container_state() { echo no; }
  _stub_ssh "$LISTING"
  cd "$DEST"
  run cmd_pull --all
  [ "$status" -eq 1 ]
  [ ! -s "$XFER_LOG" ]
  run grep -q 'not running' "$ERRS"
  [ "$status" -eq 0 ]
}

@test "unreachable catalog is refused, not guessed" {
  _load
  _dvw_ws_container_state() { echo unknown; }
  _stub_ssh "$LISTING"
  cd "$DEST"
  run cmd_pull --all
  [ "$status" -eq 1 ]
  [ ! -s "$XFER_LOG" ]
  run grep -qi 'catalog' "$ERRS"
  [ "$status" -eq 0 ]
}

@test "local devpod state guard failure aborts before any transfer" {
  _load
  _dvw_ensure_local_devpod_state() { return 1; }
  _stub_ssh "$LISTING"
  cd "$DEST"
  run cmd_pull --all
  [ "$status" -ne 0 ]
  [ ! -s "$XFER_LOG" ]
}

@test "--from is passed through to resolve_target" {
  _load
  _dvw_push_resolve_target() { printf 'TO:%s\n' "${1:-none}" > "$TMPDIR/resolve-arg"; printf 'stubws\n'; }
  _stub_ssh "$LISTING"
  cd "$DEST"
  run cmd_pull --all --from otherws
  [ "$(cat "$TMPDIR/resolve-arg")" = "TO:otherws" ]
}

@test "unknown flag errors with usage" {
  _load
  cd "$DEST"
  run cmd_pull --bogus
  [ "$status" -eq 1 ]
  run grep -q 'usage' "$ERRS"
  [ "$status" -eq 0 ]
}

@test "--all and explicit files are mutually exclusive" {
  _load
  cd "$DEST"
  run cmd_pull --all report.pdf
  [ "$status" -eq 1 ]
  run grep -q 'mutually exclusive' "$ERRS"
  [ "$status" -eq 0 ]
}

@test "-- terminates options: a --prefixed name is pullable" {
  _load
  _stub_ssh '5\t--weird.txt\x00'
  cd "$DEST"
  run cmd_pull -- --weird.txt
  [ "$status" -eq 0 ]
  [ -f "$DEST/--weird.txt" ]
}

@test "a name with a space survives the remote shell verbatim" {
  _load
  _stub_ssh '5\tQ3 report.pdf\x00'
  cd "$DEST"
  run cmd_pull "Q3 report.pdf"
  [ "$status" -eq 0 ]
  [ -f "$DEST/Q3 report.pdf" ]
  # the stub logs the path exactly as the remote shell would see it after
  # re-parsing the quoted command
  run grep -qx "/workspaces/stubws/out/Q3\\\\ report.pdf" "$XFER_LOG"
  [ "$status" -eq 0 ]
}

@test "a colon in the name lands correctly and is printed ./-prefixed" {
  _load
  _stub_ssh '5\tfoo:bar.txt\x00'
  cd "$DEST"
  run cmd_pull "foo:bar.txt"
  [ "$status" -eq 0 ]
  [ -f "$DEST/foo:bar.txt" ]
  [ "${lines[-1]}" = "./foo:bar.txt" ]
}

@test "oversized file is refused naming the cap, and never transferred" {
  _load
  _stub_ssh '2097152\tbig.bin\x00'
  cd "$DEST"
  DVW_PULL_MAX_SIZE_MB=1 run cmd_pull big.bin
  [ "$status" -ne 0 ]
  [ ! -s "$XFER_LOG" ]
  run grep -q '1 MB' "$ERRS"
  [ "$status" -eq 0 ]
}

@test "traversal in an explicit argument is rejected before listing" {
  _load
  _stub_ssh "$LISTING"
  cd "$DEST"
  run cmd_pull ../escape.txt
  [ "$status" -ne 0 ]
  [ ! -s "$XFER_LOG" ]
}

@test "existing local file: overwrite replaces it" {
  _load
  _stub_ssh '12\treport.pdf\x00'
  printf 'old' > "$DEST/report.pdf"
  run _pull_with_input 'o\n' report.pdf
  [ "$status" -eq 0 ]
  [ "$(cat "$DEST/report.pdf")" = "PULLED" ]
}

@test "existing local file: skip leaves it untouched and transfers nothing" {
  _load
  _stub_ssh '12\treport.pdf\x00'
  printf 'old' > "$DEST/report.pdf"
  run _pull_with_input 's\n' report.pdf
  [ "$(cat "$DEST/report.pdf")" = "old" ]
  [ ! -s "$XFER_LOG" ]
}

@test "existing local file: rename lands beside it, original intact" {
  _load
  _stub_ssh '12\treport.pdf\x00'
  printf 'old' > "$DEST/report.pdf"
  run _pull_with_input 'r\n\n' report.pdf
  [ "$status" -eq 0 ]
  [ "$(cat "$DEST/report.pdf")" = "old" ]
  [ "$(cat "$DEST/report-1.pdf")" = "PULLED" ]
}

@test "cancel at a collision stops the remaining files" {
  _load
  _stub_ssh '12\ta.txt\x0012\tb.txt\x00'
  printf 'old' > "$DEST/a.txt"
  run _pull_with_input 'c\n' --all
  [ "$(cat "$DEST/a.txt")" = "old" ]
  [ ! -f "$DEST/b.txt" ]
}

@test "a failed transfer leaves neither a partial file nor a clobbered one" {
  _load
  _stub_ssh '12\treport.pdf\x00'
  printf 'old' > "$DEST/report.pdf"
  XFER_RC=1 run _pull_with_input 'o\n' report.pdf
  [ "$status" -ne 0 ]
  [ "$(cat "$DEST/report.pdf")" = "old" ]
  run bash -c "ls '$DEST'/*.dvw-part 2>/dev/null"
  [ -z "$output" ]
}

@test "--dry-run prints the would-be transfer and moves nothing" {
  _load
  ui_info() { printf '%s\n' "$1"; }
  _stub_ssh "$LISTING"
  cd "$DEST"
  DVW_DRY_RUN=1 run cmd_pull --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"would run: ssh"* ]]
  [ ! -s "$XFER_LOG" ]
  [ ! -f "$DEST/report.pdf" ]
}

@test "first transfer failure aborts the remaining files" {
  _load
  _stub_ssh "$LISTING"
  cd "$DEST"
  XFER_RC=1 run cmd_pull --all
  [ "$status" -ne 0 ]
  run wc -l < "$XFER_LOG"
  [ "$output" = "1" ]
}

@test "landed local paths are printed, one per line" {
  _load
  _stub_ssh '12\treport.pdf\x00'
  cd "$DEST"
  run cmd_pull report.pdf
  [ "${lines[-1]}" = "./report.pdf" ]
}

@test "listing order is sorted, not find's directory order" {
  _load
  _stub_ssh '1\tzebra.txt\x001\talpha.txt\x001\tmid.txt\x00'
  run _pull_with_input '1\n'
  [ "$status" -eq 0 ]
  [ -f "$DEST/alpha.txt" ]
  [ ! -f "$DEST/zebra.txt" ]
}

@test "the listing temp file is removed on both success and failure" {
  _load
  _stub_ssh "$LISTING"
  cd "$DEST"
  run cmd_pull --all
  [ "$status" -eq 0 ]
  run bash -c "ls '$TMPDIR'/dvw-pull-* 2>/dev/null"
  [ -z "$output" ]
  XFER_RC=1 run cmd_pull --all
  run bash -c "ls '$TMPDIR'/dvw-pull-* 2>/dev/null"
  [ -z "$output" ]
}
