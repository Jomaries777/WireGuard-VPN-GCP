# ============================================================================
# bootstrap — the things that must OUTLIVE `terraform destroy`
# ============================================================================
#
# Apply this once. Then leave it alone.
#
# The root config in the parent folder is disposable: you destroy and re-apply
# it whenever you want the VPN, and everything in it is rebuilt from scratch.
# That is the whole point of the project. But it means anything the root config
# owns is gone after a destroy — including the hub's WireGuard identity, which
# every client config has pinned.
#
# The fix is not a lifecycle rule. `prevent_destroy = true` does NOT exclude a
# resource from `terraform destroy` — it makes the entire destroy FAIL, leaving
# you with a half-torn-down stack and a billing surprise. The fix is to put
# long-lived things in a SEPARATE STATE, which is what this folder is.
#
#   A resource's lifecycle, not its type, decides which state it belongs in.
#
# What lives here:
#
#   1. google_project_service              -> the Secret Manager API, enabled
#   2. google_secret_manager_secret        -> an empty box for the hub's key
#   3. google_service_account              -> an identity for the VM
#   4. google_secret_manager_secret_iam_*  -> that identity, allowed to use that box
#   5. google_dns_managed_zone (optional)  -> a stable hostname for clients
#
# Standing cost: $0.20/month for the DNS zone, $0.00 for everything else.
# Secret Manager's free tier covers 6 active secret versions and 10,000 access
# operations a month; we use one of each.
#
# See ../docs/stage-8-persistent-identity.md for the reasoning and the numbers.
# ============================================================================


terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}


# ----------------------------------------------------------------------------
# 1 of 5 — Enable the Secret Manager API
# ----------------------------------------------------------------------------
# Enabling an API is itself a project-level change, and it belongs here rather
# than in the disposable stack for a specific reason: disabling an API is
# disruptive and slow, so you do not want it toggling on every destroy cycle.
#
# disable_on_destroy = false means that even if you tear THIS folder down, the
# API stays enabled. Terraform stops tracking it; nothing breaks.
resource "google_project_service" "secretmanager" {
  service            = "secretmanager.googleapis.com"
  disable_on_destroy = false
}


# ----------------------------------------------------------------------------
# 2 of 5 — A box for the hub's private key (note: no version in here)
# ----------------------------------------------------------------------------
# This creates the secret CONTAINER only. It is deliberately empty.
#
# If Terraform created the first version too, the private key would be written
# into this folder's terraform.tfstate in plain text — the exact mistake the
# README warns about in Stage 4. Instead the VM generates the key on its first
# boot and adds version 1 itself (see ../startup-script.sh), so the key never
# touches your laptop, your shell history, or any state file.
#
# If you would rather generate it yourself and keep the VM read-only, run:
#
#   brew install wireguard-tools
#   wg genkey | gcloud secrets versions add ${var.name_prefix}-hub-key --data-file=-
#
# ...and then delete the secretVersionAdder binding below.
resource "google_secret_manager_secret" "hub_key" {
  secret_id = "${var.name_prefix}-hub-key"

  # "automatic" lets Google pick the replication policy. The alternative is
  # pinning it to specific regions, which matters for data residency rules and
  # not at all for a personal VPN.
  replication {
    auto {}
  }

  depends_on = [google_project_service.secretmanager]
}


# ----------------------------------------------------------------------------
# 3 of 5 — A dedicated identity for the VM
# ----------------------------------------------------------------------------
# Today the VM in the root config runs as the DEFAULT compute service account
# with cloud-platform scope. In older projects that account holds Editor on the
# whole project, which means a compromised VPN box could rewrite your
# infrastructure. Scope is not permission: cloud-platform scope says "don't
# filter this account's API access", it does not grant anything by itself.
#
# So this is a strict security improvement, not just plumbing. The VM ends up
# with exactly two permissions on exactly one secret, and nothing else.
#
# It lives in bootstrap rather than the disposable stack because a service
# account deleted and recreated on every cycle runs into GCP's soft-delete
# window and IAM propagation delays, for no benefit. Identity is long-lived;
# compute is disposable.
resource "google_service_account" "vpn_vm" {
  account_id   = "${var.name_prefix}-vm"
  display_name = "WireGuard hub VM"
  description  = "Reads (and on first boot writes) the hub's WireGuard private key."
}


# ----------------------------------------------------------------------------
# 4 of 5 — Let that identity use that one secret
# ----------------------------------------------------------------------------
# Both bindings are on the SECRET, not on the project. A project-level grant
# would let the VM read every secret you ever create in this project; this lets
# it read one.
resource "google_secret_manager_secret_iam_member" "accessor" {
  secret_id = google_secret_manager_secret.hub_key.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.vpn_vm.email}"
}

# This is the one genuinely debatable grant in the whole design. It lets the VM
# ADD a secret version, which is how the first boot seeds the key without the
# key passing through your machine. The trade: a compromised VM could push new
# versions. Scoped to one secret, and the alternative is worse — see the
# generate-it-yourself note on the secret above.
resource "google_secret_manager_secret_iam_member" "version_adder" {
  count = var.allow_vm_to_seed_key ? 1 : 0

  secret_id = google_secret_manager_secret.hub_key.secret_id
  role      = "roles/secretmanager.secretVersionAdder"
  member    = "serviceAccount:${google_service_account.vpn_vm.email}"
}


# ----------------------------------------------------------------------------
# 5 of 5 — Optional: a DNS zone, so clients pin a NAME not an address
# ----------------------------------------------------------------------------
# A stable hub key still leaves the Endpoint line changing every cycle, because
# `terraform destroy` releases the reserved IP. The obvious fix — hold the IP
# through the destroy — is the most expensive option available: an unattached
# external IPv4 bills at roughly twice the in-use rate, about $7.30/month,
# which is MORE than never destroying the VM at all.
#
# So pin a hostname instead. $0.20/month for the zone, and the A record lives
# in the disposable stack where it is rewritten on every apply.
#
# This needs a domain you own and can delegate. After applying, point your
# registrar's nameservers at the values in the `dns_name_servers` output.
# No domain? Leave dns_domain empty and read the IP from `terraform output`.
resource "google_dns_managed_zone" "vpn" {
  count = var.dns_domain == "" ? 0 : 1

  name        = "${var.name_prefix}-zone"
  dns_name    = var.dns_domain
  description = "Stable endpoint names for the WireGuard hub"
}
