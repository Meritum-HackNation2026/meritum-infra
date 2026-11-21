# Plan-only checks of the app module, no credentials needed (mock google provider;
# random runs locally). Scenario of infra#11: `terraform plan` creates the API, the
# worker and PostgreSQL in europe-central2, secrets in Secret Manager and service
# accounts with only the roles they need.
mock_provider "google" {
  mock_data "google_project" {
    defaults = { number = "123456789" }
  }
  mock_resource "google_service_account" {
    defaults = {
      email  = "meritum-postgres@meritum-test.iam.gserviceaccount.com"
      member = "serviceAccount:meritum-postgres@meritum-test.iam.gserviceaccount.com"
    }
  }
}

# Distinct accounts, so a swapped API and worker account fails the IAM checks.
override_data {
  target = data.google_service_account.backend
  values = {
    email  = "meritum-backend@meritum-test.iam.gserviceaccount.com"
    member = "serviceAccount:meritum-backend@meritum-test.iam.gserviceaccount.com"
  }
}

override_data {
  target = data.google_service_account.worker
  values = {
    email  = "meritum-worker@meritum-test.iam.gserviceaccount.com"
    member = "serviceAccount:meritum-worker@meritum-test.iam.gserviceaccount.com"
  }
}

variables {
  project_id      = "meritum-test"
  billing_account = "000000-AAAAAA-BBBBBB"
  postgres_image  = "europe-central2-docker.pkg.dev/meritum-test/meritum/meritum-postgres:0.8.7-pg18-abc1234"
}

run "everything_in_europe_central2" {
  command = plan

  assert {
    condition = alltrue([
      google_compute_subnetwork.app.region == "europe-central2",
      startswith(google_compute_instance.postgres.zone, "europe-central2-"),
      google_compute_disk.pgdata.zone == google_compute_instance.postgres.zone,
      google_artifact_registry_repository.images.location == "europe-central2",
      alltrue([for s in google_cloud_run_v2_service.api : s.location == "europe-central2"]),
      alltrue([for m in google_compute_region_instance_group_manager.worker : m.region == "europe-central2"]),
    ])
    error_message = "API, worker, PostgreSQL and the registry must run in europe-central2."
  }
  assert {
    condition = alltrue([for s in google_secret_manager_secret.db :
    one(one(one(s.replication).user_managed).replicas).location == "europe-central2"])
    error_message = "Secrets must be stored only in europe-central2."
  }
}

run "postgres_is_private_and_backed_up" {
  command = plan

  assert {
    condition = alltrue([for t in google_compute_instance_template.worker :
    length(one(t.network_interface).access_config) == 0])
    error_message = "Worker VMs must have no public IP."
  }

  assert {
    condition     = length(one(google_compute_instance.postgres.network_interface).access_config) == 0
    error_message = "The database VM must have no public IP."
  }
  assert {
    condition = (
      tolist(google_compute_firewall.postgres.source_ranges) == tolist(["10.20.0.0/24"]) &&
      tolist(one(google_compute_firewall.postgres.allow).ports) == tolist(["5432"])
    )
    error_message = "Port 5432 must be open only to the app subnet."
  }
  assert {
    condition = (
      one(one(google_compute_resource_policy.pgdata_snapshots.snapshot_schedule_policy).retention_policy).max_retention_days == 7 &&
      google_compute_disk_resource_policy_attachment.pgdata.disk == google_compute_disk.pgdata.name
    )
    error_message = "The data disk must get daily snapshots kept 7 days."
  }
}

run "autoscaling_has_limits" {
  command = plan

  assert {
    condition = alltrue([for s in google_cloud_run_v2_service.api :
    one(one(s.template).scaling).max_instance_count == 3])
    error_message = "The API scales to at most api_max_instances."
  }
  assert {
    condition = alltrue([for a in google_compute_region_autoscaler.worker :
    one(a.autoscaling_policy).min_replicas == 1 && one(a.autoscaling_policy).max_replicas == 3])
    error_message = "Workers scale between 1 and worker_max_replicas."
  }
  assert {
    condition     = one(one(google_billing_budget.app.amount).specified_amount).units == "100"
    error_message = "The budget must be set up front."
  }
}

run "least_privilege" {
  command = plan

  assert {
    condition = (
      google_project_iam_member.worker_vertex.role == "roles/aiplatform.user" &&
      toset([for m in google_secret_manager_secret_iam_member.access : m.role]) == toset(["roles/secretmanager.secretAccessor"]) &&
      toset(keys(google_secret_manager_secret_iam_member.access)) == toset([
        "api/api-prd-database-url", "api/api-prd-dbos-url",
        "worker/worker-prd-database-url", "worker/worker-prd-dbos-url",
        "postgres/postgres-password", "postgres/api-prd-database-url", "postgres/worker-prd-database-url",
      ])
    )
    error_message = "Each service account reads only its own secrets; only the worker calls Vertex AI."
  }
  assert {
    # The postgres account is created in the same plan, so only its key set is checked above.
    condition = alltrue([for k, m in google_secret_manager_secret_iam_member.access :
      m.member == {
        api    = "serviceAccount:meritum-backend@meritum-test.iam.gserviceaccount.com"
        worker = "serviceAccount:meritum-worker@meritum-test.iam.gserviceaccount.com"
    }[split("/", k)[0]] if !startswith(k, "postgres/")])
    error_message = "Secrets are granted to the right service account."
  }
  assert {
    condition = (
      google_project_iam_member.worker_vertex.member == "serviceAccount:meritum-worker@meritum-test.iam.gserviceaccount.com" &&
      toset([for m in google_project_iam_member.vm_logs : m.role]) == toset(["roles/logging.logWriter"]) &&
      toset([for m in google_artifact_registry_repository_iam_member.pull : m.role]) == toset(["roles/artifactregistry.reader"])
    )
    error_message = "VMs get only log writing and image pulls; Vertex AI goes to the worker account."
  }
  assert {
    condition = alltrue([for e in one(one(google_cloud_run_v2_service.api["prd"].template).containers).env :
      length(e.value_source) == 0 || startswith(one(one(e.value_source).secret_key_ref).secret, "meritum-api-prd-")
    ])
    error_message = "The API reads only its own secrets."
  }
}

run "only_known_environments" {
  command = plan
  variables {
    environments = ["prod"]
  }
  expect_failures = [var.environments]
}

# db.sh makes meritum_worker_prd the owner of the shared corpus schema.
run "prd_is_required" {
  command = plan
  variables {
    environments = ["dev"]
  }
  expect_failures = [var.environments]
}

run "vertex_stays_in_the_eu" {
  command = plan
  variables {
    vertex_location = "us-central1"
  }
  expect_failures = [var.vertex_location]
}
