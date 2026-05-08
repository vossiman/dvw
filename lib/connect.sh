#!/usr/bin/env bash
# Connect to a workspace via SSH (terminal + tmux session) or Cursor (GUI).
#
# Multi-machine model: the catalog (Dropbox-shared) carries each workspace's
# devpod `workspace.json` snapshot; on a fresh machine, the synthesizer below
# materializes the local devpod state from that snapshot — without ever
# running `devpod up <repo>@<branch> --id <id>`, which provisions a brand-new
# workspace and would clobber the existing remote state.

cmd_connect() {
  local ws="$1"
  shift || true
  if [[ -z "$ws" ]]; then
    ui_error "cmd_connect: workspace ID required"
    return 1
  fi

  # Optional flags to skip the chooser for non-interactive use:
  #   dvw <id> --ssh     — go straight to ssh+tmux
  #   dvw <id> --cursor  — go straight to Cursor (devpod up --ide cursor)
  #   dvw <id> --both    — Cursor first, then exec into ssh+tmux
  local forced_mode=""
  case "${1:-}" in
    --ssh)    forced_mode="ssh" ;;
    --cursor) forced_mode="cursor" ;;
    --both)   forced_mode="both" ;;
    "")       : ;;
    *) ui_error "unknown flag: $1 (expected --ssh, --cursor, or --both)"; return 1 ;;
  esac

  # Catalog's ide field is the default highlighted option; user can override.
  local default_ide="ssh" ws_json
  if ws_json=$(catalog_workspace_get "$ws" 2>/dev/null); then
    default_ide=$(echo "$ws_json" | jq -r '.ide // "ssh"')
  fi

  # Materialize devpod local state from the catalog snapshot if missing,
  # then reconcile any uid drift against the remote provider. Both are no-ops
  # on the happy path. If neither succeeds we bail before touching devpod.
  _dvw_ensure_local_devpod_state "$ws" || return 1
  _dvw_reconcile_uid "$ws" || return 1
  _dvw_reap_stale_masters "$ws"

  local mode="$forced_mode"
  if [[ -z "$mode" ]]; then
    mode=$(_connect_choose_mode "$ws" "$default_ide")
    [[ -z "$mode" ]] && return 1
  fi

  case "$mode" in
    ssh)    _connect_ssh "$ws" ;;
    cursor) _connect_cursor "$ws" ;;
    both)   _connect_cursor "$ws" && _connect_ssh "$ws" ;;
    *)      ui_error "unknown connect mode: $mode"; return 1 ;;
  esac
}

# Prompt SSH vs Cursor vs Both with the catalog's saved IDE pre-selected.
# Echoes "ssh", "cursor", or "both" on stdout; empty on cancel.
_connect_choose_mode() {
  local ws="$1" default_ide="$2"
  if ! command -v gum >/dev/null; then
    echo "ssh"
    return 0
  fi
  local ssh_label="SSH (terminal + tmux)"
  local cursor_label="Cursor (GUI)"
  local both_label="Both (Cursor + SSH/tmux)"
  local selected="$ssh_label"
  [[ "$default_ide" == "cursor" ]] && selected="$cursor_label"

  local choice
  choice=$(gum choose \
    --header="connect to $ws via" \
    --selected="$selected" \
    --cursor "❯ " \
    --cursor.foreground "$DVW_ACCENT" \
    --selected.foreground "$DVW_ACCENT" \
    "$ssh_label" "$cursor_label" "$both_label")

  case "$choice" in
    "$ssh_label")    echo "ssh" ;;
    "$cursor_label") echo "cursor" ;;
    "$both_label")   echo "both" ;;
    *)               echo "" ;;
  esac
}

# SSH path: probe-up if needed, then ssh -t into a tmux `work` session.
_connect_ssh() {
  local ws="$1"
  if ! ssh -o ConnectTimeout=3 -o BatchMode=yes "${ws}.devpod" true 2>/dev/null; then
    ui_action "starting" "$ws (ide=none)"
    _dvw_safe_devpod_up "$ws" --ide none || { ui_error "devpod up failed for $ws"; return 1; }
    catalog_workspace_set_devpod_state "$ws" 2>/dev/null || true
  fi
  catalog_workspace_touch "$ws" 2>/dev/null || true
  # Single ssh call: probe tmux inside the same login shell that will host
  # the session, so we don't pay for two TCP+auth+`bash -l` round-trips.
  exec ssh -t "${ws}.devpod" '
    infocmp -1 "$TERM" >/dev/null 2>&1 || export TERM=xterm-256color
    if command -v tmux >/dev/null 2>&1; then
      exec bash -lc "tmux new -A -s work"
    fi
    echo "tmux not found in this workspace. Falling back to plain bash (no resume)." >&2
    echo "To bootstrap the full toolchain inside the workspace:" >&2
    echo "  git clone https://github.com/vossiman/aiCodingBaseSetup /tmp/aicoding && bash /tmp/aicoding/install.sh" >&2
    exec bash -l
  '
}

