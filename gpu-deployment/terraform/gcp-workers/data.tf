locals {
  dns_project_id = coalesce(var.dns_project_id, var.project_id)
  internal_mode  = var.exposure_mode == "internal"

  gateway_project_id = coalesce(var.gateway_project_id, var.project_id)
  same_network = local.internal_mode && (
    local.gateway_project_id == var.project_id
    && var.gateway_network_name == var.worker_network_name
  )
  create_peering = local.internal_mode && var.manage_network_peering && !local.same_network

  common_labels = merge(
    {
      managed-by = "terraform"
      component  = "sglang-workers"
    },
    var.labels,
  )

  resource_prefix = trimsuffix(substr(var.name_prefix, 0, 25), "-")
  worker_port_names = {
    for name in keys(var.workers) : name => "http-${name}"
  }
  lb_scheme = local.internal_mode ? "INTERNAL_MANAGED" : "EXTERNAL_MANAGED"
}

data "google_compute_network" "worker" {
  project = var.project_id
  name    = var.worker_network_name
}

data "google_compute_subnetwork" "worker" {
  project = var.project_id
  region  = var.region
  name    = var.worker_subnetwork_name
}

data "google_compute_instance" "worker" {
  project = var.project_id
  zone    = var.worker_zone
  name    = var.worker_instance_name
}

data "google_compute_network" "gateway" {
  count = local.internal_mode ? 1 : 0

  provider = google.gateway
  project  = local.gateway_project_id
  name     = var.gateway_network_name
}

data "google_compute_subnetwork" "proxy_existing" {
  count = var.proxy_only_subnet_name != null ? 1 : 0

  project = var.project_id
  region  = var.region
  name    = var.proxy_only_subnet_name
}

data "google_dns_managed_zone" "workers" {
  project = local.dns_project_id
  name    = var.dns_managed_zone_name
}

resource "terraform_data" "validated_inputs" {
  lifecycle {
    precondition {
      condition = !local.internal_mode || (
        var.gateway_project_id != null
        && var.gateway_network_name != null
      )
      error_message = "internal mode requires gateway_project_id and gateway_network_name."
    }

    precondition {
      condition = (
        data.google_compute_subnetwork.worker.network == data.google_compute_network.worker.id
        && data.google_compute_instance.worker.network_interface[0].network == data.google_compute_network.worker.id
        && data.google_compute_instance.worker.network_interface[0].subnetwork == data.google_compute_subnetwork.worker.id
      )
      error_message = "The selected GPU VM, worker network, and worker subnetwork do not match."
    }

    precondition {
      condition = contains(
        data.google_compute_instance.worker.service_account[*].email,
        var.worker_service_account_email,
      )
      error_message = "worker_service_account_email must be attached to the selected GPU VM."
    }

    precondition {
      condition     = startswith(var.worker_zone, "${var.region}-")
      error_message = "worker_zone must be inside region."
    }

    precondition {
      condition = (
        lower(trim(var.worker_domain, ".")) == lower(trim(data.google_dns_managed_zone.workers.dns_name, "."))
        || endswith(
          lower(trim(var.worker_domain, ".")),
          ".${lower(trim(data.google_dns_managed_zone.workers.dns_name, "."))}",
        )
      )
      error_message = "worker_domain must be inside the selected public Cloud DNS zone."
    }

    precondition {
      condition = var.proxy_only_subnet_name == null ? true : (
        data.google_compute_subnetwork.proxy_existing[0].network == data.google_compute_network.worker.id
      )
      error_message = "proxy_only_subnet_name must identify a subnet in the worker VPC and region. Confirm separately that it is the ACTIVE REGIONAL_MANAGED_PROXY subnet."
    }

    precondition {
      condition     = var.exposure_mode != "public-api-key" || var.confirm_worker_api_key
      error_message = "public-api-key mode requires worker auth; use a published profile with worker.auth.enabled=true and SGLANG_WORKER_API_KEY configured."
    }
  }
}
