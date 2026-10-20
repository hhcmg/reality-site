#!/usr/bin/env bash
# Isolated Linux fixture tests. Requires root for real ownership/mode checks.
# Services, package installation, module loading and sysctl changes are mocked.
set -Eeuo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
(( EUID == 0 )) || { printf 'Run these ownership tests as root.\n' >&2; exit 1; }
if [[ -n ${TEST_JQ_BIN:-} ]]; then
    [[ -x $TEST_JQ_BIN ]] || { printf 'TEST_JQ_BIN is not executable.\n' >&2; exit 1; }
    jq() { "$TEST_JQ_BIN" "$@"; }
fi
command -v jq >/dev/null || { printf 'jq is required.\n' >&2; exit 1; }
# shellcheck source=../reality-site.sh
source "$PROJECT_DIR/reality-site.sh"

TEST_ROOT=$(mktemp -d /tmp/reality-site-system-test.XXXXXX)
# Consumed by rs_prepare_directories in the sourced production modules.
# shellcheck disable=SC2034
APP_DIR=$TEST_ROOT/app
DATA_DIR=$TEST_ROOT/data
STATE_FILE=$DATA_DIR/state.json
TMP_DIR=$TEST_ROOT/tmp
RS_LOCK_FILE=$TEST_ROOT/locks/operation.lock
RS_SYSCTL_FILE=$TEST_ROOT/sysctl/99-reality-site-bbr.conf
RS_UNIT_DIR=$TEST_ROOT/units
POLICY_PATH=$TEST_ROOT/policy-rc.d
NGINX_BIN=$TEST_ROOT/nginx
DOMAIN=site.example.test
PORT=8003
CERT_MODE=cloudflare
WEB_MODE=static
REDIRECT_URL=
# Consumed by rs_write_state in the sourced production modules.
# shellcheck disable=SC2034
ACME_EMAIL=owner@example.test
RS_POLICY_CREATED=0
PASSED=0
LOCK_HOLDER=
SYSTEMCTL_LOG=$TEST_ROOT/systemctl.log
SYSCTL_LOG=$TEST_ROOT/sysctl.log
SC_AVAILABLE='reno cubic bbr'
SC_FAIL=
FAIL_SYSCTL_RENAME=0
FAIL_SYSTEMCTL_DISABLE=0
SC_CC_FILE=$TEST_ROOT/runtime-cc
SC_QDISC_FILE=$TEST_ROOT/runtime-qdisc

cleanup() {
    if [[ -n $LOCK_HOLDER ]] && kill -0 "$LOCK_HOLDER" 2>/dev/null; then
        kill -KILL "$LOCK_HOLDER" 2>/dev/null || true
        wait "$LOCK_HOLDER" 2>/dev/null || true
    fi
    # Exact mktemp directory above; never a production path.
    [[ $TEST_ROOT == /tmp/reality-site-system-test.* && -d $TEST_ROOT ]] && rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT
pass() { PASSED=$((PASSED + 1)); printf 'PASS %s\n' "$1"; }
expect_fail() {
    local name=$1 result
    shift
    # Do not put the function under test in an `if`: Bash would then suppress
    # errexit throughout that function and diverge from the real entry point.
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

# Fail before any test if an older module still embeds a production output path.
declare -f rs_lock | grep -Fq RS_LOCK_FILE || die 'rs_lock must support RS_LOCK_FILE before running this test.'
declare -f rs_enable_bbr | grep -Fq RS_SYSCTL_FILE || die 'rs_enable_bbr must support RS_SYSCTL_FILE before running this test.'
declare -f rs_configure_timer | grep -Fq RS_UNIT_DIR || die 'rs_configure_timer must support RS_UNIT_DIR before running this test.'

# These mocks are installed globally before invoking any production function.
systemctl() {
    printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
    case ${1:-} in
        is-active) return 3 ;;
        disable) (( FAIL_SYSTEMCTL_DISABLE == 0 )) ;;
        *) return 0 ;;
    esac
}
apt-get() { die 'Package commands must not run in this fixture.'; }
modprobe() { printf 'module %s\n' "$*" >>"$SYSCTL_LOG"; }
tc() { printf 'mock tc %s\n' "$*"; }
sysctl() {
    printf '%s\n' "$*" >>"$SYSCTL_LOG"
    if [[ ${1:-} == -n ]]; then
        case ${2:-} in
            net.ipv4.tcp_available_congestion_control) printf '%s\n' "$SC_AVAILABLE" ;;
            net.ipv4.tcp_congestion_control) cat "$SC_CC_FILE" ;;
            net.core.default_qdisc) cat "$SC_QDISC_FILE" ;;
            *) return 1 ;;
        esac
        return
    fi
    local setting
    for setting in "$@"; do
        case "$setting" in
            -q|-w) continue ;;
            net.ipv4.tcp_congestion_control=*|net.core.default_qdisc=*)
                [[ $setting != "$SC_FAIL" ]] || return 1
                case "$setting" in
                    net.ipv4.tcp_congestion_control=*) printf '%s\n' "${setting#*=}" >"$SC_CC_FILE" ;;
                    net.core.default_qdisc=*) printf '%s\n' "${setting#*=}" >"$SC_QDISC_FILE" ;;
                esac
                ;;
            net.ipv4.tcp_congestion_control) cat "$SC_CC_FILE" ;;
            net.core.default_qdisc) cat "$SC_QDISC_FILE" ;;
            *) return 1 ;;
        esac
    done
}
mv() {
    local destination=${*: -1}
    if (( FAIL_SYSCTL_RENAME )) && [[ $destination == "$RS_SYSCTL_FILE" ]]; then
        return 1
    fi
    command mv "$@"
}

