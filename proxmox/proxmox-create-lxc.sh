#!/bin/bash
#
# Spusti tento skript na PROXMOX HOSTE (nie vnútri kontajnera).
# Vytvorí LXC kontajner pripravený na Docker + homelab.
#
# Použitie:
#   scp proxmox-create-lxc.sh root@proxmox:/root/
#   ssh root@proxmox
#   chmod +x proxmox-create-lxc.sh
#   ./proxmox-create-lxc.sh
#
set -euo pipefail

# === KONFIGURÁCIA ===
CTID="${CTID:-200}"
HOSTNAME="${CT_HOSTNAME:-homelab}"
STORAGE="${STORAGE:-local-lvm}"
TEMPLATE="${TEMPLATE:-local:vztmpl/debian-12-standard_12.2-1_amd64.tar.zst}"
MEMORY="${MEMORY:-4096}"
SWAP="${SWAP:-512}"
DISK="${DISK:-32}"
CORES="${CORES:-4}"
BRIDGE="${BRIDGE:-vmbr0}"
IP="${CT_IP:-192.168.1.100/24}"
GATEWAY="${GATEWAY:-192.168.1.1}"
PASSWORD="${CT_PASSWORD:-changeme}"
ZIGBEE_USB="${ZIGBEE_USB:-}"

# === FARBY ===
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

echo ""
echo "========================================="
echo "  Proxmox LXC Setup pre Home Lab"
echo "========================================="
echo ""
echo "  CTID:     $CTID"
echo "  Hostname: $HOSTNAME"
echo "  IP:       $IP"
echo "  RAM:      ${MEMORY}MB"
echo "  Disk:     ${DISK}GB"
echo "  Cores:    $CORES"
echo ""

# === CHECK ===
if ! command -v pct &> /dev/null; then
    err "Tento skript musí bežať na Proxmox hoste (pct nenájdený)."
fi

if pct status "$CTID" &> /dev/null; then
    err "Kontajner $CTID už existuje. Zvoľ iné CTID alebo ho najprv zmaž."
fi

# Stiahni template ak neexistuje
if ! pveam list local | grep -q "debian-12"; then
    log "Sťahujem Debian 12 template..."
    pveam download local debian-12-standard_12.2-1_amd64.tar.zst
fi

# === VYTVOR LXC ===
log "Vytváram LXC kontajner $CTID..."

pct create "$CTID" "$TEMPLATE" \
    --hostname "$HOSTNAME" \
    --memory "$MEMORY" \
    --swap "$SWAP" \
    --cores "$CORES" \
    --rootfs "${STORAGE}:${DISK}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=${IP},gw=${GATEWAY}" \
    --password "$PASSWORD" \
    --unprivileged 0 \
    --features "nesting=1,keyctl=1" \
    --onboot 1 \
    --start 0

log "LXC kontajner vytvorený."

# === KONFIGRÁCIA PRE DOCKER ===
log "Konfigurujem LXC pre Docker..."

CT_CONF="/etc/pve/lxc/${CTID}.conf"

# Pridaj podporu pre Docker v LXC
cat >> "$CT_CONF" << 'EOF'

# Docker support
lxc.apparmor.profile: unconfined
lxc.cgroup2.devices.allow: a
lxc.cap.drop:
lxc.mount.auto: proc:rw sys:rw
EOF

log "Docker podpora pridaná do LXC konfigurácie."

# === USB PASSTHROUGH (Zigbee) ===
if [ -n "$ZIGBEE_USB" ]; then
    log "Konfigurujem USB passthrough pre Zigbee ($ZIGBEE_USB)..."

    # Zisti major:minor číslo zariadenia
    if [ -e "$ZIGBEE_USB" ]; then
        MAJOR=$(stat -c '%t' "$ZIGBEE_USB")
        MINOR=$(stat -c '%T' "$ZIGBEE_USB")

        cat >> "$CT_CONF" << EOF

# Zigbee USB passthrough
lxc.cgroup2.devices.allow: c ${MAJOR}:${MINOR} rwm
lxc.mount.entry: ${ZIGBEE_USB} dev/ttyUSB0 none bind,optional,create=file
EOF
        log "USB passthrough nakonfigurovaný."
    else
        warn "Zariadenie $ZIGBEE_USB neexistuje. USB passthrough preskočený."
        warn "Pripoj Zigbee dongle a spusti: ./proxmox-usb-passthrough.sh $CTID"
    fi
else
    warn "ZIGBEE_USB nie je nastavený. USB passthrough preskočený."
    warn "Nastav ZIGBEE_USB=/dev/ttyUSB0 a spusti znova, alebo použi proxmox-usb-passthrough.sh"
fi

# === ŠTART ===
log "Spúšťam kontajner..."
pct start "$CTID"
sleep 3

# === INŠTALÁCIA DOCKERA VNÚTRI LXC ===
log "Inštalujem Docker vnútri LXC..."

pct exec "$CTID" -- bash -c '
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg lsb-release git > /dev/null 2>&1

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list

    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin > /dev/null 2>&1

    systemctl enable docker
    systemctl start docker
'

log "Docker nainštalovaný."

# === KLONOVANIE HOMELAB REPO ===
log "Pripravujem homelab adresár..."

pct exec "$CTID" -- bash -c '
    mkdir -p /opt/homelab
'

echo ""
log "============================================"
log "  LXC kontajner je pripravený!"
log "============================================"
echo ""
echo "  Ďalšie kroky:"
echo "    1. Skopíruj homelab súbory do kontajnera:"
echo "       pct push $CTID .env /opt/homelab/.env"
echo "       pct push $CTID docker-compose.yml /opt/homelab/docker-compose.yml"
echo "       pct push $CTID setup.sh /opt/homelab/setup.sh"
echo "       ... alebo použi:"
echo "       scp -r homelab/* root@${IP%%/*}:/opt/homelab/"
echo ""
echo "    2. Pripoj sa do kontajnera:"
echo "       pct enter $CTID"
echo ""
echo "    3. Spusti setup:"
echo "       cd /opt/homelab"
echo "       chmod +x setup.sh"
echo "       ./setup.sh"
echo ""
