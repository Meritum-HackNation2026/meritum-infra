#!/usr/bin/env bash
# Local check, outside PR CI: setup.sh gives both envs PostgreSQL app repositories,
# the real model (OpenRouter) to both workers, LLM stub fixtures only to the dev worker,
# and corpus writes only to the prd worker.
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
    # D9 (core#97): Claude Haiku 5.5 via OpenRouter in both environments.
    if [ "$app" = worker ]; then
      for line in MERITUM_LLM_PROVIDER=openrouter MERITUM_LLM_MODEL=anthropic/claude-haiku-5.5 MERITUM_LLM_REASONING=high; do
        grep -Fqx "$line" <<<"$lines" || fail "$app-$env: no $line"
      done
    elif grep -q '^MERITUM_LLM_PROVIDER=' <<<"$lines"; then
      fail "$app-$env: the api builds no LlmPort"
    fi
    # infra#57: prd writes the corpus (ingest), dev reads it with its own role.
    if [ "$app-$env" = worker-prd ]; then
      grep -qx 'MERITUM_CORPUS_PROVIDER=postgres' <<<"$lines" || fail "worker-prd: no corpus provider"
      grep -qx "MERITUM_CORPUS_DATABASE_URL=$corpus_url" <<<"$lines" || fail "worker-prd: no corpus database URL"
      grep -qx 'MERITUM_CORPUS_INGEST=enabled' <<<"$lines" || fail "worker-prd: no corpus ingest"
    elif [ "$app-$env" = worker-dev ]; then
      grep -qx 'MERITUM_CORPUS_PROVIDER=postgres' <<<"$lines" || fail "worker-dev: no corpus provider"
      grep -qx "MERITUM_CORPUS_DATABASE_URL=$corpus_url" <<<"$lines" || fail "worker-dev: no corpus database URL"
      ! grep -q '^MERITUM_CORPUS_INGEST=' <<<"$lines" || fail "worker-dev: only worker-prd may ingest"
    elif grep -q '^MERITUM_CORPUS_' <<<"$lines"; then
      fail "$app-$env: the api reads no corpus"
    fi
  done
done
# Both env files of an env take their lines from m_app_env.
[ "$(grep -cF 'm_app_env ' "$here/setup.sh")" = 2 ] || fail "setup.sh: api and worker env files must both call m_app_env"
grep -qF "corpus_url() { m_db_url \"\$(m_role worker \"\$1\")\" \"\$(pw worker \"\$1\")\" meritum corpus; }" "$here/setup.sh" \
  || fail "setup.sh: corpus URL must use the env's worker role and corpus search path"
grep -qF "m_app_env worker \"\$env\" \"\$(corpus_url \"\$env\")\"" "$here/setup.sh" \
  || fail "setup.sh: worker env files must receive the corpus URL of their env"
grep -qF 'gcp_pii' "$here/setup.sh" \
  || fail "setup.sh: api and worker env files must call gcp_pii when GCP credentials exist"
grep -qF 'm_pii_env()' "$here/lib.sh" || fail "lib.sh: missing m_pii_env"
pii=$(m_pii_env meritum-example)
grep -qx 'MERITUM_PII_GATE=sdp' <<<"$pii" || fail "m_pii_env: no MERITUM_PII_GATE=sdp"
grep -qx 'MERITUM_PII_PROJECT=meritum-example' <<<"$pii" || fail "m_pii_env: project from argument"
grep -qx 'MERITUM_PII_LOCATION=europe-central2' <<<"$pii" || fail "m_pii_env: location europe-central2"
# Live web search (infra#42): Vertex AI Search app of infra#16, only for the dev worker.
grep -qF 'm_web_search_env()' "$here/lib.sh" || fail "lib.sh: missing m_web_search_env"
ws=$(m_web_search_env worker dev 196419832223)
for line in MERITUM_WEB_SEARCH_PROVIDER=vertex_search MERITUM_WEB_SEARCH_PROJECT=196419832223 MERITUM_WEB_SEARCH_ENGINE=meritum-live-search; do
  grep -qx "$line" <<<"$ws" || fail "m_web_search_env: worker-dev has no $line"
