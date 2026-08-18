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

  # Connect mode: bare `dvw <id>` defaults to SSH. Optional flags:
  #   dvw <id> --ssh     — ssh + attach `work` tmux session (same as default)
  #   dvw <id> --cursor  — open in Cursor (devpod up --ide cursor)
  #   dvw <id> --both    — Cursor first, then exec into ssh+tmux
  #   dvw <id> --window @N — select this tmux window after attaching (ssh path
  #                          only; consumed by `dvw attach`, see cmd_attach)
  local mode="ssh" win=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ssh)    mode="ssh"; shift ;;
      --cursor) mode="cursor"; shift ;;
      --both)   mode="both"; shift ;;
      --window)
        win="${2:-}"
        if [[ -z "$win" ]]; then
          ui_error "--window requires an argument"
          return 1
        fi
        shift 2
        ;;
      *) ui_error "unknown flag: $1 (expected --ssh, --cursor, --both, or --window <id>)"; return 1 ;;
    esac
  done

  # Materialize devpod local state from the catalog snapshot if missing,
  # then resolve which container is canonical by direct observation of the
  # provider (tmux-bearing container wins). Both are no-ops on the happy path.
  _dvw_ensure_local_devpod_state "$ws" || return 1
  _dvw_ensure_ssh_alias "$ws" || return 1
  _dvw_resolve_canonical_container "$ws" || return 1
  _dvw_reap_stale_masters "$ws"

  case "$mode" in
    ssh)    _connect_ssh "$ws" "$win" ;;
    cursor) _connect_cursor "$ws" ;;
    both)   _connect_cursor "$ws" && _connect_ssh "$ws" "$win" ;;
    *)      ui_error "unknown connect mode: $mode"; return 1 ;;
  esac
}

# SSH path: probe-up if needed, then ssh -t into a tmux `work` session.
#
# Cold-branch policy (container-safety invariant): if the alias probe fails
# but a container exists on the provider, treat it as alive and open ssh
# directly. NEVER run `devpod up` against a confirmed-existing container
# from this code path — that's the wipe footgun. The actual `ssh -t`
# below uses default (long) ssh timeouts and no BatchMode, so it retries
# on its own where the 5s BatchMode probe gave up.
_connect_ssh() {
  local ws="$1" win="${2:-}"
  # Single-initiator ordering (2026-08-09): when the catalog says the
  # workspace has NO container, run the explicit up BEFORE anything touches
  # the <ws>.devpod alias. The alias's ProxyCommand (`devpod ssh --stdio`)
  # starts its own implicit `devpod up` on a cold workspace — no flag can
  # disable that — and it raced our explicit up across the image pull,
  # creating twin containers. The per-id up-lock below cannot see that
  # initiator; only this ordering can. "unknown" (catalog unreachable)
  # falls through to the legacy probe path rather than blocking connect.
  if [[ "$(_dvw_ws_container_state "$ws")" == "no" ]]; then
    ui_action "starting" "$ws (ide=none)"
    _dvw_safe_devpod_up "$ws" --ide none || { ui_error "devpod up failed for $ws"; return 1; }
    catalog_workspace_set_devpod_state "$ws" 2>/dev/null || true
  elif ! ssh -o ConnectTimeout=5 -o BatchMode=yes "${ws}.devpod" true 2>/dev/null; then
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
  _dvw_ssh_session "$ws" "$win"
}

# Delay before reconnect attempt N (zero-based). DVW_SSH_RECONNECT_DELAY is an
# internal/test override; normal sessions back off quickly and then hold at 5s.
_dvw_ssh_reconnect_delay() {
  local attempt="$1"
  if [[ -n "${DVW_SSH_RECONNECT_DELAY:-}" ]]; then
    printf '%s\n' "$DVW_SSH_RECONNECT_DELAY"
    return 0
  fi
  case "$attempt" in
    0) printf '1\n' ;;
    1) printf '2\n' ;;
    *) printf '5\n' ;;
  esac
}

