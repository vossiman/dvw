#!/usr/bin/env bash
# dvw — invoked by Windows ssh's ProxyCommand via wsl.exe to bridge a *.devpod
# host into `devpod ssh --stdio`. DevPod's own per-workspace SSH stanzas pass
# the workspace name without the .devpod suffix, so we mirror that.
set -euo pipefail

host="${1:-}"
if [[ -z "$host" ]]; then
  echo "dvw-win-ssh-proxy: usage: $0 <workspace>.devpod" >&2
  exit 2
fi

exec devpod ssh --stdio "${host%.devpod}"
