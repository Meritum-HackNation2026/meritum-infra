terraform {
  backend "gcs" {
    # Lives in the bucket this module creates; first run: README, "Stan Terraform na GCP".
    bucket = "agro-prj-sandbox-sd-2332277-meritum-tfstate"
    prefix = "state"
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

# Terraform state of every gcp/ module, one prefix each. Versioning keeps every earlier state.
resource "google_storage_bucket" "state" {
  name                        = "${var.project_id}-meritum-tfstate"
  location                    = upper(var.region)
  storage_class               = "STANDARD"
  public_access_prevention    = "enforced"
  uniform_bucket_level_access = true
  force_destroy               = false
  labels = {
    project = "meritum"
    role    = "tfstate"
  }

  versioning {
    enabled = true
  }

  lifecycle {
    prevent_destroy = true
  }
}
