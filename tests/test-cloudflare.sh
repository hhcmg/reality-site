#!/usr/bin/env bash
# Offline Cloudflare discovery, credential migration and DNS hook routing tests.
# All files live in a private temporary fixture. No API call, certificate issue,
# DNS mutation, package installation, or service operation is performed.
set -Eeuo pipefail
umask 077
(( EUID == 0 )) || { printf 'Run these ownership tests as root.\n' >&2; exit 1; }
if [[ -n ${TEST_JQ_BIN:-} ]]; then jq() { "$TEST_JQ_BIN" "$@"; }; fi
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source "$HERE/../lib/common.sh"
source "$HERE/../lib/cert.sh"
TEST_ROOT=$(mktemp -d /tmp/reality-site-cloudflare.XXXXXXXX)
trap '[[ $TEST_ROOT == /tmp/reality-site-cloudflare.* ]] && rm -rf -- "$TEST_ROOT"' EXIT
DATA_DIR="$TEST_ROOT/data"
TMP_DIR="$TEST_ROOT/tmp"
DOMAIN=node.example.com
CERT_MODE=cloudflare
mkdir -m 0700 "$DATA_DIR" "$TMP_DIR"
rs_cert_paths
mkdir -m 0700 "$ACME_HOME" "$ACME_HOME/dnsapi"
ZONE_ONE=11111111111111111111111111111111
ZONE_TWO=22222222222222222222222222222222
ZONE_CHILD=abcdef0123456789abcdef0123456789
FIXTURE_TOKEN=fixture_token_never_display_0123456789
PASSED=0
declare -A API_RESPONSES=() API_STATUSES=()
pass() { PASSED=$((PASSED + 1)); printf 'PASS %s\n' "$*"; }
reject() {
    local label=$1
    shift
    if ( "$@" ) >"$TEST_ROOT/rejected.log" 2>&1; then die "Unexpected success: $label"; fi
    ! grep -Fq "$FIXTURE_TOKEN" "$TEST_ROOT/rejected.log" || die 'Token exposed in error output.'
    pass "$label"
}
# Belt-and-braces guard: the fixture substitutes every network boundary.
curl() { die 'Unexpected network access in offline fixture.'; }
systemctl() { die 'Unexpected service operation in offline fixture.'; }
rs_cert_run_acme() { die 'Unexpected ACME operation in offline fixture.'; }

# Dynamic local token scope matches the production reader/HTTP helper contract.
rs_cert_cf_api_get() {
    local endpoint=$1 name
    [[ "$token" == "$FIXTURE_TOKEN" ]] || die 'Token was not provided to the API helper.'
    printf '%s\n' "$endpoint" >>"$TEST_ROOT/requests"
    name=${endpoint#zones?name=}
    name=${name%%&*}
    [[ "$endpoint" == "zones?name=${name}&match=all&page=1&per_page=50" && -v "API_RESPONSES[$name]" ]] \
        || { printf 'Unexpected fixture API request.\n' >&2; return 97; }
    printf '%s\n' "${API_RESPONSES[$name]}"
    return "${API_STATUSES[$name]:-0}"
}
fixture_response() {
    jq -nc --argjson result "$1" '{success:true,errors:[],result:$result,
      result_info:{page:1,per_page:50,count:($result|length),total_count:($result|length),total_pages:1}}'
}
reset_api() {
    API_RESPONSES=()
    API_STATUSES=()
    : >"$TEST_ROOT/requests"
}
empty_zone() { API_RESPONSES["$1"]=$(fixture_response '[]'); }
add_zone() {
    local query=$1 id=$2 name=${3:-$1}
    API_RESPONSES["$query"]=$(fixture_response "$(jq -nc --arg id "$id" --arg name "$name" '[{id:$id,name:$name}]')")
}
discover() {
    local token=$FIXTURE_TOKEN zone=''
    rs_cert_cf_discover_zone "$1"
}
discovery_case() {
    local expected=$1 domain=$2 expected_id=$3 names=$4 label=$5 result=0 query expected_queries=''
    discover "$domain" >"$TEST_ROOT/result" 2>"$TEST_ROOT/diagnostics" || result=$?
    if [[ "$expected" == success ]]; then
        [[ $result == 0 && $(cat "$TEST_ROOT/result") == "$expected_id" ]] || die "Discovery failed: $label"
    else
        [[ $result != 0 && ! -s "$TEST_ROOT/result" ]] || die "Discovery accepted unsafe input/response: $label"
    fi
    while IFS= read -r query; do
        [[ -z "$query" ]] || expected_queries+="zones?name=$query&match=all&page=1&per_page=50"$'\n'
    done <<<"$names"
    [[ $(cat "$TEST_ROOT/requests") == "${expected_queries%$'\n'}" ]] || die "Unexpected query sequence: $label"
    ! grep -Fq "$FIXTURE_TOKEN" "$TEST_ROOT/result" "$TEST_ROOT/diagnostics" "$TEST_ROOT/requests" || die 'Token leaked by discovery.'
    [[ ! -e "$ACME_HOME/cloudflare.credentials" && ! -e "$ACME_HOME/cloudflare-zones.json" ]] || die 'Discovery unexpectedly persisted state.'
    pass "$label"
}

