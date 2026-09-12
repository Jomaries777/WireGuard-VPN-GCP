variable "project_id" {
  description = "Your GCP project ID. The same one the root config uses."
  type        = string
}

variable "region" {
  description = "Region for the provider. Nothing here is regional, but the provider wants one."
  type        = string
  default     = "us-west1"
}

variable "name_prefix" {
  description = "Prefix applied to every resource name. Must match name_prefix in the root config."
  type        = string
  default     = "wg-us"
}

variable "allow_vm_to_seed_key" {
  description = <<-EOT
    Whether the VM may add the FIRST version of the hub key secret on its first boot.

    true  (default): zero manual steps, and the private key never touches your
                     laptop or any Terraform state file. Costs the VM one extra
                     permission on one secret.
    false:           the VM gets read-only access, and you seed the key yourself:
                       wg genkey | gcloud secrets versions add <prefix>-hub-key --data-file=-
  EOT
  type        = bool
  default     = true
}

variable "dns_domain" {
  description = <<-EOT
    A domain you own, with the trailing dot, e.g. "example.com." — used to create a
    Cloud DNS zone so clients can pin a hostname instead of an IP.

    Costs $0.20/month and requires delegating the domain to the nameservers this
    config outputs. Leave empty to skip DNS entirely; clients then need their
    Endpoint line updated after each apply.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.dns_domain == "" || endswith(var.dns_domain, ".")
    error_message = "dns_domain must be fully qualified, ending in a dot (e.g. \"example.com.\")."
  }
}
