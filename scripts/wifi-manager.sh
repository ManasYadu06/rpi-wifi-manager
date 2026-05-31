#!/usr/bin/env bash
# =============================================================================
# rpi-wifi-manager  —  Production WiFi Manager for Raspberry Pi
# =============================================================================
set -uo pipefail

# ─── Config defaults ──────────────────────────────────────────────────────────
IFACE="${IFACE:-wlan0}"
AP_SSID="${AP_SSID:-RPI-$(hostname -s)-Setup}"
AP_PASS="${AP_PASS:-raspberry}"
AP_CHANNEL="${AP_CHANNEL:-6}"
AP_IP="${AP_IP:-192.168.4.1}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-25}"
RECONNECT_RETRIES="${RECONNECT_RETRIES:-5}"
RECONNECT_BACKOFF="${RECONNECT_BACKOFF:-5}"
WATCHDOG_INTERVAL="${WATCHDOG_INTERVAL:-60}"
COUNTRY="${COUNTRY:-IN}"
STATE_FILE="/run/rpi-wifi-manager/state"
LOG_TAG="rpi-wifi-manager"
CONFIG_DIR="/etc/rpi-wifi-manager"
NM_CON_HOTSPOT="rpi-hotspot"

# ─── Load user config ─────────────────────────────────────────────────────────
[[ -f "$CONFIG_DIR/config" ]] && source "$CONFIG_DIR/config"

# ─── Logging ──────────────────────────────────────────────────────────────────
log()  { logger -t "$LOG_TAG" "$*" 2>/dev/null; echo "[$(date '+%H:%M:%S')] $*"; }
info() { log "INFO  $*"; }
warn() { log "WARN  $*"; }
err()  { log "ERROR $*"; }
die()  { err "$*"; exit 1; }

# ─── sd_notify — only from main PID ──────────────────────────────────────────
_MAIN_PID=$$
sd_notify() {
    [[ "$$" != "$_MAIN_PID" ]] && return 0
    command -v systemd-notify &>/dev/null && systemd-notify "$@" 2>/dev/null || true
}

# ─── State ────────────────────────────────────────────────────────────────────
set_state() {
    mkdir -p "$(dirname "$STATE_FILE")"
    echo "$1" > "$STATE_FILE"
    info "State → $1"
    sd_notify "STATUS=$1"
}
get_state() { [[ -f "$STATE_FILE" ]] && cat "$STATE_FILE" || echo "INIT"; }

# ─── Interface helpers ────────────────────────────────────────────────────────
iface_exists() { ip link show "$IFACE" &>/dev/null; }

clear_rfkill() {
    command -v rfkill &>/dev/null || return 0
    rfkill unblock wifi 2>/dev/null || true
    rfkill unblock all  2>/dev/null || true
}

set_regulatory() {
    local country
    country=$(iw reg get 2>/dev/null | awk '/country/{print $2; exit}' | tr -d ':')
    if [[ -z "$country" || "$country" == "00" ]]; then
        iw reg set "$COUNTRY" 2>/dev/null || true
        info "Regulatory domain set: $COUNTRY"
    fi
}

# ─── Connection health — no ping, uses NM state ───────────────────────────────
is_connected() {
    local state
    state=$(nmcli -t -f DEVICE,STATE device status 2>/dev/null \
            | awk -F: -v d="$IFACE" '$1==d{print $2}')
    [[ "$state" == "connected" ]]
}

# ─── Hotspot ──────────────────────────────────────────────────────────────────
hotspot_active() {
    nmcli -t -f NAME connection show --active 2>/dev/null | grep -qx "$NM_CON_HOTSPOT"
}

