#!/usr/bin/env bash
# dvw push — deliver a local file into the workspace this client is attached
# to. Spec: docs/superpowers/specs/2026-08-18-dvw-push-design.md

# Live sessions this client machine currently has open, one workspace id per
# line, deduped. A session is live iff its connect marker dir (created by
# _dvw_ssh_session, lib/connect.sh) has the registry files, the `connected`
# marker OpenSSH touches on authentication (absent while a connect attempt or
# reconnect backoff is in flight — a session mid-retry must not look
# pushable, or a push could auto-boot a stopped workspace), a live recorded
# pid, and — when an identity token was recorded — a matching current
# identity for that pid (PID reuse defense). Dead dirs (SIGKILL orphaned the
# RETURN trap) are ignored, not reaped — mktemp names carry no reuse risk and
# /tmp clears on reboot.
_dvw_push_live_sessions() {
  local d ws pid recorded current
  for d in "${TMPDIR:-/tmp}"/dvw-ssh.*/; do
    [[ -f "$d/workspace" && -f "$d/pid" ]] || continue
    [[ -e "$d/connected" ]] || continue
    ws=$(cat -- "$d/workspace" 2>/dev/null) || continue
    pid=$(cat -- "$d/pid" 2>/dev/null) || continue
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    kill -0 "$pid" 2>/dev/null || continue
    if [[ -f "$d/pid-start" ]]; then
      recorded=$(cat -- "$d/pid-start" 2>/dev/null) || continue
      current=$(_dvw_proc_identity "$pid")
      # Empty current = /proc unavailable: identity unknowable, keep the
      # plain kill -0 verdict rather than dropping every session.
      [[ -z "$current" || "$current" == "$recorded" ]] || continue
    fi
    printf '%s\n' "$ws"
  done | sort -u
}

# One default size cap for both transfer directions — pull mirrors push and
# must not drift from it (pull spec). Each direction stays independently
# overridable in the environment; only the default is shared.
: "${DVW_PUSH_MAX_SIZE_MB:=200}"

# Size gate, shared by fresh-pick and explicit-file paths. Silent: callers
# word the error with the file name and the active cap.
_dvw_push_check_size() {
  local f="$1" cap_mb="$DVW_PUSH_MAX_SIZE_MB" bytes
  bytes=$(stat -c %s -- "$f" 2>/dev/null) || return 1
  (( bytes <= cap_mb * 1024 * 1024 ))
}

# Roots the fresh-picker searches, one per line: ${TMPDIR:-/tmp} (test seam
# and session-registry prefix) plus always /tmp — Termius's SFTP destination
# is a property of the phone-side flow, not of this process's TMPDIR, so a
# host with TMPDIR pointing elsewhere (systemd user sessions often use
# /run/user/<uid>) must still see /tmp uploads. Deduped; always returns 0.
_dvw_push_fresh_roots() {
  local t="${TMPDIR:-/tmp}"
  t="${t%/}"
  [[ -n "$t" ]] || t=/
  printf '%s\n' "$t"
  if [[ "$t" != /tmp ]]; then printf '/tmp\n'; fi
  return 0
}

# Newest fresh Termius-style upload across _dvw_push_fresh_roots. Termius
# mobile names SFTP paste-uploads as bare UUIDv4 + original extension
# (observed 2026-08-18; undocumented upstream — recognizer only, never
# load-bearing: if it changes, `dvw push <file>` still works). Prints the
# path; rc 1 (silent) when none.
_dvw_push_pick_fresh() {
  local fresh="${DVW_PUSH_FRESH_MINUTES:-10}" line f
  local -a roots
  mapfile -t roots < <(_dvw_push_fresh_roots)
  while IFS= read -r line; do
    f="${line#* }"
    _dvw_push_check_size "$f" || continue
    printf '%s\n' "$f"
    return 0
  done < <(find "${roots[@]}" -maxdepth 1 -type f -user "$(id -un)" \
      -mmin -"$fresh" -regextype posix-extended \
      -regex '.*/[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}\.[A-Za-z0-9]+' \
      -printf '%T@ %p\n' 2>/dev/null | sort -rn)
  return 1
}

# Gate: refuse unless the catalog reports a RUNNING container for $1. Every
# push target passes through here immediately before the transfer, because
# merely opening the alias would auto-up a stopped workspace (devpod ssh
# --stdio, no opt-out; wiki-verified v0.6.15) — and a live session marker is
# necessary but not sufficient proof of running: the workspace may have been
# stopped since, or the marker may be stale. Fail closed on an unreachable
# catalog rather than guess.
_dvw_push_require_running() {
  local ws="$1"
  case "$(_dvw_ws_container_state "$ws")" in
    yes) return 0 ;;
    no)
      ui_error "push: $ws is not running — refusing (a push would silently boot it)"
      ui_info "  start it first: dvw start $ws"
      return 1 ;;
    *)
      ui_error "push: catalog unreachable — can't confirm $ws is running; refusing to guess"
      return 1 ;;
  esac
}