mkdir -m 700 "$TMP_DIR" "$TEST_ROOT/locks" "$TEST_ROOT/sysctl" "$RS_UNIT_DIR"
touch "$SYSTEMCTL_LOG" "$SYSCTL_LOG"
printf '#!/bin/sh\nexit 0\n' >"$NGINX_BIN"
chmod 700 "$NGINX_BIN"
rs_prepare_directories

# Inputs eventually become Nginx config, certificate names and shell arguments.
for value in site.example.test xn--example-9d0b.test; do
    rs_valid_domain "$value" || die "Valid domain rejected: $value"
done
pass 'accept fully qualified ASCII domain names'
for value in 'https://site.test' 'site.test:443' 'site.test;return 200' 'a..test' '*.test' '-a.test' '127.0.0.1' $'site.test\ninclude x'; do
    expect_fail "reject invalid/injected domain $value" rs_valid_domain "$value"
done
for value in 1024 8003 65535; do rs_valid_port "$value" || die 'Valid internal port rejected.'; done
pass 'accept valid internal TCP ports'
for value in 80 443 1023 65536 08003 -8003 '8003;id' '8e3'; do
    expect_fail "reject unsafe internal port $value" rs_valid_port "$value"
done

for value in 'https://www.example.com/' 'https://www.example.com:8443/a?x=1&y=2#part' 'https://www.example.com/%E4%B8%AD%E6%96%87' 'https://www.example.com/a;b?name=a%20b'; do
    rs_valid_redirect_url "$value" || die "Valid redirect URL rejected: $value"
done
pass 'accept absolute HTTPS destinations with encoded paths, query and fragment'
# These are literal injection probes, not shell interpolation.
# shellcheck disable=SC2016
for value in 'http://www.example.com/' '//www.example.com/' 'https://127.0.0.1/' 'https://[::1]/' 'https://user:pass@www.example.com/' 'https://www.example.com:0/' 'https://www.example.com:65536/' 'https://www.example.com/a b' 'https://www.example.com/中文' 'https://www.example.com/%ZZ' 'https://www.example.com/%' 'https://www.example.com/%0d%0aHeader:value' 'https://www.example.com/$request_uri' 'https://www.example.com/";return 200;' 'https://www.example.com/{x}' 'https://www.example.com/`id`' 'https://www.example.com/\x' $'https://www.example.com/\nreturn 200' 'https://site.example.test/' 'https://SITE.EXAMPLE.TEST:443/'; do
    expect_fail 'reject unsafe, malformed or self-loop redirect URL' rs_valid_redirect_url "$value"
done

rs_write_state ready
cp "$STATE_FILE" "$TEST_ROOT/valid-state.json"
DOMAIN=wrong.example.test
PORT=19000
rs_load_state
[[ $DOMAIN == site.example.test && $PORT == 8003 && $CERT_MODE == cloudflare && $WEB_MODE == static && -z $REDIRECT_URL ]]
[[ $(stat -c %a "$STATE_FILE") == 600 ]]
pass 'state round trip restores validated values and uses private mode'

