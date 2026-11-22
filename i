#!/usr/bin/env bash
# akvorado-install - GitHub-delivered installer / updater for akvorado-platform (RHEL 9, x86_64). No GitHub token is needed.
#
#   akvorado-install [install]  [--version X.Y.Z] [--flow-from IPs] [--web-from CIDRs] [--data-dir DIR]   first installation (safe to re-run; never wipes data)
#   akvorado-install update     [--version X.Y.Z]                                                         upgrade (backup, snapshot, automatic rollback)
#   akvorado-install check                                                                                READ-ONLY readiness check: PASS/WARN/FAIL (system, storage, proxy, TLS, GitHub, ranged downloads)
#   akvorado-install rollback   [--with-data]                                                             return to the state saved by the last upgrade (local, no network)
#   akvorado-install health                                                                               verification of the running platform (local, no network)
#   akvorado-install version
#
# Network options (all optional; detected, then remembered in /etc/akvorado-platform/network.env):
#   --proxy URL | --no-proxy      explicit proxy (default: https_proxy of the calling user, then /etc/environment, /etc/profile.d, /etc/dnf/dnf.conf)
#   --ca-file PEM                 corporate TLS-inspection CA: ADDED to the system trust store for the installer's own requests (verification stays on)
#   --allow-stream                only if the proxy ignores HTTP Range: whole-asset download instead of ranged chunks (still resumable and verified)
#
# Everything is delivered by ONE channel: the public GitHub Release of jaber717/akv. Hosts contacted (HTTPS/443 only):
#     api.github.com                        release metadata and the download request (HTTP 302)
#     release-assets.githubusercontent.com  the asset bytes
# TLS verification is never disabled. Nothing outside the staging directory (/var/lib/akvorado-platform/staging) is changed until every asset has been
# downloaded and verified (size, SHA-256 from SHA256SUMS and from GitHub's own asset digest).
set +x
set -Eeuo pipefail
umask 077

# ------------------------------------------------------------------------------------------------------------ constants (stamped by tools/publish-dist.sh)
AKV_REPO=${AKV_REPO:-jaber717/akv}
AKV_VERSION_DEFAULT="1.1.0-rc4"
AKV_INSTALLER_REV="2"
PREFLIGHT_SHA256="128c848241723f5e3b6ca91dd819fb6065faa97709810b9fd24eba7caae04488"
MANIFEST_SHA256="9f9fd1fd69e5935d92df3cd9943537c20eef8fe48a1e8ae23c150ff3ccf065fa"
API_HOST="api.github.com"
ASSET_HOST="release-assets.githubusercontent.com"
ETC=${AP_ETC:-/etc/akvorado-platform}
STAGING_ROOT=${AKV_STAGING:-/var/lib/akvorado-platform/staging}
LOGDIR=${AKV_LOGDIR:-/var/log/akvorado-platform}
SELF_INSTALL=/usr/local/sbin/akvorado-install
NETENV="$ETC/network.env"

E_USAGE=2; E_NEEDS_CONFIG=3; E_PREREQ=11; E_AUTH=12; E_NET=13; E_NOTFOUND=14; E_RATE=15; E_SERVER=16; E_INTEGRITY=17; E_SPACE=18; E_INCOMPLETE=19; E_PLATFORM=20; E_RANGE=21; E_BUSY=22

# ------------------------------------------------------------------------------------------------------------ output
c_b=""; c_r=""; c_g=""; c_y=""; c_0=""
if [ -t 2 ]; then c_b=$'\033[1m'; c_r=$'\033[31m'; c_g=$'\033[32m'; c_y=$'\033[33m'; c_0=$'\033[0m'; fi
now() { date +%H:%M:%S; }
say()  { printf '%s\n' "$*" >&2; }
step() { printf '\n%s[%s] == %s%s\n' "$c_b" "$(now)" "$*" "$c_0" >&2; }
ok()   { printf '%s[ OK ]%s %s %s\n' "$c_g" "$c_0" "$(now)" "$*" >&2; }
warn() { printf '%s[WARN]%s %s %s\n' "$c_y" "$c_0" "$(now)" "$*" >&2; }
die()  { local code=$1; shift; printf '%s[FAIL]%s %s %s\n' "$c_r" "$c_0" "$(now)" "$*" >&2; [ -n "${SAFE_MSG:-}" ] && printf '       %s\n' "$SAFE_MSG" >&2; exit "$code"; }
SAFE_MSG="Nothing on this host has been changed (only the staging directory ${STAGING_ROOT} is used)."
mask() { sed -E 's#(://)[^/@ ]+@#\1***@#g'; }

# ------------------------------------------------------------------------------------------------------------ run-time state
RUNTMP=""; AUTH_HDR=""; HAVE_TOKEN=0; TOKEN_SOURCE=""; PROXY_CFG=""
CMD="install"; WANT_VERSION=""; ENV_FILE_ARG=""; TOKEN_FILE_ARG=""; WITH_DATA=0; ASSUME_YES=0; ALLOW_STREAM=0
ARG_PROXY=""; ARG_NOPROXY=0; ARG_CA=""; ARG_FLOW=""; ARG_WEB=""; ARG_DATA=""
PROXY_URL=""; PROXY_SRC="direct"; EXTRA_CA=""; CA_SRC=""
API_BASE="https://${API_HOST}"
CA_ARGS=(); PROXY_ARGS=()
HTTP_CODE=0; CURL_RC=0; NOAUTH=0; ACCEPT=" 200 206 "; HTTP_REDIR=""; CR_TOTAL=0
SELF_SRC=""; ORIG_ARGS=("$@")

cleanup() { [ -n "$RUNTMP" ] && [ -d "$RUNTMP" ] && rm -rf "$RUNTMP" 2>/dev/null || true; }
trap cleanup EXIT
trap 'die 1 "interrupted (downloaded and verified parts are kept; run the same command again to resume)"' INT TERM

usage() {
  if [ -n "${BASH_EXECUTION_STRING:-}" ]; then printf '%s\n' "$BASH_EXECUTION_STRING" | sed -n '2,24p' | sed 's/^# \{0,1\}//' >&2
  elif [ -r "$0" ]; then sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//' >&2; fi
  exit "$E_USAGE"
}

