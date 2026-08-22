#!/usr/bin/env bats
# dvw pull, unit level: remote listing parse, selection grammar, collision
# resolution, path safety, human sizes. ssh is stubbed on PATH; the numbered
# picker is driven through stdin with DVW_ASSUME_TTY=1.

bats_require_minimum_version 1.5.0

# fzf must be UNREACHABLE: the numbered-fallback tests below assert the
# no-fzf branch, and absence cannot be faked with a stub.
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
}

teardown() { rm -rf "$TMPDIR"; }

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
}

# Install an ssh stub. $1 is a printf FORMAT for the remote listing (records
# separated with \x00 — a NUL payload cannot travel through $( ), which strips
# NUL bytes, so the format string is embedded in the stub and expanded there).
# $2 is the ssh exit code. The last argument — the remote command — is
# recorded in $SSH_CMD for inspection.
_stub_ssh() {
  local rc="${2:-0}"
  SSH_CMD="$TMPDIR/ssh-cmd"; export SSH_CMD
  cat > "$STUB_BIN/ssh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\${@: -1}" > "$SSH_CMD"
printf '${1:-}'
exit $rc
EOF
  chmod +x "$STUB_BIN/ssh"
}

# ---------------------------------------------------------------------------
# remote listing
# ---------------------------------------------------------------------------

@test "list parses NUL-separated size/path records" {
  _load
  _stub_ssh '12\treport.pdf\x00345\tsub/deep.txt\x00'
  run _dvw_pull_list stubws
  [ "$status" -eq 0 ]
  # records come back NUL-separated; check both survived
  [[ "$output" == *"report.pdf"* ]]
  [[ "$output" == *"sub/deep.txt"* ]]
}

@test "list targets /workspaces/<ws>/out" {
  _load
  _stub_ssh '1\ta\x00'
  run _dvw_pull_list stubws
  run grep -q '/workspaces/stubws/out' "$SSH_CMD"
  [ "$status" -eq 0 ]
}

@test "list reports a missing out dir distinctly (rc 3)" {
  _load
  _stub_ssh "" 3
  run _dvw_pull_list stubws
  [ "$status" -eq 3 ]
}

@test "list reports ssh failure distinctly (rc 255)" {
  _load
  _stub_ssh "" 255
  run _dvw_pull_list stubws
  [ "$status" -eq 255 ]
}

