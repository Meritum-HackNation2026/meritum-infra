variable "project_id" {
  type        = string
  description = "GCP project that hosts the bucket."
}

variable "region" {
  type    = string
  default = "europe-central2"
}

variable "bucket_suffix" {
  type        = string
  default     = "meritum-uploads"
  description = "Bucket name is <project_id>-<suffix> (globally unique)."
}

variable "retention_days" {
  type        = number
  default     = 30
  description = "Objects are deleted after this many days (check record retention, ADR-31)."
  validation {
    condition     = var.retention_days >= 1
    error_message = "retention_days must be at least 1."
  }
}
