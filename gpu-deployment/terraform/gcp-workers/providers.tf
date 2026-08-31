provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google" {
  alias   = "gateway"
  project = coalesce(var.gateway_project_id, var.project_id)
  region  = var.region
}
