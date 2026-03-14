#!/bin/bash
set -euo pipefail

# === COLORS ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# === LOAD ENV ===
if [ ! -f .env ]; then
    err ".env súbor neexistuje."
fi
set -a; source .env; set +a

echo ""
echo "========================================="
echo "   Home Lab Setup — VLAN variant"
echo "========================================="
echo ""

# === 1. CHECK DEPENDENCIES ===
log "Kontrolujem závislosti..."

for cmd in docker openssl; do
    if ! command -v "$cmd" &> /dev/null; then
        err "'$cmd' nie je nainštalovaný."
    fi
done

docker compose version &> /dev/null || err "'docker compose' nie je dostupný."
log "Závislosti OK."

# === 1b. CHECK LXC ===
if [ -f /proc/1/environ ] && grep -qz "container=lxc" /proc/1/environ 2>/dev/null; then
    log "Beží v LXC kontajneri."
    IN_LXC=true
else
    IN_LXC=false
fi

# === 1c. CHECK NETWORK ===
log "Kontrolujem sieť..."
if ip link show eth0 &> /dev/null; then
    ETH0_IP=$(ip -4 -br addr show eth0 | awk '{print $3}')
    log "  eth0 (servery): $ETH0_IP"
fi
if ip link show eth1 &> /dev/null; then
    ETH1_IP=$(ip -4 -br addr show eth1 | awk '{print $3}')
    log "  eth1 (IoT):     $ETH1_IP"
else
    warn "  eth1 (IoT VLAN) nenájdený — WiFi IoT zariadenia nebudú dostupné."
fi

# === 2. CREATE DIRECTORIES ===
log "Vytváram adresárovú štruktúru..."

dirs=(
    certs nginx
    homeassistant/config nodered/data
    mosquitto/config mosquitto/data mosquitto/log
    zigbee2mqtt/data grafana/data influxdb/data
    uptime-kuma/data wireguard/config
    adguard/work adguard/conf portainer/data
    esphome/config
)

for d in "${dirs[@]}"; do
    mkdir -p "$d"
done
log "Adresáre vytvorené."

# === 3. GENERATE SSL CERTIFICATES ===
if [ ! -f certs/ca.crt ]; then
    log "Generujem SSL certifikáty..."

    openssl genrsa -out certs/ca.key 4096 2>/dev/null
    openssl req -x509 -new -nodes -key certs/ca.key -sha256 \
        -days "$CERT_DAYS" -out certs/ca.crt \
        -subj "$CA_SUBJECT" 2>/dev/null

    openssl genrsa -out certs/home.key 2048 2>/dev/null
    openssl req -new -key certs/home.key -out certs/home.csr \
        -subj "/CN=homelab" 2>/dev/null

    cat > certs/san.ext << EOF
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:ha${DOMAIN_SUFFIX},DNS:nodered${DOMAIN_SUFFIX},DNS:grafana${DOMAIN_SUFFIX},DNS:kuma${DOMAIN_SUFFIX},DNS:z2mqtt${DOMAIN_SUFFIX},DNS:adguard${DOMAIN_SUFFIX},DNS:portainer${DOMAIN_SUFFIX},DNS:esphome${DOMAIN_SUFFIX},IP:${HOST_IP}
EOF

    openssl x509 -req -in certs/home.csr -CA certs/ca.crt -CAkey certs/ca.key \
        -CAcreateserial -out certs/home.crt \
        -days "$CERT_DAYS" -sha256 -extfile certs/san.ext 2>/dev/null

    rm -f certs/home.csr certs/san.ext certs/ca.srl

    log "SSL certifikáty vygenerované."
    warn "Nainštaluj certs/ca.crt na zariadeniach (PC, telefón)."
else
    log "SSL certifikáty existujú, preskakujem."
fi

# === 4. MOSQUITTO CONFIG ===
if [ ! -f mosquitto/config/mosquitto.conf ]; then
    log "Generujem Mosquitto konfiguráciu..."
    cat > mosquitto/config/mosquitto.conf << EOF
listener 1883
allow_anonymous false
password_file /mosquitto/config/password_file
persistence true
persistence_location /mosquitto/data/
log_dest file /mosquitto/log/mosquitto.log
EOF
    log "Mosquitto OK."
fi

# === 5. ZIGBEE2MQTT CONFIG ===
if [ ! -f zigbee2mqtt/data/configuration.yaml ]; then
    log "Generujem Zigbee2MQTT konfiguráciu..."
    cat > zigbee2mqtt/data/configuration.yaml << EOF
homeassistant: true
permit_join: false
frontend: true
mqtt:
  base_topic: zigbee2mqtt
  server: mqtt://mosquitto:1883
  user: ${MQTT_USER}
  password: ${MQTT_PASSWORD}
serial:
  port: ${ZIGBEE_DEVICE}
EOF
    log "Zigbee2MQTT OK."
fi

# === 6. HOME ASSISTANT CONFIG ===
if [ ! -f homeassistant/config/configuration.yaml ]; then
    log "Generujem Home Assistant konfiguráciu..."
    cat > homeassistant/config/configuration.yaml << EOF
homeassistant:
  name: Home
  unit_system: metric
  time_zone: Europe/Bratislava

http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 172.16.0.0/12
    - 10.10.10.0/24
    - 10.10.20.0/24

default_config:
EOF
    log "Home Assistant OK."