jq '.schema=1 | del(.web_mode,.redirect_url)' "$TEST_ROOT/valid-state.json" >"$STATE_FILE"
WEB_MODE=redirect
REDIRECT_URL=https://stale.example.test/
rs_load_state
[[ $WEB_MODE == static && -z $REDIRECT_URL ]]
pass 'legacy schema 1 loads static mode and clears stale redirect state'
WEB_MODE=redirect
REDIRECT_URL='https://www.example.com/a?x=1&y=2#part'
rs_write_state ready
rs_load_state
[[ $WEB_MODE == redirect && $REDIRECT_URL == 'https://www.example.com/a?x=1&y=2#part' ]]
pass 'schema 2 round trip preserves the exact redirect destination'
for expression in '.web_mode=null' '.web_mode="proxy"' '.redirect_url=null' 'del(.web_mode)' 'del(.redirect_url)' '.web_mode="redirect" | .redirect_url=""' '.web_mode="redirect" | .redirect_url="https://site.example.test/"' '.web_mode="static" | .redirect_url="https://www.example.com/"'; do
    jq "$expression" "$TEST_ROOT/valid-state.json" >"$STATE_FILE"
    expect_fail "reject invalid schema 2 mode fields: $expression" rs_load_state
done
cp "$TEST_ROOT/valid-state.json" "$STATE_FILE"
rs_load_state

jq '.domain="site.test;touch /tmp/never-execute"' "$TEST_ROOT/valid-state.json" >"$STATE_FILE"
expect_fail 'reject injected domain in saved state' rs_load_state
jq '.port=8003.5' "$TEST_ROOT/valid-state.json" >"$STATE_FILE"
expect_fail 'reject fractional port in saved state' rs_load_state
jq '.schema=99' "$TEST_ROOT/valid-state.json" >"$STATE_FILE"
expect_fail 'reject unknown state schema' rs_load_state
cp "$TEST_ROOT/valid-state.json" "$STATE_FILE"
chmod 620 "$STATE_FILE"
expect_fail 'reject group-writable saved state' rs_load_state
chmod 600 "$STATE_FILE"
chown 65534 "$STATE_FILE"
expect_fail 'reject state owned by non-root user' rs_load_state
chown 0 "$STATE_FILE"
ln "$STATE_FILE" "$TEST_ROOT/state-hardlink"
expect_fail 'reject hard-linked saved state' rs_load_state
rm "$TEST_ROOT/state-hardlink"
command mv "$STATE_FILE" "$TEST_ROOT/state-real"
ln -s "$TEST_ROOT/state-real" "$STATE_FILE"
expect_fail 'reject symbolic-link saved state' rs_load_state
rm "$STATE_FILE"
command mv "$TEST_ROOT/state-real" "$STATE_FILE"
rs_load_state

printf '# Owned by someone else\n' >"$TEST_ROOT/foreign.conf"
expect_fail 'reject overwriting a foreign configuration' rs_assert_owned_output "$TEST_ROOT/foreign.conf"
printf '# Managed by reality-site\n' >"$TEST_ROOT/managed.conf"
rs_assert_owned_output "$TEST_ROOT/managed.conf"
pass 'allow previously managed configuration'
ln -s "$TEST_ROOT/managed.conf" "$TEST_ROOT/output-link.conf"
expect_fail 'reject symbolic-link output even with valid ownership marker' rs_assert_owned_output "$TEST_ROOT/output-link.conf"

# A holder execs sleep so the killed process is the actual open-FD owner.
bash -c '
    set -euo pipefail
    source "$1"
    RS_LOCK_FILE=$2
    rs_lock
    printf ready >"$3"
    exec sleep 30
' bash "$PROJECT_DIR/lib/common.sh" "$RS_LOCK_FILE" "$TEST_ROOT/lock-ready" &
LOCK_HOLDER=$!
for ((attempt=0; attempt<50; attempt++)); do
    [[ -f $TEST_ROOT/lock-ready ]] && break
    sleep 0.05
done
[[ -f $TEST_ROOT/lock-ready ]] || die 'Lock holder did not become ready.'
lock_inode=$(stat -c %i "$RS_LOCK_FILE")
expect_fail 'second operation cannot acquire an occupied flock' rs_lock
kill -KILL "$LOCK_HOLDER"
wait "$LOCK_HOLDER" 2>/dev/null || true
LOCK_HOLDER=
(rs_lock)
[[ $(stat -c %i "$RS_LOCK_FILE") == "$lock_inode" ]]
pass 'SIGKILL releases lock and reuses the persistent inode'
ln -s "$RS_LOCK_FILE" "$TEST_ROOT/locks/symlink.lock"
original_lock=$RS_LOCK_FILE
RS_LOCK_FILE=$TEST_ROOT/locks/symlink.lock
expect_fail 'reject symlink lock file' rs_lock
RS_LOCK_FILE=$original_lock