done
for other in "api dev" "api prd" "worker prd"; do
  # shellcheck disable=SC2086
  [ -z "$(m_web_search_env $other 196419832223)" ] || fail "m_web_search_env: $other must get no web search"
done
grep -qF "gcp_web_search worker \"\$env\"" "$here/setup.sh" || fail "setup.sh: worker env files must call gcp_web_search"
grep -qF 'm_transcription_env()' "$here/lib.sh" || fail "lib.sh: missing m_transcription_env"
stt=$(m_transcription_env meritum-example)
grep -qx 'MERITUM_TRANSCRIPTION_PROVIDER=speech_v2' <<<"$stt" || fail "m_transcription_env: no speech_v2 provider"
grep -qx 'MERITUM_TRANSCRIPTION_PROJECT=meritum-example' <<<"$stt" || fail "m_transcription_env: project from argument"
# Env-file blocks of setup.sh: the call sits in the worker block only, and without
# GCP credentials gcp_transcription stays a no-op (worker on the stub).
block() { awk -v f="$1" '/^  \{$/ {b=""; next} /^  \} >/ {if (index($0, f)) print b; next} {b=b $0 "\n"}' "$here/setup.sh"; }
grep -qE '^[[:space:]]*gcp_transcription$' <<<"$(block "worker-\$env.env")" \
  || fail "setup.sh: worker env files must call gcp_transcription"
