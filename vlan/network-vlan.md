# Home Lab — Sieťový návrh s VLANmi

## Prehľad

Homelab beží v **LXC kontajneri na Proxmoxe** s VLAN segmentáciou.
IoT zariadenia sú izolované v samostatnom VLANe, servery v inom,
bežné zariadenia v defaultnej sieti.

## Topológia

```
                     INTERNET
                        │
                   [ TP-Link Router ]
                    192.168.1.1
                    WAN + NAT
                    Port fwd: 51820/UDP → 10.10.10.100
                        │
                        │ LAN port → Managed Switch (trunk)
                        │
               ┌────────┴────────────────────────────────┐
               │        Managed Switch                    │
               │        (napr. TP-Link TL-SG108E)        │
               │                                          │
               │  Port 1: Trunk (all VLANs) → Proxmox    │
               │  Port 2: Trunk (all VLANs) → Router     │
               │  Port 3: VLAN 1 untagged   → PC         │
               │  Port 4: VLAN 1 untagged   → TV         │
               │  Port 5: VLAN 20 untagged  → WiFi AP IoT│
               │  Port 6-8: voľné                        │
               └──────┬──────────────────────────────────┘
                      │
                      │ Trunk (VLAN 1, 10, 20, 30 tagged)
                      │
              ┌───────┴────────────────────────────────┐
              │  Proxmox Host                           │
              │  vmbr0: 192.168.1.10 (mgmt, VLAN 1)    │
              │  vmbr1: VLAN-aware bridge               │
              │                                         │
              │  ┌───────────────────────────────────┐  │
              │  │  LXC 200 — homelab                │  │
              │  │                                   │  │
              │  │  eth0 (VLAN 10): 10.10.10.100/24  │  │
              │  │  eth1 (VLAN 20): 10.10.20.1/24    │  │
              │  │                                   │  │
              │  │  Docker kontajnery:               │  │
              │  │   Nginx, HA, Node-RED, Grafana,   │  │
              │  │   Z2MQTT, Mosquitto, InfluxDB,    │  │
              │  │   AdGuard, Portainer, Kuma,       │  │
              │  │   WireGuard                       │  │
              │  │                                   │  │
              │  │  USB: Zigbee dongle               │  │
              │  └───────────────────────────────────┘  │
              └─────────────────────────────────────────┘
```

## VLAN rozdelenie

| VLAN ID | Subnet | Názov | Čo tam patrí |
|---------|--------|-------|---------------|
| **1** (default) | 192.168.1.0/24 | Domáca sieť | PC, telefóny, TV, tablet |
| **10** | 10.10.10.0/24 | Servery | LXC homelab, NAS, Proxmox mgmt |
| **20** | 10.10.20.0/24 | IoT | WiFi senzory, smart plugy, kamery |
| **30** | 10.10.30.0/24 | VPN | WireGuard klienti |

### Prečo VLANy?

- **IoT zariadenia** (VLAN 20) nemajú prístup na internet ani k bežným zariadeniam
- **Servery** (VLAN 10) sú oddelené od bežnej siete
- **VPN klienti** (VLAN 30) majú prístup len k serverom
- Ak sa IoT zariadeniu nabúra firmware, nemôže sa dostať k PC ani na internet

## IP adresy

| Zariadenie | IP | VLAN | Poznámka |
|-----------|-----|------|----------|
| TP-Link router | 192.168.1.1 | 1 | Brána na internet |
| Proxmox host | 192.168.1.10 | 1 | Web UI :8006 |
| LXC homelab (eth0) | 10.10.10.100 | 10 | Hlavné rozhranie |
| LXC homelab (eth1) | 10.10.20.1 | 20 | Gateway pre IoT |
| Managed switch | 192.168.1.2 | 1 | Management |
| PC | 192.168.1.51 | 1 | DHCP |
| Telefón | 192.168.1.52 | 1 | DHCP |
| IoT senzor (WiFi) | 10.10.20.50 | 20 | Statická/DHCP |

## Firewall pravidlá

### Inter-VLAN routing (na routeri alebo Proxmox)

