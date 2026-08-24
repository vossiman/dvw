#!/usr/bin/env bash
# dvw pull — take files out of the workspace this client is attached to, via
# the project's `out/` outbox. Mirror of `dvw push`.
# Spec: docs/superpowers/specs/2026-08-22-dvw-pull-design.md
#
# Target resolution, the RUNNING gate and alias registration are push's, used
# verbatim (_dvw_push_resolve_target / _dvw_push_require_running) — the two
# commands have exactly the same "which workspace, and is it safe to touch its
# alias" problem, and pull must not drift from push's answer.

# The outbox for a workspace. One place, so the listing and the transfers can
# never disagree about where files come from.
_dvw_pull_remote_dir() { printf '/workspaces/%s/out\n' "$1"; }

# Human sizes for the numbered picker's left column, keyed by relative path.
# Declared at load time, not at the call site: without a standing `-A` bash
# treats the name as an INDEXED array and evaluates the subscript
# arithmetically, so `${DVW_PULL_SIZES[a.txt]}` aborts the picker under
# set -e. Populated by cmd_pull; an empty map just omits the column.
declare -gA DVW_PULL_SIZES=()

# Origin workspace for the pickers' prompt/header, so an interactive pull
# says WHOSE outbox is on screen. Set by cmd_pull; empty just omits it.
declare -g DVW_PULL_FROM_WS=""

_dvw_pull_usage() {
  ui_error "usage: dvw pull [<file>...] [--from <ws>] [--all]"
}