# True when a multiplex master for this alias is alive. A live master is itself
# proof that authentication to the host works — it only exists because an
# earlier connection completed one.
#
# Needed alongside the connect marker below because OpenSSH does not run
# LocalCommand for a connection that rides an existing master (verified against
# a real sshd). Without this, a `dvw` invocation that reused a master left over
# from a previous one would look like it had never connected.
_dvw_ssh_master_alive() {
  local host="$1" cp
  # Same `ssh -G` idiom (and SIGPIPE guard) as ssh_reap_stale_master.
  cp=$(ssh -G "$host" 2>/dev/null | awk '$1=="controlpath"{print $2; exit}' || true)
  [[ -z "$cp" || "$cp" == "none" ]] && return 1
  [[ -S "$cp" ]] || return 1
  timeout 3 ssh -O check "$host" >/dev/null 2>&1
}

# Run the interactive SSH/tmux session and reattach after transport loss.
#
# ssh uses 255 for connection/auth/protocol failures. Once the outer connect
# path has resolved the workspace and performed its safety checks, retrying that
# status is read-only: it only reopens the same alias and tmux session. Clean
# tmux detach/logout returns 0 and all other remote-command statuses propagate.
#
# 255 is not only "the network blipped" — it is also a bad host key and a
# refused auth, and exit status alone cannot tell those apart. Two structural
# signals gate and bound the retrying; neither reads ssh's message text, which
# would tie us to another tool's wording:
#
#   1. Establishment. ssh runs with `-o LocalCommand=touch <marker>`, a client
#      hook OpenSSH runs only after a connection authenticates, so the marker
#      file existing is proof this attempt connected. A live multiplex master
#      counts too (see _dvw_ssh_master_alive), since one cannot exist without
#      an earlier connection having authenticated. Until something proves a
#      connection happened, a 255 means there is no session to reconnect to —
#      auth, host key, config, unreachable host — and it propagates with ssh's
#      own error left on screen.
#   2. DVW_SSH_RECONNECT_TOTAL_MAX (50) caps reconnects for the whole
#      invocation and is NEVER reset. Three earlier versions of this loop
#      shipped an unbounded retry because their only bound was one a failure
#      could reset: first session duration, then disconnect wording, then a
#      per-streak counter refilled by both. A bound that nothing resets is the
#      only kind that holds when the signal feeding it is wrong.
#
# Reconnect attempts (never the first connect, which may legitimately be slow
# on a cold container) also carry a short ConnectTimeout, so 50 attempts cannot
# add up to an unbounded wait when each one blocks on a dead network.
#
# This loop deliberately contains no `devpod up` path. A transient network
# failure must never be reinterpreted as a stopped container after the initial
# provider check, because that is the stale-bind-mount/wipe footgun guarded by
# _dvw_safe_devpod_up.
# Remove a marker dir made by _dvw_ssh_session — and nothing else. This is the
# one `rm -rf` in the connect path, it runs from a trap, and it runs after a
# session that may have ended in any state, so it is written to be impossible
# to misfire rather than merely correct:
#
#   - empty/unset path       → no-op (never `rm -rf ""`, never `rm -rf /`)
#   - basename not dvw-ssh.* → refuse loudly; we did not create it
#   - not a directory        → no-op (already gone, or something else's inode)
#   - symlink                → no-op (never follow one out of TMPDIR)
#   - `--` before the path   → a name starting with `-` can't become a flag
#
# Always returns 0: it is a cleanup, and a trap that fails must not change the
# status the function was returning.
_dvw_rm_marker_dir() {
  local dir="${1:-}"
  [[ -n "$dir" ]] || return 0
  if [[ "${dir##*/}" != dvw-ssh.* ]]; then
    ui_error "refusing to remove unexpected ssh marker dir: $dir"
    return 0
  fi
  [[ -L "$dir" ]] && return 0
  [[ -d "$dir" ]] || return 0
  rm -rf -- "$dir"
  return 0
}