hotspot_create() {
    info "Creating hotspot profile: SSID=$AP_SSID"
    nmcli connection delete "$NM_CON_HOTSPOT" 2>/dev/null || true
    nmcli connection add \
        type wifi ifname "$IFACE" con-name "$NM_CON_HOTSPOT" \
        autoconnect no ssid "$AP_SSID" -- \
        wifi.mode ap wifi.band bg wifi.channel "$AP_CHANNEL" \
        wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$AP_PASS" \
        ipv4.method shared ipv4.addresses "${AP_IP}/24" \
        ipv6.method disabled 2>/dev/null \
    && info "Hotspot profile created" || err "Failed to create hotspot profile"
}

hotspot_stop() {
    nmcli connection down "$NM_CON_HOTSPOT" 2>/dev/null || true
}

hotspot_start() {
    set_state "STARTING_HOTSPOT"
    hotspot_stop
    # Bring interface up before NM activates — reduces beacon delay
    clear_rfkill
    ip link set "$IFACE" up 2>/dev/null || true

    if ! nmcli connection show "$NM_CON_HOTSPOT" &>/dev/null; then
        hotspot_create
    fi

    if nmcli connection up "$NM_CON_HOTSPOT" 2>/dev/null; then
        info "Hotspot active: SSID='$AP_SSID'  IP=$AP_IP  Pass='$AP_PASS'"
        set_state "HOTSPOT"
        sd_notify "READY=1"
        return 0
    else
        err "Failed to start hotspot"
        set_state "DISCONNECTED"
        return 1
    fi
}

# ─── Scanning ─────────────────────────────────────────────────────────────────
scan_networks() {
    info "Scanning for WiFi networks..."
    local was_hotspot=false

    if hotspot_active; then
        info "Pausing hotspot for scan..."
        hotspot_stop
        was_hotspot=true
        sleep 2
    fi

    nmcli device set "$IFACE" managed yes 2>/dev/null || true
    nmcli device wifi rescan ifname "$IFACE" 2>/dev/null || true
    sleep 4

    local results
    results=$(nmcli -t -f SSID,SIGNAL,SECURITY,BSSID device wifi list \
              ifname "$IFACE" 2>/dev/null | grep -v '^--\|^$' \
              | sort -t: -k2 -rn | head -20) || true

    if [[ -z "$results" ]]; then
        warn "nmcli scan empty, trying iwlist..."
        results=$(iwlist "$IFACE" scan 2>/dev/null \
                  | awk -F'"' '/ESSID/{if($2!="")print $2}' | sort -u | head -20) || true
    fi

    [[ -n "$results" ]] && info "Scan found networks" || warn "No networks found"

    if $was_hotspot; then
        info "Resuming hotspot..."
        hotspot_start &>/dev/null || true
    fi

    echo "${results:-}"
}

scan_to_json() {
    scan_networks > /dev/null 2>&1

    local entries
    entries=$(nmcli -t -f SSID,SIGNAL,SECURITY,BSSID device wifi list \
              ifname "$IFACE" 2>/dev/null | grep -v '^--\|^$' \
              | sort -t: -k2 -rn | head -20) || true

    [[ -z "$entries" ]] && { echo "[]"; return; }

    local out="[" count=0
    while IFS=: read -r ssid signal security bssid _; do
        [[ -z "$ssid" ]] && continue
        ssid="${ssid//\"/\\\"}"
        out+=$(printf '{"ssid":"%s","signal":%s,"security":"%s","bssid":"%s"},' \
               "$ssid" "${signal:-0}" "${security:-OPEN}" "${bssid:-}")
        count=$((count + 1))
    done <<< "$entries"
    out="${out%,}]"
    info "scan_to_json: $count networks"
    echo "$out"
}