```
┌──────────────────────────────────────────────────────────────┐
│ Zdroj          │ Cieľ           │ Port        │ Akcia       │
├──────────────────────────────────────────────────────────────┤
│ VLAN 1 (domáca)│ VLAN 10 (:443) │ 443/TCP     │ ✅ POVOLIŤ │
│ VLAN 1 (domáca)│ VLAN 10 (:53)  │ 53/TCP+UDP  │ ✅ POVOLIŤ │
│ VLAN 1 (domáca)│ VLAN 10 (iné)  │ *           │ ❌ BLOKOVAŤ│
│ VLAN 1 (domáca)│ VLAN 20 (IoT)  │ *           │ ❌ BLOKOVAŤ│
├──────────────────────────────────────────────────────────────┤
│ VLAN 10 (srv)  │ VLAN 20 (IoT)  │ *           │ ✅ POVOLIŤ │
│ VLAN 10 (srv)  │ VLAN 1 (domáca)│ *           │ ✅ POVOLIŤ │
│ VLAN 10 (srv)  │ Internet       │ *           │ ✅ POVOLIŤ │
├──────────────────────────────────────────────────────────────┤
│ VLAN 20 (IoT)  │ VLAN 10 (:1883)│ 1883/TCP    │ ✅ POVOLIŤ │
│ VLAN 20 (IoT)  │ VLAN 10 (iné)  │ *           │ ❌ BLOKOVAŤ│
│ VLAN 20 (IoT)  │ VLAN 1 (domáca)│ *           │ ❌ BLOKOVAŤ│
│ VLAN 20 (IoT)  │ Internet       │ *           │ ❌ BLOKOVAŤ│
├──────────────────────────────────────────────────────────────┤
│ VLAN 30 (VPN)  │ VLAN 10 (:443) │ 443/TCP     │ ✅ POVOLIŤ │
│ VLAN 30 (VPN)  │ VLAN 10 (:53)  │ 53/TCP+UDP  │ ✅ POVOLIŤ │
│ VLAN 30 (VPN)  │ VLAN 10 (iné)  │ *           │ ❌ BLOKOVAŤ│
│ VLAN 30 (VPN)  │ VLAN 20 (IoT)  │ *           │ ❌ BLOKOVAŤ│
└──────────────────────────────────────────────────────────────┘
```

### Zhrnutie

```
VLAN 1  → VLAN 10:  len HTTPS + DNS
VLAN 20 → VLAN 10:  len MQTT (1883)
VLAN 20 → Internet: BLOK (IoT nesmie von)
VLAN 30 → VLAN 10:  len HTTPS + DNS
VLAN 10 → všade:    POVOLIŤ (server musí komunikovať)
```

## Proxmox sieťová konfigurácia

### /etc/network/interfaces

```bash
# Fyzický port
auto eno1
iface eno1 inet manual

# Management bridge (VLAN 1 — default/native)
auto vmbr0
iface vmbr0 inet static
    address 192.168.1.10/24
    gateway 192.168.1.1
    bridge-ports eno1
    bridge-stp off
    bridge-fd 0

# VLAN-aware bridge pre LXC kontajnery
auto vmbr1
iface vmbr1 inet manual
    bridge-ports eno1
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
    bridge-vids 10 20 30
```

### LXC sieťové rozhrania

V `create-lxc.sh`:

```bash
pct create 200 "$CT_TEMPLATE" \
    --hostname homelab \
    --storage local-lvm \
    --rootfs local-lvm:32 \
    --memory 4096 \
    --cores 4 \
    --net0 "name=eth0,bridge=vmbr1,tag=10,ip=10.10.10.100/24,gw=10.10.10.1" \
    --net1 "name=eth1,bridge=vmbr1,tag=20,ip=10.10.20.1/24" \
    --unprivileged 0 \
    --features "nesting=1,keyctl=1" \
    --onboot 1
```

- **eth0** (VLAN 10): Hlavná sieť servera, brána na internet
- **eth1** (VLAN 20): IoT sieť — LXC je gateway pre IoT zariadenia

## Managed Switch konfigurácia

### Odporúčané switche

| Model | Cena (~) | Portov | VLAN | Poznámka |
|-------|----------|--------|------|----------|
| TP-Link TL-SG108E | ~25€ | 8 | ✅ 802.1Q | Najlacnejší managed |
| TP-Link TL-SG108PE | ~55€ | 8 (4× PoE) | ✅ 802.1Q | PoE pre AP/kamery |
| TP-Link TL-SG116E | ~45€ | 16 | ✅ 802.1Q | Viac portov |

### VLAN tagging na switchi

```
┌──────────┬────────────┬──────────┬──────────────────────┐
│ Port     │ VLAN 1     │ VLAN 10  │ VLAN 20              │
├──────────┼────────────┼──────────┼──────────────────────┤
│ Port 1   │ Tagged     │ Tagged   │ Tagged    (Proxmox)  │
│ Port 2   │ Tagged     │ Tagged   │ Tagged    (Router)   │
│ Port 3   │ Untagged   │ —        │ —         (PC)       │
│ Port 4   │ Untagged   │ —        │ —         (TV)       │
│ Port 5   │ —          │ —        │ Untagged  (IoT AP)   │
│ Port 6   │ —          │ Untagged │ —         (NAS)      │
│ Port 7-8 │ Untagged   │ —        │ —         (voľné)    │
└──────────┴────────────┴──────────┴──────────────────────┘

Tagged   = VLAN tag v pakete (trunk port)
Untagged = Zariadenie nevidí VLAN, switch pridá tag (access port)
```

