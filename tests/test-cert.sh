#!/usr/bin/env bash
# Offline certificate validation and transactional publication tests; no network,
# package install, system service, DNS zone, or system trust store is modified.
set -Eeuo pipefail
umask 077
[[ $EUID == 0 ]] || { printf '%s\n' 'Run this fixture test as root (temporary files only).' >&2; exit 1; }
if [[ -n ${TEST_JQ_BIN:-} ]]; then jq() { "$TEST_JQ_BIN" "$@"; }; fi
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TEST_ROOT=$(mktemp -d /tmp/reality-site-cert-test.XXXXXXXX)
trap 'rm -rf -- "$TEST_ROOT"' EXIT
export TEST_ROOT
DATA_DIR="$TEST_ROOT/data"
TMP_DIR="$TEST_ROOT/tmp"
mkdir -m 0700 "$DATA_DIR" "$TMP_DIR"
DOMAIN='site.example.test'
CERT_MODE=manual
SERVICE_NAME='reality-site.service'
NGINX_BIN="$TEST_ROOT/nginx"
source "$HERE/../lib/common.sh"
info() { :; }
warn() { printf '%s\n' "$*" >&2; }
die() { warn "$*"; exit 1; }
rs_require_root() { [[ $EUID == 0 ]] || die 'not root'; }
rs_secure_file() {
    [[ -f $1 && ! -L $1 && $(stat -c '%u' -- "$1") == 0 ]] || die 'unsafe file'
    local permission
    permission=$(stat -c '%a' -- "$1")
    (( (8#$permission & 8#022) == 0 )) || die 'writable file'
}
rs_assert_owned_output() {
    rs_secure_file "$1"
    [[ $(head -n 1 -- "$1") == '# Managed by reality-site' ]] || die 'not managed output'
}
source "$HERE/../lib/cert.sh"
passed=0
ok() { passed=$((passed + 1)); printf 'ok %d - %s\n' "$passed" "$*"; }
reject() {
    local name=$1
    shift
    if ( "$@" ) >"$TEST_ROOT/rejected.log" 2>&1; then die "unexpected success: $name"; fi
    ok "$name"
}

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -subj '/CN=Fixture Root CA' -days 10 -keyout "$TEST_ROOT/root.key" \
    -out "$TEST_ROOT/root.pem" >/dev/null 2>&1
openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -subj '/CN=Fixture Intermediate CA' -keyout "$TEST_ROOT/intermediate.key" \
    -out "$TEST_ROOT/intermediate.csr" >/dev/null 2>&1
printf '%s\n' 'basicConstraints=critical,CA:TRUE,pathlen:0' \
    'keyUsage=critical,keyCertSign,cRLSign' >"$TEST_ROOT/ca.ext"
openssl x509 -req -in "$TEST_ROOT/intermediate.csr" -CA "$TEST_ROOT/root.pem" \
    -CAkey "$TEST_ROOT/root.key" -set_serial 2 -days 7 -extfile "$TEST_ROOT/ca.ext" \
    -out "$TEST_ROOT/intermediate.pem" >/dev/null 2>&1
openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -subj "/CN=$DOMAIN" -keyout "$TEST_ROOT/site.key" -out "$TEST_ROOT/site.csr" >/dev/null 2>&1
printf '%s\n' 'basicConstraints=critical,CA:FALSE' 'keyUsage=critical,digitalSignature' \
    'extendedKeyUsage=serverAuth' "subjectAltName=DNS:$DOMAIN" >"$TEST_ROOT/leaf.ext"
for version in 1 2; do
    openssl x509 -req -in "$TEST_ROOT/site.csr" -CA "$TEST_ROOT/intermediate.pem" \
        -CAkey "$TEST_ROOT/intermediate.key" -set_serial "$((10 + version))" -days 3 \
        -extfile "$TEST_ROOT/leaf.ext" -out "$TEST_ROOT/leaf$version.pem" >/dev/null 2>&1
    cat "$TEST_ROOT/leaf$version.pem" "$TEST_ROOT/intermediate.pem" >"$TEST_ROOT/chain$version.pem"
done
rs_cert_validate "$TEST_ROOT/chain1.pem" "$TEST_ROOT/site.key" "$TEST_ROOT/root.pem"
ok 'valid SAN, matching EC key and complete trusted chain'
reject 'wrong private key' rs_cert_validate "$TEST_ROOT/chain1.pem" "$TEST_ROOT/root.key" "$TEST_ROOT/root.pem"
reject 'missing intermediate certificate' rs_cert_validate "$TEST_ROOT/leaf1.pem" "$TEST_ROOT/site.key" "$TEST_ROOT/root.pem"
reject 'private fixture CA rejected by system trust store' rs_cert_validate "$TEST_ROOT/chain1.pem" "$TEST_ROOT/site.key"
DOMAIN='wrong.example.test'
reject 'wrong domain' rs_cert_validate "$TEST_ROOT/chain1.pem" "$TEST_ROOT/site.key" "$TEST_ROOT/root.pem"
DOMAIN='site.example.test'
openssl x509 -req -in "$TEST_ROOT/site.csr" -CA "$TEST_ROOT/intermediate.pem" \
    -CAkey "$TEST_ROOT/intermediate.key" -set_serial 20 -days 0 -extfile "$TEST_ROOT/leaf.ext" \
    -out "$TEST_ROOT/expired.pem" >/dev/null 2>&1
cat "$TEST_ROOT/expired.pem" "$TEST_ROOT/intermediate.pem" >"$TEST_ROOT/expired-chain.pem"
reject 'expired certificate' rs_cert_validate "$TEST_ROOT/expired-chain.pem" "$TEST_ROOT/site.key" "$TEST_ROOT/root.pem"
openssl pkey -in "$TEST_ROOT/site.key" -aes-256-cbc -passout pass:fixture \
    -out "$TEST_ROOT/encrypted.key" >/dev/null 2>&1
reject 'encrypted private key does not prompt' rs_cert_validate "$TEST_ROOT/chain1.pem" "$TEST_ROOT/encrypted.key" "$TEST_ROOT/root.pem"

# Substitute the private fixture CA only inside this test process. Production
# rs_cert_publish has no option to bypass the system's public CA trust store.
eval "$(declare -f rs_cert_validate | sed '1s/rs_cert_validate/fixture_validate/')"
rs_cert_validate() { fixture_validate "$1" "$2" "$TEST_ROOT/root.pem"; }
cat >"$NGINX_BIN" <<'NGINX'
#!/usr/bin/env bash
[[ ! -e "$TEST_ROOT/nginx-fail" ]]
NGINX
chmod 0700 "$NGINX_BIN"
systemctl() {
    case "$1" in
        is-active) [[ -f "$TEST_ROOT/service-active" ]] ;;
        reload)
            printf 'reload\n' >>"$TEST_ROOT/reloads"
            if [[ -f "$TEST_ROOT/reload-fail-once" ]]; then
                rm -f "$TEST_ROOT/reload-fail-once"
                return 1
            fi
            ;;
        *) die 'unexpected systemctl invocation in fixture' ;;
    esac
}
rs_cert_import "$TEST_ROOT/chain1.pem" "$TEST_ROOT/site.key"
first=$(readlink "$DATA_DIR/certs/live")
[[ -f "$DATA_DIR/certs/live/fullchain.pem" && $(stat -c '%a' "$DATA_DIR/certs/live/key.pem") == 600 ]]
ok 'initial import publishes private generation and relative atomic link'
printf '%s\n' '# foreign configuration' >"$DATA_DIR/nginx.conf"
reject 'unmanaged nginx configuration is never validated or reloaded' rs_cert_import "$TEST_ROOT/chain2.pem" "$TEST_ROOT/site.key"
[[ $(readlink "$DATA_DIR/certs/live") == "$first" ]]
printf '%s\n' '# Managed by reality-site' >"$DATA_DIR/nginx.conf"
touch "$TEST_ROOT/service-active"
rs_cert_import "$TEST_ROOT/chain2.pem" "$TEST_ROOT/site.key"
second=$(readlink "$DATA_DIR/certs/live")
[[ "$first" != "$second" && $(wc -l <"$TEST_ROOT/reloads") == 1 ]]
ok 'replacement validates configuration and reloads only the site service'
touch "$TEST_ROOT/nginx-fail"
reject 'configuration failure rolls back' rs_cert_import "$TEST_ROOT/chain1.pem" "$TEST_ROOT/site.key"
[[ $(readlink "$DATA_DIR/certs/live") == "$second" ]]
rm "$TEST_ROOT/nginx-fail"
touch "$TEST_ROOT/reload-fail-once"
reject 'reload failure rolls back and reloads old certificate' rs_cert_import "$TEST_ROOT/chain1.pem" "$TEST_ROOT/site.key"
[[ $(readlink "$DATA_DIR/certs/live") == "$second" && $(wc -l <"$TEST_ROOT/reloads") == 3 ]]
ok 'old certificate remains selected after failed reload'
chmod 0666 "$TEST_ROOT/chain1.pem"
reject 'group-writable imported certificate rejected' rs_cert_import "$TEST_ROOT/chain1.pem" "$TEST_ROOT/site.key"
chmod 0600 "$TEST_ROOT/chain1.pem"