# Reject a relative path instead of sanitizing it. `find -printf '%P'` can
# never emit an absolute or traversing path, so in practice this only fires on
# a hand-typed argument — but both routes go through here, so a listing from a
# compromised or merely surprising container can't write outside $PWD either.
# A literal `..` inside a name (weird..name.txt) is fine; only a whole `..`
# path component is refused.
_dvw_pull_safe_relpath() {
  local p="$1"
  [[ -n "$p" ]] || return 1
  [[ "$p" != /* ]] || return 1
  case "/$p/" in
    */../*) return 1 ;;
  esac
  return 0
}

# Bytes -> short human string, for the picker only. Integer math (bash has no
# floats) with one decimal kept by scaling: 1536 -> "1.5 KB".
_dvw_pull_human() {
  local b="$1"
  if (( b < 1024 )); then printf '%d B\n' "$b"; return; fi
  local unit div=1024
  for unit in KB MB GB TB; do
    if (( b < div * 1024 )) || [[ "$unit" == TB ]]; then
      printf '%d.%d %s\n' $(( b / div )) $(( (b % div) * 10 / div )) "$unit"
      return
    fi
    div=$(( div * 1024 ))
  done
}

# List the outbox. Emits NUL-terminated "<size>\t<relpath>" records on stdout.
# Records are NUL-separated because a newline in a filename would otherwise
# desynchronize the parse and silently shift every size onto the wrong name.
# Exit codes are the caller's whole diagnosis:
#   0   listed (possibly zero records — an empty outbox)
#   3   the out/ directory does not exist
#   255 ssh itself failed (unreachable, auth) — NOT an empty outbox
#   *   the remote find failed
_dvw_pull_list() {
  local ws="$1" dir
  dir=$(_dvw_pull_remote_dir "$ws")
  # printf %q the path into the remote command: OpenSSH hands the command to
  # the remote login shell as one string, which re-parses it.
  ssh -o ConnectTimeout=10 -o BatchMode=yes "${ws}.devpod" \
    "d=$(printf '%q' "$dir"); [ -d \"\$d\" ] || exit 3; find \"\$d\" -mindepth 1 -type f -printf '%s\t%P\0'"
}

# Interactive multi-select over the names in "$@". Selected names go to stdout
# one per line, always in listing order regardless of the order they were
# picked. rc 1 = cancelled or invalid.
#
# fzf --multi when available; otherwise a numbered list accepting indices,
# comma lists, ranges and `all`. Same DVW_ASSUME_TTY test seam and base-10
# forcing (leading zeros would parse as octal) as cmd_attach and push's picker.
_dvw_pull_select() {
  local -a names=("$@")
  local n=${#names[@]}
  (( n > 0 )) || return 1

  # Both pickers are line-oriented, and the fallback splits on a tab. A name
  # containing either can't survive the round trip, so drop it loudly rather
  # than hand back a mangled name that would then be pulled to the wrong path.
  local -a pickable=() dropped=()
  local name
  for name in "${names[@]}"; do
    if [[ "$name" == *$'\n'* || "$name" == *$'\t'* ]]; then
      dropped+=("$name")
    else
      pickable+=("$name")
    fi
  done
  if ((${#dropped[@]})); then
    ui_status_warn "pull: ${#dropped[@]} file(s) with a tab or newline in the name can't be listed — pull them by name"
  fi
  n=${#pickable[@]}
  (( n > 0 )) || { ui_error "pull: nothing selectable"; return 1; }

  # Both pickers name the origin workspace, so the user sees whose outbox
  # they are choosing from before the first byte moves.
  local origin="${DVW_PULL_FROM_WS:-}"
  if command -v fzf >/dev/null; then
    local sel
    sel=$(printf '%s\n' "${pickable[@]}" \
      | fzf --multi --prompt="pull${origin:+ $origin}> " --height=40% --reverse \
            --header="${origin:+$origin outbox — }TAB to select several, ENTER to confirm") \
      || { ui_error "pull: selection cancelled"; return 1; }
    [[ -n "$sel" ]] || { ui_error "pull: nothing selected"; return 1; }
    printf '%s\n' "$sel"
    return 0
  fi

  local i
  if [[ -n "$origin" ]]; then printf '%s outbox:\n' "$origin" >&2; fi
  for (( i = 0; i < n; i++ )); do
    printf '%2d) %s%s\n' "$((i + 1))" "${DVW_PULL_SIZES[${pickable[i]}]:+${DVW_PULL_SIZES[${pickable[i]}]}  }" "${pickable[i]}" >&2
  done
  if [[ ! -t 0 && "${DVW_ASSUME_TTY:-}" != "1" ]]; then
    ui_error "pull: no way to pick non-interactively — name the files, or use --all"
    return 1
  fi
  printf 'pull #> (e.g. 1,3 or 2-4 or all) ' >&2
  local pick
  IFS= read -r pick || pick=""
  [[ -n "$pick" ]] || { ui_error "pull: cancelled"; return 1; }

  # chosen[i]=1 marks index i; emitting by ascending index afterwards is what
  # makes the output listing-ordered and duplicate-free for free.
  local -a chosen=()
  if [[ "$pick" == all ]]; then
    for (( i = 0; i < n; i++ )); do chosen[i]=1; done
  else
    local part lo hi
    local IFS_SAVE="$IFS"; IFS=','
    # shellcheck disable=SC2206  # deliberate split on commas
    local -a parts=($pick)
    IFS="$IFS_SAVE"
    for part in "${parts[@]}"; do
      part="${part//[[:space:]]/}"
      [[ -n "$part" ]] || continue
      if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        lo=$((10#${BASH_REMATCH[1]})); hi=$((10#${BASH_REMATCH[2]}))
      elif [[ "$part" =~ ^[0-9]+$ ]]; then
        lo=$((10#$part)); hi=$lo
      else
        ui_error "pull: invalid selection: $part"
        return 1
      fi
      if (( lo < 1 || hi > n || lo > hi )); then
        ui_error "pull: selection out of range (1-$n): $part"
        return 1
      fi
      for (( i = lo; i <= hi; i++ )); do chosen[i-1]=1; done
    done
  fi

  local any=0
  for (( i = 0; i < n; i++ )); do
    if [[ "${chosen[i]:-}" == 1 ]]; then printf '%s\n' "${pickable[i]}"; any=1; fi
  done
  (( any )) || { ui_error "pull: nothing selected"; return 1; }
}

# Decide where $1 actually lands. Prints the final path on stdout.
#   rc 0 = go ahead with the printed path (may differ from $1)
#   rc 2 = skip this file
#   rc 3 = cancel the whole pull
#   rc 1 = can't ask (non-interactive) — refuse rather than pick a default
# The prompt goes to stderr so the printed path stays the only thing on stdout.
_dvw_pull_collide() {
  local path="$1"
  [[ -e "$path" ]] || { printf '%s\n' "$path"; return 0; }

  local dir base stem ext suggestion reply name
  dir=$(dirname -- "$path")
  while :; do
    if [[ ! -t 0 && "${DVW_ASSUME_TTY:-}" != "1" ]]; then
      ui_error "pull: $path exists and stdin is not a terminal — refusing to overwrite"
      return 1
    fi
    printf '%s exists: [o]verwrite / [r]ename / [s]kip / [c]ancel? ' "$path" >&2
    IFS= read -r reply || return 3
    case "$reply" in
      o|O) printf '%s\n' "$path"; return 0 ;;
      s|S) return 2 ;;
      c|C) return 3 ;;
      r|R)
        base=$(basename -- "$path")
        # name-1.ext, or name-1 when there is no extension. A leading-dot name
        # (.env) is all stem, so the suffix lands at the end where it belongs.
        if [[ "$base" == ?*.* && "$base" != .* ]]; then
          stem="${base%.*}"; ext=".${base##*.}"
        else
          stem="$base"; ext=""
        fi
        suggestion="${stem}-1${ext}"
        # Inner loop: a rejected name re-asks for a NAME. Falling back to the
        # o/r/s/c question would swallow the user's next line as an answer to
        # a question they weren't asked.
        while :; do
          printf 'new name [%s]: ' "$suggestion" >&2
          IFS= read -r name || return 3
          [[ -n "$name" ]] || name="$suggestion"
          # A rename is a name, not a path: it must stay in the destination
          # directory, so a download can't be relocated by a typo.
          if [[ "$name" == */* || "$name" == . || "$name" == .. ]]; then
            ui_error "pull: name only, no directories: $name"
            continue
          fi
          break
        done
        path="$dir/$name"
        # Outer loop: the new name may collide too, and answering rename twice
        # must not end up clobbering the second file either.
        [[ -e "$path" ]] || { printf '%s\n' "$path"; return 0; }
        ;;
      *) ui_error "pull: answer o, r, s or c" ;;
    esac
  done
}

