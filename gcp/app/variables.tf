variable "project_id" {
  type        = string
  description = "GCP project that hosts the app."
}

variable "region" {
  type    = string
  default = "europe-central2"
}

variable "zone" {
  type        = string
  default     = "europe-central2-a"
  description = "Zone of the PostgreSQL VM and its data disk."
}

variable "environments" {
  type        = list(string)
  default     = ["prd"]
  description = "Environments with their own API, worker, app_<env> schema and meritum_dbos_<env> database (layout of onprem/dellpromaxgb10/platform/db.sh)."
  validation {
    # prd is required: db.sh makes meritum_worker_prd the owner of the shared corpus schema.
    condition     = contains(var.environments, "prd") && alltrue([for e in var.environments : contains(["dev", "prd"], e)])
    error_message = "environments must contain prd and may contain only dev and prd."
  }
}

variable "subnet_cidr" {
  type        = string
  default     = "10.20.0.0/24"
  description = "App subnet: PostgreSQL, worker VMs and the API's Direct VPC egress."
}

variable "postgres_image" {
  type        = string
  description = "Pinned meritum-postgres image (infra#7) in the Artifact Registry repo of this module, e.g. europe-central2-docker.pkg.dev/<project>/meritum/meritum-postgres:0.8.7-pg18-<commit>."
}

variable "postgres_machine_type" {
  type    = string
  default = "e2-medium"
}

variable "postgres_disk_gb" {
  type        = number
  default     = 20
  description = "Size of the data disk (pd-balanced) that holds the PostgreSQL data directory."
}

variable "backup_retention_days" {
  type        = number
  default     = 7
  description = "Daily snapshots of the data disk are kept this many days."
}

variable "api_max_instances" {
  type        = number
  default     = 3
  description = "Upper limit of Cloud Run instances of the API, per environment."
}

variable "worker_machine_type" {
  type    = string
  default = "e2-medium"
}

variable "worker_max_replicas" {
  type        = number
  default     = 3
  description = "Upper limit of worker VMs per environment (autoscaled on CPU from 1)."
  validation {
    condition     = var.worker_max_replicas >= 1
    error_message = "worker_max_replicas must be at least 1."
  }
}

variable "vertex_location" {
  type        = string
  default     = "europe-west4"
  description = "EU region of Vertex AI where the chosen model is available (ADR-14), passed to the worker as GOOGLE_CLOUD_LOCATION."
  validation {
    # GCP regions in EU member states; europe-west2 (London) and europe-west6 (Zurich) are not.
    condition = contains([
      "eu", "europe-central2", "europe-north1", "europe-north2", "europe-southwest1", "europe-west1",
      "europe-west3", "europe-west4", "europe-west8", "europe-west9", "europe-west10", "europe-west12",
    ], var.vertex_location)
    error_message = "vertex_location must be a GCP region in the EU or the eu multi-region."
  }
}

variable "billing_account" {
  type        = string
  description = "Billing account of the project, for the budget (gcloud billing projects describe <project_id>)."
}

variable "monthly_budget" {
  type        = number
  default     = 100
  description = "Monthly budget in the billing account's currency; alerts at 50, 90 and 100 %."
}

variable "db_password_version" {
  type        = number
  default     = 1
  description = "Bump to generate new database passwords (written to Secret Manager only, never to the state)."
}
