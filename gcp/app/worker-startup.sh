#!/usr/bin/env bash
# Boot script of a worker VM (Container-Optimized OS): runs the DBOS worker of one
# environment. Settings come from instance metadata, database URLs from Secret
# Manager; the env file lives in /run (tmpfs) only.
set -euo pipefail
mkdir -p /run/meritum
curl -fsS --retry 5 -H 'Metadata-Flavor: Google' \
  http://metadata.google.internal/computeMetadata/v1/instance/attributes/meritum-vm-lib >/run/meritum/vm-lib.sh
# shellcheck source=gcp/app/vm-lib.sh
. /run/meritum/vm-lib.sh

env=$(md meritum-env)
image=$(md meritum-image)
vertex_location=$(md meritum-vertex-location)
project=$(md_get project/project-id)
database_url=$(secret "worker-$env-database-url")
dbos_url=$(secret "worker-$env-dbos-url")

umask 077
envfile=/run/meritum/worker.env
cat >"$envfile" <<ENV
MERITUM_ENV=$env
MERITUM_DATABASE_URL=$database_url
MERITUM_DBOS_URL=$dbos_url
MERITUM_DBOS_SCHEMA=dbos
MERITUM_API_ROLE=meritum_api_$env
GOOGLE_CLOUD_PROJECT=$project
GOOGLE_CLOUD_LOCATION=$vertex_location
GOOGLE_GENAI_USE_VERTEXAI=true
MERITUM_PII_GATE=sdp
MERITUM_PII_PROJECT=$project
MERITUM_PII_LOCATION=europe-central2
ENV

docker_login
docker pull -q "$image" >/dev/null
# DBOS system tables in meritum_dbos_<env>; the API role gets access so it can enqueue.
# shellcheck disable=SC2016 # expanded by the container's shell
docker run --rm --env-file "$envfile" "$image" \
  sh -c 'dbos migrate -s "$MERITUM_DBOS_URL" --schema "$MERITUM_DBOS_SCHEMA" -r "$MERITUM_API_ROLE"' >/dev/null
docker rm -f meritum-worker >/dev/null 2>&1 || true
# --stop-timeout: DBOS gets time to finish the current step when the VM is scaled in.
docker run -d --name meritum-worker --restart always --stop-timeout 40 --log-driver gcplogs \
  --env-file "$envfile" "$image" >/dev/null
echo "[meritum] worker $env started from $image" >&2