parse_args() {
  [ $# -gt 0 ] && case "$1" in install|update|check|rollback|health|version) CMD=$1; shift ;; -h|--help|help) usage ;; esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --version)      WANT_VERSION=${2:?--version needs a value}; WANT_VERSION=${WANT_VERSION#v}; shift 2 ;;
      --env-file)     ENV_FILE_ARG=${2:?--env-file needs a path}; shift 2 ;;
      --token-file)   TOKEN_FILE_ARG=${2:?--token-file needs a path}; shift 2 ;;
      --proxy)        ARG_PROXY=${2:?--proxy needs a URL}; shift 2 ;;
      --no-proxy)     ARG_NOPROXY=1; shift ;;
      --ca-file)      ARG_CA=${2:?--ca-file needs a PEM file}; shift 2 ;;
      --flow-from)    ARG_FLOW=${2:?--flow-from needs IPs}; shift 2 ;;
      --web-from)     ARG_WEB=${2:?--web-from needs CIDRs}; shift 2 ;;
      --data-dir)     ARG_DATA=${2:?--data-dir needs a directory}; shift 2 ;;
      --allow-stream) ALLOW_STREAM=1; shift ;;
      --with-data)    WITH_DATA=1; shift ;;
      --yes|-y)       ASSUME_YES=1; shift ;;
      -h|--help)      usage ;;
      *) say "unknown argument: $1"; usage ;;
    esac
  done
  if [ -n "$WANT_VERSION" ] && ! [[ "$WANT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.]+)?$ ]]; then die "$E_USAGE" "--version '$WANT_VERSION' is not a version like 1.1.0"; fi
}

# ------------------------------------------------------------------------------------------------------------ root + environment hand-over
# 'sudo' drops proxy variables (env_reset). The installer therefore starts as the calling user and re-runs itself through "sudo env VAR=..." so that the
# proxy / CA settings of the calling user reach the root process. Works when started as   bash -c "$(curl ...)"   (the script text is in BASH_EXECUTION_STRING).
self_source() {
  if [ -n "${BASH_EXECUTION_STRING:-}" ]; then SELF_SRC=$BASH_EXECUTION_STRING
  elif [ -r "$0" ]; then SELF_SRC=$(cat "$0"); fi
}
elevate() {
  command -v sudo >/dev/null 2>&1 || die "$E_PREREQ" "root is required and sudo is not installed: run this as root"
  local e=() v
  for v in https_proxy HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY AKV_CA_BUNDLE AKV_REPO AKV_CHUNK_MIB AKV_CHUNK_BYTES AKV_RETRIES AKV_CHUNK_RETRIES AKV_TEST_MODE AKV_API_BASE AKV_STAGE_ONLY AKV_STAGING AKV_LOGDIR AP_ETC AKV_NO_PROMPT AKV_MAX_WAIT PLATFORM_ALLOW_EL_CLONE; do
    [ -n "${!v:-}" ] && e+=("$v=${!v}")
  done
  say "root is required: re-running through sudo (the proxy and CA settings of your session are passed along)"
  if [ -n "$SELF_SRC" ] && [ -n "${BASH_EXECUTION_STRING:-}" ]; then exec sudo env "${e[@]}" bash -c "$SELF_SRC" akvorado-install "${ORIG_ARGS[@]}"
  else exec sudo env "${e[@]}" bash "$0" "${ORIG_ARGS[@]}"; fi
}
need_root() { [ "$(id -u)" -eq 0 ] || elevate; }

# ------------------------------------------------------------------------------------------------------------ prerequisites
check_tools() {
  local t miss=()
  for t in curl tar sha256sum python3 df awk sed grep sort cat install mktemp; do command -v "$t" >/dev/null 2>&1 || miss+=("$t"); done
  [ "${#miss[@]}" -eq 0 ] || die "$E_PREREQ" "missing tools on this host: ${miss[*]} (curl, tar, coreutils and python3 are part of every RHEL 9 installation)"
  [ "$(uname -m)" = x86_64 ] || die "$E_PREREQ" "architecture $(uname -m) is not supported (x86_64 only)"
}
check_os() {
  [ -r /etc/os-release ] || die "$E_PREREQ" "no /etc/os-release"
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}:${VERSION_ID:-}" in
    rhel:9.*) ok "Red Hat Enterprise Linux ${VERSION_ID}" ;;
    *) if [ "${PLATFORM_ALLOW_EL_CLONE:-no}" = yes ] && [[ "${VERSION_ID:-}" == 9.* ]]; then warn "${PRETTY_NAME:-$ID} is an EL9 clone, accepted because PLATFORM_ALLOW_EL_CLONE=yes (test systems only)"; else die "$E_PREREQ" "${PRETTY_NAME:-unknown OS} is not supported: Red Hat Enterprise Linux 9.x is required"; fi ;;
  esac
}
setup_test_mode() { # the API base can be redirected ONLY in test mode and only to loopback: a token must never be sent to an arbitrary host
  if [ "${AKV_TEST_MODE:-0}" = 1 ] && [ -n "${AKV_API_BASE:-}" ]; then
    API_BASE=$AKV_API_BASE
    case "$API_BASE" in https://127.0.0.1:*|https://localhost:*) ;; *) die "$E_USAGE" "AKV_API_BASE may only point to loopback (test mode)";; esac
    warn "TEST MODE: API base $API_BASE"
  fi
}

