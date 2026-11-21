# API on Cloud Run, one service per environment, scaled from 0 up to api_max_instances.
# Cloudflare proxies the public hostname to its run.app URL (README).
resource "google_cloud_run_v2_service" "api" {
  for_each = local.envs
  name     = "meritum-api-${each.key}"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"
  # Public API: no IAM check on invocations (works under domain-restricted sharing too).
  invoker_iam_disabled = true
  labels               = { project = "meritum", role = "api", env = each.key }
  deletion_protection  = false # no data here; `terraform destroy` stops the costs (README)

  template {
    service_account = data.google_service_account.backend.email
    scaling {
      min_instance_count = 0
      max_instance_count = var.api_max_instances
    }
    # PostgreSQL has only a private IP; other traffic leaves Cloud Run directly.
    vpc_access {
      egress = "PRIVATE_RANGES_ONLY"
      network_interfaces {
        network    = google_compute_network.app.id
        subnetwork = google_compute_subnetwork.app.id
      }
    }
    containers {
      # Placeholder until the first deploy (infra#6) sets the meritum-api image.
      image = "us-docker.pkg.dev/cloudrun/container/hello"
      ports {
        container_port = 8000
      }
      resources {
        limits = { cpu = "1", memory = "512Mi" }
      }
      env {
        name  = "MERITUM_ENV"
        value = each.key
      }
      env {
        name  = "MERITUM_DBOS_SCHEMA"
        value = "dbos"
      }
      dynamic "env" {
        for_each = { MERITUM_DATABASE_URL = "database-url", MERITUM_DBOS_URL = "dbos-url" }
        content {
          name = env.key
          value_source {
            secret_key_ref {
              secret  = google_secret_manager_secret.db["api-${each.key}-${env.value}"].secret_id
              version = "latest"
            }
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [template[0].containers[0].image, client, client_version]
  }
  depends_on = [google_secret_manager_secret_version.url, google_secret_manager_secret_iam_member.access]
}