reset_api
empty_zone node.example.org
add_zone example.org "$ZONE_ONE"
discovery_case success node.example.org "$ZONE_ONE" $'node.example.org\nexample.org' 'first root domain selected'
reset_api
empty_zone node.example.net
add_zone example.net "$ZONE_TWO"
discovery_case success node.example.net "$ZONE_TWO" $'node.example.net\nexample.net' 'same token selects a second root domain'
reset_api
add_zone example.com "$ZONE_ONE"
discovery_case success example.com "$ZONE_ONE" example.com 'zone apex accepted'
reset_api
empty_zone node.a.example.com
add_zone a.example.com "$ZONE_CHILD"
add_zone example.com "$ZONE_ONE"
discovery_case success node.a.example.com "$ZONE_CHILD" $'node.a.example.com\na.example.com' 'delegated child zone wins over parent'
reset_api
add_zone node.a.example.com "$ZONE_CHILD"
discovery_case success node.a.example.com "$ZONE_CHILD" node.a.example.com 'full hostname can be a zone'
reset_api
empty_zone node.a.example.co.uk
empty_zone a.example.co.uk
add_zone example.co.uk "$ZONE_TWO"
discovery_case success node.a.example.co.uk "$ZONE_TWO" $'node.a.example.co.uk\na.example.co.uk\nexample.co.uk' 'multi-label public suffix does not assume final two labels'
reset_api
empty_zone node.example.com
empty_zone example.com
discovery_case failure node.example.com '' $'node.example.com\nexample.com' 'no match never queries bare TLD'

for domain in '' example localhost node..example.com -node.example.com \
    'node.example.com?account=other' 'node.example.com/anything' 'node.example.com.' \
    'https://node.example.com' '1.2.3.4' $'node.example.com\nother.example.com'; do
    reset_api
    discovery_case failure "$domain" '' '' 'invalid domain rejected before API request'
done
for status in 22 28; do
    reset_api
    empty_zone node.example.com
    API_STATUSES[node.example.com]=$status
    add_zone example.com "$ZONE_ONE"
    discovery_case failure node.example.com '' node.example.com 'HTTP/network failure never falls back to a parent zone'