# ─── WiFi client connect ──────────────────────────────────────────────────────
wifi_connect() {
    local ssid="$1"
    local pass="${2:-}"
    # Per-SSID profile name so multiple networks are remembered
    local con_name="rpi-wifi-${ssid// /_}"

    info "Connecting to SSID='$ssid'"
    set_state "CONNECTING"

    # Stop hotspot — single radio can't be AP and client simultaneously
    hotspot_stop
    sleep 1

    # Delete stale profile for this SSID only, then connect fresh
    nmcli connection delete "$con_name" 2>/dev/null || true

    local rc=0
    if [[ -n "$pass" ]]; then
        nmcli --wait "$CONNECT_TIMEOUT" device wifi connect "$ssid" \
            password "$pass" ifname "$IFACE" name "$con_name" 2>/dev/null || rc=$?
    else
        nmcli --wait "$CONNECT_TIMEOUT" device wifi connect "$ssid" \
            ifname "$IFACE" name "$con_name" 2>/dev/null || rc=$?
    fi

    if [[ $rc -eq 0 ]] && is_connected; then
        local ip
        ip=$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet /{print $2}' | head -1)
        info "Connected! SSID='$ssid'  IP=$ip"
        set_state "CONNECTED"
        sd_notify "READY=1"
        # Save and set high priority so it auto-connects next boot
        nmcli connection modify "$con_name" \
            connection.autoconnect yes \
            connection.autoconnect-priority 10 2>/dev/null || true
        return 0
    else
        err "Failed to connect to '$ssid' — wrong password or out of range"
        nmcli connection delete "$con_name" 2>/dev/null || true
        set_state "DISCONNECTED"
        # Restart hotspot immediately so user can try again from portal
        info "Restarting hotspot after failed connect..."
        hotspot_start || true
        return 1
    fi
}

# ─── Reconnect loop with exponential backoff ──────────────────────────────────
reconnect_loop() {
    local ssid="${1:-}"
    local pass="${2:-}"
    local attempt=0
    local backoff=$RECONNECT_BACKOFF

    while true; do
        attempt=$((attempt + 1))
        [[ $RECONNECT_RETRIES -gt 0 && $attempt -gt $RECONNECT_RETRIES ]] && {
            warn "Max retries ($RECONNECT_RETRIES) reached → hotspot"
            break
        }

        info "Reconnect attempt $attempt (backoff=${backoff}s)"
        set_state "RECONNECTING[$attempt]"

        if [[ -n "$ssid" ]]; then
            wifi_connect "$ssid" "$pass" && return 0
        else
            local rc=0
            nmcli --wait "$CONNECT_TIMEOUT" device connect "$IFACE" 2>/dev/null || rc=$?
            if [[ $rc -eq 0 ]] && is_connected; then
                local ip
                ip=$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet /{print $2}' | head -1)
                info "Reconnected. IP=$ip"
                set_state "CONNECTED"
                return 0
            fi
        fi

        sleep "$backoff"
        backoff=$((backoff * 2))
        [[ $backoff -gt 120 ]] && backoff=120
    done

    return 1
}