# Fetch remote path $2 from workspace $1 to local path $3.
#
# `ssh cat`, not scp, deliberately. scp has two incompatible behaviours for
# the remote path depending on the OpenSSH version: before 9.0 the remote
# shell re-parses it (so a name with a space needs shell quoting), from 9.0 it
# travels over SFTP verbatim (so the same quoting would become part of the
# name). No single spelling is right for both, and this client talks to
# whatever sshd devpod injected. `ssh cat` has exactly one parser — the remote
# shell — and we quote for it with printf %q.
#
# The bytes land in a sibling .dvw-part file and are renamed into place only
# after a clean exit, so an interrupted transfer never leaves a truncated file
# under the real name — and never destroys the file the user chose to
# overwrite. mv is same-directory, hence atomic.
_dvw_pull_fetch() {
  local ws="$1" remote="$2" dest="$3"
  if [[ "${DVW_DRY_RUN:-}" == "1" ]]; then
    _dvw_run_or_print ssh "${ws}.devpod" "cat -- $(printf '%q' "$remote")" ">$dest"
    return 0
  fi
  local part="${dest}.dvw-part" rc=0
  ssh -o BatchMode=yes "${ws}.devpod" "cat -- $(printf '%q' "$remote")" > "$part" || rc=$?
  if (( rc != 0 )); then
    rm -f -- "$part"
    return "$rc"
  fi
  mv -f -- "$part" "$dest" || { rm -f -- "$part"; return 1; }
}

