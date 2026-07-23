variable "aws_region" {
  description = "AWS region containing both the gateway and worker VPCs."
  type        = string
  default     = "us-east-2"
}

variable "name_prefix" {
  description = "Optional prefix for worker AWS resource names. Keep short enough for the 32-character NLB name limit."
  type        = string
  default     = ""

  validation {
    condition     = var.name_prefix == "" || can(regex("^[a-zA-Z0-9][a-zA-Z0-9-]*$", var.name_prefix))
    error_message = "name_prefix must be empty or contain only letters, numbers, and hyphens."
  }
}

variable "gateway_vpc_id" {
  description = "VPC containing the API gateway EKS cluster."
  type        = string
}

variable "gateway_subnet_ids" {
  description = "Gateway EKS private subnets whose effective route tables need worker-VPC routes."
  type        = set(string)

  validation {
    condition     = length(var.gateway_subnet_ids) > 0
    error_message = "Provide at least one gateway private subnet ID."
  }
}

variable "worker_vpc_id" {
  description = "VPC containing the GPU instance and internal worker NLBs."
  type        = string
}

variable "existing_vpc_peering_connection_id" {
  description = "Reuse an active gateway-to-worker VPC peering connection. Leave null to create and auto-accept one in the current AWS account."
  type        = string
  default     = null
  nullable    = true
}

variable "manage_vpc_routes" {
  description = "Create both directions of VPC routes. Set false only while adopting routes that already exist outside this state."
  type        = bool
  default     = true
}

variable "worker_subnet_ids" {
  description = "Worker-VPC subnets in which the internal NLBs will be created."
  type        = set(string)

  validation {
    condition     = length(var.worker_subnet_ids) > 0
    error_message = "Provide at least one worker subnet ID."
  }
}

variable "worker_instance_id" {
  description = "GPU EC2 instance registered in every worker target group."
  type        = string
}

variable "worker_instance_security_group_id" {
  description = "Security group attached to the GPU EC2 instance."
  type        = string
}

variable "existing_nlb_security_group_id" {
  description = "Reuse a security group for private worker NLBs. Leave null to create one."
  type        = string
  default     = null
  nullable    = true
}

variable "nlb_security_group_name" {
  description = "Name used when Terraform creates the reusable worker NLB security group."
  type        = string
  default     = "sglang-worker-private-nlbs"
}

variable "manage_security_group_rules" {
  description = "Create the NLB and worker security-group rules. Set false only while adopting rules that already exist outside this state."
  type        = bool
  default     = true
}

variable "workers" {
  description = "Workers to expose. Each map key becomes the DNS label and resource-name component."
  type = map(object({
    node_port         = number
    target_group_name = optional(string)
    nlb_name          = optional(string)
  }))

  validation {
    condition = length(var.workers) > 0 && alltrue([
      for name, worker in var.workers :
      can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", name))
      && worker.node_port >= 30000
      && worker.node_port <= 32767
      && (worker.target_group_name == null || length(worker.target_group_name) <= 32)
      && (worker.nlb_name == null || length(worker.nlb_name) <= 32)
    ])
    error_message = "workers must be non-empty; keys must be DNS labels, ports must be in 30000-32767, and explicit AWS names must not exceed 32 characters."
  }
}

variable "route53_zone_name" {
  description = "Existing public Route 53 hosted zone, for example orangelinelabs.com."
  type        = string
}

variable "worker_domain" {
  description = "DNS suffix for worker endpoints, for example workers.orangelinelabs.com."
  type        = string

  validation {
    condition     = !startswith(var.worker_domain, "*.") && !endswith(var.worker_domain, ".")
    error_message = "worker_domain must be a suffix without a wildcard or trailing dot."
  }
}

variable "certificate_arn" {
  description = "Most recent ISSUED regional ACM certificate whose primary domain is *.worker_domain. Leave null to create and DNS-validate one."
  type        = string
  default     = null
  nullable    = true
}

variable "tls_security_policy" {
  description = "NLB TLS listener security policy."
  type        = string
  default     = "ELBSecurityPolicy-TLS13-1-2-2021-06"
}

variable "enable_cross_zone_load_balancing" {
  description = "Route each NLB node to healthy targets in every enabled AZ."
  type        = bool
  default     = true
}

variable "enable_deletion_protection" {
  description = "Protect worker NLBs from accidental deletion."
  type        = bool
  default     = false
}

variable "node_port_min" {
  description = "Lowest NodePort permitted from the reusable NLB security group."
  type        = number
  default     = 30000
}

variable "node_port_max" {
  description = "Highest NodePort permitted from the reusable NLB security group."
  type        = number
  default     = 32767
}

variable "tags" {
  description = "Additional tags applied to AWS resources."
  type        = map(string)
  default     = {}
}
