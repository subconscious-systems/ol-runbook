resource "google_org_policy_policy" "datadog_domain_restricted_sharing" {
  for_each = local.datadog_domain_policy_environments

  name   = "projects/${google_project.environment[each.key].number}/policies/iam.allowedPolicyMemberDomains"
  parent = "projects/${google_project.environment[each.key].number}"

  spec {
    inherit_from_parent = false

    rules {
      values {
        allowed_values = local.datadog_domain_policy_allowed_customer_ids
      }
    }
  }

  depends_on = [google_project_service.api]
}
