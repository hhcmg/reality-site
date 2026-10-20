#!/usr/bin/env bash
# Offline domain-certificate preparation tests. Only a temporary fixture is
# written; ACME and all service/state publication entry points are mocked.
set -Eeuo pipefail
umask 077
[[ $EUID == 0 ]] || { printf 'Run this fixture test as root (temporary files only).\n' >&2; exit 1; }
if [[ -n ${TEST_JQ_BIN:-} ]]; then jq() { "$TEST_JQ_BIN" "$@"; }; fi
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
TEST_ROOT=$(mktemp -d /tmp/reality-site-domain-cert.XXXXXXXX)
trap '[[ $TEST_ROOT == /tmp/reality-site-domain-cert.* ]] && rm -rf -- "$TEST_ROOT"' EXIT
source "$HERE/../lib/common.sh"
source "$HERE/../lib/cert.sh"
DATA_DIR="$TEST_ROOT/data"
TMP_DIR="$TEST_ROOT/tmp"
DOMAIN=new.example.test
CERT_MODE=manual
ACME_EMAIL=owner@example.test
mkdir -m 0700 "$DATA_DIR" "$TMP_DIR" "$DATA_DIR/certs" \
    "$DATA_DIR/certs/generation.old" "$DATA_DIR/certs/generation.candidate"
OUT_CHAIN="$DATA_DIR/certs/generation.candidate/fullchain.pem"
OUT_KEY="$DATA_DIR/certs/generation.candidate/key.pem"
printf 'old chain\n' >"$DATA_DIR/certs/generation.old/fullchain.pem"
printf 'old key\n' >"$DATA_DIR/certs/generation.old/key.pem"
ln -s generation.old "$DATA_DIR/certs/live"
printf 'old state\n' >"$DATA_DIR/state.json"
printf 'old nginx configuration\n' >"$DATA_DIR/nginx.conf"
printf 'old timer\n' >"$DATA_DIR/renew.timer"
for path in state.json nginx.conf renew.timer certs/generation.old/fullchain.pem certs/generation.old/key.pem; do
    sha256sum "$DATA_DIR/$path"
done >"$TEST_ROOT/active.sha256"
PASSED=0
ACME_RESULT=0
FAIL_INSTALL=
CORRUPT_COPY=0
info() { :; }
pass() { PASSED=$((PASSED + 1)); printf 'PASS %s\n' "$*"; }
assert_unchanged() {
    [[ $(readlink "$DATA_DIR/certs/live") == generation.old ]] || die 'Active certificate changed.'
    sha256sum --status -c "$TEST_ROOT/active.sha256" || die 'Active state changed.'
    [[ ! -s "$TEST_ROOT/side-effects.log" ]] || die 'Unexpected publication/service mutation.'
    if [[ -e "$TEST_ROOT/old-acme.sha256" ]]; then
        sha256sum --status -c "$TEST_ROOT/old-acme.sha256" || die 'Old domain ACME data changed.'
    fi
}
reject() {
    local name=$1
    shift
    # Intentionally suppress errexit in the function under test, just like the
    # domain transaction: every operational failure must be checked explicitly.
    if ( "$@" ) >"$TEST_ROOT/rejected.log" 2>&1; then
        die "Unexpected success: $name"
    fi
    assert_unchanged
    pass "$name"
}
forbidden() {
    printf '%s\n' "$*" >>"$TEST_ROOT/side-effects.log"
    die 'Candidate preparation attempted an active-state operation.'
}
systemctl() { forbidden systemctl "$@"; }
rs_cert_publish() { forbidden publish "$@"; }
rs_write_state() { forbidden state "$@"; }
rs_cert_install_acme() { forbidden install-acme; }
rs_cert_cf_credentials() { forbidden prompt-credentials; }
rs_cert_render_dns_hook() { forbidden render-hook "$@"; }
# Read-only discovery and the hook upgrade are exercised in test-cloudflare.sh;
# candidate preparation still must preserve the prior credentials and hook.
rs_cert_cf_discover_zone() { printf '%s\n' 22222222222222222222222222222222; }
rs_cert_run_acme() {
    printf '%s\n' "$@" >"$TEST_ROOT/acme-args"
    return "$ACME_RESULT"
}
install() {
    local destination=${*: -1}
    [[ "$destination" != "$FAIL_INSTALL" ]] || return 1
    command install "$@" || return 1
    if [[ "$CORRUPT_COPY" == 1 && "$destination" == "$OUT_CHAIN" ]]; then
        printf 'invalid certificate copy\n' >"$destination" || return 1
    fi
}

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -subj '/CN=Domain Fixture Root CA' -days 10 -keyout "$TEST_ROOT/root.key" \
    -out "$TEST_ROOT/root.pem" >/dev/null 2>&1
openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -subj "/CN=$DOMAIN" -keyout "$TEST_ROOT/new.key" \
    -out "$TEST_ROOT/new.csr" >/dev/null 2>&1
printf '%s\n' 'basicConstraints=critical,CA:FALSE' 'keyUsage=critical,digitalSignature' \
    'extendedKeyUsage=serverAuth' "subjectAltName=DNS:$DOMAIN" >"$TEST_ROOT/leaf.ext"
openssl x509 -req -in "$TEST_ROOT/new.csr" -CA "$TEST_ROOT/root.pem" \
    -CAkey "$TEST_ROOT/root.key" -set_serial 10 -days 3 -extfile "$TEST_ROOT/leaf.ext" \
    -out "$TEST_ROOT/new.pem" >/dev/null 2>&1
cat "$TEST_ROOT/new.pem" "$TEST_ROOT/root.pem" >"$TEST_ROOT/fullchain.pem"
# A private CA is substituted only in this fixture process, never on disk or in
# the public production interface.
eval "$(declare -f rs_cert_validate | sed '1s/rs_cert_validate/fixture_validate/')"
rs_cert_validate() {
    printf '%s\n' "$1" >>"$TEST_ROOT/validations"
    fixture_validate "$1" "$2" "$TEST_ROOT/root.pem"
}

reject 'manual mode requires both input files' rs_cert_prepare_domain "$OUT_CHAIN" "$OUT_KEY"
reject 'incomplete argument list rejected' rs_cert_prepare_domain "$OUT_CHAIN" "$OUT_KEY" "$TEST_ROOT/fullchain.pem"
reject 'relative manual input rejected' rs_cert_prepare_domain "$OUT_CHAIN" "$OUT_KEY" fullchain.pem "$TEST_ROOT/new.key"
reject 'relative candidate output rejected' rs_cert_prepare_domain fullchain.pem "$OUT_KEY" "$TEST_ROOT/fullchain.pem" "$TEST_ROOT/new.key"
reject 'same output paths rejected' rs_cert_prepare_domain "$OUT_CHAIN" "$OUT_CHAIN" "$TEST_ROOT/fullchain.pem" "$TEST_ROOT/new.key"
reject 'aliased output paths rejected' rs_cert_prepare_domain "$OUT_CHAIN" "${OUT_CHAIN%/*}/../generation.candidate/fullchain.pem" "$TEST_ROOT/fullchain.pem" "$TEST_ROOT/new.key"

rs_cert_prepare_domain "$OUT_CHAIN" "$OUT_KEY" "$TEST_ROOT/fullchain.pem" "$TEST_ROOT/new.key"
cmp "$OUT_CHAIN" "$TEST_ROOT/fullchain.pem"
cmp "$OUT_KEY" "$TEST_ROOT/new.key"
[[ $(stat -c '%a %u' "$OUT_CHAIN") == '600 0' && $(stat -c '%a %u' "$OUT_KEY") == '600 0' ]]
[[ $(wc -l <"$TEST_ROOT/validations") == 2 ]]
[[ $(tail -n 1 "$TEST_ROOT/validations") == "$OUT_CHAIN" ]]
assert_unchanged
pass 'manual candidate is copied privately and validated again after freezing'

