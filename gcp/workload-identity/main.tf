terraform {
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
  workload_identity_pool_id = var.pool_id
  display_name              = "Meritum on-prem"
  description               = "Backend and worker containers on the team server dellpromaxgb10"
}

# X.509 federation: the server proves its identity with a certificate signed by
# its own CA, so no service account key and no token from an outside issuer.
resource "google_iam_workload_identity_pool_provider" "server" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.onprem.workload_identity_pool_id
  workload_identity_pool_provider_id = var.provider_id
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
        pem_certificate = var.trust_anchor_pem
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
