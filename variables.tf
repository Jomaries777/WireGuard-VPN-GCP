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


# ----------------------------------------------------------------------------
# Optional: surviving a destroy/apply cycle (the Stage 8 exercise)
# ----------------------------------------------------------------------------
# Every variable below defaults to the original behaviour, so Stages 1-7 work
# exactly as written whether or not you have applied the bootstrap/ folder.
#
# Set them and the hub keeps its identity, its endpoint name and its peer list
# across a destroy — `terraform apply` then gives you a working tunnel with no
# SSH and no client edits. See docs/stage-8-persistent-identity.md.

variable "hub_key_secret_id" {
  description = <<-EOT
    Secret Manager secret holding the hub's WireGuard private key, from the
    bootstrap/ output of the same name.

    Empty (the default) means the VM generates a fresh key on every build, so
    every client config breaks after a destroy — the behaviour Stage 8 asks you
    to fix.
  EOT
  type        = string
  default     = ""
}

variable "vm_service_account_email" {
  description = <<-EOT
    Service account for the VM, from the bootstrap/ output of the same name.
    Required if hub_key_secret_id is set, since that account is what holds
    permission on the secret.

    Empty means the default compute service account, which in older projects
    carries Editor on the entire project. The bootstrap account is far narrower:
    two permissions on one secret.
  EOT
  type        = string
  default     = ""
}

variable "dns_zone_name" {
  description = "Cloud DNS managed zone from bootstrap/. Empty disables the A record below."
  type        = string
  default     = ""
}

variable "dns_hostname" {
  description = <<-EOT
    Fully qualified name for the endpoint, e.g. "vpn.example.com." — an A record
    pointing at today's IP is written on every apply, so clients pin this name
    and never need editing again.

    Holding the reserved IP through a destroy instead would cost about
    $7.30/month, more than never destroying the VM at all. A DNS zone is $0.20.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.dns_hostname == "" || endswith(var.dns_hostname, ".")
    error_message = "dns_hostname must be fully qualified, ending in a dot (e.g. \"vpn.example.com.\")."
  }
}

variable "peers" {
  description = <<-EOT
    Devices allowed on the tunnel, written into wg0.conf at boot so you never
    have to SSH in and run add-peer. Client PUBLIC keys are not secrets, so
    declaring them here costs nothing in money or exposure.

    Each device needs its own tunnel_ip inside the hub_address subnet:

      peers = {
        macbook = { public_key = "AbCd...=", tunnel_ip = "10.20.0.2" }
        phone   = { public_key = "EfGh...=", tunnel_ip = "10.20.0.3" }
      }

    These become the source of truth: a peer added by hand with add-peer on the
    VM will NOT survive the next apply.
  EOT
  type = map(object({
    public_key = string
    tunnel_ip  = string
  }))
  default = {}

  # A mistyped key produces a tunnel that comes up cleanly and never completes a
  # handshake, with nothing in any log to say why. Much better to fail at plan
  # time. A Curve25519 public key is always 32 bytes, so always 44 base64
  # characters ending in "=".
  validation {
    condition = alltrue([
      for name, p in var.peers : can(regex("^[A-Za-z0-9+/]{43}=$", p.public_key))
    ])
    error_message = "Each peer public_key must be a 44-character base64 WireGuard key ending in \"=\"."
  }

  validation {
    condition = alltrue([
      for name, p in var.peers : can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}$", p.tunnel_ip))
    ])
    error_message = "Each peer tunnel_ip must be a bare IPv4 address with no prefix length, e.g. \"10.20.0.2\"."
  }

  validation {
    condition     = length(distinct([for name, p in var.peers : p.tunnel_ip])) == length(var.peers)
    error_message = "Two peers share a tunnel_ip. Each device needs its own address."
  }
}
