#!/usr/bin/env bash
# Shared Meritum platform on dellpromaxgb10. Idempotent; runs on the host as
# meritum-runner (workflow .github/workflows/platform.yml, or by hand).
#
#   network   meritum (private Docker network of every Meritum container)
#   postgres  meritum-postgres (image postgres/Dockerfile: pgvector + Polish FTS `public.polish`),
#             database `meritum` with schemas app_dev and app_prd (owned by
#             meritum_worker_<env>, read/write for meritum_api_<env>), mocks_prd
#             (meritum_mocks_prd; mocks deploy from main only, so no dev env),
#             corpus shared by both envs (written by meritum_worker_prd only),
#             and one DBOS database per env, meritum_dbos_<env> (db.sh)
#   files     volume meritum-files-<env>, shared by the api and worker of that env
#   gcp       workload identity certificates and external_account credential files of
#             the api and worker, ~/meritum/gcp (wif.sh, gcp/workload-identity/)
#   env files ~/meritum/envs/<app>-<env>.env (mode 600), read by the app deploys
#   gateway   meritum-gateway (nginx) on 172.17.0.1:18095, reachable by cloudflared only
#   routes    meritum.gburek.app -> meritum-web-prd, meritum-dev.gburek.app -> meritum-web-dev,
#             meritum-<platform>.gburek.app -> meritum-mocks-prd (nginx.conf)
#             (Cloudflare tunnel ingress + DNS; skipped with a warning without a token)
#
# Env: CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID, CLOUDFLARE_TUNNEL_ID, CLOUDFLARE_ZONE_ID,
# MERITUM_GCP_PROJECT_ID, MERITUM_GCP_PROJECT_NUMBER.
# Host files (never committed): ~/meritum/db.env (generated passwords) and the
# optional ~/meritum/app.env (shared app secrets, appended to every env file).
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=onprem/dellpromaxgb10/platform/lib.sh
. "$here/lib.sh"
# shellcheck source=onprem/dellpromaxgb10/platform/db.sh
. "$here/db.sh"
# shellcheck source=onprem/dellpromaxgb10/platform/wif.sh
. "$here/wif.sh"

APPS=(api worker mocks)
ENVS=(dev prd)
# Mocks deploy from main only: no mocks dev role, schema, env file or hostnames.
has_env() { [ "$1" != mocks ] || [ "$2" = prd ]; }

mkdir -p "$M_STATE/envs" "$M_STATE/gateway"
chmod 700 "$M_STATE"
exec 9>"$M_STATE/deploy.lock"
flock 9

umask 077
vars=(POSTGRES_PASSWORD)
for app in "${APPS[@]}"; do for env in "${ENVS[@]}"; do has_env "$app" "$env" && vars+=("$(pw_var "$app" "$env")"); done; done
m_db_passwords "$M_STATE/db.env" "${vars[@]}"

# --- network and database --------------------------------------------------------
docker network inspect "$M_NETWORK" >/dev/null 2>&1 \
  || docker network create --label meritum.managed=true "$M_NETWORK" >/dev/null

# Image tagged by the hash of its inputs; a change rebuilds it and replaces the
# container on the same data volume, after a full dump to $M_STATE/backups.
pg_hash=$(cat "$here"/postgres/{Dockerfile,polish.stop,extensions.sql,polish-fts.sql} | sha256sum | cut -c1-12)
M_POSTGRES_IMAGE="meritum-postgres:$pg_hash"
docker image inspect "$M_POSTGRES_IMAGE" >/dev/null 2>&1 \
  || docker build -q -t "$M_POSTGRES_IMAGE" --label meritum.managed=true "$here/postgres" >/dev/null
current=$(docker inspect -f '{{.Config.Image}}' "$M_POSTGRES" 2>/dev/null || true)
if [ -n "$current" ] && [ "$current" != "$M_POSTGRES_IMAGE" ]; then
  mkdir -p "$M_STATE/backups"
  dump="$M_STATE/backups/pg_dumpall-$(date -u +%Y%m%dT%H%M%SZ).sql.gz"
  docker exec "$M_POSTGRES" pg_dumpall -U meritum | gzip >"$dump"
  m_log "dumped the database to $dump; replacing $M_POSTGRES ($current -> $M_POSTGRES_IMAGE)"
  docker stop -t 30 "$M_POSTGRES" >/dev/null
  docker rm "$M_POSTGRES" >/dev/null
