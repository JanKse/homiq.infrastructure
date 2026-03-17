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
    err ".env súbor neexistuje. Skopíruj .env.example a uprav hodnoty."
fi
set -a; source .env; set +a

echo ""
echo "========================================="
echo "   Home Lab Automated Setup"
echo "========================================="
echo ""

# === 1. CHECK DEPENDENCIES ===
log "Kontrolujem závislosti..."

for cmd in docker openssl; do
    if ! command -v "$cmd" &> /dev/null; then
        err "'$cmd' nie je nainštalovaný."
    fi
done

if ! docker compose version &> /dev/null; then
    err "'docker compose' nie je dostupný."
fi

log "Všetky závislosti OK."

# === 1b. CHECK IF RUNNING IN LXC ===
if [ -f /proc/1/environ ] && grep -qz "container=lxc" /proc/1/environ 2>/dev/null; then
    log "Beží v LXC kontajneri na Proxmox."
    IN_LXC=true
else
    IN_LXC=false
fi

# === 2. CREATE DIRECTORIES ===
log "Vytváram adresárovú štruktúru..."

dirs=(
    certs
    nginx
    homeassistant/config
    nodered/data
    mosquitto/config
    mosquitto/data
    mosquitto/log
    zigbee2mqtt/data
    grafana/data
    influxdb/data
    uptime-kuma/data
    wireguard/config
    adguard/work
    adguard/conf
    portainer/data
)

for d in "${dirs[@]}"; do
    mkdir -p "$d"
done

log "Adresáre vytvorené."

# === 3. GENERATE SSL CERTIFICATES ===
if [ ! -f certs/ca.crt ]; then
    log "Generujem SSL certifikáty..."

    # Root CA
    openssl genrsa -out certs/ca.key 4096 2>/dev/null
    openssl req -x509 -new -nodes -key certs/ca.key -sha256 \
        -days "$CERT_DAYS" -out certs/ca.crt \
        -subj "$CA_SUBJECT" 2>/dev/null

    # Server cert
    openssl genrsa -out certs/home.key 2048 2>/dev/null
    openssl req -new -key certs/home.key -out certs/home.csr \
        -subj "/CN=homelab" 2>/dev/null

    cat > certs/san.ext << EOF
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:ha${DOMAIN_SUFFIX},DNS:nodered${DOMAIN_SUFFIX},DNS:grafana${DOMAIN_SUFFIX},DNS:kuma${DOMAIN_SUFFIX},DNS:z2mqtt${DOMAIN_SUFFIX},DNS:adguard${DOMAIN_SUFFIX},DNS:portainer${DOMAIN_SUFFIX},IP:${HOST_IP}
EOF

    openssl x509 -req -in certs/home.csr -CA certs/ca.crt -CAkey certs/ca.key \
        -CAcreateserial -out certs/home.crt \
        -days "$CERT_DAYS" -sha256 -extfile certs/san.ext 2>/dev/null

    rm -f certs/home.csr certs/san.ext certs/ca.srl

    log "SSL certifikáty vygenerované."
    warn "Nainštaluj certs/ca.crt na svojich zariadeniach (PC, telefón)."
else
    log "SSL certifikáty už existujú, preskakujem."
fi

# === 4. GENERATE MOSQUITTO CONFIG ===
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
    log "Mosquitto konfigurácia vytvorená."
else
    log "Mosquitto konfigurácia už existuje."
fi

# === 5. GENERATE ZIGBEE2MQTT CONFIG ===
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
    log "Zigbee2MQTT konfigurácia vytvorená."
else
    log "Zigbee2MQTT konfigurácia už existuje."
fi

# === 6. GENERATE HOME ASSISTANT BASE CONFIG ===
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
    - 192.168.0.0/16

default_config:
EOF
    log "Home Assistant konfigurácia vytvorená."
else
    log "Home Assistant konfigurácia už existuje."
fi

# === 7. FIX PERMISSIONS ===
log "Nastavujem práva..."
chmod 600 certs/ca.key certs/home.key 2>/dev/null || true
chown -R 1000:1000 nodered/data 2>/dev/null || true
chown -R 472:472 grafana/data 2>/dev/null || true
touch mosquitto/config/password_file mosquitto/log/mosquitto.log
chmod 644 mosquitto/config/password_file 2>/dev/null || true
chmod 666 mosquitto/log/mosquitto.log 2>/dev/null || true
chmod 755 mosquitto/config mosquitto/data mosquitto/log 2>/dev/null || true

# === 7b. CHECK ZIGBEE USB (LXC) ===
if [ "$IN_LXC" = true ]; then
    if [ -e /dev/ttyUSB0 ]; then
        log "Zigbee USB zariadenie: /dev/ttyUSB0 prístupné."
    else
        warn "/dev/ttyUSB0 nenájdený v LXC."
        warn "Na Proxmox hoste spusti: proxmox/add-usb.sh $CT_ID /dev/ttyUSB0"
    fi
fi

# === 8. CREATE MOSQUITTO PASSWORD ===
log "Vytváram MQTT používateľa..."
docker run --rm -v "$(pwd)/mosquitto/config:/mosquitto/config" \
    eclipse-mosquitto:latest \
    mosquitto_passwd -b -c /mosquitto/config/password_file "$MQTT_USER" "$MQTT_PASSWORD" \
    2>/dev/null || warn "MQTT heslo sa nepodarilo vytvoriť (skús manuálne)."
chmod 644 mosquitto/config/password_file 2>/dev/null || true

# === 9. GENERATE ADGUARD CONFIG (auto DNS) ===
if [ ! -f adguard/conf/AdGuardHome.yaml ]; then
    log "Generujem AdGuard Home konfiguráciu s DNS rewrites..."
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
EOF
    log "AdGuard konfigurácia vytvorená s DNS rewrites."
    warn "Pri prvom prístupe na https://adguard${DOMAIN_SUFFIX} nastav admin heslo."
else
    log "AdGuard konfigurácia už existuje."
fi

log "Generujem DNS záznamy (záloha)..."
cat > dns_records.txt << EOF
# DNS záznamy (automaticky v AdGuard, záloha pre /etc/hosts):
${HOST_IP}  ha${DOMAIN_SUFFIX}
${HOST_IP}  nodered${DOMAIN_SUFFIX}
${HOST_IP}  grafana${DOMAIN_SUFFIX}
${HOST_IP}  kuma${DOMAIN_SUFFIX}
${HOST_IP}  z2mqtt${DOMAIN_SUFFIX}
${HOST_IP}  adguard${DOMAIN_SUFFIX}
${HOST_IP}  portainer${DOMAIN_SUFFIX}
EOF
log "DNS záznamy uložené v dns_records.txt"

# === 10. START CONTAINERS ===
echo ""
read -p "Chceš spustiť docker compose up? [y/N] " -n 1 -r
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    log "Spúšťam kontajnery..."
    docker compose up -d

    echo ""
    log "============================================"
    log "  Home Lab je pripravený!"
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
    echo ""
    echo "  DNS:"
    echo "    Nastav DNS server na routeri: ${HOST_IP}"
    echo "    AdGuard automaticky resolvuje všetky *.local domény."
    echo ""
    warn "Nezabudni nainštalovať certs/ca.crt na zariadenia!"
    warn "Nastav DNS na routeri na ${HOST_IP} (AdGuard)."
else
    log "Preskakujem spustenie. Spusti manuálne: docker compose up -d"
fi
