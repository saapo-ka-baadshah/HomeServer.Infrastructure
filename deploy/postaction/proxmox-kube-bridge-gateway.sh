#!/usr/bin/env bash
# ============================================================================
# Proxmox host: Kubernetes bridge internal gateway
# ============================================================================
# Makes the Proxmox host the internal IPv4 gateway for the dedicated K8s bridge
# (vmbr1, 10.200.0.0/24) so ALL cluster communication stays on the isolated
# subnet -- the home router (192.168.178.1) is never the nodes' default gateway.
#
#  1. vmbr1 host address  -> 10.200.0.1/24 (first usable IP of the mgmt subnet)
#  2. ip_forward          -> enabled (persistent via /etc/sysctl.d)
#  3. iptables NAT        -> MASQUERADE vmbr1 traffic egressing any other NIC
#                            + FORWARD accept (persistent via systemd oneshot)
#
# The bridge address is also managed by Terraform (root main.tf); this script
# covers the sysctl + iptables pieces and reconciles the address if Terraform
# has not applied yet. Idempotent -- safe to re-run.
#
# Usage (as root on the Proxmox host):
#   BRIDGE=vmbr1 MGMT_SUBNET=10.200.0.0/24 ./proxmox-kube-bridge-gateway.sh
# ============================================================================
set -euo pipefail

BRIDGE="${BRIDGE:-vmbr1}"
MGMT_SUBNET="${MGMT_SUBNET:-10.200.0.0/24}"
GATEWAY_IP="${GATEWAY_IP:-10.200.0.1}"
PREFIX="${MGMT_SUBNET##*/}"
GATEWAY_CIDR="${GATEWAY_IP}/${PREFIX}"
UNIT="kube-bridge-gateway.service"
SCRIPT="/usr/local/sbin/kube-bridge-gateway.sh"

if [ "$(id -u)" -ne 0 ]; then
  echo "error: run as root" >&2
  exit 1
fi

# --- 1) vmbr1 host address (reconcile with Terraform-managed interfaces file) --
if [ -f /etc/network/interfaces ] && grep -q "iface ${BRIDGE} inet static" /etc/network/interfaces; then
  python3 - "$BRIDGE" "$GATEWAY_CIDR" <<'PY'
import re, sys
bridge, cidr = sys.argv[1], sys.argv[2]
path = "/etc/network/interfaces"
text = open(path).read()
stanza = re.search(rf"^iface {bridge} inet static.*?(?=\n\n|^iface |\Z)", text, re.M | re.S)
if stanza and not re.search(rf"^\s*address\s+{re.escape(cidr)}\s*$", stanza.group(0), re.M):
    new = re.sub(rf"^(iface {bridge} inet static.*?)(?=\n\n|^iface |\Z)",
                 lambda m: re.sub(r"^\s*address\s+\S+", f"\taddress {cidr}", m.group(1), count=1, flags=re.M),
                 text, count=1, flags=re.M | re.S)
    open(path, "w").write(new)
    print(f"set {bridge} address -> {cidr}")
PY
fi

# Reconcile the live address now (never touch other bridges / vmbr0).
CURRENT="$(ip -4 -o addr show dev "$BRIDGE" 2>/dev/null | awk '{print $4}' | head -1)"
if [ -n "$CURRENT" ] && [ "$CURRENT" != "$GATEWAY_CIDR" ]; then
  ip -4 addr del "$CURRENT" dev "$BRIDGE"
  ip -4 addr add "$GATEWAY_CIDR" dev "$BRIDGE"
  echo "reconciled ${BRIDGE} live address -> ${GATEWAY_CIDR}"
elif [ -z "$CURRENT" ]; then
  ip -4 addr add "$GATEWAY_CIDR" dev "$BRIDGE"
else
  echo "${BRIDGE} already at ${GATEWAY_CIDR}"
fi

# --- 2) persistent IPv4 forwarding ---
printf '# Kubernetes bridge gateway (Proxmox host = internal default route for vmbr1)\nnet.ipv4.ip_forward=1\n' \
  > /etc/sysctl.d/90-kube-bridge-gateway.conf
sysctl -p /etc/sysctl.d/90-kube-bridge-gateway.conf >/dev/null

# --- 3) iptables NAT/forwarding, re-applied on every boot via systemd ---
cat > "$SCRIPT" <<SCRIPT
#!/usr/bin/env bash
set -euo pipefail
BRIDGE="${BRIDGE}"
MGMT_SUBNET="${MGMT_SUBNET}"
apply() {
  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
  iptables -t nat -C POSTROUTING -s "\$MGMT_SUBNET" ! -o "\$BRIDGE" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s "\$MGMT_SUBNET" ! -o "\$BRIDGE" -j MASQUERADE
  iptables -C FORWARD -i "\$BRIDGE" -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i "\$BRIDGE" -j ACCEPT
  iptables -C FORWARD -o "\$BRIDGE" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -o "\$BRIDGE" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
}
teardown() {
  iptables -t nat -D POSTROUTING -s "\$MGMT_SUBNET" ! -o "\$BRIDGE" -j MASQUERADE 2>/dev/null || true
  iptables -D FORWARD -i "\$BRIDGE" -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -o "\$BRIDGE" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
}
case "\${1:-apply}" in
  stop|teardown) teardown ;;
  *) apply ;;
esac
SCRIPT
chmod 0755 "$SCRIPT"

cat > "/etc/systemd/system/$UNIT" <<UNIT
[Unit]
Description=Kubernetes bridge gateway (NAT ${MGMT_SUBNET} from ${BRIDGE} to WAN)
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$SCRIPT apply
ExecStop=$SCRIPT teardown

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable "$UNIT" >/dev/null
systemctl restart "$UNIT"

echo "Proxmox host configured as internal gateway for ${MGMT_SUBNET} (${BRIDGE})"
ip -4 addr show "$BRIDGE"
iptables -t nat -S POSTROUTING | grep "$MGMT_SUBNET" || true