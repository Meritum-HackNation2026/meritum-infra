#!/usr/bin/env bash
# Local check, outside PR CI: setup.sh gives both envs PostgreSQL app repositories,
# LLM stub fixtures only to the dev worker, and corpus writes only to the prd worker.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=onprem/dellpromaxgb10/platform/lib.sh
. "$here/lib.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
corpus_url='postgresql://meritum_worker_prd:test@meritum-postgres:5432/meritum?options=-csearch_path%3Dcorpus,public'
for app in api worker; do
  for env in dev prd; do
    lines=$(m_app_env "$app" "$env" "$corpus_url")
    grep -qx 'MERITUM_DATABASE_PROVIDER=postgres' <<<"$lines" || fail "$app-$env: no postgres provider"
    if [ "$app-$env" = worker-dev ]; then
      grep -qx "MERITUM_LLM_STUB_FIXTURES=$M_LLM_STUB_FIXTURES" <<<"$lines" || fail "worker-dev: no stub fixtures"
    elif grep -q '^MERITUM_LLM_STUB_FIXTURES=' <<<"$lines"; then
      fail "$app-$env: stub fixtures belong only to worker-dev"
    fi
    if [ "$app-$env" = worker-prd ]; then
      grep -qx 'MERITUM_CORPUS_PROVIDER=postgres' <<<"$lines" || fail "worker-prd: no corpus provider"
      grep -qx "MERITUM_CORPUS_DATABASE_URL=$corpus_url" <<<"$lines" || fail "worker-prd: no corpus database URL"
    elif grep -q '^MERITUM_CORPUS_' <<<"$lines"; then
      fail "$app-$env: corpus writes belong only to worker-prd"
    fi
  done
done
# Both env files of an env take their lines from m_app_env.
[ "$(grep -cF 'm_app_env ' "$here/setup.sh")" = 2 ] || fail "setup.sh: api and worker env files must both call m_app_env"
grep -qF "corpus_url() { m_db_url \"\$(m_role worker prd)\" \"\$(pw worker prd)\" meritum corpus; }" "$here/setup.sh" \
  || fail "setup.sh: corpus URL must use the prd worker role and corpus search path"
grep -qF "m_app_env worker \"\$env\" \"\$(corpus_url)\"" "$here/setup.sh" \
  || fail "setup.sh: worker env files must receive the corpus URL"
grep -qF 'gcp_pii' "$here/setup.sh" \
  || fail "setup.sh: api and worker env files must call gcp_pii when GCP credentials exist"
grep -qF 'm_pii_env()' "$here/lib.sh" || fail "lib.sh: missing m_pii_env"
pii=$(m_pii_env meritum-example)
grep -qx 'MERITUM_PII_GATE=sdp' <<<"$pii" || fail "m_pii_env: no MERITUM_PII_GATE=sdp"
grep -qx 'MERITUM_PII_PROJECT=meritum-example' <<<"$pii" || fail "m_pii_env: project from argument"
grep -qx 'MERITUM_PII_LOCATION=europe-central2' <<<"$pii" || fail "m_pii_env: location europe-central2"
echo "app env: ok"