# Cursor path: probe before calling `devpod up`.
#
# `devpod up --ide cursor` on a workspace whose container is already running
# can re-synthesize the agent-side workspace dir (rm -rf content/, sparse
# re-clone of just .devcontainer/) without recreating the container itself.
# The container's bind mount keeps pointing at the *old* content/ inode,
# which is now an unlinked zombie kept alive only by the mount. Anything
# that calls getcwd(2) inside that workspace path then fails with ENOENT —
# Cursor's node server fatals on boot, while bash tolerates the dead cwd
# (which is why --ssh kept working). It also nukes uncommitted source.
#
# So: only run `devpod up` when the workspace truly isn't reachable. The
# WSL→Windows bridge in win-ssh-proxy.sh routes Cursor through devpod ssh
# --stdio directly, so a healthy running workspace doesn't need devpod CLI
# involvement to be openable in Cursor.
_connect_cursor() {
  local ws="$1"
  catalog_workspace_touch "$ws" 2>/dev/null || true

  case "$(_dvw_workspace_health "$ws")" in
    alive)
      ui_action "opening" "$ws in Cursor"
      _dvw_cursor_open "$ws" || return 1
      catalog_workspace_set_devpod_state "$ws" 2>/dev/null || true
      ;;
    stale)
      ui_error "$ws has a stale workspace bind mount (kernel reports cwd as deleted)"
      ui_info "  this happens when devpod up re-synthesized agent-side content/"
      ui_info "  while the container kept running on the old inode. Recover with:"
      ui_info "    dvw recreate $ws"
      return 1
      ;;
    cold|*)
      ui_action "starting" "$ws in Cursor"
      if ! _dvw_safe_devpod_up "$ws" --ide cursor; then
        ui_error "devpod up --ide cursor failed for $ws"
        return 1
      fi
      catalog_workspace_set_devpod_state "$ws" 2>/dev/null || true
      ;;
  esac
}

# Launch Cursor pointed at <ws>.devpod:/workspaces/<ws>. The *.devpod ssh
# bridge in win-ssh-proxy.sh handles connection routing, so we just need a
# binary to invoke and a vscode-remote URI to open. Order of detection:
#
#   1. ~/.local/bin/cursor  - Linux AppImage shim (cursor-shim.sh)
#   2. `cursor` on PATH     - distro / direct install
#   3. `cursor.exe` on PATH - WSL interop with Windows PATH propagated
#   4. /mnt/c/Users/$USER/AppData/Local/Programs/{cursor,Cursor}/{cursor,Cursor}.exe
#                           - canonical Windows install reachable from WSL
#
# Detaches the process so dvw returns immediately. stdout/stderr go to
# /dev/null because the GUI binary spams startup chatter.
_dvw_cursor_open() {
  local ws="$1"
  local uri="vscode-remote://ssh-remote+${ws}.devpod/workspaces/${ws}"
  local bin
  for bin in \
      "$HOME/.local/bin/cursor" \
      cursor \
      cursor.exe \
      "/mnt/c/Users/${USER}/AppData/Local/Programs/cursor/cursor.exe" \
      "/mnt/c/Users/${USER}/AppData/Local/Programs/Cursor/Cursor.exe"
  do
    if [[ -x "$bin" ]] || command -v "$bin" >/dev/null 2>&1; then
      ( "$bin" --folder-uri "$uri" >/dev/null 2>&1 & disown ) 2>/dev/null
      return 0
    fi
  done
  ui_error "no cursor binary found"
  ui_info "  tried: ~/.local/bin/cursor, cursor, cursor.exe,"
  ui_info "         /mnt/c/Users/$USER/AppData/Local/Programs/cursor/cursor.exe"
  ui_info "  open manually: cursor --folder-uri \"$uri\""
  return 1
}