# ─── Watchdog ─────────────────────────────────────────────────────────────────
watchdog_loop() {
    info "Watchdog started (interval=${WATCHDOG_INTERVAL}s)"
    local hotspot_scan_counter=0

    while true; do
        sleep "$WATCHDOG_INTERVAL"
        sd_notify "WATCHDOG=1"

        local state
        state=$(get_state)

        if [[ "$state" == "CONNECTED" ]]; then
            # Check if connection dropped
            if ! is_connected; then
                warn "Connection lost — reconnecting..."
                set_state "DISCONNECTED"
                if ! reconnect_loop; then
                    warn "All reconnect attempts failed → hotspot"
                    hotspot_start || true
                fi
            fi

        elif [[ "$state" == "HOTSPOT" ]]; then
            # Periodically scan for known networks while in hotspot mode
            # Covers: router boots late, arena deploy, temporary outage
            hotspot_scan_counter=$((hotspot_scan_counter + 1))
            if [[ $((hotspot_scan_counter % 3)) -eq 0 ]]; then
                info "Hotspot mode: scanning for known networks..."

                # Must pause hotspot to scan on single radio
                hotspot_stop
                sleep 2
                nmcli device wifi rescan ifname "$IFACE" 2>/dev/null || true
                sleep 4

                # Get visible SSIDs
                local visible_ssids
                visible_ssids=$(nmcli -t -f SSID device wifi list \
                                ifname "$IFACE" 2>/dev/null \
                                | grep -v '^--\|^$' | sort -u) || true

                # Get saved NM connection names (excluding hotspot)
                local saved_ssids
                saved_ssids=$(nmcli -t -f NAME,TYPE connection show 2>/dev/null \
                              | awk -F: '/wireless/{print $1}' \
                              | grep -v "^${NM_CON_HOTSPOT}$") || true

                # Check for any saved SSID now in range
                local found_ssid=""
                while IFS= read -r saved; do
                    [[ -z "$saved" ]] && continue
                    # saved connection name may differ from SSID; get the SSID
                    local saved_net_ssid
                    saved_net_ssid=$(nmcli -t -f connection.ssid connection show \
                                    "$saved" 2>/dev/null | cut -d: -f2) || true
                    if echo "$visible_ssids" | grep -qF "${saved_net_ssid:-$saved}"; then
                        found_ssid="$saved_net_ssid"
                        break
                    fi
                done <<< "$saved_ssids"

                if [[ -n "$found_ssid" ]]; then
                    info "Known network '$found_ssid' in range — connecting..."
                    local rc=0
                    nmcli --wait "$CONNECT_TIMEOUT" device connect "$IFACE" 2>/dev/null || rc=$?
                    if [[ $rc -eq 0 ]] && is_connected; then
                        local ip
                        ip=$(ip -4 addr show "$IFACE" 2>/dev/null \
                             | awk '/inet /{print $2}' | head -1)
                        info "Auto-connected to '$found_ssid'. IP=$ip"
                        set_state "CONNECTED"
                        hotspot_scan_counter=0
                    else
                        warn "Connect to '$found_ssid' failed — resuming hotspot"
                        hotspot_start || true
                    fi
                else
                    info "No known networks in range — resuming hotspot"
                    hotspot_start || true
                fi
            fi
        fi
    done
}

# ─── Setup ────────────────────────────────────────────────────────────────────
setup_system() {
    info "=== rpi-wifi-manager setup ==="
    AP_SSID="RPI-$(hostname -s)-Setup"
    info "AP SSID: $AP_SSID"

    nmcli general status &>/dev/null || die "NetworkManager not running"

    systemctl disable wpa_supplicant 2>/dev/null || true
    systemctl stop    wpa_supplicant 2>/dev/null || true

    cat > /etc/NetworkManager/conf.d/rpi-wifi-manager.conf << 'NM_CONF'
[main]
plugins=ifupdown,keyfile

[ifupdown]
managed=true

[device]
wifi.scan-rand-mac-address=no
wifi.backend=wpa_supplicant
NM_CONF
    info "Wrote NM config"

    mkdir -p "$CONFIG_DIR"
    if [[ ! -f "$CONFIG_DIR/config" ]]; then
        cat > "$CONFIG_DIR/config" << CONF
# rpi-wifi-manager — edit then: sudo systemctl restart rpi-wifi-manager
IFACE=wlan0
AP_SSID=RPI-$(hostname -s)-Setup
AP_PASS=raspberry
AP_CHANNEL=6
AP_IP=192.168.4.1
COUNTRY=IN
CONNECT_TIMEOUT=25
RECONNECT_RETRIES=5
RECONNECT_BACKOFF=5
WATCHDOG_INTERVAL=60
CONF
        info "Created $CONFIG_DIR/config"
    fi

    hotspot_create
    systemctl daemon-reload
    systemctl enable rpi-wifi-manager.service
    info "Setup complete. Run: sudo systemctl start rpi-wifi-manager"
}