fi
if ! docker container inspect "$M_POSTGRES" >/dev/null 2>&1; then
  m_log "starting $M_POSTGRES"
  docker run -d --name "$M_POSTGRES" --network "$M_NETWORK" --restart unless-stopped \
    --label meritum.managed=true --label meritum.role=postgres \
    -e POSTGRES_USER=meritum -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" -e POSTGRES_DB=meritum \
    -v meritum-postgres-data:/var/lib/postgresql \
    --health-cmd "pg_isready -h 127.0.0.1 -U meritum -d meritum" --health-interval 5s \
    "$M_POSTGRES_IMAGE" >/dev/null
fi
docker start "$M_POSTGRES" >/dev/null
for i in $(seq 60); do
  docker exec "$M_POSTGRES" pg_isready -h 127.0.0.1 -U meritum -d meritum >/dev/null 2>&1 && break
  [ "$i" = 60 ] && { m_log "$M_POSTGRES not ready"; exit 1; }
  sleep 1
done

# Roles, schemas and DBOS databases (db.sh); public stays read-only (pgvector, pg_trgm, polish).
mocks_envs=(); for env in "${ENVS[@]}"; do if has_env mocks "$env"; then mocks_envs+=("$env"); fi; done
{
  cat "$here/postgres/extensions.sql"
  cat "$here/postgres/polish-fts.sql"
  m_db_sql "${ENVS[*]}" "${mocks_envs[*]}"
} | docker exec -i -e PGOPTIONS="-c client_min_messages=warning" "$M_POSTGRES" psql -q -v ON_ERROR_STOP=1 -U meritum -d meritum >/dev/null
m_log "roles, app schemas, corpus, DBOS databases and Polish FTS ready: ${ENVS[*]} (mocks: prd only)"

# --- uploaded files: one volume per env, shared by api and worker --------------------
for env in "${ENVS[@]}"; do
  docker volume inspect "$(m_files_volume "$env")" >/dev/null 2>&1 \
    || docker volume create --label meritum.managed=true "$(m_files_volume "$env")" >/dev/null
  m_files_own "$(m_files_volume "$env")" "$M_POSTGRES_IMAGE"
done

# --- GCP: workload identity of the api and worker (gcp/workload-identity/) ------------
gcp_env() { :; }
gcp_pii() { :; }
gcp_web_search() { :; }
gcp_transcription() { :; }
gcp_ocr() { :; }
if [ -z "${MERITUM_GCP_PROJECT_ID:-}" ] || [ -z "${MERITUM_GCP_PROJECT_NUMBER:-}" ]; then
  m_log "WARNING: MERITUM_GCP_PROJECT_ID or MERITUM_GCP_PROJECT_NUMBER unset, no GCP credentials"
  echo "::warning title=GCP::GCP_PROJECT_ID or GCP_PROJECT_NUMBER is not set; api and worker get no GCP credentials"
else
  m_wif_issue "$M_STATE/gcp" "$MERITUM_GCP_PROJECT_ID" "$MERITUM_GCP_PROJECT_NUMBER"
  gcp_env() { m_wif_env "$M_STATE/gcp" "$1" "$MERITUM_GCP_PROJECT_ID"; }
  gcp_pii() { m_pii_env "$MERITUM_GCP_PROJECT_ID"; }
  gcp_web_search() { m_web_search_env "$1" "$2" "$MERITUM_GCP_PROJECT_NUMBER"; }
  gcp_transcription() { m_transcription_env "$MERITUM_GCP_PROJECT_ID"; }
  gcp_ocr() { m_ocr_env "$MERITUM_GCP_PROJECT_ID"; }
  m_log "GCP credentials ready; trust anchor $M_STATE/gcp/ca/ca.pem, $(openssl x509 -noout -fingerprint -sha256 -in "$M_STATE/gcp/ca/ca.pem")"
fi