done
reset_api
API_RESPONSES[node.example.com]=$(jq -nc --arg secret "$FIXTURE_TOKEN" '{success:false,errors:[{code:10000,message:$secret}],result:null}')
add_zone example.com "$ZONE_ONE"
discovery_case failure node.example.com '' node.example.com 'permission error is sanitized and stops lookup'
for response in '' '{' 'null' '[]' 'true' '"unexpected"' \
    '{"success":"true","result":[]}' '{"success":true,"result":null}' \
    '{"success":true,"result":{}}' '{"success":true,"result":"[]"}' \
    '{"success":true,"result":[]} {"success":true,"result":[]}' '{"success":true}'; do
    reset_api
    API_RESPONSES[node.example.com]=$response
    add_zone example.com "$ZONE_ONE"
    discovery_case failure node.example.com '' node.example.com 'malformed API response never selects parent'
done
for result in \
    '[{"name":"unrelated.net","id":"11111111111111111111111111111111"}]' \
    '[{"name":"example.com","id":"11111111111111111111111111111111"}]' \
    '[{"name":"node.example.com","id":""}]' '[{"name":"node.example.com","id":"1234"}]' \
    '[{"name":"node.example.com","id":"zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"}]' \
    '[{"name":"node.example.com","id":111}]' '[{"name":null,"id":"11111111111111111111111111111111"}]' \
    '[null]' \
    '[{"name":"node.example.com","id":"11111111111111111111111111111111"},{"name":"node.example.com","id":"22222222222222222222222222222222"}]'; do
    reset_api
    API_RESPONSES[node.example.com]=$(fixture_response "$result")
    add_zone example.com "$ZONE_ONE"
    discovery_case failure node.example.com '' node.example.com 'invalid or ambiguous zone fails closed'
done
for mutation in '.result_info.total_pages=2 | .result_info.total_count=2' '.result_info.page=2' \
    '.result_info.total_count=2' '.result_info.count=0' '.result_info.total_pages="1"' \
    '.result_info.total_count="1"' '.result_info.page="1"' '.result_info=null' '.result_info=[]'; do
    reset_api
    add_zone node.example.com "$ZONE_CHILD"
    API_RESPONSES[node.example.com]=$(jq -c "$mutation" <<<"${API_RESPONSES[node.example.com]}")
    add_zone example.com "$ZONE_ONE"
    discovery_case failure node.example.com '' node.example.com 'partial or inconsistent pagination fails closed'
done
for mutation in 'del(.result_info)' '.result_info={}' '.result_info={page:1,total_count:1}'; do
    reset_api
    add_zone example.com "$ZONE_ONE"
    API_RESPONSES[example.com]=$(jq -c "$mutation" <<<"${API_RESPONSES[example.com]}")
    discovery_case success example.com "$ZONE_ONE" example.com 'optional pagination fields may be absent'
done

write_credentials() { printf '%s\n%s\n' "$FIXTURE_TOKEN" "$ZONE_ONE" >"$ACME_HOME/cloudflare.credentials"; chmod 0600 "$ACME_HOME/cloudflare.credentials"; }
check_credentials() {
    local token='' zone=''
    rs_cert_cf_read_credentials
    [[ "$token" == "$FIXTURE_TOKEN" && "$zone" == "$ZONE_ONE" ]]
}
write_credentials
check_credentials
pass 'legacy two-line credentials read into caller locals'
sha256sum "$ACME_HOME/cloudflare.credentials" >"$TEST_ROOT/credentials.sha256"
chmod 0644 "$ACME_HOME/cloudflare.credentials"
reject 'credentials must remain private' check_credentials
chmod 0600 "$ACME_HOME/cloudflare.credentials"
ln "$ACME_HOME/cloudflare.credentials" "$TEST_ROOT/credential-hardlink"
reject 'hard-linked credential file rejected' check_credentials
rm "$TEST_ROOT/credential-hardlink"
printf 'unterminated extra line' >>"$ACME_HOME/cloudflare.credentials"
reject 'unterminated extra credential line rejected' check_credentials
write_credentials

