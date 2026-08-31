removed {
  from = google_project.environment

  lifecycle {
    destroy = false
  }
}

data "google_project" "environment" {
  project_id = var.project_id
}

resource "google_project_service" "api" {
  for_each = local.required_apis

  project                    = data.google_project.environment.project_id
  service                    = each.value
  disable_on_destroy         = false
  disable_dependent_services = false

  timeouts {
    create = "30m"
    update = "40m"
  }
}

resource "google_storage_bucket" "terraform_state" {
  project                     = data.google_project.environment.project_id
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