# The exact policy text is an ownership/recovery marker for new nginx installs.
rs_policy_text >"$POLICY_PATH"
chmod 755 "$POLICY_PATH"
: >"$SYSTEMCTL_LOG"
RS_POLICY_CREATED=0
rs_recover_policy
[[ ! -e $POLICY_PATH ]]
grep -Eq '^disable( --now)? nginx\.service$' "$SYSTEMCTL_LOG" || die 'Recovery must disable the newly installed default nginx service.'
pass 'recover owned stale policy and disable the newly installed default service'
rs_policy_text >"$POLICY_PATH"
chmod 755 "$POLICY_PATH"
RS_POLICY_CREATED=1
FAIL_SYSTEMCTL_DISABLE=1
expect_fail 'failed default-service disable retains its recovery policy' rs_restore_policy
cmp "$POLICY_PATH" <(rs_policy_text)
FAIL_SYSTEMCTL_DISABLE=0
rs_restore_policy
[[ ! -e $POLICY_PATH && $RS_POLICY_CREATED == 0 ]]
pass 'retry completes policy cleanup after the service operation recovers'
printf '#!/bin/sh\n# administrator policy\nexit 101\n' >"$POLICY_PATH"
cp "$POLICY_PATH" "$TEST_ROOT/custom-policy.expected"
: >"$SYSTEMCTL_LOG"
rs_recover_policy
cmp "$POLICY_PATH" "$TEST_ROOT/custom-policy.expected"
[[ ! -s $SYSTEMCTL_LOG ]]
pass 'leave existing administrator policy and services unchanged'
RS_POLICY_CREATED=1
expect_fail 'cleanup refuses a policy replaced during installation' rs_restore_policy
cmp "$POLICY_PATH" "$TEST_ROOT/custom-policy.expected"
[[ ! -s $SYSTEMCTL_LOG ]]
RS_POLICY_CREATED=0
rm "$POLICY_PATH"
rs_policy_text >"$POLICY_PATH"
chmod 755 "$POLICY_PATH"
RS_POLICY_CREATED=1
rs_restore_policy
[[ ! -e $POLICY_PATH && $RS_POLICY_CREATED == 0 ]]
pass 'normal cleanup removes only its temporary service policy'

reset_bbr() {
    printf cubic >"$SC_CC_FILE"
    printf fq_codel >"$SC_QDISC_FILE"
    : >"$SYSCTL_LOG"
    SC_AVAILABLE='reno cubic bbr'
    SC_FAIL=
    FAIL_SYSCTL_RENAME=0
}
reset_bbr
SC_AVAILABLE='reno cubic'
expect_fail 'unavailable BBR makes no persistent or runtime change' rs_enable_bbr
[[ ! -e $RS_SYSCTL_FILE && $(cat "$SC_CC_FILE") == cubic && $(cat "$SC_QDISC_FILE") == fq_codel ]]
reset_bbr
SC_FAIL='net.core.default_qdisc=fq'
expect_fail 'rejected fq leaves original congestion control' rs_enable_bbr
[[ ! -e $RS_SYSCTL_FILE && $(cat "$SC_CC_FILE") == cubic && $(cat "$SC_QDISC_FILE") == fq_codel ]]
reset_bbr
SC_FAIL='net.ipv4.tcp_congestion_control=bbr'
expect_fail 'failed BBR activation rolls back the qdisc change' rs_enable_bbr
[[ ! -e $RS_SYSCTL_FILE && $(cat "$SC_CC_FILE") == cubic && $(cat "$SC_QDISC_FILE") == fq_codel ]]
reset_bbr
rs_enable_bbr
[[ $(cat "$SC_CC_FILE") == bbr && $(cat "$SC_QDISC_FILE") == fq ]]
grep -Fxq 'net.ipv4.tcp_congestion_control = bbr' "$RS_SYSCTL_FILE"
grep -Fxq 'net.core.default_qdisc = fq' "$RS_SYSCTL_FILE"
pass 'BBR success persists the two settings without a kernel installation'
cp "$RS_SYSCTL_FILE" "$TEST_ROOT/sysctl.expected"
reset_bbr
FAIL_SYSCTL_RENAME=1
expect_fail 'persistent write failure restores runtime settings' rs_enable_bbr
cmp "$RS_SYSCTL_FILE" "$TEST_ROOT/sysctl.expected"
[[ $(cat "$SC_CC_FILE") == cubic && $(cat "$SC_QDISC_FILE") == fq_codel ]]
pass 'failed atomic replacement preserves the old sysctl file'
FAIL_SYSCTL_RENAME=0

