output "project_ids" {
  description = "Project ID by environment."
  value       = { for environment, project in google_project.environment : environment => project.project_id }
}

output "project_numbers" {
  description = "Project number by environment (needed for Workload Identity Federation principals)."
  value       = { for environment, project in google_project.environment : environment => project.number }
}

output "regions" {
  description = "Deployment region by environment."
  value       = { for environment, _ in local.environments : environment => var.region }
}

output "zones" {
  description = "Bootstrap VM zone by environment."
  value       = { for environment, config in local.environments : environment => config.zone }
}

output "vm_names" {
  description = "Keyless bootstrap VM name by environment."
  value       = { for environment, vm in google_compute_instance.bootstrap : environment => vm.name }
}

output "vm_internal_ips" {
  description = "Private bootstrap VM address by environment. No public address is assigned."
  value = {
    for environment, vm in google_compute_instance.bootstrap :
    environment => vm.network_interface[0].network_ip
  }
}

output "bootstrap_service_accounts" {
  description = "Attached platform-applier service account by environment."
  value       = { for environment, sa in google_service_account.bootstrap : environment => sa.email }
}

output "platform_apply_roles" {
  description = "Reviewed project-level roles granted to each platform-applier service account."
  value       = sort(tolist(local.platform_apply_roles))
}

output "state_bucket_roles" {
  description = "Bucket-scoped roles granted to platform and operator principals."
  value       = sort(tolist(local.state_bucket_roles))
}

output "state_buckets" {
  description = "Versioned GCS Terraform-state bucket by environment."
  value       = { for environment, bucket in google_storage_bucket.terraform_state : environment => bucket.name }
}

output "recommended_backend_bucket" {
  description = "Sandbox bucket used for foundation state after the first approved sandbox apply."
  value       = google_storage_bucket.terraform_state["sandbox"].name
}

output "budget_names" {
  description = "Cloud Billing budget resource name by enabled environment."
  value       = { for environment, budget in google_billing_budget.environment : environment => budget.name }
}

output "iap_ssh_commands" {
  description = "Keyless IAP/OS Login command by environment."
  value = {
    for environment, vm in google_compute_instance.bootstrap :
    environment => "gcloud compute ssh ${vm.name} --project ${vm.project} --zone ${vm.zone} --tunnel-through-iap"
  }
}

output "keyless_assertions" {
  description = "Expected security properties for the bootstrap VMs."
  value = {
    public_ip_assigned       = false
    os_login_enabled         = true
    project_ssh_keys_blocked = true
    service_account_keys     = "none-created"
  }
}
