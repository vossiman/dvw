# Sourced by host-install.sh and host-update.sh. The catalog seeds new
# workspaces from either an exact immutable blueprint URL or the CI-qualified
# selector (aicoding-select); without one of them catalog selection fails
# closed, so check before the caller changes anything.
#
# catalog_blueprint_preflight <svc_dir>
#   Sets catalog_blueprint_url and catalog_blueprint_url_from_env (1 when it
#   came from the environment). Prints the reason and returns 1 on failure.
catalog_blueprint_preflight() {
  local svc_dir=$1 missing="" tool
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
  for tool in aicoding-select jq timeout; do
    command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
  done
  if ! command -v gh >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
    missing="$missing gh-or-curl"
  fi
  if [ -n "$missing" ]; then
    echo "error: missing catalog blueprint prerequisite:$missing" >&2
    echo "       install the minimal common updater before deploying, or configure an exact immutable blueprint URL" >&2
    return 1
  fi
}
