#!/usr/bin/env bash
# Run in a Linux test environment as root. No real service/sysctl changes.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
if [[ -n ${TEST_JQ_BIN:-} ]]; then
    jq() { "$TEST_JQ_BIN" "$@"; }
    export -f jq
fi
for script in "$ROOT/reality-site.sh" "$ROOT"/lib/*.sh "$ROOT"/tests/*.sh; do
    bash -n "$script"
done
if command -v shellcheck >/dev/null; then
    shellcheck --external-sources --source-path="$ROOT" "$ROOT/reality-site.sh" "$ROOT"/lib/*.sh
else
    printf 'SKIP ShellCheck: not installed.\n'
fi
bash "$ROOT/tests/test-system.sh"
bash "$ROOT/tests/test-cloudflare.sh"
bash "$ROOT/tests/test-cert.sh"
bash "$ROOT/tests/test-web.sh"
bash "$ROOT/tests/test-mode.sh"
bash "$ROOT/tests/test-domain-cert.sh"
bash "$ROOT/tests/test-domain.sh"
bash "$ROOT/tests/test-domain-web.sh"
