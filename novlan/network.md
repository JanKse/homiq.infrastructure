# Home Lab — Sieťový návrh

## Prehľad

Celý homelab beží v **jednom LXC kontajneri na Proxmoxe**. Všetko je na jednej sieti
`192.168.1.0/24` (bežný TP-Link router bez VLANov). IoT zariadenia komunikujú cez
**Zigbee** (nie cez WiFi/IP), takže sú prirodzene izolované.

## Topológia

```
              INTERNET
                 │
            [ TP-Link Router ]
            192.168.1.1
            DHCP: .50 – .200
            DNS:  192.168.1.100 (AdGuard)
                 │
                 │ LAN (192.168.1.0/24)
                 │
       ┌─────────┼──────────┬──────────────┐
       │         │          │              │
  [ Proxmox ]  [ PC ]   [ Telefón ]    [ TV ]
  192.168.1.10  .51       .52           .53
       │
  ┌────┴─────────────────────────┐
  │  LXC 200 — homelab           │
  │  192.168.1.100                │
  │                               │
  │  ┌─────────────────────────┐  │
  │  │ Docker (home-net)       │  │
  │  │                         │  │
  │  │  Nginx (:443, :80)     │  │
  │  │    ├── Home Assistant   │  │
  │  │    ├── Node-RED         │  │
  │  │    ├── Grafana          │  │
  │  │    ├── Uptime Kuma      │  │
  │  │    ├── Zigbee2MQTT      │  │
  │  │    ├── AdGuard Home     │  │
  │  │    └── Portainer        │  │
  │  │                         │  │
  │  │  Mosquitto (:1883)     │  │
  │  │  InfluxDB              │  │
  │  │  WireGuard (:51820)    │  │
  │  └─────────────────────────┘  │
  │                               │
  │  USB: Zigbee dongle ──── 💡🌡️│
  └───────────────────────────────┘
```

## IP adresy

| Zariadenie | IP | Poznámka |
|-----------|-----|----------|
| TP-Link router | 192.168.1.1 | Brána, DHCP server |
| Proxmox host | 192.168.1.10 | Web UI: https://192.168.1.10:8006 |
| LXC homelab | 192.168.1.100 | Všetky služby bežia tu |
| DHCP rozsah | 192.168.1.50 – .200 | Pre ostatné zariadenia |

## Porty otvorené na LXC (192.168.1.100)

| Port | Protokol | Služba | Prístup |
|------|----------|--------|---------|
| 80 | TCP | Nginx (redirect → 443) | LAN |
| 443 | TCP | Nginx (HTTPS proxy) | LAN |
| 53 | TCP/UDP | AdGuard Home (DNS) | LAN |
| 1883 | TCP | Mosquitto (MQTT) | LAN |
| 51820 | UDP | WireGuard (VPN) | Internet* |

> \* Port 51820/UDP treba forwardnúť na routeri z internetu na 192.168.1.100

## DNS (AdGuard Home)

AdGuard beží na `192.168.1.100:53` a automaticky resolvuje:

| Doména | Cieľ | Služba |
|--------|------|--------|
| ha.local | 192.168.1.100 | Home Assistant |
| nodered.local | 192.168.1.100 | Node-RED |
| grafana.local | 192.168.1.100 | Grafana |
| kuma.local | 192.168.1.100 | Uptime Kuma |
| z2mqtt.local | 192.168.1.100 | Zigbee2MQTT |
| adguard.local | 192.168.1.100 | AdGuard Home |
| portainer.local | 192.168.1.100 | Portainer |

Ostatné DNS requesty → Cloudflare DoH (šifrované).

### Nastavenie na TP-Link routeri

1. Prihlás sa na `http://192.168.1.1`
2. **DHCP Settings** → DNS server: `192.168.1.100`
3. Ulož, reštartuj router
4. Všetky zariadenia v sieti automaticky dostanú AdGuard ako DNS

> Ak TP-Link nepodporuje zmenu DNS v DHCP, nastav DNS manuálne na každom
> zariadení, alebo použi AdGuard v režime DHCP servera (vypni DHCP na routeri).

## HTTPS (certifikáty)

Používame **vlastnú CA** (self-signed), keďže nie je verejná doména.

```
Prehliadač → https://ha.local
    │
    ├── DNS (AdGuard) → 192.168.1.100
    └── TLS (Nginx)   → certifikát podpísaný Home Lab CA
         │
         └── Proxy → Home Assistant :8123
```

### Inštalácia CA certifikátu na zariadenia

| Zariadenie | Postup |
|------------|--------|
| **Windows** | Dvojklik `ca.crt` → Inštalovať → Dôveryhodné koreňové CA |
| **macOS** | Dvojklik `ca.crt` → Kľúčenka → Vždy dôverovať |
| **Linux** | `sudo cp ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates` |
| **Android** | Nastavenia → Zabezpečenie → Inštalovať z úložiska |
| **iOS** | Otvoriť `ca.crt` → Profil → Nastavenia → Dôverovať |

