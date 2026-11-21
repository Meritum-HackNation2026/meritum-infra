#!/usr/bin/env bash
# Workload Identity Federation of the backend and worker containers (infra#28).
# Source it, don't run it. The Terraform side is gcp/workload-identity/.
#
# The host keeps its own CA in $dir/ca (never mounted into a container) and one
# certificate per service account, CN = account ID, in $dir/<account>/:
#   cert.pem, key.pem            certificate and private key of the service
#   certificate_config.json      where the client library finds them
#   credentials.json             external_account config, GOOGLE_APPLICATION_CREDENTIALS
# A container mounts only its own account directories read-only at
# $M_WIF_MOUNT/<account>, so the backend cannot act as the worker.
# google-auth (>= 2.39) exchanges the certificate over mTLS at sts.mtls.googleapis.com
# for a short-lived token and impersonates the account: no service account key anywhere.
# shellcheck disable=SC2034  # used by the scripts that source this file
M_WIF_ACCOUNTS=(meritum-backend meritum-worker meritum-speech)
M_WIF_MOUNT="/etc/meritum/gcp"
M_WIF_POOL="meritum-onprem"
M_WIF_PROVIDER="dellpromaxgb10"
M_WIF_CA_DAYS=1825
M_WIF_CERT_DAYS=365 # Google accepts at most 390
M_WIF_RENEW_DAYS=30

# m_wif_issue DIR PROJECT_ID PROJECT_NUMBER: CA, certificates (renewed within M_WIF_RENEW_DAYS
# of expiry) and credential files. Idempotent. Prints nothing secret.
m_wif_issue() {
  local dir=$1 project=$2 number=$3 sa d
  mkdir -p "$dir/ca"
  chmod 700 "$dir" "$dir/ca"
  if [ ! -s "$dir/ca/ca.pem" ]; then
    m_log "creating the workload identity CA in $dir/ca"
    (umask 077; openssl ecparam -name prime256v1 -genkey -noout -out "$dir/ca/ca.key")
    openssl req -x509 -new -key "$dir/ca/ca.key" -sha256 -days "$M_WIF_CA_DAYS" \
      -subj "/CN=Meritum dellpromaxgb10 workload CA" \
      -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
      -out "$dir/ca/ca.pem" 2>/dev/null
  fi
  for sa in "${M_WIF_ACCOUNTS[@]}"; do
    d="$dir/$sa"
    mkdir -p "$d"
    chmod 755 "$d"
    if ! { [ -s "$d/cert.pem" ] \
      && openssl x509 -noout -checkend $((M_WIF_RENEW_DAYS * 86400)) -in "$d/cert.pem" >/dev/null \
      && openssl verify -CAfile "$dir/ca/ca.pem" "$d/cert.pem" >/dev/null 2>&1; }; then
      m_log "issuing the workload certificate $sa"
      # A new key with every certificate, so a renewal also rotates the key.
      (umask 077; openssl ecparam -name prime256v1 -genkey -noout -out "$d/key.pem")
      openssl req -new -key "$d/key.pem" -subj "/CN=$sa" 2>/dev/null \
        | openssl x509 -req -sha256 -days "$M_WIF_CERT_DAYS" -CA "$dir/ca/ca.pem" -CAkey "$dir/ca/ca.key" \
          -set_serial "0x$(openssl rand -hex 16)" \
          -extfile <(printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth\n') \
          -out "$d/cert.pem" 2>/dev/null
    fi
    # Readable inside the container whatever its uid; on the host the parent
    # directory (700, meritum-runner) keeps other users out.
    chmod 644 "$d/cert.pem" "$d/key.pem"
    cat >"$d/certificate_config.json" <<JSON
{
  "cert_configs": {
    "workload": {
      "cert_path": "$M_WIF_MOUNT/$sa/cert.pem",
      "key_path": "$M_WIF_MOUNT/$sa/key.pem"
    }
  }
}
JSON
    cat >"$d/credentials.json" <<JSON
{
  "universe_domain": "googleapis.com",
  "type": "external_account",
  "audience": "//iam.googleapis.com/projects/$number/locations/global/workloadIdentityPools/$M_WIF_POOL/providers/$M_WIF_PROVIDER",
  "subject_token_type": "urn:ietf:params:oauth:token-type:mtls",
  "token_url": "https://sts.mtls.googleapis.com/v1/token",
  "credential_source": {
    "certificate": {
      "certificate_config_location": "$M_WIF_MOUNT/$sa/certificate_config.json"
    }
  },
  "service_account_impersonation_url": "https://iamcredentials.mtls.googleapis.com/v1/projects/-/serviceAccounts/$sa@$project.iam.gserviceaccount.com:generateAccessToken"
}
JSON
    chmod 644 "$d/certificate_config.json" "$d/credentials.json"
  done
}

# m_wif_env DIR APP PROJECT_ID: env file lines of APP (api | worker), its
# credentials, project and the -v mounts of its own account directories.
m_wif_env() {
  local dir=$1 app=$2 project=$3 sa mounts=() own
  case "$app" in
    api) own=(meritum-backend) ;;
    worker) own=(meritum-worker meritum-speech) ;;
    *) m_log "m_wif_env: unknown app $app"; return 1 ;;
  esac
  printf 'GOOGLE_CLOUD_PROJECT=%s\n' "$project"
  [ "$app" != worker ] || printf 'MERITUM_SPEECH_CREDENTIALS=%s/meritum-speech/credentials.json\n' "$M_WIF_MOUNT"
  for sa in "${own[@]}"; do mounts+=("$dir/$sa:$M_WIF_MOUNT/$sa:ro"); done
  printf 'GOOGLE_APPLICATION_CREDENTIALS=%s/%s/credentials.json\n' "$M_WIF_MOUNT" "${own[0]}"
  printf 'MERITUM_GCP_MOUNTS=%s\n' "${mounts[*]}"
}
