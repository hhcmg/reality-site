#!/usr/bin/env bash
# Real loopback Nginx, private fixture CA, no system services or external network.
set -Eeuo pipefail
PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
(( EUID == 0 )) || { printf 'Run these filesystem/worker tests as root.\n' >&2; exit 1; }
if [[ -n ${TEST_JQ_BIN:-} ]]; then jq() { "$TEST_JQ_BIN" "$@"; }; fi
command -v jq >/dev/null || { printf 'jq is required.\n' >&2; exit 1; }
# shellcheck source=../reality-site.sh
source "$PROJECT_DIR/reality-site.sh"
NGINX_BIN=${TEST_NGINX_BIN:-/usr/sbin/nginx}
if [[ ! -x $NGINX_BIN ]]; then
    printf 'SKIP live domain tests: nginx unavailable; set TEST_NGINX_BIN to a local test binary.\n'
    exit 0
fi

TEST_ROOT=$(mktemp -d /tmp/reality-site-domain-web-test.XXXXXX)
# Used by rs_prepare_directories in the sourced production module.
# shellcheck disable=SC2034
APP_DIR=$TEST_ROOT/app
DATA_DIR=$TEST_ROOT/data
STATE_FILE=$DATA_DIR/state.json
RS_UNIT_DIR=$TEST_ROOT/units
TMP_DIR=$TEST_ROOT/tmp
DOMAIN=old.example.test
PORT=18004
WEB_MODE=static
REDIRECT_URL=
CERT_MODE=manual
ACME_EMAIL=
PASSED=0
NGINX_TEST_STARTED=0
CA_FILE=$TEST_ROOT/ca.pem
cleanup() {
    if (( NGINX_TEST_STARTED )); then
        "$NGINX_BIN" -p "$DATA_DIR/nginx/" -c "$DATA_DIR/nginx.conf" -s quit >/dev/null 2>&1 || true
    fi
    [[ $TEST_ROOT == /tmp/reality-site-domain-web-test.* && -d $TEST_ROOT ]] && rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT
pass() { PASSED=$((PASSED + 1)); printf 'PASS %s\n' "$1"; }

# Adapt only the fixture MIME location, as in test-web.sh.
if [[ -n ${TEST_NGINX_MIME_TYPES:-} ]]; then
    [[ $TEST_NGINX_MIME_TYPES =~ ^/[A-Za-z0-9_./-]+$ ]] || die 'Invalid fixture MIME path.'
    sed "s|/etc/nginx/mime.types|$TEST_NGINX_MIME_TYPES|g" "$PROJECT_DIR/lib/web.sh" >"$TEST_ROOT/web-fixture.sh"
    # shellcheck disable=SC1091
    source "$TEST_ROOT/web-fixture.sh"
fi
# Preserve the real validators, changing only the trust anchor used by the test.
declare -f rs_cert_validate | sed '1s/rs_cert_validate/rs_fixture_cert_validate/' >"$TEST_ROOT/cert-validator.sh"
declare -f rs_web_check | sed '1s/rs_web_check/rs_fixture_web_check/' >"$TEST_ROOT/web-validator.sh"
# shellcheck disable=SC1091
source "$TEST_ROOT/cert-validator.sh"
# shellcheck disable=SC1091
source "$TEST_ROOT/web-validator.sh"
rs_cert_validate() { rs_fixture_cert_validate "$1" "$2" "$CA_FILE"; }
rs_web_check() { rs_fixture_web_check "$CA_FILE"; }

systemctl() {
    case ${1:-} in
        is-active)
            [[ -f $DATA_DIR/nginx/nginx.pid ]] && kill -0 "$(cat "$DATA_DIR/nginx/nginx.pid")" 2>/dev/null
            ;;
        reload)
            "$NGINX_BIN" -p "$DATA_DIR/nginx/" -c "$DATA_DIR/nginx.conf" -s reload
            ;;
        *) die "Unexpected service operation in isolated fixture: $*" ;;
    esac
}
make_certificate() {
    local domain=$1 name=$2
    openssl req -new -newkey rsa:2048 -nodes -subj "/CN=$domain" \
        -keyout "$TEST_ROOT/$name.key" -out "$TEST_ROOT/$name.csr" >>"$TEST_ROOT/cert.log" 2>&1
    printf 'subjectAltName=DNS:%s\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' "$domain" >"$TEST_ROOT/$name.ext"
    openssl x509 -req -in "$TEST_ROOT/$name.csr" -CA "$CA_FILE" -CAkey "$TEST_ROOT/ca.key" \
        -CAcreateserial -days 3 -extfile "$TEST_ROOT/$name.ext" -out "$TEST_ROOT/$name.pem" >>"$TEST_ROOT/cert.log" 2>&1
    chmod 600 "$TEST_ROOT/$name.pem" "$TEST_ROOT/$name.key"
}
assert_served_certificate() {
    local expected=$1 actual_fingerprint expected_fingerprint
    timeout 15s openssl s_client -connect "127.0.0.1:$PORT" -servername "$DOMAIN" \
        -CAfile "$CA_FILE" -verify_hostname "$DOMAIN" -verify_return_error -tls1_3 -alpn h2 \
        </dev/null >"$TEST_ROOT/handshake.log" 2>&1 || return 1
    grep -Fq 'ALPN protocol: h2' "$TEST_ROOT/handshake.log" || return 1
    openssl x509 -in "$TEST_ROOT/handshake.log" -out "$TEST_ROOT/served.pem" || return 1
    openssl x509 -in "$TEST_ROOT/served.pem" -noout -ext subjectAltName | grep -Fq "DNS:$DOMAIN" || return 1
    actual_fingerprint=$(openssl x509 -in "$TEST_ROOT/served.pem" -noout -fingerprint -sha256) || return 1
    expected_fingerprint=$(openssl x509 -in "$expected" -noout -fingerprint -sha256) || return 1
    [[ $actual_fingerprint == "$expected_fingerprint" ]]
}
wait_for_certificate() {
    local expected=$1 attempt
    for ((attempt=0; attempt<30; attempt++)); do
        if assert_served_certificate "$expected"; then return 0; fi
        sleep 0.1
    done
    cat "$TEST_ROOT/handshake.log" >&2
    die "Nginx did not serve the expected certificate for $DOMAIN."
}
get_page() {
    curl -q --silent --show-error --fail --noproxy '*' --cacert "$CA_FILE" \
        --connect-timeout 5 --max-time 15 --resolve "$DOMAIN:$PORT:127.0.0.1" "https://$DOMAIN:$PORT/"
}

