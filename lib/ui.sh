#!/usr/bin/env bash
# Top-level interactive menu for bare `dvw`.

# Pick a workspace via fzf (preferred) or gum filter, fallback to gum choose.
ui_pick_workspace() {
  local prompt="${1:-workspace> }"
  local ids
  ids=$(catalog_workspace_ids)
  if [[ -z "$ids" ]]; then
    echo "no workspaces in catalog" >&2
    return 1
  fi
  if command -v fzf >/dev/null; then
    printf '%s\n' "$ids" | fzf --prompt="$prompt" --height=30% --reverse
  else
    printf '%s\n' "$ids" | gum filter --placeholder "$prompt"
  fi
}

ui_top_menu() {
  command -v gum >/dev/null || {
    echo "gum required for menu; either install gum or invoke a subcommand directly" >&2
    return 1
  }
  local action
  action=$(gum choose \
    "Connect to workspace" \
    "Create new workspace" \
    "Status" \
    "Stop a workspace" \
    "Start a workspace" \
    "Remove a workspace" \
    "Doctor")
  case "$action" in
    "Connect to workspace")
      local ws; ws=$(ui_pick_workspace "connect> ") || return 1
      cmd_connect "$ws"
      ;;
    "Create new workspace")
      cmd_new
      ;;
    "Status")
      cmd_status
      ;;
    "Stop a workspace")
      local ws; ws=$(ui_pick_workspace "stop> ") || return 1
      cmd_stop "$ws"
      ;;
    "Start a workspace")
      local ws; ws=$(ui_pick_workspace "start> ") || return 1
      cmd_start "$ws"
      ;;
    "Remove a workspace")
      local ws; ws=$(ui_pick_workspace "remove> ") || return 1
      cmd_rm "$ws"
      ;;
    "Doctor")
      cmd_doctor
      ;;
    *)
      return 1
      ;;
  esac
}
