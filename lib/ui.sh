#!/usr/bin/env bash
# Top-level interactive menu for bare `dvw`.

# Nord palette — used across banner / picker / chooser chrome.
DVW_ACCENT="#88c0d0"        # frost cyan (primary accent)
DVW_SUBTLE="#616e88"        # polar slate (subdued text)
DVW_GREEN="#a3be8c"         # aurora green (running)
DVW_RED="#bf616a"           # aurora red (stopped, when we want emphasis)
DVW_GREY="#4c566a"          # polar1 (stopped indicator, dim labels)
DVW_BLUE="#81a1c1"          # frost blue (vscode-ish)
DVW_TEAL="#8fbcbb"          # frost teal (cursor-ish)
DVW_YELLOW="#ebcb8b"        # aurora yellow / sand (ssh)
DVW_PEACH="#d08770"         # aurora copper (jetbrains)
DVW_BG_HL="#3b4252"         # polar2 (fzf highlighted-row bg)

# ─── UI helpers ─────────────────────────────────────────────────────────────
# All printers below assume an ANSI-capable terminal (true-color). Used by
# every command surface in commands.sh, connect.sh, wizard.sh, and ssh-sync.sh.

# _ansi <hex> [bold] -> emit '\033[...m' for embedding into format strings.
_ansi() {
  local hex="$1" mod="${2:-}"
  local r=$((16#${hex:1:2})) g=$((16#${hex:3:2})) b=$((16#${hex:5:2}))
  if [[ "$mod" == "bold" ]]; then
    printf '\033[1;38;2;%d;%d;%dm' "$r" "$g" "$b"
  else
    printf '\033[38;2;%d;%d;%dm' "$r" "$g" "$b"
  fi
}
ui_reset() { printf '\033[0m'; }

# ui_banner "Title" ["subtitle"]  — Nord double-border title block.
ui_banner() {
  local title="$1" sub="${2:-}"
  if [[ -n "$sub" ]]; then
    gum join --vertical \
      "$(gum style \
          --border double --padding "0 2" \
          --foreground "$DVW_ACCENT" --border-foreground "$DVW_ACCENT" \
          --bold \
          "$title")" \
      "$(gum style \
          --foreground "$DVW_SUBTLE" --margin "0 0 1 2" \
          "$sub")"
  else
    gum style \
      --border double --padding "0 2" --margin "0 0 1 0" \
      --foreground "$DVW_ACCENT" --border-foreground "$DVW_ACCENT" \
      --bold \
      "$title"
  fi
}

# Colored [OK]/[WARN]/[FAIL] markers. Detail string follows on the same line.
ui_status_ok()   { printf '%s[OK]%s    %s\n' "$(_ansi "$DVW_GREEN"  bold)" "$(ui_reset)" "$1"; }
ui_status_warn() { printf '%s[WARN]%s  %s\n' "$(_ansi "$DVW_YELLOW" bold)" "$(ui_reset)" "$1"; }
ui_status_fail() { printf '%s[FAIL]%s  %s\n' "$(_ansi "$DVW_RED"    bold)" "$(ui_reset)" "$1"; }

# ui_action "verb" "subject"  — short colored line: "▸ verb  subject"
ui_action() {
  local verb="$1" subject="$2"
  printf '%s▸%s %s%s%s %s%s%s\n' \
    "$(_ansi "$DVW_ACCENT")" "$(ui_reset)" \
    "$(_ansi "$DVW_SUBTLE")" "$verb" "$(ui_reset)" \
    "$(_ansi "$DVW_ACCENT" bold)" "$subject" "$(ui_reset)"
}

# ui_info "msg"  — subdued info (prints to stdout). For hints/notes.
ui_info() {
  printf '%s%s%s\n' "$(_ansi "$DVW_SUBTLE")" "$1" "$(ui_reset)"
}

# ui_error "msg"  — red error (prints to stderr).
ui_error() {
  printf '%s✗%s %s%s%s\n' "$(_ansi "$DVW_RED" bold)" "$(ui_reset)" \
    "$(_ansi "$DVW_RED")" "$1" "$(ui_reset)" >&2
}

# ui_progress LABEL CMD [ARGS...]
#
# Run CMD; if it doesn't return within ~0.8s, emit a dim "› LABEL…" hint
# so the user isn't staring at a silent terminal during slow pre-flights
# (rclone-mounted catalog/blueprint stat, ssh blueprint cp, etc).
# Returns CMD's exit code unchanged. Cheap on the happy path: no output
# at all, just one fork+sleep that gets killed before it prints.
ui_progress() {
  local label="$1"; shift
  ( sleep 0.8 && printf '  %s› %s…%s\n' "$(_ansi "$DVW_SUBTLE")" "$label" "$(ui_reset)" >&2 ) &
  local marker_pid=$!
  local rc=0
  "$@" || rc=$?
  # Kill+reap the marker. Both can fail (already exited / SIGTERM'd) and
  # under `set -e` an unguarded nonzero exit (incl. wait's 128+15=143)
  # would tear down the caller — hence the `|| true`s.
  kill "$marker_pid" 2>/dev/null || true
  wait "$marker_pid" 2>/dev/null || true
  return "$rc"
}

# Apply the picker/status row colorization. Reads stdin (already column-aligned),
# writes ANSI-colored to stdout.
_ui_colorize_workspace_row() {
  local r b d
  r=$(printf '\033[0m'); b=$(printf '\033[1m'); d=$(printf '\033[2m')
  local A T Y B2 P GR G R2
  A=$(_ansi  "$DVW_ACCENT")
  T=$(_ansi  "$DVW_TEAL")
  Y=$(_ansi  "$DVW_YELLOW")
  B2=$(_ansi "$DVW_BLUE")
  P=$(_ansi  "$DVW_PEACH")
  GR=$(_ansi "$DVW_GREY")
  G=$(_ansi  "$DVW_GREEN")
  R2=$(_ansi "$DVW_RED" bold)
  sed -E "
    s|^([^ ]+)|${b}${A}\\1${r}|
    s|⚠ stale|${R2}⚠ stale${r}|g
    s|● running|${G}● running${r}|g
    s|○ stopped|${GR}○ stopped${r}|g
    s|(  )(·)(  )(cursor)([ ]+)|\\1${d}\\2${r}\\3${T}\\4${r}\\5|g
    s|(  )(·)(  )(ssh)([ ]+)|\\1${d}\\2${r}\\3${Y}\\4${r}\\5|g
    s|(  )(·)(  )(vscode)([ ]+)|\\1${d}\\2${r}\\3${B2}\\4${r}\\5|g
    s|(  )(·)(  )(jetbrains)([ ]+)|\\1${d}\\2${r}\\3${P}\\4${r}\\5|g
    s|(  )(·)(  )(none)([ ]+)|\\1${d}\\2${r}\\3${GR}\\4${r}\\5|g
    s|(last:[^ ]+)|${d}\\1${r}|g
    s|(on:[^ ]+)|${d}\\1${r}|g
    s|  ·  |  ${d}·${r}  |g
  "
}

# Memoized state classification across every catalog workspace, populated
# by a single parallel pass of `_dvw_workspace_health` (SSH into the
# container, read /proc/self/cwd). One probe per workspace, in parallel,
# done once per dvw invocation.
#
# Two output sets:
#   DVW_RUNNING_IDS - workspaces whose container responds to SSH (alive OR
#                     stale; both mean "the container is up"). Used by the
#                     picker, menu and status row to render the indicator.
#   DVW_STALE_IDS   - subset of running where /workspaces/<id> resolves to
#                     a deleted inode. Cursor's node fatals there; SSH+tmux
#                     still works because bash tolerates a dead cwd.
#
# Why container-peek instead of `devpod status`: devpod status reports the
# docker-level state (Running/Stopped) but doesn't see whether the workspace
# bind mount still resolves. A workspace can be "Running" per devpod yet
# completely broken for users — exactly the failure mode that motivated
# this work. The SSH probe is one layer deeper: it verifies actual
# usability, not just docker bookkeeping.
DVW_RUNNING_IDS=""
DVW_STALE_IDS=""
DVW_RUNNING_LOADED=""
DVW_STALE_LOADED=""

_dvw_load_running_ids() {
  [[ -n "$DVW_RUNNING_LOADED" ]] && return 0
  local ids tmp id
  ids=$(catalog_workspace_ids 2>/dev/null || true)
  if [[ -z "$ids" ]]; then
    DVW_RUNNING_LOADED=1
    DVW_STALE_LOADED=1
    return 0
  fi
  tmp=$(mktemp -d)
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    {
      local state
      state=$(_dvw_workspace_health "$id" 2>/dev/null)
      case "$state" in
        alive) echo "$id" > "$tmp/run.$id" ;;
        stale) echo "$id" > "$tmp/run.$id"; echo "$id" > "$tmp/stale.$id" ;;
      esac
    } &
  done <<<"$ids"
  wait
  DVW_RUNNING_IDS=$(cd "$tmp" && ls run.*   2>/dev/null | sed 's/^run\.//'   | sort -u || true)
  DVW_STALE_IDS=$(  cd "$tmp" && ls stale.* 2>/dev/null | sed 's/^stale\.//' | sort -u || true)
  rm -rf "$tmp"
  DVW_RUNNING_LOADED=1
  DVW_STALE_LOADED=1
}

