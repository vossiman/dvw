#!/usr/bin/env bash
# Connect to a workspace via SSH (terminal + tmux session) or Cursor (GUI).
#
# Multi-machine model: the catalog (served by the catalog service) carries each workspace's
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
  # then resolve which container is canonical by direct observation of the
  # provider (tmux-bearing container wins). Both are no-ops on the happy path.
  _dvw_ensure_local_devpod_state "$ws" || return 1
  _dvw_ensure_ssh_alias "$ws" || return 1
  _dvw_resolve_canonical_container "$ws" || return 1
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
#
# Cold-branch policy (container-safety invariant): if the alias probe fails
# but a container exists on the provider, treat it as alive and `exec ssh`
# directly. NEVER run `devpod up` against a confirmed-existing container
# from this code path — that's the wipe footgun. The actual `exec ssh -t`
# below uses default (long) ssh timeouts and no BatchMode, so it retries
# on its own where the 5s BatchMode probe gave up.
_connect_ssh() {
  local ws="$1"
  if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "${ws}.devpod" true 2>/dev/null; then
    if ! _dvw_alias_defined "$ws"; then
      ui_status_warn "$ws: ssh alias not registered on this machine — registering now"
      _dvw_ensure_ssh_alias "$ws" || { ui_error "could not register ssh alias for $ws"; return 1; }
    elif _dvw_provider_has_container "$ws"; then
      ui_status_ok "$ws: container is running (alias probe was slow); opening ssh directly"
    else
      ui_action "starting" "$ws (ide=none)"
      _dvw_safe_devpod_up "$ws" --ide none || { ui_error "devpod up failed for $ws"; return 1; }
      catalog_workspace_set_devpod_state "$ws" 2>/dev/null || true
    fi
  fi
  catalog_workspace_touch "$ws" 2>/dev/null || true
  # Single ssh call: probe tmux inside the same login shell that will host
  # the session, so we don't pay for two TCP+auth+`bash -l` round-trips.
  # tmux exclusivity: `-A -D` together mean "create if missing, otherwise
  # attach with -d (detach any other client of this session)". Last attach
  # wins; the session itself keeps running across viewer changes. Plain
  # `docker exec` shells (Cursor remote-ssh, non-tmux ssh) are unaffected —
  # exclusivity is scoped to the tmux path only.
  exec ssh -t "${ws}.devpod" '
    infocmp -1 "$TERM" >/dev/null 2>&1 || export TERM=xterm-256color
    if command -v tmux >/dev/null 2>&1; then
      exec bash -lc "tmux new -A -D -s work"
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
      # Cold-branch policy (container-safety invariant): if the alias probe
      # failed but a container exists on the provider, treat as alive and
      # let Cursor open via its own ssh-remote (which has its own retry/
      # timeout). NEVER `devpod up` against a confirmed-existing container.
      # Only fall through to the wrapper (which still has its own fresh
      # safety check) when no container exists.
      if ! _dvw_alias_defined "$ws"; then
        ui_status_warn "$ws: ssh alias not registered on this machine — registering now"
        _dvw_ensure_ssh_alias "$ws" || { ui_error "could not register ssh alias for $ws"; return 1; }
        _dvw_cursor_open "$ws" || return 1
        catalog_workspace_set_devpod_state "$ws" 2>/dev/null || true
      elif _dvw_provider_has_container "$ws"; then
        ui_status_ok "$ws: container is running (alias probe was slow); opening Cursor directly"
        _dvw_cursor_open "$ws" || return 1
        catalog_workspace_set_devpod_state "$ws" 2>/dev/null || true
      else
        ui_action "starting" "$ws in Cursor"
        if ! _dvw_safe_devpod_up "$ws" --ide cursor; then
          ui_error "devpod up --ide cursor failed for $ws"
          return 1
        fi
        catalog_workspace_set_devpod_state "$ws" 2>/dev/null || true
      fi
      ;;
  esac
}