_dvw_ssh_session() {
  local ws="$1" win="${2:-}" rc=0 total=0 delay markdir marker established=0
  local max_total="${DVW_SSH_RECONNECT_TOTAL_MAX:-50}"
  local connect_timeout="${DVW_SSH_RECONNECT_CONNECT_TIMEOUT:-10}"
  local -a retry_opts=()
  markdir=$(mktemp -d "${TMPDIR:-/tmp}/dvw-ssh.XXXXXX") || return 1
  marker="$markdir/connected"
  # Session registry for `dvw push`: which workspace this client process is
  # attached to. Lifecycle rides the existing markdir trap — nothing new to
  # clean up. pid lets readers skip dirs orphaned by SIGKILL (trap never ran).
  printf '%s\n' "$ws" > "$markdir/workspace"
  printf '%s\n' "$$" > "$markdir/pid"
  # Fires on every return path below, including the Ctrl-C one. It disarms
  # itself first: bash leaves a RETURN trap armed after the function that set
  # it returns, so without `trap - RETURN` it fires a second time when the
  # *caller* returns — a scope where $markdir is gone, which under `set -u`
  # aborts dvw with "markdir: unbound variable" after an otherwise clean exit.
  # `${markdir:-}` is deliberate belt-and-braces: even if the disarm above ever
  # fails to hold, an unset var reaches the helper as empty (a no-op) instead of
  # aborting dvw under `set -u`.
  trap 'trap - RETURN; _dvw_rm_marker_dir "${markdir:-}"' RETURN

  # `dvw attach` threads a tmux window id through here so the session lands
  # directly on the window agent-notify flagged @waiting, instead of just the
  # `work` session's default view. Validate before embedding: this string
  # reaches a remote shell via `-t "${ws}.devpod" "$remote_command"`, so a
  # malformed id must never make it into that command line. tmux window ids
  # are always `@<digits>` (stable across renames/reordering — never the
  # positional index), so anything else is rejected outright rather than
  # quoted defensively.
  #
  # Reconnect note: the retry loop below re-runs this same remote_command on
  # every reattach, so a transport blip mid-session re-selects the window on
  # reconnect too. Accepted: the flag itself is one-shot (agent-notify clears
  # it on the first select), so this only ever re-selects a window the user
  # may have already moved off in the interim — a cosmetic jump, not a
  # correctness problem, and far simpler than threading "already selected
  # once" state through the reconnect loop for it.
  local select_cmd=""
  if [[ -n "$win" ]]; then
    if [[ "$win" =~ ^@[0-9]+$ ]]; then
      select_cmd=" \\; select-window -t '$win'"
    else
      ui_error "ignoring malformed window id: $win"
    fi
  fi

  # Expanded by the remote login shell, not by this client-side assignment.
  # shellcheck disable=SC2016
  local remote_command="
    infocmp -1 \"\$TERM\" >/dev/null 2>&1 || export TERM=xterm-256color
    if command -v tmux >/dev/null 2>&1; then
      exec bash -lc \"tmux new -A -D -s work$select_cmd\"
    fi
    echo \"tmux not found in this workspace. Falling back to plain bash (no resume).\" >&2
    echo \"To bootstrap the full toolchain inside the workspace:\" >&2
    echo \"  git clone https://github.com/vossiman/aiCodingBaseSetup /tmp/aicoding && bash /tmp/aicoding/install.sh\" >&2
    exec bash -l
  "

  while true; do
    rc=0
    # Single ssh call: probe tmux inside the same login shell that will host
    # the session, so we don't pay for two TCP+auth+`bash -l` round-trips.
    #
    # tmux exclusivity: `-A -D` together mean "create if missing, otherwise
    # attach with -d (detach any other client of this session)". Last attach
    # wins; the session itself keeps running across viewer changes. Plain
    # `docker exec` shells (Cursor remote-ssh, non-tmux ssh) are unaffected —
    # exclusivity is scoped to the tmux path only.
    # A master alive before the attempt proves auth to this host works, and is
    # what covers a session that rides one (OpenSSH skips LocalCommand then).
    _dvw_ssh_master_alive "${ws}.devpod" && established=1
    rm -f "$marker"
    ssh -o PermitLocalCommand=yes -o "LocalCommand=touch '$marker'" \
      "${retry_opts[@]}" -t "${ws}.devpod" "$remote_command" || rc=$?
    [[ -e "$marker" ]] && established=1

    case "$rc" in
      0)   return 0 ;;
      255) ;;
      *)   return "$rc" ;;
    esac

    if (( ! established )); then
      # ssh never authenticated, so there is no session to reattach to. Its own
      # error is already on screen; retrying would only bury it.
      ui_error "$ws: ssh never connected — not a dropped session (see above)"
      return "$rc"
    fi

    if (( total >= max_total )); then
      ui_error "$ws: $total reconnects in one session without settling — giving up"
      ui_info "  the tmux 'work' session is untouched; reconnect with: dvw $ws"
      return "$rc"
    fi

    _dvw_reap_stale_masters "$ws"
    delay=$(_dvw_ssh_reconnect_delay "$total")
    total=$((total + 1))
    retry_opts=(-o "ConnectTimeout=$connect_timeout")
    ui_status_warn "$ws: ssh transport lost — reconnecting in ${delay}s ($total/$max_total, Ctrl-C to stop)"
    # An interrupt during the delay is an explicit request to leave the
    # reconnect loop. Returning 130 matches conventional SIGINT status.
    sleep "$delay" || return 130
  done
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

  # Single-initiator ordering (2026-08-09): a definitively cold workspace is
  # brought up here, before the health check — _dvw_workspace_health probes
  # via the <ws>.devpod alias, whose ProxyCommand implicitly ups a cold
  # workspace and races this explicit up (twin containers). `devpod up
  # --ide cursor` opens the Cursor window itself when done.
  if [[ "$(_dvw_ws_container_state "$ws")" == "no" ]]; then
    ui_action "starting" "$ws in Cursor"
    if ! _dvw_safe_devpod_up "$ws" --ide cursor; then
      ui_error "devpod up --ide cursor failed for $ws"
      return 1
    fi
    catalog_workspace_set_devpod_state "$ws" 2>/dev/null || true
    return 0
  fi

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
# Provider status probe state (filled by lib/connect-resolver.sh).
#
# Implementations of _dvw_load_probe / _dvw_provider_has_container /
# _dvw_resolve_canonical_container live in connect-resolver.sh (catalog-service
# HTTP). The `dvw` entrypoint sources that file AFTER this one so those
# definitions win. Do not reintroduce SSH fan-out copies here.
#
# State for each catalog entry lands in DVW_PROBE_STATE[id]:
#   alive       container running, /proc/1/cwd is a live inode
#   stale       container running, /proc/1/cwd shows (deleted)
#   stopped     container exists on provider, not running
#   absent      no container on provider for this workspace
#   unreachable could not query the provider (catalog unreachable). Captured
#               detail in DVW_PROBE_ERROR. Distinct from "stopped".
#   unknown     catalog entry has no provider name set at all. Should not
#               happen for new workspaces; only legacy/corrupt entries.
#
# This is a READ-ONLY probe. The service does no docker mutations for status.
# ---------------------------------------------------------------------------
declare -gA DVW_PROBE_STATE=()
DVW_PROBE_ERROR=""
DVW_PROBE_LOADED=""
# Orphan container detection: containers found in docker whose uid is not
# claimed by any agent workspace directory. Surfaced as warnings in
# `dvw doctor`. Read-only. One entry per CONTAINER (not per uid — twin
# containers from racing `devpod up` runs share a uid, 2026-08-09).
DVW_PROBE_ORPHAN_NAMES=""
# Per-orphan details, keyed by container name. Value is a tab-separated record:
#   "<host>\t<uid>\t<state>\t<mountstatus>\t<mountsrc>\t<workspace_id_inside_mount>"
# Populated by connect-resolver.sh from GET /v1/containers/orphans.
declare -gA DVW_PROBE_ORPHAN_INFO=()
# Count of RUNNING containers mounting /workspaces/<id>, keyed by workspace id.
# >1 means duplicate siblings: resolve() refuses to disambiguate them without a
# tmux `work` session, so connect hard-fails while the bulk status still reports
# the arbitrary winner as running. Empty for servers predating the
# running_siblings field — treated as "unknown", never as a problem.
declare -gA DVW_PROBE_SIBLINGS=()

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
# So before each `devpod up`, ask the catalog service: does a container
# currently exist for this workspace? (`_dvw_provider_has_container` from
# connect-resolver.sh). If yes, refuse without explicit confirmation.
# cmd_recreate doesn't go through this — recreate is destructive by design
# and the user typed it on purpose.
_dvw_safe_devpod_up() {
  local id="$1"
  shift
  # Zombie guard (2026-08-09): an id purged from the catalog but still in
  # the local DevPod registry stays `devpod list`-visible and up-able, and
  # `devpod up` silently resurrects it as an orphan container. The catalog
  # is the authority on what may be brought up. Fail-open when the catalog
  # cannot answer (empty/unreachable): blocking every up on a catalog
  # outage would hurt more than the zombie risk.
  local _catalog_ids
  _catalog_ids=$(catalog_workspace_ids 2>/dev/null) || _catalog_ids=""
  if [[ -n "$_catalog_ids" ]] && ! grep -qxF -- "$id" <<<"$_catalog_ids"; then
    ui_error "$id is not in the catalog — refusing \`devpod up\`"
    ui_info "  an id in \`devpod list\` but not the catalog is a stale/zombie registry entry."
    ui_info "  adopt it as a real workspace via \`dvw new\`, or drop it: devpod delete $id"
    return 1
  fi
  if _dvw_provider_has_container "$id"; then
    ui_status_warn "$id is unreachable via SSH but a container exists on its provider"
    ui_info "  running \`devpod up\` against an already-running container can wipe"
    ui_info "  content/ and leave the bind mount on a deleted inode (lost source)."
    ui_info "  recover: fix the network to the agent, or \`dvw recreate $id\`."
    if ! ui_confirm "run \`devpod up $id $*\` anyway?"; then
      ui_info "aborted"
      return 1
    fi
  fi
  # Serialise per workspace. Two overlapping `devpod up` runs for one id create
  # two containers: observed 2026-07-26, siblings 6s apart with identical config,
  # one abandoned before setup-user ever chowned /workspaces. The survivor pair
  # then deadlocks connect, which refuses to guess between them. Atomic mkdir,
  # same idiom as dvw_update_refresh_if_stale (lib/update-check.sh).
  # Skipped under --dry-run: that mode must not touch the filesystem.
  if [[ "${DVW_DRY_RUN:-}" == "1" ]]; then
    _dvw_run_or_print devpod up "$id" "$@"
    return $?
  fi
  local lock="${DVW_UP_LOCK_DIR:-${TMPDIR:-/tmp}}/dvw-up-${id//[^A-Za-z0-9_.-]/_}.lock"
  if ! mkdir "$lock" 2>/dev/null; then
    ui_status_warn "$id: a \`devpod up\` is already in flight — refusing to start a second"
    ui_info "  two concurrent runs create duplicate containers that connect cannot disambiguate."
    ui_info "  if no other run is active, the lock is stale: rmdir $lock"
    return 1
  fi
  _dvw_run_or_print devpod up "$id" "$@"
  local up_rc=$?
  rmdir "$lock" 2>/dev/null || true
  return $up_rc
}

