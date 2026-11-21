output "data_store_id" {
  value = google_discovery_engine_data_store.live.data_store_id
}

output "serving_config" {
  description = "Serving config of the search engine for the core Vertex AI Search adapter (core#34)."
  value       = "${google_discovery_engine_search_engine.live.name}/servingConfigs/default_search"
}

output "patterns" {
  value = sort(tolist(local.patterns))
}
