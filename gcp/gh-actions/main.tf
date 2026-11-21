terraform {
  required_version = ">= 1.6"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

locals {
  runner_names = [for i in range(var.runner_count) : format("meritum-gh-runner-%d", i + 1)]
}

resource "google_compute_instance" "gh_runner" {
  for_each = toset(local.runner_names)

  name         = each.key
  machine_type = var.machine_type
  tags         = ["gh-runner"]
  labels = {
    project = "meritum"
    role    = "gh-runner"
  }

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
      size  = var.disk_size_gb
      type  = "pd-balanced"
    }
  }

  network_interface {
    network = "default"
    access_config {} # public egress for the GitHub API, Docker Hub and package mirrors
  }

  service_account {
    scopes = ["cloud-platform"]
  }

  metadata = {
    # GCE guest agent creates this user and installs the key for SSH.
    ssh-keys = "${var.admin_user}:${var.ssh_public_key}"
  }

  metadata_startup_script = templatefile("${path.module}/startup.sh.tftpl", {
    admin_user          = var.admin_user
    admin_password_hash = var.admin_password_hash
    org_url             = "https://github.com/${var.gh_org}"
    registration_token  = var.gh_registration_token
    runner_name         = each.key
    runner_labels       = var.runner_labels
  })

  # The registration token is single-use and expires after an hour; a fresh one on the next
  # apply must not recreate machines that are already registered.
  lifecycle {
    ignore_changes = [metadata_startup_script]
  }
}
