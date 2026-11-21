variable "project_id" {
  type        = string
  description = "GCP project that hosts the state bucket."
}

variable "region" {
  type    = string
  default = "europe-central2"
}