# --- env files for the app deploys -------------------------------------------------
gateway_subnet=$(docker network inspect "$M_NETWORK" -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' | awk '{print $1}')
pw() { local var; var=$(pw_var "$1" "$2"); printf '%s' "${!var}"; }
# MERITUM_DATABASE_URL: database meritum, search_path app_<env>, public.
app_url() { m_db_url "$(m_role "$1" "$2")" "$(pw "$1" "$2")" meritum "$(m_app_schema "$2")"; }
# MERITUM_CORPUS_DATABASE_URL: only the prd worker writes to schema corpus.
corpus_url() { m_db_url "$(m_role worker prd)" "$(pw worker prd)" meritum corpus; }
# MERITUM_DBOS_URL: the env's DBOS database; tables in schema dbos (DBOS default).
dbos_url() { m_db_url "$(m_role "$1" "$2")" "$(pw "$1" "$2")" "$(m_dbos_db "$2")"; }
extra() { if [ -f "$M_STATE/app.env" ]; then grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$M_STATE/app.env" || true; fi; }
for env in "${ENVS[@]}"; do
  {
    printf 'MERITUM_ENV=%s\n' "$env"
    printf 'MERITUM_DATABASE_URL=%s\n' "$(app_url api "$env")"
    m_app_env api "$env"
    # The API enqueues into the worker's DBOS tables with its own role
    # (access granted by `dbos migrate -r` in the worker deploy).
    printf 'MERITUM_DBOS_URL=%s\n' "$(dbos_url api "$env")"
    printf 'MERITUM_DBOS_SCHEMA=dbos\n'
    printf 'FORWARDED_ALLOW_IPS=%s\n' "$gateway_subnet"
    m_files_env "$env"
    gcp_env api
    gcp_pii
    extra
  } >"$M_STATE/envs/api-$env.env"
  {
    printf 'MERITUM_ENV=%s\n' "$env"
    printf 'MERITUM_DATABASE_URL=%s\n' "$(app_url worker "$env")"
    m_app_env worker "$env" "$(corpus_url)"
    printf 'MERITUM_DBOS_URL=%s\n' "$(dbos_url worker "$env")"
    printf 'MERITUM_DBOS_SCHEMA=dbos\n'
    printf 'MERITUM_API_ROLE=%s\n' "$(m_role api "$env")"
    m_files_env "$env"
    gcp_env worker
    gcp_pii
    gcp_web_search worker "$env"
    gcp_transcription
    gcp_ocr
    admin_var=MERITUM_ADMIN_EMAILS_${env^^}
    m_admin_env "${!admin_var:-}"
    fc_var=MERITUM_FACT_CHECK_API_KEY_${env^^}
    m_fact_check_env "${!fc_var:-}"
    extra
  } >"$M_STATE/envs/worker-$env.env"
  has_env mocks "$env" && {
    printf 'MERITUM_ENV=%s\n' "$env"
    printf 'DATABASE_URL=%s\n' "$(m_db_url "$(m_role mocks "$env")" "$(pw mocks "$env")" meritum)"
  } >"$M_STATE/envs/mocks-$env.env"
done
for env in "${ENVS[@]}"; do
  admin_var=MERITUM_ADMIN_EMAILS_${env^^}
  [ -n "${!admin_var:-}" ] || echo "::warning title=Admin e-mails::$admin_var is not set; worker-$env gets no MERITUM_ADMIN_EMAILS"
  fc_var=MERITUM_FACT_CHECK_API_KEY_${env^^}
  [ -n "${!fc_var:-}" ] || echo "::warning title=Fact Check::$fc_var is not set; worker-$env gets no MERITUM_FACT_CHECK_*"
done
m_log "env files written to $M_STATE/envs"

# --- gateway ---------------------------------------------------------------------
cp "$here/nginx.conf" "$M_STATE/gateway/nginx.conf"
chmod 644 "$M_STATE/gateway/nginx.conf"
hash=$(sha256sum "$M_STATE/gateway/nginx.conf" | cut -c1-16)
if [ "$(docker inspect -f '{{index .Config.Labels "meritum.config-hash"}}' "$M_GATEWAY" 2>/dev/null || true)" != "$hash" ]; then
  m_log "(re)creating $M_GATEWAY on $M_GATEWAY_BIND"
  docker rm -f "$M_GATEWAY" >/dev/null 2>&1 || true
  docker run -d --name "$M_GATEWAY" --network "$M_NETWORK" --restart unless-stopped \
    --label meritum.managed=true --label meritum.role=gateway --label meritum.config-hash="$hash" \
    -p "$M_GATEWAY_BIND:80" -v "$M_STATE/gateway/nginx.conf:/etc/nginx/nginx.conf:ro" \
    nginx:1.29-alpine >/dev/null
fi

# --- public routes ---------------------------------------------------------------
if [ -z "${CLOUDFLARE_API_TOKEN:-}" ]; then
  m_log "WARNING: CLOUDFLARE_API_TOKEN unset, tunnel routes not managed"
  echo "::warning title=Cloudflare::CLOUDFLARE_API_TOKEN is not set; meritum hostnames are not routed"
else
  # shellcheck source=onprem/dellpromaxgb10/platform/cloudflare.sh
  . "$here/cloudflare.sh"
  for env in "${ENVS[@]}"; do
    hosts=("$(m_host "$env")")
    if has_env mocks "$env"; then for p in "${M_MOCK_PLATFORMS[@]}"; do hosts+=("$(m_mock_host "$p" "$env")"); done; fi
    for host in "${hosts[@]}"; do
      cf_ingress_ensure "$host" "http://$M_GATEWAY_BIND"
      cf_dns_ensure "$host"
    done
  done
fi
m_log "platform ready"
