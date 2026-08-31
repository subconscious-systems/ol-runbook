mock_provider "google" {
  override_during = plan
}

variables {
  project_id                   = "worker-project"
  dns_project_id               = "dns-project"
  region                       = "us-central1"
  worker_zone                  = "us-central1-a"
  worker_instance_name         = "gpu-worker-1"
  worker_service_account_email = "gpu-worker@worker-project.iam.gserviceaccount.com"
  worker_network_name          = "worker-network"
  worker_subnetwork_name       = "worker-subnet"
  dns_managed_zone_name        = "example-com"
  worker_domain                = "workers.example.com"
  existing_certificate_id      = "existing-wildcard"
  name_prefix                  = "test-workers"
  workers = {
    "8b-a" = { node_port = 30003 }
    "8b-b" = { node_port = 30004 }
  }
}

override_data {
  target = data.google_compute_network.worker
  values = {
    id        = "projects/worker-project/global/networks/worker-network"
    self_link = "https://www.googleapis.com/compute/v1/projects/worker-project/global/networks/worker-network"
    name      = "worker-network"
  }
}

override_data {
  target = data.google_compute_subnetwork.worker
  values = {
    id        = "projects/worker-project/regions/us-central1/subnetworks/worker-subnet"
    self_link = "https://www.googleapis.com/compute/v1/projects/worker-project/regions/us-central1/subnetworks/worker-subnet"
    network   = "projects/worker-project/global/networks/worker-network"
    name      = "worker-subnet"
  }
}

override_data {
  target = data.google_compute_instance.worker
  values = {
    self_link = "https://www.googleapis.com/compute/v1/projects/worker-project/zones/us-central1-a/instances/gpu-worker-1"
    network_interface = [{
      network    = "projects/worker-project/global/networks/worker-network"
      subnetwork = "projects/worker-project/regions/us-central1/subnetworks/worker-subnet"
    }]
    service_account = [{
      email  = "gpu-worker@worker-project.iam.gserviceaccount.com"
      scopes = []
    }]
  }
}

override_data {
  target = data.google_dns_managed_zone.workers
  values = {
    name     = "example-com"
    dns_name = "example.com."
    project  = "dns-project"
  }
}

run "internal_private_routing" {
  command = plan

  variables {
    exposure_mode          = "internal"
    gateway_project_id     = "gateway-project"
    gateway_network_name   = "gateway-network"
    manage_network_peering = true
  }

  override_data {
    target = data.google_compute_network.gateway[0]
    values = {
      id        = "projects/gateway-project/global/networks/gateway-network"
      self_link = "https://www.googleapis.com/compute/v1/projects/gateway-project/global/networks/gateway-network"
      name      = "gateway-network"
    }
  }

  assert {
    condition = (
      length(google_compute_forwarding_rule.internal_https) == 1
      && length(google_compute_forwarding_rule.public_https) == 0
      && google_compute_forwarding_rule.internal_https[0].load_balancing_scheme == "INTERNAL_MANAGED"
    )
    error_message = "Internal mode must create only a private INTERNAL_MANAGED HTTPS frontend."
  }

  assert {
    condition = (
      length(google_compute_network_peering.gateway_to_workers) == 1
      && length(google_compute_network_peering.workers_to_gateway) == 1
    )
    error_message = "Internal mode must create both peering directions when requested."
  }

  assert {
    condition = (
      length(google_compute_region_backend_service.worker) == 2
      && alltrue([
        for backend in google_compute_region_backend_service.worker :
        backend.load_balancing_scheme == "INTERNAL_MANAGED"
      ])
    )
    error_message = "Every internal worker needs an INTERNAL_MANAGED backend service."
  }
}

run "public_requires_api_key_acknowledgement" {
  command = plan

  variables {
    exposure_mode          = "public-api-key"
    confirm_worker_api_key = false
  }

  expect_failures = [terraform_data.validated_inputs]
}

run "public_api_key_routing" {
  command = plan

  variables {
    exposure_mode          = "public-api-key"
    confirm_worker_api_key = true
  }

  assert {
    condition = (
      length(google_compute_forwarding_rule.internal_https) == 0
      && length(google_compute_forwarding_rule.public_https) == 1
      && google_compute_forwarding_rule.public_https[0].load_balancing_scheme == "EXTERNAL_MANAGED"
      && google_compute_forwarding_rule.public_https[0].network == data.google_compute_network.worker.id
    )
    error_message = "Public API-key mode must create only an EXTERNAL_MANAGED HTTPS frontend."
  }

  assert {
    condition = (
      length(google_compute_network_peering.gateway_to_workers) == 0
      && length(google_compute_network_peering.workers_to_gateway) == 0
    )
    error_message = "Public mode must not create gateway VPC peering."
  }

  assert {
    condition = alltrue([
      for backend in google_compute_region_backend_service.worker :
      backend.load_balancing_scheme == "EXTERNAL_MANAGED"
    ])
    error_message = "Every public worker needs an EXTERNAL_MANAGED backend service."
  }

  assert {
    condition = alltrue([
      for endpoint in output.worker_endpoints : endpoint.requires_api_key
    ])
    error_message = "Dashboard endpoint output must identify bearer-key protection."
  }
}

run "managed_wildcard_certificate" {
  command = plan

  variables {
    exposure_mode           = "public-api-key"
    confirm_worker_api_key  = true
    existing_certificate_id = null
  }

  override_resource {
    target = google_certificate_manager_dns_authorization.workers[0]
    values = {
      id = "projects/worker-project/locations/us-central1/dnsAuthorizations/test-workers-dns-auth"
      dns_resource_record = [{
        name = "_acme-challenge_workers.example.com."
        type = "CNAME"
        data = "validation.example.net."
      }]
    }
  }

  assert {
    condition = (
      length(google_certificate_manager_dns_authorization.workers) == 1
      && length(google_dns_record_set.certificate_validation) == 1
      && length(google_certificate_manager_certificate.workers) == 1
      && length(google_certificate_manager_certificate.workers[0].managed[0].domains) == 1
      && contains(google_certificate_manager_certificate.workers[0].managed[0].domains, "*.workers.example.com")
    )
    error_message = "A missing certificate must create regional DNS authorization, its CNAME, and a wildcard certificate."
  }
}
