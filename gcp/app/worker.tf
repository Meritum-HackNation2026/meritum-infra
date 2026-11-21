# DBOS worker on VMs (it serves no HTTP), one managed instance group per environment,
# autoscaled on CPU from 1 up to worker_max_replicas.
resource "google_project_iam_member" "worker_vertex" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = data.google_service_account.worker.member
}

resource "google_compute_instance_template" "worker" {
  for_each     = local.envs
  name_prefix  = "meritum-worker-${each.key}-"
  machine_type = var.worker_machine_type
  tags         = ["meritum-worker"]
  labels       = { project = "meritum", role = "worker", env = each.key }

  disk {
    source_image = "cos-cloud/cos-stable"
    disk_size_gb = 20
    boot         = true
  }

  network_interface {
    subnetwork = google_compute_subnetwork.app.id
  }

  service_account {
    email  = data.google_service_account.worker.email
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot = true
  }

  metadata = {
    google-logging-enabled  = "true"
    meritum-env             = each.key
    meritum-image           = "${local.images}/meritum-worker:${each.key}"
    meritum-registry        = local.registry_host
    meritum-vertex-location = var.vertex_location
    meritum-vm-lib          = file("${path.module}/vm-lib.sh")
    startup-script          = file("${path.module}/worker-startup.sh")
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_compute_region_instance_group_manager" "worker" {
  for_each           = local.envs
  name               = "meritum-worker-${each.key}"
  region             = var.region
  base_instance_name = "meritum-worker-${each.key}"
  version {
    instance_template = google_compute_instance_template.worker[each.key].self_link_unique
  }
  depends_on = [google_secret_manager_secret_version.url, google_secret_manager_secret_iam_member.access]
}

resource "google_compute_region_autoscaler" "worker" {
  for_each = local.envs
  name     = "meritum-worker-${each.key}"
  region   = var.region
  target   = google_compute_region_instance_group_manager.worker[each.key].id
  autoscaling_policy {
    min_replicas    = 1
    max_replicas    = var.worker_max_replicas
    cooldown_period = 120
    cpu_utilization {
      target = 0.6
    }
  }
}
