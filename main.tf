# ============================================================================
# US VPN endpoint — what this file builds in GCP
# ============================================================================
#
#   1. google_compute_address   -> a reserved static external IP
#   2. google_compute_firewall  -> a rule allowing WireGuard traffic (UDP 51820)
#   3. google_compute_firewall  -> a rule allowing SSH (TCP 22)
#   4. google_compute_instance  -> the VM itself, running Ubuntu + WireGuard
#
# ...plus one optional fifth, a DNS A record, if you have applied the bootstrap/
# folder with a domain. Everything optional defaults to off, so this file builds
# exactly the four resources above until you opt in.
#
# Terraform works out the order by itself. It sees that the VM block references
# the address block, so it creates the address first. You never write the order
# down — you write the relationships, and it derives the order. That is the
# core idea behind declarative infrastructure.
#
# Run `terraform destroy` to remove all of it. Nothing else is left behind —
# which is also the problem the bootstrap/ folder exists to solve, since "all of
# it" includes the hub's identity. See docs/stage-8-persistent-identity.md.
# ============================================================================


# ----------------------------------------------------------------------------
# Terraform settings
# ----------------------------------------------------------------------------
# Pins the versions of Terraform and the GCP provider. Without pinning, a
# provider update months from now could change behaviour under you and you'd
# have no idea why something that worked stopped working.
terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0" # any 6.x, but not 7.x
    }
  }
}


# ----------------------------------------------------------------------------
# Provider: tells Terraform which cloud, which project, and where by default
# ----------------------------------------------------------------------------
# Credentials are NOT set here. The provider picks them up from the Application
# Default Credentials you created with `gcloud auth application-default login`.
# Keeping credentials out of code is deliberate — it means this file is safe to
# share or commit.
provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}


# ----------------------------------------------------------------------------
# RESOURCE 1 of 4 — Static external IP address
# ----------------------------------------------------------------------------
# Creates: a reserved regional external IP in GCP (VPC network -> IP addresses).
#
# Why reserve one instead of taking the free ephemeral IP: an ephemeral IP is
# released whenever the VM stops, and you get a different one on restart. Every
# client config has that IP in its Endpoint line, so they would all silently
# break. Reserving it costs a small amount per month while attached.
#
# Cost note: GCP charges MORE for a reserved IP that is sitting unused than one
# attached to a running VM. `terraform destroy` releases it, which is another
# reason to tear the stack down rather than just stopping the VM.
resource "google_compute_address" "vpn" {
  name   = "${var.name_prefix}-ip"
  region = var.region
}


# ----------------------------------------------------------------------------
# RESOURCE 2 of 4 — Firewall rule: allow WireGuard
# ----------------------------------------------------------------------------
# Creates: an ingress rule on the default VPC network (VPC network -> Firewall).
#
# GCP's default network blocks essentially all inbound traffic, so without this
# rule your clients' packets reach the VM's network and get dropped before the
# VM ever sees them. The symptom is a tunnel that never completes a handshake.
#
# Opening UDP 51820 to the entire internet is safe here, and the reason is worth
# understanding: WireGuard silently discards any packet it cannot
# cryptographically authenticate. It never replies, never sends an error, never
# identifies itself. To a port scanner the VM looks like it has nothing running.
#
# target_tags is how this rule finds the VM — it applies only to instances
# carrying the "wireguard" tag, not to everything in the project.
resource "google_compute_firewall" "wireguard" {
  name    = "${var.name_prefix}-allow-wireguard"
  network = "default"

  allow {
    protocol = "udp"
    ports    = ["51820"]
  }

  source_ranges = ["0.0.0.0/0"] # the whole internet
  target_tags   = ["wireguard"] # matches the tag on the instance below
}


# ----------------------------------------------------------------------------
# RESOURCE 3 of 4 — Firewall rule: allow SSH
# ----------------------------------------------------------------------------
# Creates: a second ingress rule, for administration access.
#
# You need this to run `add-peer` on the VM. Unlike WireGuard, SSH announces
# itself to anyone who connects — it returns a banner with its version number,
# which is exactly what automated scanners look for. Every public SSH port on
# the internet receives constant login attempts.
#
# So narrow source_ranges to your own IP if your home address is stable enough.
# See ssh_source_ranges in variables.tf. The default is the whole internet,
# which is convenient and sloppy.
resource "google_compute_firewall" "ssh" {
  name    = "${var.name_prefix}-allow-ssh"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = var.ssh_source_ranges
  target_tags   = ["wireguard"]
}


