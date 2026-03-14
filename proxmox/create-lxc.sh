#!/bin/bash
# =============================================================
#  Spúšťa sa NA PROXMOX HOSTE (nie v LXC kontajneri)
#  Vytvorí LXC kontajner pripravený na Docker + Zigbee
# =============================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# === KONFIGURÁCIA ===
CT_ID="${CT_ID:-200}"
CT_NAME="${CT_NAME:-homelab}"
CT_DISK="${CT_DISK:-32}"
CT_RAM="${CT_RAM:-4096}"
CT_SWAP="${CT_SWAP:-512}"
CT_CORES="${CT_CORES:-4}"
CT_BRIDGE="${CT_BRIDGE:-vmbr0}"
CT_IP="${CT_IP:-192.168.1.100/24}"
CT_GW="${CT_GW:-192.168.1.1}"
CT_STORAGE="${CT_STORAGE:-local-lvm}"
CT_TEMPLATE="${CT_TEMPLATE:-local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst}"
ZIGBEE_USB="${ZIGBEE_USB:-}"

echo ""
echo "========================================="
echo "   Proxmox LXC Setup pre Home Lab"
echo "========================================="
echo ""
echo "  CT ID:      $CT_ID"
echo "  Meno:       $CT_NAME"
echo "  Disk:       ${CT_DISK}G"
echo "  RAM:        ${CT_RAM}MB"
echo "  CPU:        ${CT_CORES} jadrá"
echo "  IP:         $CT_IP"
echo "  Gateway:    $CT_GW"
echo ""

# === CHECK ===
if ! command -v pct &> /dev/null; then
    err "Tento skript treba spustiť na Proxmox hoste (pct nenájdený)."
fi

if pct status "$CT_ID" &> /dev/null; then
    err "Kontajner $CT_ID už existuje. Zvoľ iné CT_ID alebo zmaž existujúci."
fi

# === STIAHNI TEMPLATE ak neexistuje ===
if ! pveam list local | grep -q "debian-12-standard"; then
    log "Sťahujem Debian 12 template..."
    pveam download local debian-12-standard_12.7-1_amd64.tar.zst
fi

# === VYTVOR LXC ===
log "Vytváram LXC kontajner $CT_ID ($CT_NAME)..."

pct create "$CT_ID" "$CT_TEMPLATE" \
    --hostname "$CT_NAME" \
    --storage "$CT_STORAGE" \
    --rootfs "${CT_STORAGE}:${CT_DISK}" \
    --memory "$CT_RAM" \
    --swap "$CT_SWAP" \
    --cores "$CT_CORES" \
    --net0 "name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP},gw=${CT_GW}" \
    --unprivileged 0 \
    --features "nesting=1,keyctl=1" \
    --onboot 1 \
    --start 0

log "LXC kontajner vytvorený."

# === KONFIGURÁCIA PRE DOCKER ===
log "Konfigurujem LXC pre Docker..."

CT_CONF="/etc/pve/lxc/${CT_ID}.conf"

# Povoľ /dev/net/tun (WireGuard)
echo "lxc.cgroup2.devices.allow: c 10:200 rwm" >> "$CT_CONF"
echo "lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file" >> "$CT_CONF"

# === USB PASSTHROUGH (Zigbee dongle) ===
if [ -n "$ZIGBEE_USB" ]; then
    if [ -e "$ZIGBEE_USB" ]; then
        USB_MAJOR=$(stat -c '%t' "$ZIGBEE_USB" 2>/dev/null | xargs printf "%d" 2>/dev/null || echo "")
        USB_MINOR=$(stat -c '%T' "$ZIGBEE_USB" 2>/dev/null | xargs printf "%d" 2>/dev/null || echo "")

        if [ -n "$USB_MAJOR" ] && [ -n "$USB_MINOR" ]; then
            echo "lxc.cgroup2.devices.allow: c ${USB_MAJOR}:${USB_MINOR} rwm" >> "$CT_CONF"
            echo "lxc.mount.entry: ${ZIGBEE_USB} dev/ttyUSB0 none bind,optional,create=file" >> "$CT_CONF"
            log "USB passthrough nakonfigurovaný: $ZIGBEE_USB -> /dev/ttyUSB0"
        else
            warn "Nepodarilo sa zistiť major/minor pre $ZIGBEE_USB"
            warn "Pridávam generický USB serial prístup..."
            echo "lxc.cgroup2.devices.allow: c 188:* rwm" >> "$CT_CONF"
            echo "lxc.mount.entry: ${ZIGBEE_USB} dev/ttyUSB0 none bind,optional,create=file" >> "$CT_CONF"
        fi
    else
        warn "$ZIGBEE_USB neexistuje. USB passthrough preskočený."
        warn "Pripoj Zigbee dongle a spusti: proxmox/add-usb.sh $CT_ID $ZIGBEE_USB"
    fi
else
    warn "ZIGBEE_USB nie je nastavený. USB passthrough preskočený."
fi

log "LXC konfigurácia dokončená."

# === SPUSTI KONTAJNER ===
log "Spúšťam kontajner..."
pct start "$CT_ID"
sleep 3

# === SKOPÍRUJ BOOTSTRAP SKRIPT DO LXC ===
log "Kopírujem bootstrap skript do LXC..."
pct push "$CT_ID" "$(dirname "$0")/../proxmox/bootstrap-lxc.sh" /root/bootstrap-lxc.sh
pct exec "$CT_ID" -- chmod +x /root/bootstrap-lxc.sh

echo ""
log "============================================"
log "  LXC kontajner $CT_ID je pripravený!"
log "============================================"
echo ""
echo "  Ďalší krok — pripoj sa a spusti bootstrap:"
echo ""
echo "    pct enter $CT_ID"
echo "    ./bootstrap-lxc.sh"
echo ""
echo "  Alebo vzdialene:"
echo ""
echo "    pct exec $CT_ID -- /root/bootstrap-lxc.sh"
echo ""