# Probe the workspace's SSH endpoint and the bind mount's liveness. Echoes:
#   alive — cd /workspaces/<id> succeeds and /proc/self/cwd is a live inode
#   stale — cd succeeds but the kernel marks cwd "(deleted)"; the bind mount
#           points at an unlinked inode and Cursor's node will fatal on it.
#           Caller should refuse and direct the user to `dvw recreate`.
#   cold  — SSH or `cd` failed; workspace likely stopped or never created.
#           Caller should fall back to `devpod up`.
_dvw_workspace_health() {
  local ws="$1" rc
  ssh -o ConnectTimeout=3 -o BatchMode=yes "${ws}.devpod" "
    cd /workspaces/$ws 2>/dev/null || exit 2
    cwd=\$(readlink /proc/self/cwd 2>/dev/null)
    [[ \"\$cwd\" == *'(deleted)'* ]] && exit 1
    exit 0
  " 2>/dev/null
  rc=$?
  case "$rc" in
    0) echo alive ;;
    1) echo stale ;;
    *) echo cold  ;;
  esac
}

# Returns 0 if a container labelled with this workspace's uid exists on
# the workspace's provider host (regardless of whether it's running),
# non-zero otherwise. Used to detect the "our local SSH probe said cold
# but the container actually exists" case before blindly running
# `devpod up` against it.
#
# Devpod doesn't tag containers with `devpod.workspaceUID` — the durable
# identifier is the devcontainer feature label `dev.containers.id`, which
# equals workspace.uid (verified 2026-05). The CLI-side workspace.json is
# often near-empty after a recreate; `devpod list --output json` is the
# authoritative local source for both uid and provider HOST.
#
# Costs one local devpod CLI call + one SSH round-trip to the provider
# host (ConnectTimeout=5s).
_dvw_provider_has_container() {
  local id="$1" host uid info
  info=$(devpod list --output json 2>/dev/null \
    | jq -c --arg id "$id" '.[] | select(.id == $id)')
  [[ -n "$info" ]] || return 1
  uid=$(jq  -r '.uid // empty'                          <<<"$info" 2>/dev/null)
  host=$(jq -r '.provider.options.HOST.value // empty'  <<<"$info" 2>/dev/null)
  [[ -n "$host" && -n "$uid" ]] || return 1
  ssh -o ConnectTimeout=5 -o BatchMode=yes "$host" \
    "docker ps -a --filter label=dev.containers.id=$uid -q 2>/dev/null | head -1 | grep -q ." \
    >/dev/null 2>&1
}

# Wrapper for `devpod up <id> [args...]` with a safety check.
#
# The failure mode this guards against: our local SSH probe (`ssh
# ${id}.devpod true`) returned non-zero, so a caller concluded the
# workspace is stopped and is about to run `devpod up` to start it. But
# that probe can fail for non-container reasons — transient network, sshd
# restart, the agent host being briefly unresponsive — and `devpod up`
# against a container that's actually running is precisely the call that
# re-synthesizes content/ on the agent and leaves the container with a
# stale bind mount. Lost work.
#
# So before each `devpod up`, ask the provider host directly: do you have
# a container for this workspace? If yes, refuse without explicit
# confirmation. cmd_recreate doesn't go through this — recreate is
# destructive by design and the user typed it on purpose.
_dvw_safe_devpod_up() {
  local id="$1"
  shift
  if _dvw_provider_has_container "$id"; then
    ui_status_warn "$id is unreachable via SSH but a container exists on its provider"
    ui_info "  running \`devpod up\` against an already-running container can wipe"
    ui_info "  content/ and leave the bind mount on a deleted inode (lost source)."
    ui_info "  recover: fix the network to the agent, or \`dvw recreate $id\`."
    if [[ -t 0 ]] && command -v gum >/dev/null; then
      gum confirm "run \`devpod up $id $*\` anyway?" || { ui_info "aborted"; return 1; }
    else
      ui_error "refusing to run \`devpod up\` non-interactively without confirmation"
      return 1
    fi
  fi
  devpod up "$id" "$@"
}

# ----------------------------------------------------------------------------
# Multi-machine sync helpers
#
# These bridge the catalog (Dropbox, shared) and devpod's per-machine state
# (~/.devpod/contexts/<ctx>/workspaces/<id>/workspace.json). The catalog stores
# a verbatim snapshot of workspace.json plus a top-level `uid` field.
# ----------------------------------------------------------------------------

