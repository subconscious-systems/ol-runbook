resource "google_project" "environment" {
  project_id          = var.project_id
  name                = var.project_name
  billing_account     = var.billing_account_id
  org_id              = var.organization_id != "" ? var.organization_id : null
  folder_id           = var.folder_id != "" ? var.folder_id : null
  auto_create_network = false
  deletion_policy     = var.project_deletion_policy

  labels = merge(var.labels, { environment = "production" })
}

resource "google_project_service" "api" {
  for_each = local.required_apis

  project                    = google_project.environment.project_id
  service                    = each.value
  disable_on_destroy         = false
  disable_dependent_services = false

  timeouts {
    create = "30m"
    update = "40m"
  }
}

resource "google_storage_bucket" "terraform_state" {
  project                     = google_project.environment.project_id
  name                        = "${var.project_id}-subconscious-tfstate"
  location                    = upper(var.region)
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  versioning {
    enabled = true
  }

  labels = merge(var.labels, {
    environment = "production"
    component   = "terraform-state"
  })

  depends_on = [google_project_service.api]
}
