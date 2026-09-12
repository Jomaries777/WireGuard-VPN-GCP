#!/bin/bash
# Runs automatically on the VM's boot. You do not run this yourself.
#
# NOTE FOR ANYONE EDITING THIS FILE: Terraform reads it through templatefile(),
# which consumes dollar-brace sequences for its own substitutions. The four it
# fills in are hub_address, project_id, key_secret_id and peer_blocks.
#
# Every OTHER dollar-brace in this file has to be written with a doubled dollar
# sign — $${#candidate} below is the only one — or Terraform tries to resolve it
# and the plan fails with "unknown variable". Same for curl's percent-brace
# format strings, hence %%{http_code}. Bare $VAR and $(...) are untouched, which
# is why the rest of this script sticks to those.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y wireguard

# Let the VM forward packets between the tunnel and the internet.
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-wireguard.conf
sysctl --system

cd /etc/wireguard
umask 077

SECRET_ID="${key_secret_id}"
PROJECT_ID="${project_id}"
SECRET_API="https://secretmanager.googleapis.com/v1/projects/$PROJECT_ID/secrets/$SECRET_ID"

# Anything written here is visible in the serial console
# (gcloud compute instances get-serial-port-output), which is where to look when
# the tunnel comes up but nothing connects.
log() { echo "[wg-hub] $*"; }

# Ask the metadata server for an OAuth token for whichever service account this
# VM runs as. No credentials on disk, nothing to rotate.
get_token() {
  curl -sf -H 'Metadata-Flavor: Google' \
    http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])'
}

