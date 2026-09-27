# Sourced by host-install.sh and host-update.sh. The catalog seeds new
# workspaces from either an exact immutable blueprint URL or the CI-qualified
# selector that dvw vendors from aiCodingBaseSetup (vendor/aicoding, DVW-27);
# without one of them catalog selection fails closed, so check before the
# caller changes anything. The host needs no aicoding install.
#
# catalog_blueprint_preflight <svc_dir> [tools]
#   Sets catalog_blueprint_url and catalog_blueprint_url_from_env (1 when it
#   came from the environment). Prints the reason and returns 1 on failure.
#   "tools" checks only the host tools, for callers that run before the
#   checkout exists or is refreshed; the vendored file arrives with it.
catalog_blueprint_preflight() {
  local svc_dir=$1 mode=${2:-all} missing="" tool selector
  catalog_blueprint_url="${CATALOG_BLUEPRINT_DEVCONTAINER_URL:-}"
  catalog_blueprint_url_from_env=0
  [ -z "$catalog_blueprint_url" ] || catalog_blueprint_url_from_env=1
  if [ -z "$catalog_blueprint_url" ] && [ -r "$svc_dir/catalog.env" ]; then
    catalog_blueprint_url=$(awk -F= '
      $1 == "CATALOG_BLUEPRINT_DEVCONTAINER_URL" {
        sub(/^[^=]*=/, ""); print; exit
      }
    ' "$svc_dir/catalog.env")
    case "$catalog_blueprint_url" in
      \"*\") catalog_blueprint_url=${catalog_blueprint_url#\"}; catalog_blueprint_url=${catalog_blueprint_url%\"} ;;
      \'*\') catalog_blueprint_url=${catalog_blueprint_url#\'}; catalog_blueprint_url=${catalog_blueprint_url%\'} ;;
    esac
  fi

  if [ -n "$catalog_blueprint_url" ]; then
    if [[ ! "$catalog_blueprint_url" =~ ^https://raw\.githubusercontent\.com/vossiman/aiCodingBaseSetup/[0-9a-f]{40}/devcontainer\.json$ ]]; then
      echo "error: CATALOG_BLUEPRINT_DEVCONTAINER_URL must be an exact supported immutable URL" >&2
      return 1
    fi
    return 0
  fi
  # curl, not "gh or curl": the service has no GitHub login, gh api refuses to
  # run unauthenticated, and the selector's only tokenless path is curl.
  for tool in jq timeout curl; do
    command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
  done
  if [ -n "$missing" ]; then
    echo "error: missing catalog blueprint prerequisite:$missing" >&2
    echo "       install it with apt (the catalog's vendored selector needs it), or configure an exact immutable blueprint URL" >&2
    return 1
  fi
  [ "$mode" != tools ] || return 0
  selector="$svc_dir/vendor/aicoding/bin/aicoding-select"
  if [ ! -x "$selector" ]; then
    echo "error: missing vendored selector: $selector" >&2
    echo "       the dvw checkout is incomplete; pull it again, or configure an exact immutable blueprint URL" >&2
    return 1
  fi
}
