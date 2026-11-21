#!/usr/bin/env bash
# Local check, outside PR CI: setup.sh gives the api and worker of one env the same
# files volume and the two envs different ones. Needs only bash.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=onprem/dellpromaxgb10/platform/lib.sh
. "$here/lib.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
dev=$(m_files_env dev); prd=$(m_files_env prd)
grep -qx 'MERITUM_FILES_VOLUME=meritum-files-dev' <<<"$dev" || fail "dev volume: $dev"
grep -qx "MERITUM_FILES_DIR=$M_FILES_DIR" <<<"$dev" || fail "dev dir: $dev"
[ "$dev" != "$prd" ] || fail "dev and prd share a volume"
# Both env files of an env take their lines from m_files_env.
[ "$(grep -cF "m_files_env \"\$env\"" "$here/setup.sh")" = 2 ] || fail "setup.sh: api and worker env files must both call m_files_env"
echo "files volume: ok"