# ------------------------------------------------------------------------------------------------------------ network: proxy, CA, credentials
make_runtmp() {
  local base=/run; [ -d /run ] && [ -w /run ] || base=/dev/shm
  RUNTMP=$(mktemp -d "$base/akvorado-install.XXXXXX"); chmod 0700 "$RUNTMP"
  AUTH_HDR="$RUNTMP/auth.hdr"; PROXY_CFG="$RUNTMP/proxy.cfg"
}
net_saved() { { [ -r "$NETENV" ] && sed -n "s/^$1=//p" "$NETENV" | tail -1 | tr -d '"'; } || true; }
detect_proxy_files() { # prints "URL<TAB>source" for the first proxy found in the usual system places
  local f x
  for f in /etc/environment /etc/profile /etc/profile.d/*.sh /etc/bashrc; do
    [ -r "$f" ] || continue
    x=$(grep -hiE '^[[:space:]]*(export[[:space:]]+)?(https_proxy|all_proxy)=' "$f" 2>/dev/null | head -1 | sed -E "s/^[^=]*=//; s/[\"']//g; s/[[:space:]]+\$//") || true
    [ -n "$x" ] && { printf '%s\t%s\n' "$x" "$f"; return 0; }
  done
  x=$(sed -n 's/^proxy[[:space:]]*=[[:space:]]*//p' /etc/dnf/dnf.conf 2>/dev/null | head -1 | tr -d ' ') || true
  [ -n "$x" ] && { printf '%s\t%s\n' "$x" /etc/dnf/dnf.conf; return 0; }
  return 0
}
resolve_network() {
  local u="" src="" line v ui=""
  if [ "$ARG_NOPROXY" = 1 ]; then PROXY_URL=""; PROXY_SRC="direct (--no-proxy)"
  else
    if [ -n "$ARG_PROXY" ]; then u=$ARG_PROXY; src="--proxy"; fi
    if [ -z "$u" ]; then for v in https_proxy HTTPS_PROXY all_proxy ALL_PROXY; do if [ -n "${!v:-}" ]; then u=${!v}; src="environment ($v)"; break; fi; done; fi
    if [ -z "$u" ]; then u=$(net_saved PROXY_URL); [ -n "$u" ] && src="saved settings ($NETENV)"; fi
    if [ -z "$u" ]; then line=$(detect_proxy_files); if [ -n "$line" ]; then u=${line%%$'\t'*}; src=${line#*$'\t'}; fi; fi
    if [ -n "$u" ]; then
      [[ "$u" =~ ^(https?|socks5h?)://([^/@[:space:]]+@)?[^/@[:space:]:]+(:[0-9]+)?/?$ ]] || die "$E_USAGE" "the proxy '$(printf '%s' "$u" | mask)' (from $src) is not a valid URL; expected http://host:port"
      if [[ "$u" =~ ^([a-z0-9]+://)([^/@]+)@(.*)$ ]]; then ui=${BASH_REMATCH[2]}; u="${BASH_REMATCH[1]}${BASH_REMATCH[3]}"; fi
      PROXY_URL=${u%/}; PROXY_SRC=$src
      if [ -n "$ui" ]; then ( umask 077; printf 'proxy-user = "%s"\n' "$ui" > "$PROXY_CFG" ); fi
      if [ ! -s "$PROXY_CFG" ] && [ -r "$ETC/proxy-credentials" ]; then ( umask 077; printf 'proxy-user = "%s"\n' "$(head -1 "$ETC/proxy-credentials")" > "$PROXY_CFG" ); fi
    fi
  fi
  # corporate CA: ADDED to the system store (plain curl --cacert would REPLACE it)
  local ca=${ARG_CA:-${AKV_CA_BUNDLE:-}}; CA_SRC=""
  if [ -n "$ca" ]; then CA_SRC="--ca-file / AKV_CA_BUNDLE"; else ca=$(net_saved CA_FILE); [ -n "$ca" ] && CA_SRC="saved settings"; fi
  if [ -n "$ca" ]; then
    [ -r "$ca" ] || die "$E_USAGE" "CA file $ca is not readable"
    grep -q 'BEGIN CERTIFICATE' "$ca" || die "$E_USAGE" "$ca contains no PEM certificate"
    if grep -q 'PRIVATE KEY' "$ca"; then die "$E_USAGE" "$ca contains a private key: pass only the CA CERTIFICATE"; fi
    EXTRA_CA=$ca
    local sys=/etc/pki/tls/certs/ca-bundle.crt; [ -r "$sys" ] || sys=/etc/ssl/certs/ca-certificates.crt
    cat "$sys" "$ca" > "$RUNTMP/ca.pem"; CA_ARGS=(--cacert "$RUNTMP/ca.pem")
  fi
  if [ -n "$PROXY_URL" ]; then PROXY_ARGS=(--proxy "$PROXY_URL"); if [ -s "$PROXY_CFG" ]; then PROXY_ARGS+=(-K "$PROXY_CFG" --proxy-anyauth); fi
  elif [ "$ARG_NOPROXY" = 1 ]; then PROXY_ARGS=(--noproxy '*'); fi
  local desc="direct connection"; [ -n "$PROXY_URL" ] && desc="proxy $(printf '%s' "$PROXY_URL" | mask) (from $PROXY_SRC)"
  [ -n "$EXTRA_CA" ] && desc="$desc; extra CA added to the system trust store ($CA_SRC)"
  ok "network: $desc"
}
save_network() { # remembered for sudo runs, updates and reruns; non-secret only
  [ "$CMD" = install ] || [ "$CMD" = update ] || return 0
  local want_p=$PROXY_URL want_c=""
  if [ -n "$EXTRA_CA" ]; then install -d -m 0755 "$ETC/ca"; [ "$EXTRA_CA" = "$ETC/ca/extra-ca.pem" ] || install -m 0644 "$EXTRA_CA" "$ETC/ca/extra-ca.pem"; want_c="$ETC/ca/extra-ca.pem"; fi
  [ -n "$want_p$want_c" ] || return 0
  if [ "$(net_saved PROXY_URL)" = "$want_p" ] && [ "$(net_saved CA_FILE)" = "$want_c" ]; then return 0; fi
  install -d -m 0755 "$ETC"
  ( umask 022; printf '# network settings remembered by akvorado-install (no credentials)\nPROXY_URL=%s\nCA_FILE=%s\n' "$want_p" "$want_c" > "$NETENV.new" ) && mv -f "$NETENV.new" "$NETENV"
  ok "network settings saved in $NETENV (reused by every later run, also under sudo)"
}

# credentials are OPTIONAL (public distribution repository); supported for a private mirror
set_token() { # $1 token (not logged) $2 source label
  local t=$1; t=${t//[$'\r\n\t ']/}; t=${t#Bearer}
  [ -n "$t" ] || return 1
  [[ "$t" =~ ^[[:graph:]]{20,4096}$ ]] || die "$E_AUTH" "the token from $2 does not look like a token (no spaces, at least 20 characters); check for a copy/paste error"
  ( umask 077; printf 'header = "Authorization: Bearer %s"\n' "$t" > "$AUTH_HDR" )
  HAVE_TOKEN=1; TOKEN_SOURCE=$2; return 0
}
acquire_token() {
  local t="" f=${TOKEN_FILE_ARG:-${AKV_TOKEN_FILE:-}}
  if [ -n "${AKV_TOKEN_FD:-}" ]; then [[ "$AKV_TOKEN_FD" =~ ^[0-9]+$ ]] || die "$E_USAGE" "AKV_TOKEN_FD must be a file descriptor number"; IFS= read -r t <&"$AKV_TOKEN_FD" || true; set_token "$t" "file descriptor $AKV_TOKEN_FD" && return 0; fi
  if [ -n "$f" ]; then [ -r "$f" ] || die "$E_AUTH" "token file $f is not readable"; IFS= read -r t < "$f" || true; set_token "$t" "token file" && return 0; fi
  return 0
}

# ------------------------------------------------------------------------------------------------------------ HTTP with classification and retries
curl_common() {
  CURL_ARGS=(--proto '=https' --proto-redir '=https' --tlsv1.2 --max-redirs 5 --connect-timeout 20 -sS "${CA_ARGS[@]}" "${PROXY_ARGS[@]}")
  if [ "$HAVE_TOKEN" = 1 ] && [ "$NOAUTH" != 1 ]; then CURL_ARGS+=(-K "$AUTH_HDR"); fi
  return 0
}
tls_rc() { case "$1" in 35|51|53|54|58|59|60|64|66|77|80|82|83|90|91) return 0 ;; esac; return 1; }
transient_rc() { case "$1" in 6|7|18|28|52|55|56) return 0 ;; esac; return 1; }
hdr() { awk -v k="$(printf '%s' "$1" | tr 'A-Z' 'a-z')" 'BEGIN{FS=": *"} {l=tolower($1)} l==k {gsub(/\r/,"",$2); v=$2} END{print v}' "$RUNTMP/headers" 2>/dev/null; }
proxy_code() { sed -nE 's/.*CONNECT tunnel failed, response ([0-9]+).*/\1/p; s/.*HTTP code ([0-9]+) from proxy after CONNECT.*/\1/p' "$RUNTMP/curl.err" 2>/dev/null | head -1 || true; }
cert_issuer() { local px=""; command -v openssl >/dev/null 2>&1 || return 0; [ -n "$PROXY_URL" ] && px="-proxy $(printf '%s' "$PROXY_URL" | sed -E 's#^[a-z0-9]+://##; s#/.*##')"; timeout 15 openssl s_client $px -connect "$1:443" -servername "$1" </dev/null 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null | sed 's/^issuer=//' || true; }
explain_failure() { # $1 context; never returns
  local ctx=$1 body="" pc; pc=$(proxy_code)
  [ -s "$RUNTMP/body" ] && body=$(head -c 300 "$RUNTMP/body" | tr -d '\r' | tr '\n' ' ')
  if [ -n "$pc" ]; then
    case "$pc" in
      407) die "$E_NET" "the PROXY requires authentication (HTTP 407) during: $ctx. Re-run with --proxy http://USER@proxy:port (the password is asked and never stored) or put USER:PASSWORD in $ETC/proxy-credentials (mode 600)." ;;
      403) die "$E_NET" "the proxy REFUSED the tunnel (HTTP 403) during: $ctx. Its policy blocks this host: ask the firewall team to allow ${API_HOST} and ${ASSET_HOST} on 443 (by name)." ;;
      5??) die "$E_SERVER" "the proxy answered HTTP $pc while opening the tunnel during: $ctx (gateway/timeout on the proxy side), still failing after retries. Run the same command again: the download resumes." ;;
      *)   die "$E_NET" "the proxy answered HTTP $pc while opening the tunnel during: $ctx." ;;
    esac
  fi
  if [ "$CURL_RC" -ne 0 ]; then
    if tls_rc "$CURL_RC"; then
      local iss; iss=$(cert_issuer "$API_HOST")
      die "$E_NET" "TLS verification FAILED (curl exit $CURL_RC) during: $ctx. The certificate presented${iss:+ (issued by: $iss)} is not trusted by this host. Behind a TLS-inspecting proxy pass the CA with --ca-file /path/ca.pem (it is ADDED to the system trust store) or install it with update-ca-trust. Verification is never disabled."
    fi
    case "$CURL_RC" in
      5) die "$E_NET" "the proxy host name cannot be resolved (curl exit 5) during: $ctx. Check the proxy address (${PROXY_URL:-none}) and DNS." ;;
      6) die "$E_NET" "DNS cannot resolve the GitHub host (curl exit 6) during: $ctx. If this network needs a proxy, set https_proxy or use --proxy http://host:port." ;;
      7) die "$E_NET" "cannot connect (curl exit 7) during: $ctx. ${PROXY_URL:+Proxy $(printf '%s' "$PROXY_URL" | mask) refused the connection.} Check the address, the port and the firewall." ;;
      28) die "$E_NET" "connection timed out (curl exit 28) during: $ctx." ;;
      *) die "$E_NET" "network failure (curl exit $CURL_RC) during: $ctx. Required: HTTPS (443) to ${API_HOST} and ${ASSET_HOST}, directly or through a proxy." ;;
    esac
  fi
  case "$HTTP_CODE" in
    401) die "$E_AUTH" "HTTP 401 during: $ctx (token invalid or expired)." ;;
    403) die "$E_AUTH" "HTTP 403 during: $ctx. A firewall or proxy may be blocking this request. GitHub said: ${body:-<no body>}" ;;
    404) die "$E_NOTFOUND" "HTTP 404 during: $ctx. The release or asset does not exist (check --version). GitHub said: ${body:-<no body>}" ;;
    429) die "$E_RATE" "HTTP 429 (rate limited) during: $ctx, still limited after retries. Wait a few minutes and run the same command again; the download resumes." ;;
    5??) die "$E_SERVER" "GitHub (or a gateway in between) answered HTTP $HTTP_CODE during: $ctx, still failing after retries. Run the same command again: the download resumes where it stopped." ;;
    *) die "$E_NET" "unexpected HTTP $HTTP_CODE during: $ctx. ${body}" ;;
  esac
}
ask_proxy_credentials() { # HTTP 407 and a terminal: ask once; kept only in the tmpfs config of this run
  { : </dev/tty; } 2>/dev/null || return 1
  local u p; printf 'Proxy username: ' >/dev/tty; IFS= read -r u </dev/tty || return 1; printf 'Proxy password (hidden): ' >/dev/tty; IFS= read -rs p </dev/tty || return 1; printf '\n' >/dev/tty
  [ -n "$u" ] || return 1
  ( umask 077; printf 'proxy-user = "%s:%s"\n' "$u" "$p" > "$PROXY_CFG" ); PROXY_ARGS=(--proxy "$PROXY_URL" -K "$PROXY_CFG" --proxy-anyauth); return 0
}
# http_get <url> <outfile> <context> [curl args...]  retries transient failures; permanent failure -> explain_failure; success codes: $ACCEPT
http_get() {
  local url=$1 out=$2 ctx=$3; shift 3
  local attempt=0 max=${AKV_RETRIES:-6} wait=0 ra="" w pc asked=0 retry rs
  while :; do
    attempt=$((attempt+1)); curl_common
    : > "$RUNTMP/headers"; : > "$RUNTMP/body"; CURL_RC=0
    w=$(curl "${CURL_ARGS[@]}" "$@" -D "$RUNTMP/headers" -o "$out" -w '%{http_code} %{redirect_url}' "$url" 2>"$RUNTMP/curl.err") || CURL_RC=$?
    HTTP_CODE=${w%% *}; HTTP_REDIR=""; [ "$w" != "$HTTP_CODE" ] && HTTP_REDIR=${w#* }
    HTTP_CODE=${HTTP_CODE//[^0-9]/}; HTTP_CODE=${HTTP_CODE:-0}
    if [ "$CURL_RC" -eq 0 ] && [ "$HTTP_CODE" -ge 400 ] 2>/dev/null; then head -c 600 "$out" > "$RUNTMP/body" 2>/dev/null || true; fi
    if [ "$CURL_RC" -eq 0 ] && [[ "$ACCEPT" == *" $HTTP_CODE "* ]]; then return 0; fi
    if [ "$CURL_RC" -eq 33 ]; then return 33; fi
    pc=$(proxy_code)
    if [ "$pc" = 407 ] && [ "$asked" = 0 ]; then asked=1; if ask_proxy_credentials; then continue; fi; fi
    if [ "$pc" = 407 ] || [ "$pc" = 403 ]; then explain_failure "$ctx"; fi
    if [ "$CURL_RC" -ne 0 ] && tls_rc "$CURL_RC"; then explain_failure "$ctx"; fi
    retry=0
    if [ "$CURL_RC" -ne 0 ] && transient_rc "$CURL_RC"; then retry=1; fi
    case "$HTTP_CODE" in 429|500|502|503|504) retry=1 ;; esac
    if [ "$HTTP_CODE" = 403 ] && { [ "$(hdr x-ratelimit-remaining)" = 0 ] || grep -qi 'rate limit' "$RUNTMP/body" 2>/dev/null; }; then retry=1; fi
    if [ "$retry" = 0 ] || [ "$attempt" -ge "$max" ]; then explain_failure "$ctx"; fi
    ra=$(hdr retry-after || true)
    if [[ "$ra" =~ ^[0-9]+$ ]]; then wait=$ra; else wait=$(( 2 ** attempt )); fi
    if [ "$HTTP_CODE" = 403 ]; then rs=$(hdr x-ratelimit-reset || true); [[ "$rs" =~ ^[0-9]+$ ]] && wait=$(( rs - $(date +%s) + 2 )); fi
    [ "$wait" -gt "${AKV_MAX_WAIT:-120}" ] && wait=${AKV_MAX_WAIT:-120}
    [ "$wait" -lt 1 ] && wait=1
    warn "attempt $attempt/$max failed (${CURL_RC:+curl $CURL_RC, }HTTP $HTTP_CODE) during: $ctx - retrying in ${wait}s"
    sleep "$wait"
  done
}

# ------------------------------------------------------------------------------------------------------------ release metadata
json_release() {
  python3 -I - "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print("TAG\t%s\t%s\t%s" % (d.get("tag_name", ""), str(d.get("prerelease")).lower(), str(d.get("draft")).lower()))
for a in d.get("assets", []):
    print("ASSET\t%s\t%s\t%s\t%s\t%s" % (a["name"], a["id"], a["size"], a.get("digest") or "-", a.get("state", "")))
PY
}
json_manifest() {
  python3 -I - "$1" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
assert m.get("schema") == 1, "unsupported manifest schema"
print("VERSION\t%s" % m["version"])
print("UNPACKED\t%d" % m.get("images_unpacked_bytes", 0))
print("IMAGES_SHA\t%s" % m["images_archive"]["sha256"])
for p in m["images_archive"]["parts"]:
    print("IMGPART\t%s" % p)
for a in m["assets"]:
    print("ASSET\t%s\t%d\t%s" % (a["name"], a["size"], a["sha256"]))
c = m.get("compat", {})
print("UPGRADE_FROM\t%s" % " ".join(c.get("upgrade_from", [])))
print("SCHEMA_CHANGE\t%s" % str(c.get("schema_change", False)).lower())
print("INSTALLER_SHA\t%s" % m.get("installer_sha256", ""))
PY
}
installed_version() { { [ -r "$ETC/release.json" ] && python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1])).get("platform_version",""))' "$ETC/release.json" 2>/dev/null; } || true; }