# Launch Cursor pointed at <ws>.devpod:/workspaces/<ws>. The *.devpod ssh
# bridge in win-ssh-proxy.sh handles connection routing, so we just need
# a working CLI binary and the right URI.
#
# Args mirror what devpod itself runs (pkg/ide/vscode/open.go,
# `openViaCLI`):
#   cursor --reuse-window --folder-uri=vscode-remote://ssh-remote+<ws>.devpod/<folder>
#
# Two non-obvious requirements:
#   - The `=` between `--folder-uri` and the value is required (devpod's
#     own comment: "Needs to be separated by `=` because of windows").
#     Space-separated form silently no-ops on the Windows binary.
#   - The CLI is the WSL-aware *shell wrapper* at
#     resources/app/bin/cursor, NOT the Electron GUI Cursor.exe. The
#     wrapper translates paths/env between WSL and Windows; calling
#     Cursor.exe directly with --folder-uri doesn't run the CLI
#     bootstrap that hands off the URI to a running window. VS Code
#     follows the same pattern with `code` vs `Code.exe`.
#
# Detection order:
#   1. ~/.local/bin/cursor  - Linux AppImage shim (cursor-shim.sh)
#   2. `cursor` on PATH     - native install / user-managed shim
#   3. WSL→Windows install of Cursor's bin/cursor wrapper:
#        /mnt/c/Users/$USER/AppData/Local/Programs/{cursor,Cursor}/resources/app/bin/cursor
#
# Detaches and silences the launched process so dvw returns immediately.
_dvw_cursor_open() {
  local ws="$1"
  local folder="workspaces/${ws}"
  local uri_arg="--folder-uri=vscode-remote://ssh-remote+${ws}.devpod/${folder}"
  local bin
  for bin in \
      "$HOME/.local/bin/cursor" \
      cursor \
      "/mnt/c/Users/${USER}/AppData/Local/Programs/cursor/resources/app/bin/cursor" \
      "/mnt/c/Users/${USER}/AppData/Local/Programs/Cursor/resources/app/bin/cursor"
  do
    if [[ -x "$bin" ]] || command -v "$bin" >/dev/null 2>&1; then
      ( "$bin" --new-window "$uri_arg" >/dev/null 2>&1 & disown ) 2>/dev/null
      return 0
    fi
  done
  ui_error "no cursor CLI found"
  ui_info "  tried: ~/.local/bin/cursor, \`cursor\` on PATH,"
  ui_info "         /mnt/c/Users/$USER/AppData/Local/Programs/{cursor,Cursor}/resources/app/bin/cursor"
  ui_info "  open manually: cursor --new-window \"$uri_arg\""
  return 1
}

# Probe the workspace's SSH endpoint and the bind mount's liveness. Echoes:
#   alive — cd /workspaces/<id> succeeds and /proc/self/cwd is a live inode
#   stale — cd succeeds but the kernel marks cwd "(deleted)"; the bind mount
#           points at an unlinked inode and Cursor's node will fatal on it.
#           Caller should refuse and direct the user to `dvw recreate`.
#   cold  — SSH or `cd` failed; workspace likely stopped or never created.
#           Caller should fall back to `devpod up`.
#
# Stderr from the ssh call is captured into DVW_LAST_WS_HEALTH_ERR so callers
# can distinguish "container is down" from "this machine can't reach the
# workspace alias" (auth failure, no route, host unknown, etc.). The cross-
# workspace status path uses the provider-first probe (_dvw_load_probe); this
# function remains as the connect-time double-check that also catches the
# stale-bind-mount marker after the provider says alive.
DVW_LAST_WS_HEALTH_ERR=""
_dvw_workspace_health() {
  local ws="$1" rc=0 err_file err
  err_file=$(mktemp)
  # `|| rc=$?` keeps set -e from aborting on ssh failure when called from
  # non-cmd-sub contexts. Without it, a direct `_dvw_workspace_health $id`
  # under set -e dies before we can return "cold".
  ssh -o ConnectTimeout=5 -o BatchMode=yes "${ws}.devpod" "
    cd /workspaces/$ws 2>/dev/null || exit 2
    cwd=\$(readlink /proc/self/cwd 2>/dev/null)
    [[ \"\$cwd\" == *'(deleted)'* ]] && exit 1
    exit 0
  " 2>"$err_file" || rc=$?
  err=$(<"$err_file")
  rm -f "$err_file"
  DVW_LAST_WS_HEALTH_ERR="$err"
  case "$rc" in
    0) echo alive ;;
    1) echo stale ;;
    *) echo cold  ;;
  esac
}

# ---------------------------------------------------------------------------
# Provider-first probe
#
# Single SSH round-trip per provider per dvw invocation. The remote script
# enumerates the agent's own workspace directory list, reads each workspace's
# uid from its workspace.json on disk, and joins with `docker ps -a` labels
# server-side. The remote returns `<workspace-id> <state>` lines. The client
# never needs to know any workspace's uid — the server has both halves of
# the join and tells us the answer.
#
# Why provider-side-join (not client-side-with-cached-uid): the client's
# notion of uid (in the catalog snapshot or in this machine's local devpod
# state) can be stale or absent — especially on the "first dvw run on this
# machine" case. The agent's workspace.json on the provider IS the source
# of truth for the id→uid mapping. Asking the server for the join makes the
# probe robust to every client-side missing-data case.
#
# Catalog convention used here: the per-workspace `.provider` field is the
# provider NAME, which by dvw convention also matches the SSH host alias
# (`dvw doctor` enforces this via `devpod provider add … --option HOST=$p`).
# So `ssh <provider-name>` reaches the right host without any further name
# resolution.
#
# State for each catalog entry lands in DVW_PROBE_STATE[id]:
#   alive       container running, /proc/1/cwd is a live inode
#   stale       container running, /proc/1/cwd shows (deleted)
#   stopped     container exists on provider, not running
#   absent      no container on provider for this workspace
#   unreachable could not query the provider host (ssh failed). Captured
#               stderr in DVW_PROBE_ERROR. Distinct from "stopped".
#   unknown     catalog entry has no provider name set at all. Should not
#               happen for new workspaces; only legacy/corrupt entries.
#
# This is a READ-ONLY probe. The remote script does no docker mutations.
# ---------------------------------------------------------------------------
declare -gA DVW_PROBE_STATE=()
DVW_PROBE_ERROR=""
DVW_PROBE_LOADED=""
# Orphan container detection: uids found in `docker ps -a` labels that are
# not claimed by any agent workspace directory. Surfaced as warnings in
# `dvw doctor`. Read-only; we never act on them.
DVW_PROBE_ORPHAN_UIDS=""
# Per-orphan details, keyed by uid. Value is a tab-separated record:
#   "<name>\t<state>\t<mountstatus>\t<mountsrc>\t<workspace_id_inside_mount>"
# Populated by _dvw_probe_one_host's server-side script.
declare -gA DVW_PROBE_ORPHAN_INFO=()

