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
    if _dvw_provider_has_container "$ws"; then
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
      # Cold-branch policy (container-safety invariant): if the alias probe
      # failed but a container exists on the provider, treat as alive and
      # let Cursor open via its own ssh-remote (which has its own retry/
      # timeout). NEVER `devpod up` against a confirmed-existing container.
      # Only fall through to the wrapper (which still has its own fresh
      # safety check) when no container exists.
      if _dvw_provider_has_container "$ws"; then
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
      ( "$bin" --reuse-window "$uri_arg" >/dev/null 2>&1 & disown ) 2>/dev/null
      return 0
    fi
  done
  ui_error "no cursor CLI found"
  ui_info "  tried: ~/.local/bin/cursor, \`cursor\` on PATH,"
  ui_info "         /mnt/c/Users/$USER/AppData/Local/Programs/{cursor,Cursor}/resources/app/bin/cursor"
  ui_info "  open manually: cursor --reuse-window \"$uri_arg\""
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
# IFS=$'\t' so empty-label lines parse as uid="" (skipped below) rather than
# slipping the state into the uid slot.
while IFS=$'\t' read -r uid state cid; do
  [ -z "$uid" ] && continue
  if ! grep -qFx "$uid" "$claimed_tmp" 2>/dev/null; then
    echo "__ORPHAN $uid"
  fi
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

  # Parse the response. id→state lines set DVW_PROBE_STATE; __ORPHAN lines
  # accumulate uids for doctor.
  local orphans=()
  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "$line" == "__ORPHAN "* ]]; then
      orphans+=("${line#__ORPHAN }")
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
