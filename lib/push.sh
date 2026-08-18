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
