#!/bin/bash
set -euo pipefail

GREEN='\033[0;32m'
NC='\033[0m'
log() { echo -e "${GREEN}[✓]${NC} $1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

BACKUP_DIR="backups/$(date +%Y-%m-%d_%H-%M-%S)"
mkdir -p "$BACKUP_DIR"

log "Zálohujem do $BACKUP_DIR ..."

# Zálohuj konfigurácie a dáta
dirs_to_backup=(
    homeassistant/config
    nodered/data
    zigbee2mqtt/data
    grafana/data
    mosquitto/config
    uptime-kuma/data
    influxdb/data
    wireguard/config
    certs
    nginx
    .env
    docker-compose.yml
)

for item in "${dirs_to_backup[@]}"; do
    if [ -e "$item" ]; then
        cp -r "$item" "$BACKUP_DIR/" 2>/dev/null || true
        log "  $item"
    fi
done

# Komprimuj
tar -czf "${BACKUP_DIR}.tar.gz" -C backups "$(basename "$BACKUP_DIR")"
rm -rf "$BACKUP_DIR"

log "Záloha vytvorená: ${BACKUP_DIR}.tar.gz"
log "Veľkosť: $(du -h "${BACKUP_DIR}.tar.gz" | cut -f1)"
