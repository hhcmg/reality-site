#!/usr/bin/env bash
# Failure-injection tests in private fixtures. No real service is contacted.
set -Eeuo pipefail
PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
(( EUID == 0 )) || { printf 'Run these ownership tests as root.\n' >&2; exit 1; }
if [[ -n ${TEST_JQ_BIN:-} ]]; then jq() { "$TEST_JQ_BIN" "$@"; }; fi
command -v jq >/dev/null || { printf 'jq is required.\n' >&2; exit 1; }
# shellcheck source=../reality-site.sh
source "$PROJECT_DIR/reality-site.sh"

TEST_ROOT=$(mktemp -d /tmp/reality-site-mode-test.XXXXXX)
APP_DIR=$TEST_ROOT/app
DATA_DIR=$TEST_ROOT/data
STATE_FILE=$DATA_DIR/state.json
RS_UNIT_DIR=$TEST_ROOT/units
TMP_DIR=$TEST_ROOT/tmp
NGINX_BIN=$TEST_ROOT/nginx
DOMAIN=site.example.test
PORT=18003
CERT_MODE=manual
ACME_EMAIL=
WEB_MODE=static
REDIRECT_URL=
RS_MODE_PENDING=0
PASSED=0
SERVICE_ACTIVE=1
SERVICE_LOG=$TEST_ROOT/service.log

cleanup() {
    [[ $TEST_ROOT == /tmp/reality-site-mode-test.* && -d $TEST_ROOT ]] && rm -rf -- "$TEST_ROOT"
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
systemctl() {
    printf '%s\n' "$*" >>"$SERVICE_LOG"
    case ${1:-} in
        is-active) (( SERVICE_ACTIVE == 1 )) ;;
        reload)
            if [[ -e $TEST_ROOT/fail-reload-next ]]; then
                rm "$TEST_ROOT/fail-reload-next"
                return 1
            fi
            return 0
            ;;
        *) die "Unexpected service operation: $*" ;;
    esac
}

mkdir -m 700 "$TMP_DIR" "$RS_UNIT_DIR"
rs_prepare_directories
mkdir -m 755 "$DATA_DIR/www" "$DATA_DIR/nginx"
mkdir -m 700 "$DATA_DIR/backups"
printf '# Managed by reality-site\n' >"$RS_UNIT_DIR/$SERVICE_NAME"
printf '<html><body>Preserved custom page</body></html>\n' >"$DATA_DIR/www/index.html"
chmod 644 "$DATA_DIR/www/index.html"
cat >"$NGINX_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
root=$(dirname -- "$0")
printf '%s\n' "$*" >>"$root/nginx.log"
if [[ -e $root/fail-nginx-next ]]; then
    rm "$root/fail-nginx-next"
    exit 1
fi
EOF
chmod 700 "$NGINX_BIN"
rs_web_render "$DATA_DIR/nginx.conf"
rs_write_state ready
cp "$DATA_DIR/nginx.conf" "$TEST_ROOT/original.conf"
cp "$STATE_FILE" "$TEST_ROOT/original-state.json"
cp "$DATA_DIR/www/index.html" "$TEST_ROOT/original.html"

assert_original() {
    cmp "$DATA_DIR/nginx.conf" "$TEST_ROOT/original.conf"
    cmp "$STATE_FILE" "$TEST_ROOT/original-state.json"
    cmp "$DATA_DIR/www/index.html" "$TEST_ROOT/original.html"
    rs_load_state
    [[ $WEB_MODE == static && -z $REDIRECT_URL ]]
}