# Materialize ~/.devpod/.../workspaces/<id>/workspace.json on this machine
# from the catalog snapshot, if it doesn't already exist locally. No-op if
# the local file is already present. Returns 1 if neither exists.
_dvw_ensure_local_devpod_state() {
  local id="$1" path snapshot
  path=$(catalog_devpod_workspace_json_path "$id")
  if [[ -f "$path" ]]; then
    return 0
  fi
  if ! snapshot=$(catalog_workspace_get_devpod_state "$id" 2>/dev/null); then
    ui_error "\"$id\" is not registered on this machine and the catalog has no devpod_state snapshot"
    ui_info "(legacy catalog entry from before multi-machine sync — \`dvw rm $id\` then \`dvw new\` to migrate)"
    return 1
  fi
  mkdir -p "$(dirname "$path")"
  local tmp="$path.tmp"
  if ! printf '%s' "$snapshot" | jq -c . > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    ui_error "could not write synthesized workspace.json for \"$id\""
    return 1
  fi
  mv "$tmp" "$path"
  ui_status_ok "registered \"$id\" locally from catalog snapshot"
}

# Detect uid drift (local vs catalog vs remote provider) and rewrite the
# losers to match the elected uid. Best-effort — if SSH to provider fails
# we proceed without reconciling.
_dvw_reconcile_uid() {
  local id="$1" path local_uid cat_uid
  path=$(catalog_devpod_workspace_json_path "$id")
  [[ -f "$path" ]] || return 0
  local_uid=$(jq -r '.workspace.uid // empty' "$path" 2>/dev/null)
  cat_uid=$(catalog_workspace_get_uid "$id" 2>/dev/null)

  # Happy path: catalog hasn't recorded a uid yet (legacy or pre-snapshot
  # creation) → reverse-sync after the next successful connect will fill it.
  # Or local and catalog already agree → nothing to do.
  if [[ -z "$cat_uid" ]] || [[ "$local_uid" == "$cat_uid" ]]; then
    return 0
  fi

  local host
  host=$(jq -r '.workspace.provider.options.HOST.value // empty' "$path" 2>/dev/null)
  if [[ -z "$host" ]]; then
    ui_status_warn "uid drift: local=$local_uid catalog=$cat_uid (no provider HOST in workspace.json — skipping reconcile)"
    return 0
  fi

  ui_action "probing" "$host for live uid (local=$local_uid catalog=$cat_uid)"
  local probe
  if ! probe=$(_dvw_probe_remote_uid "$host" "$id" 2>/dev/null); then
    ui_status_warn "could not probe $host; skipping reconcile (will use local uid=$local_uid)"
    return 0
  fi

  local remote_uid
  remote_uid=$(echo "$probe" | jq -r '.remote_uid // empty')
  local has_content
  has_content=$(echo "$probe" | jq -r '.has_content // false')
  local volumes
  volumes=$(echo "$probe" | jq -r '.volumes[]? // empty')

  # Score each candidate: +1 per signal of "live" state.
  local winner="" winner_score=-1
  local cand
  for cand in "$remote_uid" "$local_uid" "$cat_uid"; do
    [[ -z "$cand" ]] && continue
    local score=0
    [[ "$cand" == "$remote_uid" ]] && score=$((score+1))
    grep -qx "dind-var-lib-docker-$cand" <<<"$volumes" && score=$((score+1))
    [[ "$cand" == "$remote_uid" && "$has_content" == "true" ]] && score=$((score+1))
    if (( score > winner_score )); then
      winner="$cand"
      winner_score=$score
    fi
  done

  if [[ -z "$winner" ]] || (( winner_score == 0 )); then
    ui_error "neither uid resolves to live state on $host — workspace lost"
    ui_info "(\`dvw rm $id\` then \`dvw new\` to recreate)"
    return 1
  fi

  if [[ "$winner" == "$local_uid" ]] && [[ "$winner" == "$cat_uid" ]]; then
    return 0
  fi

  local updated=()
  if [[ "$local_uid" != "$winner" ]]; then
    _dvw_rewrite_local_uid "$id" "$winner" || return 1
    updated+=("local")
  fi
  if [[ "$cat_uid" != "$winner" ]]; then
    catalog_workspace_set_devpod_state "$id" >/dev/null 2>&1 || {
      ui_status_warn "could not push uid=$winner to catalog (will retry after next connect)"
    }
    updated+=("catalog")
  fi
  if [[ -n "$remote_uid" ]] && [[ "$remote_uid" != "$winner" ]]; then
    ui_status_warn "remote workspace.json on $host still has uid=$remote_uid (not auto-rewritten — fix manually if needed)"
  fi

  ui_status_ok "uid drift resolved: local=$local_uid catalog=$cat_uid remote=$remote_uid → elected=$winner (updated: ${updated[*]:-none})"
}

