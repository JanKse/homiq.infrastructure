#!/bin/bash
# =============================================================
#  Spúšťa sa NA PROXMOX HOSTE
#  Nastaví VLAN-aware bridge (vmbr1) a VLAN sub-interfaces
#  + inter-VLAN routing + firewall
# =============================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# === LOAD CONFIG ===
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

PVE_MGMT_IP="${PVE_MGMT_IP:-192.168.0.10/24}"
PVE_MGMT_GW="${PVE_MGMT_GW:-192.168.0.1}"
VLAN_SERVERS_ID="${VLAN_SERVERS_ID:-10}"
VLAN_IOT_ID="${VLAN_IOT_ID:-20}"
VLAN_VPN_ID="${VLAN_VPN_ID:-30}"

echo ""
echo "========================================="
echo "   Proxmox VLAN Network Setup"
echo "========================================="
echo ""
echo "  vmbr0: ${PVE_MGMT_IP} (management)"
echo "  vmbr1: VLAN-aware bridge"
echo "    VLAN ${VLAN_SERVERS_ID}: 10.10.10.1/24 (servery)"
echo "    VLAN ${VLAN_IOT_ID}: 10.10.20.1/24 (IoT)"
echo "    VLAN ${VLAN_VPN_ID}: 10.10.30.1/24 (VPN)"
echo ""

if ! command -v pvesh &> /dev/null; then
    err "Tento skript treba spustiť na Proxmox hoste."
fi

