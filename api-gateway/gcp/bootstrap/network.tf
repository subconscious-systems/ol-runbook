resource "google_compute_network" "bootstrap" {
  for_each = local.environments

  project                 = google_project.environment[each.key].project_id
  name                    = "gateway-${each.key}-bootstrap"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"

  depends_on = [google_project_service.api]
}

resource "google_compute_subnetwork" "bootstrap" {
  for_each = local.environments

  project                  = google_project.environment[each.key].project_id
  name                     = "gateway-${each.key}-bootstrap-${var.region}"
  region                   = var.region
  network                  = google_compute_network.bootstrap[each.key].id
  ip_cidr_range            = each.value.subnet_cidr
  private_ip_google_access = true

  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

resource "google_compute_router" "bootstrap" {
  for_each = local.environments

  project = google_project.environment[each.key].project_id
  name    = "gateway-${each.key}-bootstrap"
  region  = var.region
  network = google_compute_network.bootstrap[each.key].id
}

resource "google_compute_router_nat" "bootstrap" {
  for_each = local.environments

  project                            = google_project.environment[each.key].project_id
  name                               = "gateway-${each.key}-bootstrap"
  region                             = var.region
  router                             = google_compute_router.bootstrap[each.key].name
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"
  min_ports_per_vm                   = 64

  subnetwork {
    name                    = google_compute_subnetwork.bootstrap[each.key].id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

resource "google_compute_firewall" "iap_ssh" {
  for_each = local.environments

  project   = google_project.environment[each.key].project_id
  name      = "gateway-${each.key}-allow-iap-ssh"
  network   = google_compute_network.bootstrap[each.key].name
  direction = "INGRESS"
  priority  = 1000

  source_ranges           = ["35.235.240.0/20"]
  target_service_accounts = [google_service_account.bootstrap[each.key].email]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}