cmd_pull() {
  local -a wanted=()
  local from="" all=0 arg
  while (($#)); do
    arg="$1"; shift
    case "$arg" in
      --from)
        [[ -n "${1:-}" ]] || { _dvw_pull_usage; return 1; }
        from="$1"; shift ;;
      --all) all=1 ;;
      # Standard option terminator, so a file literally named --weird.txt is
      # pullable.
      --) wanted+=("$@"); break ;;
      --*) ui_error "pull: unknown flag: $arg"; _dvw_pull_usage; return 1 ;;
      *) wanted+=("$arg") ;;
    esac
  done

  if (( all )) && ((${#wanted[@]})); then
    ui_error "pull: --all and file arguments are mutually exclusive"
    return 1
  fi

  # Validate typed names before anything reaches the network: a traversing
  # argument is a mistake worth reporting immediately, not after an ssh.
  local w
  for w in "${wanted[@]}"; do
    _dvw_pull_safe_relpath "$w" || {
      ui_error "pull: refusing unsafe path: $w (names are relative to out/)"
      return 1
    }
  done

  local ws
  ws=$(_dvw_push_resolve_target "$from") || return 1
  # RUNNING gate before the alias is touched — opening it would auto-boot a
  # stopped workspace (devpod ssh --stdio, no opt-out). Same reasoning, same
  # helper, as cmd_push.
  _dvw_push_require_running "$ws" || return 1
  _dvw_ensure_local_devpod_state "$ws" || return 1
  _dvw_ensure_ssh_alias "$ws" || return 1

  local remote_dir listing rc=0
  remote_dir=$(_dvw_pull_remote_dir "$ws")
  # The listing goes to a FILE, never through $( ): command substitution
  # strips NUL bytes, which are exactly what separates the records. Removed on
  # every return path by the trap — same disarm-first RETURN-trap idiom as
  # cmd_push's clipboard temp file, for the same set -u reason.
  listing=$(mktemp "${TMPDIR:-/tmp}/dvw-pull-XXXXXX") || {
    ui_error "pull: mktemp failed"
    return 1
  }
  trap 'trap - RETURN; if [[ -n "${listing:-}" ]]; then rm -f -- "$listing"; fi' RETURN
  _dvw_pull_list "$ws" > "$listing" || rc=$?
  case "$rc" in
    0) ;;
    3)
      ui_error "pull: $ws has no outbox — $remote_dir does not exist"
      ui_info "  create it in the container: mkdir -p $remote_dir"
      return 1 ;;
    255)
      ui_error "pull: ${ws}.devpod is unreachable — could not list $remote_dir"
      return 1 ;;
    *)
      ui_error "pull: listing $remote_dir failed (rc=$rc)"
      return 1 ;;
  esac

  # Parse the NUL-separated "<size>\t<relpath>" records into parallel state.
  local -a names=()
  declare -A sizes=()
  local rec size path
  while IFS= read -r -d '' rec; do
    [[ -n "$rec" ]] || continue
    size="${rec%%$'\t'*}"
    path="${rec#*$'\t'}"
    [[ "$size" =~ ^[0-9]+$ ]] || continue
    _dvw_pull_safe_relpath "$path" || {
      ui_status_warn "pull: skipping unsafe remote path: $path"
      continue
    }
    names+=("$path")
    sizes["$path"]="$(_dvw_pull_human "$size")"
    sizes["bytes:$path"]="$size"
  done < "$listing"

  if ((${#names[@]} == 0)); then
    ui_error "pull: nothing in $remote_dir"
    return 1
  fi

  # `find` returns directory order, which is arbitrary and can differ between
  # two runs over an unchanged outbox — so the number you picked last time
  # would silently point at a different file. Sort so the listing is stable.
  # Byte order (LC_ALL=C), so the numbering doesn't shift with the locale.
  mapfile -d '' -t names < <(printf '%s\0' "${names[@]}" | LC_ALL=C sort -z)

  local -a selected=()
  if ((${#wanted[@]})); then
    for w in "${wanted[@]}"; do
      if [[ -z "${sizes[bytes:$w]:-}" ]]; then
        ui_error "pull: no such file in $remote_dir: $w"
        return 1
      fi
      selected+=("$w")
    done
  elif (( all )); then
    selected=("${names[@]}")
  else
    # Exported for the numbered picker's size column; scoped to this call.
    declare -gA DVW_PULL_SIZES=()
    for w in "${names[@]}"; do DVW_PULL_SIZES["$w"]="${sizes[$w]}"; done
    DVW_PULL_FROM_WS="$ws"
    local sel
    sel=$(_dvw_pull_select "${names[@]}") || return 1
    mapfile -t selected <<<"$sel"
  fi

  # Size gate for everything selected, before the first byte moves: a run that
  # is going to refuse a file should refuse it before half the set has landed.
  local cap_mb="${DVW_PULL_MAX_SIZE_MB:-50}" bytes
  for w in "${selected[@]}"; do
    bytes="${sizes[bytes:$w]:-0}"
    if (( bytes > cap_mb * 1024 * 1024 )); then
      ui_error "pull: $w exceeds the ${cap_mb} MB cap"
      return 1
    fi
  done

  local dest destdir part
  for w in "${selected[@]}"; do
    dest="./$w"
    destdir=$(dirname -- "$dest")
    mkdir -p -- "$destdir" || { ui_error "pull: cannot create $destdir"; return 1; }

    rc=0
    dest=$(_dvw_pull_collide "$dest") || rc=$?
    case "$rc" in
      0) ;;
      2) ui_info "pull: skipped $w"; continue ;;
      3) ui_info "pull: cancelled"; return 0 ;;
      *) return 1 ;;
    esac
    [[ "$dest" == /* || "$dest" == ./* ]] || dest="./$dest"

    rc=0
    _dvw_pull_fetch "$ws" "$remote_dir/$w" "$dest" || rc=$?
    if (( rc != 0 )); then
      ui_error "pull: fetching $w from ${ws}.devpod failed (rc=$rc) — remaining files skipped"
      return "$rc"
    fi
    if [[ "${DVW_DRY_RUN:-}" == "1" ]]; then
      continue
    fi
    ui_status_ok "$ws:out/$w → $dest (${sizes[$w]})"
    printf '%s\n' "$dest"
  done
}
