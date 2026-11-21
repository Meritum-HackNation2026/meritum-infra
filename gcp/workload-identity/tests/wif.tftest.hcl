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
    condition     = one(one(one(google_iam_workload_identity_pool_provider.server.x509).trust_store).trust_anchors).pem_certificate == var.trust_anchor_pem
    error_message = "Only certificates signed by the server's CA are trusted."
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
