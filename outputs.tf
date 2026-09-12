output "vpn_public_ip" {
  description = "The static external IP. Changes on every destroy/apply, which is why the endpoint below prefers a hostname."
  value       = google_compute_address.vpn.address
}

output "ssh_command" {
  description = "Run this to get onto the VM and add peers."
  value       = "gcloud compute ssh ${google_compute_instance.vpn.name} --zone ${var.zone} --project ${var.project_id}"
}

# Prefers the DNS name when you have one, so a client config written once keeps
# working across destroy/apply cycles. Falls back to the raw address otherwise,
# which is what Stages 1-7 expect.
output "endpoint" {
  description = "Paste this straight into your client's Endpoint field."
  value = var.dns_hostname == "" ? "${google_compute_address.vpn.address}:51820" : format(
    "%s:51820", trimsuffix(var.dns_hostname, ".")
  )
}

output "hub_public_key_command" {
  description = "Reads the hub's public key off the VM. Should print the same value before and after a destroy once bootstrap/ is in use."
  value       = "gcloud compute ssh ${google_compute_instance.vpn.name} --zone ${var.zone} --project ${var.project_id} --command 'sudo hub-key'"
}

output "identity_survives_destroy" {
  description = "Whether the hub's key and endpoint name are held outside this stack's state."
  value = (
    var.hub_key_secret_id == ""
    ? "No — the hub generates a new key on every apply, so every client config breaks. See docs/stage-8-persistent-identity.md."
    : var.dns_hostname == ""
    ? "Key yes, endpoint no — the key is held in Secret Manager, but the IP still changes so clients need their Endpoint line updated."
    : "Yes — key in Secret Manager, endpoint pinned to a DNS name. Apply, wait two minutes, reactivate the tunnel."
  )
}
