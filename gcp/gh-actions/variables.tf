variable "project_id" {
  type        = string
  description = "GCP project that hosts the runners."
}

variable "region" {
  type    = string
  default = "europe-central2"
}

variable "zone" {
  type    = string
  default = "europe-central2-a"
}

variable "gh_org" {
  type        = string
  description = "GitHub organization the runners register to."
  default     = "Meritum-HackNation2026"
}

variable "gh_registration_token" {
  type        = string
  sensitive   = true
  description = "Org runner registration token (POST /orgs/{org}/actions/runners/registration-token, valid 1 h). scripts/apply.sh fetches it."
}

variable "runner_count" {
  type        = number
  description = "Number of runner VMs, named meritum-gh-runner-1..N. Raising it only adds VMs; lowering it destroys the highest-numbered ones."
  default     = 5
}

variable "machine_type" {
  type    = string
  default = "e2-standard-4"
}

variable "disk_size_gb" {
  type    = number
  default = 100
}

variable "runner_labels" {
  type        = string
  description = "Extra labels; GitHub adds self-hosted, Linux and X64 itself."
  default     = "gcp,meritum"
}

variable "runner_group" {
  type        = string
  description = "Org runner group the runners join (visibility: all repositories). It must exist before apply; the README shows how to create it."
  default     = "meritum-gcp"
}

variable "admin_user" {
  type        = string
  description = "Login for SSH and sudo on every runner VM."
  default     = "meritum"
}

variable "admin_password_hash" {
  type        = string
  sensitive   = true
  description = "SHA-512 crypt hash (openssl passwd -6) of the admin password, for sudo and the serial console."
}

variable "ssh_public_key" {
  type        = string
  description = "OpenSSH public key for admin_user."
}
