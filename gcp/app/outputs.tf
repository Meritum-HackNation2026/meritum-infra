output "api_urls" {
  description = "run.app address of the API per environment: the Cloudflare origin (README)."
  value       = { for e, s in google_cloud_run_v2_service.api : e => s.uri }
}

output "postgres_ip" {
  value = google_compute_address.postgres.address
}

output "registry" {
  description = "Artifact Registry path for meritum-postgres, meritum-api and meritum-worker images."
  value       = local.images
}
