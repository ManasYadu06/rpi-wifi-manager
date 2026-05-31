# rpi-wifi-manager

Production-grade WiFi manager for Raspberry Pi. Replaces the basic hotspot script with a full state-machine daemon, fast AP bring-up, SSID scanning, auto-reconnect, and a captive portal web UI — all integrated into systemd.

## Problems solved

| Problem | Fix |
|---|---|
| **Slow AP appearance** | `rfkill unblock` + `iw reg set` + `ip link up` in `ExecStartPre` before NM activates; pre-built NM connection profile so no probe delay |
| **No SSID scan** | `nmcli device wifi rescan` → JSON output; iwlist fallback; live rescan in portal UI |
| **No reconnection** | Exponential backoff reconnect loop; watchdog polls every 60 s; falls back to hotspot after N retries |
| **AP name** | Auto-named `RPI-<hostname>-Setup` so every Pi has a unique, recognisable SSID |
| **Not systemd-native** | `Type=notify` + `sd_notify` + `WatchdogSec` + `Restart=on-failure`; proper `After=` ordering |

---

## Architecture

```
boot
 └─ NetworkManager.service
     └─ rpi-wifi-manager.service   (Type=notify, watchdog)
         ├─ wifi-manager daemon    ← state machine
         │    ├─ SCANNING          scan for known networks
         │    ├─ CONNECTING        nmcli connect with timeout
         │    ├─ CONNECTED         watchdog pings gateway
         │    ├─ RECONNECTING[N]   exponential backoff
         │    └─ HOTSPOT           nmcli AP mode
         └─ rpi-wifi-portal.service
              └─ wifi-portal.py    HTTP:80 captive portal
```

---

## Installation

```bash
git clone https://github.com/ManasYadu06/rpi-wifi-connectivity-through-hotspot.git
cd rpi-wifi-connectivity-through-hotspot
sudo ./install.sh
sudo reboot
```

Requires: **Raspberry Pi OS (Bookworm/Bullseye)** with NetworkManager. NetworkManager is the default on Bookworm. On Bullseye you may need:
```bash
sudo apt install network-manager
sudo raspi-config  # Advanced → Network Manager → Enable
```

---

## Configuration

Edit `/etc/rpi-wifi-manager/config` then `sudo systemctl restart rpi-wifi-manager`.

```bash
IFACE=wlan0
AP_SSID=RPI-mypi-Setup         # auto-set from hostname if left as default
AP_PASS=raspberry
AP_CHANNEL=6
AP_IP=192.168.4.1
COUNTRY=IN                     # WiFi regulatory domain

CONNECT_TIMEOUT=30             # seconds to wait for association
RECONNECT_RETRIES=5            # 0 = infinite retries
RECONNECT_BACKOFF=5            # initial seconds between retries (doubles each time)
WATCHDOG_INTERVAL=60           # seconds between connection health checks
```

---

## CLI usage

```bash
sudo wifi-manager status           # current state, SSID, IP
sudo wifi-manager scan             # scan & print nearby networks
sudo wifi-manager connect "MySSID" "mypassword"
sudo wifi-manager hotspot          # force AP mode now
sudo wifi-manager reconnect        # force reconnect attempt
sudo wifi-manager config           # show active config
```

---

## Captive Portal

When in hotspot mode:
1. Connect any phone/laptop to `RPI-<hostname>-Setup` (password: `raspberry`)
2. Browser auto-redirects to `http://192.168.4.1`
3. Page shows live scan results, signal strength, security type
4. Enter SSID + password → Pi connects and saves credentials
5. On next boot, Pi auto-connects without needing the hotspot

---

## Service management

```bash
# Logs
sudo journalctl -u rpi-wifi-manager -f
sudo journalctl -u rpi-wifi-portal  -f

# Control
sudo systemctl start   rpi-wifi-manager
sudo systemctl stop    rpi-wifi-manager
sudo systemctl restart rpi-wifi-manager
sudo systemctl status  rpi-wifi-manager
```

---

## Troubleshooting

**AP doesn't appear after boot**
```bash
sudo rfkill list              # check if WiFi is soft/hard blocked
sudo iw dev                   # check interface name (may not be wlan0)
sudo journalctl -u rpi-wifi-manager -n 50
```
If interface is not `wlan0`, edit `IFACE=` in `/etc/rpi-wifi-manager/config`.

**Scan returns no results**
```bash
sudo wifi-manager scan
sudo iwlist wlan0 scan | grep ESSID
```
The Pi may need to be in managed mode (not AP mode) to scan. The daemon handles this automatically but manual scans require stopping the hotspot first.

**Can't connect to a network**
```bash
sudo nmcli device wifi list          # check NM sees the AP
sudo nmcli -s connection show        # check saved credentials
sudo wifi-manager connect "SSID" "pass"
```

**NetworkManager not installed (older OS)**
```bash
sudo apt install network-manager
sudo systemctl enable NetworkManager
sudo systemctl start  NetworkManager
# Then re-run install.sh
```

---

## Files installed

| Path | Description |
|---|---|
| `/usr/local/bin/wifi-manager` | Main daemon + CLI |
| `/usr/local/bin/wifi-portal.py` | Captive portal web server |
| `/etc/systemd/system/rpi-wifi-manager.service` | Daemon unit |
| `/etc/systemd/system/rpi-wifi-portal.service` | Portal unit |
| `/etc/rpi-wifi-manager/config` | User configuration |
| `/etc/NetworkManager/conf.d/rpi-wifi-manager.conf` | NM tuning |
| `/run/rpi-wifi-manager/state` | Runtime state file |
