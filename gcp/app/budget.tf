# Budget set up front (ADR-14). It alerts the billing admins; the hard limits are
# api_max_instances and worker_max_replicas.
resource "google_billing_budget" "app" {
  billing_account = var.billing_account
  display_name    = "Meritum ${var.project_id}"
  budget_filter {
    projects = ["projects/${data.google_project.this.number}"]
  }
  amount {
    specified_amount {
      units = tostring(var.monthly_budget)
    }
  }
  dynamic "threshold_rules" {
    for_each = [0.5, 0.9, 1.0]
    content {
      threshold_percent = threshold_rules.value
    }
  }
  depends_on = [google_project_service.apis]
}
