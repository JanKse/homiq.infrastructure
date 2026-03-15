#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo ""
echo "========================================="
echo "   Home Lab Teardown"
echo "========================================="
echo ""

echo "Toto zastaví všetky kontajnery."
read -p "Chceš pokračovať? [y/N] " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Zrušené."
    exit 0
fi

log "Zastavujem kontajnery..."
docker compose down

echo ""
read -p "Chceš zmazať aj volumes/dáta? [y/N] " -n 1 -r
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    warn "Mazanie dát..."
    docker compose down -v
    log "Volumes zmazané."
else
    log "Dáta ponechané."
fi

log "Hotovo."
