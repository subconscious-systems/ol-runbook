resource "google_service_account" "bootstrap" {
  project      = data.google_project.environment.project_id
  account_id   = "gateway-platform"
  display_name = "Gateway production platform applier"
  description  = "Attached only to the keyless Distr bootstrap VM; no user-managed keys."

  depends_on = [google_project_service.api]
}

resource "google_project_iam_member" "platform_apply" {
  for_each = local.platform_apply_roles

  project = data.google_project.environment.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.bootstrap.email}"
}

resource "google_project_iam_member" "platform_dns" {
  project = var.dns_project_id
  role    = "roles/dns.admin"
  member  = "serviceAccount:${google_service_account.bootstrap.email}"
}

resource "google_storage_bucket_iam_member" "platform_state" {
  for_each = local.state_bucket_roles

  bucket = google_storage_bucket.terraform_state.name
  role   = each.value
  member = "serviceAccount:${google_service_account.bootstrap.email}"
}

resource "google_project_iam_member" "operator_project_access" {
  for_each = local.operator_project_bindings

  project = data.google_project.environment.project_id
  role    = each.value.role
  member  = each.value.principal
}

resource "google_storage_bucket_iam_member" "operator_state" {
  for_each = local.operator_state_bindings

  bucket = google_storage_bucket.terraform_state.name
  role   = each.value.role
  member = each.value.principal
}

resource "google_service_account_iam_member" "operator_act_as" {
  for_each = local.operator_service_account_bindings

  service_account_id = google_service_account.bootstrap.name
  role               = "roles/iam.serviceAccountUser"
  member             = each.value.principal
}
