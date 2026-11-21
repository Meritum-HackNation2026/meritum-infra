terraform {
  backend "gcs" {
    bucket = "agro-prj-sandbox-sd-2332277-meritum-tfstate"
    prefix = "search"
  }
  required_version = ">= 1.7"
  required_providers {
    google = {
      source  = "hashicorp/google"
      # Issue #16: 6.x, at least 6.50.0 (Discovery Engine resources).
      version = "~> 6.50"
    }
  }
}

provider "google" {
  project = var.project_id
  # The Discovery Engine API needs a quota project with user credentials.
  billing_project       = var.project_id
  user_project_override = true
}

resource "google_project_service" "discoveryengine" {
  service            = "discoveryengine.googleapis.com"
  disable_on_destroy = false
}

locals {
  included = [for e in yamldecode(file(var.catalog_path)).entries : e.domain if !try(e.excluded, false)]
  # A path under another catalog pattern is already searched (exact_match = false), so it does
  # not use one of the 50 basic website search patterns.
  patterns = toset([for p in local.included : p if !anytrue([for q in local.included : startswith(p, "${q}/")])])
}

# Live search only (US-KOR-04, ADR-07); corpus ingestion does not read from it (ADR-32).
resource "google_discovery_engine_data_store" "live" {
  location                    = "global"
  data_store_id               = var.data_store_id
  display_name                = "Meritum: katalog źródeł"
  industry_vertical           = "GENERIC"
  content_config              = "PUBLIC_WEBSITE"
  solution_types              = ["SOLUTION_TYPE_SEARCH"]
  create_advanced_site_search = false
  depends_on                  = [google_project_service.discoveryengine]

  lifecycle {
    precondition {
      condition     = length(local.patterns) <= 50
      error_message = "Basic website search takes at most 50 INCLUDE patterns; the catalog gives ${length(local.patterns)}."
    }
  }
}

resource "google_discovery_engine_target_site" "catalog" {
  for_each             = local.patterns
  location             = google_discovery_engine_data_store.live.location
  data_store_id        = google_discovery_engine_data_store.live.data_store_id
  provided_uri_pattern = each.value
  type                 = "INCLUDE"
  exact_match          = false
}

resource "google_discovery_engine_search_engine" "live" {
  engine_id         = var.data_store_id
  collection_id     = "default_collection"
  location          = google_discovery_engine_data_store.live.location
  display_name      = "Meritum: wyszukiwanie na żywo"
  industry_vertical = "GENERIC"
  data_store_ids    = [google_discovery_engine_data_store.live.data_store_id]
  search_engine_config {
    search_tier = "SEARCH_TIER_ENTERPRISE"
  }
}
