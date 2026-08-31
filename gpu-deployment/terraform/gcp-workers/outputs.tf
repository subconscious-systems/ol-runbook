output "exposure_mode" {
  description = "Selected worker frontend mode."
  value       = var.exposure_mode
}

output "frontend_ip" {
  description = "Private or public regional load-balancer IP."
  value       = local.frontend_ip
}

output "certificate_id" {
  description = "Regional Certificate Manager certificate attached to the HTTPS proxy."
  value       = local.certificate_id
}

output "gateway_route_allowed_host_suffix" {
  description = "Add this suffix to the gateway routeAllowedHostSuffixes setting."
  value       = trim(var.worker_domain, ".")
}

output "worker_endpoints" {
  description = "Worker endpoint details for the API gateway dashboard."
  value = {
    for name, worker in var.workers :
    name => {
      url                = "https://${name}.${trim(var.worker_domain, ".")}"
      node_port          = worker.node_port
      frontend_ip        = local.frontend_ip
      backend_service_id = google_compute_region_backend_service.worker[name].id
      requires_api_key   = true
    }
  }
}
