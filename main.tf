# ============================================================================
# US VPN endpoint — what this file builds in GCP
# ============================================================================
#
#   1. google_compute_address   -> a reserved static external IP
#   2. google_compute_firewall  -> a rule allowing WireGuard traffic (UDP 51820)
#   3. google_compute_firewall  -> a rule allowing SSH (TCP 22)
#   4. google_compute_instance  -> the VM itself, running Ubuntu + WireGuard
#
# Terraform works out the order by itself. It sees that the VM block references
# the address block, so it creates the address first. You never write the order
# down — you write the relationships, and it derives the order. That is the
# core idea behind declarative infrastructure.
#
# Run `terraform destroy` to remove all four. Nothing else is left behind.
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

  # Runs once on the VM's first boot, as root. Installs WireGuard, generates the
  # hub's key pair, enables IP forwarding and NAT, starts the tunnel, and
  # installs the `add-peer` helper.
  #
  # templatefile() reads startup-script.sh and substitutes ${hub_address} into
  # it before upload, so the tunnel address is defined in one place.
  #
  # Note this runs AFTER `terraform apply` reports success — apply finishes when
  # the VM exists, not when the software inside it is ready. Give it two minutes.
  metadata_startup_script = templatefile("${path.module}/startup-script.sh", {
    hub_address = var.hub_address
  })

  # The identity the VM itself uses when calling Google APIs. Not needed for the
  # VPN to work, but required if you later extend the startup script to fetch a
  # key from Secret Manager (the Stage 8 exercise).
  service_account {
    scopes = ["cloud-platform"]
  }
}