# Same pass populates DVW_STALE_IDS as a side-effect; this exists so callers
# that care only about staleness still read naturally.
_dvw_load_stale_ids() { _dvw_load_running_ids; }

# One line per workspace, MRU-sorted, column-aligned, ANSI-colored:
#   <id>  ·  <short-repo>@<branch>  ·  <ide>  ·  ●running | ⚠stale | ○stopped
#
# - id           bold frost-cyan accent (DVW_ACCENT)
# - · separators dim
# - ide          per-ide hue (cursor=teal, ssh=yellow, vscode=blue,
#                 jetbrains=peach, none/other=grey)
# - status       running=green, stale=red (running but bind mount is dead —
#                 Cursor will fatal on connect), stopped=grey
#
# Pipeline:
#   1. jq → TSV (plain text, no color)
#   2. column -t pads fields based on plain text width
#   3. sed wraps tokens with ANSI; widths stay correct because ANSI codes
#      don't print as visible characters
# fzf needs --ansi to render the embedded codes (passed in ui_pick_workspace).
_dvw_decorated_workspaces() {
  _dvw_load_running_ids
  _dvw_load_stale_ids
  local raw
  raw=$(catalog_read 2>/dev/null \
    | jq -r --arg running "$DVW_RUNNING_IDS" --arg stale "$DVW_STALE_IDS" '
    ($running | split("\n") | map(select(. != ""))) as $r |
    ($stale   | split("\n") | map(select(. != ""))) as $s |
    def shortrepo:
      sub("^git@github\\.com:"; "")
      | sub("^https://github\\.com/"; "")
      | sub("\\.git$"; "");
    .workspaces | sort_by(.last_used_at) | reverse | .[]
    | [
        .id,
        ((.repo | shortrepo) + "@" + .branch),
        .ide,
        (.id as $id
         | if   ($s | index($id)) then "⚠ stale"
           elif ($r | index($id)) then "● running"
           else                        "○ stopped" end)
      ] | @tsv
  ')
  [[ -z "$raw" ]] && return 0
  printf '%s\n' "$raw" \
    | column -t -s $'\t' -o '  ·  ' \
    | _ui_colorize_workspace_row
}

# Pick a workspace via fzf (preferred) or gum filter. Returns the id only.
ui_pick_workspace() {
  local prompt="${1:-workspace> }"
  local list
  list=$(_dvw_decorated_workspaces)
  if [[ -z "$list" ]]; then
    echo "no workspaces in catalog" >&2
    return 1
  fi
  local sel
  if command -v fzf >/dev/null; then
    sel=$(printf '%s\n' "$list" | fzf \
      --ansi \
      --prompt="$prompt" \
      --height=45% \
      --reverse \
      --border=rounded \
      --border-label=" ❯ pick a workspace " \
      --border-label-pos=3 \
      --padding=0,1 \
      --pointer="❯" \
      --info=inline-right \
      --color="border:$DVW_ACCENT,label:$DVW_ACCENT,prompt:$DVW_ACCENT,pointer:$DVW_ACCENT,fg+:$DVW_ACCENT:bold,hl:$DVW_ACCENT,hl+:$DVW_ACCENT:bold,info:$DVW_SUBTLE,gutter:-1,bg+:$DVW_BG_HL")
  else
    sel=$(printf '%s\n' "$list" | gum filter --placeholder "$prompt")
  fi
  [[ -z "$sel" ]] && return 1
  # The id is the first whitespace-delimited token. ANSI codes are stripped
  # by awk's default whitespace splitting since they're inside the token.
  # Use sed to strip ANSI first, then awk extracts the bare id.
  sed 's/\x1b\[[0-9;]*m//g' <<<"$sel" | awk '{print $1}'
}

ui_top_menu() {
  command -v gum >/dev/null || {
    echo "gum required for menu; either install gum or invoke a subcommand directly" >&2
    return 1
  }

  _dvw_load_running_ids
  local total running
  total=$(catalog_read 2>/dev/null | jq -r '.workspaces | length' 2>/dev/null || echo 0)
  running=$(printf '%s\n' "$DVW_RUNNING_IDS" | grep -c . || true)

  ui_banner "dvw — devpod workspaces" "$total total · $running running"

  local action
  action=$(gum choose \
    --cursor "❯ " \
    --cursor.foreground "$DVW_ACCENT" \
    --selected.foreground "$DVW_ACCENT" \
    --header.foreground "$DVW_SUBTLE" \
    --header "what would you like to do?" \
    "❯ Connect to workspace" \
    "+ Create new workspace" \
    "⊞ Install blueprint into a workspace" \
    "● Status" \
    "■ Stop a workspace" \
    "▶ Start a workspace" \
    "↻ Recreate a workspace" \
    "✕ Remove a workspace" \
    "⚕ Doctor")

  case "$action" in
    *"Connect to workspace")
      local ws; ws=$(ui_pick_workspace "connect> ") || return 1
      cmd_connect "$ws"
      ;;
    *"Create new workspace")
      cmd_new
      ;;
    *"Install blueprint into a workspace")
      cmd_blueprint
      ;;
    *"Status")
      cmd_status
      ;;
    *"Stop a workspace")
      local ws; ws=$(ui_pick_workspace "stop> ") || return 1
      cmd_stop "$ws"
      ;;
    *"Start a workspace")
      local ws; ws=$(ui_pick_workspace "start> ") || return 1
      cmd_start "$ws"
      ;;
    *"Recreate a workspace")
      local ws; ws=$(ui_pick_workspace "recreate> ") || return 1
      cmd_recreate "$ws"
      ;;
    *"Remove a workspace")
      local ws; ws=$(ui_pick_workspace "remove> ") || return 1
      cmd_rm "$ws"
      ;;
    *"Doctor")
      cmd_doctor
      ;;
    *)
      return 1
      ;;
  esac
}
