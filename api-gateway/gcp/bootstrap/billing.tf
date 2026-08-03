resource "google_billing_budget" "environment" {
  for_each = local.environments

  billing_account = var.billing_account_id
  display_name    = "Subconscious gateway ${each.key} monthly budget"

  budget_filter {
    projects               = ["projects/${google_project.environment[each.key].number}"]
    calendar_period        = "MONTH"
    credit_types_treatment = "INCLUDE_ALL_CREDITS"
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(var.monthly_budget_amounts_usd[each.key])
    }
  }

  threshold_rules {
    threshold_percent = 0.5
  }

  threshold_rules {
    threshold_percent = 0.9
  }

  threshold_rules {
    threshold_percent = 1.0
  }

  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "FORECASTED_SPEND"
  }

  depends_on = [google_project_service.api]
}
