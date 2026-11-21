# Plan-only checks of the Vertex AI Search module, no credentials needed (mock provider).
mock_provider "google" {}

variables {
  project_id   = "meritum-test"
  catalog_path = "tests/fixtures/catalog.yaml"
}

run "patterns_from_catalog" {
  command = plan

  assert {
    condition     = google_discovery_engine_data_store.live.location == "global"
    error_message = "Data store must be in the global location (basic website search)."
  }
  assert {
    condition     = google_discovery_engine_data_store.live.content_config == "PUBLIC_WEBSITE"
    error_message = "Data store must be a website data store."
  }
  assert {
    # The nested mswia path is already covered by www.gov.pl/web/mswia.
    condition     = toset(keys(google_discovery_engine_target_site.catalog)) == toset(["www.gov.pl/web/mswia", "policja.pl"])
    error_message = "One pattern per included catalog entry, excluded entries and covered paths left out."
  }
  assert {
    condition     = alltrue([for t in google_discovery_engine_target_site.catalog : t.type == "INCLUDE" && t.exact_match == false])
    error_message = "Every pattern is INCLUDE and matches the whole path prefix."
  }
  assert {
    condition     = google_discovery_engine_search_engine.live.search_engine_config[0].search_tier == "SEARCH_TIER_ENTERPRISE"
    error_message = "Search engine must be the Enterprise edition."
  }
}

run "pattern_limit" {
  command = plan

  variables {
    catalog_path = "tests/fixtures/catalog-over-limit.yaml"
  }

  expect_failures = [google_discovery_engine_data_store.live]
}