# A renewal upgrade uses the stored zone and must work without Zone Read.
reset_api
printf '#!/bin/sh\n# legacy hook\n' >"$ACME_HOME/dnsapi/dns_realitysite.sh"
chmod 0700 "$ACME_HOME/dnsapi/dns_realitysite.sh"
rs_cert_cf_sync_hook
[[ ! -s "$TEST_ROOT/requests" ]]
sha256sum --status -c "$TEST_ROOT/credentials.sha256"
[[ $(jq -r --arg d "$DOMAIN" '.zones[$d]' "$ACME_HOME/cloudflare-zones.json") == "$ZONE_ONE" ]]
[[ $(stat -c '%a' "$ACME_HOME/cloudflare-zones.json") == 600 ]]
sh -n "$ACME_HOME/dnsapi/dns_realitysite.sh"
[[ $(stat -c '%a' "$ACME_HOME/dnsapi/dns_realitysite.sh") == 700 ]]
pass 'legacy hook upgrade seeds active domain mapping without API calls or credential replacement'
rs_cert_cf_sync_hook
[[ ! -s "$TEST_ROOT/requests" ]]
pass 'repeated hook sync is offline and idempotent'
sha256sum "$ACME_HOME/dnsapi/dns_realitysite.sh" >"$TEST_ROOT/hook.sha256"
fail_hook_render() (
    cat() { return 1; }
    rs_cert_cf_sync_hook
)
reject 'hook render failure propagates under conditional invocation' fail_hook_render
sha256sum --status -c "$TEST_ROOT/hook.sha256"
pass 'failed hook upgrade leaves the prior executable hook intact'

DOMAIN=node.example.net
reset_api
empty_zone "$DOMAIN"
add_zone example.net "$ZONE_TWO"
rs_cert_cf_prepare_domain
sha256sum --status -c "$TEST_ROOT/credentials.sha256"
[[ $(jq -r '.zones["node.example.com"]' "$ACME_HOME/cloudflare-zones.json") == "$ZONE_ONE" ]]
[[ $(jq -r '.zones["node.example.net"]' "$ACME_HOME/cloudflare-zones.json") == "$ZONE_TWO" ]]
pass 'cross-zone preparation preserves old mapping and immutable legacy credentials'
sha256sum "$ACME_HOME/cloudflare-zones.json" >"$TEST_ROOT/mapping.sha256"
DOMAIN=denied.example.net
reset_api
API_RESPONSES[$DOMAIN]='{"success":false,"errors":[{"code":10000}],"result":null}'
reject 'failed cross-zone lookup cannot change saved credentials or mappings' rs_cert_cf_prepare_domain
sha256sum --status -c "$TEST_ROOT/credentials.sha256"
sha256sum --status -c "$TEST_ROOT/mapping.sha256"
reject 'existing mapping missing active domain is not silently assigned the legacy zone' rs_cert_cf_sync_hook
DOMAIN=node.example.com

rs_cert_cf_store_zone third.example.net "$ZONE_CHILD"
rs_cert_cf_validate_zones
[[ $(jq -r '.zones["node.example.net"]' "$ACME_HOME/cloudflare-zones.json") == "$ZONE_TWO" ]]
pass 'adding a mapping retains other saved domain assignments'
cp "$ACME_HOME/cloudflare-zones.json" "$TEST_ROOT/zones.saved"
reject 'invalid mapping domain rejected' rs_cert_cf_store_zone 'invalid.domain?query=1' "$ZONE_ONE"
reject 'invalid zone ID rejected' rs_cert_cf_store_zone node.example.com wrong
cmp "$TEST_ROOT/zones.saved" "$ACME_HOME/cloudflare-zones.json"
chmod 0644 "$ACME_HOME/cloudflare-zones.json"
reject 'non-private mapping file rejected' rs_cert_cf_validate_zones
chmod 0600 "$ACME_HOME/cloudflare-zones.json"
for malformed in '{' '{"schema":2,"zones":{}}' '{"schema":1,"zones":[]}' \
    '{"schema":1,"zones":{"node.example.com":"short"}}' \
    '{"schema":1,"zones":{"bad?name":"11111111111111111111111111111111"}}'; do
    printf '%s\n' "$malformed" >"$ACME_HOME/cloudflare-zones.json"
    reject 'malformed map never gets repaired by overwriting it' rs_cert_cf_store_zone node.example.com "$ZONE_ONE"
