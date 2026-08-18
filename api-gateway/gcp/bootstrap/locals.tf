locals {
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

  # These service-scoped roles avoid Owner and Editor. Project IAM mutation is
  # still powerful and is required for Terraform to create WIF/ESO identities.
  platform_apply_roles = toset([
    "roles/cloudsql.admin",
    "roles/compute.loadBalancerAdmin",
    "roles/compute.networkAdmin",
    "roles/compute.publicIpAdmin",
    "roles/compute.securityAdmin",
    "roles/container.admin",
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

  state_bucket_roles = toset([
    "roles/storage.bucketViewer",
    "roles/storage.objectAdmin",
  ])

  operator_project_roles = toset([
    "roles/compute.osAdminLogin",
    "roles/compute.viewer",
    "roles/iap.tunnelResourceAccessor",
  ])

  operator_project_bindings = {
    for binding in flatten([
      for principal in var.operator_principals : [
        for role in local.operator_project_roles : {
          key       = "${principal}/${role}"
          principal = principal
          role      = role
        }
      ]
    ]) : binding.key => binding
  }

  operator_state_bindings = {
    for binding in flatten([
      for principal in var.operator_principals : [
        for role in local.state_bucket_roles : {
          key       = "${principal}/${role}"
          principal = principal
          role      = role
        }
      ]
    ]) : binding.key => binding
  }

  operator_service_account_bindings = {
    for principal in var.operator_principals : principal => {
      principal = principal
    }
  }
}

check "project_parent" {
  assert {
    condition     = (var.organization_id != "") != (var.folder_id != "")
    error_message = "Set exactly one of organization_id or folder_id."
  }
}

check "external_dns_project" {
  assert {
    condition     = var.dns_project_id != var.project_id
    error_message = "dns_project_id must name the existing shared DNS project, not the new gateway project."
  }
}