declare -A A_ID A_SIZE A_DIGEST M_SIZE M_SHA
M_ASSETS=(); IMG_PARTS=(); REL_TAG=""; REL_VER=""; REL_PRE=false; M_VERSION=""; M_UNPACKED=0; M_IMAGES_SHA=""; M_UPGRADE_FROM=""; M_SCHEMA_CHANGE=false; M_INSTALLER_SHA=""

resolve_release() {
  local url ver=${WANT_VERSION:-}
  if [ -z "$ver" ]; then if [ "$CMD" = update ]; then url="$API_BASE/repos/$AKV_REPO/releases/latest"; else ver=$AKV_VERSION_DEFAULT; fi; fi
  [ -n "$ver" ] && url="$API_BASE/repos/$AKV_REPO/releases/tags/v$ver"
  step "Release metadata (${url#"$API_BASE"})"
  ACCEPT=" 200 "; http_get "$url" "$RUNTMP/release.json" "release lookup" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28"
  local kind a b c d e
  A_ID=(); A_SIZE=(); A_DIGEST=()
  while IFS=$'\t' read -r kind a b c d e; do
    case "$kind" in
      TAG) REL_TAG=$a; REL_PRE=$b; [ "$c" = true ] && die "$E_NOTFOUND" "release $a is a draft: drafts are never installed" ;;
      ASSET) [ "$e" = uploaded ] || { [ -z "$e" ] || die "$E_INCOMPLETE" "asset $a is in state '$e' (upload not finished): the release is incomplete"; }
             A_ID[$a]=$b; A_SIZE[$a]=$c; A_DIGEST[$a]=$d ;;
    esac
  done < <(json_release "$RUNTMP/release.json")
  [ -n "$REL_TAG" ] || die "$E_NOTFOUND" "release lookup returned no tag"
  REL_VER=${REL_TAG#v}
  [ "$REL_PRE" = true ] && warn "release $REL_TAG is marked PRE-RELEASE (release candidate)"
  ok "release $REL_TAG with ${#A_ID[@]} assets"
}
download_small() {
  local n=$1 dest=$2
  [ -n "${A_ID[$n]:-}" ] || die "$E_INCOMPLETE" "the release has no asset named '$n' (incomplete release; the installer cannot continue)"
  ACCEPT=" 200 206 "; http_get "$API_BASE/repos/$AKV_REPO/releases/assets/${A_ID[$n]}" "$dest" "download of $n" -L -H "Accept: application/octet-stream"
}
sha_of() { sha256sum "$1" | awk '{print $1}'; }