# ─── Main daemon ──────────────────────────────────────────────────────────────
run_daemon() {
    info "=== rpi-wifi-manager daemon starting ==="
    sd_notify "STATUS=Initializing"

    # Wait for NM to be fully ready before doing anything
    local nm_wait=0
    until nmcli general status 2>/dev/null | grep -qE "connected|disconnected|asleep"; do
        nm_wait=$((nm_wait + 1))
        [[ $nm_wait -gt 40 ]] && die "NetworkManager not ready after 40s"
        info "Waiting for NetworkManager... (${nm_wait}s)"
        sleep 1
    done
    info "NetworkManager ready"

    iface_exists || die "Interface $IFACE not found"
    clear_rfkill
    set_regulatory
    set_state "SCANNING"

    # Give NM a moment to auto-connect to any saved networks it already knows
    sleep 5
    if is_connected; then
        local ip
        ip=$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet /{print $2}' | head -1)
        info "Already connected (NM auto-connect). IP=$ip"
        set_state "CONNECTED"
        sd_notify "READY=1"
    else
        # Trigger an explicit scan and connection attempt
        nmcli device wifi rescan ifname "$IFACE" 2>/dev/null || true
        sleep 3
        local rc=0
        nmcli --wait "$CONNECT_TIMEOUT" device connect "$IFACE" 2>/dev/null || rc=$?
        if [[ $rc -eq 0 ]] && is_connected; then
            local ip
            ip=$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet /{print $2}' | head -1)
            info "Connected to saved network. IP=$ip"
            set_state "CONNECTED"
            sd_notify "READY=1"
        else
            info "No saved network available → starting hotspot"
            hotspot_start || true
        fi
    fi

    # Start watchdog
    watchdog_loop &
    WATCHDOG_PID=$!

    trap 'info "Shutting down..."; kill "$WATCHDOG_PID" 2>/dev/null; hotspot_stop; set_state "STOPPED"; exit 0' SIGTERM SIGINT

    wait "$WATCHDOG_PID"
}

# ─── CLI ──────────────────────────────────────────────────────────────────────
usage() {
    cat << EOF
Usage: $(basename "$0") <command> [args]

Commands:
  daemon              Run as systemd daemon
  setup               Install config + systemd units
  status              Show state, IP, SSID
  scan                Scan for nearby networks
  scan-json           Scan and output JSON (used by portal)
  connect <ssid> [pw] Connect to a WiFi network
  hotspot             Start hotspot now
  reconnect           Force reconnect attempt
  config              Show active config
EOF
}

cmd="${1:-help}"
shift || true

case "$cmd" in
    daemon)    run_daemon ;;
    setup)     setup_system ;;
    status)
        state=$(get_state)
        ip=$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet /{print $2}' | head -1)
        ssid=$(nmcli -t -f active,ssid dev wifi 2>/dev/null \
               | awk -F: '/^yes/{print $2}' | head -1)
        printf "State  : %s\nSSID   : %s\nIP     : %s\nIface  : %s\n" \
               "$state" "${ssid:-none}" "${ip:-none}" "$IFACE"
        ;;
    scan)      scan_networks ;;
    scan-json) scan_to_json ;;
    connect)
        ssid="${1:-}"; shift || true
        pass="${1:-}"; shift || true
        [[ -z "$ssid" ]] && die "Usage: $0 connect <ssid> [password]"
        wifi_connect "$ssid" "$pass"
        ;;
    hotspot)   hotspot_start ;;
    reconnect)
        set_state "RECONNECTING[manual]"
        reconnect_loop || hotspot_start
        ;;
    config)
        echo "IFACE=$IFACE  AP_SSID=$AP_SSID  AP_IP=$AP_IP"
        echo "COUNTRY=$COUNTRY  CHANNEL=$AP_CHANNEL"
        echo "CONNECT_TIMEOUT=$CONNECT_TIMEOUT  RETRIES=$RECONNECT_RETRIES"
        ;;
    help|--help|-h|*) usage ;;
esac
