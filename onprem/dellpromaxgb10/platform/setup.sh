#!/usr/bin/env bash
# Shared Meritum platform on dellpromaxgb10. Idempotent; runs on the host as
# meritum-runner (workflow .github/workflows/platform.yml, or by hand).
#
#   network   meritum (private Docker network of every Meritum container)
#   postgres  meritum-postgres (image postgres/Dockerfile: pgvector + Polish FTS `public.polish`),
#             database `meritum` with schemas app_dev and app_prd (owned by
#             meritum_worker_<env>, read/write for meritum_api_<env>), mocks_prd
#             (meritum_mocks_prd; mocks deploy from main only, so no dev env),
#             and one DBOS database per env, meritum_dbos_<env> (db.sh)
#   files     volume meritum-files-<env>, shared by the api and worker of that env
#   env files ~/meritum/envs/<app>-<env>.env (mode 600), read by the app deploys
#   gateway   meritum-gateway (nginx) on 172.17.0.1:18095, reachable by cloudflared only
#   routes    meritum.gburek.app -> meritum-web-prd, meritum-dev.gburek.app -> meritum-web-dev,
#             meritum-<platform>.gburek.app -> meritum-mocks-prd (nginx.conf)
#             (Cloudflare tunnel ingress + DNS; skipped with a warning without a token)
#
# Env: CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID, CLOUDFLARE_TUNNEL_ID, CLOUDFLARE_ZONE_ID.
# Host files (never committed): ~/meritum/db.env (generated passwords) and the
# optional ~/meritum/app.env (shared app secrets, appended to every env file).
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=onprem/dellpromaxgb10/platform/lib.sh
. "$here/lib.sh"
# shellcheck source=onprem/dellpromaxgb10/platform/db.sh
. "$here/db.sh"

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
m_log "roles, app schemas, DBOS databases and Polish FTS ready: ${ENVS[*]} (mocks: prd only)"

# --- uploaded files: one volume per env, shared by api and worker --------------------
for env in "${ENVS[@]}"; do
  docker volume inspect "$(m_files_volume "$env")" >/dev/null 2>&1 \
    || docker volume create --label meritum.managed=true "$(m_files_volume "$env")" >/dev/null
done

# --- env files for the app deploys -------------------------------------------------
gateway_subnet=$(docker network inspect "$M_NETWORK" -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' | awk '{print $1}')
pw() { local var; var=$(pw_var "$1" "$2"); printf '%s' "${!var}"; }
# MERITUM_DATABASE_URL: database meritum, search_path app_<env>, public.
app_url() { m_db_url "$(m_role "$1" "$2")" "$(pw "$1" "$2")" meritum "$(m_app_schema "$2")"; }
# MERITUM_DBOS_URL: the env's DBOS database; tables in schema dbos (DBOS default).
dbos_url() { m_db_url "$(m_role "$1" "$2")" "$(pw "$1" "$2")" "$(m_dbos_db "$2")"; }
extra() { if [ -f "$M_STATE/app.env" ]; then grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$M_STATE/app.env" || true; fi; }
for env in "${ENVS[@]}"; do
  {
    printf 'MERITUM_ENV=%s\n' "$env"
    printf 'MERITUM_DATABASE_URL=%s\n' "$(app_url api "$env")"
    # The API enqueues into the worker's DBOS tables with its own role
    # (access granted by `dbos migrate -r` in the worker deploy).
    printf 'MERITUM_DBOS_URL=%s\n' "$(dbos_url api "$env")"
    printf 'MERITUM_DBOS_SCHEMA=dbos\n'
    printf 'FORWARDED_ALLOW_IPS=%s\n' "$gateway_subnet"
    printf 'MERITUM_FILES_VOLUME=%s\n' "$(m_files_volume "$env")"
    printf 'MERITUM_FILES_DIR=%s\n' "$M_FILES_DIR"
    extra
  } >"$M_STATE/envs/api-$env.env"
  {
    printf 'MERITUM_ENV=%s\n' "$env"
    printf 'MERITUM_DATABASE_URL=%s\n' "$(app_url worker "$env")"
    printf 'MERITUM_DBOS_URL=%s\n' "$(dbos_url worker "$env")"
    printf 'MERITUM_DBOS_SCHEMA=dbos\n'
    printf 'MERITUM_API_ROLE=%s\n' "$(m_role api "$env")"
    printf 'MERITUM_FILES_VOLUME=%s\n' "$(m_files_volume "$env")"
    printf 'MERITUM_FILES_DIR=%s\n' "$M_FILES_DIR"
    extra
  } >"$M_STATE/envs/worker-$env.env"
  has_env mocks "$env" && {
    printf 'MERITUM_ENV=%s\n' "$env"
    printf 'DATABASE_URL=%s\n' "$(m_db_url "$(m_role mocks "$env")" "$(pw mocks "$env")" meritum)"
  } >"$M_STATE/envs/mocks-$env.env"
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
