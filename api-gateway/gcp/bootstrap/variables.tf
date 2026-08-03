variable "organization_id" {
  type        = string
  description = "Numeric Google Cloud organization ID. Set this or folder_id, not both."
  default     = ""

  validation {
    condition     = var.organization_id == "" || can(regex("^[0-9]+$", var.organization_id))
    error_message = "organization_id must be empty or numeric."
  }
}

variable "folder_id" {
  type        = string
  description = "Numeric folder ID for both projects. Set this or organization_id, not both."
  default     = ""

  validation {
    condition     = var.folder_id == "" || can(regex("^[0-9]+$", var.folder_id))
    error_message = "folder_id must be empty or numeric."
  }
}

variable "billing_account_id" {
  type        = string
  description = "Billing account ID attached to both projects (for example 000000-000000-000000)."

  validation {
    condition     = can(regex("^[0-9A-F]{6}-[0-9A-F]{6}-[0-9A-F]{6}$", upper(var.billing_account_id)))
    error_message = "billing_account_id must look like 000000-000000-000000."
  }
}

variable "quota_project_id" {
  type        = string
  description = "Existing project used for client-based API quota during foundation creation."
  default     = ""

  validation {
    condition = (
      var.quota_project_id == "" ||
      can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.quota_project_id))
    )
    error_message = "quota_project_id must be empty or a valid Google Cloud project ID."
  }
}

variable "enabled_environments" {
  type        = set(string)
  description = "Foundation environments created by this state. Start with sandbox; add prod only after the explicit production gate."
  default     = ["sandbox"]

  validation {
    condition = (
      contains(var.enabled_environments, "sandbox") &&
      alltrue([
        for environment in var.enabled_environments :
        contains(["sandbox", "prod"], environment)
      ])
    )
    error_message = "enabled_environments must contain sandbox and may also contain prod."
  }
}

variable "sandbox_project_id" {
  type        = string
  description = "Globally unique project ID for the sandbox gateway."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.sandbox_project_id))
    error_message = "sandbox_project_id must be a valid 6-30 character Google Cloud project ID."
  }
}

variable "production_project_id" {
  type        = string
  description = "Globally unique project ID for the production gateway."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.production_project_id))
    error_message = "production_project_id must be a valid 6-30 character Google Cloud project ID."
  }
}

variable "sandbox_project_name" {
  type        = string
  description = "Display name for the sandbox project."
  default     = "Gateway Sandbox"

  validation {
    condition     = length(var.sandbox_project_name) >= 4 && length(var.sandbox_project_name) <= 30
    error_message = "sandbox_project_name must be 4-30 characters."
  }
}

variable "production_project_name" {
  type        = string
  description = "Display name for the production project."
  default     = "Gateway Production"

  validation {
    condition     = length(var.production_project_name) >= 4 && length(var.production_project_name) <= 30
    error_message = "production_project_name must be 4-30 characters."
  }
}

variable "monthly_budget_amounts_usd" {
  type        = map(number)
  description = "Monthly budget amount in USD per environment; alerts are not hard spend caps."
  default = {
    sandbox = 1200
    prod    = 1200
  }

  validation {
    condition = (
      alltrue([
        for environment in ["sandbox", "prod"] :
        contains(keys(var.monthly_budget_amounts_usd), environment)
      ]) &&
      alltrue([
        for amount in values(var.monthly_budget_amounts_usd) :
        amount > 0 && floor(amount) == amount
      ])
    )
    error_message = "monthly_budget_amounts_usd must contain positive whole-dollar sandbox and prod amounts."
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

variable "bootstrap_zones" {
  type        = map(string)
  description = "Bootstrap VM zone per environment. Both must be in us-east1."
  default = {
    sandbox = "us-east1-b"
    prod    = "us-east1-c"
  }

  validation {
    condition = (
      length(var.bootstrap_zones) == 2 &&
      alltrue([for environment in ["sandbox", "prod"] : contains(keys(var.bootstrap_zones), environment)]) &&
      alltrue([for zone in values(var.bootstrap_zones) : startswith(zone, "us-east1-")])
    )
    error_message = "bootstrap_zones must contain sandbox and prod zones in us-east1."
  }
}

variable "bootstrap_subnet_cidrs" {
  type        = map(string)
  description = "Non-overlapping CIDRs for the isolated bootstrap VM subnets."
  default = {
    sandbox = "10.10.0.0/24"
    prod    = "10.20.0.0/24"
  }

  validation {
    condition = (
      length(var.bootstrap_subnet_cidrs) == 2 &&
      alltrue([for environment in ["sandbox", "prod"] : contains(keys(var.bootstrap_subnet_cidrs), environment)]) &&
      alltrue([for cidr in values(var.bootstrap_subnet_cidrs) : can(cidrhost(cidr, 1))]) &&
      lookup(var.bootstrap_subnet_cidrs, "sandbox", "") != lookup(var.bootstrap_subnet_cidrs, "prod", "")
    )
    error_message = "bootstrap_subnet_cidrs must contain distinct valid sandbox and prod CIDRs."
  }
}

variable "bootstrap_machine_type" {
  type        = string
  description = "Machine type for each keyless Distr Docker-agent VM."
  default     = "e2-standard-2"
}

variable "bootstrap_disk_size_gb" {
  type        = number
  description = "Balanced persistent boot disk size for each bootstrap VM."
  default     = 40

  validation {
    condition     = var.bootstrap_disk_size_gb >= 30
    error_message = "bootstrap_disk_size_gb must be at least 30 GiB."
  }
}

variable "operator_principals" {
  type        = set(string)
  description = "Users or groups allowed to reach both VMs through IAP and OS Login (user: or group: form)."

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

variable "project_deletion_policy" {
  type        = string
  description = "PREVENT protects projects; set DELETE only during an approved final teardown."
  default     = "PREVENT"

  validation {
    condition     = contains(["PREVENT", "ABANDON", "DELETE"], var.project_deletion_policy)
    error_message = "project_deletion_policy must be PREVENT, ABANDON, or DELETE."
  }
}

variable "protect_bootstrap_vms" {
  type        = bool
  description = "Enable Compute Engine deletion protection on both bootstrap VMs."
  default     = true
}

variable "labels" {
  type        = map(string)
  description = "Additional labels applied to projects and bootstrap resources."
  default = {
    application = "subconscious-gateway"
    managed-by  = "terraform"
  }
}
