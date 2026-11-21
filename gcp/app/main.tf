terraform {
  required_version = ">= 1.11" # write-only secret data, ephemeral random_password
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
  # The Billing Budgets API needs a quota project with user credentials.
  billing_project       = var.project_id
  user_project_override = true
}

data "google_project" "this" {}

# Service accounts of gcp/storage (apply it first): the API runs as meritum-backend,
# the worker VMs as meritum-worker.
data "google_service_account" "backend" {
  account_id = "meritum-backend"
}

data "google_service_account" "worker" {
  account_id = "meritum-worker"
}

locals {
  envs     = toset(var.environments)
  registry = "${var.region}-docker.pkg.dev"
  # Deploys (infra#6) push meritum-worker:<env> here; worker VMs pull it on boot.
  images = "${local.registry}/${var.project_id}/${google_artifact_registry_repository.images.repository_id}"
}

resource "google_project_service" "apis" {
  for_each = toset([
    "aiplatform.googleapis.com",
    "artifactregistry.googleapis.com",
    "billingbudgets.googleapis.com",
    "compute.googleapis.com",
    "run.googleapis.com",
    "secretmanager.googleapis.com",
  ])
  service            = each.key
  disable_on_destroy = false
}

resource "google_artifact_registry_repository" "images" {
  repository_id = "meritum"
  location      = var.region
  format        = "DOCKER"
  description   = "Images of the API, the worker and meritum-postgres."
  depends_on    = [google_project_service.apis]
}

# --- network ----------------------------------------------------------------------
resource "google_compute_network" "app" {
  name                    = "meritum-app"
  auto_create_subnetworks = false
  depends_on              = [google_project_service.apis]
}

resource "google_compute_subnetwork" "app" {
  name                     = "meritum-app"
  network                  = google_compute_network.app.id
  region                   = var.region
  ip_cidr_range            = var.subnet_cidr
  private_ip_google_access = true # Artifact Registry, Secret Manager and Vertex AI without public IPs
}

# Workers fetch web pages; no VM has a public IP, so egress goes through NAT.
resource "google_compute_router" "app" {
  name    = "meritum-app"
  network = google_compute_network.app.id
  region  = var.region
}

resource "google_compute_router_nat" "app" {
  name                               = "meritum-app"
  router                             = google_compute_router.app.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# SSH only through IAP (gcloud compute ssh --tunnel-through-iap).
resource "google_compute_firewall" "iap_ssh" {
  name          = "meritum-app-iap-ssh"
  network       = google_compute_network.app.id
  source_ranges = ["35.235.240.0/20"]
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}
