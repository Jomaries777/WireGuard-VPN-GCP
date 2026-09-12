variable "project_id" {
  description = "Your GCP project ID. Not the project name or number."
  type        = string
}

variable "region" {
  description = "US region for the VPN endpoint. us-west1 (Oregon) is the closest US region to Manila."
  type        = string
  default     = "us-west1"
}

variable "zone" {
  description = "Zone within the region."
  type        = string
  default     = "us-west1-b"
}

variable "machine_type" {
  description = "VM size. e2-micro is plenty for WireGuard."
  type        = string
  default     = "e2-micro"
}

variable "name_prefix" {
  description = "Prefix applied to every resource name, so you can tell these apart from your other projects."
  type        = string
  default     = "wg-us"
}

variable "hub_address" {
  description = "The hub's address inside the tunnel, with prefix length. Keep this on a subnet unlikely to collide with any café or office Wi-Fi you sit on."
  type        = string
  default     = "10.20.0.1/24"
}

variable "ssh_source_ranges" {
  description = "Who may reach SSH. Defaults to the whole internet, which is convenient and sloppy. Narrow it to YOUR.IP.HERE/32 if your home IP is stable enough."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