# === DETECT PHYSICAL INTERFACE ===
# Poradie: 1) z .env / prostredia, 2) UP interfaces, 3) všetky fyzické, 4) interaktívny výber
if [ -z "${PHYS_IF:-}" ]; then
    # Skús state UP
    PHYS_IF=$(ip -o link show | awk -F': ' '
        {
            iface=$2
            if (iface ~ /^(lo|vmbr|docker|br-|veth|bond)/) next
            if ($0 ~ /state UP/) { print iface; exit }
        }')
fi
if [ -z "${PHYS_IF:-}" ]; then
    # Skús aj state UNKNOWN (interface v bridge môže mať UNKNOWN)
    PHYS_IF=$(ip -o link show | awk -F': ' '
        {
            iface=$2
            if (iface ~ /^(lo|vmbr|docker|br-|veth|bond)/) next
            if ($0 ~ /state (UP|UNKNOWN)/) { print iface; exit }
        }')
fi
if [ -z "${PHYS_IF:-}" ]; then
    # Zobraziť dostupné a opýtať sa
    echo ""
    warn "Nepodarilo sa automaticky nájsť fyzické rozhranie."
    echo ""
    echo "  Dostupné sieťové rozhrania:"
    ip -o link show | awk -F': ' '!/lo/ {printf "    %s\n", $2}'
    echo ""
    read -rp "  Zadaj názov fyzického rozhrania (napr. eno1, enp2s0, eth0): " PHYS_IF
    echo ""
    if [ -z "$PHYS_IF" ]; then
        err "Žiadne rozhranie nezadané. Ukončujem."
    fi
    if ! ip link show "$PHYS_IF" &> /dev/null; then
        err "Rozhranie '$PHYS_IF' neexistuje."
    fi
fi
log "Fyzické rozhranie: $PHYS_IF"

# === BACKUP ===
BACKUP="/etc/network/interfaces.bak.$(date +%Y%m%d_%H%M%S)"
cp /etc/network/interfaces "$BACKUP"
log "Záloha: $BACKUP"

# === CHECK IF vmbr1 EXISTS ===
if ip link show vmbr1 &> /dev/null; then
    warn "vmbr1 už existuje. Preskakujem sieťovú konfiguráciu."
    warn "Ak chceš prekonfigurovať, zmaž vmbr1 a spusti znova."
else
    log "Pridávam vmbr1 do /etc/network/interfaces..."

    cat >> /etc/network/interfaces << EOF

# === VLAN-aware bridge pre LXC kontajnery ===
auto vmbr1
iface vmbr1 inet manual
    bridge-ports ${PHYS_IF}
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
    bridge-vids ${VLAN_SERVERS_ID} ${VLAN_IOT_ID} ${VLAN_VPN_ID}

# VLAN sub-interfaces (Proxmox = router medzi VLANmi)
auto vmbr1.${VLAN_SERVERS_ID}
iface vmbr1.${VLAN_SERVERS_ID} inet static
    address 10.10.10.1/24

auto vmbr1.${VLAN_IOT_ID}
iface vmbr1.${VLAN_IOT_ID} inet static
    address 10.10.20.1/24

auto vmbr1.${VLAN_VPN_ID}
iface vmbr1.${VLAN_VPN_ID} inet static
    address 10.10.30.1/24
EOF

    log "Sieťová konfigurácia pridaná."
fi

# === IP FORWARDING ===
log "Povoľujem IP forwarding..."
cat > /etc/sysctl.d/99-vlan-routing.conf << EOF
net.ipv4.ip_forward=1
net.ipv4.conf.all.src_valid_mark=1
EOF
sysctl --system > /dev/null 2>&1

# === FIREWALL ===
log "Nastavujem firewall pravidlá..."

FIREWALL_SCRIPT="/etc/network/if-up.d/homelab-firewall"
cat > "$FIREWALL_SCRIPT" << 'FWEOF'
#!/bin/bash
# Homelab VLAN firewall — spúšťa sa pri aktivácii siete

# Ak už pravidlá existujú, preskočiť
iptables -L HOMELAB_FW -n &>/dev/null && exit 0

# === NAT ===
# Servery (VLAN 10) majú internet
iptables -t nat -A POSTROUTING -s 10.10.10.0/24 -o vmbr0 -j MASQUERADE
# VPN klienti (VLAN 30) majú internet
iptables -t nat -A POSTROUTING -s 10.10.30.0/24 -o vmbr0 -j MASQUERADE
# IoT (VLAN 20) NEMÁ internet — žiadny NAT

# === FORWARD chain ===
iptables -N HOMELAB_FW 2>/dev/null || true
iptables -A FORWARD -j HOMELAB_FW

# Established/related vždy OK
iptables -A HOMELAB_FW -m state --state ESTABLISHED,RELATED -j ACCEPT

# --- VLAN 1 (domáca, 192.168.1.0/24) → VLAN 10 (servery) ---
# Len HTTPS + DNS
iptables -A HOMELAB_FW -s 192.168.1.0/24 -d 10.10.10.100 -p tcp --dport 443 -j ACCEPT
iptables -A HOMELAB_FW -s 192.168.1.0/24 -d 10.10.10.100 -p tcp --dport 53 -j ACCEPT
iptables -A HOMELAB_FW -s 192.168.1.0/24 -d 10.10.10.100 -p udp --dport 53 -j ACCEPT
iptables -A HOMELAB_FW -s 192.168.1.0/24 -d 10.10.10.0/24 -j DROP

# --- VLAN 20 (IoT) → VLAN 10 (servery) ---
# Len MQTT
iptables -A HOMELAB_FW -s 10.10.20.0/24 -d 10.10.10.100 -p tcp --dport 1883 -j ACCEPT
# IoT → všetko ostatné: BLOK
iptables -A HOMELAB_FW -s 10.10.20.0/24 -d 10.10.10.0/24 -j DROP
iptables -A HOMELAB_FW -s 10.10.20.0/24 -d 192.168.1.0/24 -j DROP
iptables -A HOMELAB_FW -s 10.10.20.0/24 -o vmbr0 -j DROP

# --- VLAN 30 (VPN) → VLAN 10 (servery) ---
# Len HTTPS + DNS
iptables -A HOMELAB_FW -s 10.10.30.0/24 -d 10.10.10.100 -p tcp --dport 443 -j ACCEPT
iptables -A HOMELAB_FW -s 10.10.30.0/24 -d 10.10.10.100 -p tcp --dport 53 -j ACCEPT
iptables -A HOMELAB_FW -s 10.10.30.0/24 -d 10.10.10.100 -p udp --dport 53 -j ACCEPT
iptables -A HOMELAB_FW -s 10.10.30.0/24 -d 10.10.10.0/24 -j DROP
iptables -A HOMELAB_FW -s 10.10.30.0/24 -d 10.10.20.0/24 -j DROP

# --- VLAN 10 (servery) → všade OK ---
iptables -A HOMELAB_FW -s 10.10.10.0/24 -j ACCEPT
FWEOF

chmod +x "$FIREWALL_SCRIPT"
log "Firewall skript vytvorený: $FIREWALL_SCRIPT"

# === APPLY FIREWALL NOW ===
bash "$FIREWALL_SCRIPT"
log "Firewall pravidlá aplikované."

echo ""
log "============================================"
log "  Proxmox sieť nakonfigurovaná!"
log "============================================"
echo ""
echo "  Bridges:"
echo "    vmbr0: ${PVE_MGMT_IP} (management, VLAN 1)"
echo "    vmbr1: VLAN-aware trunk"
echo ""
echo "  VLAN routing (Proxmox = router):"
echo "    VLAN ${VLAN_SERVERS_ID}: 10.10.10.1/24 — servery (internet ✓)"
echo "    VLAN ${VLAN_IOT_ID}: 10.10.20.1/24 — IoT (internet ✗)"
echo "    VLAN ${VLAN_VPN_ID}: 10.10.30.1/24 — VPN (internet ✓)"
echo ""
echo "  Firewall:"
echo "    IoT → servery: len MQTT (1883)"
echo "    IoT → internet: BLOKOVANÉ"
echo "    Domáca → servery: len HTTPS + DNS"
echo ""
warn "REBOOT Proxmox hosta, aby sa aktivoval vmbr1!"
warn "Potom spusti: proxmox/create-lxc.sh"
echo ""
