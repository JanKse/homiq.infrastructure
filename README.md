# homiq.infrastructure

Infraštruktúra pre domáci homelab — Docker kontajnery bežiace v LXC na Proxmoxe,
s VLAN segmentáciou siete.

Sieťový návrh: [`docs/network-vlan.md`](docs/network-vlan.md)

---

## Štruktúra repozitára

```
proxmox/          — skripty pre základnú verziu (bez VLANov)
vlan/             — skripty pre VLAN verziu  ← odporúčaná
  proxmox/        — skripty spúšťané na Proxmox hoste
  nginx/          — konfigurácia reverse proxy
  docker-compose.yml
  setup.sh        — prvotná inštalácia v LXC
  teardown.sh     — zastavenie / mazanie
docs/             — dokumentácia siete
```

---

## VLAN verzia — postup inštalácie

### Prerekvizity

- **Proxmox** nainštalovaný na serveri
- **Managed switch** s podporou 802.1Q VLAN taggovania
  (napr. TP-Link TL-SG108E ~25€)
- **Zigbee USB dongle** (napr. Sonoff Zigbee 3.0 USB Dongle Plus)

### VLAN schéma

| VLAN | Subnet | Účel |
|------|--------|------|
| 10 | `10.10.10.0/24` | Servery (LXC homelab) |
| 20 | `10.10.20.0/24` | IoT zariadenia (senzory, smart plugy) |
| 30 | `10.10.30.0/24` | VPN klienti (WireGuard) |

---

## Krok 1 — Sieť na Proxmoxe

Spusti **na Proxmox hoste** (cez SSH alebo Shell v UI):

```bash
bash vlan/proxmox/setup-proxmox-network.sh
```

Skript:
- vytvorí `vmbr1` — VLAN-aware bridge
- pridá sub-interfaces `vmbr1.10`, `vmbr1.20`, `vmbr1.30`
- zapne IP forwarding
- nastaví `iptables` firewall pravidlá (IoT izolovaný od internetu a LAN)

> Sieťové rozhranie sa aplikuje po reštarte alebo `ifreload -a`.

---

## Krok 2 — Vytvorenie .env súboru

V adresári `vlan/` vytvor `.env` súbor:

```bash
# identita kontajnera
CT_ID=200
CT_NAME=homelab

# siete
CT_IP=10.10.10.100/24
CT_GW=10.10.10.1
CT_IOT_IP=10.10.20.1/24
VLAN_SERVERS_ID=10
VLAN_IOT_ID=20
VLAN_VPN_ID=30

# proxmox management
PVE_MGMT_IP=192.168.1.10/24
PVE_MGMT_GW=192.168.1.1

# zigbee USB (nechaj prázdne ak nie je zapojený)
ZIGBEE_USB=/dev/ttyUSB0
ZIGBEE_DEVICE=/dev/ttyUSB0

# domény
DOMAIN_SUFFIX=.home
HOST_IP=10.10.10.100

# heslá
GRAFANA_PASSWORD=zmenMa123
INFLUXDB_PASSWORD=zmenMa123
INFLUXDB_TOKEN=zmenMa_dlhy_token
MQTT_USER=mqtt
MQTT_PASSWORD=zmenMa123

# certifikáty
CERT_DAYS=3650
CA_SUBJECT="/CN=HomeLab CA/O=HomeLab"
```

---

## Krok 3 — Vytvorenie LXC kontajnera

Spusti **na Proxmox hoste**:

```bash
bash vlan/proxmox/create-lxc.sh
```

Skript vytvorí LXC 200 s dvoma sieťovými rozhraniami:
- `eth0` → VLAN 10 (`10.10.10.100/24`) — hlavná sieť
- `eth1` → VLAN 20 (`10.10.20.1/24`) — IoT gateway

Potom skopíruje `bootstrap-lxc.sh` do kontajnera a vypíše ďalší krok.

---

## Krok 4 — Bootstrap LXC

Spusti **vo vnútri LXC kontajnera** (alebo cez `pct exec`):

```bash
# možnosť A — priamo na Proxmox hoste
pct exec 200 -- /root/bootstrap-lxc.sh

# možnosť B — po prihlásení do LXC (ssh root@10.10.10.100)
/root/bootstrap-lxc.sh
```

Bootstrap nainštaluje Docker, nastaví timezone, IP forwarding, a overí sieťové rozhrania.

---

## Krok 5 — Kopírovanie súborov do LXC

**Z Proxmox hosta** alebo z lokálneho PC:

```bash
scp -r vlan/* root@10.10.10.100:/opt/homelab/
```

---

## Krok 6 — Spustenie setup

Prihlás sa do LXC a spusti setup:

```bash
ssh root@10.10.10.100
cd /opt/homelab
nano .env          # skontroluj a uprav heslá
./setup.sh
```

Setup:
- vygeneruje SSL certifikáty (self-signed CA)
- vytvorí konfigurácie pre Mosquitto, Zigbee2MQTT, Home Assistant, AdGuard
- spustí všetky Docker kontajnery

---

## Krok 7 — Managed Switch

Nakonfiguruj VLAN tagging na switchi podľa [`docs/network-vlan.md`](docs/network-vlan.md):

| Port | VLAN 1 | VLAN 10 | VLAN 20 | Zariadenie |
|------|--------|---------|---------|-----------|
| 1 | Tagged | Tagged | Tagged | → Proxmox |
| 2 | Tagged | Tagged | Tagged | → Router |
| 3 | Untagged | — | — | PC / TV |
| 5 | — | — | Untagged | WiFi AP (IoT) |
| 6 | — | Untagged | — | NAS |

---

## Prístup k službám

Po spustení sú služby dostupné cez HTTPS (port 443) na `10.10.10.100`:

| Služba | Adresa |
|--------|--------|
| Home Assistant | `https://ha.home` |
| Grafana | `https://grafana.home` |
| Node-RED | `https://nodered.home` |
| Portainer | `https://portainer.home` |
| AdGuard DNS | `https://adguard.home` |
| Uptime Kuma | `https://kuma.home` |
| Zigbee2MQTT | `https://z2mqtt.home` |
| ESPHome | `http://10.10.10.100:6052` |

> AdGuard DNS (`10.10.10.100:53`) musí byť nastavený ako DNS server na routeri
> alebo priamo v zariadeniach, aby fungovalo `*.home` rozlíšenie.

---

## Správa

```bash
# zastavenie / zmazanie kontajnerov
cd /opt/homelab && ./teardown.sh

# USB Zigbee dongle pridaný neskôr
bash proxmox/add-usb.sh 200 /dev/ttyUSB0

# logy Docker kontajnera
docker compose logs -f homeassistant

# stav všetkých kontajnerov
docker compose ps
```
