# PostgreSQL in a container on a VM: Cloud SQL cannot load the Polish dictionary (ADR-04).
resource "google_service_account" "postgres" {
  account_id   = "meritum-postgres"
  display_name = "Meritum PostgreSQL VM (secrets: read, images: pull)"
}

resource "google_compute_address" "postgres" {
  name         = "meritum-postgres"
  region       = var.region
  subnetwork   = google_compute_subnetwork.app.id
  address_type = "INTERNAL"
}

resource "google_compute_disk" "pgdata" {
  name   = "meritum-pgdata"
  zone   = var.zone
  type   = "pd-balanced"
  size   = var.postgres_disk_gb
  labels = { project = "meritum", role = "pgdata" }
}

# Backups: daily snapshots of the data disk, kept after the disk is deleted.
resource "google_compute_resource_policy" "pgdata_snapshots" {
  name   = "meritum-pgdata-daily"
  region = var.region
  snapshot_schedule_policy {
    schedule {
      daily_schedule {
        days_in_cycle = 1
        start_time    = "02:00"
      }
    }
    retention_policy {
      max_retention_days    = var.backup_retention_days
      on_source_disk_delete = "KEEP_AUTO_SNAPSHOTS"
    }
    snapshot_properties {
      storage_locations = [var.region]
      labels            = { project = "meritum", role = "pgdata" }
    }
  }
}

resource "google_compute_disk_resource_policy_attachment" "pgdata" {
  name = google_compute_resource_policy.pgdata_snapshots.name
  disk = google_compute_disk.pgdata.name
  zone = var.zone
}

resource "google_compute_instance" "postgres" {
  name                      = "meritum-postgres"
  machine_type              = var.postgres_machine_type
  zone                      = var.zone
  tags                      = ["meritum-postgres"]
  labels                    = { project = "meritum", role = "postgres" }
  allow_stopping_for_update = true

  boot_disk {
    initialize_params {
      image = "cos-cloud/cos-stable"
      size  = 10
    }
  }

  attached_disk {
    source      = google_compute_disk.pgdata.id
    device_name = "pgdata" # /dev/disk/by-id/google-pgdata in postgres-startup.sh
  }

  network_interface {
    subnetwork = google_compute_subnetwork.app.id
    network_ip = google_compute_address.postgres.address
  }

  service_account {
    email  = google_service_account.postgres.email
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot = true
  }

  metadata = {
    google-logging-enabled = "true"
    meritum-envs           = join(" ", var.environments)
    meritum-postgres-image = var.postgres_image
    meritum-registry       = local.registry
    meritum-vm-lib         = file("${path.module}/vm-lib.sh")
    # The same layout as the team server: roles, app_<env> schemas, DBOS databases.
    meritum-platform-lib = file("${path.module}/../../onprem/dellpromaxgb10/platform/lib.sh")
    meritum-db           = file("${path.module}/../../onprem/dellpromaxgb10/platform/db.sh")
  }
  metadata_startup_script = file("${path.module}/postgres-startup.sh")

  # Database passwords must exist before the first boot.
  depends_on = [google_secret_manager_secret_version.postgres, google_secret_manager_secret_version.url, google_secret_manager_secret_iam_member.access]
}

resource "google_compute_firewall" "postgres" {
  name          = "meritum-postgres"
  network       = google_compute_network.app.id
  source_ranges = [var.subnet_cidr] # worker VMs and the API's Direct VPC egress
  target_tags   = ["meritum-postgres"]
  allow {
    protocol = "tcp"
    ports    = ["5432"]
  }
}
