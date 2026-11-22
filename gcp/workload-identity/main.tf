terraform {
  backend "gcs" {
    bucket = "agro-prj-sandbox-sd-2332277-meritum-tfstate"
    prefix = "workload-identity"
  }
  required_version = ">= 1.7"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.project_id
}

data "google_project" "this" {}

resource "google_iam_workload_identity_pool" "onprem" {
  workload_identity_pool_id = "meritum-onprem" # M_WIF_POOL in wif.sh
  display_name              = "Meritum on-prem"
  description               = "Backend and worker containers on the team server dellpromaxgb10"
}

# X.509 federation: the server proves its identity with a certificate signed by
# its own CA, so no service account key and no token from an outside issuer.
resource "google_iam_workload_identity_pool_provider" "server" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.onprem.workload_identity_pool_id
  workload_identity_pool_provider_id = "dellpromaxgb10" # M_WIF_PROVIDER in wif.sh
  display_name                       = "dellpromaxgb10"
  description                        = "Service certificates signed by the CA of dellpromaxgb10"
  disabled                           = var.disabled
  attribute_mapping = {
    "google.subject" = "assertion.subject.dn.cn"
  }
  attribute_condition = "assertion.subject.dn.cn in ${jsonencode(sort(var.service_accounts))}"

  x509 {
    trust_store {
      trust_anchors {
        pem_certificate = trimspace(var.trust_anchor_pem) # IAM rejects a trailing newline
      }
    }
  }
}

# Service accounts of gcp/storage (infra#8). The certificate with CN <account>,
# issued on dellpromaxgb10 (onprem/dellpromaxgb10/platform/wif.sh), may act only
# as the service account <account>.
resource "google_service_account_iam_member" "workload_identity_user" {
  for_each           = toset(var.service_accounts)
  service_account_id = "projects/${var.project_id}/serviceAccounts/${each.key}@${var.project_id}.iam.gserviceaccount.com"
  role               = "roles/iam.workloadIdentityUser"
  member             = "principal://iam.googleapis.com/projects/${data.google_project.this.number}/locations/global/workloadIdentityPools/${google_iam_workload_identity_pool.onprem.workload_identity_pool_id}/subject/${each.key}"
}

# SDP PII gate (core#90): on-prem containers impersonate these accounts via WIF.
locals {
  pii_service_accounts = toset(["meritum-backend", "meritum-worker"])
}

resource "google_project_iam_member" "dlp_user" {
  for_each = local.pii_service_accounts
  project  = var.project_id
  role     = "roles/dlp.user"
  member   = "serviceAccount:${each.key}@${var.project_id}.iam.gserviceaccount.com"
}

resource "google_project_iam_member" "service_usage" {
  for_each = local.pii_service_accounts
  project  = var.project_id
  role     = "roles/serviceusage.serviceUsageConsumer"
  member   = "serviceAccount:${each.key}@${var.project_id}.iam.gserviceaccount.com"
}

# Live web search (infra#42): the worker calls :search on the meritum-live-search
# serving config of gcp/search (infra#16).
resource "google_project_iam_member" "discoveryengine_viewer" {
  project = var.project_id
  role    = "roles/discoveryengine.viewer"
  member  = "serviceAccount:meritum-worker@${var.project_id}.iam.gserviceaccount.com"
}

# Worker transcription (Speech-to-Text v2, Chirp 3 in the eu multi-region, ADR-30)
# over ADC, i.e. as meritum-worker (meritum-speech only reads gs:// for batch);
# disable_on_destroy=false keeps the API on.
resource "google_project_service" "speech" {
  project            = var.project_id
  service            = "speech.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_iam_member" "speech_client" {
  project = var.project_id
  role    = "roles/speech.client"
  member  = "serviceAccount:meritum-worker@${var.project_id}.iam.gserviceaccount.com"
}
