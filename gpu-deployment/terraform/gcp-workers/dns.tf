resource "google_certificate_manager_dns_authorization" "workers" {
  count = var.existing_certificate_id == null ? 1 : 0

  project  = var.project_id
  location = var.region
  name     = "${local.resource_prefix}-dns-auth"
  domain   = trim(var.worker_domain, ".")
  type     = "PER_PROJECT_RECORD"

  labels = local.common_labels

  depends_on = [terraform_data.validated_inputs]
}

resource "google_dns_record_set" "certificate_validation" {
  count = var.existing_certificate_id == null ? 1 : 0

  project      = local.dns_project_id
  managed_zone = data.google_dns_managed_zone.workers.name
  name         = google_certificate_manager_dns_authorization.workers[0].dns_resource_record[0].name
  type         = google_certificate_manager_dns_authorization.workers[0].dns_resource_record[0].type
  ttl          = 300
  rrdatas      = [google_certificate_manager_dns_authorization.workers[0].dns_resource_record[0].data]
}

resource "google_certificate_manager_certificate" "workers" {
  count = var.existing_certificate_id == null ? 1 : 0

  project     = var.project_id
  location    = var.region
  name        = "${local.resource_prefix}-wildcard"
  description = "Wildcard TLS certificate for private or API-key-protected SGLang workers"
  labels      = local.common_labels

  managed {
    domains            = ["*.${trim(var.worker_domain, ".")}"]
    dns_authorizations = [google_certificate_manager_dns_authorization.workers[0].id]
  }

  depends_on = [google_dns_record_set.certificate_validation]
}

locals {
  certificate_id = var.existing_certificate_id != null ? (
    startswith(var.existing_certificate_id, "projects/") ? var.existing_certificate_id : (
      "projects/${var.project_id}/locations/${var.region}/certificates/${var.existing_certificate_id}"
    )
  ) : google_certificate_manager_certificate.workers[0].id
}

resource "google_compute_region_ssl_policy" "workers" {
  project         = var.project_id
  region          = var.region
  name            = "${local.resource_prefix}-tls"
  profile         = "MODERN"
  min_tls_version = "TLS_1_2"
}

resource "google_compute_region_target_https_proxy" "workers" {
  project = var.project_id
  region  = var.region
  name    = "${local.resource_prefix}-https"
  url_map = google_compute_region_url_map.workers.id

  certificate_manager_certificates = [local.certificate_id]
  ssl_policy                       = google_compute_region_ssl_policy.workers.id
}

resource "google_compute_address" "internal" {
  count = local.internal_mode ? 1 : 0

  project      = var.project_id
  region       = var.region
  name         = "${local.resource_prefix}-internal-ip"
  address_type = "INTERNAL"
  subnetwork   = data.google_compute_subnetwork.worker.id
}

resource "google_compute_address" "public" {
  count = local.internal_mode ? 0 : 1

  project      = var.project_id
  region       = var.region
  name         = "${local.resource_prefix}-public-ip"
  address_type = "EXTERNAL"
  network_tier = "PREMIUM"
}

locals {
  frontend_ip = local.internal_mode ? (
    google_compute_address.internal[0].address
  ) : google_compute_address.public[0].address
}

resource "google_compute_forwarding_rule" "internal_https" {
  count = local.internal_mode ? 1 : 0

  project               = var.project_id
  region                = var.region
  name                  = "${local.resource_prefix}-internal-https"
  load_balancing_scheme = "INTERNAL_MANAGED"
  network               = data.google_compute_network.worker.id
  subnetwork            = data.google_compute_subnetwork.worker.id
  ip_address            = google_compute_address.internal[0].id
  port_range            = "443"
  target                = google_compute_region_target_https_proxy.workers.id
  allow_global_access   = false

  depends_on = [google_compute_subnetwork.proxy_only]
}

resource "google_compute_forwarding_rule" "public_https" {
  count = local.internal_mode ? 0 : 1

  project               = var.project_id
  region                = var.region
  name                  = "${local.resource_prefix}-public-https"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  network               = data.google_compute_network.worker.id
  ip_address            = google_compute_address.public[0].id
  ip_protocol           = "TCP"
  port_range            = "443"
  network_tier          = "PREMIUM"
  target                = google_compute_region_target_https_proxy.workers.id

  depends_on = [google_compute_subnetwork.proxy_only]
}

resource "google_dns_record_set" "worker" {
  for_each = var.workers

  project      = local.dns_project_id
  managed_zone = data.google_dns_managed_zone.workers.name
  name         = "${each.key}.${trim(var.worker_domain, ".")}."
  type         = "A"
  ttl          = 300
  rrdatas      = [local.frontend_ip]
}