load_manifest() {
  step "Manifest and checksums"
  download_small SHA256SUMS "$RUNTMP/SHA256SUMS"
  download_small manifest.json "$RUNTMP/manifest.json"
  local n d
  for n in SHA256SUMS manifest.json; do
    d=${A_DIGEST[$n]:-"-"}
    if [ "$d" != "-" ]; then [ "sha256:$(sha_of "$RUNTMP/$n")" = "$d" ] || die "$E_INTEGRITY" "$n does not match GitHub's recorded digest ($d): refusing to continue"; fi
  done
  local want; want=$(awk '$2=="manifest.json" || $2=="*manifest.json" {print $1}' "$RUNTMP/SHA256SUMS")
  [ -n "$want" ] && [ "$want" = "$(sha_of "$RUNTMP/manifest.json")" ] || die "$E_INTEGRITY" "manifest.json is not covered by / does not match SHA256SUMS"
  # the manifest checksum is pinned INSIDE this installer, which the release tag (protected, immutable) pins: the chain no longer depends on mutable release assets
  if [ "${MANIFEST_SHA256:0:2}" != "@@" ] && [ "$REL_VER" = "$AKV_VERSION_DEFAULT" ]; then
    [ "$(sha_of "$RUNTMP/manifest.json")" = "$MANIFEST_SHA256" ] || die "$E_INTEGRITY" "manifest.json does not match the checksum pinned inside this installer: refusing to continue (the release may have been altered)"
    ok "manifest matches the checksum pinned in this installer"
  else
    warn "the manifest checksum is not pinned for this release (a different or development version): relying on TLS, SHA256SUMS and GitHub's own digests"
  fi
  local kind a b c
  M_ASSETS=(); IMG_PARTS=()
  while IFS=$'\t' read -r kind a b c; do
    case "$kind" in
      VERSION) M_VERSION=$a ;; UNPACKED) M_UNPACKED=$a ;; IMAGES_SHA) M_IMAGES_SHA=$a ;; IMGPART) IMG_PARTS+=("$a") ;;
      UPGRADE_FROM) M_UPGRADE_FROM=$a ;; SCHEMA_CHANGE) M_SCHEMA_CHANGE=$a ;; INSTALLER_SHA) M_INSTALLER_SHA=$a ;;
      ASSET) M_ASSETS+=("$a"); M_SIZE[$a]=$b; M_SHA[$a]=$c ;;
    esac
  done < <(json_manifest "$RUNTMP/manifest.json")
  [ "$M_VERSION" = "$REL_VER" ] || die "$E_INTEGRITY" "manifest version '$M_VERSION' does not match the release tag '$REL_TAG'"
  if [ -n "$M_INSTALLER_SHA" ] && [ -n "$SELF_SRC" ]; then
    [ "$(printf '%s' "$SELF_SRC" | sha256sum | awk '{print $1}')" = "$M_INSTALLER_SHA" ] || warn "this installer is not the exact one recorded in the release manifest (another revision); every asset is still verified against the manifest"
  fi
  local missing=() bad=() sum
  for n in "${M_ASSETS[@]}"; do
    if [ -z "${A_ID[$n]:-}" ]; then missing+=("$n"); continue; fi
    [ "${A_SIZE[$n]}" = "${M_SIZE[$n]}" ] || bad+=("$n (size ${A_SIZE[$n]} != ${M_SIZE[$n]})")
    sum=$(awk -v f="$n" '$2==f || $2=="*"f {print $1}' "$RUNTMP/SHA256SUMS")
    [ "$sum" = "${M_SHA[$n]}" ] || bad+=("$n (SHA256SUMS disagrees with the manifest)")
    d=${A_DIGEST[$n]:-"-"}; [ "$d" = "-" ] || [ "$d" = "sha256:${M_SHA[$n]}" ] || bad+=("$n (GitHub digest $d disagrees)")
  done
  [ "${#missing[@]}" -eq 0 ] || die "$E_INCOMPLETE" "the release is INCOMPLETE; missing assets: ${missing[*]}"
  [ "${#bad[@]}" -eq 0 ] || die "$E_INTEGRITY" "release metadata is inconsistent: ${bad[*]}"
  ok "manifest for $M_VERSION: ${#M_ASSETS[@]} assets, all present, sizes and SHA-256 consistent (manifest = SHA256SUMS = GitHub digest)"
}

# ------------------------------------------------------------------------------------------------------------ disk space
avail_bytes() { local p=$1; while [ ! -e "$p" ] && [ "$p" != / ]; do p=$(dirname "$p"); done; df -P -B1 "$p" | awk 'NR==2 {print $4}'; }
fs_id() { local p=$1; while [ ! -e "$p" ] && [ "$p" != / ]; do p=$(dirname "$p"); done; stat -c %d "$p"; }
human() { awk -v b="$1" 'BEGIN{printf "%.1f GiB", b/1073741824}'; }
mib() { awk -v b="$1" 'BEGIN{printf "%.0f MiB", b/1048576}'; }
check_space() {
  step "Disk space"
  local total=0 n dockerdir=/var/lib/docker
  for n in "${M_ASSETS[@]}"; do total=$(( total + M_SIZE[$n] )); done
  local stage_need=$(( total + total / 5 + 536870912 )) docker_need=$(( M_UNPACKED + M_UNPACKED / 4 + 1073741824 ))
  [ -d "$dockerdir" ] || dockerdir=/var/lib
  local sa da; sa=$(avail_bytes "$STAGING_ROOT"); da=$(avail_bytes "$dockerdir")
  if [ "$(fs_id "$STAGING_ROOT")" = "$(fs_id "$dockerdir")" ]; then
    local both=$(( stage_need + docker_need ))
    [ "$sa" -ge "$both" ] || die "$E_SPACE" "insufficient disk space: $(human "$both") needed on the filesystem holding $STAGING_ROOT and $dockerdir (downloads $(human "$stage_need") + unpacked images $(human "$docker_need")), $(human "$sa") available"
    ok "free space $(human "$sa") >= required $(human "$both")"
  else
    [ "$sa" -ge "$stage_need" ] || die "$E_SPACE" "insufficient disk space on $STAGING_ROOT: $(human "$stage_need") needed, $(human "$sa") available"
    [ "$da" -ge "$docker_need" ] || die "$E_SPACE" "insufficient disk space on $dockerdir: $(human "$docker_need") needed for the container images, $(human "$da") available"
    ok "free space: staging $(human "$sa") >= $(human "$stage_need"); images $(human "$da") >= $(human "$docker_need")"
  fi
}