done
cp "$TEST_ROOT/zones.saved" "$ACME_HOME/cloudflare-zones.json"

# Exercise the generated POSIX hook, including both add and cleanup URL paths.
# A portable jq is substituted only into this temporary generated fixture.
if [[ -n ${TEST_JQ_BIN:-} ]]; then
    sed -i "s|/usr/bin/jq|$TEST_JQ_BIN|g" "$ACME_HOME/dnsapi/dns_realitysite.sh"
fi
source "$ACME_HOME/dnsapi/dns_realitysite.sh"
_err() { printf '%s\n' "$*" >&2; }
_rs_cf_api() {
    printf '%s %s\n' "$1" "$2" >>"$TEST_ROOT/hook-requests"
    case "$1" in
        GET)
            if [[ ${HOOK_EXISTING:-0} == 1 ]]; then
                jq -nc --arg name "${RS_CF_FIND_NAME:?}" --arg value "${RS_CF_FIND_VALUE:?}" \
                    '{success:true,result:[{id:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",type:"TXT",name:$name,content:$value}],result_info:{total_pages:1}}'
            else
                printf '%s\n' '{"success":true,"result":[],"result_info":{"total_pages":0}}'
            fi ;;
        POST|DELETE) printf '%s\n' '{"success":true}' ;;
        *) return 98 ;;
    esac
}
_rs_cf_load_credentials
_rs_cf_select_zone _acme-challenge.node.example.com
[[ "$RS_CF_ZONE_ID" == "$ZONE_ONE" ]]
_rs_cf_select_zone _acme-challenge.node.example.net
[[ "$RS_CF_ZONE_ID" == "$ZONE_TWO" ]]
pass 'generated hook selects the exact domain mapping rather than the legacy zone'
for record in _acme-challenge.unknown.example.com node.example.com _acme-challenge.; do
    reject 'unmapped or malformed challenge must not reuse the last selected zone' _rs_cf_select_zone "$record"
done
for domain in node.example.com node.example.net; do
    if [[ "$domain" == node.example.com ]]; then expected_zone=$ZONE_ONE; else expected_zone=$ZONE_TWO; fi
    : >"$TEST_ROOT/hook-requests"
    HOOK_EXISTING=0
    dns_realitysite_add "_acme-challenge.$domain" fixture_challenge_0123456789
    grep -Fq "POST https://api.cloudflare.com/client/v4/zones/$expected_zone/dns_records" "$TEST_ROOT/hook-requests"
    HOOK_EXISTING=1
    dns_realitysite_rm "_acme-challenge.$domain" fixture_challenge_0123456789
    grep -Fq "DELETE https://api.cloudflare.com/client/v4/zones/$expected_zone/dns_records/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$TEST_ROOT/hook-requests"
    pass "hook add and cleanup both use the selected zone for $domain"
done
chmod 0644 "$ACME_HOME/cloudflare-zones.json"
reject 'hook fails closed on an unsafe map' dns_realitysite_add _acme-challenge.node.example.com fixture_challenge_0123456789
chmod 0600 "$ACME_HOME/cloudflare-zones.json"
mv "$ACME_HOME/cloudflare-zones.json" "$TEST_ROOT/zones.absent"
_rs_cf_load_credentials
_rs_cf_select_zone _acme-challenge.node.example.com
[[ "$RS_CF_ZONE_ID" == "$ZONE_ONE" ]]
pass 'hook retains legacy fallback only when no mapping file exists'
printf '%d Cloudflare checks passed.\n' "$PASSED"
