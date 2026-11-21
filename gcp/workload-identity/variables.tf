variable "project_id" {
  type        = string
  description = "GCP project of the bucket and the service accounts (gcp/storage)."
}

variable "trust_anchor_pem" {
  type        = string
  description = "CA certificate of dellpromaxgb10 (~meritum-runner/meritum/gcp/ca/ca.pem), public."
  validation {
    condition     = startswith(trimspace(var.trust_anchor_pem), "-----BEGIN CERTIFICATE-----")
    error_message = "trust_anchor_pem must be a PEM certificate."
  }
}

variable "service_accounts" {
  type        = list(string)
  default     = ["meritum-backend", "meritum-worker", "meritum-speech"]
  description = "Account IDs from gcp/storage; each is also the CN of its certificate."
}

variable "disabled" {
  type        = bool
  default     = false
  description = "true cuts the server off at once (README: revoking access)."
}