CERT_MODE=cloudflare
rs_cert_paths
mkdir -m 0700 "$ACME_HOME" "$ACME_HOME/dnsapi" "$ACME_HOME/${DOMAIN}_ecc"
touch "$ACME_HOME/acme.sh" "$ACME_HOME/dnsapi/dns_realitysite.sh"
printf '%s\n%s\n' 'fixture_token_012345678901234567890123456789' '0123456789abcdef0123456789abcdef' >"$ACME_HOME/cloudflare.credentials"
chmod 0700 "$ACME_HOME/acme.sh" "$ACME_HOME/dnsapi/dns_realitysite.sh"
cp "$TEST_ROOT/chain1.pem" "$ACME_HOME/${DOMAIN}_ecc/fullchain.cer"
cp "$TEST_ROOT/site.key" "$ACME_HOME/${DOMAIN}_ecc/${DOMAIN}.key"
rs_cert_run_acme() { return 2; }
rs_cert_renew
cmp "$DATA_DIR/certs/live/fullchain.pem" "$TEST_ROOT/chain1.pem"
ok 'renewal skip republishes ACME certificate after previous apply failure'
before=$(readlink "$DATA_DIR/certs/live")
rs_cert_renew
[[ $(readlink "$DATA_DIR/certs/live") == "$before" ]]
ok 'unchanged renewed certificate does not accumulate generations or reload'
rs_cert_run_acme() { return 1; }
reject 'ACME renewal failure preserves selected certificate' rs_cert_renew
[[ $(readlink "$DATA_DIR/certs/live") == "$before" ]]
rs_cert_render_dns_hook "$TEST_ROOT/dns_realitysite.sh"
sh -n "$TEST_ROOT/dns_realitysite.sh"
grep -Fq "$ACME_HOME/cloudflare.credentials" "$TEST_ROOT/dns_realitysite.sh"
! grep -Eq 'Authorization: Bearer.*--|/root/\.acme.sh|dns_realityself_' "$TEST_ROOT/dns_realitysite.sh"
ok 'DNS hook syntax and private credential path'
source "$TEST_ROOT/dns_realitysite.sh"
printf '%s\n%s\n' 'fixture_token_012345678901234567890123456789' '0123456789abcdef0123456789abcdef' >"$ACME_HOME/cloudflare.credentials"
_rs_cf_load_credentials
ok 'DNS hook loads root-only credential file without sourcing shell code'
chmod 0644 "$ACME_HOME/cloudflare.credentials"
reject 'DNS hook refuses non-private credential file' _rs_cf_load_credentials
chmod 0600 "$ACME_HOME/cloudflare.credentials"
printf 'unexpected third line\n' >>"$ACME_HOME/cloudflare.credentials"
reject 'DNS hook refuses malformed credential file' _rs_cf_load_credentials
printf '%s\n%s\n%s' 'fixture_token_012345678901234567890123456789' '0123456789abcdef0123456789abcdef' 'unterminated third line' >"$ACME_HOME/cloudflare.credentials"
reject 'DNS hook refuses unterminated third credential line' _rs_cf_load_credentials
printf '%d certificate tests passed.\n' "$passed"