fi

# === 7. FIX PERMISSIONS ===
log "Nastavujem práva..."
chmod 600 certs/ca.key certs/home.key 2>/dev/null || true
chown -R 1000:1000 nodered/data 2>/dev/null || true
chown -R 472:472 grafana/data 2>/dev/null || true

# === 7b. CHECK USB ===
if [ "$IN_LXC" = true ]; then
    if [ -e /dev/ttyUSB0 ]; then
        log "Zigbee USB: /dev/ttyUSB0 prístupné."
    else
        warn "/dev/ttyUSB0 nenájdený. Na PVE hoste: proxmox/add-usb.sh ${CT_ID:-200} /dev/ttyUSB0"
    fi
fi

# === 8. MQTT PASSWORD ===
log "Vytváram MQTT používateľa..."
docker run --rm -v "$(pwd)/mosquitto/config:/mosquitto/config" \
    eclipse-mosquitto:latest \
    mosquitto_passwd -b -c /mosquitto/config/password_file "$MQTT_USER" "$MQTT_PASSWORD" \
    2>/dev/null || warn "MQTT heslo — skús manuálne."

# === 9. ADGUARD CONFIG ===
if [ ! -f adguard/conf/AdGuardHome.yaml ]; then
    log "Generujem AdGuard konfiguráciu s DNS rewrites..."
    cat > adguard/conf/AdGuardHome.yaml << EOF
bind_host: 0.0.0.0
bind_port: 3000
users:
  - name: admin
    password: \$2y\$10\$placeholder_hash_change_on_first_login
dns:
  bind_hosts:
    - 0.0.0.0
  port: 53
  upstream_dns:
    - https://dns.cloudflare.com/dns-query
    - https://dns.google/dns-query
  rewrites:
    - domain: ha${DOMAIN_SUFFIX}
      answer: ${HOST_IP}
    - domain: nodered${DOMAIN_SUFFIX}
      answer: ${HOST_IP}
    - domain: grafana${DOMAIN_SUFFIX}
      answer: ${HOST_IP}
    - domain: kuma${DOMAIN_SUFFIX}
      answer: ${HOST_IP}
    - domain: z2mqtt${DOMAIN_SUFFIX}
      answer: ${HOST_IP}
    - domain: adguard${DOMAIN_SUFFIX}
      answer: ${HOST_IP}
    - domain: portainer${DOMAIN_SUFFIX}
      answer: ${HOST_IP}
    - domain: esphome${DOMAIN_SUFFIX}
      answer: ${HOST_IP}
EOF
    log "AdGuard OK."
    warn "Pri prvom prístupe nastav admin heslo."
fi

# === 9b. DNS RECORDS BACKUP ===
log "Generujem DNS záznamy..."
cat > dns_records.txt << EOF
# DNS rewrites (automaticky cez AdGuard, záloha pre /etc/hosts):
${HOST_IP}  ha${DOMAIN_SUFFIX}
${HOST_IP}  nodered${DOMAIN_SUFFIX}
${HOST_IP}  grafana${DOMAIN_SUFFIX}
${HOST_IP}  kuma${DOMAIN_SUFFIX}
${HOST_IP}  z2mqtt${DOMAIN_SUFFIX}
${HOST_IP}  adguard${DOMAIN_SUFFIX}
${HOST_IP}  portainer${DOMAIN_SUFFIX}
${HOST_IP}  esphome${DOMAIN_SUFFIX}
EOF
log "DNS záznamy: dns_records.txt"

# === 10. START ===
echo ""
read -p "Chceš spustiť docker compose up? [y/N] " -n 1 -r
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    log "Spúšťam kontajnery..."
    docker compose up -d

    echo ""
    log "============================================"
    log "  Home Lab je pripravený! (VLAN setup)"
    log "============================================"
    echo ""
    echo "  Služby (HTTPS):"
    echo "    Home Assistant:  https://ha${DOMAIN_SUFFIX}"
    echo "    Node-RED:        https://nodered${DOMAIN_SUFFIX}"
    echo "    Grafana:         https://grafana${DOMAIN_SUFFIX}"
    echo "    Uptime Kuma:     https://kuma${DOMAIN_SUFFIX}"
    echo "    Zigbee2MQTT:     https://z2mqtt${DOMAIN_SUFFIX}"
    echo "    AdGuard Home:    https://adguard${DOMAIN_SUFFIX}"
    echo "    Portainer:       https://portainer${DOMAIN_SUFFIX}"
    echo "    ESPHome:         https://esphome${DOMAIN_SUFFIX}"
    echo ""
    echo "  Sieť:"
    echo "    LXC eth0 (VLAN ${VLAN_SERVERS_ID:-10}): ${HOST_IP} — servery"
    echo "    LXC eth1 (VLAN ${VLAN_IOT_ID:-20}): ${CT_IOT_IP:-10.10.20.1/24} — IoT gateway"
    echo "    WireGuard VPN: VLAN ${VLAN_VPN_ID:-30}"
    echo ""
    echo "  DNS:"
    echo "    Na routeri nastav DNS: ${HOST_IP}"
    echo "    VPN klienti: automaticky cez WireGuard PEERDNS"
    echo ""
    warn "Nainštaluj certs/ca.crt na zariadenia!"
else
    log "Preskakujem. Spusti: docker compose up -d"
fi