_dvw_load_probe() {
  [[ -n "$DVW_PROBE_LOADED" ]] && return 0
  DVW_PROBE_LOADED=1

  local catalog
  catalog=$(catalog_read 2>/dev/null) || return 0
  [[ -z "$catalog" ]] && return 0

  # Per-workspace (id, provider-name) from the catalog. Nothing else from
  # the catalog is read — uid/HOST resolution happens server-side.
  local rows
  rows=$(jq -r '.workspaces[] | "\(.id)\t\(.provider // "")"' <<<"$catalog")
  [[ -z "$rows" ]] && return 0

  # Bucket workspaces by provider (== ssh host).
  declare -A host_ids=()
  local id provider
  while IFS=$'\t' read -r id provider; do
    [[ -z "$id" ]] && continue
    if [[ -z "$provider" ]]; then
      DVW_PROBE_STATE["$id"]="unknown"
      continue
    fi
    host_ids["$provider"]+="$id"$'\n'
  done <<<"$rows"

  local host
  for host in "${!host_ids[@]}"; do
    _dvw_probe_one_host "$host" "${host_ids[$host]}"
  done
}

# Probe a single provider host. Args:
#   $1 = host alias (must resolve via ~/.ssh/config; by dvw convention this
#        equals the catalog's provider NAME)
#   $2 = newline-separated workspace ids on this host
#
# The remote script does the id→state join itself by reading every
# ~/.devpod/agent/contexts/default/workspaces/*/workspace.json for the uid,
# then matching against `docker ps -a` labels. It also emits orphan-marker
# lines for any labeled container whose uid isn't claimed by a workspace dir.
#
# Output lines from remote:
#   <id> alive|stale|stopped|absent
#   __ORPHAN <uid>
#
# On ssh failure (timeout/auth/no-route/host-unknown): mark every id on
# this host as `unreachable`, store stderr in DVW_PROBE_ERROR. Distinct
# from "stopped" — reachability and aliveness are different questions.
_dvw_probe_one_host() {
  local host="$1" ids="$2"
  local err_file out rc=0
  err_file=$(mktemp)
  # `|| rc=$?` keeps set -e from aborting on ssh failure; we need to record
  # `unreachable` state for the host's workspaces, not abort the whole run.
  #
  # The remote script's safety: read-only on disk and on docker. No `docker
  # run/stop/rm`, no `rm`/`mv`/`>`. Anything that could mutate is absent
  # from the heredoc by design — that's invariant #3 (audit it on every
  # edit).
  out=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "$host" 'bash -s' 2>"$err_file" <<'REMOTE'
set +e
ctx_dir="$HOME/.devpod/agent/contexts/default/workspaces"
ps_tmp=$(mktemp)
# Filter at the docker level to only see containers that carry the
# `dev.containers.id` label. Containers without that label are not
# devpod-managed and have no business in the orphan/state output.
# This avoids the IFS-empty-field parsing trap (bash strips leading
# IFS chars when IFS is whitespace-only, including TAB).
docker ps -a --filter 'label=dev.containers.id' \
  --format '{{.Label "dev.containers.id"}}	{{.State}}	{{.ID}}' 2>/dev/null > "$ps_tmp"

# Track uids claimed by a workspace dir; remaining ps entries are orphans.
claimed_tmp=$(mktemp)

if [ -d "$ctx_dir" ]; then
  for ws_dir in "$ctx_dir"/*/; do
    [ -d "$ws_dir" ] || continue
    ws_id=$(basename "$ws_dir")
    ws_uid=$(jq -r '.workspace.uid // empty' "$ws_dir/workspace.json" 2>/dev/null)
    if [ -z "$ws_uid" ]; then
      echo "$ws_id absent"
      continue
    fi
    echo "$ws_uid" >> "$claimed_tmp"
    # awk -F'\t' so $1=label even when label is empty (gives "")
    match=$(awk -F'\t' -v u="$ws_uid" '$1==u {print; exit}' "$ps_tmp")
    if [ -z "$match" ]; then
      echo "$ws_id absent"
      continue
    fi
    state=$(awk -F'\t' '{print $2}' <<<"$match")
    cid=$(awk -F'\t' '{print $3}' <<<"$match")
    if [ "$state" = "running" ]; then
      pid=$(docker inspect --format '{{.State.Pid}}' "$cid" 2>/dev/null)
      cwd=""
      if [ -n "$pid" ] && [ "$pid" != "0" ]; then
        cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null)
      fi
      case "$cwd" in
        *'(deleted)'*) echo "$ws_id stale"  ;;
        *)             echo "$ws_id alive"  ;;
      esac
    else
      echo "$ws_id stopped"
    fi
  done
fi

# Orphans: labelled containers whose uid is not claimed by any workspace dir.
# For each one, emit a tab-separated detail line so the client can show enough
# in `dvw doctor` to decide whether to investigate further.
#
# Output format (TAB-separated):
#   __ORPHAN<TAB>uid<TAB>name<TAB>state<TAB>mountstatus<TAB>mountsrc<TAB>ws_dest_id
#
# mountstatus:
#   alive    — bind mount source path exists; for running containers, PID 1
#              cwd doesn't show the (deleted) inode marker
#   deleted  — source path missing on host (or running container's PID 1 cwd
#              shows (deleted) — the wipe-footgun fingerprint)
#   nomount  — container has no /workspaces/* bind mount (rare; non-standard)
while IFS=$'\t' read -r o_uid o_state o_cid; do
  [ -z "$o_uid" ] && continue
  if grep -qFx "$o_uid" "$claimed_tmp" 2>/dev/null; then
    continue
  fi
  o_name=$(docker inspect --format '{{.Name}}' "$o_cid" 2>/dev/null | sed 's:^/::')
  # Find /workspaces/* bind mount. Emit as "dest|source", grep for /workspaces,
  # then split — avoids depending on Sprig template funcs which aren't in all
  # Docker versions.
  mount_line=$(docker inspect --format '{{range .Mounts}}{{.Destination}}|{{.Source}}{{println}}{{end}}' "$o_cid" 2>/dev/null | grep '^/workspaces/' | head -1)
  if [ -z "$mount_line" ]; then
    o_mount_status="nomount"
    o_mount_src=""
    o_ws_dest_id=""
  else
    o_ws_dest_id=$(echo "$mount_line" | awk -F'|' '{print $1}' | sed 's:^/workspaces/::')
    o_mount_src=$(echo "$mount_line" | awk -F'|' '{print $2}')
    o_mount_status="alive"
    if [ "$o_state" = "running" ]; then
      o_pid=$(docker inspect --format '{{.State.Pid}}' "$o_cid" 2>/dev/null)
      if [ -n "$o_pid" ] && [ "$o_pid" != "0" ]; then
        o_cwd=$(readlink "/proc/$o_pid/cwd" 2>/dev/null)
        case "$o_cwd" in
          *'(deleted)'*) o_mount_status="deleted" ;;
        esac
      fi
      [ "$o_mount_status" = "alive" ] && [ ! -d "$o_mount_src" ] && o_mount_status="deleted"
    else
      [ ! -d "$o_mount_src" ] && o_mount_status="deleted"
    fi
  fi
  printf '__ORPHAN\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$o_uid" "$o_name" "$o_state" "$o_mount_status" "$o_mount_src" "$o_ws_dest_id"
done < "$ps_tmp"

rm -f "$ps_tmp" "$claimed_tmp"
REMOTE
) || rc=$?

  if (( rc != 0 )); then
    DVW_PROBE_ERROR=$(<"$err_file")
    rm -f "$err_file"
    local id
    while IFS= read -r id; do
      [[ -z "$id" ]] && continue
      DVW_PROBE_STATE["$id"]="unreachable"
    done <<<"$ids"
    return 0
  fi
  rm -f "$err_file"

  # Parse the response. id→state lines (space-separated) set DVW_PROBE_STATE;
  # __ORPHAN lines (TAB-separated, multi-field) populate DVW_PROBE_ORPHAN_INFO.
  local orphans=()
  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "$line" == "__ORPHAN"$'\t'* ]]; then
      local _marker o_uid o_name o_state o_mstatus o_msrc o_wsdest
      IFS=$'\t' read -r _marker o_uid o_name o_state o_mstatus o_msrc o_wsdest <<<"$line"
      [[ -z "$o_uid" ]] && continue
      # Record format: host \t name \t state \t mountstatus \t mountsrc \t wsdest
      # host is prepended client-side (the server doesn't know its own alias).
      DVW_PROBE_ORPHAN_INFO["$o_uid"]="${host}"$'\t'"${o_name}"$'\t'"${o_state}"$'\t'"${o_mstatus}"$'\t'"${o_msrc}"$'\t'"${o_wsdest}"
      orphans+=("$o_uid")
    else
      local rid rstate
      rid=$(awk '{print $1}' <<<"$line")
      rstate=$(awk '{print $2}' <<<"$line")
      [[ -n "$rid" && -n "$rstate" ]] && DVW_PROBE_STATE["$rid"]="$rstate"
    fi
  done <<<"$out"

  # For ids the host didn't mention at all (no workspace dir AND no
  # container), fall back to `absent`.
  local id
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    [[ -z "${DVW_PROBE_STATE[$id]:-}" ]] && DVW_PROBE_STATE["$id"]="absent"
  done <<<"$ids"

  if (( ${#orphans[@]} > 0 )); then
    DVW_PROBE_ORPHAN_UIDS=$(printf '%s\n' "${orphans[@]}")
  fi
}

# Container-safety invariant: this is the ONLY place dvw decides whether
# a container exists at the moment of a destructive call. It MUST be a
# fresh SSH probe — never read from the cached _dvw_load_probe table.
# Reason: there's an unbounded gap between when the bulk probe ran (top
# of the invocation, used for status display) and when a code path is
# about to call `devpod up`. Within that gap a container could have been
# created (e.g. user `devpod up` from another shell). Running `devpod up`
# against a now-existing container is the wipe footgun. So always ask
# fresh, right before the decision.
#
# Costs one local `devpod list` + one short SSH to the provider. Cheap.
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
  _dvw_run_or_print devpod up "$id" "$@"
}

# Dry-run helper. When DVW_DRY_RUN=1, print the would-be command and return
# 0 without executing. Otherwise exec the command and return its rc.
#
# Wraps every dvw-internal mutating shellout (devpod up/delete/stop, docker
# restart). Plumbed in from the top-level --dry-run flag in `dvw`.
_dvw_run_or_print() {
  if [[ "${DVW_DRY_RUN:-}" == "1" ]]; then
    local arg quoted=()
    for arg in "$@"; do
      if [[ "$arg" == *[[:space:]\"\'\\]* ]]; then
        quoted+=("$(printf '%q' "$arg")")
      else
        quoted+=("$arg")
      fi
    done
    ui_info "[dry-run] would run: ${quoted[*]}"
    return 0
  fi
  "$@"
}

# ----------------------------------------------------------------------------
# Multi-machine sync helpers
#
# These bridge the catalog (served by the catalog service) and devpod's per-machine state
# (~/.devpod/contexts/<ctx>/workspaces/<id>/workspace.json). The catalog stores
# a verbatim snapshot of workspace.json plus a top-level `uid` field.
# ----------------------------------------------------------------------------

# ----------------------------------------------------------------------------
# Per-workspace SSH alias writer
#
# The catalog and the ssh blueprint both sync, but neither carries the
# per-workspace `Host <id>.devpod` stanza that resolves the alias — DevPod
# writes that only on the machine that ran `devpod up`/`devpod ssh`. On a
# second machine the alias is absent, so `ssh <id>.devpod` fails DNS even
# though the container is healthy on its provider. These helpers let dvw
# author the stanza itself (idempotently, never via `devpod up`), so any
# machine can open any catalog workspace.
#
# Field set mirrors DevPod's own stanza exactly, so a later real `devpod up`
# reasserts identical content in place rather than duplicating it.
# ----------------------------------------------------------------------------

# Resolve the devpod binary path. Prefers `command -v devpod` (PATH), falls
# back to the conventional ~/.local/bin/devpod that DevPod's own stanzas use.
# Echoes the path; status 0 if found, 1 if neither exists.
_dvw_devpod_bin() {
  local bin
  if bin=$(command -v devpod 2>/dev/null) && [[ -n "$bin" ]]; then
    echo "$bin"
    return 0
  fi
  if [[ -x "$HOME/.local/bin/devpod" ]]; then
    echo "$HOME/.local/bin/devpod"
    return 0
  fi
  return 1
}

# True (status 0) iff ~/.ssh/config already contains a DevPod-marked block for
# <id> (matched exactly on the start marker, so `myws` != `myws-extra`).
_dvw_ssh_alias_present() {
  local id="$1" cfg="${DVW_SSH_CONFIG:-$HOME/.ssh/config}"
  [[ -f "$cfg" ]] || return 1
  grep -qxF "# DevPod Start ${id}.devpod" "$cfg"
}

# Render a DevPod-shaped SSH alias block for <id> on stdout. Pure string
# builder — no I/O, no globals. Field set and order mirror DevPod's own
# stanzas exactly. Args: id user context devpod_bin.
_dvw_render_ssh_alias_block() {
  local id="$1" user="$2" ctx="$3" bin="$4"
  cat <<EOF
# DevPod Start ${id}.devpod
Host ${id}.devpod
  ForwardAgent yes
  LogLevel error
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  HostKeyAlgorithms rsa-sha2-256,rsa-sha2-512,ssh-rsa
  ProxyCommand "${bin}" ssh --stdio --context ${ctx} --user ${user} ${id}
  User ${user}
# DevPod End ${id}.devpod
EOF
}

# Resolve the SSH user for <id> via a three-tier fallback:
#   1. The User line of an existing local DevPod block (covers re-runs).
#   2. The provider container's devcontainer.metadata remoteUser label, read
#      over the workspace's provider HOST (one short SSH).
#   3. The `codespace` convention default.
# Always echoes a non-empty user and returns 0.
#
# The catalog deliberately has NO user field anywhere (verified): the user is
# a property of the built container, so the label is the source of truth.
_dvw_resolve_ssh_user() {
  local id="$1" cfg="${DVW_SSH_CONFIG:-$HOME/.ssh/config}"

  # Tier 1: existing local block.
  if [[ -f "$cfg" ]]; then
    local existing
    existing=$(awk -v s="# DevPod Start ${id}.devpod" -v e="# DevPod End ${id}.devpod" '
      $0 == s {inblk=1; next}
      $0 == e {inblk=0}
      inblk && $1 == "User" {print $2; exit}
    ' "$cfg")
    if [[ -n "$existing" ]]; then
      echo "$existing"
      return 0
    fi
  fi

  # Tier 2: provider container remoteUser label.
  local path host uid user
  path=$(catalog_devpod_workspace_json_path "$id")
  if [[ -f "$path" ]]; then
    host=$(jq -r '.provider.options.HOST.value // empty' "$path" 2>/dev/null)
    uid=$(jq -r '.uid // empty' "$path" 2>/dev/null)
    if [[ -n "$host" && -n "$uid" ]]; then
      user=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "$host" "
        cid=\$(docker ps -a --filter label=dev.containers.id=$uid --format '{{.ID}}' 2>/dev/null | head -1)
        [ -z \"\$cid\" ] && exit 0
        docker inspect --format '{{index .Config.Labels \"devcontainer.metadata\"}}' \"\$cid\" 2>/dev/null
      " 2>/dev/null \
        | jq -r '(if type=="array" then .[] else . end) | .remoteUser? // empty' 2>/dev/null \
        | grep -v '^$' | tail -1)
      if [[ -n "$user" ]]; then
        echo "$user"
        return 0
      fi
    fi
  fi

  # Tier 3: convention default.
  echo "codespace"
  return 0
}

# Ensure ~/.ssh/config has a per-workspace DevPod alias block for <id>.
# No-op if a block is already present (idempotent). Otherwise resolves the
# user (3-tier), context (from materialized workspace.json), and devpod
# binary, renders a DevPod-shaped block, and appends it atomically with a
# separating blank line and mode 600. Returns 1 only if the devpod binary
# can't be located (can't form a working ProxyCommand without it).
_dvw_ensure_ssh_alias() {
  local id="$1" cfg="${DVW_SSH_CONFIG:-$HOME/.ssh/config}"

  if _dvw_ssh_alias_present "$id"; then
    return 0
  fi

  local bin
  if ! bin=$(_dvw_devpod_bin); then
    ui_error "cannot register ssh alias for \"$id\": devpod binary not found (PATH or ~/.local/bin/devpod)"
    return 1
  fi

  local user ctx path
  user=$(_dvw_resolve_ssh_user "$id")
  path=$(catalog_devpod_workspace_json_path "$id")
  ctx=$(jq -r '.context // "default"' "$path" 2>/dev/null)
  [[ -z "$ctx" || "$ctx" == "null" ]] && ctx="default"

  local block
  block=$(_dvw_render_ssh_alias_block "$id" "$user" "$ctx" "$bin")

  mkdir -p "$(dirname "$cfg")"
  chmod 700 "$(dirname "$cfg")" 2>/dev/null || true

  # Atomic, mode-preserving append with a guaranteed separating blank line.
  # Rebuild the whole file via a tmp to avoid partial writes; normalize the
  # existing content to end in exactly one newline before appending so the
  # marker never gets jammed onto a no-trailing-newline last line.
  local tmp="$cfg.dvw.tmp"
  {
    if [[ -f "$cfg" ]]; then
      sed -e :a -e '/^[[:space:]]*$/{$d;N;ba}' "$cfg"
      printf '\n'
    fi
    printf '%s\n' "$block"
  } > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$cfg"

  ui_status_ok "registered ssh alias \"${id}.devpod\" (user=${user})"
}

# True (status 0) iff `<id>.devpod` resolves to a ProxyCommand locally (i.e.
# the per-workspace alias is actually defined in ssh config, not merely the
# generic Host *.devpod block). Used to tell "alias absent" from "alias slow".
_dvw_alias_defined() {
  local ws="$1"
  ssh -G "${ws}.devpod" 2>/dev/null | grep -qi '^proxycommand '
}

# Remove the per-workspace DevPod alias block for <id> from ~/.ssh/config.
# The inverse of _dvw_ensure_ssh_alias: cmd_rm now calls this so deleting a
# workspace doesn't leave a dangling `Host <id>.devpod` stanza behind that
# would accumulate as workspaces come and go. Matches the block on its exact
# DevPod start/end markers (so `myws` never strips `myws-extra`), rewrites the
# file atomically via a tmp + mv, and re-asserts mode 600. Idempotent: a no-op
# success when the block (or the config file) is absent.
_dvw_remove_ssh_alias() {
  local id="$1" cfg="${DVW_SSH_CONFIG:-$HOME/.ssh/config}"
  [[ -f "$cfg" ]] || return 0
  _dvw_ssh_alias_present "$id" || return 0

  local tmp="$cfg.dvw.tmp"
  # Drop every line from the start marker through the end marker, inclusive.
  # `insec==0 {print}` ordering keeps the start line out (insec already set)
  # and the end line out (set back to 0 only after the print test).
  awk -v s="# DevPod Start ${id}.devpod" -v e="# DevPod End ${id}.devpod" '
    $0 == s { insec=1 }
    insec == 0 { print }
    $0 == e { insec=0 }
  ' "$cfg" > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$cfg"

  ui_status_ok "removed ssh alias \"${id}.devpod\""
}

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

# True (status 0) iff some catalog workspace whose id != $1 records uid $2
# (as .uid or .devpod_state.uid). Used to refuse aligning a workspace to a uid
# that already belongs to a different workspace. Empty uid → false (status 1).
_dvw_uid_claimed_by_other() {
  local id="$1" uid="$2"
  [[ -z "$uid" ]] && return 1
  catalog_read 2>/dev/null \
    | jq -e --arg id "$id" --arg uid "$uid" '
        any(.workspaces[];
            .id != $id and ((.uid == $uid) or (.devpod_state.uid == $uid)))
      ' >/dev/null 2>&1
}

# Pure winner-selection over a probe blob. Input #2 is newline-separated
# `<uid>\t<work_session_activity>` lines (activity -1 means no `work` tmux).
# Echoes the chosen uid on stdout. Status: 0 = decided (or cold/empty → no
# output), 1 = pathological (>=2 candidates, none with a `work` tmux session).
# No I/O beyond optional ui_* warnings; safe to unit-test.
_dvw_pick_canonical_uid() {
  local id="$1" probe="$2" chosen n_total n_with_tmux
  probe=$(printf '%s\n' "$probe" | awk 'NF')
  [[ -z "$probe" ]] && return 0          # cold / empty probe → no candidate
  n_total=$(printf '%s\n' "$probe" | wc -l)
  n_with_tmux=$(printf '%s\n' "$probe" | awk -F'\t' '$2 != "-1" && $2 != "" { n++ } END { print n+0 }')

  if (( n_total == 1 )); then
    chosen=$(printf '%s\n' "$probe" | cut -f1)
  elif (( n_with_tmux >= 1 )); then
    chosen=$(printf '%s\n' "$probe" | awk -F'\t' '$2 != "-1"' \
             | sort -t$'\t' -k2 -nr | head -1 | cut -f1)
    if (( n_with_tmux >= 2 )); then
      {
        ui_status_warn "$id has $n_with_tmux containers with a live \`work\` tmux session — picking most-recently-active"
        printf '%s\n' "$probe" | awk -F'\t' '$2 != "-1" { printf "    %s  last_activity=%s\n", $1, $2 }'
        ui_info "  recommend manual cleanup: dvw doctor"
      } >&2
    fi
  else
    {
      ui_status_warn "$id has $n_total containers but none have a \`work\` tmux session:"
      printf '%s\n' "$probe" | awk -F'\t' '{ printf "    %s\n", $1 }'
      ui_info "  refusing to guess. Pick one and start tmux in it, or run \`dvw doctor\`."
    } >&2
    return 1
  fi
  printf '%s\n' "$chosen"
  return 0
}

# Resolve which container is canonical for <id> by direct observation of the
# provider host. Writes the resolved uid into the local workspace.json (#1)
# and pushes to the catalog service (#3). The agent's workspace.json (#2)
# is intentionally NOT consulted or written for uid purposes.
#
# Authority: a container is canonical iff its bind-mount destination is
# /workspaces/<id> AND (when ≥2 candidates exist) it has a live tmux session
# named `work`. Rationale: the uid in workspace.json files is bookkeeping
# that gets re-written by whichever devpod client connects last via
# --workspace-info; the running tmux session inside the container is the
# user's actual valuable state and the only signal that's stable across
# stale-client-write races.
#
# Replaces an earlier `_dvw_reconcile_uid` that trusted the agent file as
# authoritative. That model failed when stale ssh tunnels carrying old
# --workspace-info blobs silently overwrote the agent file, causing
# routing to flap between sibling containers.
#
# Return codes:
#   0 — local file #1 reflects the canonical uid (no-op if already correct,
#       or written atomically + catalog updated if it had to change). Also
#       returned when no candidate containers exist yet — caller falls
#       through to the existing cold-start (`_dvw_safe_devpod_up`) path.
#   1 — pathological state (≥2 candidate containers, none with a `work`
#       tmux session, cannot disambiguate). Caller should stop.
#
# No container is ever touched by this function.
_dvw_resolve_canonical_container() {
  local id="$1" path host current_uid probe chosen
  path=$(catalog_devpod_workspace_json_path "$id")
  [[ -f "$path" ]] || return 0
  current_uid=$(jq -r '.uid // empty' "$path" 2>/dev/null)
  host=$(jq -r '.provider.options.HOST.value // empty' "$path" 2>/dev/null)
  if [[ -z "$host" ]]; then
    ui_status_warn "resolve: no provider HOST in $id's workspace.json — skipping"
    return 0
  fi
  # Single SSH round-trip. Scope candidates to *this* workspace by the bind-mount
  # destination /workspaces/<id> (baked at create, immutable, contains the exact
  # id) rather than a 2-char name-slug prefix, which collided across workspaces
  # sharing a prefix (devmachine-git vs devmachine-new-dvw). For each matching
  # container, probe whether a tmux session named `work` exists; emit
  # `<uid>\t<work_session_activity>` (or `<uid>\t-1` if no such session).
  probe=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "$host" "
    target='/workspaces/${id}'
    for cid in \$(docker ps --filter 'label=dev.containers.id' --format '{{.ID}}' 2>/dev/null); do
      hit=\$(docker inspect -f '{{range .Mounts}}{{.Destination}}{{\"\\n\"}}{{end}}' \"\$cid\" 2>/dev/null \
            | awk -v t=\"\$target\" '\$0 == t { print; exit }')
      [[ -z \"\$hit\" ]] && continue
      uid=\$(docker inspect -f '{{index .Config.Labels \"dev.containers.id\"}}' \"\$cid\" 2>/dev/null)
      [[ -z \"\$uid\" ]] && continue
      act=\$(docker exec \"\$cid\" tmux list-sessions \
              -F '#{session_name} #{session_activity}' 2>/dev/null \
            | awk '\$1 == \"work\" { print \$2; exit }')
      [[ -z \"\$act\" ]] && act=-1
      printf '%s\\t%s\\n' \"\$uid\" \"\$act\"
    done
  " 2>/dev/null) || {
    ui_status_warn "resolve: ssh to $host failed — proceeding with current local uid"
    return 0
  }

  chosen=$(_dvw_pick_canonical_uid "$id" "$probe") || return 1
  [[ -z "$chosen" ]] && return 0

  if [[ "$chosen" != "$current_uid" ]]; then
    if _dvw_uid_claimed_by_other "$id" "$chosen"; then
      ui_status_warn "$id: refusing to align to uid=$chosen — it is already claimed by another workspace in the catalog"
      ui_info "  run \`dvw doctor\` to inspect; this prevents cross-workspace identity theft"
      return 1
    fi
    ui_status_warn "$id: canonical uid=$chosen (was=${current_uid:-unset}) — aligning local & catalog"
    _dvw_rewrite_local_uid "$id" "$chosen" || return 1
    catalog_workspace_set_devpod_state "$id" >/dev/null 2>&1 || {
      ui_status_warn "could not push uid=$chosen to catalog (will retry next time)"
    }
    ui_status_ok "$id: uid aligned to $chosen"
  fi
  return 0
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
    # Client-side workspace.json has `.provider.options.HOST.value` at top
    # level (not nested under `.workspace`, which is the agent layout).
    host=$(jq -r '.provider.options.HOST.value // empty' "$path" 2>/dev/null)
    [[ -n "$host" ]] && ssh_reap_stale_master "$host"
  fi
  return 0
}

# Rewrite the local workspace.json's `.uid` atomically. Client layout uses
# `.uid` at top level, NOT `.workspace.uid` (that's the agent's layout).
# Earlier versions of this function targeted `.workspace.uid` and silently
# created a phantom field while leaving the real `.uid` unchanged.
_dvw_rewrite_local_uid() {
  local id="$1" new_uid="$2" path tmp
  path=$(catalog_devpod_workspace_json_path "$id")
  tmp="$path.tmp"
  if ! jq --arg uid "$new_uid" '.uid = $uid' "$path" > "$tmp"; then
    rm -f "$tmp"
    ui_error "failed to rewrite local workspace.json uid for \"$id\""
    return 1
  fi
  mv "$tmp" "$path"
}
