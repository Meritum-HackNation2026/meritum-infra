# Plan-only checks of the bucket module, no credentials needed (mock provider).
mock_provider "google" {}

variables {
  project_id = "meritum-test"
}

run "bucket" {
  command = plan

  assert {
    condition     = google_storage_bucket.uploads.location == "EUROPE-CENTRAL2"
    error_message = "Bucket must live in europe-central2."
  }
  assert {
    condition     = google_storage_bucket.uploads.public_access_prevention == "enforced"
    error_message = "Public access must be blocked."
  }
  assert {
    condition     = google_storage_bucket.uploads.uniform_bucket_level_access == true
    error_message = "Uniform bucket-level access must be on."
  }
  assert {
    condition = anytrue([for r in google_storage_bucket.uploads.lifecycle_rule :
    one(r.action).type == "Delete" && one(r.condition).age == 30])
    error_message = "Objects must be deleted after 30 days."
  }
}

run "least_privilege" {
  command = plan

  assert {
    condition = (
      google_storage_bucket_iam_member.backend.role == "roles/storage.objectCreator" &&
      google_storage_bucket_iam_member.worker_read.role == "roles/storage.objectViewer" &&
      google_project_iam_custom_role.object_deleter.permissions == toset(["storage.objects.delete"]) &&
      google_storage_bucket_iam_member.speech.role == "roles/storage.objectViewer"
    )
    error_message = "Service accounts get only the roles they need."
  }
}
