#!/usr/bin/env bash
# Run as root in an isolated Linux environment. No system services are changed.
set -Eeuo pipefail

MODULE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../lib" && pwd)
(( EUID == 0 )) || { printf 'Run these filesystem/worker tests as root.\n' >&2; exit 1; }
TEST_ROOT=$(mktemp -d /tmp/reality-site-web-test.XXXXXX)
NGINX_BIN=${TEST_NGINX_BIN:-/usr/sbin/nginx}
DATA_DIR=$TEST_ROOT/data
APP_DIR=$TEST_ROOT/app
STATE_FILE=$DATA_DIR/state.json
RS_UNIT_DIR=$TEST_ROOT/units
DOMAIN=site.example.test
PORT=18003
WEB_MODE=static
REDIRECT_URL=
VERSION=1.3.0
CERT_MODE=manual
ACME_EMAIL=
SERVICE_NAME=reality-site.service
TMP_DIR=$TEST_ROOT/tmp
PASSED=0
NGINX_TEST_STARTED=0
RS_MODE_PENDING=0

if [[ -n ${TEST_JQ_BIN:-} ]]; then jq() { "$TEST_JQ_BIN" "$@"; }; fi
command -v jq >/dev/null || { printf 'jq is required.\n' >&2; exit 1; }

# shellcheck source=../lib/common.sh
source "$MODULE_DIR/common.sh"
# shellcheck source=../lib/web.sh
source "$MODULE_DIR/web.sh"
# Adapt only the MIME include path in a private copy of the production module.
if [[ -n ${TEST_NGINX_MIME_TYPES:-} ]]; then
    [[ $TEST_NGINX_MIME_TYPES =~ ^/[A-Za-z0-9_./-]+$ ]] || die 'Invalid fixture MIME path.'
    sed "s|/etc/nginx/mime.types|$TEST_NGINX_MIME_TYPES|g" "$MODULE_DIR/web.sh" >"$TEST_ROOT/web-fixture.sh"
    # shellcheck disable=SC1091
    source "$TEST_ROOT/web-fixture.sh"
fi