! grep -qE 'gcp_transcription' <<<"$(block "api-\$env.env")" || fail "setup.sh: api env files must not get transcription"
grep -qF 'gcp_transcription() { :; }' "$here/setup.sh" || fail "setup.sh: gcp_transcription must be a no-op without GCP credentials"
# Worker OCR (infra#55): Cloud Vision via ADC, worker block only, no-op without GCP credentials.
ocr=$(m_ocr_env meritum-example)
grep -qx 'MERITUM_OCR_PROVIDER=vision' <<<"$ocr" || fail "m_ocr_env: no vision provider"
grep -qx 'MERITUM_OCR_PROJECT=meritum-example' <<<"$ocr" || fail "m_ocr_env: project from argument"
grep -qE '^[[:space:]]*gcp_ocr$' <<<"$(block "worker-\$env.env")" || fail "setup.sh: worker env files must call gcp_ocr"
! grep -qE 'gcp_ocr' <<<"$(block "api-\$env.env")" || fail "setup.sh: api env files must not get OCR"
grep -qF 'gcp_ocr() { :; }' "$here/setup.sh" || fail "setup.sh: gcp_ocr must be a no-op without GCP credentials"
# Admin e-mails (infra#51): the worker needs the same list as the backend for case_assigned mail.
grep -qF 'm_admin_env()' "$here/lib.sh" || fail "lib.sh: missing m_admin_env"
[ "$(m_admin_env 'a@x.pl,b@x.pl')" = 'MERITUM_ADMIN_EMAILS=a@x.pl,b@x.pl' ] || fail "m_admin_env: value passed through"
[ -z "$(m_admin_env '')" ] || fail "m_admin_env: empty value must write no line"
grep -qE '^[[:space:]]*m_admin_env "\$\{!admin_var:-\}"$' <<<"$(block "worker-\$env.env")" || fail "setup.sh: worker env files must call m_admin_env"
! grep -qF 'm_admin_env' <<<"$(block "api-\$env.env")" || fail "setup.sh: api env files must not get admin e-mails"
# shellcheck disable=SC2016
grep -qF 'MERITUM_ADMIN_EMAILS_DEV: ${{ secrets.MERITUM_ADMIN_EMAILS_DEV }}' "$here/../../../.github/workflows/platform.yml" || fail "platform.yml: no MERITUM_ADMIN_EMAILS_DEV secret"
# shellcheck disable=SC2016
grep -qF 'MERITUM_ADMIN_EMAILS_PRD: ${{ secrets.MERITUM_ADMIN_EMAILS_PRD }}' "$here/../../../.github/workflows/platform.yml" || fail "platform.yml: no MERITUM_ADMIN_EMAILS_PRD secret"
# Fact Check (infra#53): the worker needs the Google Fact Check Tools key from the repository secret.
grep -qF 'm_fact_check_env()' "$here/lib.sh" || fail "lib.sh: missing m_fact_check_env"
fc=$(m_fact_check_env 'k123')
grep -qx 'MERITUM_FACT_CHECK_PROVIDER=google' <<<"$fc" || fail "m_fact_check_env: no provider line"
grep -qx 'MERITUM_FACT_CHECK_API_KEY=k123' <<<"$fc" || fail "m_fact_check_env: key passed through"
[ -z "$(m_fact_check_env '')" ] || fail "m_fact_check_env: empty value must write no lines"
grep -qE '^[[:space:]]*m_fact_check_env "\$\{!fc_var:-\}"$' <<<"$(block "worker-\$env.env")" || fail "setup.sh: worker env files must call m_fact_check_env"
! grep -qF 'm_fact_check_env' <<<"$(block "api-\$env.env")" || fail "setup.sh: api env files must not get the fact check key"
# shellcheck disable=SC2016
grep -qF 'MERITUM_FACT_CHECK_API_KEY_DEV: ${{ secrets.MERITUM_FACT_CHECK_API_KEY_DEV }}' "$here/../../../.github/workflows/platform.yml" || fail "platform.yml: no MERITUM_FACT_CHECK_API_KEY_DEV secret"
# shellcheck disable=SC2016
grep -qF 'MERITUM_FACT_CHECK_API_KEY_PRD: ${{ secrets.MERITUM_FACT_CHECK_API_KEY_PRD }}' "$here/../../../.github/workflows/platform.yml" || fail "platform.yml: no MERITUM_FACT_CHECK_API_KEY_PRD secret"
# EU sanctions list (infra#66): official FSF export and the copy on the files volume, workers only.
sanctions=$(m_sanctions_env)
grep -qx 'MERITUM_SANCTIONS_LIST_URL=https://webgate.ec.europa.eu/fsd/fsf/public/files/xmlFullSanctionsList_1_1/content?token=dG9rZW4tMjAxNw' <<<"$sanctions" || fail "m_sanctions_env: no FSF export URL" # gitleaks:allow public catalogue token
grep -qx "MERITUM_SANCTIONS_LIST_PATH=$M_FILES_DIR/eu-sanctions.json" <<<"$sanctions" || fail "m_sanctions_env: copy not on the files volume"
grep -qE '^[[:space:]]*m_sanctions_env$' <<<"$(block "worker-\$env.env")" || fail "setup.sh: worker env files must call m_sanctions_env"
! grep -qF 'm_sanctions_env' <<<"$(block "api-\$env.env")" || fail "setup.sh: api env files must not get the sanctions list"
echo "app env: ok"
# Corpus embeddings (infra#57, D2): Vertex in the EU via ADC, both workers (ingest and search
# must use one model), no-op without GCP credentials.
emb=$(m_embeddings_env meritum-example)
for line in MERITUM_EMBEDDINGS_PROVIDER=vertex MERITUM_EMBEDDINGS_MODEL=gemini-embedding-001 \
  MERITUM_EMBEDDINGS_REGION=europe-central2 MERITUM_EMBEDDINGS_PROJECT=meritum-example; do
  grep -qx "$line" <<<"$emb" || fail "m_embeddings_env: no $line"
done
grep -qE '^[[:space:]]*gcp_embeddings$' <<<"$(block "worker-\$env.env")" || fail "setup.sh: worker env files must call gcp_embeddings"
! grep -qE 'gcp_embeddings' <<<"$(block "api-\$env.env")" || fail "setup.sh: api env files must not get embeddings"
grep -qF 'gcp_embeddings() { :; }' "$here/setup.sh" || fail "setup.sh: gcp_embeddings must be a no-op without GCP credentials"
# Pinned snapshot (worker: no auto-latest yet): the MERITUM_CORPUS_VERSION_<ENV> repository variable.
[ "$(m_corpus_version_env 2026-11-22T10:00Z)" = 'MERITUM_CORPUS_VERSION=2026-11-22T10:00Z' ] || fail "m_corpus_version_env: no version line"
[ -z "$(m_corpus_version_env '')" ] || fail "m_corpus_version_env: empty must write nothing"
# shellcheck disable=SC2016 # literal text of setup.sh
grep -qF 'm_corpus_version_env "${!cv_var:-}"' "$here/setup.sh" || fail "setup.sh: worker env files must call m_corpus_version_env"