# Single SSH round-trip to the provider host. Returns JSON with remote_uid,
# has_content, volumes (array of dind volume names with the devpod prefix).
_dvw_probe_remote_uid() {
  local host="$1" id="$2"
  ssh -o ConnectTimeout=5 -o BatchMode=yes "$host" "
    set +e
    ws_dir=\$HOME/.devpod/agent/contexts/default/workspaces/$id
    remote_uid=\$(jq -r '.workspace.uid // empty' \"\$ws_dir/workspace.json\" 2>/dev/null)
    has_content=false
    [[ -d \"\$ws_dir/content\" ]] && has_content=true
    vols=\$(docker volume ls --format '{{.Name}}' 2>/dev/null | grep '^dind-var-lib-docker-' || true)
    jq -cn --arg uid \"\$remote_uid\" --arg hc \"\$has_content\" --arg vols \"\$vols\" '
      { remote_uid: \$uid,
        has_content: (\$hc == \"true\"),
        volumes: (\$vols | split(\"\n\") | map(select(. != \"\"))) }'
  "
}

# Tear down a stale SSH ControlMaster whose remote TCP connection is dead.
# End-to-end probe through the multiplex socket with a tight outer timeout;
# if it doesn't return, `ssh -O exit` and rm the socket so the next ssh has
# to reauthenticate instead of blocking on a long kernel TCP timeout.
#
# Triggered by `dvw start`/`dvw recreate`/connect when the previous network
# (e.g. WireGuard) has gone away while a multiplex master was still cached.
# Cheap and idempotent — returns 0 if no socket exists or the master is
# healthy.
ssh_reap_stale_master() {
  local host="$1" cp
  # awk's `exit` after the first match makes ssh -G SIGPIPE on continued
  # writes, which `set -o pipefail` propagates. Guard with `|| true` so
  # the assignment doesn't tear the script down on a benign pipe close.
  cp=$(ssh -G "$host" 2>/dev/null | awk '$1=="controlpath"{print $2; exit}' || true)
  [[ -z "$cp" || "$cp" == "none" ]] && return 0
  [[ -S "$cp" ]] || return 0
  if timeout 3 ssh -o BatchMode=yes -o ConnectTimeout=2 "$host" true 2>/dev/null; then
    return 0
  fi
  ui_status_warn "stale ssh master to $host — clearing (route likely changed)"
  timeout 2 ssh -O exit "$host" >/dev/null 2>&1 || true
  rm -f "$cp" 2>/dev/null || true
  return 0
}

# Reap stale SSH masters for both `<id>.devpod` (used by dvw connect) and
# the workspace's provider HOST (used by `devpod up`). Read by all paths
# that may shell out to devpod or ssh.
_dvw_reap_stale_masters() {
  local id="$1" path host
  ssh_reap_stale_master "${id}.devpod"
  path=$(catalog_devpod_workspace_json_path "$id")
  if [[ -f "$path" ]]; then
    host=$(jq -r '.workspace.provider.options.HOST.value // empty' "$path" 2>/dev/null)
    [[ -n "$host" ]] && ssh_reap_stale_master "$host"
  fi
  return 0
}

# Rewrite .workspace.uid in the local workspace.json atomically.
_dvw_rewrite_local_uid() {
  local id="$1" new_uid="$2" path tmp
  path=$(catalog_devpod_workspace_json_path "$id")
  tmp="$path.tmp"
  if ! jq --arg uid "$new_uid" '.workspace.uid = $uid' "$path" > "$tmp"; then
    rm -f "$tmp"
    ui_error "failed to rewrite local workspace.json uid for \"$id\""
    return 1
  fi
  mv "$tmp" "$path"
}
