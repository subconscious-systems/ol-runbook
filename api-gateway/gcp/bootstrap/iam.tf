resource "google_service_account" "bootstrap" {
  for_each = local.environments

  project      = google_project.environment[each.key].project_id
  account_id   = "gateway-${each.key}-platform"
  display_name = "Gateway ${each.key} platform applier"
  description  = "Attached only to the keyless Distr bootstrap VM; no user-managed keys."

  depends_on = [google_project_service.api]
}

resource "google_project_iam_member" "platform_apply" {
  for_each = local.platform_role_bindings

  project = google_project.environment[each.value.environment].project_id
  role    = each.value.role
  member  = "serviceAccount:${google_service_account.bootstrap[each.value.environment].email}"
}

resource "google_storage_bucket_iam_member" "platform_state" {
  for_each = local.platform_state_bindings

  bucket = google_storage_bucket.terraform_state[each.value.environment].name
  role   = each.value.role
  member = "serviceAccount:${google_service_account.bootstrap[each.value.environment].email}"
}

resource "google_project_iam_member" "operator_project_access" {
  for_each = local.operator_project_bindings

  project = google_project.environment[each.value.environment].project_id
  role    = each.value.role
  member  = each.value.principal
}

resource "google_storage_bucket_iam_member" "operator_state" {
  for_each = local.operator_state_bindings

  bucket = google_storage_bucket.terraform_state[each.value.environment].name
  role   = each.value.role
  member = each.value.principal
}

resource "google_service_account_iam_member" "operator_act_as" {
  for_each = local.operator_service_account_bindings

  service_account_id = google_service_account.bootstrap[each.value.environment].name
  role               = "roles/iam.serviceAccountUser"
  member             = each.value.principal
}
