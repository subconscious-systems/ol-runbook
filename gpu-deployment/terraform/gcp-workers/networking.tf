resource "google_compute_network_peering" "gateway_to_workers" {
  count = local.create_peering ? 1 : 0

  provider     = google.gateway
  name         = "${local.resource_prefix}-gw-to-workers"
  network      = data.google_compute_network.gateway[0].self_link
  peer_network = data.google_compute_network.worker.self_link

  import_custom_routes = false
  export_custom_routes = false

  depends_on = [terraform_data.validated_inputs]
}

resource "google_compute_network_peering" "workers_to_gateway" {
  count = local.create_peering ? 1 : 0

  name         = "${local.resource_prefix}-workers-to-gw"
  network      = data.google_compute_network.worker.self_link
  peer_network = data.google_compute_network.gateway[0].self_link

  import_custom_routes = false
  export_custom_routes = false

  depends_on = [terraform_data.validated_inputs]
}

resource "google_compute_subnetwork" "proxy_only" {
  count = var.proxy_only_subnet_name == null ? 1 : 0

  project       = var.project_id
  region        = var.region
  name          = "${local.resource_prefix}-proxy-only"
  network       = data.google_compute_network.worker.id
  ip_cidr_range = var.proxy_only_subnet_cidr
  purpose       = "REGIONAL_MANAGED_PROXY"
  role          = "ACTIVE"

  depends_on = [terraform_data.validated_inputs]
}

locals {
  proxy_only_subnet = var.proxy_only_subnet_name != null ? (
    data.google_compute_subnetwork.proxy_existing[0]
  ) : google_compute_subnetwork.proxy_only[0]
}

resource "google_compute_firewall" "health_checks" {
  project = var.project_id
  name    = "${local.resource_prefix}-health-checks"
  network = data.google_compute_network.worker.name

  direction     = "INGRESS"
  source_ranges = ["35.191.0.0/16", "130.211.0.0/22"]

  allow {
    protocol = "tcp"
    ports    = [for worker in values(var.workers) : tostring(worker.node_port)]
  }

  target_service_accounts = [var.worker_service_account_email]

  depends_on = [terraform_data.validated_inputs]
}

resource "google_compute_firewall" "proxies" {
  project = var.project_id
  name    = "${local.resource_prefix}-proxies"
  network = data.google_compute_network.worker.name

  direction     = "INGRESS"
  source_ranges = [local.proxy_only_subnet.ip_cidr_range]

  allow {
    protocol = "tcp"
    ports    = [for worker in values(var.workers) : tostring(worker.node_port)]
  }

  target_service_accounts = [var.worker_service_account_email]

  depends_on = [terraform_data.validated_inputs]
}