# Dry-run helper. When DVW_DRY_RUN=1, print the would-be command and return
# 0 without executing. Otherwise exec the command and return its rc.
#
# Wraps every dvw-internal mutating shellout (devpod up/delete/stop, docker
# restart). Plumbed in from the top-level --dry-run flag in `dvw`.
# Append one line per mutating action to an action log. dvw had NO logging at
# all, which is why "did something run `devpod up` twice, and what removed the
# previous containers?" was unanswerable after the fact (2026-07-26). Every
# mutating shellout already funnels through _dvw_run_or_print, so this is the
# one choke point that sees them all.
#
# Strictly fail-open: a logging problem must never break the command. Set
# DVW_ACTION_LOG=/dev/null to disable.
_dvw_log_action() {
  local logf="${DVW_ACTION_LOG:-$HOME/.dvw/actions.log}"
  [[ "$logf" == /dev/null ]] && return 0
  mkdir -p "$(dirname "$logf")" 2>/dev/null || return 0
  printf '%s\tpid=%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$" "$*" >> "$logf" 2>/dev/null || true
  return 0
}

_dvw_run_or_print() {
  _dvw_log_action "${DVW_DRY_RUN:+[dry-run] }$*"
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

# Canonical-container resolve (_dvw_resolve_canonical_container) is implemented
# in lib/connect-resolver.sh via GET /v1/workspaces/{id}/container. Keep
# _dvw_pick_canonical_uid above for unit tests and any offline tooling that
# still reasons over a probe blob; production no longer SSH-probes for resolve.

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
