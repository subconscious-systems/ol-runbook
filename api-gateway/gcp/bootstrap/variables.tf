variable "billing_account_id" {
  type        = string
  description = "Billing account already attached to the selected project, used for budget alerts."

  validation {
    condition     = can(regex("^[0-9A-F]{6}-[0-9A-F]{6}-[0-9A-F]{6}$", upper(var.billing_account_id)))
    error_message = "billing_account_id must look like 000000-000000-000000."
  }
}

variable "quota_project_id" {
  type        = string
  description = "Existing project used for client-based API quota during foundation administration."
  default     = ""

  validation {
    condition = (
      var.quota_project_id == "" ||
      can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.quota_project_id))
    )
    error_message = "quota_project_id must be empty or a valid Google Cloud project ID."
  }
}

variable "project_id" {
  type        = string
  description = "Existing Google Cloud project where the production gateway is deployed."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be a valid 6-30 character Google Cloud project ID."
  }
}

variable "dns_project_id" {
  type        = string
  description = "Existing project that owns the approved public Cloud DNS zone."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.dns_project_id))
    error_message = "dns_project_id must be a valid 6-30 character Google Cloud project ID."
  }
}

variable "monthly_budget_amount_usd" {
  type        = number
  description = "Production monthly budget amount in USD; alerts are not hard spend caps."
  default     = 1200

  validation {
    condition     = var.monthly_budget_amount_usd > 0 && floor(var.monthly_budget_amount_usd) == var.monthly_budget_amount_usd
    error_message = "monthly_budget_amount_usd must be a positive whole-dollar amount."
  }
}

variable "region" {
  type        = string
  description = "Locked deployment region."
  default     = "us-east1"

  validation {
    condition     = var.region == "us-east1"
    error_message = "This production-parity runbook is locked to us-east1."
  }
}

variable "bootstrap_zone" {
  type        = string
  description = "Production bootstrap VM zone in us-east1."
  default     = "us-east1-b"

  validation {
    condition     = startswith(var.bootstrap_zone, "us-east1-")
    error_message = "bootstrap_zone must be in us-east1."
  }
}

variable "bootstrap_subnet_cidr" {
  type        = string
  description = "CIDR for the isolated production bootstrap VM subnet."
  default     = "10.40.0.0/24"

  validation {
    condition = (
      can(cidrhost(var.bootstrap_subnet_cidr, 0))
      && try(split("/", var.bootstrap_subnet_cidr)[1], "") == "24"
      && var.bootstrap_subnet_cidr == try("${cidrhost(var.bootstrap_subnet_cidr, 0)}/24", "")
      && can(regex(
        "^(?:10|192\\.168|172\\.(?:1[6-9]|2[0-9]|3[01]))\\.",
        var.bootstrap_subnet_cidr,
      ))
    )
    error_message = "bootstrap_subnet_cidr must be a canonical RFC1918 /24 with no host bits set."
  }
}

variable "bootstrap_machine_type" {
  type        = string
  description = "Machine type for the keyless Distr Docker-agent VM."
  default     = "e2-standard-2"
}

variable "bootstrap_disk_size_gb" {
  type        = number
  description = "Balanced persistent boot disk size for the bootstrap VM."
  default     = 40

  validation {
    condition     = var.bootstrap_disk_size_gb >= 30
    error_message = "bootstrap_disk_size_gb must be at least 30 GiB."
  }
}

variable "operator_principals" {
  type        = set(string)
  description = "Users or groups allowed to reach the VM through IAP and OS Login (user: or group: form)."

  validation {
    condition = (
      length(var.operator_principals) > 0 &&
      alltrue([
        for principal in var.operator_principals :
        can(regex("^(user|group):[^[:space:]]+@[^[:space:]]+$", principal))
      ])
    )
    error_message = "Set at least one operator principal in user:email or group:email form."
  }
}

variable "protect_bootstrap_vms" {
  type        = bool
  description = "Enable Compute Engine deletion protection on the bootstrap VM."
  default     = true
}

variable "labels" {
  type        = map(string)
  description = "Additional labels applied to bootstrap resources."
  default = {
    application = "subconscious-gateway"
    managed-by  = "terraform"
  }
}
