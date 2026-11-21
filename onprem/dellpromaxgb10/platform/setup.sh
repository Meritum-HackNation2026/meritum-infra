#!/usr/bin/env bash
# Shared Meritum platform on dellpromaxgb10. Idempotent; runs on the host as
# meritum-runner (workflow .github/workflows/platform.yml, or by hand).
#
#   network   meritum (private Docker network of every Meritum container)
#   postgres  meritum-postgres, database `meritum`, one role + schema per app and env:
#               meritum_api_dev    -> api_dev       meritum_api_prd    -> api_prd
#               meritum_worker_dev -> worker_dev    meritum_worker_prd -> worker_prd
#             (worker_<env> also holds the DBOS system tables of that env)
#   env files ~/meritum/envs/<app>-<env>.env (mode 600), read by the app deploys
#   gateway   meritum-gateway (nginx) on 172.17.0.1:18095, reachable by cloudflared only
#   routes    meritum.gburek.app -> meritum-web-prd, meritum-dev.gburek.app -> meritum-web-dev
#             (Cloudflare tunnel ingress + DNS; skipped with a warning without a token)
#
# Env: CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID, CLOUDFLARE_TUNNEL_ID, CLOUDFLARE_ZONE_ID.
# Host files (never committed): ~/meritum/db.env (generated passwords) and the
# optional ~/meritum/app.env (shared app secrets, appended to every env file).
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=onprem/dellpromaxgb10/platform/lib.sh
. "$here/lib.sh"

APPS=(api worker)
ENVS=(dev prd)

mkdir -p "$M_STATE/envs" "$M_STATE/gateway"
chmod 700 "$M_STATE"
exec 9>"$M_STATE/deploy.lock"
flock 9

umask 077
touch "$M_STATE/db.env"
gen_password() { head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32; }
pw_var() { printf '%s_PASSWORD' "$(printf '%s_%s' "$1" "$2" | tr '[:lower:]' '[:upper:]')"; }
vars=(POSTGRES_PASSWORD)
for app in "${APPS[@]}"; do for env in "${ENVS[@]}"; do vars+=("$(pw_var "$app" "$env")"); done; done
for var in "${vars[@]}"; do
  grep -q "^$var=" "$M_STATE/db.env" || { printf '%s=%s\n' "$var" "$(gen_password)" >>"$M_STATE/db.env"; m_log "generated $var"; }
done
# shellcheck disable=SC1091
. "$M_STATE/db.env"

# --- network and database --------------------------------------------------------
docker network inspect "$M_NETWORK" >/dev/null 2>&1 \
  || docker network create --label meritum.managed=true "$M_NETWORK" >/dev/null

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

# Each role owns only its schema; public is read-only (extensions such as pgvector live there).
{
  echo "REVOKE ALL ON DATABASE meritum FROM PUBLIC;"
  echo "REVOKE CREATE ON SCHEMA public FROM PUBLIC;"
  echo "CREATE EXTENSION IF NOT EXISTS vector SCHEMA public;"
  echo "CREATE EXTENSION IF NOT EXISTS pg_trgm SCHEMA public;"
  for app in "${APPS[@]}"; do for env in "${ENVS[@]}"; do
    role=$(m_role "$app" "$env"); schema=$(m_schema "$app" "$env"); var=$(pw_var "$app" "$env")
    echo "DO \$\$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$role') THEN CREATE ROLE $role; END IF; END \$\$;"
    echo "ALTER ROLE $role WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD '${!var}';"
    echo "GRANT CONNECT ON DATABASE meritum TO $role;"
    echo "CREATE SCHEMA IF NOT EXISTS $schema AUTHORIZATION $role;"
    echo "ALTER ROLE $role SET search_path = $schema, public;"
  done; done
} | docker exec -i -e PGOPTIONS="-c client_min_messages=warning" "$M_POSTGRES" psql -q -v ON_ERROR_STOP=1 -U meritum -d meritum >/dev/null
m_log "roles and schemas ready: ${APPS[*]} x ${ENVS[*]}"

# --- env files for the app deploys -------------------------------------------------
gateway_subnet=$(docker network inspect "$M_NETWORK" -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' | awk '{print $1}')
url() { local var; var=$(pw_var "$1" "$2"); printf 'postgresql://%s:%s@%s:5432/meritum' "$(m_role "$1" "$2")" "${!var}" "$M_POSTGRES"; }
extra() { if [ -f "$M_STATE/app.env" ]; then grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$M_STATE/app.env" || true; fi; }
for env in "${ENVS[@]}"; do
  {
    printf 'MERITUM_ENV=%s\n' "$env"
    printf 'MERITUM_DATABASE_URL=%s\n' "$(url api "$env")"
    # The API enqueues into the worker's DBOS tables with its own role
    # (access granted by `dbos migrate -r` in the worker deploy).
    printf 'MERITUM_DBOS_URL=%s\n' "$(url api "$env")"
    printf 'MERITUM_DBOS_SCHEMA=%s\n' "$(m_schema worker "$env")"
    printf 'FORWARDED_ALLOW_IPS=%s\n' "$gateway_subnet"
    extra
  } >"$M_STATE/envs/api-$env.env"
  {
    printf 'MERITUM_ENV=%s\n' "$env"
    printf 'MERITUM_DBOS_URL=%s\n' "$(url worker "$env")"
    printf 'MERITUM_DBOS_SCHEMA=%s\n' "$(m_schema worker "$env")"
    printf 'MERITUM_API_ROLE=%s\n' "$(m_role api "$env")"
    extra
  } >"$M_STATE/envs/worker-$env.env"
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
    host=$(m_host "$env")
    cf_ingress_ensure "$host" "http://$M_GATEWAY_BIND"
    cf_dns_ensure "$host"
  done
fi
m_log "platform ready"
