provider "google" {
  billing_project       = var.quota_project_id != "" ? var.quota_project_id : null
  user_project_override = var.quota_project_id != ""
}