### TP-Link TL-SG108E nastavenie (krok za krokom)

1. Prihlás sa na management IP switcha
2. **VLAN** → **802.1Q VLAN**
3. Vytvor VLANy:
   - VLAN 10 (Servers): Port 1,2 Tagged; Port 6 Untagged
   - VLAN 20 (IoT): Port 1,2 Tagged; Port 5 Untagged
4. **VLAN** → **802.1Q PVID**:
   - Port 3,4,7,8: PVID = 1
   - Port 5: PVID = 20
   - Port 6: PVID = 10

## Inter-VLAN routing

### Možnosť A: Router (TP-Link — obmedzené)

Bežný TP-Link domáci router **nepodporuje** inter-VLAN routing.
Musíš to riešiť cez Proxmox/LXC alebo vymeniť router.

### Možnosť B: Proxmox ako router (odporúčam)

Proxmox robí inter-VLAN routing. V `/etc/network/interfaces`:

```bash
# VLAN sub-interfaces na vmbr1
auto vmbr1.10
iface vmbr1.10 inet static
    address 10.10.10.1/24

auto vmbr1.20
iface vmbr1.20 inet static
    address 10.10.20.1/24

auto vmbr1.30
iface vmbr1.30 inet static
    address 10.10.30.1/24
```

Firewall pravidlá cez `iptables` na Proxmox hoste:

```bash
# /etc/network/if-up.d/firewall-vlans (chmod +x)
#!/bin/bash

# Povoľ forwarding
sysctl -w net.ipv4.ip_forward=1

# NAT pre VLANy na internet (cez vmbr0)
iptables -t nat -A POSTROUTING -s 10.10.10.0/24 -o vmbr0 -j MASQUERADE
iptables -t nat -A POSTROUTING -s 10.10.30.0/24 -o vmbr0 -j MASQUERADE
# IoT NEMÁ NAT = nemá internet

# VLAN 1 → VLAN 10: len HTTPS + DNS
iptables -A FORWARD -s 192.168.1.0/24 -d 10.10.10.100 -p tcp --dport 443 -j ACCEPT
iptables -A FORWARD -s 192.168.1.0/24 -d 10.10.10.100 -p tcp --dport 53 -j ACCEPT
iptables -A FORWARD -s 192.168.1.0/24 -d 10.10.10.100 -p udp --dport 53 -j ACCEPT
iptables -A FORWARD -s 192.168.1.0/24 -d 10.10.10.0/24 -j DROP

# VLAN 20 (IoT) → VLAN 10: len MQTT
iptables -A FORWARD -s 10.10.20.0/24 -d 10.10.10.100 -p tcp --dport 1883 -j ACCEPT
iptables -A FORWARD -s 10.10.20.0/24 -j DROP

# VLAN 30 (VPN) → VLAN 10: len HTTPS + DNS
iptables -A FORWARD -s 10.10.30.0/24 -d 10.10.10.100 -p tcp --dport 443 -j ACCEPT
iptables -A FORWARD -s 10.10.30.0/24 -d 10.10.10.100 -p tcp --dport 53 -j ACCEPT
iptables -A FORWARD -s 10.10.30.0/24 -d 10.10.10.100 -p udp --dport 53 -j ACCEPT
iptables -A FORWARD -s 10.10.30.0/24 -j DROP

# VLAN 10 (servery) → všade OK
iptables -A FORWARD -s 10.10.10.0/24 -j ACCEPT

# Established/related
iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
```

### Možnosť C: Vymeň router za OpenWrt/pfSense

Dlhodobo najlepšie riešenie. Odporúčané zariadenia:

| Zariadenie | Cena (~) | Poznámka |
|-----------|----------|----------|
| Mikrotik hEX S (RB760iGS) | ~60€ | VLAN, firewall, RouterOS |
| Nanopi R4S + OpenWrt | ~80€ | Plný Linux router |
| Mini PC (N100) + pfSense | ~120€ | Enterprise-level |
| Starý PC + OPNsense | 0€ | Ak máš starý HW |

## DNS s VLANmi

AdGuard Home počúva na `10.10.10.100:53` a je prístupný zo všetkých VLANov
(Proxmox routuje).

### DHCP DNS pre každý VLAN

