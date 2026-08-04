locals {
  environment_definitions = {
    sandbox = {
      project_id   = var.sandbox_project_id
      project_name = var.sandbox_project_name
      zone         = var.bootstrap_zones["sandbox"]
      subnet_cidr  = var.bootstrap_subnet_cidrs["sandbox"]
    }
    prod = {
      project_id   = var.production_project_id
      project_name = var.production_project_name
      zone         = var.bootstrap_zones["prod"]
      subnet_cidr  = var.bootstrap_subnet_cidrs["prod"]
    }
  }

  environments = {
    for environment, config in local.environment_definitions :
    environment => config
    if contains(var.enabled_environments, environment)
  }

  required_apis = toset([
    "artifactregistry.googleapis.com",
    "billingbudgets.googleapis.com",
    "certificatemanager.googleapis.com",
    "cloudasset.googleapis.com",
    "cloudbilling.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "container.googleapis.com",
    "dns.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "iap.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "orgpolicy.googleapis.com",
    "oslogin.googleapis.com",
    "redis.googleapis.com",
    "secretmanager.googleapis.com",
    "servicenetworking.googleapis.com",
    "serviceusage.googleapis.com",
    "sqladmin.googleapis.com",
    "storage.googleapis.com",
    "sts.googleapis.com",
  ])

  api_bindings = {
    for pair in flatten([
      for environment, config in local.environments : [
        for service in local.required_apis : {
          key         = "${environment}/${service}"
          environment = environment
          project_id  = config.project_id
          service     = service
        }
      ]
    ]) : pair.key => pair
  }

  # These service-scoped roles avoid Owner and Editor. Project IAM mutation is
  # still powerful and is required for Terraform to create WIF/ESO identities.
  platform_apply_roles = toset([
    "roles/cloudsql.admin",
    "roles/compute.loadBalancerAdmin",
    "roles/compute.networkAdmin",
    "roles/compute.publicIpAdmin",
    "roles/compute.securityAdmin",
    "roles/container.admin",
    "roles/dns.admin",
    "roles/iam.securityAdmin",
    "roles/iam.serviceAccountAdmin",
    "roles/iam.serviceAccountUser",
    "roles/orgpolicy.policyViewer",
    "roles/redis.admin",
    "roles/resourcemanager.projectIamAdmin",
    "roles/secretmanager.admin",
    "roles/serviceusage.serviceUsageAdmin",
    "roles/serviceusage.serviceUsageConsumer",
  ])

  platform_role_bindings = {
    for binding in flatten([
      for environment, config in local.environments : [
        for role in local.platform_apply_roles : {
          key         = "${environment}/${role}"
          environment = environment
          project_id  = config.project_id
          role        = role
        }
      ]
    ]) : binding.key => binding
  }

  state_bucket_roles = toset([
    "roles/storage.bucketViewer",
    "roles/storage.objectAdmin",
  ])

  platform_state_bindings = {
    for binding in flatten([
      for environment, config in local.environments : [
        for role in local.state_bucket_roles : {
          key         = "${environment}/${role}"
          environment = environment
          project_id  = config.project_id
          role        = role
        }
      ]
    ]) : binding.key => binding
  }

  operator_project_roles = toset([
    "roles/compute.osAdminLogin",
    "roles/compute.viewer",
    "roles/iap.tunnelResourceAccessor",
  ])

  operator_project_bindings = {
    for binding in flatten([
      for environment, config in local.environments : [
        for principal in var.operator_principals : [
          for role in local.operator_project_roles : {
            key         = "${environment}/${principal}/${role}"
            environment = environment
            project_id  = config.project_id
            principal   = principal
            role        = role
          }
        ]
      ]
    ]) : binding.key => binding
  }

  operator_state_bindings = {
    for binding in flatten([
      for environment, config in local.environments : [
        for principal in var.operator_principals : [
          for role in local.state_bucket_roles : {
            key         = "${environment}/${principal}/${role}"
            environment = environment
            project_id  = config.project_id
            principal   = principal
            role        = role
          }
        ]
      ]
    ]) : binding.key => binding
  }

  operator_service_account_bindings = {
    for binding in flatten([
      for environment, config in local.environments : [
        for principal in var.operator_principals : {
          key         = "${environment}/${principal}"
          environment = environment
          project_id  = config.project_id
          principal   = principal
        }
      ]
    ]) : binding.key => binding
  }
}

check "project_parent" {
  assert {
    condition     = (var.organization_id != "") != (var.folder_id != "")
    error_message = "Set exactly one of organization_id or folder_id."
  }
}

check "separate_projects" {
  assert {
    condition     = var.sandbox_project_id != var.production_project_id
    error_message = "Sandbox and production must use separate project IDs."
  }
}