DOMAIN=wrong.example.test
reject 'certificate for the wrong new domain rejected' rs_cert_prepare_domain "$OUT_CHAIN" "$OUT_KEY" "$TEST_ROOT/fullchain.pem" "$TEST_ROOT/new.key"
DOMAIN=new.example.test
reject 'mismatched manual private key rejected' rs_cert_prepare_domain "$OUT_CHAIN" "$OUT_KEY" "$TEST_ROOT/fullchain.pem" "$TEST_ROOT/root.key"
chmod 0666 "$TEST_ROOT/fullchain.pem"
reject 'writable manual certificate rejected' rs_cert_prepare_domain "$OUT_CHAIN" "$OUT_KEY" "$TEST_ROOT/fullchain.pem" "$TEST_ROOT/new.key"
chmod 0600 "$TEST_ROOT/fullchain.pem"
ln -s "$TEST_ROOT/fullchain.pem" "$TEST_ROOT/linked.pem"
reject 'symlink manual certificate rejected' rs_cert_prepare_domain "$OUT_CHAIN" "$OUT_KEY" "$TEST_ROOT/linked.pem" "$TEST_ROOT/new.key"
ln "$TEST_ROOT/new.key" "$TEST_ROOT/linked.key"
reject 'hard-linked manual key rejected' rs_cert_prepare_domain "$OUT_CHAIN" "$OUT_KEY" "$TEST_ROOT/fullchain.pem" "$TEST_ROOT/new.key"
rm "$TEST_ROOT/linked.key"
for FAIL_INSTALL in "$OUT_CHAIN" "$OUT_KEY"; do
    reject 'failed candidate copy propagates under conditional invocation' rs_cert_prepare_domain "$OUT_CHAIN" "$OUT_KEY" "$TEST_ROOT/fullchain.pem" "$TEST_ROOT/new.key"
done
FAIL_INSTALL=
CORRUPT_COPY=1
reject 'changed frozen copy rejected by the second validation' rs_cert_prepare_domain "$OUT_CHAIN" "$OUT_KEY" "$TEST_ROOT/fullchain.pem" "$TEST_ROOT/new.key"
CORRUPT_COPY=0

CERT_MODE=cloudflare
rs_cert_paths
reject 'missing ACME home rejected without creating it' rs_cert_prepare_domain "$OUT_CHAIN" "$OUT_KEY"
[[ ! -e "$ACME_HOME" && ! -e "$TEST_ROOT/acme-args" ]]
mkdir -m 0700 "$ACME_HOME" "$ACME_HOME/dnsapi" "$ACME_HOME/${DOMAIN}_ecc" "$ACME_HOME/old.example.test_ecc"
printf '#!/bin/sh\nexit 0\n' >"$ACME_HOME/acme.sh"
printf '#!/bin/sh\n# existing hook\n' >"$ACME_HOME/dnsapi/dns_realitysite.sh"
printf '%s\n%s\n' fixture_token_01234567890123456789 0123456789abcdef0123456789abcdef >"$ACME_HOME/cloudflare.credentials"
rs_cert_cf_store_zone old.example.test 0123456789abcdef0123456789abcdef
chmod 0700 "$ACME_HOME/acme.sh" "$ACME_HOME/dnsapi/dns_realitysite.sh"
printf 'old ACME account/domain files\n' >"$ACME_HOME/old.example.test_ecc/old.example.test.conf"
sha256sum "$ACME_HOME/old.example.test_ecc/old.example.test.conf" \
    "$ACME_HOME/acme.sh" "$ACME_HOME/dnsapi/dns_realitysite.sh" \
    "$ACME_HOME/cloudflare.credentials" >"$TEST_ROOT/old-acme.sha256"
