#!/usr/bin/env bash
# Helpers of the VM boot scripts (postgres-startup.sh, worker-startup.sh). Source it,
# don't run it. The VMs run Container-Optimized OS: curl and docker, no gcloud or jq.

# The startup-script service runs without HOME; lib.sh and docker-credential-gcr need
# one, and the root home on COS is read-only.
export HOME=/var/lib/meritum
mkdir -p "$HOME"

md_url=http://metadata.google.internal/computeMetadata/v1
md_get() { curl -fsS --retry 5 -H 'Metadata-Flavor: Google' "$md_url/$1"; }
# Instance metadata attribute $1 (set by Terraform in gcp/app).
md() { md_get "instance/attributes/$1"; }

# Latest version of secret meritum-$1; the VM's service account must be able to read it.
secret() {
  local project token
  project=$(md_get project/project-id)
  token=$(md_get instance/service-accounts/default/token | sed 's/.*"access_token": *"\([^"]*\)".*/\1/')
  curl -fsS --retry 5 -H "Authorization: Bearer $token" \
    "https://secretmanager.googleapis.com/v1/projects/$project/secrets/meritum-$1/versions/latest:access" \
    | sed -n 's/.*"data": *"\([^"]*\)".*/\1/p' | base64 -d
}

# docker pull from Artifact Registry as the VM's service account.
docker_login() {
  docker-credential-gcr configure-docker --registries="$(md meritum-registry)" >/dev/null
}
