#!/bin/bash
# Runs automatically on the VM's first boot. You do not run this yourself.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y wireguard

# Let the VM forward packets between the tunnel and the internet.
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-wireguard.conf
sysctl --system

cd /etc/wireguard
umask 077

# Generate the hub's key pair, but only if it doesn't already exist, so a
# reboot never invalidates every client config.
if [ ! -f hub_private.key ]; then
  wg genkey | tee hub_private.key | wg pubkey > hub_public.key
fi

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