cleanup() {
    if (( NGINX_TEST_STARTED )); then
        "$NGINX_BIN" -p "$DATA_DIR/nginx/" -c "$DATA_DIR/nginx.conf" -s quit >/dev/null 2>&1 || true
    fi
    # Exactly the directory returned by mktemp above; no computed recursive target.
    [[ $TEST_ROOT == /tmp/reality-site-web-test.* ]] && rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT
pass() { PASSED=$((PASSED + 1)); printf 'PASS %s\n' "$1"; }
expect_fail() {
    local name=$1 result
    shift
    set +e
    (set -e; "$@") >"$TEST_ROOT/expected-failure.log" 2>&1
    result=$?
    set -e
    if (( result == 0 )); then
        cat "$TEST_ROOT/expected-failure.log" >&2
        die "Expected rejection: $name"
    fi
    pass "$name"
}

mkdir -p "$APP_DIR/assets" "$DATA_DIR/www" "$DATA_DIR/nginx/client_temp" "$DATA_DIR/backups" "$DATA_DIR/certs/live" "$TMP_DIR" "$RS_UNIT_DIR"
chmod 755 "$TEST_ROOT" "$DATA_DIR" "$DATA_DIR/www" "$DATA_DIR/nginx"
chmod 700 "$DATA_DIR/certs" "$DATA_DIR/certs/live" "$DATA_DIR/backups" "$TMP_DIR"
printf '<!doctype html><html><body>Initial site</body></html>\n' >"$APP_DIR/assets/index.html"
printf '%s\n' reality-site-v1 >"$DATA_DIR/.managed-by"
printf '# Managed by reality-site\n' >"$RS_UNIT_DIR/$SERVICE_NAME"
rs_write_state ready

rs_web_render "$DATA_DIR/nginx.conf"
grep -Fq "listen 127.0.0.1:$PORT ssl http2;" "$DATA_DIR/nginx.conf"
grep -Fq 'ssl_protocols TLSv1.2 TLSv1.3;' "$DATA_DIR/nginx.conf"
if grep -Eq 'listen[[:space:]]+(443|80|\[::\])' "$DATA_DIR/nginx.conf"; then die 'Unexpected public listener.'; fi
pass 'render loopback-only HTTPS with TLS 1.3 + HTTP/2'
rs_web_render "$DATA_DIR/nginx.conf"
pass 'render replaces only a managed configuration'
printf 'foreign\n' >"$TEST_ROOT/foreign.conf"
expect_fail 'reject foreign nginx configuration' rs_web_render "$TEST_ROOT/foreign.conf"
ln -s "$TEST_ROOT/foreign.conf" "$TEST_ROOT/link.conf"
expect_fail 'reject symlink configuration output' rs_web_render "$TEST_ROOT/link.conf"
original_domain=$DOMAIN
DOMAIN='example.test;return 200'
expect_fail 'reject nginx domain injection' rs_web_render "$TEST_ROOT/bad.conf"
DOMAIN=$original_domain
original_port=$PORT
PORT=443
expect_fail 'reject public HTTPS port as internal port' rs_web_render "$TEST_ROOT/bad.conf"
PORT=$original_port

rs_web_set_page "$APP_DIR/assets/index.html"
cmp "$APP_DIR/assets/index.html" "$DATA_DIR/www/index.html"
[[ $(stat -c %a "$DATA_DIR/www/index.html") == 644 ]]
pass 'install HTML with worker-readable permissions'
printf '<html><body>Replacement site</body></html>\n' >"$TEST_ROOT/next.html"
rs_web_set_page "$TEST_ROOT/next.html"
cmp "$TEST_ROOT/next.html" "$DATA_DIR/www/index.html"
backup=$(find "$DATA_DIR/backups" -type f -name '*.html' -print -quit)
cmp "$APP_DIR/assets/index.html" "$backup"
[[ $(stat -c %a "$backup") == 600 ]]
pass 'replace HTML atomically and back up old content'
ln -s "$TEST_ROOT/next.html" "$TEST_ROOT/link.html"
expect_fail 'reject symlink HTML input' rs_web_set_page "$TEST_ROOT/link.html"
printf 'not a page\n' >"$TEST_ROOT/plain.txt"
expect_fail 'reject non-HTML input' rs_web_set_page "$TEST_ROOT/plain.txt"
cp "$TEST_ROOT/next.html" "$TEST_ROOT/large.html"
truncate -s 10485761 "$TEST_ROOT/large.html"
expect_fail 'reject HTML exceeding 10 MiB' rs_web_set_page "$TEST_ROOT/large.html"
cmp "$TEST_ROOT/next.html" "$DATA_DIR/www/index.html"
pass 'all rejected updates preserve the published page'

# Exercise listen detection without changing actual services or relying on ports.
# Called indirectly by rs_web_port_check.
# shellcheck disable=SC2317
ss() { printf '%s\n' "${TEST_LISTENERS:-}"; }
rs_web_port_check
pass 'allow unused internal TCP port'
TEST_LISTENERS='LISTEN 0 511 0.0.0.0:18003 0.0.0.0:*'
expect_fail 'reject occupied IPv4 wildcard port' rs_web_port_check
TEST_LISTENERS='LISTEN 0 511 [::]:18003 [::]:*'
expect_fail 'reject occupied IPv6 wildcard port' rs_web_port_check
unset -f ss
unset TEST_LISTENERS

if [[ -x $NGINX_BIN ]]; then
    id www-data >/dev/null
    chown www-data:www-data "$DATA_DIR/nginx/client_temp"
    chmod 700 "$DATA_DIR/nginx/client_temp"
    rs_web_port_check
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=Reality site test CA' \
        -keyout "$TEST_ROOT/ca.key" -out "$TEST_ROOT/ca.pem" \
        -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign' \
        >"$TEST_ROOT/cert.log" 2>&1
    openssl req -new -newkey rsa:2048 -nodes -subj "/CN=$DOMAIN" \
        -keyout "$DATA_DIR/certs/live/key.pem" -out "$TEST_ROOT/site.csr" \
        >>"$TEST_ROOT/cert.log" 2>&1
    printf 'subjectAltName=DNS:%s\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' "$DOMAIN" >"$TEST_ROOT/site.ext"
    openssl x509 -req -in "$TEST_ROOT/site.csr" -CA "$TEST_ROOT/ca.pem" -CAkey "$TEST_ROOT/ca.key" \
        -CAcreateserial -days 1 -extfile "$TEST_ROOT/site.ext" -out "$DATA_DIR/certs/live/fullchain.pem" \
        >>"$TEST_ROOT/cert.log" 2>&1
    chmod 600 "$DATA_DIR/certs/live/"*.pem
    "$NGINX_BIN" -t -q -p "$DATA_DIR/nginx/" -c "$DATA_DIR/nginx.conf"
    "$NGINX_BIN" -p "$DATA_DIR/nginx/" -c "$DATA_DIR/nginx.conf"
    NGINX_TEST_STARTED=1
    rs_web_check "$TEST_ROOT/ca.pem"
    pass 'live nginx: TLS 1.3 + trusted hostname + ALPN h2 + HTTPS GET'
    printf 'hidden fixture\n' >"$DATA_DIR/www/.hidden"
    hidden_status=$(curl -q --silent --show-error --noproxy '*' --cacert "$TEST_ROOT/ca.pem" --resolve "$DOMAIN:$PORT:127.0.0.1" --write-out '%{http_code}' --output /dev/null "https://$DOMAIN:$PORT/.hidden")
    [[ $hidden_status == 403 ]]
    pass 'static mode still denies hidden files'
    # systemctl is replaced by operations on this isolated nginx process only.
    systemctl() {
        case ${1:-} in
            is-active) (( NGINX_TEST_STARTED == 1 )) ;;
            reload)
                "$NGINX_BIN" -p "$DATA_DIR/nginx/" -c "$DATA_DIR/nginx.conf" -s reload || return 1
                # HUP is asynchronous; let the old worker stop accepting requests.
                sleep 0.5
                ;;
            *) die "Unexpected service command: $*" ;;
        esac
    }
    cp "$DATA_DIR/www/index.html" "$TEST_ROOT/page-before-mode.html"
    cp "$DATA_DIR/certs/live/fullchain.pem" "$TEST_ROOT/cert-before-mode.pem"
    cp "$DATA_DIR/certs/live/key.pem" "$TEST_ROOT/key-before-mode.pem"
    rs_web_set_mode redirect 'https://unreachable.invalid:9/a;b?x=1&word=%E4%B8%AD#part'
    for ((attempt=0; attempt<30; attempt++)); do
        rs_web_check "$TEST_ROOT/ca.pem" >"$TEST_ROOT/mode-check.log" 2>&1 && break
        sleep 0.1
    done
    if (( attempt == 30 )); then
        cat "$TEST_ROOT/mode-check.log" >&2
        curl -q --silent --show-error --noproxy '*' --cacert "$TEST_ROOT/ca.pem" --resolve "$DOMAIN:$PORT:127.0.0.1" --dump-header - --output /dev/null "https://$DOMAIN:$PORT/" >&2
    fi
    rs_web_check "$TEST_ROOT/ca.pem"
    [[ $(jq -r .web_mode "$STATE_FILE") == redirect ]]
    pass 'live nginx returns exact 302 Location without following an unreachable destination'
    headers=$(curl -q --silent --show-error --noproxy '*' --cacert "$TEST_ROOT/ca.pem" --resolve "$DOMAIN:$PORT:127.0.0.1" --dump-header - --output /dev/null "https://$DOMAIN:$PORT/other?original=query")
    location_actual=$(awk 'tolower(substr($0,1,9)) == "location:" { value=substr($0,10); sub(/^[ \t]+/,"",value); sub(/\r$/,"",value); print value }' <<<"$headers")
    cache_actual=$(awk 'tolower(substr($0,1,14)) == "cache-control:" { value=substr($0,15); sub(/^[ \t]+/,"",value); sub(/\r$/,"",value); print value }' <<<"$headers")
    [[ $location_actual == 'https://unreachable.invalid:9/a;b?x=1&word=%E4%B8%AD#part' ]]
    [[ $cache_actual == no-store ]]
    pass 'redirect uses the configured address without appending incoming path or query'
    WEB_MODE=static
    expect_fail 'mode-aware check rejects a redirect when static response is expected' rs_web_check "$TEST_ROOT/ca.pem"
    WEB_MODE=redirect
    REDIRECT_URL=https://different.invalid/
    expect_fail 'mode-aware check rejects an unexpected Location' rs_web_check "$TEST_ROOT/ca.pem"
    rs_load_state
    rs_web_set_mode static
    for ((attempt=0; attempt<30; attempt++)); do
        rs_web_check "$TEST_ROOT/ca.pem" >"$TEST_ROOT/mode-check.log" 2>&1 && break
        sleep 0.1
    done
    rs_web_check "$TEST_ROOT/ca.pem"
    [[ $(jq -r .web_mode "$STATE_FILE") == static ]]
    cmp "$DATA_DIR/www/index.html" "$TEST_ROOT/page-before-mode.html"
    cmp "$DATA_DIR/certs/live/fullchain.pem" "$TEST_ROOT/cert-before-mode.pem"
    cmp "$DATA_DIR/certs/live/key.pem" "$TEST_ROOT/key-before-mode.pem"
    pass 'live static-to-redirect-to-static switch preserves page and certificate bytes'
    expect_fail 'live nginx rejects an untrusted certificate' rs_web_check
    DOMAIN=wrong.example.test
    expect_fail 'live nginx rejects a mismatched certificate hostname' rs_web_check "$TEST_ROOT/ca.pem"
    DOMAIN=$original_domain
    expect_fail 'live nginx is not treated as a reusable occupied port' rs_web_port_check
else
    printf 'SKIP live TLS tests: nginx unavailable; set TEST_NGINX_BIN to a local test binary.\n'
fi

printf '\n%d checks passed. No system services were changed.\n' "$PASSED"
