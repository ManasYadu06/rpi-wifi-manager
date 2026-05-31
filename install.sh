#!/usr/bin/env bash
# =============================================================================
# install.sh  —  Install rpi-wifi-manager onto the Raspberry Pi
# Run: sudo ./install.sh
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
die()   { echo -e "${RED}[✗] $*${NC}"; exit 1; }

[[ $EUID -ne 0 ]] && die "Run as root: sudo $0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║     rpi-wifi-manager  —  Installer       ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ─── 1. Dependencies ─────────────────────────────────────────────────────────
info "Checking dependencies..."
apt-get update -qq
apt-get install -y -qq \
    network-manager \
    iw \
    wireless-tools \
    rfkill \
    python3 \
    curl \
    avahi-daemon \
    libnss-mdns \
    2>/dev/null

# Ensure NM is enabled
systemctl enable NetworkManager
systemctl start  NetworkManager

# ─── Configure mDNS (avahi) ───────────────────────────────────────────────────
info "Configuring mDNS (avahi)..."
HOSTNAME_SHORT=$(hostname -s)
cat > /etc/avahi/avahi-daemon.conf << 'AVAHI'
[server]
host-name=HOSTNAME_PLACEHOLDER
domain-name=local
allow-interfaces=wlan0,eth0
use-ipv4=yes
use-ipv6=no

[publish]
publish-addresses=yes
publish-hinfo=yes
publish-workstation=yes
publish-domain=yes

[rlimits]
rlimit-core=0
rlimit-data=4194304
rlimit-fsize=0
rlimit-nofile=768
rlimit-stack=4194304
rlimit-nproc=3
AVAHI
# Substitute real hostname into conf (heredoc can't expand vars with quotes)
sed -i "s/HOSTNAME_PLACEHOLDER/${HOSTNAME_SHORT}/" /etc/avahi/avahi-daemon.conf
systemctl enable avahi-daemon
systemctl restart avahi-daemon 2>/dev/null || systemctl start avahi-daemon
info "mDNS enabled → http://${HOSTNAME_SHORT}.local  and  http://raspberry.local" 

# ─── 2. Disable conflicting services ─────────────────────────────────────────
info "Disabling conflicting services..."
for svc in wpa_supplicant dhcpcd; do
    if systemctl list-units --full -all 2>/dev/null | grep -q "$svc.service"; then
        systemctl disable "$svc" 2>/dev/null || true
        systemctl stop    "$svc" 2>/dev/null || true
        warn "Disabled $svc (NM handles this now)"
    fi
done

# Remove ifupdown wlan entries so NM has full control
if grep -q "wlan" /etc/network/interfaces 2>/dev/null; then
    cp /etc/network/interfaces /etc/network/interfaces.bak
    sed -i '/wlan/d' /etc/network/interfaces
    warn "Cleaned wlan entries from /etc/network/interfaces (backup saved)"
fi

# ─── 3. Install binaries ──────────────────────────────────────────────────────
info "Installing scripts..."
install -m 755 "$SCRIPT_DIR/scripts/wifi-manager.sh" /usr/local/bin/wifi-manager
install -m 755 "$SCRIPT_DIR/web/wifi-portal.py"       /usr/local/bin/wifi-portal.py

# ─── 4. Install systemd units ────────────────────────────────────────────────
info "Installing systemd units..."
install -m 644 "$SCRIPT_DIR/systemd/rpi-wifi-manager.service" \
               /etc/systemd/system/rpi-wifi-manager.service
install -m 644 "$SCRIPT_DIR/systemd/rpi-wifi-portal.service"  \
               /etc/systemd/system/rpi-wifi-portal.service

# ─── 5. Run setup (creates /etc/rpi-wifi-manager/config, NM profile) ─────────
info "Running initial setup..."
wifi-manager setup

# ─── 6. Enable & start ───────────────────────────────────────────────────────
info "Enabling services..."
systemctl daemon-reload
systemctl enable rpi-wifi-manager.service
systemctl enable rpi-wifi-portal.service

echo ""
echo -e "${GREEN}Installation complete!${NC}"
echo ""
echo "  AP SSID  : RPI-$(hostname -s)-Setup"
echo "  AP Pass  : raspberry"
echo "  Portal   : http://192.168.4.1  (when hotspot is active)"
echo ""
echo "  Edit config : sudo nano /etc/rpi-wifi-manager/config"
echo "  Start now   : sudo systemctl start rpi-wifi-manager"
echo "  View logs   : sudo journalctl -u rpi-wifi-manager -f"
echo "  Status      : sudo wifi-manager status"
echo ""
echo "  Reboot for full effect: sudo reboot"
echo ""
