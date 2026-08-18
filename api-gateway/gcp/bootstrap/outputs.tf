output "project_id" {
  description = "Production project ID."
  value       = google_project.environment.project_id
}

output "project_number" {
  description = "Production project number."
  value       = google_project.environment.number
}

output "region" {
  description = "Deployment region."
  value       = var.region
}

output "zone" {
  description = "Bootstrap VM zone."
  value       = var.bootstrap_zone
}

output "vm_name" {
  description = "Keyless bootstrap VM name."
  value       = google_compute_instance.bootstrap.name
}

output "vm_internal_ip" {
  description = "Private bootstrap VM address. No public address is assigned."
  value       = google_compute_instance.bootstrap.network_interface[0].network_ip
}

output "bootstrap_service_account" {
  description = "Attached platform-applier service account."
  value       = google_service_account.bootstrap.email
}

output "dns_project_id" {
  description = "Existing project containing the approved public Cloud DNS zone."
  value       = var.dns_project_id
}

output "platform_apply_roles" {
  description = "Reviewed project-level roles granted to the platform-applier service account."
  value       = sort(tolist(local.platform_apply_roles))
}

output "state_bucket_roles" {
  description = "Bucket-scoped roles granted to platform and operator principals."
  value       = sort(tolist(local.state_bucket_roles))
}

output "state_bucket" {
  description = "Versioned GCS Terraform-state bucket."
  value       = google_storage_bucket.terraform_state.name
}

output "recommended_backend_bucket" {
  description = "Production bucket used for foundation state after the first approved apply."
  value       = google_storage_bucket.terraform_state.name
}

output "budget_name" {
  description = "Cloud Billing budget resource name."
  value       = google_billing_budget.environment.name
}

output "iap_ssh_command" {
  description = "Keyless IAP/OS Login command."
  value       = "gcloud compute ssh ${google_compute_instance.bootstrap.name} --project ${google_compute_instance.bootstrap.project} --zone ${google_compute_instance.bootstrap.zone} --tunnel-through-iap"
}

output "keyless_assertions" {
  description = "Expected security properties for the bootstrap VM."
  value = {
    public_ip_assigned       = false
    os_login_enabled         = true
    project_ssh_keys_blocked = true
    service_account_keys     = "none-created"
  }
}