# Resolve the push target to exactly one workspace id (printed on stdout).
# With $1 (--to value): taken as-is. Without: live attached sessions on this
# machine — one wins outright, several go to a picker, none is an error.
# Resolution only picks a name; the RUNNING gate (_dvw_push_require_running)
# runs in cmd_push on whatever was picked, so both paths hit the same check
# right before the alias is touched.
_dvw_push_resolve_target() {
  local to="${1:-}"
  if [[ -n "$to" ]]; then
    printf '%s\n' "$to"
    return 0
  fi

  local sessions count=0
  # _dvw_push_live_sessions always returns rc 0 (it filters, never errors) —
  # relied on here since this call site runs under errexit.
  sessions=$(_dvw_push_live_sessions)
  [[ -n "$sessions" ]] && count=$(wc -l <<<"$sessions")

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
    sel=$(printf '%s\n' "$sessions" | fzf --prompt='push to> ' --height=40% --reverse) \
      || { ui_error "push: selection cancelled"; return 1; }
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

_dvw_push_usage() {
  ui_error "usage: dvw push [<file>...] [--clipboard] [--to <ws>]"
}

# Copy the landed path to the local clipboard when a tool exists (desktop
# nicety). Printing the path is the contract; this is best-effort and silent
# about failures. Returns 0 only when a tool actually copied (a present but
# failing tool falls through to the next one, then to rc 1) — callers use
# the rc to decide whether to mention the copy, never printing anything
# themselves, and must never claim "copied" on rc 1.
_dvw_push_copy_path() {
  local p="$1"
  if command -v wl-copy >/dev/null; then
    printf '%s' "$p" | wl-copy 2>/dev/null && return 0
  fi
  if command -v xclip >/dev/null; then
    printf '%s' "$p" | xclip -selection clipboard 2>/dev/null && return 0
  fi
  if command -v clip.exe >/dev/null; then
    printf '%s' "$p" | clip.exe 2>/dev/null && return 0
  fi
  return 1
}

# Clipboard image -> temp png, path on stdout. First tool wins: wl-paste
# (Wayland), xclip (X11), PowerShell (WSL). Named clip-<HHMMSS>.png so the
# mirrored container path is readable in an agent prompt. Tool detection runs
# before mktemp and every error branch removes $out, so no path out of here
# leaves a stray temp file; the success path hands ownership of $out to the
# caller, which is responsible for removing it after the transfer.
_dvw_push_clipboard_grab() {
  local tool
  # WSL detection outranks tool discovery: WSLg installs wl-paste and sets
  # WAYLAND_DISPLAY, but its bridge exposes clipboard images as image/bmp
  # only, so the wl-paste branch fails without falling through — the
  # powershell branch is the one that actually works there. (Clipboard-bridge
  # spec, R3 finding.)
  if wsl_bridge_is_wsl && command -v powershell.exe >/dev/null; then tool=powershell
  elif command -v wl-paste >/dev/null; then tool=wl-paste
  elif command -v xclip >/dev/null; then tool=xclip
  elif command -v powershell.exe >/dev/null; then tool=powershell
  else
    ui_error "push: no clipboard tool found (wl-paste, xclip, or powershell.exe)"
    return 1
  fi
  local out
  out=$(mktemp "${TMPDIR:-/tmp}/clip-XXXXXX.png") || { ui_error "push: mktemp failed"; return 1; }
  case "$tool" in
    wl-paste)
      wl-paste --type image/png > "$out" 2>/dev/null || { ui_error "push: no image on the clipboard (wl-paste)"; rm -f "$out"; return 1; } ;;
    xclip)
      xclip -selection clipboard -t image/png -o > "$out" 2>/dev/null || { ui_error "push: no image on the clipboard (xclip)"; rm -f "$out"; return 1; } ;;
    powershell)
      local win
      win=$(wslpath -w "$out" 2>/dev/null) || { ui_error "push: wslpath failed"; rm -f "$out"; return 1; }
      powershell.exe -NoProfile -Command "
        Add-Type -AssemblyName System.Windows.Forms;
        \$img = [System.Windows.Forms.Clipboard]::GetImage();
        if (\$img -eq \$null) { exit 1 };
        \$img.Save('$win', [System.Drawing.Imaging.ImageFormat]::Png)" \
        >/dev/null 2>&1 || { ui_error "push: no image on the Windows clipboard"; rm -f "$out"; return 1; } ;;
  esac
  [[ -s "$out" ]] || { ui_error "push: clipboard produced an empty file"; rm -f "$out"; return 1; }
  printf '%s\n' "$out"
}

