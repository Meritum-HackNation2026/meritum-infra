# Database credentials in Secret Manager. Passwords are ephemeral: Terraform writes
# them once (write-only secret_data_wo) and never keeps them in the state or the plan.
locals {
  roles = { for p in setproduct(["api", "worker"], var.environments) : "${p[0]}-${p[1]}" => { app = p[0], env = p[1] } }
  # MERITUM_DATABASE_URL (database meritum, search_path app_<env>) and MERITUM_DBOS_URL
  # (database meritum_dbos_<env>) of every role, as m_db_url in db.sh builds them.
  urls = merge(
    { for k, r in local.roles : "${k}-database-url" => { role = k, app = r.app, suffix = "meritum?options=-csearch_path%3Dapp_${r.env},public" } },
    { for k, r in local.roles : "${k}-dbos-url" => { role = k, app = r.app, suffix = "meritum_dbos_${r.env}" } },
  )
  secrets = setunion(["postgres-password"], keys(local.urls))

  # Who reads which secret: each app its own URLs; the PostgreSQL VM the superuser
  # password and the database URLs, which carry the role passwords.
  secret_readers = merge(
    { for s, u in local.urls : "${u.app}/${s}" => { reader = u.app, secret = s } },
    { for s in setunion(["postgres-password"], [for k in keys(local.roles) : "${k}-database-url"]) :
    "postgres/${s}" => { reader = "postgres", secret = s } },
  )
  members = {
    api      = data.google_service_account.backend.member
    worker   = data.google_service_account.worker.member
    postgres = google_service_account.postgres.member
  }
}

# Only [A-Za-z0-9]: db.sh puts passwords into SQL and URLs unescaped.
ephemeral "random_password" "db" {
  for_each = setunion(["postgres"], keys(local.roles))
  length   = 32
  special  = false
}

resource "google_secret_manager_secret" "db" {
  for_each  = local.secrets
  secret_id = "meritum-${each.key}"
  labels    = { project = "meritum" }
  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "postgres" {
  secret                 = google_secret_manager_secret.db["postgres-password"].id
  secret_data_wo         = ephemeral.random_password.db["postgres"].result
  secret_data_wo_version = var.db_password_version
}

resource "google_secret_manager_secret_version" "url" {
  for_each = local.urls
  secret   = google_secret_manager_secret.db[each.key].id
  secret_data_wo = format("postgresql://meritum_%s:%s@%s:5432/%s",
    replace(each.value.role, "-", "_"), ephemeral.random_password.db[each.value.role].result,
  google_compute_address.postgres.address, each.value.suffix)
  secret_data_wo_version = var.db_password_version
}

resource "google_secret_manager_secret_iam_member" "access" {
  for_each  = local.secret_readers
  secret_id = google_secret_manager_secret.db[each.value.secret].id
  role      = "roles/secretmanager.secretAccessor"
  member    = local.members[each.value.reader]
}