# ------------------------------------------------------------------------------------------------------------ downloads: ranged chunks, resumable, verified
CHUNK=$(( ${AKV_CHUNK_BYTES:-$(( ${AKV_CHUNK_MIB:-16} * 1048576 ))} ))
AURL=""
resolve_asset_url() { # the signed, short-lived URL of the asset bytes (no token is ever sent to the storage host)
  local n=$1
  ACCEPT=" 301 302 303 307 308 "; NOAUTH=0
  http_get "$API_BASE/repos/$AKV_REPO/releases/assets/${A_ID[$n]}" "$RUNTMP/redir.body" "download request for $n" -H "Accept: application/octet-stream"
  ACCEPT=" 200 206 "
  [ -n "$HTTP_REDIR" ] || die "$E_NET" "GitHub did not return a download location for $n (HTTP $HTTP_CODE)"
  AURL=$HTTP_REDIR
  case "$AURL" in https://*) ;; *) die "$E_NET" "refusing a non-HTTPS download location for $n" ;; esac
}
# chunk_get <url> <first> <last> <out>  -> 0 ok | 1 retry | 2 URL expired | 3 Range ignored | 4 re-encoded | 5 inconsistent
chunk_get() {
  local url=$1 a=$2 b=$3 out=$4 want code cr ce got
  want=$(( b - a + 1 ))
  NOAUTH=1; curl_common; NOAUTH=0
  : > "$RUNTMP/headers"; CURL_RC=0
  code=$(curl "${CURL_ARGS[@]}" --max-time "${AKV_CHUNK_TIMEOUT:-300}" --speed-time 30 --speed-limit 1024 -H 'Accept-Encoding: identity' -r "$a-$b" -D "$RUNTMP/headers" -o "$out" -w '%{http_code}' "$url" 2>"$RUNTMP/curl.err") || CURL_RC=$?
  HTTP_CODE=${code//[^0-9]/}; HTTP_CODE=${HTTP_CODE:-0}
  if [ "$CURL_RC" -ne 0 ]; then return 1; fi
  case "$HTTP_CODE" in
    206) ;;
    200) return 3 ;;
    400|401|403) return 2 ;;
    416) return 5 ;;
    *) return 1 ;;
  esac
  ce=$(hdr content-encoding); if [ -n "$ce" ] && [ "$ce" != identity ]; then return 4; fi
  cr=$(hdr content-range)
  [[ "$cr" =~ ^bytes\ ([0-9]+)-([0-9]+)/([0-9]+)$ ]] || return 5
  if [ "${BASH_REMATCH[1]}" != "$a" ] || [ "${BASH_REMATCH[2]}" != "$b" ]; then return 5; fi
  CR_TOTAL=${BASH_REMATCH[3]}
  got=$(stat -c %s "$out" 2>/dev/null || echo 0); [ "$got" = "$want" ] || return 1
  return 0
}
fetch_asset_stream() { # explicit fallback for a path that ignores Range: whole asset, resumable with -C -
  local n=$1 dir=$2 size=${M_SIZE[$1]} part="$dir/.$1.part" got attempt=0 rc
  while :; do
    attempt=$((attempt+1)); rc=0
    ACCEPT=" 200 206 "; http_get "$API_BASE/repos/$AKV_REPO/releases/assets/${A_ID[$n]}" "$part" "download of $n (stream mode)" -L -H "Accept: application/octet-stream" -C - || rc=$?
    if [ "$rc" = 33 ]; then rm -f "$part"; continue; fi
    got=$(stat -c %s "$part" 2>/dev/null || echo 0)
    if [ "$got" -lt "$size" ]; then [ "$attempt" -ge 12 ] && die "$E_NET" "download of $n keeps stopping early"; warn "$n incomplete ($got of $size bytes): resuming"; continue; fi
    return 0
  done
}
fetch_asset() { # <name> <dest dir>: idempotent; a partial file is continued at the last verified chunk boundary
  local n=$1 dir=$2 want=${M_SHA[$1]} size=${M_SIZE[$1]} part final okf got off last try rc t0 next_pct=10 pct att=0 rec base resolves el pc
  final="$dir/$n"; part="$dir/.$n.part"; okf="$dir/.$n.ok"
  if [ -f "$final" ] && [ "$(stat -c %s "$final")" = "$size" ] && [ "$(sha_of "$final")" = "$want" ]; then ok "$n already downloaded and verified"; return 0; fi
  rm -f "$final"
  while :; do
    att=$((att+1))
    if [ "$ALLOW_STREAM" = 1 ]; then fetch_asset_stream "$n" "$dir"
    else
      off=0; [ -f "$part" ] && off=$(stat -c %s "$part")
      rec=0; [ -f "$okf" ] && rec=$(cat "$okf" 2>/dev/null || echo 0); [[ "$rec" =~ ^[0-9]+$ ]] || rec=0
      if [ "$off" -gt "$rec" ]; then truncate -s "$rec" "$part" 2>/dev/null || rm -f "$part"; off=$rec; fi      # drop a chunk that was being appended when we stopped
      if [ "$off" -gt "$size" ]; then rm -f "$part" "$okf"; off=0; fi
      [ "$off" -gt 0 ] && say "  resuming $n at $(mib "$off") of $(mib "$size")"
      resolve_asset_url "$n"; t0=$(date +%s); base=$off; resolves=0; next_pct=$(( off * 100 / size / 10 * 10 + 10 ))
      while [ "$off" -lt "$size" ]; do
        last=$(( off + CHUNK - 1 )); [ "$last" -ge "$size" ] && last=$((size - 1))
        try=0
        while :; do
          try=$((try+1)); rc=0; chunk_get "$AURL" "$off" "$last" "$RUNTMP/chunk" || rc=$?
          [ "$rc" = 0 ] && break
          case "$rc" in
            2) resolves=$((resolves+1)); [ "$resolves" -gt 8 ] && die "$E_NET" "the signed download URL for $n keeps being refused (HTTP $HTTP_CODE)"; resolve_asset_url "$n"; continue ;;
            3) die "$E_RANGE" "this network path IGNORES HTTP Range (HTTP 200 for a ranged request on $n). Chunked, resumable download is not possible through it. Ask the proxy team to disable download buffering/AV scanning for ${ASSET_HOST}, or re-run with --allow-stream (whole-file download, still verified; it may fail on large files behind this proxy)." ;;
            4) die "$E_RANGE" "the network path RE-ENCODED the response of $n (Content-Encoding: $(hdr content-encoding)): refusing to store modified bytes. Exempt ${ASSET_HOST} from content modification." ;;
            5) die "$E_INTEGRITY" "inconsistent ranged response for $n at offset $off (bad Content-Range, changed size or HTTP 416): refusing to continue" ;;
            *) pc=$(proxy_code)
               if [ "$pc" = 407 ] || [ "$pc" = 403 ]; then explain_failure "ranged download of $n"; fi
               if [ "$CURL_RC" -ne 0 ] && tls_rc "$CURL_RC"; then explain_failure "ranged download of $n"; fi
               if [ "$try" -ge "${AKV_CHUNK_RETRIES:-6}" ]; then explain_failure "ranged download of $n at $(mib "$off") (everything before it is kept and resumes)"; fi
               warn "chunk at $(mib "$off") of $n failed (${CURL_RC:+curl $CURL_RC, }HTTP $HTTP_CODE), attempt $try/${AKV_CHUNK_RETRIES:-6} - retrying in $(( 2 ** try ))s"; sleep $(( 2 ** try )) ;;
          esac
        done
        cat "$RUNTMP/chunk" >> "$part"; off=$((last + 1)); printf '%s' "$off" > "$okf.new"; mv -f "$okf.new" "$okf"
        pct=$(( off * 100 / size ))
        if [ "$pct" -ge "$next_pct" ] || [ "$off" -ge "$size" ]; then
          el=$(( $(date +%s) - t0 )); [ "$el" -lt 1 ] && el=1
          say "  [$(now)] $n: $(mib "$off") / $(mib "$size") (${pct}%) $(awk -v b=$(( off - base )) -v t="$el" 'BEGIN{printf "%.1f", b/1048576/t}') MiB/s"; next_pct=$(( pct / 10 * 10 + 10 ))
        fi
      done
    fi
    got=$(stat -c %s "$part" 2>/dev/null || echo 0)
    if [ "$got" != "$size" ]; then rm -f "$part" "$okf"; [ "$att" -ge 3 ] && die "$E_INTEGRITY" "$n has $got bytes, expected $size"; continue; fi
    if [ "$(sha_of "$part")" != "$want" ]; then
      rm -f "$part" "$okf"
      [ "$att" -ge 2 ] && die "$E_INTEGRITY" "CHECKSUM MISMATCH for $n (expected $want): the download was corrupted or tampered with; it was discarded twice"
      warn "checksum mismatch for $n: discarding and downloading again"; continue
    fi
    mv -f "$part" "$final"; rm -f "$okf"; ok "$n ($(mib "$size")) verified"; return 0
  done
}

