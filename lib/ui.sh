#!/usr/bin/env bash
# Top-level interactive menu for bare `dvw`.

# Catppuccin Mocha mauve, used as accent for menu chrome.
DVW_ACCENT="#cba6f7"

_dvw_running_ids() {
  devpod list --output json 2>/dev/null \
    | jq -r '.[] | select(.status == "Running") | .id' 2>/dev/null \
    || true
}

# One line per workspace, MRU-sorted:
#   <id>  ·  <repo>@<branch>  ·  <ide>  ·  ●running | ○stopped
_dvw_decorated_workspaces() {
  local running
  running=$(_dvw_running_ids)
  catalog_read 2>/dev/null | jq -r --arg running "$running" '
    ($running | split("\n") | map(select(. != ""))) as $r |
    .workspaces | sort_by(.last_used_at) | reverse | .[]
    | [
        .id,
        (.repo + "@" + .branch),
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
      --header="enter=select  esc=cancel")
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

  local total running
  total=$(catalog_read 2>/dev/null | jq -r '.workspaces | length' 2>/dev/null || echo 0)
  running=$(_dvw_running_ids | grep -c . || true)

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
