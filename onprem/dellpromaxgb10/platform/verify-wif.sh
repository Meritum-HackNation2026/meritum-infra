#!/usr/bin/env bash
# Local check on dellpromaxgb10, outside CI (needs GCP): a container with only the
# backend's credential files writes a test object through Application Default
# Credentials, a container with the worker's deletes it, and no service account
# key is on disk. Run as meritum-runner after setup.sh and the Terraform apply of
# gcp/workload-identity/:
#   sudo -iu meritum-runner <repo>/onprem/dellpromaxgb10/platform/verify-wif.sh [bucket]
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=onprem/dellpromaxgb10/platform/lib.sh
. "$here/lib.sh"
# shellcheck source=onprem/dellpromaxgb10/platform/wif.sh
. "$here/wif.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
env_file="$M_STATE/envs/api-prd.env"
project=$(sed -n 's/^GOOGLE_CLOUD_PROJECT=//p' "$env_file")
[ -n "$project" ] || fail "no GOOGLE_CLOUD_PROJECT in $env_file: run setup.sh with the GCP variables"
bucket="${1:-$project-meritum-uploads}"
object="verify-wif/$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM.txt"
image="python:3.13-slim"

# run APP SCRIPT: python in a container with the credentials and mounts of APP only.
run() {
  local mounts=() list m
  read -ra list <<<"$(sed -n 's/^MERITUM_GCP_MOUNTS=//p' "$M_STATE/envs/$1-prd.env")"
  for m in "${list[@]}"; do mounts+=(-v "$m"); done
  docker run --rm "${mounts[@]}" \
    -e GOOGLE_CLOUD_PROJECT="$project" \
    -e GOOGLE_APPLICATION_CREDENTIALS="$(sed -n 's/^GOOGLE_APPLICATION_CREDENTIALS=//p' "$M_STATE/envs/$1-prd.env")" \
    -e BUCKET="$bucket" -e OBJECT="$object" -e CODE="$2" "$image" sh -c \
    'pip install -q --root-user-action=ignore --disable-pip-version-check "google-auth>=2.39" google-cloud-storage >/dev/null && python -c "$CODE"'
}

run api "
import os
from google.cloud import storage
storage.Client().bucket(os.environ['BUCKET']).blob(os.environ['OBJECT']).upload_from_string(b'meritum wif check')
print('backend wrote gs://' + os.environ['BUCKET'] + '/' + os.environ['OBJECT'])
" || fail "backend could not write"

run worker "
import os
from google.cloud import storage
storage.Client().bucket(os.environ['BUCKET']).blob(os.environ['OBJECT']).delete()
print('worker deleted it')
" || fail "worker could not delete gs://$bucket/$object"

grep -rlq '"type": *"service_account"' "$M_STATE" && fail "service account key in $M_STATE"
for sa in "${M_WIF_ACCOUNTS[@]}"; do grep -q '"type": "external_account"' "$M_STATE/gcp/$sa/credentials.json" || fail "$sa"; done
echo "workload identity: ok"
