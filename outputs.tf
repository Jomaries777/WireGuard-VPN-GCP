output "vpn_public_ip" {
  description = "The static external IP. This goes in the Endpoint line of every client config."
  value       = google_compute_address.vpn.address
}

output "ssh_command" {
  description = "Run this to get onto the VM and add peers."
  value       = "gcloud compute ssh ${google_compute_instance.vpn.name} --zone ${var.zone} --project ${var.project_id}"
}

output "endpoint" {
  description = "Paste this straight into your client's Endpoint field."
  value       = "${google_compute_address.vpn.address}:51820"
}
