# Plan-only checks of the Workload Identity module, no credentials needed (mock provider).
mock_provider "google" {
  mock_data "google_project" {
    defaults = {
      number = "123456789"
    }
  }
}

variables {
  project_id       = "meritum-test"
  trust_anchor_pem = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n"
}

run "server_certificate_only" {
  command = plan

  assert {
    condition = (
      google_iam_workload_identity_pool.onprem.workload_identity_pool_id == "meritum-onprem" &&
      google_iam_workload_identity_pool_provider.server.workload_identity_pool_provider_id == "dellpromaxgb10"
    )
    error_message = "Pool and provider IDs are the audience in wif.sh (M_WIF_POOL, M_WIF_PROVIDER)."
  }
  assert {
    condition     = one(one(one(google_iam_workload_identity_pool_provider.server.x509).trust_store).trust_anchors).pem_certificate == "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----"
    error_message = "Only the server's CA is trusted, trimmed: the IAM API rejects a trailing newline."
  }
  assert {
    condition     = google_iam_workload_identity_pool_provider.server.attribute_mapping["google.subject"] == "assertion.subject.dn.cn"
    error_message = "The subject is the certificate's CN."
  }
  assert {
    condition     = google_iam_workload_identity_pool_provider.server.attribute_condition == "assertion.subject.dn.cn in [\"meritum-backend\",\"meritum-speech\",\"meritum-worker\"]"
    error_message = "Only the three service certificates may sign in."
  }
}

run "one_binding_per_service" {
  command = plan

  assert {
    condition     = toset(keys(google_service_account_iam_member.workload_identity_user)) == toset(["meritum-backend", "meritum-worker", "meritum-speech"])
    error_message = "Exactly the three service accounts of infra#8 are bound."
  }
  assert {
    condition = alltrue([for name, b in google_service_account_iam_member.workload_identity_user :
      b.role == "roles/iam.workloadIdentityUser" &&
      b.member == "principal://iam.googleapis.com/projects/123456789/locations/global/workloadIdentityPools/meritum-onprem/subject/${name}"
    ])
    error_message = "Each service account trusts only the certificate with its own name."
  }
}

run "rejects_non_pem_trust_anchor" {
  command = plan

  variables {
    trust_anchor_pem = "not a certificate"
  }
  expect_failures = [var.trust_anchor_pem]
}

run "dlp_and_service_usage_for_api_and_worker" {
  command = plan

  assert {
    condition     = toset(keys(google_project_iam_member.dlp_user)) == toset(["meritum-backend", "meritum-worker"])
    error_message = "Only meritum-backend and meritum-worker need roles/dlp.user for the PII adapter."
  }
  assert {
    condition = alltrue([for _, m in google_project_iam_member.dlp_user :
      m.role == "roles/dlp.user" &&
      endswith(m.member, "@meritum-test.iam.gserviceaccount.com")
    ])
    error_message = "Each DLP binding targets the project's service account."
  }
  assert {
    condition     = toset(keys(google_project_iam_member.service_usage)) == toset(["meritum-backend", "meritum-worker"])
    error_message = "SDP sends x-goog-user-project; API and worker need serviceusage.serviceUsageConsumer."
  }
  assert {
    condition     = alltrue([for _, m in google_project_iam_member.service_usage : m.role == "roles/serviceusage.serviceUsageConsumer"])
    error_message = "Service Usage consumer role for quota project checks."
  }
}

run "live_web_search_for_worker_only" {
  command = plan

  assert {
    condition = (
      google_project_iam_member.discoveryengine_viewer.role == "roles/discoveryengine.viewer" &&
      google_project_iam_member.discoveryengine_viewer.member == "serviceAccount:meritum-worker@meritum-test.iam.gserviceaccount.com"
    )
    error_message = "Only meritum-worker calls :search on the meritum-live-search serving config (infra#42)."
  }
}
