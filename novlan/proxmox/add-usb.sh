#!/bin/bash
# =============================================================
#  Pridá USB zariadenie do bežiaceho LXC kontajnera
#  Spúšťa sa NA PROXMOX HOSTE
#  Použitie: ./add-usb.sh <CT_ID> <USB_DEVICE>
#  Príklad:  ./add-usb.sh 200 /dev/ttyUSB0
# =============================================================
set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
log() { echo -e "${GREEN}[✓]${NC} $1"; }
err() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

CT_ID="${1:-}"
USB_DEV="${2:-/dev/ttyUSB0}"

if [ -z "$CT_ID" ]; then
    echo "Použitie: $0 <CT_ID> [USB_DEVICE]"
    echo "Príklad:  $0 200 /dev/ttyUSB0"
    exit 1
fi

if [ ! -e "$USB_DEV" ]; then
    err "Zariadenie $USB_DEV neexistuje. Pripoj Zigbee dongle."
fi

CT_CONF="/etc/pve/lxc/${CT_ID}.conf"
if [ ! -f "$CT_CONF" ]; then
    err "LXC konfigurácia $CT_CONF neexistuje."
fi

# Zisti major:minor
USB_MAJOR=$(stat -c '%t' "$USB_DEV" | xargs printf "%d")
USB_MINOR=$(stat -c '%T' "$USB_DEV" | xargs printf "%d")

log "Zariadenie: $USB_DEV (major=$USB_MAJOR, minor=$USB_MINOR)"

# Pridaj do konfigurácie ak ešte nie je
if grep -q "dev/ttyUSB0" "$CT_CONF"; then
    log "USB passthrough už je v konfigurácii."
else
    echo "lxc.cgroup2.devices.allow: c ${USB_MAJOR}:${USB_MINOR} rwm" >> "$CT_CONF"
    echo "lxc.mount.entry: ${USB_DEV} dev/ttyUSB0 none bind,optional,create=file" >> "$CT_CONF"
    log "USB passthrough pridaný do $CT_CONF"
fi

# Reštartuj kontajner
log "Reštartujem kontajner $CT_ID..."
pct reboot "$CT_ID"
sleep 5

# Overenie
if pct exec "$CT_ID" -- test -e /dev/ttyUSB0; then
    log "USB zariadenie je viditeľné v LXC kontajneri."
else
    err "USB zariadenie nie je viditeľné v LXC. Skontroluj konfiguráciu."
fi