# ------------------------------------------------------------------------------------------------------------ staging and hand-off
STAGE=""; REL_DIR=""; BUNDLE=""
unsafe_tar() { tar -tzf "$1" | grep -Eq '(^|/)\.\.(/|$)|^/' ; }
stage_release() {
  STAGE="$STAGING_ROOT/$REL_VER"
  install -d -m 0700 "$STAGING_ROOT" "$STAGE" "$STAGE/dl"
  step "Downloading $REL_TAG into $STAGE ($(( CHUNK / 1048576 )) MiB ranged chunks, resumable; nothing else on the host is touched)"
  local n
  for n in "${M_ASSETS[@]}"; do fetch_asset "$n" "$STAGE/dl"; done
  step "Verifying and unpacking"
  local sum; sum=$(cat "${IMG_PARTS[@]/#/$STAGE/dl/}" | sha256sum | awk '{print $1}')
  [ "$sum" = "$M_IMAGES_SHA" ] || die "$E_INTEGRITY" "the reassembled container image archive has SHA-256 $sum, the manifest says $M_IMAGES_SHA"
  ok "container image archive: ${#IMG_PARTS[@]} parts reassemble to the expected SHA-256"
  rm -rf "$STAGE/release" "$STAGE/bundle"; mkdir -p "$STAGE/release" "$STAGE/bundle/images" "$STAGE/bundle/rpm-repo"
  local tree="$STAGE/dl/akvorado-platform-$REL_VER.tar.gz" rpmr="$STAGE/dl/akvorado-platform-$REL_VER-rpm-repo.tar.gz"
  for n in "$tree" "$rpmr"; do [ -f "$n" ] || die "$E_INCOMPLETE" "expected asset $(basename "$n") is missing from the manifest"; if unsafe_tar "$n"; then die "$E_INTEGRITY" "$(basename "$n") contains absolute or parent-relative paths: refusing to unpack"; fi; done
  tar -xzf "$tree" -C "$STAGE/release" --strip-components=1 --no-same-owner
  tar -xzf "$rpmr" -C "$STAGE/bundle/rpm-repo" --no-same-owner
  for n in "${IMG_PARTS[@]}"; do ln -f "$STAGE/dl/$n" "$STAGE/bundle/images/$n" 2>/dev/null || cp -f "$STAGE/dl/$n" "$STAGE/bundle/images/$n"; done
  cp -f "$RUNTMP/manifest.json" "$STAGE/bundle/manifest.json"; cp -f "$RUNTMP/SHA256SUMS" "$STAGE/bundle/SHA256SUMS"
  REL_DIR="$STAGE/release"; BUNDLE="$STAGE/bundle"
  [ -x "$REL_DIR/bin/akvorado-platform" ] || chmod 0755 "$REL_DIR/bin/akvorado-platform" 2>/dev/null || true
  [ "$(cat "$REL_DIR/VERSION" 2>/dev/null)" = "$REL_VER" ] || die "$E_INTEGRITY" "the release tree says version '$(cat "$REL_DIR/VERSION" 2>/dev/null)', the release is $REL_VER"
  ok "release tree $REL_VER and offline bundle ready"
}

# ------------------------------------------------------------------------------------------------------------ first-run settings: detect everything, ask only what cannot be known
tty_ok() { [ "${AKV_NO_PROMPT:-0}" != 1 ] && { : </dev/tty; } 2>/dev/null; }
ask() { local a; printf '%s [%s]: ' "$1" "$2" >/dev/tty; IFS= read -r a </dev/tty || a=""; printf '%s' "${a:-$2}"; }
host_ip() { local d; d=$(ip -4 -o route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1); [ -n "$d" ] && ip -4 -o addr show dev "$d" 2>/dev/null | awk '{print $4}' | head -1; }
valid_cidrs() { local c; for c in $1; do [[ "$c" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]] || return 1; done; [ -n "$1" ]; }
data_candidates() { df -BG -x tmpfs -x devtmpfs -x squashfs --output=target,avail 2>/dev/null | awk 'NR>1 && $1!="/" && $1!="/boot" && $1!~"^/boot/" && $1!="/home" && $1!~"^/run" && $1!~"^/var/lib/docker" && $2+0>=30 {print $1}'; }
ensure_env_file() { # creates platform.env (+ self-signed certificate, SNMP secret, static exporter file) when it does not exist yet
  ENVF=${ENV_FILE_ARG:-$ETC/platform.env}
  [ -f "$ENVF" ] && return 0
  [ -n "$ENV_FILE_ARG" ] && die "$E_USAGE" "environment file $ENV_FILE_ARG does not exist"
  local cidr ipc ip_only dom flow web data cands n snmp="" cert key c fl=""
  ipc=$(host_ip || true); ip_only=${ipc%/*}
  dom=$(hostname -f 2>/dev/null || true); case "$dom" in *.*) ;; *) dom=${ip_only:-$(hostname)} ;; esac
  flow=${ARG_FLOW:-}; web=${ARG_WEB:-}; data=${ARG_DATA:-}
  if [ -z "$web" ] && [ -n "$ipc" ]; then web=$(python3 -I -c 'import ipaddress,sys;print(ipaddress.ip_interface(sys.argv[1]).network)' "$ipc" 2>/dev/null || true); fi
  if [ -z "$data" ]; then
    if mountpoint -q /data/netflow 2>/dev/null; then data=/data/netflow
    else cands=$(data_candidates); n=$(printf '%s\n' "$cands" | grep -c . || true)
      if [ "$n" = 1 ]; then data=$cands
      elif [ "$n" -gt 1 ]; then data=$(printf '%s\n' "$cands" | head -1); warn "several volumes could hold the data; using $data (override with --data-dir)"
      else SAFE_MSG=""; die "$E_NEEDS_CONFIG" "no dedicated data volume found: mount a volume with at least 100 GiB (XFS recommended) and run the same command again, or pass --data-dir <mount point>. The installer never formats a disk."; fi
    fi
  fi
  if tty_ok; then
    say ""; say "First-run setup: only what cannot be detected is asked. Press Enter to accept the value in brackets."
    [ -z "$flow" ] && flow=$(ask "IP address(es) of the router(s) that will send NetFlow (space separated)" "")
    web=$(ask "Networks allowed to open the web UI" "${web:-${ip_only:-10.0.0.1}/32}")
    printf 'SNMP read-only community of the router (Enter = none; interface names are then set later): ' >/dev/tty; IFS= read -rs c </dev/tty || c=""; printf '\n' >/dev/tty; snmp=$c
  fi
  [ -n "$flow" ] || { SAFE_MSG=""; die "$E_NEEDS_CONFIG" "the router address(es) that send NetFlow are required: run interactively (a terminal) or pass --flow-from 'IP IP'"; }
  for cidr in $flow; do [[ "$cidr" == */* ]] || cidr="$cidr/32"; fl="$fl $cidr"; done; flow=${fl# }
  valid_cidrs "$flow" || die "$E_USAGE" "invalid router address list: $flow"
  valid_cidrs "$web" || die "$E_USAGE" "invalid web network list: $web"
  install -d -m 0755 "$ETC" "$ETC/tls" "$ETC/site"; install -d -m 0700 "$ETC/secrets"
  cert="$ETC/tls/netflow.crt"; key="$ETC/tls/netflow.key"
  if [ ! -s "$cert" ]; then
    command -v openssl >/dev/null 2>&1 || die "$E_PREREQ" "openssl is required to create the web UI certificate"
    ( umask 077; openssl req -x509 -newkey rsa:3072 -nodes -days 825 -keyout "$key" -out "$cert" -subj "/CN=$dom" -addext "subjectAltName=DNS:$dom${ip_only:+,IP:$ip_only}" 2>/dev/null ) && chmod 0644 "$cert" && ok "self-signed web UI certificate created for $dom (replace it later with your own if you prefer)"
  fi
  cp "$REL_DIR/env/production.env.example" "$ENVF.new"
  setv() { sed -i "s|^$1=.*|$1=$2|" "$ENVF.new"; }
  setv NETFLOW_DOMAIN "$dom"; setv NETFLOW_DATA_DIR "$data"; setv WEB_ALLOWED_CIDRS "\"$web\""; setv FLOW_ALLOWED_CIDRS "\"$flow\""
  setv NETFLOW_TLS_CERT_FILE "$cert"; setv NETFLOW_TLS_KEY_FILE "$key"; setv NETFLOW_TLS_CA_FILE "$cert"
  setv CH_GRAFANA_ENABLE no; setv PACKAGE_SOURCE bundle
  if [ -n "$snmp" ]; then
    [[ "$snmp" =~ ^[A-Za-z0-9._@%+=:-]{6,64}$ ]] || die "$E_USAGE" "the SNMP community must be 6-64 characters of [A-Za-z0-9._@%+=:-]"
    ( umask 077; printf '%s\n' "$snmp" > "$ETC/secrets/snmp-community" ); setv SNMP_ENABLED yes
  else
    setv SNMP_ENABLED no
    if [ ! -s "$ETC/site/exporters-static.yaml" ]; then
      { echo '---'; for cidr in $flow; do printf '%s:\n  name: router-%s\n  default: {name: ifindex-unmapped, description: "interface not named yet: edit this file", speed: 1000}\n' "$cidr" "${cidr%/*}"; done; } > "$ETC/site/exporters-static.yaml"
    fi
  fi
  chmod 0640 "$ENVF.new"; mv -f "$ENVF.new" "$ENVF"
  ok "settings written to $ENVF (reused by every later run; edit it to change anything)"
}

