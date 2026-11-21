#!/usr/bin/env bash
# Boot script of the PostgreSQL VM (Container-Optimized OS), run on every boot and
# idempotent: mounts the data disk, starts meritum-postgres from the pinned image and
# applies the database layout of the team server (onprem/dellpromaxgb10/platform/db.sh).
set -euo pipefail
mkdir -p /run/meritum
for f in vm-lib platform-lib db; do
  curl -fsS --retry 5 -H 'Metadata-Flavor: Google' \
    "http://metadata.google.internal/computeMetadata/v1/instance/attributes/meritum-$f" >"/run/meritum/$f.sh"
done
# shellcheck source=gcp/app/vm-lib.sh
. /run/meritum/vm-lib.sh
# shellcheck source=onprem/dellpromaxgb10/platform/lib.sh
. /run/meritum/platform-lib.sh
# shellcheck source=onprem/dellpromaxgb10/platform/db.sh
. /run/meritum/db.sh

data=/mnt/disks/pgdata
disk=/dev/disk/by-id/google-pgdata
# Format only a disk without a file system (the first boot on a new disk).
blkid "$disk" >/dev/null || mkfs.ext4 -m 0 -E lazy_itable_init=0,lazy_journal_init=0,discard "$disk"
mkdir -p "$data"
mountpoint -q "$data" || mount -o discard,defaults "$disk" "$data"

envs=$(md meritum-envs)
image=$(md meritum-postgres-image)
POSTGRES_PASSWORD=$(secret postgres-password)
export POSTGRES_PASSWORD
# db.sh reads role passwords from <APP>_<ENV>_PASSWORD; they sit in the role's
# database URL, postgresql://<role>:<password>@<host>:5432/meritum?...
for env in $envs; do
  for app in api worker; do
    url=$(secret "$app-$env-database-url")
    password=${url#*://*:}
    printf -v "$(pw_var "$app" "$env")" '%s' "${password%%@*}"
  done
done

docker_login
current=$(docker inspect -f '{{.Config.Image}}' "$M_POSTGRES" 2>/dev/null || true)
if [ -n "$current" ] && [ "$current" != "$image" ]; then
  m_log "replacing $M_POSTGRES ($current -> $image); the data stays on $data"
  docker stop -t 30 "$M_POSTGRES" >/dev/null
  docker rm "$M_POSTGRES" >/dev/null
fi
if ! docker container inspect "$M_POSTGRES" >/dev/null 2>&1; then
  m_log "starting $M_POSTGRES from $image"
  docker run -d --name "$M_POSTGRES" --restart unless-stopped --log-driver gcplogs \
    -p 5432:5432 -e POSTGRES_USER=meritum -e POSTGRES_PASSWORD -e POSTGRES_DB=meritum \
    -v "$data:/var/lib/postgresql" "$image" >/dev/null
fi
docker start "$M_POSTGRES" >/dev/null
for i in $(seq 60); do
  docker exec "$M_POSTGRES" pg_isready -h 127.0.0.1 -U meritum -d meritum >/dev/null 2>&1 && break
  [ "$i" = 60 ] && { m_log "$M_POSTGRES not ready"; exit 1; }
  sleep 1
done

# Roles (passwords from Secret Manager on every boot), app_<env> schemas, DBOS databases.
m_db_sql "$envs" "" | docker exec -i -e PGOPTIONS="-c client_min_messages=warning" "$M_POSTGRES" \
  psql -q -v ON_ERROR_STOP=1 -U meritum -d meritum >/dev/null
m_log "database layout applied for: $envs"
