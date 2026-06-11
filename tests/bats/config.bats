#!/usr/bin/env bats
#
# Tests for lib/config.sh — the optional per-machine dvw config file.
# Precedence is env > file > built-in default; the file is parsed, not sourced.

setup() {
  TMPDIR=$(mktemp -d)
  CFG="$TMPDIR/config"
  source "$DVW_ROOT/lib/config.sh"
}

teardown() {
  rm -rf "$TMPDIR"
}

@test "dvw_load_config: sets known keys from the file" {
  cat > "$CFG" <<'EOF'
DVW_CATALOG_HOST=myserver
DVW_PROVIDER=prod
EOF
  unset DVW_CATALOG_HOST DVW_PROVIDER
  dvw_load_config "$CFG"
  [ "$DVW_CATALOG_HOST" = "myserver" ]
  [ "$DVW_PROVIDER" = "prod" ]
}

@test "dvw_load_config: ignores unknown keys, comments, and blank lines" {
  cat > "$CFG" <<'EOF'
# a comment
DVW_CATALOG_HOST=myserver   # trailing comment

NOT_A_KEY=nope
EOF
  unset DVW_CATALOG_HOST NOT_A_KEY
  dvw_load_config "$CFG"
  [ "$DVW_CATALOG_HOST" = "myserver" ]
  [ -z "${NOT_A_KEY:-}" ]
}

@test "dvw_load_config: env wins over the file" {
  echo 'DVW_CATALOG_HOST=from-file' > "$CFG"
  export DVW_CATALOG_HOST=from-env
  dvw_load_config "$CFG"
  [ "$DVW_CATALOG_HOST" = "from-env" ]
}

@test "dvw_load_config: tolerates spaces around = and surrounding quotes" {
  cat > "$CFG" <<'EOF'
DVW_CATALOG_HOST = "my server"
DVW_PROVIDER = 'prod-host'
EOF
  unset DVW_CATALOG_HOST DVW_PROVIDER
  dvw_load_config "$CFG"
  [ "$DVW_CATALOG_HOST" = "my server" ]
  [ "$DVW_PROVIDER" = "prod-host" ]
}

@test "dvw_load_config: missing file is a silent no-op" {
  unset DVW_CATALOG_HOST
  run dvw_load_config "$TMPDIR/does-not-exist"
  [ "$status" -eq 0 ]
  [ -z "${DVW_CATALOG_HOST:-}" ]
}

@test "dvw_config_set: creates the file (and dir) with 0600 perms" {
  local f="$TMPDIR/sub/dvw/config"
  dvw_config_set DVW_CATALOG_HOST myserver "$f"
  [ -f "$f" ]
  [ "$(stat -c '%a' "$f")" = "600" ]
  grep -qx 'DVW_CATALOG_HOST=myserver' "$f"
}

@test "dvw_config_set: replaces an existing key without duplicating it" {
  dvw_config_set DVW_CATALOG_HOST first "$CFG"
  dvw_config_set DVW_CATALOG_HOST second "$CFG"
  [ "$(grep -c '^DVW_CATALOG_HOST=' "$CFG")" -eq 1 ]
  grep -qx 'DVW_CATALOG_HOST=second' "$CFG"
}

@test "dvw_config_set then dvw_load_config round-trips" {
  dvw_config_set DVW_PROVIDER prod "$CFG"
  unset DVW_PROVIDER
  dvw_load_config "$CFG"
  [ "$DVW_PROVIDER" = "prod" ]
}
