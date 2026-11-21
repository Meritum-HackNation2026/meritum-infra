#!/usr/bin/env bash
# Local check, outside PR CI: nginx.conf routes every M_MOCK_PLATFORMS host
# (the list setup.sh hands to the Cloudflare tunnel) to meritum-mocks-prd.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=onprem/dellpromaxgb10/platform/lib.sh
. "$here/lib.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
re=$(sed -n 's/^ *~\(\^meritum-.*\$\) *meritum-mocks-prd:3000;$/\1/p' "$here/nginx.conf")
[ -n "$re" ] || fail "nginx.conf: no mocks host regex"
[[ " ${M_MOCK_PLATFORMS[*]} " == *" discord "* ]] || fail "M_MOCK_PLATFORMS lacks discord"
for p in "${M_MOCK_PLATFORMS[@]}"; do
  host=$(m_mock_host "$p" prd)
  grep -Eq "$re" <<<"$host" || fail "nginx.conf does not route $host"
done
echo "mock hosts: ok"
