resource "google_project" "environment" {
  for_each = local.environments

  project_id          = each.value.project_id
  name                = each.value.project_name
  billing_account     = var.billing_account_id
  org_id              = var.organization_id != "" ? var.organization_id : null
  folder_id           = var.folder_id != "" ? var.folder_id : null
  auto_create_network = false
  deletion_policy     = var.project_deletion_policy

  labels = merge(var.labels, {
    environment = each.key
  })
}

resource "google_project_service" "api" {
  for_each = local.api_bindings

  project                    = google_project.environment[each.value.environment].project_id
  service                    = each.value.service
  disable_on_destroy         = false
  disable_dependent_services = false

  timeouts {
    create = "30m"
    update = "40m"
  }
}

resource "google_storage_bucket" "terraform_state" {
  for_each = local.environments

  project                     = google_project.environment[each.key].project_id
  name                        = "${each.value.project_id}-subconscious-tfstate"
  location                    = upper(var.region)
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  versioning {
    enabled = true
  }

  labels = merge(var.labels, {
    environment = each.key
    component   = "terraform-state"
  })

  depends_on = [google_project_service.api]
}