| VLAN | DHCP server | DNS server |
|------|-------------|------------|
| VLAN 1 | TP-Link router | 10.10.10.100 (nastaviť na routeri) |
| VLAN 10 | Statické IP | 10.10.10.100 |
| VLAN 20 | AdGuard DHCP* | 10.10.20.1 (LXC eth1, forward na AdGuard) |
| VLAN 30 | WireGuard | 10.10.10.100 (PEERDNS) |

> \* AdGuard Home môže robiť DHCP server pre IoT VLAN —
> zariadenia automaticky dostanú IP a DNS.

## Traffic flow s VLANmi

### LAN → Home Assistant

```
PC (192.168.1.51, VLAN 1)
 │
 ├─ DNS: ha.local → AdGuard (10.10.10.100:53)
 │  route: VLAN 1 → Proxmox → VLAN 10 (povolené, port 53)
 │  odpoveď: 10.10.10.100
 │
 └─ HTTPS: 10.10.10.100:443
    route: VLAN 1 → Proxmox → VLAN 10 (povolené, port 443)
    → Nginx → HA ✅
```

### IoT → MQTT

```
WiFi senzor teploty (10.10.20.50, VLAN 20)
 │
 └─ MQTT publish → 10.10.10.100:1883
    route: VLAN 20 → Proxmox → VLAN 10 (povolené, port 1883)
    → Mosquitto → HA ✅

    ❌ 10.10.20.50 → internet = BLOKOVANÉ
    ❌ 10.10.20.50 → 192.168.1.51 (PC) = BLOKOVANÉ
```

### VPN → služby

```
📱 Telefón (10.10.30.2, VLAN 30 cez WireGuard)
 │
 ├─ DNS: ha.local → AdGuard → 10.10.10.100
 └─ HTTPS → Nginx → HA ✅
    ❌ Prístup k IoT VLANu = BLOKOVANÉ
```

### Zigbee (bez zmeny)

```
💡 Zigbee žiarovka
 └─ Zigbee rádio → USB dongle → Z2MQTT → MQTT → HA
    (nie je na IP sieti, VLANy sa ho netýkajú)
```

## Kompletný diagram

```
                    INTERNET
                       │
                  [ Router ]
                  192.168.1.1
                  NAT, fwd 51820→10.10.10.100
                       │
                       │
              [ Managed Switch ]
               ┌───┬───┬───┬───┐
               │   │   │   │   │
              P1  P2  P3  P5  P6
              │   │   │   │   │
          Proxmox RT  PC IoT NAS
                          AP

    VLAN 1: 192.168.1.0/24 ──── PC, TV, telefóny
                │
    Proxmox (router medzi VLANmi)
                │
    ┌───────────┼───────────┐
    │           │           │
  VLAN 10    VLAN 20     VLAN 30
  Servery     IoT         VPN
  10.10.10/24 10.10.20/24 10.10.30/24
    │           │           │
  LXC:eth0   LXC:eth1   WireGuard
  .100        .1 (gw)    peers
    │           │
  Docker     WiFi senzory
  (všetky    smart plugy
   služby)   kamery
```

## Porovnanie: s VLANmi vs. bez

| | Bez VLANov | S VLANmi |
|---|-----------|----------|
| **Cena** | 0€ (máš všetko) | ~25-60€ (switch) |
| **Zložitosť** | Jednoduchá | Stredná |
| **IoT izolácia** | Len Zigbee (OK) | Zigbee + WiFi IoT |
| **Bezpečnosť** | Dobrá | Výborná |
| **WiFi IoT** | Na rovnakej sieti ako PC | Izolované |
| **Škálovateľnosť** | Obmedzená | Pridáš VLAN pre čokoľvek |

### Kedy sa oplatí?

- **Bez VLANov stačí** ak: všetky IoT zariadenia sú Zigbee
- **VLANy sa oplatia** ak: plánuješ WiFi IoT (kamery, smart plugy s Tasmota/ESPHome), alebo chceš robustnejšiu bezpečnosť

## Odporúčaný nákupný zoznam

| Položka | Model | Cena (~) |
|---------|-------|----------|
| Managed switch | TP-Link TL-SG108E | 25€ |
| Zigbee dongle | Sonoff ZBDongle-P | 15€ |
| Mini server (ak nemáš Proxmox HW) | N100 mini PC (16GB RAM, 256GB SSD) | 150€ |
| (Voliteľne) WiFi AP pre IoT VLAN | TP-Link EAP225 (VLAN per SSID) | 50€ |
| **Spolu** | | **~240€** |

> WiFi AP s VLAN podporou ti umožní mať dve WiFi siete:
> - `Domáca-WiFi` → VLAN 1
> - `IoT-WiFi` → VLAN 20 (izolovaná, bez internetu)
