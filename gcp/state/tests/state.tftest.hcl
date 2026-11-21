# Plan-only checks of the state bucket, no credentials needed (mock provider).
mock_provider "google" {}

variables {
  project_id = "meritum-test"
}

run "state_bucket" {
  command = plan

  assert {
    condition     = google_storage_bucket.state.location == "EUROPE-CENTRAL2"
    error_message = "State bucket must live in europe-central2."
  }
  assert {
    condition     = one(google_storage_bucket.state.versioning).enabled == true
    error_message = "Object versioning must be on, so an overwritten state can be restored."
  }
  assert {
    condition     = google_storage_bucket.state.public_access_prevention == "enforced"
    error_message = "Public access must be blocked."
  }
  assert {
    condition     = google_storage_bucket.state.uniform_bucket_level_access == true
    error_message = "Uniform bucket-level access must be on."
  }
}
