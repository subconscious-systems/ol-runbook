variable "project_id" {
  description = "Project containing the GPU VM and worker load balancer."
  type        = string
}

variable "dns_project_id" {
  description = "Project containing the public Cloud DNS managed zone. Null uses project_id."
  type        = string
  default     = null
  nullable    = true
}

variable "region" {
  description = "Region containing the GPU VM and regional load balancer."
  type        = string
}

variable "worker_zone" {
  description = "Zone containing the existing GPU VM."
  type        = string
}

variable "worker_instance_name" {
  description = "Name of the existing GPU VM running k3s and SGLang."
  type        = string
}

variable "worker_service_account_email" {
  description = "Service account attached to the existing GPU VM; used to target narrow load-balancer firewall rules."
  type        = string
}

variable "worker_network_name" {
  description = "VPC network containing the GPU VM."
  type        = string
}

variable "worker_subnetwork_name" {
  description = "Regional subnetwork containing the GPU VM."
  type        = string
}

variable "exposure_mode" {
  description = "internal for peered private access, or public-api-key for a public frontend protected by SGLang bearer auth."
  type        = string
  default     = "internal"

  validation {
    condition     = contains(["internal", "public-api-key"], var.exposure_mode)
    error_message = "exposure_mode must be internal or public-api-key."
  }
}

variable "confirm_worker_api_key" {
  description = "Explicit acknowledgement that every published worker endpoint enforces SGLANG_WORKER_API_KEY. Required in public-api-key mode."
  type        = bool
  default     = false
}

variable "gateway_project_id" {
  description = "Project containing the gateway GKE VPC. Required in internal mode."
  type        = string
  default     = null
  nullable    = true
}

variable "gateway_network_name" {
  description = "Gateway GKE VPC network to peer with the worker VPC. Required in internal mode."
  type        = string
  default     = null
  nullable    = true
}

variable "manage_network_peering" {
  description = "Create both directions of VPC Network Peering in internal mode. Set false when the networks are already connected."
  type        = bool
  default     = true
}

variable "proxy_only_subnet_name" {
  description = "Existing ACTIVE REGIONAL_MANAGED_PROXY subnet name. Null creates one."
  type        = string
  default     = null
  nullable    = true
}

variable "proxy_only_subnet_cidr" {
  description = "CIDR used when creating the regional proxy-only subnet."
  type        = string
  default     = "10.129.0.0/23"
}

variable "dns_managed_zone_name" {
  description = "Cloud DNS managed-zone resource name, not the DNS suffix."
  type        = string
}

variable "worker_domain" {
  description = "DNS suffix for worker endpoints, such as workers.example.com."
  type        = string
}

variable "existing_certificate_id" {
  description = "Existing regional Certificate Manager certificate resource name or projects/... ID. Null creates a wildcard certificate."
  type        = string
  default     = null
  nullable    = true
}

variable "name_prefix" {
  description = "Short prefix for GCP resource names."
  type        = string
  default     = "sglang-workers"

  validation {
    condition     = can(regex("^[a-z]([-a-z0-9]*[a-z0-9])?$", var.name_prefix)) && length(var.name_prefix) <= 25
    error_message = "name_prefix must be a lowercase GCP resource prefix of at most 25 characters."
  }
}

variable "workers" {
  description = "Worker hostname labels and k3s NodePorts."
  type = map(object({
    node_port = number
  }))

  validation {
    condition = (
      length(var.workers) > 0
      && alltrue([
        for name, worker in var.workers :
        can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", name))
        && length(name) <= 30
        && worker.node_port >= 30000
        && worker.node_port <= 32767
      ])
      && length(distinct([for worker in values(var.workers) : worker.node_port])) == length(var.workers)
    )
    error_message = "workers must contain unique NodePorts in 30000-32767 and DNS-safe labels of at most 30 characters."
  }
}

variable "backend_timeout_seconds" {
  description = "Maximum request/stream duration from the load balancer to SGLang."
  type        = number
  default     = 3600

  validation {
    condition     = var.backend_timeout_seconds >= 1 && var.backend_timeout_seconds <= 86400
    error_message = "backend_timeout_seconds must be between 1 and 86400."
  }
}

variable "labels" {
  description = "Additional labels for label-capable resources."
  type        = map(string)
  default     = {}
}