@test "list of an empty out dir succeeds with no records" {
  _load
  _stub_ssh ""
  run _dvw_pull_list stubws
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# selection grammar (numbered fallback)
# ---------------------------------------------------------------------------

@test "numbered pick: single index" {
  _load
  DVW_ASSUME_TTY=1
  result=$(printf '2\n' | _dvw_pull_select a.txt b.txt c.txt)
  [ "$result" = "b.txt" ]
}

@test "numbered pick: comma list preserves listing order" {
  _load
  DVW_ASSUME_TTY=1
  result=$(printf '3,1\n' | _dvw_pull_select a.txt b.txt c.txt)
  [ "$result" = "$(printf 'a.txt\nc.txt')" ]
}

@test "numbered pick: range" {
  _load
  DVW_ASSUME_TTY=1
  result=$(printf '2-3\n' | _dvw_pull_select a.txt b.txt c.txt)
  [ "$result" = "$(printf 'b.txt\nc.txt')" ]
}

@test "numbered pick: all" {
  _load
  DVW_ASSUME_TTY=1
  result=$(printf 'all\n' | _dvw_pull_select a.txt b.txt c.txt)
  [ "$result" = "$(printf 'a.txt\nb.txt\nc.txt')" ]
}

@test "numbered pick: duplicates collapse" {
  _load
  DVW_ASSUME_TTY=1
  result=$(printf '1,1,1-2\n' | _dvw_pull_select a.txt b.txt c.txt)
  [ "$result" = "$(printf 'a.txt\nb.txt')" ]
}

@test "numbered pick: empty input cancels" {
  _load
  DVW_ASSUME_TTY=1
  printf '\n' | _dvw_pull_select a.txt b.txt c.txt && rc=0 || rc=$?
  [ "$rc" -ne 0 ]
}

@test "numbered pick: out-of-range index is an error" {
  _load
  DVW_ASSUME_TTY=1
  printf '9\n' | _dvw_pull_select a.txt b.txt c.txt && rc=0 || rc=$?
  [ "$rc" -ne 0 ]
  grep -q '9' "$ERRS"
}

@test "numbered pick: non-numeric is an error" {
  _load
  DVW_ASSUME_TTY=1
  printf 'x\n' | _dvw_pull_select a.txt b.txt c.txt && rc=0 || rc=$?
  [ "$rc" -ne 0 ]
}

@test "numbered pick: leading zeros are decimal, not octal" {
  _load
  DVW_ASSUME_TTY=1
  result=$(printf '09\n' | _dvw_pull_select a b c d e f g h i)
  [ "$result" = "i" ]
}

@test "numbered pick refuses non-TTY without the test seam" {
  _load
  printf '1\n' | _dvw_pull_select a.txt b.txt && rc=0 || rc=$?
  [ "$rc" -ne 0 ]
}

# ---------------------------------------------------------------------------
# collision resolution
# ---------------------------------------------------------------------------

@test "collision: no existing file returns the path unchanged, no prompt" {
  _load
  result=$(_dvw_pull_collide "$TMPDIR/new.txt" </dev/null)
  [ "$result" = "$TMPDIR/new.txt" ]
}

@test "collision: overwrite returns the same path" {
  _load
  : > "$TMPDIR/x.txt"
  DVW_ASSUME_TTY=1
  result=$(printf 'o\n' | _dvw_pull_collide "$TMPDIR/x.txt")
  [ "$result" = "$TMPDIR/x.txt" ]
}

@test "collision: skip returns rc 2" {
  _load
  : > "$TMPDIR/x.txt"
  DVW_ASSUME_TTY=1
  printf 's\n' | _dvw_pull_collide "$TMPDIR/x.txt" && rc=0 || rc=$?
  [ "$rc" -eq 2 ]
}

@test "collision: cancel returns rc 3" {
  _load
  : > "$TMPDIR/x.txt"
  DVW_ASSUME_TTY=1
  printf 'c\n' | _dvw_pull_collide "$TMPDIR/x.txt" && rc=0 || rc=$?
  [ "$rc" -eq 3 ]
}

@test "collision: rename to a free name returns it" {
  _load
  : > "$TMPDIR/x.txt"
  DVW_ASSUME_TTY=1
  result=$(printf 'r\nfree.txt\n' | _dvw_pull_collide "$TMPDIR/x.txt")
  [ "$result" = "$TMPDIR/free.txt" ]
}

@test "collision: rename offers name-1.ext as the default" {
  _load
  : > "$TMPDIR/x.txt"
  DVW_ASSUME_TTY=1
  result=$(printf 'r\n\n' | _dvw_pull_collide "$TMPDIR/x.txt")
  [ "$result" = "$TMPDIR/x-1.txt" ]
}

@test "collision: renaming onto another existing file re-prompts, never clobbers" {
  _load
  : > "$TMPDIR/x.txt"; printf 'keep' > "$TMPDIR/taken.txt"
  DVW_ASSUME_TTY=1
  result=$(printf 'r\ntaken.txt\ns\n' | _dvw_pull_collide "$TMPDIR/x.txt") && rc=0 || rc=$?
  [ "$rc" -eq 2 ]
  [ "$(cat "$TMPDIR/taken.txt")" = "keep" ]
}

@test "collision: rename cannot escape the destination directory" {
  _load
  : > "$TMPDIR/x.txt"
  DVW_ASSUME_TTY=1
  result=$(printf 'r\n../evil.txt\nfree.txt\n' | _dvw_pull_collide "$TMPDIR/x.txt")
  [ "$result" = "$TMPDIR/free.txt" ]
}

@test "collision on non-TTY stdin is an error, not a silent overwrite" {
  _load
  printf 'keep' > "$TMPDIR/x.txt"
  _dvw_pull_collide "$TMPDIR/x.txt" </dev/null && rc=0 || rc=$?
  [ "$rc" -eq 1 ]
  [ "$(cat "$TMPDIR/x.txt")" = "keep" ]
}

# ---------------------------------------------------------------------------
# relative-path safety
# ---------------------------------------------------------------------------

@test "relative path safety accepts ordinary names" {
  _load
  _dvw_pull_safe_relpath "a.txt"
  _dvw_pull_safe_relpath "sub/dir/a.txt"
  _dvw_pull_safe_relpath "weird name:with-colon.txt"
}

@test "relative path safety rejects traversal, absolute and empty" {
  _load
  ! _dvw_pull_safe_relpath "../a.txt"
  ! _dvw_pull_safe_relpath "sub/../../a.txt"
  ! _dvw_pull_safe_relpath "/etc/passwd"
  ! _dvw_pull_safe_relpath ""
}

@test "relative path safety allows .. inside a name" {
  _load
  _dvw_pull_safe_relpath "weird..name.txt"
}