## VPN (WireGuard)

```
📱 Vzdialene (mobilná sieť)
   │
   └── WireGuard tunel (port 51820/UDP)
       │
       ├── DNS: 192.168.1.100 (AdGuard)
       │   └── ha.local → 192.168.1.100 ✓
       │
       └── Prístup ku všetkým službám cez HTTPS
           https://ha.local ✓
           https://grafana.local ✓
```

### Nastavenie port forwarding na TP-Link routeri

1. Prihlás sa na `http://192.168.1.1`
2. **Forwarding** → **Virtual Servers** (alebo **NAT Forwarding**)
3. Pridaj pravidlo:
   - Service Port: `51820`
   - Internal IP: `192.168.1.100`
   - Internal Port: `51820`
   - Protocol: **UDP**
4. Ulož

### Dynamická IP (DuckDNS)

Ak nemáš statickú verejnú IP, použi DuckDNS:

1. Zaregistruj sa na [duckdns.org](https://www.duckdns.org)
2. Vytvor subdoménu (napr. `mojhomelab.duckdns.org`)
3. V `.env` nastav: `WG_SERVERURL=mojhomelab.duckdns.org`
4. Pridaj DuckDNS updater do `docker-compose.yml`:

```yaml
  duckdns:
    image: lscr.io/linuxserver/duckdns:latest
    container_name: duckdns
    environment:
      - TOKEN=tvoj-duckdns-token
      - SUBDOMAINS=mojhomelab
    restart: always
```

## Traffic flow

### LAN prístup (z PC/telefónu doma)

```
PC (192.168.1.51)
 │
 ├─ DNS query: "ha.local" → AdGuard (192.168.1.100:53) → "192.168.1.100"
 │
 └─ HTTPS: 192.168.1.100:443
    → Nginx: server_name = ha.local
    → proxy_pass → homeassistant:8123
    → Home Assistant dashboard ✅
```

### VPN prístup (vzdialene)

```
📱 Telefón (mobilná sieť)
 │
 └─ WireGuard tunel → router :51820 → LXC :51820
    │
    ├─ DNS: ha.local → AdGuard → 192.168.1.100
    └─ HTTPS → Nginx → HA ✅
```

### IoT (Zigbee zariadenia)

```
💡 Zigbee žiarovka
 │
 └─ Zigbee rádiovo → USB dongle → Zigbee2MQTT → MQTT → Home Assistant
    (nie je na IP sieti, prirodzene izolované)
```

## Bezpečnosť

| Vrstva | Opatrenie |
|--------|-----------|
| **Sieť** | Všetky služby za HTTPS reverse proxy |
| **DNS** | AdGuard blokuje reklamy a trackery |
| **IoT** | Zigbee zariadenia nie sú na IP sieti |
| **VPN** | WireGuard — vzdialený prístup len cez šifrovaný tunel |
| **Router** | Len port 51820/UDP forwardnutý z internetu |
| **Certifikáty** | Vlastná CA, TLS 1.2+ |
| **MQTT** | Heslo chránený prístup |

## Súborová štruktúra

```
homelab/
├── .env                          # Konfigurácia (IP, heslá)
├── docker-compose.yml            # Všetky služby
├── setup.sh                      # Automatický setup
├── backup.sh                     # Záloha
├── teardown.sh                   # Zastavenie
├── nginx/nginx.conf              # HTTPS reverse proxy
├── certs/                        # SSL certifikáty (generované)
├── proxmox/
│   ├── create-lxc.sh             # Vytvorenie LXC na Proxmoxe
│   ├── bootstrap-lxc.sh          # Inštalácia Dockeru v LXC
│   └── add-usb.sh                # USB passthrough pre Zigbee
├── homeassistant/config/
├── nodered/data/
├── mosquitto/{config,data,log}/
├── zigbee2mqtt/data/
├── grafana/data/
├── influxdb/data/
├── uptime-kuma/data/
├── adguard/{work,conf}/
├── portainer/data/
└── wireguard/config/
```

## Rýchly štart

```bash
# 1. Na Proxmox hoste — vytvor LXC
./proxmox/create-lxc.sh

# 2. V LXC — nainštaluj Docker
pct exec 200 -- /root/bootstrap-lxc.sh

# 3. Skopíruj súbory do LXC
scp -r ./* root@192.168.1.100:/opt/homelab/

# 4. V LXC — spusti všetko
ssh root@192.168.1.100
cd /opt/homelab
nano .env           # uprav heslá a IP
./setup.sh          # certifikáty + docker compose up

# 5. Na routeri
#    - DNS server: 192.168.1.100
#    - Port forward: 51820/UDP → 192.168.1.100
```
