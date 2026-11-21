#!/usr/bin/env bash
# Creates or updates the runner VMs. Usage: scripts/apply.sh [plan|apply|destroy] [extra terraform args]
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a

ACTION="${1:-apply}"; shift || true
TF=(terraform -chdir=gcp/gh-actions)

# Single-use org registration token, valid for one hour (needs a gh token with admin:org).
if [ "$ACTION" != "destroy" ]; then
  TF_VAR_gh_registration_token=$(gh api -X POST "orgs/$GH_ORG/actions/runners/registration-token" --jq .token)
else
  TF_VAR_gh_registration_token=unused
fi
export TF_VAR_gh_registration_token
export TF_VAR_admin_user="$RUNNER_ADMIN_USER"
export TF_VAR_admin_password_hash="$RUNNER_ADMIN_PASSWORD_HASH"
export TF_VAR_ssh_public_key="$RUNNER_SSH_PUBLIC_KEY"
export TF_VAR_runner_labels="$RUNNER_LABELS"

"${TF[@]}" init -input=false >/dev/null
"${TF[@]}" "$ACTION" -input=false "$@"
