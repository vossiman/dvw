#!/usr/bin/env bash
# Top-level interactive menu for bare `dvw`.

# Catppuccin Mocha palette — used across banner / picker / chooser chrome.
DVW_ACCENT="#cba6f7"        # mauve (primary accent)
DVW_SUBTLE="#9399b2"        # overlay1 (subdued text)
DVW_GREEN="#a6e3a1"         # green (running)
DVW_RED="#f38ba8"           # red (stopped, when we want emphasis)
DVW_BLUE="#89b4fa"          # blue (vscode-ish)
DVW_TEAL="#94e2d5"          # teal (cursor-ish)
DVW_YELLOW="#f9e2af"        # yellow (ssh)
DVW_PEACH="#fab387"         # peach (jetbrains)

# Memoized list of running workspace ids. Set once via _dvw_load_running_ids
# at first call; reused across the menu, picker, and cmd_status.
#
# `devpod list --output json` does NOT include workspace state (verified
# 2026-05; only id/context/ide/lastUsed/etc.). Per-workspace state lives in
# `devpod status <id> --output json` → `.state`. We parallelize across all
# catalog workspaces so the menu/status path stays fast.
DVW_RUNNING_IDS=""
DVW_RUNNING_LOADED=""

_dvw_load_running_ids() {
  [[ -n "$DVW_RUNNING_LOADED" ]] && return 0
  local ids tmp id
  ids=$(catalog_workspace_ids 2>/dev/null || true)
  if [[ -z "$ids" ]]; then
    DVW_RUNNING_IDS=""
    DVW_RUNNING_LOADED=1
    return 0
  fi
  tmp=$(mktemp -d)
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    {
      local state
      state=$(devpod status "$id" --output json --timeout 5s 2>/dev/null \
        | jq -r '.state // ""' 2>/dev/null)
      [[ "$state" == "Running" ]] && echo "$id" > "$tmp/$id"
    } &
  done <<<"$ids"
  wait
  DVW_RUNNING_IDS=$(cat "$tmp"/* 2>/dev/null | sort -u || true)
  rm -rf "$tmp"
  DVW_RUNNING_LOADED=1
}

# One line per workspace, MRU-sorted, column-aligned, ANSI-colored:
#   <id>  ·  <short-repo>@<branch>  ·  <ide>  ·  ●running | ○stopped
#
# - id           bold mauve
# - · separators dim grey
# - ide          per-ide hue (cursor=teal, ssh=yellow, vscode=blue,
#                 jetbrains=peach, none/other=dim)
# - status       running=green, stopped=dim
#
# Pipeline:
#   1. jq → TSV (plain text, no color)
#   2. column -t pads fields based on plain text width
#   3. sed wraps tokens with ANSI; widths stay correct because ANSI codes
#      don't print as visible characters
# fzf needs --ansi to render the embedded codes (passed in ui_pick_workspace).
_dvw_decorated_workspaces() {
  _dvw_load_running_ids
  local raw
  raw=$(catalog_read 2>/dev/null | jq -r --arg running "$DVW_RUNNING_IDS" '
    ($running | split("\n") | map(select(. != ""))) as $r |
    def shortrepo:
      sub("^git@github\\.com:"; "")
      | sub("^https://github\\.com/"; "")
      | sub("\\.git$"; "");
    .workspaces | sort_by(.last_used_at) | reverse | .[]
    | [
        .id,
        ((.repo | shortrepo) + "@" + .branch),
        .ide,
        (if (.id as $id | $r | index($id)) then "●running" else "○stopped" end)
      ] | @tsv
  ')
  [[ -z "$raw" ]] && return 0

  # ANSI helpers (built once per call).
  local r b d
  r=$(printf '\033[0m')
  b=$(printf '\033[1m')
  d=$(printf '\033[2m')
  local mauve teal yellow blue peach grey green
  mauve=$(printf '\033[38;2;203;166;247m')
  teal=$(printf '\033[38;2;148;226;213m')
  yellow=$(printf '\033[38;2;249;226;175m')
  blue=$(printf '\033[38;2;137;180;250m')
  peach=$(printf '\033[38;2;250;179;135m')
  grey=$(printf '\033[38;2;108;112;134m')
  green=$(printf '\033[38;2;166;227;161m')

  printf '%s\n' "$raw" \
    | column -t -s $'\t' -o '  ·  ' \
    | sed -E "
        s|^([^ ]+)|${b}${mauve}\\1${r}|
        s|●running|${green}●running${r}|g
        s|○stopped|${grey}○stopped${r}|g
        s|(  )(·)(  )(cursor)([ ]+)|\\1${d}\\2${r}\\3${teal}\\4${r}\\5|g
        s|(  )(·)(  )(ssh)([ ]+)|\\1${d}\\2${r}\\3${yellow}\\4${r}\\5|g
        s|(  )(·)(  )(vscode)([ ]+)|\\1${d}\\2${r}\\3${blue}\\4${r}\\5|g
        s|(  )(·)(  )(jetbrains)([ ]+)|\\1${d}\\2${r}\\3${peach}\\4${r}\\5|g
        s|(  )(·)(  )(none)([ ]+)|\\1${d}\\2${r}\\3${grey}\\4${r}\\5|g
        s|  ·  |  ${d}·${r}  |g
      "
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
      --color="border:$DVW_ACCENT,label:$DVW_ACCENT,prompt:$DVW_ACCENT,pointer:$DVW_ACCENT,fg+:$DVW_ACCENT:bold,hl:$DVW_ACCENT,hl+:$DVW_ACCENT:bold,info:$DVW_SUBTLE,gutter:-1,bg+:#313244")
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

  # Banner: a thicker double border with the title bold-mauve and the
  # subtitle in muted overlay grey for visual hierarchy.
  gum join --vertical \
    "$(gum style \
        --border double \
        --padding "0 2" \
        --margin "0 0 0 0" \
        --foreground "$DVW_ACCENT" \
        --border-foreground "$DVW_ACCENT" \
        --bold \
        "dvw — devpod workspaces")" \
    "$(gum style \
        --foreground "$DVW_SUBTLE" \
        --margin "0 0 1 2" \
        "$total total · $running running")"

  local action
  action=$(gum choose \
    --cursor "❯ " \
    --cursor.foreground "$DVW_ACCENT" \
    --selected.foreground "$DVW_ACCENT" \
    --header.foreground "$DVW_SUBTLE" \
    --header "what would you like to do?" \
    "❯ Connect to workspace" \
    "+ Create new workspace" \
    "● Status" \
    "■ Stop a workspace" \
    "▶ Start a workspace" \
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
