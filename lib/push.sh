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

# Resolve the push target to exactly one workspace id (printed on stdout).
# With $1 (--to value): trust nothing — gate on the catalog reporting a
# RUNNING container, because merely opening the alias would auto-up a stopped
# workspace (devpod ssh --stdio, no opt-out; wiki-verified v0.6.15).
# Without: live attached sessions on this machine are proof-of-running by
# construction — one wins outright, several go to a picker, none is an error.
_dvw_push_resolve_target() {
  local to="${1:-}"
  if [[ -n "$to" ]]; then
    case "$(_dvw_ws_container_state "$to")" in
      yes) printf '%s\n' "$to"; return 0 ;;
      no)
        ui_error "push: $to is not running — refusing (a push would silently boot it)"
        ui_info "  start it first: dvw start $to"
        return 1 ;;
      *)
        ui_error "push: catalog unreachable — can't confirm $to is running; refusing to guess"
        return 1 ;;
    esac
  fi

  local sessions count
  sessions=$(_dvw_push_live_sessions)
  count=$(grep -c . <<<"$sessions" 2>/dev/null || echo 0)
  [[ -z "$sessions" ]] && count=0

  if (( count == 0 )); then
    ui_error "push: not attached to any workspace from this machine — use dvw push --to <ws>"
    return 1
  fi
  if (( count == 1 )); then
    printf '%s\n' "$sessions"
    return 0
  fi

  # Several attached workspaces: pick one. fzf-preferred, numbered fallback —
  # same idiom as cmd_attach (lib/commands.sh), including the DVW_ASSUME_TTY
  # test seam and base-10 forcing (leading zeros would parse as octal).
  local sel
  if command -v fzf >/dev/null; then
    sel=$(printf '%s\n' "$sessions" | fzf --prompt='push to> ' --height=40% --reverse) || return 1
  else
    local n i=0 line pick
    n=$count
    while IFS= read -r line; do
      i=$((i+1))
      printf '%2d) %s\n' "$i" "$line" >&2
    done <<<"$sessions"
    if [[ ! -t 0 && "${DVW_ASSUME_TTY:-}" != "1" ]]; then
      ui_error "push: attached to $count workspaces and no way to pick non-interactively — use --to <ws>"
      return 1
    fi
    printf 'push to #> ' >&2
    IFS= read -r pick || pick=""
    if [[ ! "$pick" =~ ^[0-9]+$ ]]; then
      ui_error "invalid selection: ${pick:-<empty>}"
      return 1
    fi
    pick=$((10#$pick))
    if (( pick < 1 || pick > n )); then
      ui_error "invalid selection: $pick"
      return 1
    fi
    sel=$(sed -n "${pick}p" <<<"$sessions")
  fi
  [[ -n "$sel" ]] || { ui_error "push: no workspace selected"; return 1; }
  printf '%s\n' "$sel"
}
