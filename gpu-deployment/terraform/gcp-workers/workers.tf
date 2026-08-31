resource "google_compute_instance_group" "workers" {
  project = var.project_id
  zone    = var.worker_zone
  name    = "${local.resource_prefix}-backends"
  network = data.google_compute_network.worker.id

  instances = [data.google_compute_instance.worker.self_link]

  dynamic "named_port" {
    for_each = var.workers
    content {
      name = local.worker_port_names[named_port.key]
      port = named_port.value.node_port
    }
  }

  depends_on = [terraform_data.validated_inputs]
}

resource "google_compute_region_health_check" "worker" {
  for_each = var.workers

  project = var.project_id
  region  = var.region
  name    = "${local.resource_prefix}-${each.key}-health"

  timeout_sec         = 6
  check_interval_sec  = 30
  healthy_threshold   = 3
  unhealthy_threshold = 2

  http_health_check {
    port         = each.value.node_port
    request_path = "/health"
  }

  depends_on = [terraform_data.validated_inputs]
}

resource "google_compute_region_backend_service" "worker" {
  for_each = var.workers

  project               = var.project_id
  region                = var.region
  name                  = "${local.resource_prefix}-${each.key}"
  protocol              = "HTTP"
  port_name             = local.worker_port_names[each.key]
  load_balancing_scheme = local.lb_scheme
  timeout_sec           = var.backend_timeout_seconds
  health_checks         = [google_compute_region_health_check.worker[each.key].id]

  backend {
    group           = google_compute_instance_group.workers.id
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }

  log_config {
    enable      = true
    sample_rate = 1.0
  }
}

resource "google_compute_region_url_map" "workers" {
  project = var.project_id
  region  = var.region
  name    = "${local.resource_prefix}-routes"

  default_service = google_compute_region_backend_service.worker[sort(keys(var.workers))[0]].id

  dynamic "host_rule" {
    for_each = var.workers
    content {
      hosts        = ["${host_rule.key}.${trim(var.worker_domain, ".")}"]
      path_matcher = "worker-${host_rule.key}"
    }
  }

  dynamic "path_matcher" {
    for_each = var.workers
    content {
      name            = "worker-${path_matcher.key}"
      default_service = google_compute_region_backend_service.worker[path_matcher.key].id
    }
  }
}
