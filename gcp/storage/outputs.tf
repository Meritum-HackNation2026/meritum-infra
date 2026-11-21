output "bucket" {
  value = google_storage_bucket.uploads.name
}

output "service_accounts" {
  value = {
    backend = google_service_account.backend.email
    worker  = google_service_account.worker.email
    speech  = google_service_account.speech.email
  }
}