SERVICE_ACTIVE=0
expect_fail 'inactive service rejects mode change without altering config or state' rs_web_set_mode redirect https://www.example.com/
assert_original
SERVICE_ACTIVE=1
expect_fail 'reject unknown mode' rs_web_set_mode proxy https://www.example.com/
expect_fail 'reject static mode with a destination' rs_web_set_mode static https://www.example.com/
# The nginx variable is intentionally literal.
# shellcheck disable=SC2016
expect_fail 'reject unsafe redirect before changing config' rs_web_set_mode redirect 'https://www.example.com/$request_uri'
assert_original
jq '.status="installing"' "$TEST_ROOT/original-state.json" >"$STATE_FILE"
expect_fail 'unfinished installation rejects mode change' rs_web_set_mode redirect https://www.example.com/
cp "$TEST_ROOT/original-state.json" "$STATE_FILE"
printf '# Foreign service\n' >"$RS_UNIT_DIR/$SERVICE_NAME"
expect_fail 'refuse foreign service unit' rs_web_set_mode redirect https://www.example.com/
printf '# Managed by reality-site\n' >"$RS_UNIT_DIR/$SERVICE_NAME"

touch "$TEST_ROOT/fail-nginx-next"
expect_fail 'failed staged nginx validation restores original state and config' rs_web_set_mode redirect https://www.example.com/
assert_original
touch "$TEST_ROOT/fail-reload-next"
expect_fail 'failed reload restores original state and config' rs_web_set_mode redirect https://www.example.com/
assert_original
fail_state_publish() {
    # Called indirectly by rs_web_set_mode in the sourced module.
    # shellcheck disable=SC2317
    rs_write_state() { printf '{"partial":true}\n' >"$STATE_FILE"; return 1; }
    rs_web_set_mode redirect https://www.example.com/
}
expect_fail 'failed state publication restores exact old state and config' fail_state_publish
assert_original
pass 'all ordinary failures preserve the saved HTML bytes'

rs_web_set_mode redirect 'https://www.example.com/a;b?x=1&word=%E4%B8%AD#part'
rs_load_state
[[ $WEB_MODE == redirect && $REDIRECT_URL == 'https://www.example.com/a;b?x=1&word=%E4%B8%AD#part' ]]
grep -Fq 'return 302 "https://www.example.com/a;b?x=1&word=%E4%B8%AD#part";' "$DATA_DIR/nginx.conf"
if grep -Fq 'try_files' "$DATA_DIR/nginx.conf"; then die 'Unexpected static response in redirect mode.'; fi
cmp "$DATA_DIR/www/index.html" "$TEST_ROOT/original.html"
pass 'redirect render quotes URL as one literal and preserves the saved page'
cp "$STATE_FILE" "$TEST_ROOT/redirect-state.json"
printf '<html><body>Updated while redirecting</body></html>\n' >"$TEST_ROOT/next.html"
rs_web_set_page "$TEST_ROOT/next.html"
cmp "$STATE_FILE" "$TEST_ROOT/redirect-state.json"
cmp "$DATA_DIR/www/index.html" "$TEST_ROOT/next.html"
pass 'set-page updates the saved HTML without changing redirect mode'
cp "$DATA_DIR/nginx.conf" "$TEST_ROOT/redirect.conf"
: >"$SERVICE_LOG"
rs_web_set_mode redirect "$REDIRECT_URL"
cmp "$STATE_FILE" "$TEST_ROOT/redirect-state.json"
cmp "$DATA_DIR/nginx.conf" "$TEST_ROOT/redirect.conf"
if grep -Eq '^reload ' "$SERVICE_LOG"; then die 'Unexpected reload for unchanged mode.'; fi
pass 'same mode and same URL do not reload or rewrite state'
rs_web_set_mode static
rs_load_state
[[ $WEB_MODE == static && -z $REDIRECT_URL ]]
# nginx variables must remain literal in the generated config.
# shellcheck disable=SC2016
grep -Fq 'try_files $uri $uri/ =404;' "$DATA_DIR/nginx.conf"
if grep -Fq 'return 302' "$DATA_DIR/nginx.conf"; then die 'Unexpected redirect response in static mode.'; fi
cmp "$DATA_DIR/www/index.html" "$TEST_ROOT/next.html"
pass 'switching back to static exposes the latest saved page'

printf '\n%d isolated mode/rollback checks passed.\n' "$PASSED"