# Exercise main-command sequencing without performing cryptographic/network I/O.
IMPORT_LOG=$TEST_ROOT/import.log
printf 'fixture chain\n' >"$TEST_ROOT/chain.pem"
printf 'fixture key\n' >"$TEST_ROOT/key.pem"
printf 'old certificate\n' >"$TEST_ROOT/published.pem"
cp "$TEST_ROOT/published.pem" "$TEST_ROOT/published.expected"
rs_cert_validate() { printf 'validate\n' >>"$IMPORT_LOG"; }
rs_cert_import() {
    [[ $(jq -r .cert_mode "$STATE_FILE") == manual ]] || die 'Certificate publish happened before persisting manual mode.'
    printf 'publish-sees-manual\n' >>"$IMPORT_LOG"
    return 1
}
CERT_MODE=cloudflare
rs_write_state ready
printf '# Managed by reality-site\n' >"$RS_UNIT_DIR/reality-site-renew.timer"
printf '# Managed by reality-site\n' >"$RS_UNIT_DIR/reality-site-renew.service"
: >"$IMPORT_LOG"
: >"$SYSTEMCTL_LOG"
expect_fail 'failed certificate publish leaves manual mode for safe recovery' rs_dispatch import-cert "$TEST_ROOT/chain.pem" "$TEST_ROOT/key.pem"
[[ $(jq -r .cert_mode "$STATE_FILE") == manual ]]
grep -Fxq publish-sees-manual "$IMPORT_LOG"
grep -Eq '^disable --now reality-site-renew\.timer$' "$SYSTEMCTL_LOG"
cmp "$TEST_ROOT/published.pem" "$TEST_ROOT/published.expected"
pass 'import disables automatic renewal before publishing replacement certificate'

CERT_MODE=cloudflare
rs_write_state ready
: >"$IMPORT_LOG"
state_write_failure() {
    # Called indirectly by rs_dispatch in the sourced module.
    # shellcheck disable=SC2317
    rs_write_state() { return 1; }
    rs_dispatch import-cert "$TEST_ROOT/chain.pem" "$TEST_ROOT/key.pem"
}
expect_fail 'manual-mode state failure prevents certificate publication' state_write_failure
[[ $(jq -r .cert_mode "$STATE_FILE") == cloudflare ]]
if grep -Fq publish-sees-manual "$IMPORT_LOG"; then die 'Unexpected publication after state failure.'; fi
pass 'state failure preserves the old mode and never reaches publication'

# Repeat install upgrades program files but must not reconfigure the ready site.
repeat_ready_install() {
    rs_check_platform() { :; }
    rs_recover_policy() { :; }
    rs_status() { :; }
    rs_panel() { :; }
    rs_install_dependencies() { die 'Unexpected dependency reinstall.'; }
    rs_web_install() { die 'Unexpected website rewrite.'; }
    rs_cert_cf_api_get() { die 'An existing site upgrade must not need Zone Read or network access.'; }
    rs_cert_paths
    mkdir -m 0700 "$ACME_HOME" "$ACME_HOME/dnsapi"
    printf '%s\n%s\n' fixture_token_01234567890123456789 0123456789abcdef0123456789abcdef >"$ACME_HOME/cloudflare.credentials"
    chmod 0600 "$ACME_HOME/cloudflare.credentials"
    printf '#!/bin/sh\n# legacy hook\n' >"$ACME_HOME/dnsapi/dns_realitysite.sh"
    chmod 0700 "$ACME_HOME/dnsapi/dns_realitysite.sh"
    cp "$ACME_HOME/cloudflare.credentials" "$TEST_ROOT/credentials-before-upgrade"
    cp "$STATE_FILE" "$TEST_ROOT/state-before-upgrade.json"
    rs_install
    cmp "$STATE_FILE" "$TEST_ROOT/state-before-upgrade.json"
    cmp "$PROJECT_DIR/reality-site.sh" "$APP_DIR/reality-site.sh"
    cmp "$PROJECT_DIR/lib/domain.sh" "$APP_DIR/lib/domain.sh"
    [[ $(bash "$APP_DIR/reality-site.sh" version) == "$VERSION" ]]
    bash "$APP_DIR/reality-site.sh" help | grep -Fq 'set-domain'
    cmp "$ACME_HOME/cloudflare.credentials" "$TEST_ROOT/credentials-before-upgrade"
    [[ $(jq -r --arg domain "$DOMAIN" '.zones[$domain]' "$ACME_HOME/cloudflare-zones.json") == 0123456789abcdef0123456789abcdef ]]
    grep -Fq '_rs_cf_select_zone()' "$ACME_HOME/dnsapi/dns_realitysite.sh"
    sh -n "$ACME_HOME/dnsapi/dns_realitysite.sh"
}
repeat_ready_install
pass 'repeat installation upgrades program and legacy hook offline while preserving ready state and credentials'

printf '\n%d isolated system/common/main checks passed.\n' "$PASSED"
