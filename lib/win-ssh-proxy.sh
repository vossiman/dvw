#!/usr/bin/env bash
# dvw — invoked by Windows ssh's ProxyCommand via wsl.exe to bridge a *.devpod
# host into `devpod ssh --stdio`. DevPod's own per-workspace SSH stanzas pass
# the workspace name without the .devpod suffix, so we mirror that.
#
# --agent-forwarding=false mirrors the Linux/macOS renderer in connect.sh: the
# flag defaults to TRUE, and it forwards over DevPod's own transport, so the
# `ForwardAgent no` in the WSL bridge block does not cover it. See
# _dvw_render_ssh_alias_block for the full rationale.
set -euo pipefail

host="${1:-}"
if [[ -z "$host" ]]; then
  echo "dvw-win-ssh-proxy: usage: $0 <workspace>.devpod" >&2
  exit 2
fi

exec devpod ssh --stdio --agent-forwarding=false "${host%.devpod}"