# A WireGuard private key is 32 bytes, so 44 base64 characters. Checking that
# `wg pubkey` accepts it catches a secret holding a stray newline, a passphrase,
# or somebody else's file — all of which otherwise produce a tunnel that starts
# cleanly and never completes a handshake.
key_is_valid() {
  local candidate="$1"
  [ $${#candidate} -eq 44 ] || return 1
  printf '%s\n' "$candidate" | wg pubkey > /dev/null 2>&1
}

# ----------------------------------------------------------------------------
# Establish the hub's private key
# ----------------------------------------------------------------------------
# Three deliberately distinct outcomes. The one to avoid is quietly generating a
# DIFFERENT key when one was supposed to be fetched: every client would fail with
# no indication why, so that case exits non-zero and leaves wg0 down instead.
if [ -z "$SECRET_ID" ]; then
  # No secret configured. Original behaviour: generate locally, guarded so a
  # reboot doesn't invalidate every client config. A destroy still loses the key
  # — that is the Stage 8 exercise, and bootstrap/ is the answer.
  if [ ! -f hub_private.key ]; then
    log "no secret configured, generating a local key pair"
    wg genkey | tee hub_private.key | wg pubkey > hub_public.key
  fi

else
  # `set -e` would abort here with no explanation, and "VM built, tunnel dead,
  # nothing in the log" is the worst outcome to debug.
  if ! TOKEN=$(get_token); then
    log "FATAL: no OAuth token from the metadata server."
    log "Does this VM have a service account attached at all?"
    exit 1
  fi

  BODY=$(mktemp)
  STATUS=$(curl -s -o "$BODY" -w '%%{http_code}' \
    -H "Authorization: Bearer $TOKEN" \
    "$SECRET_API/versions/latest:access")

  if [ "$STATUS" = "200" ]; then
    log "fetched hub key from secret $SECRET_ID"
    FETCHED=$(python3 -c '
import base64, json, sys
with open(sys.argv[1]) as fh:
    print(base64.b64decode(json.load(fh)["payload"]["data"]).decode().strip())
' "$BODY")

    if ! key_is_valid "$FETCHED"; then
      log "FATAL: secret $SECRET_ID does not contain a valid WireGuard private key."
      log "Refusing to start the tunnel under a different identity than your clients expect."
      log "Fix the secret, then reboot this VM or re-run terraform apply."
      rm -f "$BODY"
      exit 1
    fi
    printf '%s\n' "$FETCHED" > hub_private.key

  elif [ "$STATUS" = "404" ]; then
    # The secret exists but has no versions yet — the expected state on the very
    # first apply after bootstrap/. Generate the key here and publish it, so it
    # never passes through a laptop or a Terraform state file.
    log "secret $SECRET_ID is empty, generating and publishing version 1"
    wg genkey > hub_private.key

    PAYLOAD=$(python3 -c '
import base64, json, sys
with open(sys.argv[1], "rb") as fh:
    print(json.dumps({"payload": {"data": base64.b64encode(fh.read().strip()).decode()}}))
' hub_private.key)

    ADD_STATUS=$(curl -s -o /dev/null -w '%%{http_code}' -X POST \
      -H "Authorization: Bearer $TOKEN" \
      -H 'Content-Type: application/json' \
      -d "$PAYLOAD" \
      "$SECRET_API:addVersion")

    if [ "$ADD_STATUS" != "200" ]; then
      # Not fatal: the tunnel will work today. But the key is not saved, so the
      # next destroy loses it and clients break again. Usually a missing
      # secretVersionAdder role (allow_vm_to_seed_key = false in bootstrap/).
      log "WARNING: could not publish the key (HTTP $ADD_STATUS)."
      log "The tunnel will work now but this identity will NOT survive a destroy."
      log "Check the VM's roles on secret $SECRET_ID."
    fi

  else
    log "FATAL: reading secret $SECRET_ID failed with HTTP $STATUS."
    log "Usually the Secret Manager API is disabled, or this VM's service account"
    log "lacks roles/secretmanager.secretAccessor on that secret."
    cat "$BODY" || true
    rm -f "$BODY"
    exit 1
  fi

  rm -f "$BODY"
fi

# Derive the public key from whichever private key we ended up with.
wg pubkey < hub_private.key > hub_public.key

# Find the VM's internet-facing interface rather than assuming its name.
WAN_IF=$(ip route get 1.1.1.1 | awk '{print $5; exit}')

cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = ${hub_address}
ListenPort = 51820
PrivateKey = $(cat /etc/wireguard/hub_private.key)
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o $WAN_IF -j MASQUERADE; iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o $WAN_IF -j MASQUERADE; iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
EOF

# Peers declared in terraform.tfvars, if any. The quoted heredoc delimiter is
# load-bearing: it stops the shell expanding anything inside the rendered block.
cat >> /etc/wireguard/wg0.conf <<'WGPEERS'
${peer_blocks}
WGPEERS

chmod 600 /etc/wireguard/wg0.conf
systemctl enable --now wg-quick@wg0

# Helper so adding a phone or laptop is one command instead of hand-editing.
cat > /usr/local/bin/add-peer <<'PEEREOF'
#!/bin/bash
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "usage: sudo add-peer <client-public-key> <tunnel-ip>"
  echo "example: sudo add-peer AbCd...= 10.20.0.2"
  exit 1
fi

cat >> /etc/wireguard/wg0.conf <<PEER

[Peer]
PublicKey = $1
AllowedIPs = $2/32
PEER

systemctl restart wg-quick@wg0
echo "Peer added at $2."
echo ""
echo "NOTE: this peer lives only on this VM's disk. It will NOT survive a"
echo "destroy/apply cycle. To make it permanent, add it to the peers map in"
echo "terraform.tfvars instead."
echo ""
echo "Hub public key (put this in the client's [Peer] PublicKey field):"
cat /etc/wireguard/hub_public.key
PEEREOF

chmod +x /usr/local/bin/add-peer

# Convenience so you can read the hub key without hunting for it.
cat > /usr/local/bin/hub-key <<'KEYEOF'
#!/bin/bash
cat /etc/wireguard/hub_public.key
KEYEOF

chmod +x /usr/local/bin/hub-key

log "hub is up with public key $(cat /etc/wireguard/hub_public.key)"
