terraform {
  backend "gcs" {
    bucket = "agro-prj-sandbox-sd-2332277-meritum-tfstate"
    prefix = "storage"
  }
  required_version = ">= 1.7"
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
}

# Citizens' recordings and images (ADR-31). Deleted after the check record's retention.
resource "google_storage_bucket" "uploads" {
  name                        = "${var.project_id}-${var.bucket_suffix}"
  location                    = upper(var.region)
  storage_class               = "STANDARD"
  public_access_prevention    = "enforced"
  uniform_bucket_level_access = true
  force_destroy               = false
  labels = {
    project = "meritum"
    role    = "uploads"
  }

  lifecycle_rule {
    condition {
      age = var.retention_days
    }
    action {
      type = "Delete"
    }
  }
}

resource "google_service_account" "backend" {
  account_id   = "meritum-backend"
  display_name = "Meritum backend (uploads: write)"
}

resource "google_service_account" "worker" {
  account_id   = "meritum-worker"
  display_name = "Meritum worker (uploads: read, delete)"
}

resource "google_service_account" "speech" {
  account_id   = "meritum-speech"
  display_name = "Meritum Speech-to-Text batch (uploads: read)"
}

# Backend only creates objects: no read, overwrite or delete.
resource "google_storage_bucket_iam_member" "backend" {
  bucket = google_storage_bucket.uploads.name
  role   = "roles/storage.objectCreator"
  member = google_service_account.backend.member
}

resource "google_storage_bucket_iam_member" "worker_read" {
  bucket = google_storage_bucket.uploads.name
  role   = "roles/storage.objectViewer"
  member = google_service_account.worker.member
}

# No predefined role grants delete without create, hence a custom one.
resource "google_project_iam_custom_role" "object_deleter" {
  role_id     = "meritumObjectDeleter"
  title       = "Meritum object deleter"
  permissions = ["storage.objects.delete"]
}

resource "google_storage_bucket_iam_member" "worker_delete" {
  bucket = google_storage_bucket.uploads.name
  role   = google_project_iam_custom_role.object_deleter.id
  member = google_service_account.worker.member
}

# Speech-to-Text batch reads recordings longer than about a minute from gs://.
resource "google_storage_bucket_iam_member" "speech" {
  bucket = google_storage_bucket.uploads.name
  role   = "roles/storage.objectViewer"
  member = google_service_account.speech.member
}
