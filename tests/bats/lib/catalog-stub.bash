# Shared bats helper: stub the dvw-catalog HTTP transport.
#
# lib/catalog-http-lib.sh reaches the service one of two ways:
#   - curl --unix-socket "$DVW_CATALOG_SOCK"           (when SOCK is a real socket)
#   - ssh "$DVW_CATALOG_HOST" -- curl --unix-socket …  (the normal laptop case)
# In both branches it appends `-w $'\n%{http_code}'` and parses the response as
#   <body>\n<HTTP_CODE>
# (last line = status, everything before = body).
#
# We can't run a real service in bats, so we shim BOTH `curl` and `ssh` onto a
# PATH-first stub dir. Tests set DVW_CATALOG_HOST=stub and ensure
# DVW_CATALOG_SOCK is NOT a real socket, so the deterministic ssh-branch fires;
# the ssh shim strips its own ssh args and re-dispatches to the curl shim, which
# parses `-X METHOD` and the request path out of curl's argv and emits the
# canned `<body>\n<code>` for that route.
#
# A test supplies route answers by defining the bash function `catalog_route`:
#   catalog_route() {  # args: METHOD PATH BODY
#     case "$1 $2" in
#       "GET /v1/health")     _stub_emit '{"status":"ok"}' 200 ;;
#       "GET /v1/workspaces") _stub_emit "$CANNED_LIST" 200 ;;
#       *)                    _stub_emit '{"error":"no route"}' 404 ;;
#     esac
#   }
# _stub_emit BODY CODE prints "<body>\n<code>" exactly as the lib expects.

# Install the curl + ssh shims into $STUB_BIN (must be first on PATH).
catalog_stub_install() {
  : "${STUB_BIN:?catalog_stub_install: STUB_BIN must be set and on PATH}"
  mkdir -p "$STUB_BIN"

  # The shims call back into the test's catalog_route function. They run in a
  # fresh `bash` process, so we hand them the test file's environment by
  # writing catalog_route + helpers to a sourced dispatcher file.
  local dispatch="$STUB_BIN/.catalog-dispatch.bash"
  {
    declare -f _stub_emit
    declare -f _stub_parse_curl
    declare -f catalog_route
  } > "$dispatch"

  cat > "$STUB_BIN/curl" <<EOF
#!/usr/bin/env bash
source "$dispatch"
_stub_parse_curl "\$@"
EOF
  chmod +x "$STUB_BIN/curl"

  # ssh shim: drop ssh options/host up to the `--` separator, then treat the
  # remainder ("curl <args…>") as a curl invocation and dispatch it. stdin (the
  # request body, if any) flows straight through to _stub_parse_curl.
  cat > "$STUB_BIN/ssh" <<EOF
#!/usr/bin/env bash
source "$dispatch"
args=("\$@")
i=0
while (( i < \${#args[@]} )); do
  if [[ "\${args[\$i]}" == "--" ]]; then
    ((i++)); break
  fi
  ((i++))
done
rest=("\${args[@]:\$i}")
# rest = (curl <curl-args…>); drop the leading "curl" token.
_stub_parse_curl "\${rest[@]:1}"
EOF
  chmod +x "$STUB_BIN/ssh"
}

# Parse a curl argv (without the leading `curl`): pull out -X METHOD and the
# request path from the URL (http://localhost<path>), read any body from stdin,
# then hand off to the test's catalog_route. Defined here so it can be dumped
# into the dispatcher file via `declare -f`.
_stub_parse_curl() {
  local method="GET" url="" path="" body="" has_data=0
  while (( $# )); do
    case "$1" in
      -X) method="$2"; shift 2 ;;
      --data-binary|--data|-d) has_data=1; shift 2 ;;
      http://*|https://*) url="$1"; shift ;;
      *) shift ;;
    esac
  done
  path="${url#http://localhost}"
  path="${path#https://localhost}"
  (( has_data )) && body="$(cat)"
  catalog_route "$method" "$path" "$body"
}

# Emit a response the way lib/catalog-http-lib.sh parses it: body, newline, code.
_stub_emit() {
  local body="$1" code="$2"
  printf '%s\n%s' "$body" "$code"
}