cp "$TEST_ROOT/fullchain.pem" "$ACME_HOME/${DOMAIN}_ecc/fullchain.cer"
cp "$TEST_ROOT/new.key" "$ACME_HOME/${DOMAIN}_ecc/${DOMAIN}.key"
reject 'Cloudflare mode rejects manual inputs' rs_cert_prepare_domain "$OUT_CHAIN" "$OUT_KEY" "$TEST_ROOT/fullchain.pem" "$TEST_ROOT/new.key"
[[ ! -e "$TEST_ROOT/acme-args" ]]
for result in 0 2; do
    ACME_RESULT=$result
    rs_cert_prepare_domain "$OUT_CHAIN" "$OUT_KEY"
    cmp "$OUT_CHAIN" "$TEST_ROOT/fullchain.pem"
    cmp "$OUT_KEY" "$TEST_ROOT/new.key"
    cmp "$TEST_ROOT/acme-args" <(printf '%s\n' --issue --server letsencrypt --dns dns_realitysite -d "$DOMAIN" --keylength ec-256)
    assert_unchanged
    pass "ACME exit $result validates candidate without force, register, revoke, reload or state changes"
done
ACME_RESULT=1
reject 'ACME failure preserves active state and old ACME files' rs_cert_prepare_domain "$OUT_CHAIN" "$OUT_KEY"
ACME_RESULT=2
printf 'invalid certificate\n' >"$ACME_HOME/${DOMAIN}_ecc/fullchain.cer"
reject 'ACME skip still requires a valid existing certificate' rs_cert_prepare_domain "$OUT_CHAIN" "$OUT_KEY"
cp "$TEST_ROOT/fullchain.pem" "$ACME_HOME/${DOMAIN}_ecc/fullchain.cer"
for path in "$ACME_HOME/acme.sh" "$ACME_HOME/cloudflare.credentials" "$ACME_HOME/dnsapi/dns_realitysite.sh"; do
    original_mode=$(stat -c '%a' "$path")
    chmod 0644 "$path"
    rm -f "$TEST_ROOT/acme-args"
    reject 'unsafe ACME file mode rejected before issuance' rs_cert_prepare_domain "$OUT_CHAIN" "$OUT_KEY"
    [[ ! -e "$TEST_ROOT/acme-args" ]]
    chmod "$original_mode" "$path"
done
for path in "$ACME_HOME/acme.sh" "$ACME_HOME/cloudflare.credentials" "$ACME_HOME/dnsapi/dns_realitysite.sh"; do
    mv "$path" "$TEST_ROOT/acme-file.saved"
    # Temporarily omit the snapshot containing the intentionally missing file.
    mv "$TEST_ROOT/old-acme.sha256" "$TEST_ROOT/old-acme.sha256.saved"
    reject 'missing ACME file rejected without repair' rs_cert_prepare_domain "$OUT_CHAIN" "$OUT_KEY"
    [[ ! -e "$path" && ! -e "$TEST_ROOT/acme-args" ]]
    mv "$TEST_ROOT/acme-file.saved" "$path"
    mv "$TEST_ROOT/old-acme.sha256.saved" "$TEST_ROOT/old-acme.sha256"
done
chmod 0755 "$ACME_HOME/dnsapi"
reject 'non-private ACME hook directory rejected' rs_cert_prepare_domain "$OUT_CHAIN" "$OUT_KEY"
chmod 0700 "$ACME_HOME/dnsapi"
mv "$ACME_HOME/${DOMAIN}_ecc" "$TEST_ROOT/acme-domain.saved"
ln -s "$TEST_ROOT/acme-domain.saved" "$ACME_HOME/${DOMAIN}_ecc"
reject 'symlink new-domain ACME directory rejected' rs_cert_prepare_domain "$OUT_CHAIN" "$OUT_KEY"
rm "$ACME_HOME/${DOMAIN}_ecc"
mv "$TEST_ROOT/acme-domain.saved" "$ACME_HOME/${DOMAIN}_ecc"
CERT_MODE=unknown
reject 'unsupported mode rejected' rs_cert_prepare_domain "$OUT_CHAIN" "$OUT_KEY"
assert_unchanged
printf '%d domain certificate preparation checks passed.\n' "$PASSED"
