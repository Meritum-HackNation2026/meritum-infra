# Audience of the credential configuration files (onprem/dellpromaxgb10/platform/wif.sh).
output "audience" {
  value = "//iam.googleapis.com/${google_iam_workload_identity_pool_provider.server.name}"
}

output "project_number" {
  value = data.google_project.this.number
}