# ----------------------------------------------------------------------------
# RESOURCE 4 of 4 — The VM
# ----------------------------------------------------------------------------
# Creates: a Compute Engine instance (Compute Engine -> VM instances).
#
# This is the only resource here that costs meaningful money — both for the
# machine running and, far more significantly, for data leaving it. Egress is
# roughly $0.12/GB, so video streaming is what drives the bill, not uptime.
resource "google_compute_instance" "vpn" {
  name         = "${var.name_prefix}-vm"
  machine_type = var.machine_type
  zone         = var.zone

  # This tag is what the two firewall rules above attach themselves to. Remove
  # it and the VM becomes unreachable — a genuinely confusing failure, because
  # everything still looks correctly configured.
  tags = ["wireguard"]

  # The disk the VM boots from. Created with the VM, deleted with the VM.
  # pd-standard is the cheapest option and more than fast enough for this.
  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
      size  = 10 # GB — the minimum practical size
      type  = "pd-standard"
    }
  }

  # Attaches the VM to the default VPC network and gives it the reserved IP.
  #
  # The access_config block is what makes the VM reachable from the internet at
  # all. Omit it entirely and the VM has only an internal address — useful for
  # private workloads, useless for a VPN endpoint.
  #
  # Referencing google_compute_address.vpn.address here is also what tells
  # Terraform to create the address first.
  network_interface {
    network = "default"

    access_config {
      nat_ip = google_compute_address.vpn.address
    }
  }

  # Runs on the VM's boot, as root. Installs WireGuard, establishes the hub's key
  # pair, enables IP forwarding and NAT, starts the tunnel, and installs the
  # `add-peer` helper.
  #
  # templatefile() reads startup-script.sh and substitutes these values into it
  # before upload, so each is defined in exactly one place.
  #
  # Note this runs AFTER `terraform apply` reports success — apply finishes when
  # the VM exists, not when the software inside it is ready. Give it two minutes.
  metadata_startup_script = templatefile("${path.module}/startup-script.sh", {
    hub_address   = var.hub_address
    project_id    = var.project_id
    key_secret_id = var.hub_key_secret_id
    peer_blocks   = local.peer_blocks
  })

  # The identity the VM uses when calling Google APIs.
  #
  # Leaving email unset falls back to the DEFAULT compute service account, which
  # in older projects holds Editor on the whole project. Pointing this at the
  # account from bootstrap/ instead gives the VM two permissions on one secret
  # and nothing else — a narrower blast radius than the original config, not a
  # wider one.
  #
  # Scope and permission are different things: cloud-platform scope means "don't
  # filter this account's API access", and grants nothing on its own. The IAM
  # bindings in bootstrap/ are what actually allow anything.
  service_account {
    email  = var.vm_service_account_email != "" ? var.vm_service_account_email : null
    scopes = ["cloud-platform"]
  }

  lifecycle {
    # Fetching the key needs an identity that holds permission on the secret, and
    # the default compute service account does not. Without this check the VM
    # builds fine and the tunnel silently comes up under a fresh key — a failure
    # that looks like a WireGuard problem and isn't.
    precondition {
      condition     = var.hub_key_secret_id == "" || var.vm_service_account_email != ""
      error_message = "hub_key_secret_id needs vm_service_account_email set too. Both come from `terraform output` in bootstrap/."
    }

    # A peer given the hub's own tunnel address produces a routing loop rather
    # than an error message.
    precondition {
      condition     = !contains([for name, p in var.peers : p.tunnel_ip], local.hub_tunnel_ip)
      error_message = "A peer is using ${local.hub_tunnel_ip}, which is the hub's own tunnel address. Give each device a different one."
    }
  }
}


# ============================================================================
# Stage 9 additions — only active once you have applied the bootstrap/ folder
# ============================================================================
# Everything below defaults to off, so the four resources above are still the
# whole story until you opt in. Kept at the end of the file so the numbered walk
# through 1-to-4 reads as it always did.
#
# Why any of this exists: `terraform destroy` takes the hub's identity with it,
# so every client config breaks on the next apply. The reasoning, and the prices
# that decide between the approaches, are in
# docs/stage-8-persistent-identity.md.
# ============================================================================


# ----------------------------------------------------------------------------
# Peer stanzas, rendered here rather than looped over in bash
# ----------------------------------------------------------------------------
# var.peers becomes a block of wg0.conf text. Doing this in HCL keeps the
# startup script readable — the alternative is a bash loop building config with
# string concatenation, which is where quoting bugs live.
locals {
  peer_blocks = join("", [
    for name, p in var.peers : <<-EOT

      # ${name}
      [Peer]
      PublicKey = ${p.public_key}
      AllowedIPs = ${p.tunnel_ip}/32
    EOT
  ])

  # The hub's own tunnel address without the prefix length, so we can check no
  # peer has been given the same address.
  hub_tunnel_ip = split("/", var.hub_address)[0]
}


# ----------------------------------------------------------------------------
# Optional — DNS A record, so clients pin a NAME instead of an address
# ----------------------------------------------------------------------------
# Created only when you have applied the bootstrap/ folder with a domain set.
#
# The reserved IP above is released by `terraform destroy` and you get a
# different one next time, so every client's Endpoint line breaks even if the
# hub's key survives. Holding the IP through the destroy would fix that and cost
# about $7.30/month, since an unattached external IPv4 bills at roughly twice
# the in-use rate — more than simply never destroying the VM. A DNS zone is
# $0.20/month, so the cheap fix is to let the address churn and keep the name.
#
# TTL is deliberately 60. WireGuard resolves Endpoint when the tunnel is
# activated, not continuously, so after an apply you deactivate and reactivate
# the tunnel. A long TTL turns that into a confusing few minutes of failed
# handshakes.
resource "google_dns_record_set" "vpn" {
  count = (var.dns_zone_name == "" || var.dns_hostname == "") ? 0 : 1

  name         = var.dns_hostname
  managed_zone = var.dns_zone_name
  type         = "A"
  ttl          = 60
  rrdatas      = [google_compute_address.vpn.address]
}
