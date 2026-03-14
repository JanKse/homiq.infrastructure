#!/bin/bash
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }

cd "$(dirname "${BASH_SOURCE[0]}")"

echo ""
read -p "Zastaviť všetky kontajnery? [y/N] " -n 1 -r
echo ""
[[ ! $REPLY =~ ^[Yy]$ ]] && exit 0

log "Zastavujem..."
docker compose down

read -p "Zmazať aj volumes/dáta? [y/N] " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    warn "Mazanie volumes..."
    docker compose down -v
fi

log "Hotovo."
