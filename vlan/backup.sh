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

for item in homeassistant/config nodered/data zigbee2mqtt/data grafana/data \
    mosquitto/config uptime-kuma/data influxdb/data wireguard/config \
    adguard/conf portainer/data esphome/config certs nginx \
    .env docker-compose.yml; do
    if [ -e "$item" ]; then
        cp -r "$item" "$BACKUP_DIR/" 2>/dev/null || true
        log "  $item"
    fi
done

tar -czf "${BACKUP_DIR}.tar.gz" -C backups "$(basename "$BACKUP_DIR")"
rm -rf "$BACKUP_DIR"

log "Záloha: ${BACKUP_DIR}.tar.gz ($(du -h "${BACKUP_DIR}.tar.gz" | cut -f1))"
