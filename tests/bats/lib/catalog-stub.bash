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
# the ssh shim hands the remote command string to a real shell (`bash -c`),
# exactly as OpenSSH hands it to the remote login shell, which re-parses it and
# runs the curl shim. That shim parses `-X METHOD` and the request path out of
# curl's argv and emits the canned `<body>\n<code>` for that route.
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
    declare -f _stub_cfg_value
    declare -f _stub_parse_curl
    declare -f catalog_route
  } > "$dispatch"

  cat > "$STUB_BIN/curl" <<EOF
#!/usr/bin/env bash
source "$dispatch"
_stub_parse_curl "\$@"
EOF
  chmod +x "$STUB_BIN/curl"

  # ssh shim: faithfully emulate OpenSSH. A real `ssh host <cmd>` hands the
  # final argument to the remote LOGIN SHELL as a single string, which RE-PARSES
  # (word-splits / quote-removes) it. The lib relies on this and pre-quotes the
  # command with printf %q. Emulating it via `bash -c "$cmd"` means transport
  # bugs that only appear when a real shell re-tokenizes an arg — an unquoted
  # newline (the -w status format) or a spaced `Bearer <token>` header — surface
  # in tests instead of being masked by argv-preserving array passing. stdin
  # (the request body) flows straight through to the curl shim.
  cat > "$STUB_BIN/ssh" <<EOF
#!/usr/bin/env bash
cmd="\${@: -1}"
exec bash -c "\$cmd"
EOF
  chmod +x "$STUB_BIN/ssh"
}

# Extract the value of `key = "..."` from a curl config-file text, undoing
# the \\ \" \t \n \r escapes lib/catalog-http-lib.sh's _catalog_cfg_escape
# applies. Prints the decoded value and returns 0, or returns 1 if the key
# isn't present. Character-at-a-time on purpose: an escaped quote inside the
# value (e.g. JSON containing `\"`) must not be mistaken for the closing
# quote, which a plain "up to the next quote" regex would get wrong.
_stub_cfg_value() {
  local key="$1" cfg="$2" marker="${1} = \""
  local rest="${cfg%%"$marker"*}"
  [[ "$rest" == "$cfg" ]] && return 1
  rest="${cfg#*"$marker"}"
  local out="" i=0 c n
  while (( i < ${#rest} )); do
    c="${rest:i:1}"
    if [[ "$c" == '"' ]]; then
      break
    elif [[ "$c" == '\' ]]; then
      n="${rest:i+1:1}"
      case "$n" in
        '\\') out+='\' ;;
        '"')  out+='"' ;;
        t)    out+=$'\t' ;;
        n)    out+=$'\n' ;;
        r)    out+=$'\r' ;;
        *)    out+="$n" ;;
      esac
      (( i += 2 ))
    else
      out+="$c"
      (( i += 1 ))
    fi
  done
  printf '%s' "$out"
}

# Parse a curl argv (without the leading `curl`): pull out -X METHOD and the
# request path from the URL (http://localhost<path>), read any body/config
# from stdin or a --data-binary file, then hand off to the test's
# catalog_route. Defined here so it can be dumped into the dispatcher file
# via `declare -f`.
#
# The credential (and, when both are present, the JSON body too) travels via
# `--config -` (a curl config file on stdin, see lib/catalog-http-lib.sh),
# never as a -H/-d argument, so this shim reads that config off stdin and
# extracts the `header = "..."` and `data-raw = "..."` lines (`data-raw`,
# not `data-binary`, so a body starting with `@` is sent literally instead
# of curl reading it as a filename). A body sent WITHOUT a credential still
# arrives the old way, via `--data-binary @-`.
_stub_parse_curl() {
  local method="GET" url="" path="" body="" auth="" data_arg="" cfg_stdin=0
  while (( $# )); do
    case "$1" in
      -X) method="$2"; shift 2 ;;
      -H) [[ "$2" == [Aa]uthorization:* ]] && auth="$2"; shift 2 ;;
      --config) [[ "$2" == "-" ]] && cfg_stdin=1; shift 2 ;;
      --data-binary|--data|-d) data_arg="$2"; shift 2 ;;
      http://*|https://*) url="$1"; shift ;;
      *) shift ;;
    esac
  done
  path="${url#http://localhost}"
  path="${path#https://localhost}"

  if (( cfg_stdin )); then
    local cfg; cfg="$(cat)"
    local v
    v="$(_stub_cfg_value header "$cfg")" && auth="$v"
    v="$(_stub_cfg_value data-raw "$cfg")" && body="$v"
  elif [[ -n "$data_arg" ]]; then
    if [[ "$data_arg" == @* ]]; then
      local f="${data_arg#@}"
      if [[ "$f" == "-" ]]; then body="$(cat)"; else body="$(cat "$f")"; fi
    else
      body="$data_arg"
    fi
  fi
  # 4th arg = the Authorization header verbatim (empty if none). A split/mangled
  # header arrives here as just "authorization:" — tests assert on it to catch
  # transport-quoting regressions.
  catalog_route "$method" "$path" "$body" "$auth"
}

# Emit a response the way lib/catalog-http-lib.sh parses it: body, newline, code.
_stub_emit() {
  local body="$1" code="$2"
  printf '%s\n%s' "$body" "$code"
}
