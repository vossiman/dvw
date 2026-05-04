#!/usr/bin/env bash
# Top-level interactive menu for bare `dvw`.

# Catppuccin Mocha mauve, used as accent for menu chrome.
DVW_ACCENT="#cba6f7"

# Memoized list of running workspace ids. Set once via _dvw_load_running_ids
# at menu entry; reused by the picker so we don't hit `devpod list` twice.
DVW_RUNNING_IDS=""
DVW_RUNNING_LOADED=""

_dvw_load_running_ids() {
  [[ -n "$DVW_RUNNING_LOADED" ]] && return 0
  DVW_RUNNING_IDS=$(devpod list --output json 2>/dev/null \
    | jq -r '.[] | select(.status == "Running") | .id' 2>/dev/null \
    || true)
  DVW_RUNNING_LOADED=1
}

# One line per workspace, MRU-sorted:
#   <id>  ·  <short-repo>@<branch>  ·  <ide>  ·  ●running | ○stopped
# short-repo strips git@github.com: / https://github.com/ prefix and .git suffix.
_dvw_decorated_workspaces() {
  _dvw_load_running_ids
  catalog_read 2>/dev/null | jq -r --arg running "$DVW_RUNNING_IDS" '
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
      ] | join("  ·  ")
  '
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
      --prompt="$prompt" \
      --height=40% \
      --reverse \
      --header="enter=select  esc=cancel" \
      --color="fg+:$DVW_ACCENT,hl+:$DVW_ACCENT,prompt:$DVW_ACCENT,header:#a6adc8,info:#a6adc8")
  else
    sel=$(printf '%s\n' "$list" | gum filter --placeholder "$prompt")
  fi
  [[ -z "$sel" ]] && return 1
  awk '{print $1}' <<<"$sel"
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

  gum style \
    --border rounded \
    --padding "0 1" \
    --margin "0 0 1 0" \
    --foreground "$DVW_ACCENT" \
    --border-foreground "$DVW_ACCENT" \
    "dvw — devpod workspaces" \
    "$total total · $running running"

  local action
  action=$(gum choose \
    --cursor "❯ " \
    --cursor.foreground "$DVW_ACCENT" \
    --selected.foreground "$DVW_ACCENT" \
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
