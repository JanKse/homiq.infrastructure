#!/bin/bash
# =============================================================
#  Spúšťa sa VNÚTRI LXC kontajnera
#  Nainštaluje Docker, nastaví prostredie pre VLAN setup
# =============================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

HOMELAB_DIR="/opt/homelab"

echo ""
echo "========================================="
echo "   LXC Bootstrap — VLAN variant"
echo "========================================="
echo ""

# === 1. SYSTEM UPDATE ===
log "Aktualizujem systém..."
apt-get update -qq
apt-get upgrade -y -qq

# === 2. INSTALL DEPENDENCIES ===
log "Inštalujem závislosti..."
apt-get install -y -qq \
    ca-certificates curl gnupg lsb-release \
    openssl git htop nano

# === 3. INSTALL DOCKER ===
if command -v docker &> /dev/null; then
    log "Docker už je nainštalovaný: $(docker --version)"
else
    log "Inštalujem Docker..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -qq
    apt-get install -y -qq \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin

    systemctl enable docker
    systemctl start docker
    log "Docker nainštalovaný: $(docker --version)"
fi

# === 4. VERIFY ===
log "Testujem Docker..."
if docker run --rm hello-world &> /dev/null; then
    log "Docker funguje správne."
else
    warn "Docker test zlyhal. Zbieram diagnostiku..."
    systemctl status docker --no-pager -l || true
    journalctl -u docker -n 80 --no-pager || true
    err "Docker test zlyhal. Ak je kontajner unprivileged, treba ho vytvoriť nanovo cez proxmox/create-lxc.sh (privileged CT)."
fi

# === 5. PREPARE DIR ===
mkdir -p "$HOMELAB_DIR"

# === 6. TIMEZONE ===
log "Nastavujem časovú zónu..."
timedatectl set-timezone Europe/Bratislava 2>/dev/null || \
    ln -sf /usr/share/zoneinfo/Europe/Bratislava /etc/localtime

# === 7. IP FORWARDING ===
log "Povoľujem IP forwarding..."
cat > /etc/sysctl.d/99-homelab.conf << EOF
net.ipv4.ip_forward=1
net.ipv4.conf.all.src_valid_mark=1
EOF
sysctl --system > /dev/null 2>&1

# === 8. CHECK NETWORK INTERFACES ===
log "Sieťové rozhrania:"
echo ""
ip -4 -br addr show | grep -E "eth[0-9]"
echo ""

if ip link show eth1 &> /dev/null; then
    log "eth1 (IoT VLAN) je prítomný."
else
    warn "eth1 (IoT VLAN) nie je prítomný. Skontroluj LXC konfiguráciu."
fi

if [ -e /dev/ttyUSB0 ]; then
    log "Zigbee USB zariadenie: /dev/ttyUSB0"
else
    warn "/dev/ttyUSB0 nenájdený."
fi

echo ""
log "============================================"
log "  LXC bootstrap dokončený!"
log "============================================"
echo ""
echo "  Skopíruj homelab súbory a spusti setup:"
echo ""
echo "    scp -r vlan/* root@10.10.10.100:${HOMELAB_DIR}/"
echo "    cd ${HOMELAB_DIR} && ./setup.sh"
echo ""
