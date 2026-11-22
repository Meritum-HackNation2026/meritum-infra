variable "project_id" {
  type        = string
  description = "GCP project that hosts the data store."
}

variable "catalog_path" {
  type        = string
  default     = "../../../core/src/meritum_core/corpus/catalog/catalog.yaml"
  description = "core's source catalog (core#22); the default is the core submodule next to infra in the monorepo."
}

variable "data_store_id" {
  type        = string
  default     = "meritum-live-search"
  description = "Data store id, also used as the search engine id."
}

variable "shared_prefix" {
  type        = string
  default     = "www.gov.pl/web"
  description = "Path prefix whose catalogue entries share one INCLUDE pattern (gov.pl services)."
}