cmd_push() {
  local -a files=()
  local to="" clipboard=0 arg
  # generated: temp file this invocation created (clipboard grab) — removed
  # on every return path by the trap below, success and failure alike, so
  # screenshots never accumulate in TMPDIR. Same disarm-first RETURN-trap
  # idiom as _dvw_ssh_session (lib/connect.sh) for the same set -u reason.
  local generated=""
  trap 'trap - RETURN; if [[ -n "${generated:-}" ]]; then rm -f -- "$generated"; fi' RETURN
  while (($#)); do
    arg="$1"; shift
    case "$arg" in
      --to)
        [[ -n "${1:-}" ]] || { _dvw_push_usage; return 1; }
        to="$1"; shift ;;
      --clipboard) clipboard=1 ;;
      # Standard option terminator: everything after `--` is a file, so
      # dash-leading names (e.g. --weird.png) are pushable; the scp source
      # handling below already makes them safe on the transfer side.
      --) files+=("$@"); break ;;
      --*) ui_error "push: unknown flag: $arg"; _dvw_push_usage; return 1 ;;
      *) files+=("$arg") ;;
    esac
  done

  if (( clipboard )) && ((${#files[@]})); then
    ui_error "push: --clipboard and file arguments are mutually exclusive"
    return 1
  fi

  if (( clipboard )); then
    local grabbed
    grabbed=$(_dvw_push_clipboard_grab) || return 1
    generated="$grabbed"
    files=("$grabbed")
  elif ((${#files[@]} == 0)); then
    local fresh roots_msg
    if ! fresh=$(_dvw_push_pick_fresh); then
      roots_msg=$(_dvw_push_fresh_roots | head -1)
      [[ "$roots_msg" != /tmp ]] && roots_msg="$roots_msg or /tmp"
      ui_error "push: nothing fresh to push — no <uuid>.<ext> file of yours in $roots_msg newer than ${DVW_PUSH_FRESH_MINUTES:-10} min and under ${DVW_PUSH_MAX_SIZE_MB} MB"
      ui_info "  push a specific file instead: dvw push <file>"
      return 1
    fi
    files=("$fresh")
    # Spec: announce the auto-picked file before transfer so the user knows
    # what "no args" resolved to. Best-effort/guarded: age display must never
    # fail the push under set -euo pipefail.
    local age now mtime
    now=$(date +%s) || now=0
    mtime=$(stat -c %Y "$fresh" 2>/dev/null) || mtime="$now"
    age=$(( now - mtime )) 2>/dev/null || age=0
    ui_info "pushing $(basename "$fresh") (uploaded ${age}s ago)"
  fi

  local f
  for f in "${files[@]}"; do
    [[ -f "$f" ]] || { ui_error "push: no such file: $f"; return 1; }
    _dvw_push_check_size "$f" || {
      ui_error "push: $f exceeds the ${DVW_PUSH_MAX_SIZE_MB} MB cap"
      return 1
    }
  done

  local ws
  ws=$(_dvw_push_resolve_target "$to") || return 1
  # RUNNING gate for every path — explicit --to and live-session alike —
  # immediately before anything touches the auto-starting alias. See
  # _dvw_push_require_running for why a live session marker is not enough.
  _dvw_push_require_running "$ws" || return 1
  # Materialize local devpod state from the catalog snapshot before touching
  # the ssh alias — mirrors cmd_connect (lib/connect.sh:45-46). Without this,
  # `--to <ws>` on a client that never registered <ws> writes a persistently
  # wrong guessed-user alias block into ~/.ssh/config and then fails opaquely.
  _dvw_ensure_local_devpod_state "$ws" || return 1
  _dvw_ensure_ssh_alias "$ws" || return 1

  local base bytes rc src
  for f in "${files[@]}"; do
    base=$(basename -- "$f")
    bytes=$(stat -c %s -- "$f" 2>/dev/null || echo 0)
    rc=0
    # scp treats a leading `user@host:` colon or a leading `-` in the source
    # specially; force a relative path unambiguous with `./` so a file named
    # e.g. "foo:bar.png" or "-oProxyCommand=..." is never misparsed.
    src="$f"
    [[ "$src" == /* ]] || src="./$src"
    _dvw_run_or_print scp -q "$src" "${ws}.devpod:/tmp/" || rc=$?
    if (( rc != 0 )); then
      ui_error "push: scp to ${ws}.devpod failed (rc=$rc) — remaining files skipped"
      return "$rc"
    fi
    # Dry-run already printed the would-run scp line above; skip the status
    # line, clipboard copy, and final path print — none of them are real.
    if [[ "${DVW_DRY_RUN:-}" == "1" ]]; then
      continue
    fi
    if _dvw_push_copy_path "/tmp/$base"; then
      ui_status_ok "$base → $ws ($(( bytes / 1024 )) KB, path copied to clipboard)"
    else
      ui_status_ok "$base → $ws ($(( bytes / 1024 )) KB)"
    fi
    printf '%s\n' "/tmp/$base"
  done
}
