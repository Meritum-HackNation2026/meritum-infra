#!/usr/bin/env bash
# Local check, outside PR CI: wif.sh issues one certificate per service account,
# signed by the server CA, keeps it on a rerun, renews it near expiry and writes
# external_account credential files with no service account key. Needs openssl.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=onprem/dellpromaxgb10/platform/lib.sh
. "$here/lib.sh"
# shellcheck source=onprem/dellpromaxgb10/platform/wif.sh
. "$here/wif.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
dir=$(mktemp -d); trap 'rm -rf "$dir"' EXIT
serial() { openssl x509 -noout -serial -in "$dir/$1/cert.pem"; }

m_wif_issue "$dir" meritum-test 123456789 2>/dev/null
openssl x509 -noout -ext basicConstraints -in "$dir/ca/ca.pem" | grep -q 'CA:TRUE' || fail "ca.pem is not a CA"
for sa in "${M_WIF_ACCOUNTS[@]}"; do
  openssl verify -CAfile "$dir/ca/ca.pem" "$dir/$sa/cert.pem" >/dev/null || fail "$sa: not signed by the CA"
  openssl x509 -noout -subject -in "$dir/$sa/cert.pem" | grep -q "CN *= *$sa\$" || fail "$sa: wrong CN"
  creds="$dir/$sa/credentials.json"
  grep -q '"type": "external_account"' "$creds" || fail "$sa: not external_account"
  grep -q '"audience": "//iam.googleapis.com/projects/123456789/locations/global/workloadIdentityPools/meritum-onprem/providers/dellpromaxgb10"' "$creds" || fail "$sa: audience"
  grep -q "serviceAccounts/$sa@meritum-test.iam.gserviceaccount.com:" "$creds" || fail "$sa: impersonates another account"
  grep -q "\"certificate_config_location\": \"$M_WIF_MOUNT/$sa/certificate_config.json\"" "$creds" || fail "$sa: config path"
  grep -q "\"key_path\": \"$M_WIF_MOUNT/$sa/key.pem\"" "$dir/$sa/certificate_config.json" || fail "$sa: key path"
done
[ -z "$(find "$dir"/meritum-* -name "ca*")" ] || fail "CA files inside a mounted directory"
grep -rq '"type": "service_account"' "$dir" && fail "service account key on disk"

api=$(m_wif_env "$dir" api meritum-test); worker=$(m_wif_env "$dir" worker meritum-test)
grep -qx "MERITUM_GCP_MOUNTS=$dir/meritum-backend:$M_WIF_MOUNT/meritum-backend:ro" <<<"$api" || fail "api mounts: $api"
grep -qx "MERITUM_GCP_MOUNTS=$dir/meritum-worker:$M_WIF_MOUNT/meritum-worker:ro $dir/meritum-speech:$M_WIF_MOUNT/meritum-speech:ro" <<<"$worker" || fail "worker mounts: $worker"
grep -qx "GOOGLE_APPLICATION_CREDENTIALS=$M_WIF_MOUNT/meritum-worker/credentials.json" <<<"$worker" || fail "worker credentials: $worker"

before=$(serial meritum-backend)
m_wif_issue "$dir" meritum-test 123456789 2>/dev/null
[ "$(serial meritum-backend)" = "$before" ] || fail "rerun replaced a valid certificate"

# A certificate expiring within M_WIF_RENEW_DAYS is renewed.
openssl req -new -key "$dir/meritum-backend/key.pem" -subj /CN=meritum-backend 2>/dev/null \
  | openssl x509 -req -days 1 -CA "$dir/ca/ca.pem" -CAkey "$dir/ca/ca.key" -set_serial 7 -out "$dir/meritum-backend/cert.pem" 2>/dev/null
m_wif_issue "$dir" meritum-test 123456789 2>/dev/null
[ "$(serial meritum-backend)" != "serial=07" ] || fail "expiring certificate not renewed"
echo "workload identity files: ok"
