#!/usr/bin/env bash
# dvw push — deliver a local file into the workspace this client is attached
# to. Spec: docs/superpowers/specs/2026-08-18-dvw-push-design.md

# Live sessions this client machine currently has open, one workspace id per
# line, deduped. A session is live iff its connect marker dir (created by
# _dvw_ssh_session, lib/connect.sh) has both registry files and the recorded
# pid is still alive. Dead-pid dirs (SIGKILL orphaned the RETURN trap) are
# ignored, not reaped — mktemp names carry no reuse risk and /tmp clears on
# reboot.
_dvw_push_live_sessions() {
  local d ws pid
  for d in "${TMPDIR:-/tmp}"/dvw-ssh.*/; do
    [[ -f "$d/workspace" && -f "$d/pid" ]] || continue
    ws=$(cat -- "$d/workspace" 2>/dev/null) || continue
    pid=$(cat -- "$d/pid" 2>/dev/null) || continue
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    kill -0 "$pid" 2>/dev/null || continue
    printf '%s\n' "$ws"
  done | sort -u
}

# Size gate, shared by fresh-pick and explicit-file paths. Silent: callers
# word the error with the file name and the active cap.
_dvw_push_check_size() {
  local f="$1" cap_mb="${DVW_PUSH_MAX_SIZE_MB:-50}" bytes
  bytes=$(stat -c %s "$f" 2>/dev/null) || return 1
  (( bytes <= cap_mb * 1024 * 1024 ))
}

# Newest fresh Termius-style upload in ${TMPDIR:-/tmp}. Termius mobile names
# SFTP paste-uploads as bare UUIDv4 + original extension (observed 2026-08-18;
# undocumented upstream — recognizer only, never load-bearing: if it changes,
# `dvw push <file>` still works). Prints the path; rc 1 (silent) when none.
_dvw_push_pick_fresh() {
  local fresh="${DVW_PUSH_FRESH_MINUTES:-10}" line f
  while IFS= read -r line; do
    f="${line#* }"
    _dvw_push_check_size "$f" || continue
    printf '%s\n' "$f"
    return 0
  done < <(find "${TMPDIR:-/tmp}" -maxdepth 1 -type f -user "$(id -un)" \
      -mmin -"$fresh" -regextype posix-extended \
      -regex '.*/[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}\.[A-Za-z0-9]+' \
      -printf '%T@ %p\n' 2>/dev/null | sort -rn)
  return 1
}
