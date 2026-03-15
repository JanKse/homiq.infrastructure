#!/bin/bash
# =============================================================
#  Spúšťa sa VNÚTRI LXC kontajnera
#  Nainštaluje Docker, docker compose, a pripraví prostredie
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
echo "   LXC Bootstrap — Docker + Home Lab"
echo "========================================="
echo ""

# === 1. SYSTEM UPDATE ===
log "Aktualizujem systém..."
apt-get update -qq
apt-get upgrade -y -qq

# === 2. INSTALL DEPENDENCIES ===
log "Inštalujem závislosti..."
apt-get install -y -qq \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    openssl \
    git \
    htop \
    nano

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
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin

    systemctl enable docker
    systemctl start docker

    log "Docker nainštalovaný: $(docker --version)"
fi

# === 4. VERIFY DOCKER ===
log "Testujem Docker..."
if docker run --rm hello-world &> /dev/null; then
    log "Docker funguje správne."
else
    err "Docker test zlyhal. Skontroluj LXC konfiguráciu (nesting, keyctl)."
fi

# === 5. PREPARE HOMELAB DIRECTORY ===
log "Pripravujem $HOMELAB_DIR ..."
mkdir -p "$HOMELAB_DIR"

# === 6. TIMEZONE ===
log "Nastavujem časovú zónu..."
timedatectl set-timezone Europe/Bratislava 2>/dev/null || \
    ln -sf /usr/share/zoneinfo/Europe/Bratislava /etc/localtime

# === 7. ENABLE IP FORWARDING (WireGuard) ===
log "Povoľujem IP forwarding..."
cat > /etc/sysctl.d/99-wireguard.conf << EOF
net.ipv4.ip_forward=1
net.ipv4.conf.all.src_valid_mark=1
EOF
sysctl --system > /dev/null 2>&1

# === 8. CHECK USB DEVICE ===
if [ -e /dev/ttyUSB0 ]; then
    log "Zigbee USB zariadenie nájdené: /dev/ttyUSB0"
else
    warn "/dev/ttyUSB0 nenájdený — Zigbee dongle nie je pripojený alebo USB passthrough nie je nakonfigurovaný."
fi

echo ""
log "============================================"
log "  LXC bootstrap dokončený!"
log "============================================"
echo ""
echo "  Ďalší krok — skopíruj homelab súbory:"
echo ""
echo "    # Z Proxmox hosta alebo lokálne:"
echo "    scp -r homelab/* root@\$(hostname -I | awk '{print \$1}'):${HOMELAB_DIR}/"
echo ""
echo "    # Potom v LXC:"
echo "    cd ${HOMELAB_DIR}"
echo "    nano .env        # uprav konfiguráciu"
echo "    ./setup.sh       # spusti setup"
echo ""
