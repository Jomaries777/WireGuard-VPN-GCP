# These outputs are the handoff to the root config. Copy them into the root
# terraform.tfvars — `root_tfvars` prints the block ready to paste.
#
# Passing them as plain variables rather than reading this folder's state with a
# terraform_remote_state data source is deliberate: it keeps the disposable
# stack from depending on a state file the README tells you to treat as secret,
# and it makes the coupling between the two stacks something you can see.

output "hub_key_secret_id" {
  description = "Secret holding the hub's WireGuard private key."
  value       = google_secret_manager_secret.hub_key.secret_id
}

output "vm_service_account_email" {
  description = "Service account the VM should run as."
  value       = google_service_account.vpn_vm.email
}

output "dns_zone_name" {
  description = "Cloud DNS managed zone name, or empty if DNS is off."
  value       = var.dns_domain == "" ? "" : google_dns_managed_zone.vpn[0].name
}

output "dns_name_servers" {
  description = "Point your registrar's nameservers at these, or the hostname will never resolve."
  value       = var.dns_domain == "" ? [] : google_dns_managed_zone.vpn[0].name_servers
}

output "root_tfvars" {
  description = "Paste this into ../terraform.tfvars."
  value       = <<-EOT

    hub_key_secret_id        = "${google_secret_manager_secret.hub_key.secret_id}"
    vm_service_account_email = "${google_service_account.vpn_vm.email}"
    dns_zone_name            = "${var.dns_domain == "" ? "" : google_dns_managed_zone.vpn[0].name}"
    dns_hostname             = "${var.dns_domain == "" ? "" : "vpn.${var.dns_domain}"}"
  EOT
}