handoff() {
  local env_args=() out_rc=0
  ensure_env_file
  step "Platform pre-flight (read-only)"
  env_args=(--env-file "$ENVF" --package-source bundle --bundle-dir "$BUNDLE")
  "$REL_DIR/bin/akvorado-platform" preflight "${env_args[@]}" || out_rc=$?
  if [ "$out_rc" -ne 0 ]; then
    SAFE_MSG=""
    say ""; say "Pre-flight found problems (marked FAIL above). Nothing was installed or changed on this host."
    say "Fix the FAIL items (settings file: $ENVF), then run the SAME command again. Verified downloads in $STAGE are reused; nothing is downloaded twice."
    exit "$E_NEEDS_CONFIG"
  fi
  case "$CMD" in
    install) step "Installing"; "$REL_DIR/bin/akvorado-platform" install "${env_args[@]}" || die "$E_PLATFORM" "platform installation failed (see the report above and $LOGDIR/). The installation is idempotent: fix the cause and run the same command again." ;;
    update)  step "Upgrading"; "$REL_DIR/bin/akvorado-platform" upgrade --yes "${env_args[@]}" || die "$E_PLATFORM" "the upgrade did not complete; if it rolled back automatically the previous version is running again (akvorado-install health). Details: $LOGDIR/" ;;
  esac
  # keep THIS installer (the running copy) as the stable entry point, so its fixes survive updates of the platform tree
  if [ -n "$SELF_SRC" ] && [ -n "${BASH_EXECUTION_STRING:-}" ]; then printf '%s\n' "$SELF_SRC" > "$SELF_INSTALL.new" && chmod 0755 "$SELF_INSTALL.new" && mv -f "$SELF_INSTALL.new" "$SELF_INSTALL" || warn "could not install $SELF_INSTALL"
  elif [ -r "$0" ]; then install -m 0755 "$0" "$SELF_INSTALL" 2>/dev/null || warn "could not install $SELF_INSTALL"
  else install -m 0755 "$REL_DIR/bootstrap/akvorado-install" "$SELF_INSTALL" 2>/dev/null || warn "could not install $SELF_INSTALL"; fi
  rm -rf "$STAGE/dl" "$STAGE/bundle/images" 2>/dev/null || true
  step "Done"
  "$REL_DIR/bin/akvorado-platform" status || true
  say ""; say "Health check:   akvorado-install health"
  say "Update:         akvorado-install update"
  say "Rollback:       akvorado-install rollback"
}

# ------------------------------------------------------------------------------------------------------------ check (read-only): the preflight of this release, fetched from the same immutable tag
run_check() {
  step "Readiness check (read-only): fetching the preflight of this release"
  local f="$RUNTMP/preflight.sh" ver=${WANT_VERSION:-$AKV_VERSION_DEFAULT}
  ACCEPT=" 200 "; http_get "$API_BASE/repos/$AKV_REPO/contents/preflight?ref=v$ver" "$f" "download of the preflight script" -H "Accept: application/vnd.github.raw"
  if [ "${PREFLIGHT_SHA256:0:2}" = "@@" ]; then warn "preflight checksum is not stamped in this installer (development copy)"
  else [ "$(sha_of "$f")" = "$PREFLIGHT_SHA256" ] || die "$E_INTEGRITY" "the preflight script does not match the checksum stamped in this installer: not running it"; fi
  ok "preflight fetched and verified"
  AKV_REPO="$AKV_REPO" AKV_VERSION="$ver" AKV_CA="${EXTRA_CA:-}" https_proxy="${PROXY_URL:-}" AKV_NO_PROMPT=1 bash "$f" || true
}

# ------------------------------------------------------------------------------------------------------------ commands
local_platform() { [ -x /usr/local/sbin/akvorado-platform ] || die "$E_PREREQ" "akvorado-platform is not installed on this host (run: akvorado-install install)"; echo /usr/local/sbin/akvorado-platform; }

main() {
  self_source; parse_args "$@"
  local ap a cur
  case "$CMD" in
    version) say "akvorado-install revision $AKV_INSTALLER_REV (default release $AKV_VERSION_DEFAULT, repository $AKV_REPO)"; exit 0 ;;
    rollback) need_root; ap=$(local_platform); a=(--yes); [ "$WITH_DATA" = 1 ] && a+=(--with-data); exec "$ap" rollback "${a[@]}" ;;
    health)   need_root; ap=$(local_platform); "$ap" verify; exec "$ap" status ;;
  esac
  if [ "$CMD" = check ]; then   # read-only and needs no root: it runs as the calling user, so that user's proxy settings apply as they are
    check_tools; setup_test_mode; make_runtmp; resolve_network; acquire_token; run_check; exit 0
  fi
  need_root; check_tools; setup_test_mode; check_os
  mkdir -p "$LOGDIR"; chmod 750 "$LOGDIR"
  # only one installer at a time: two runs appending to the same staged files (or installing together) would corrupt each other
  install -d -m 0700 "$STAGING_ROOT"; exec 200>"$STAGING_ROOT/.lock"
  if command -v flock >/dev/null 2>&1; then flock -n 200 || die "$E_BUSY" "another akvorado-install is already running on this host (it holds $STAGING_ROOT/.lock). Wait for it to finish, or stop it, then run the same command again."; fi
  exec > >(tee -a "$LOGDIR/akvorado-install-$(date +%Y%m%d-%H%M%S).log") 2>&1
  make_runtmp; resolve_network; acquire_token
  [ "$HAVE_TOKEN" = 1 ] && ok "credentials: token from $TOKEN_SOURCE (tmpfs only, never in a command line or log)"
  resolve_release
  cur=$(installed_version)
  case "$CMD" in
    install) if [ -n "$cur" ] && [ "$cur" != "$REL_VER" ]; then die "$E_USAGE" "release $cur is already installed; use 'akvorado-install update' to move to $REL_VER (install never changes the version of a managed installation)"; fi ;;
    update)  if [ -n "$cur" ] && [ "$cur" = "$REL_VER" ]; then ok "already running $cur - nothing to do"; exit 0; fi
             [ -n "$cur" ] || die "$E_USAGE" "no managed installation found: use 'akvorado-install install'" ;;
  esac
  load_manifest
  if [ "$CMD" = update ]; then
    case " $M_UPGRADE_FROM " in *" $cur "*) ok "upgrade path $cur -> $REL_VER is supported (schema change: $M_SCHEMA_CHANGE)" ;; *) die "$E_USAGE" "upgrading from $cur to $REL_VER is not a supported path (supported sources: ${M_UPGRADE_FROM:-none}). Nothing was changed." ;; esac
  fi
  check_space
  mkdir -p "$STAGING_ROOT"; chmod 0700 "$STAGING_ROOT" 2>/dev/null || true
  stage_release
  save_network
  if [ "${AKV_TEST_MODE:-0}" = 1 ] && [ "${AKV_STAGE_ONLY:-0}" = 1 ]; then ok "test mode: staged $REL_VER, stopping before the platform hand-off"; exit 0; fi
  handoff
}
main "$@"
