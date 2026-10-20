#!/usr/bin/env bash
# Offline domain migration and interruption recovery. No service/network access.
set -Eeuo pipefail
PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
(( EUID == 0 )) || { printf 'Run these ownership tests as root.\n' >&2; exit 1; }
if [[ -n ${TEST_JQ_BIN:-} ]]; then jq() { "$TEST_JQ_BIN" "$@"; }; fi
command -v jq >/dev/null || { printf 'jq is required.\n' >&2; exit 1; }
# shellcheck source=../reality-site.sh
source "$PROJECT_DIR/reality-site.sh"

TEST_ROOT=$(mktemp -d /tmp/reality-site-domain-test.XXXXXX)
# Used by rs_prepare_directories in the sourced production module.
# shellcheck disable=SC2034
APP_DIR=$TEST_ROOT/app
DATA_DIR=$TEST_ROOT/data
STATE_FILE=$DATA_DIR/state.json
RS_UNIT_DIR=$TEST_ROOT/units
TMP_DIR=$TEST_ROOT/tmp
NGINX_BIN=$TEST_ROOT/nginx
DOMAIN=old.example.test
PORT=18003
CERT_MODE=cloudflare
ACME_EMAIL=owner@example.test
WEB_MODE=static
REDIRECT_URL=
PASSED=0
SERVICE_ACTIVE=1
SERVICE_LOG=$TEST_ROOT/service.log
CERT_LOG=$TEST_ROOT/cert.log
CHECK_LOG=$TEST_ROOT/check.log

cleanup() {
    [[ $TEST_ROOT == /tmp/reality-site-domain-test.* && -d $TEST_ROOT ]] && rm -rf -- "$TEST_ROOT"
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
            if [[ $(readlink "$DATA_DIR/certs/live") != generation.original ]]; then
                [[ -s $DATA_DIR/.domain-change.pending ]] || die 'New certificate became live without a journal.'
            fi
            if [[ -e $TEST_ROOT/fail-reload-next ]]; then
                rm "$TEST_ROOT/fail-reload-next"
                return 1
            fi
            return 0
            ;;
        *) die "Unexpected service operation: $*" ;;
    esac
}
# A fixture certificate records the domain and mode it was requested for.
# Real chain/key validation is covered separately in test-domain-cert.sh.
rs_cert_cf_sync_hook() {
    [[ "$DOMAIN" == old.example.test ]] || die 'Legacy hook must be migrated under the original domain.'
    [[ ! -e $TEST_ROOT/fail-hook-upgrade ]] || return 1
    printf '%s\n' "$DOMAIN" >>"$TEST_ROOT/hook-sync.log"
}
rs_cert_prepare_domain() {
    printf '%s|%s|%s|%s|%s\n' "$DOMAIN" "$CERT_MODE" "$#" "${3:-}" "${4:-}" >>"$CERT_LOG"
    [[ $(readlink "$DATA_DIR/certs/live") == generation.original ]] || die 'Issuance must leave the original certificate live.'
    [[ $(jq -r .domain "$STATE_FILE") == old.example.test ]] || die 'Issuance must leave the original state live.'
    [[ ! -e $TEST_ROOT/fail-certificate ]] || return 1
    printf 'chain for %s\n' "$DOMAIN" >"$1"
    printf 'key for %s\n' "$DOMAIN" >"$2"
    chmod 600 "$1" "$2"
}
rs_cert_validate() { [[ -s $1 && -s $2 ]]; }
rs_web_check() {
    printf '%s|%s|%s|%s\n' "$DOMAIN" "$PORT" "$WEB_MODE" "$REDIRECT_URL" >>"$CHECK_LOG"
    [[ ! -e $TEST_ROOT/fail-check ]] || return 1
    [[ $(readlink "$DATA_DIR/certs/live") != generation.original ]] || return 1
    grep -Fq "server_name $DOMAIN;" "$DATA_DIR/nginx.conf"
}
apt-get() { die 'Package installation must not run in a domain migration.'; }
curl() { die 'Network access must not run in this fixture.'; }

