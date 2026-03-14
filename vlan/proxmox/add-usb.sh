#!/bin/bash
# Pridá USB zariadenie do bežiaceho LXC kontajnera
# Použitie: ./add-usb.sh <CT_ID> [USB_DEVICE]
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
    exit 1
fi

[ ! -e "$USB_DEV" ] && err "$USB_DEV neexistuje."

CT_CONF="/etc/pve/lxc/${CT_ID}.conf"
[ ! -f "$CT_CONF" ] && err "$CT_CONF neexistuje."

if grep -q "dev/ttyUSB0" "$CT_CONF"; then
    log "USB passthrough už je v konfigurácii."
else
    echo "lxc.cgroup2.devices.allow: c 188:* rwm" >> "$CT_CONF"
    echo "lxc.mount.entry: ${USB_DEV} dev/ttyUSB0 none bind,optional,create=file" >> "$CT_CONF"
    log "USB passthrough pridaný."
fi

log "Reštartujem kontajner $CT_ID..."
pct reboot "$CT_ID"
sleep 5

if pct exec "$CT_ID" -- test -e /dev/ttyUSB0; then
    log "USB viditeľné v LXC."
else
    err "USB nie je viditeľné."
fi
