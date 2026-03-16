#!/bin/bash
# =============================================================
#  Spúšťa sa NA PROXMOX HOSTE
#  Vytvorí LXC kontajner s dvoma NIC (VLAN 10 + VLAN 20)
#  Single-NIC model: obe NIC idú cez vmbr0 s VLAN tagmi
# =============================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# === LOAD CONFIG ===
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

CT_ID="${CT_ID:-200}"
CT_NAME="${CT_NAME:-homelab}"
CT_DISK="${CT_DISK:-32}"
CT_RAM="${CT_RAM:-4096}"
CT_SWAP="${CT_SWAP:-512}"
CT_CORES="${CT_CORES:-4}"
CT_STORAGE="${CT_STORAGE:-local-lvm}"
CT_TEMPLATE="${CT_TEMPLATE:-local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst}"
CT_IP="${CT_IP:-10.10.10.100/24}"
CT_GW="${CT_GW:-10.10.10.1}"
CT_IOT_IP="${CT_IOT_IP:-10.10.20.1/24}"
VLAN_SERVERS_ID="${VLAN_SERVERS_ID:-10}"
VLAN_IOT_ID="${VLAN_IOT_ID:-20}"
ZIGBEE_USB="${ZIGBEE_USB:-}"

echo ""
echo "========================================="
echo "   Proxmox LXC Setup — VLAN variant"
echo "========================================="
echo ""
echo "  CT ID:       $CT_ID"
echo "  Meno:        $CT_NAME"
echo "  Disk:        ${CT_DISK}G"
echo "  RAM:         ${CT_RAM}MB"
echo "  CPU:         ${CT_CORES} jadrá"
echo ""
echo "  eth0 (VLAN $VLAN_SERVERS_ID): $CT_IP  gw=$CT_GW"
echo "  eth1 (VLAN $VLAN_IOT_ID):     $CT_IOT_IP  (IoT gateway)"
echo ""

# === CHECK ===
if ! command -v pct &> /dev/null; then
    err "Tento skript treba spustiť na Proxmox hoste (pct nenájdený)."
fi

if pct status "$CT_ID" &> /dev/null; then
    err "Kontajner $CT_ID už existuje."
fi

# === CHECK VLAN BRIDGE ===
if ! ip link show vmbr0 &> /dev/null; then
    err "Bridge vmbr0 neexistuje. Najprv nastav management bridge na Proxmoxe."
fi

# === DOWNLOAD TEMPLATE ===
if ! pveam list local | grep -q "debian-12-standard"; then
    log "Sťahujem Debian 12 template..."
    pveam download local debian-12-standard_12.7-1_amd64.tar.zst
fi

# === CREATE LXC ===
log "Vytváram LXC kontajner $CT_ID ..."

pct create "$CT_ID" "$CT_TEMPLATE" \
    --hostname "$CT_NAME" \
    --storage "$CT_STORAGE" \
    --rootfs "${CT_STORAGE}:${CT_DISK}" \
    --memory "$CT_RAM" \
    --swap "$CT_SWAP" \
    --cores "$CT_CORES" \
    --net0 "name=eth0,bridge=vmbr0,tag=${VLAN_SERVERS_ID},ip=${CT_IP},gw=${CT_GW}" \
    --net1 "name=eth1,bridge=vmbr0,tag=${VLAN_IOT_ID},ip=${CT_IOT_IP}" \
    --unprivileged 0 \
    --features "nesting=1,keyctl=1" \
    --onboot 1 \
    --start 0

log "LXC kontajner vytvorený."

# === LXC CONFIG ===
log "Konfigurujem LXC pre Docker + WireGuard..."

CT_CONF="/etc/pve/lxc/${CT_ID}.conf"

# /dev/net/tun pre WireGuard
echo "lxc.cgroup2.devices.allow: c 10:200 rwm" >> "$CT_CONF"
echo "lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file" >> "$CT_CONF"

# === USB PASSTHROUGH ===
if [ -n "$ZIGBEE_USB" ] && [ -e "$ZIGBEE_USB" ]; then
    echo "lxc.cgroup2.devices.allow: c 188:* rwm" >> "$CT_CONF"
    echo "lxc.mount.entry: ${ZIGBEE_USB} dev/ttyUSB0 none bind,optional,create=file" >> "$CT_CONF"
    log "USB passthrough: $ZIGBEE_USB → /dev/ttyUSB0"
else
    warn "Zigbee USB preskočený. Neskôr: proxmox/add-usb.sh $CT_ID /dev/ttyUSB0"
fi

# === START + BOOTSTRAP ===
log "Spúšťam kontajner..."
pct start "$CT_ID"
sleep 3

log "Kopírujem bootstrap skript..."
pct push "$CT_ID" "${SCRIPT_DIR}/bootstrap-lxc.sh" /root/bootstrap-lxc.sh
pct exec "$CT_ID" -- chmod +x /root/bootstrap-lxc.sh

echo ""
log "============================================"
log "  LXC $CT_ID pripravený!"
log "============================================"
echo ""
echo "  Sieťové rozhrania:"
echo "    eth0 (VLAN $VLAN_SERVERS_ID) cez vmbr0: $CT_IP    — servery"
echo "    eth1 (VLAN $VLAN_IOT_ID) cez vmbr0:    $CT_IOT_IP — IoT gateway"
echo ""
echo "  Ďalší krok:"
echo "    pct exec $CT_ID -- /root/bootstrap-lxc.sh"
echo ""
