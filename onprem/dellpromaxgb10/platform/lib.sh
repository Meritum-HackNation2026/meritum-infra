#!/usr/bin/env bash
# Names shared by the platform and the app deploys (meritum-backend, -worker,
# -frontend copy the few they need). Source it, don't run it.
#
#   branch   env  hostname                 web container    api container    worker container
#   main     prd  meritum.gburek.app       meritum-web-prd  meritum-api-prd  meritum-worker-prd
#   develop  dev  meritum-dev.gburek.app   meritum-web-dev  meritum-api-dev  meritum-worker-dev
#
# Platform mocks (meritum-mocks, main only): meritum-<platform>.gburek.app,
# served by meritum-mocks-prd.
#
# Everything created here carries the Docker label meritum.managed=true.
# shellcheck disable=SC2034  # used by the scripts that source this file
M_DOMAIN="${M_DOMAIN:-gburek.app}"
M_STATE="${M_STATE:-$HOME/meritum}"
M_NETWORK="meritum"
M_POSTGRES="meritum-postgres"
M_GATEWAY="meritum-gateway"
# docker0 address: cloudflared (default bridge) reaches it, the LAN does not.
# 18080/18081 are TuttiTrip's, 18090 is ExactDocs'.
M_GATEWAY_BIND="${M_GATEWAY_BIND:-172.17.0.1:18095}"

M_MOCK_PLATFORMS=(x facebook instagram reddit tiktok discord)

m_log() { printf '[meritum] %s\n' "$*" >&2; }
m_role() { printf 'meritum_%s_%s' "$1" "$2"; }
m_schema() { printf '%s_%s' "$1" "$2"; }
# Uploaded files of one env (GCS bucket on GCP, ADR-31): Docker volume mounted by
# the backend and the worker at M_FILES_DIR; adapter core/021 reads MERITUM_FILES_DIR.
M_FILES_DIR="/var/lib/meritum/files"
m_files_volume() { printf 'meritum-files-%s' "$1"; }
# The backend and worker images run as nonroot, uid 999; a new volume belongs to root.
M_APP_UID=999
# Give volume $1 to the app user, with any local image $2 that has chown.
m_files_own() { docker run --rm --user 0 --entrypoint chown -v "$1:/files" "$2" "$M_APP_UID:$M_APP_UID" /files; }
# Env file lines of the files volume, the same for the api and worker of env $1. The
# backend reads MERITUM_FILES_DIR, the worker MERITUM_BLOB_* (core BlobSettings).
m_files_env() {
  printf 'MERITUM_FILES_VOLUME=%s\nMERITUM_FILES_DIR=%s\n' "$(m_files_volume "$1")" "$M_FILES_DIR"
  printf 'MERITUM_BLOB_PROVIDER=filesystem\nMERITUM_BLOB_DIRECTORY=%s\n' "$M_FILES_DIR"
}
# LLM stub fixtures inside the worker image, kept on dev for a switch back to the stub, which without them fails every check (worker#68).
M_LLM_STUB_FIXTURES="/app/features/fixtures/llm_stub_answer.json"
# LLM of the worker (core#97, D9): Claude Haiku 5.5 via OpenRouter on dev. OPENROUTER_API_KEY
# comes from the meritum-worker deploy (repository secret), never from these files. Prd keeps the
# stub until its deploy passes the key, because core's default provider is now openrouter.
M_LLM_MODEL="anthropic/claude-haiku-5.5"
M_LLM_REASONING="high"
# Env file lines of app $1 (api, worker) in env $2: meritum-core repositories in PostgreSQL,
# the worker's LLM, the dev worker's stub fixtures, and the prd worker's writable corpus URL in $3.
m_app_env() {
  printf 'MERITUM_DATABASE_PROVIDER=postgres\n'
  if [ "$1-$2" = worker-dev ]; then
    printf 'MERITUM_LLM_STUB_FIXTURES=%s\n' "$M_LLM_STUB_FIXTURES"
    printf 'MERITUM_LLM_PROVIDER=openrouter\nMERITUM_LLM_MODEL=%s\nMERITUM_LLM_REASONING=%s\n' "$M_LLM_MODEL" "$M_LLM_REASONING"
  fi
  if [ "$1-$2" = worker-prd ]; then
    printf 'MERITUM_LLM_PROVIDER=stub\n'
    printf 'MERITUM_CORPUS_PROVIDER=postgres\nMERITUM_CORPUS_DATABASE_URL=%s\n' "$3"
  fi
}
# Sensitive Data Protection (core#90): only with GCP credentials from setup.sh (wif.sh).
M_PII_LOCATION="${M_PII_LOCATION:-europe-central2}"
m_pii_env() {
  printf 'MERITUM_PII_GATE=sdp\nMERITUM_PII_PROJECT=%s\nMERITUM_PII_LOCATION=%s\n' "$1" "$M_PII_LOCATION"
}
# Live web search (infra#42): Vertex AI Search app of gcp/search (infra#16), dev worker only.
# $1 app, $2 env, $3 project number; the worker reads the credentials from ADC (wif.sh).
M_WEB_SEARCH_ENGINE="meritum-live-search"
m_web_search_env() {
  [ "$1-$2" = worker-dev ] || return 0
  printf 'MERITUM_WEB_SEARCH_PROVIDER=vertex_search\nMERITUM_WEB_SEARCH_PROJECT=%s\nMERITUM_WEB_SEARCH_ENGINE=%s\n' "$3" "$M_WEB_SEARCH_ENGINE"
}
# Worker transcription (ADR-30): Chirp 3 via ADC, only with GCP credentials from setup.sh.
m_transcription_env() {
  printf 'MERITUM_TRANSCRIPTION_PROVIDER=speech_v2\nMERITUM_TRANSCRIPTION_PROJECT=%s\n' "$1"
}
m_host() { if [ "$1" = prd ]; then printf 'meritum.%s' "$M_DOMAIN"; else printf 'meritum-%s.%s' "$1" "$M_DOMAIN"; fi; }
m_mock_host() { if [ "$2" = prd ]; then printf 'meritum-%s.%s' "$1" "$M_DOMAIN"; else printf 'meritum-%s-%s.%s' "$1" "$2" "$M_DOMAIN"; fi; }
