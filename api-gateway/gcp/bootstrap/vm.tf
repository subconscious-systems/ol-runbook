data "google_compute_image" "ubuntu" {
  project = "ubuntu-os-cloud"
  family  = "ubuntu-2404-lts-amd64"
}

resource "google_compute_instance" "bootstrap" {
  for_each = local.environments

  project                   = google_project.environment[each.key].project_id
  name                      = "gateway-${each.key}-bootstrap"
  zone                      = each.value.zone
  machine_type              = var.bootstrap_machine_type
  can_ip_forward            = false
  allow_stopping_for_update = true
  deletion_protection       = var.protect_bootstrap_vms

  boot_disk {
    auto_delete = true

    initialize_params {
      image = data.google_compute_image.ubuntu.self_link
      size  = var.bootstrap_disk_size_gb
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.bootstrap[each.key].id
    # Intentionally no access_config: this VM has no public IP.
  }

  service_account {
    email  = google_service_account.bootstrap[each.key].email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  metadata = {
    block-project-ssh-keys = "TRUE"
    enable-oslogin         = "TRUE"
    serial-port-enable     = "FALSE"
    user-data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
      host_setup_b64 = filebase64("${path.module}/scripts/host-setup.sh")
    })
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  labels = merge(var.labels, {
    environment = each.key
    component   = "distr-bootstrap"
  })

  depends_on = [
    google_compute_router_nat.bootstrap,
    google_project_iam_member.platform_apply,
    google_project_iam_member.operator_project_access,
    google_service_account_iam_member.operator_act_as,
  ]
}