mkdir -m 700 "$TMP_DIR" "$RS_UNIT_DIR"
rs_prepare_directories
mkdir -m 755 "$DATA_DIR/www" "$DATA_DIR/nginx"
mkdir -m 700 "$DATA_DIR/backups" "$DATA_DIR/certs" "$DATA_DIR/certs/generation.original"
printf '# Managed by reality-site\n' >"$RS_UNIT_DIR/$SERVICE_NAME"
printf '<html><body>Custom page retained across migration</body></html>\n' >"$DATA_DIR/www/index.html"
chmod 644 "$DATA_DIR/www/index.html"
printf 'original fullchain\n' >"$DATA_DIR/certs/generation.original/fullchain.pem"
printf 'original private key\n' >"$DATA_DIR/certs/generation.original/key.pem"
chmod 600 "$DATA_DIR/certs/generation.original/"*.pem
ln -s generation.original "$DATA_DIR/certs/live"
printf 'manual input chain\n' >"$TEST_ROOT/manual-chain.pem"
printf 'manual input key\n' >"$TEST_ROOT/manual-key.pem"
chmod 600 "$TEST_ROOT/manual-"*.pem
cat >"$NGINX_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
root=$(dirname -- "$0")
printf '%s\n' "$*" >>"$root/nginx.log"
config=''
while (( $# )); do
    if [[ $1 == -c ]]; then config=$2; shift 2; else shift; fi
done
if [[ $config == */domain-candidate.conf ]]; then
    grep -Eq 'ssl_certificate .*/certs/generation\.[[:alnum:]]+/fullchain.pem;' "$config"
    grep -Eq 'ssl_certificate_key .*/certs/generation\.[[:alnum:]]+/key.pem;' "$config"
    [[ $(readlink "$root/data/certs/live") == generation.original ]]
    printf 'candidate uses private generation\n' >>"$root/candidate.log"
elif [[ $config == "$root/data/nginx.conf" ]]; then
    grep -Fq "ssl_certificate $root/data/certs/live/fullchain.pem;" "$config"
fi
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
cp "$DATA_DIR/certs/generation.original/fullchain.pem" "$TEST_ROOT/original-chain.pem"
cp "$DATA_DIR/certs/generation.original/key.pem" "$TEST_ROOT/original-key.pem"

clear_logs() {
    : >"$SERVICE_LOG"
    : >"$CERT_LOG"
    : >"$CHECK_LOG"
    : >"$TEST_ROOT/nginx.log"
    : >"$TEST_ROOT/candidate.log"
    : >"$TEST_ROOT/hook-sync.log"
}
assert_original() {
    cmp "$DATA_DIR/nginx.conf" "$TEST_ROOT/original.conf"
    cmp "$STATE_FILE" "$TEST_ROOT/original-state.json"
    cmp "$DATA_DIR/www/index.html" "$TEST_ROOT/original.html"
    cmp "$DATA_DIR/certs/live/fullchain.pem" "$TEST_ROOT/original-chain.pem"
    cmp "$DATA_DIR/certs/live/key.pem" "$TEST_ROOT/original-key.pem"
    [[ $(readlink "$DATA_DIR/certs/live") == generation.original ]]
    [[ ! -e $DATA_DIR/.domain-change.pending ]]
    rs_load_state
    [[ $DOMAIN == old.example.test && $PORT == 18003 && $CERT_MODE == cloudflare ]]
    [[ $WEB_MODE == static && -z $REDIRECT_URL && $ACME_EMAIL == owner@example.test ]]
}
assert_no_change_work() {
    [[ ! -s $CERT_LOG && ! -s $CHECK_LOG && ! -s $TEST_ROOT/nginx.log ]]
    if grep -Eq '^reload ' "$SERVICE_LOG"; then die 'Unexpected service reload.'; fi
}
reset_original() {
    cp "$TEST_ROOT/original.conf" "$DATA_DIR/nginx.conf"
    cp "$TEST_ROOT/original-state.json" "$STATE_FILE"
    rs_cert_paths
    rs_cert_switch_link generation.original
    rs_load_state
    clear_logs
}

clear_logs
rs_domain_set old.example.test
assert_original
assert_no_change_work
pass 'unchanged domain does not issue, validate, reload, or rewrite state'
expect_fail 'missing new domain is rejected' rs_domain_set
expect_fail 'invalid domain is rejected' rs_domain_set 'https://new.example.test'
expect_fail 'Cloudflare mode rejects manual certificate arguments' rs_domain_set new.example.test "$TEST_ROOT/manual-chain.pem" "$TEST_ROOT/manual-key.pem"
assert_original
assert_no_change_work
SERVICE_ACTIVE=0
expect_fail 'inactive service rejects migration before certificate issuance' rs_domain_set new.example.test
SERVICE_ACTIVE=1
assert_original
assert_no_change_work
jq '.status="installing"' "$TEST_ROOT/original-state.json" >"$STATE_FILE"
expect_fail 'unfinished installation rejects migration' rs_domain_set new.example.test
cp "$TEST_ROOT/original-state.json" "$STATE_FILE"
assert_original
assert_no_change_work
printf '# Foreign service\n' >"$RS_UNIT_DIR/$SERVICE_NAME"
expect_fail 'foreign service unit rejects migration' rs_domain_set new.example.test
printf '# Managed by reality-site\n' >"$RS_UNIT_DIR/$SERVICE_NAME"
assert_original

WEB_MODE=redirect
REDIRECT_URL=https://new.example.test/path
rs_web_render "$DATA_DIR/nginx.conf"
rs_write_state ready
cp "$STATE_FILE" "$TEST_ROOT/redirect-before.json"
cp "$DATA_DIR/nginx.conf" "$TEST_ROOT/redirect-before.conf"
clear_logs
expect_fail 'new domain matching existing 302 host rejects before issuance' rs_domain_set new.example.test
cmp "$STATE_FILE" "$TEST_ROOT/redirect-before.json"
cmp "$DATA_DIR/nginx.conf" "$TEST_ROOT/redirect-before.conf"
[[ $(readlink "$DATA_DIR/certs/live") == generation.original ]]
assert_no_change_work
reset_original

touch "$TEST_ROOT/fail-hook-upgrade"
expect_fail 'hook upgrade failure preserves the old website before issuance' rs_domain_set new.example.test
rm "$TEST_ROOT/fail-hook-upgrade"
assert_original
assert_no_change_work

touch "$TEST_ROOT/fail-certificate"
expect_fail 'certificate issuance failure preserves old site and certificate' rs_domain_set new.example.test
rm "$TEST_ROOT/fail-certificate"
assert_original
touch "$TEST_ROOT/fail-nginx-next"
expect_fail 'candidate nginx validation failure preserves exact old files' rs_domain_set new.example.test
assert_original
touch "$TEST_ROOT/fail-reload-next"
expect_fail 'new service reload failure rolls back exact old files and link' rs_domain_set new.example.test
assert_original
touch "$TEST_ROOT/fail-check"
expect_fail 'local HTTPS verification failure rolls back state, config, and certificate' rs_domain_set new.example.test
rm "$TEST_ROOT/fail-check"
assert_original
fail_state_publish() {
    # shellcheck disable=SC2317
    rs_write_state() { printf '{"partial":true}\n' >"$STATE_FILE"; return 1; }
    rs_domain_set new.example.test
}
expect_fail 'partial state write failure rolls back exact old state bytes' fail_state_publish
assert_original
pass 'all failure paths preserve the custom page and old private key'

clear_logs
rs_domain_set new.example.test
rs_load_state
[[ $DOMAIN == new.example.test && $PORT == 18003 && $CERT_MODE == cloudflare ]]
[[ $WEB_MODE == static && -z $REDIRECT_URL && $ACME_EMAIL == owner@example.test ]]
grep -Fxq 'new.example.test|cloudflare|2||' "$CERT_LOG"
grep -Fxq 'old.example.test' "$TEST_ROOT/hook-sync.log"
grep -Fxq 'new.example.test|18003|static|' "$CHECK_LOG"
grep -Fq 'server_name new.example.test;' "$DATA_DIR/nginx.conf"
grep -Fq 'listen 127.0.0.1:18003 ssl http2;' "$DATA_DIR/nginx.conf"
grep -Fq 'chain for new.example.test' "$DATA_DIR/certs/live/fullchain.pem"
grep -Fxq 'candidate uses private generation' "$TEST_ROOT/candidate.log"
cmp "$DATA_DIR/www/index.html" "$TEST_ROOT/original.html"
[[ ! -e $DATA_DIR/.domain-change.pending ]]
pass 'Cloudflare migration validates staged generation before publishing while retaining settings and page'
reset_original

WEB_MODE=redirect
REDIRECT_URL='https://external.example.test/a?x=1&y=2#part'
rs_web_render "$DATA_DIR/nginx.conf"
rs_write_state ready
rs_domain_set new.example.test
rs_load_state
[[ $DOMAIN == new.example.test && $WEB_MODE == redirect ]]
[[ $REDIRECT_URL == 'https://external.example.test/a?x=1&y=2#part' ]]
grep -Fq 'return 302 "https://external.example.test/a?x=1&y=2#part";' "$DATA_DIR/nginx.conf"
cmp "$DATA_DIR/www/index.html" "$TEST_ROOT/original.html"
pass 'redirect migration preserves the exact saved destination and custom page'
reset_original

CERT_MODE=manual
rs_write_state ready
cp "$STATE_FILE" "$TEST_ROOT/manual-before.json"
clear_logs
rs_domain_set old.example.test
cmp "$STATE_FILE" "$TEST_ROOT/manual-before.json"
assert_no_change_work
pass 'manual mode same-domain call needs no certificate input and makes no changes'
expect_fail 'manual migration requires both fullchain and key' rs_domain_set new.example.test
expect_fail 'manual migration rejects a missing private key argument' rs_domain_set new.example.test "$TEST_ROOT/manual-chain.pem"
cmp "$STATE_FILE" "$TEST_ROOT/manual-before.json"
assert_no_change_work
rs_domain_set new.example.test "$TEST_ROOT/manual-chain.pem" "$TEST_ROOT/manual-key.pem"
rs_load_state
[[ $DOMAIN == new.example.test && $CERT_MODE == manual && $PORT == 18003 && $WEB_MODE == static ]]
grep -Fxq "new.example.test|manual|4|$TEST_ROOT/manual-chain.pem|$TEST_ROOT/manual-key.pem" "$CERT_LOG"
cmp "$DATA_DIR/www/index.html" "$TEST_ROOT/original.html"
pass 'manual migration forwards both certificate sources and preserves manual mode'
reset_original

# Simulate termination after publishing candidate files but before committing.
# Recovery must use the durable journal, with no in-memory transaction globals.
RECOVERY_DIR=$(mktemp -d "$DATA_DIR/backups/domain.20260101T000000Z.XXXXXXXX")
cp "$TEST_ROOT/original-state.json" "$RECOVERY_DIR/state.json"
cp "$TEST_ROOT/original.conf" "$RECOVERY_DIR/nginx.conf"
printf 'generation.original\n' >"$RECOVERY_DIR/cert-target"
chmod 600 "$RECOVERY_DIR/"*
printf '%s\n' "${RECOVERY_DIR##*/}" >"$DATA_DIR/.domain-change.pending"
chmod 600 "$DATA_DIR/.domain-change.pending"
mkdir -m 700 "$DATA_DIR/certs/generation.interrupted"
printf 'interrupted chain\n' >"$DATA_DIR/certs/generation.interrupted/fullchain.pem"
printf 'interrupted key\n' >"$DATA_DIR/certs/generation.interrupted/key.pem"
chmod 600 "$DATA_DIR/certs/generation.interrupted/"*.pem
rs_cert_switch_link generation.interrupted
DOMAIN=interrupted.example.test
rs_web_render "$DATA_DIR/nginx.conf"
rs_write_state ready
clear_logs
touch "$TEST_ROOT/fail-reload-next"
expect_fail 'interrupted recovery retains its journal when service reload fails' rs_domain_recover
cmp "$DATA_DIR/nginx.conf" "$TEST_ROOT/original.conf"
cmp "$STATE_FILE" "$TEST_ROOT/original-state.json"
[[ $(readlink "$DATA_DIR/certs/live") == generation.original ]]
[[ -s $DATA_DIR/.domain-change.pending ]]
rs_domain_recover
assert_original
[[ -d $RECOVERY_DIR ]]
grep -Eq '^reload ' "$SERVICE_LOG"
[[ ! -s $CERT_LOG ]]
pass 'durable journal restores interrupted domain, config, and certificate and retains backup'
clear_logs
rs_domain_recover
assert_original
assert_no_change_work
pass 'recovery without a journal is a no-op'

printf '\n%d isolated domain migration/recovery checks passed.\n' "$PASSED"