chmod 755 "$TEST_ROOT"
mkdir -m 700 "$TMP_DIR" "$RS_UNIT_DIR"
rs_prepare_directories
mkdir -m 755 "$DATA_DIR/www" "$DATA_DIR/nginx"
mkdir -m 700 "$DATA_DIR/backups"
for name in client_temp proxy_temp fastcgi_temp uwsgi_temp scgi_temp; do
    install -d -o www-data -g www-data -m 700 "$DATA_DIR/nginx/$name"
done
printf '# Managed by reality-site\n' >"$RS_UNIT_DIR/$SERVICE_NAME"
printf '<!doctype html><html><body>Preserved migration page</body></html>\n' >"$DATA_DIR/www/index.html"
chmod 644 "$DATA_DIR/www/index.html"
cp "$DATA_DIR/www/index.html" "$TEST_ROOT/original.html"
openssl req -x509 -newkey rsa:2048 -nodes -days 4 -subj '/CN=Domain migration fixture CA' \
    -keyout "$TEST_ROOT/ca.key" -out "$CA_FILE" \
    -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign' \
    >"$TEST_ROOT/cert.log" 2>&1
make_certificate old.example.test old
make_certificate new.example.test new
make_certificate third.example.test third
make_certificate third.example.test replacement
rs_cert_publish "$TEST_ROOT/old.pem" "$TEST_ROOT/old.key"
rs_web_port_check
rs_web_render "$DATA_DIR/nginx.conf"
rs_write_state ready
"$NGINX_BIN" -t -q -p "$DATA_DIR/nginx/" -c "$DATA_DIR/nginx.conf"
"$NGINX_BIN" -p "$DATA_DIR/nginx/" -c "$DATA_DIR/nginx.conf"
NGINX_TEST_STARTED=1
rs_web_check
wait_for_certificate "$TEST_ROOT/old.pem"
get_page >"$TEST_ROOT/served.html"
cmp "$TEST_ROOT/served.html" "$TEST_ROOT/original.html"
pass 'original domain serves its trusted SAN certificate, HTTP/2, and saved static page'

rs_domain_set new.example.test "$TEST_ROOT/new.pem" "$TEST_ROOT/new.key"
rs_load_state
[[ $DOMAIN == new.example.test && $PORT == 18004 && $CERT_MODE == manual && $WEB_MODE == static ]]
wait_for_certificate "$TEST_ROOT/new.pem"
pass 'real migration serves the new SAN certificate on the original loopback port'
rs_web_check
get_page >"$TEST_ROOT/served.html"
cmp "$TEST_ROOT/served.html" "$TEST_ROOT/original.html"
cmp "$DATA_DIR/www/index.html" "$TEST_ROOT/original.html"
[[ ! -e $DATA_DIR/.domain-change.pending ]]
pass 'static migration preserves page bytes and returns HTTP 200 before committing'

rs_web_set_mode redirect 'https://unreachable.invalid:9/a;b?x=1&word=%E4%B8%AD#part'
rs_domain_set third.example.test "$TEST_ROOT/third.pem" "$TEST_ROOT/third.key"
rs_load_state
[[ $DOMAIN == third.example.test && $PORT == 18004 && $CERT_MODE == manual && $WEB_MODE == redirect ]]
[[ $REDIRECT_URL == 'https://unreachable.invalid:9/a;b?x=1&word=%E4%B8%AD#part' ]]
wait_for_certificate "$TEST_ROOT/third.pem"
rs_web_check
pass 'redirect migration serves the third SAN certificate and exact HTTP 302 Location'
cmp "$DATA_DIR/www/index.html" "$TEST_ROOT/original.html"
[[ ! -e $DATA_DIR/.domain-change.pending ]]
pass 'redirect migration retains the saved HTML and clears its transaction journal'

grep -Fq "ssl_certificate $DATA_DIR/certs/live/fullchain.pem;" "$DATA_DIR/nginx.conf"
rs_cert_import "$TEST_ROOT/replacement.pem" "$TEST_ROOT/replacement.key"
wait_for_certificate "$TEST_ROOT/replacement.pem"
rs_web_check
[[ $(jq -r .domain "$STATE_FILE") == third.example.test ]]
pass 'later manual certificate import reloads the active live link after domain migration'

printf '\n%d live domain migration checks passed. No system services were changed.\n' "$PASSED"
