#!/usr/bin/env bash
# Local check, outside PR CI: setup.sh gives the api and worker PostgreSQL repositories
# in both envs, and LLM stub fixtures only to the dev worker (worker#68). Needs only bash.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=onprem/dellpromaxgb10/platform/lib.sh
. "$here/lib.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
for app in api worker; do
  for env in dev prd; do
    lines=$(m_app_env "$app" "$env")
    grep -qx 'MERITUM_DATABASE_PROVIDER=postgres' <<<"$lines" || fail "$app-$env: no postgres provider"
    if [ "$app-$env" = worker-dev ]; then
      grep -qx "MERITUM_LLM_STUB_FIXTURES=$M_LLM_STUB_FIXTURES" <<<"$lines" || fail "worker-dev: no stub fixtures"
    elif grep -q '^MERITUM_LLM_STUB_FIXTURES=' <<<"$lines"; then
      fail "$app-$env: stub fixtures belong only to worker-dev"
    fi
  done
done
# Both env files of an env take their lines from m_app_env.
[ "$(grep -cF 'm_app_env ' "$here/setup.sh")" = 2 ] || fail "setup.sh: api and worker env files must both call m_app_env"
echo "app env: ok"
