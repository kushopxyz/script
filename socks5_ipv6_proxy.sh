#!/usr/bin/env bash
# ==============================================================================
# IPv6 SOCKS5 Proxy Auto-Setup Script
# Version: 3.0.0
#
# Handles: Linode, Vultr, DigitalOcean, Hetzner, and any VPS with a /64 IPv6
# Engine:  microsocks + systemd (each proxy = supervised service)
#
# Usage:
#   ./socks5_ipv6_proxy.sh              # Auto-detect and create proxies
#   ./socks5_ipv6_proxy.sh -n 20        # Create exactly 20 proxies
#   ./socks5_ipv6_proxy.sh -p 20000     # Ports start at 20000
#   ./socks5_ipv6_proxy.sh -r           # Remove everything
# ==============================================================================
SCRIPT_VERSION="3.0.0"

set -Eeuo pipefail
trap 'echo -e "\033[0;31m[ERROR]\033[0m Line $LINENO: $BASH_COMMAND" >&2' ERR

# ---- Self-fix CRLF (script may have been edited on Windows) ----
if grep -qP '\r' "$0" 2>/dev/null; then
    sed -i 's/\r$//' "$0"
    exec bash "$0" "$@"
fi

# ======================== CONFIGURATION ========================
WORK_DIR="/root/socks5-ipv6"
INSTANCES_DIR="${WORK_DIR}/instances"
OUTPUT_FILE="/root/socks5_ipv6_proxies.txt"
START_PORT=10000

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[ OK ]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }

check_root() {
    [[ $EUID -eq 0 ]] || log_error "This script must be run as root/sudo."
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_ID="${ID:-unknown}"
    else
        OS_ID="unknown"
    fi
    case "$OS_ID" in
        ubuntu|debian|pop) PKG="apt" ;;
        centos|almalinux|rocky|rhel|fedora) PKG="dnf" ;;
        *) log_error "Unsupported OS: $OS_ID" ;;
    esac
}

# ======================== PREREQUISITES ========================
install_deps() {
    log_info "Installing dependencies..."
    case "$PKG" in
        apt)
            apt-get update -qq >/dev/null 2>&1
            apt-get install -y -qq curl net-tools openssl python3 iproute2 ndisc6 >/dev/null 2>&1
            apt-get install -y -qq microsocks >/dev/null 2>&1 || true
            ;;
        dnf)
            dnf install -y -q curl net-tools openssl python3 iproute gcc git make ndisc6 >/dev/null 2>&1 || true
            ;;
    esac

    if ! command -v microsocks &>/dev/null; then
        log_info "Building microsocks from source..."
        local build_dir="/tmp/microsocks-build"
        rm -rf "$build_dir"
        git clone --depth=1 https://github.com/rofl0r/microsocks.git "$build_dir" 2>/dev/null
        make -C "$build_dir" -j"$(nproc)" >/dev/null 2>&1
        cp "$build_dir/microsocks" /usr/local/bin/microsocks
        chmod +x /usr/local/bin/microsocks
        rm -rf "$build_dir"
    fi

    command -v microsocks &>/dev/null || log_error "Failed to install microsocks."
    MICROSOCKS_BIN=$(command -v microsocks)
    log_ok "Dependencies ready (microsocks: ${MICROSOCKS_BIN})"
}

# ======================== ENSURE IPv6 IS UP ========================
ensure_ipv6() {
    log_info "Ensuring IPv6 connectivity..."

    # Find the main network interface (has link-local or default route)
    local iface
    iface=$(ip -6 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
    if [[ -z "$iface" ]]; then
        iface=$(ip -o link show up | awk -F': ' '!/lo/{print $2}' | head -1)
    fi
    [[ -n "$iface" ]] || log_error "No active network interface found."

    # Enable SLAAC (accept_ra=2 works even with forwarding=1)
    sysctl -w net.ipv6.conf.all.accept_ra=2 &>/dev/null || true
    sysctl -w "net.ipv6.conf.${iface}.accept_ra=2" &>/dev/null || true
    sysctl -w "net.ipv6.conf.${iface}.autoconf=1" &>/dev/null || true
    sysctl -w "net.ipv6.conf.${iface}.disable_ipv6=0" &>/dev/null || true

    # Check if we already have a global IPv6
    if ip -6 addr show dev "$iface" scope global 2>/dev/null | grep -q "inet6"; then
        log_ok "Global IPv6 already present on ${iface}"
        return 0
    fi

    # No global IPv6 — try router discovery
    log_info "No global IPv6 found. Trying router discovery on ${iface}..."

    local ra_output gw=""
    if command -v rdisc6 &>/dev/null; then
        ra_output=$(rdisc6 -1 "$iface" 2>/dev/null || true)
        gw=$(echo "$ra_output" | grep -oP 'from \K[0-9a-f:]+' | head -1 || true)
    fi

    # Wait up to 15s for SLAAC to assign address
    local waited=0
    while (( waited < 15 )); do
        if ip -6 addr show dev "$iface" scope global 2>/dev/null | grep -q "inet6"; then
            log_ok "IPv6 obtained via SLAAC on ${iface}"
            # Add default route if missing
            if ! ip -6 route show default 2>/dev/null | grep -q "default"; then
                if [[ -n "${gw:-}" ]]; then
                    ip -6 route add default via "$gw" dev "$iface" 2>/dev/null || true
                fi
            fi
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done

    # SLAAC failed — try adding default route manually and trigger again
    if [[ -n "${gw:-}" ]]; then
        ip -6 route add default via "$gw" dev "$iface" 2>/dev/null || true
        sleep 3
        if ip -6 addr show dev "$iface" scope global 2>/dev/null | grep -q "inet6"; then
            log_ok "IPv6 obtained after adding gateway ${gw}"
            return 0
        fi
    fi

    log_error "Cannot obtain global IPv6 on ${iface}.
  Please ensure IPv6 is enabled in your VPS provider dashboard and reboot."
}

# ======================== IPv6 DETECTION ========================
detect_ipv6() {
    log_info "Detecting IPv6 configuration..."

    command -v python3 &>/dev/null || log_error "python3 is required but not found."

    IPV6_IFACE=$(ip -6 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
    if [[ -z "$IPV6_IFACE" ]]; then
        IPV6_IFACE=$(ip -6 addr show scope global | awk -F'[ :]+' '/^[0-9]/{print $2}' | head -1)
    fi
    [[ -n "$IPV6_IFACE" ]] || log_error "Cannot detect IPv6 network interface."

    local all_addrs best_line
    all_addrs=$(ip -6 addr show dev "$IPV6_IFACE" scope global 2>/dev/null \
        | grep -oP 'inet6 \K[0-9a-f:]+/[0-9]+' || true)
    [[ -n "$all_addrs" ]] || log_error "No global IPv6 address found on ${IPV6_IFACE}."

    best_line=$(echo "$all_addrs" | awk -F'/' '{print $2, $0}' | sort -n | awk '{print $2}' | head -1)
    local best_prefix="${best_line##*/}"

    if (( best_prefix > 64 )); then
        log_error "No usable IPv6 subnet on ${IPV6_IFACE} (smallest prefix: /${best_prefix})."
    fi

    IPV6_ADDR="${best_line%%/*}"
    IPV6_PREFIX="$best_prefix"

    IPV6_NET=$(python3 -c "
import ipaddress
net = ipaddress.IPv6Network('${IPV6_ADDR}/${IPV6_PREFIX}', strict=False)
print(str(net.network_address))
")

    # Detect gateway
    IPV6_GW=$(ip -6 route show default | awk '{print $3}' | head -1)

    log_ok "Interface: ${IPV6_IFACE}"
    log_ok "Address  : ${IPV6_ADDR}/${IPV6_PREFIX}"
    log_ok "Subnet   : ${IPV6_NET}/${IPV6_PREFIX}"
    log_ok "Gateway  : ${IPV6_GW:-unknown}"
}

check_ipv6_connectivity() {
    log_info "Testing IPv6 connectivity..."
    if ping -6 -c 1 -W 5 google.com &>/dev/null; then
        log_ok "IPv6 internet reachable"
    elif ping -6 -c 1 -W 5 2001:4860:4860::8888 &>/dev/null; then
        log_ok "IPv6 connectivity OK (DNS may not resolve AAAA)"
    else
        log_warn "IPv6 ping failed — firewall may block ICMP, continuing..."
    fi
}

# ======================== IPv6 GENERATION ========================
generate_random_ipv6() {
    python3 -c "
import ipaddress, secrets
net = ipaddress.IPv6Network('${IPV6_NET}/${IPV6_PREFIX}', strict=False)
bits = 128 - net.prefixlen
host_id = secrets.randbelow(2**bits - 2) + 1
addr = net.network_address + host_id
print(str(addr))
"
}

# ======================== RAM -> PROXY COUNT ========================
calculate_proxy_count() {
    TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
    TOTAL_CORES=$(nproc 2>/dev/null || echo 1)

    if   (( TOTAL_RAM < 512  )); then PROXY_COUNT=5
    elif (( TOTAL_RAM < 1024 )); then PROXY_COUNT=50
    elif (( TOTAL_RAM < 2048 )); then PROXY_COUNT=100
    elif (( TOTAL_RAM < 4096 )); then PROXY_COUNT=200
    elif (( TOTAL_RAM < 8192 )); then PROXY_COUNT=300
    else PROXY_COUNT=500
    fi

    log_info "System  : ${TOTAL_RAM}MB RAM, ${TOTAL_CORES} CPU cores"
    log_info "Creating: ${PROXY_COUNT} proxies"
}

# ======================== FORCE IPv6 PREFERENCE ========================
setup_ipv6_preference() {
    log_info "Configuring system to prefer IPv6 for DNS resolution..."

    cat > /etc/gai.conf <<'EOF'
label  ::1/128       0
label  ::/0          1
label  2002::/16     2
label ::/96          3
label ::ffff:0:0/96  4
precedence  ::1/128       50
precedence  ::/0          40
precedence  2002::/16     30
precedence ::/96          20
precedence ::ffff:0:0/96  10
EOF

    log_ok "IPv6 preferred over IPv4 (gai.conf)"
}

# ======================== CREATE PROXIES ========================
setup_proxies() {
    if [[ -d "$WORK_DIR" ]]; then
        log_warn "Previous installation found. Cleaning..."
        stop_all_proxies
        rm -rf "$WORK_DIR"
    fi

    mkdir -p "$WORK_DIR" "$INSTANCES_DIR"

    PUBLIC_IPV4=$(curl -s -4 -m 5 ifconfig.me 2>/dev/null || curl -s -4 -m 5 api.ipify.org 2>/dev/null || echo "N/A")

    > "$WORK_DIR/proxies.conf"
    > "${WORK_DIR}/url.txt"
    > "${WORK_DIR}/ipport.txt"

    sysctl -w "net.ipv6.conf.${IPV6_IFACE}.accept_dad=0" &>/dev/null || true
    sysctl -w "net.ipv6.conf.${IPV6_IFACE}.dad_transmits=0" &>/dev/null || true

    USED_IPS=()

    for ((i = 1; i <= PROXY_COUNT; i++)); do
        local ipv6
        while true; do
            ipv6=$(generate_random_ipv6)
            local dup=0
            for u in "${USED_IPS[@]:-}"; do
                [[ "$u" == "$ipv6" ]] && dup=1 && break
            done
            (( dup == 0 )) && break
        done
        USED_IPS+=("$ipv6")

        local user pass port
        user=$(openssl rand -hex 3)
        pass=$(openssl rand -hex 4)
        port=$(( START_PORT + i - 1 ))

        if ip -6 addr add "${ipv6}/64" dev "$IPV6_IFACE" nodad 2>/dev/null || \
           ip -6 addr add "${ipv6}/64" dev "$IPV6_IFACE" 2>/dev/null; then

            echo "${port}|${user}|${pass}|${ipv6}" >> "$WORK_DIR/proxies.conf"

            printf 'PORT=%s\nSOCKS_USER=%s\nSOCKS_PASS=%s\nIPV6=%s\n' \
                "$port" "$user" "$pass" "$ipv6" > "${INSTANCES_DIR}/${port}.env"

            echo "socks5://${user}:${pass}@${PUBLIC_IPV4}:${port}" >> "${WORK_DIR}/url.txt"
            echo "socks5://${PUBLIC_IPV4}:${port}:${user}:${pass}" >> "${WORK_DIR}/ipport.txt"
            printf "  ${GREEN}[%3d/%d]${NC} :%d -> %s\n" "$i" "$PROXY_COUNT" "$port" "$ipv6"
        else
            printf "  ${RED}[%3d/%d]${NC} :%d -> %s (FAILED)\n" "$i" "$PROXY_COUNT" "$port" "$ipv6"
        fi
    done

    PROXY_COUNT=$(wc -l < "$WORK_DIR/proxies.conf")

    {
        echo "# ===== socks5://user:pass@ip:port ====="
        cat "${WORK_DIR}/url.txt"
        echo ""
        echo "# ===== socks5://IP:Port:User:Pass ====="
        cat "${WORK_DIR}/ipport.txt"
    } > "$OUTPUT_FILE"

    log_info "Waiting for IPv6 addresses to settle..."
    sleep 3
}

# ======================== SOURCE ROUTING ========================
setup_ipv6_routing() {
    log_info "Setting up per-address source routing..."

    if [[ -z "${IPV6_GW:-}" ]]; then
        IPV6_GW=$(ip -6 route show default | awk '{print $3}' | head -1)
    fi
    if [[ -z "${IPV6_GW:-}" ]]; then
        log_warn "No IPv6 gateway — source routing skipped."
        return
    fi

    local table_id=100
    for ipv6 in "${USED_IPS[@]}"; do
        table_id=$((table_id + 1))
        ip -6 rule del from "$ipv6" table "$table_id" 2>/dev/null || true
        ip -6 rule add from "$ipv6" table "$table_id" prio "$table_id"
        ip -6 route replace default via "$IPV6_GW" dev "$IPV6_IFACE" src "$ipv6" table "$table_id" 2>/dev/null || true
    done

    log_ok "Source routing: ${#USED_IPS[@]} addresses (tables 101-${table_id})"
}

# ======================== NDP PROXY ========================
setup_ndp() {
    log_info "Configuring NDP proxy..."

    sysctl -w net.ipv6.conf.all.proxy_ndp=1 &>/dev/null
    sysctl -w "net.ipv6.conf.${IPV6_IFACE}.proxy_ndp=1" &>/dev/null

    cat > /etc/sysctl.d/99-socks5-ndp.conf <<SYSCTL
net.ipv6.conf.all.proxy_ndp=1
net.ipv6.conf.${IPV6_IFACE}.proxy_ndp=1
net.ipv6.conf.all.accept_ra=2
net.ipv6.conf.${IPV6_IFACE}.accept_ra=2
SYSCTL

    for ipv6 in "${USED_IPS[@]}"; do
        ip -6 neigh add proxy "$ipv6" dev "$IPV6_IFACE" 2>/dev/null || true
    done

    log_ok "NDP proxy enabled for ${#USED_IPS[@]} addresses"
}

# ======================== START / STOP ========================
start_all_proxies() {
    log_info "Starting ${PROXY_COUNT} microsocks services..."

    local -a units=()
    while IFS='|' read -r port _user _pass _ipv6; do
        units+=("microsocks@${port}.service")
    done < "$WORK_DIR/proxies.conf"

    (( ${#units[@]} > 0 )) || log_error "No proxies to start."

    systemctl enable "${units[@]}" &>/dev/null 2>&1
    systemctl start "${units[@]}" 2>/dev/null || true

    sleep 3

    local listening=0 failed=0
    for unit in "${units[@]}"; do
        if systemctl is-active --quiet "$unit" 2>/dev/null; then
            listening=$((listening + 1))
        else
            failed=$((failed + 1))
        fi
    done

    ACTUAL_STARTED=$listening
    ACTUAL_FAILED=$failed

    if (( failed > 0 )); then
        log_warn "${listening}/${#units[@]} running (${failed} failed — systemd will auto-restart)"
    else
        log_ok "All ${listening} proxies running"
    fi
}

stop_all_proxies() {
    if [[ -f "$WORK_DIR/proxies.conf" ]]; then
        local -a units=()
        while IFS='|' read -r port _user _pass _ipv6; do
            units+=("microsocks@${port}.service")
        done < "$WORK_DIR/proxies.conf"
        if (( ${#units[@]} > 0 )); then
            systemctl stop "${units[@]}" 2>/dev/null || true
            systemctl disable "${units[@]}" 2>/dev/null || true
        fi
    fi
    pkill -f "microsocks -p" 2>/dev/null || true
    sleep 1
    pkill -9 -f "microsocks -p" 2>/dev/null || true
}

# ======================== PERSISTENCE ========================
make_persistent() {
    log_info "Making configuration persistent..."

    local gw
    gw=$(ip -6 route show default | awk '{print $3}' | head -1)

    # ---- Boot script ----
    cat > /usr/local/bin/socks5-ipv6-setup.sh <<HEADER
#!/bin/bash
# Auto-generated by socks5_ipv6_proxy.sh v${SCRIPT_VERSION}
sysctl -w net.ipv6.conf.all.accept_ra=2 &>/dev/null || true
sysctl -w net.ipv6.conf.${IPV6_IFACE}.accept_ra=2 &>/dev/null || true
sysctl -w net.ipv6.conf.${IPV6_IFACE}.accept_dad=0 &>/dev/null || true
sysctl -w net.ipv6.conf.${IPV6_IFACE}.dad_transmits=0 &>/dev/null || true
sleep 5
HEADER

    local table_id=100
    for ipv6 in "${USED_IPS[@]}"; do
        table_id=$((table_id + 1))
        cat >> /usr/local/bin/socks5-ipv6-setup.sh <<LINE
ip -6 addr add ${ipv6}/64 dev ${IPV6_IFACE} nodad 2>/dev/null || true
ip -6 neigh add proxy ${ipv6} dev ${IPV6_IFACE} 2>/dev/null || true
ip -6 rule add from ${ipv6} table ${table_id} prio ${table_id} 2>/dev/null || true
ip -6 route replace default via ${gw} dev ${IPV6_IFACE} src ${ipv6} table ${table_id} 2>/dev/null || true
LINE
    done
    chmod +x /usr/local/bin/socks5-ipv6-setup.sh

    # ---- Systemd: IPv6 setup ----
    cat > /etc/systemd/system/socks5-ipv6-setup.service <<UNIT
[Unit]
Description=SOCKS5 IPv6 Address Setup
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/socks5-ipv6-setup.sh

[Install]
WantedBy=multi-user.target
UNIT

    # ---- Systemd: microsocks template ----
    cat > /etc/systemd/system/microsocks@.service <<UNIT
[Unit]
Description=MicroSocks SOCKS5 proxy on port %i
After=socks5-ipv6-setup.service
Requires=socks5-ipv6-setup.service

[Service]
Type=simple
EnvironmentFile=${INSTANCES_DIR}/%i.env
ExecStart=${MICROSOCKS_BIN} -p \${PORT} -u \${SOCKS_USER} -P \${SOCKS_PASS} -b \${IPV6}
Restart=always
RestartSec=2
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable socks5-ipv6-setup.service &>/dev/null

    # ---- Watchdog ----
    setup_watchdog

    log_ok "Persistence configured"
}

# ======================== WATCHDOG ========================
setup_watchdog() {
    local gw
    gw=$(ip -6 route show default | awk '{print $3}' | head -1)

    cat > /usr/local/bin/socks5-ipv6-watchdog.sh <<WDEOF
#!/bin/bash
IFACE="${IPV6_IFACE}"
CONF="${WORK_DIR}/proxies.conf"
GW="${gw}"
RECOVERED=0
TID=100

[[ -f "\$CONF" ]] || exit 0

# Ensure SLAAC stays active
sysctl -w net.ipv6.conf.all.accept_ra=2 &>/dev/null || true
sysctl -w net.ipv6.conf.\${IFACE}.accept_ra=2 &>/dev/null || true

while IFS='|' read -r port user pass ipv6; do
    TID=\$((TID + 1))
    if ! ip -6 addr show dev "\$IFACE" | grep -q "\$ipv6"; then
        ip -6 addr add "\${ipv6}/64" dev "\$IFACE" nodad 2>/dev/null || true
        ip -6 neigh add proxy "\$ipv6" dev "\$IFACE" 2>/dev/null || true
        RECOVERED=\$((RECOVERED + 1))
    fi
    if ! ip -6 rule show | grep -q "from \$ipv6"; then
        ip -6 rule add from "\$ipv6" table "\$TID" prio "\$TID" 2>/dev/null || true
        ip -6 route replace default via "\$GW" dev "\$IFACE" src "\$ipv6" table "\$TID" 2>/dev/null || true
        RECOVERED=\$((RECOVERED + 1))
    fi
    if ! systemctl is-active --quiet "microsocks@\${port}.service" 2>/dev/null; then
        systemctl restart "microsocks@\${port}.service" 2>/dev/null || true
        RECOVERED=\$((RECOVERED + 1))
    fi
done < "\$CONF"

(( RECOVERED > 0 )) && logger -t socks5-watchdog "Recovered: \$RECOVERED items"
WDEOF

    chmod +x /usr/local/bin/socks5-ipv6-watchdog.sh

    cat > /etc/systemd/system/socks5-ipv6-watchdog.service <<WDSVC
[Unit]
Description=SOCKS5 IPv6 Watchdog

[Service]
Type=oneshot
ExecStart=/usr/local/bin/socks5-ipv6-watchdog.sh
WDSVC

    cat > /etc/systemd/system/socks5-ipv6-watchdog.timer <<WDTIMER
[Unit]
Description=SOCKS5 IPv6 Watchdog Timer

[Timer]
OnBootSec=120
OnUnitActiveSec=60
AccuracySec=10

[Install]
WantedBy=timers.target
WDTIMER

    systemctl daemon-reload
    systemctl enable --now socks5-ipv6-watchdog.timer &>/dev/null
    log_ok "Watchdog active (every 60s)"
}

# ======================== FIREWALL ========================
configure_firewall() {
    local first_port=$START_PORT
    local last_port=$(( START_PORT + PROXY_COUNT - 1 ))

    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow "${first_port}:${last_port}"/tcp &>/dev/null
        log_ok "UFW: opened ports ${first_port}-${last_port}"
    elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --add-port="${first_port}-${last_port}"/tcp &>/dev/null
        firewall-cmd --reload &>/dev/null
        log_ok "Firewalld: opened ports ${first_port}-${last_port}"
    else
        log_warn "No active firewall. Ensure ports ${first_port}-${last_port} are open."
    fi
}

# ======================== REMOVE ALL ========================
remove_all() {
    log_warn "Removing all IPv6 SOCKS5 proxies..."

    # Detect interface before cleanup
    local rm_iface
    rm_iface=$(ip -o link show up | awk -F': ' '!/lo/{print $2}' | head -1)

    stop_all_proxies
    log_ok "Proxies stopped"

    # Remove proxy IPv6 addresses (not the system SLAAC address)
    if [[ -f "$WORK_DIR/proxies.conf" ]]; then
        while IFS='|' read -r _port _user _pass ipv6; do
            ip -6 addr del "${ipv6}/64" dev "$rm_iface" 2>/dev/null || true
            ip -6 neigh del proxy "$ipv6" dev "$rm_iface" 2>/dev/null || true
        done < "$WORK_DIR/proxies.conf"
        log_ok "Proxy IPv6 addresses removed"
    fi

    # Remove source routing (tables 101-600)
    for tid in $(seq 101 600); do
        ip -6 rule del table "$tid" 2>/dev/null || true
        ip -6 route flush table "$tid" 2>/dev/null || true
    done
    log_ok "Source routing rules removed"

    # Remove systemd units
    systemctl disable --now socks5-ipv6-setup.service 2>/dev/null || true
    systemctl disable --now socks5-ipv6-watchdog.timer 2>/dev/null || true
    systemctl disable --now socks5-ipv6-watchdog.service 2>/dev/null || true
    rm -f /etc/systemd/system/socks5-ipv6-setup.service
    rm -f /etc/systemd/system/microsocks@.service
    rm -f /etc/systemd/system/socks5-ipv6-watchdog.service
    rm -f /etc/systemd/system/socks5-ipv6-watchdog.timer
    rm -f /usr/local/bin/socks5-ipv6-setup.sh
    rm -f /usr/local/bin/socks5-ipv6-watchdog.sh
    # Legacy
    rm -f /etc/systemd/system/socks5-ipv6.service
    rm -f /usr/local/bin/socks5-ipv6-start.sh
    systemctl daemon-reload 2>/dev/null || true
    log_ok "Systemd units removed"

    # Remove configs
    rm -f /etc/gai.conf
    rm -f /etc/netplan/60-socks5-ipv6.yaml
    netplan apply 2>/dev/null || true
    rm -f /etc/sysconfig/network-scripts/ifcfg-*-socks5-ipv6 2>/dev/null || true
    rm -f /etc/network/interfaces.d/socks5-ipv6 2>/dev/null || true

    # Remove sysctl but keep accept_ra=2
    rm -f /etc/sysctl.d/99-socks5-ndp.conf
    sysctl --system &>/dev/null || true

    # Restore IPv6 SLAAC
    if [[ -n "$rm_iface" ]]; then
        sysctl -w "net.ipv6.conf.all.accept_ra=2" &>/dev/null || true
        sysctl -w "net.ipv6.conf.${rm_iface}.accept_ra=2" &>/dev/null || true
        sysctl -w "net.ipv6.conf.${rm_iface}.autoconf=1" &>/dev/null || true
        log_ok "IPv6 SLAAC restored on ${rm_iface}"
    fi

    # Firewall cleanup
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        if [[ -f "$WORK_DIR/proxies.conf" ]] && [[ -s "$WORK_DIR/proxies.conf" ]]; then
            local fp lp
            fp=$(head -1 "$WORK_DIR/proxies.conf" | cut -d'|' -f1)
            lp=$(tail -1 "$WORK_DIR/proxies.conf" | cut -d'|' -f1)
            ufw delete allow "${fp}:${lp}/tcp" 2>/dev/null || true
        fi
    fi

    rm -rf "$WORK_DIR" "$OUTPUT_FILE" /run/socks5-ipv6

    log_ok "Cleanup complete. All proxies removed."
    exit 0
}

# ======================== VERIFY ========================
verify_proxies() {
    log_info "Verifying proxy functionality..."
    local test_line
    test_line=$(head -1 "$WORK_DIR/proxies.conf")
    local port user pass ipv6
    IFS='|' read -r port user pass ipv6 <<< "$test_line"

    local result
    result=$(curl -s -m 30 -x "socks5://${user}:${pass}@127.0.0.1:${port}" https://api64.ipify.org 2>/dev/null || true)

    if [[ "$result" == "$ipv6" ]]; then
        log_ok "PERFECT: outgoing IPv6 = ${result}"
    elif [[ -n "$result" ]]; then
        log_warn "Proxy works, outgoing IP: ${result} (expected ${ipv6})"
    else
        log_warn "Proxy verification timed out"
    fi
}

# ======================== SUMMARY ========================
show_summary() {
    local actual=${ACTUAL_STARTED:-$PROXY_COUNT}
    local fails=${ACTUAL_FAILED:-0}

    echo ""
    if (( fails == 0 )); then
        echo -e "${GREEN}=================================================================${NC}"
        echo -e "${GREEN}  ALL ${actual} IPv6 SOCKS5 PROXIES ARE RUNNING${NC}"
        echo -e "${GREEN}=================================================================${NC}"
    else
        echo -e "${YELLOW}=================================================================${NC}"
        echo -e "${YELLOW}  ${actual}/${PROXY_COUNT} RUNNING (${fails} FAILED — auto-restart)${NC}"
        echo -e "${YELLOW}=================================================================${NC}"
    fi
    echo ""

    echo -e "${CYAN}--- socks5://user:pass@ip:port ---${NC}"
    head -3 "${WORK_DIR}/url.txt"
    local remaining=$(( PROXY_COUNT - 3 ))
    (( remaining > 0 )) && echo "  ... (${remaining} more) ..."
    echo ""
    echo -e "${CYAN}--- socks5://IP:Port:User:Pass ---${NC}"
    head -3 "${WORK_DIR}/ipport.txt"
    (( remaining > 0 )) && echo "  ... (${remaining} more) ..."

    echo ""
    echo -e "${CYAN}Proxy files:${NC}"
    echo -e "  All formats : ${OUTPUT_FILE}"
    echo -e "  URL format  : ${WORK_DIR}/url.txt"
    echo -e "  IP:Port     : ${WORK_DIR}/ipport.txt"
    echo ""
    local first_line tp tu tps tv6
    first_line=$(head -1 "$WORK_DIR/proxies.conf")
    IFS='|' read -r tp tu tps tv6 <<< "$first_line"
    echo -e "${YELLOW}Quick test:${NC}"
    echo -e "  curl -x socks5://${tu}:${tps}@${PUBLIC_IPV4}:${tp} https://api64.ipify.org"
    echo ""
    echo -e "${YELLOW}Management:${NC}"
    echo -e "  Remove all : $0 -r"
    echo -e "  Status     : systemctl list-units 'microsocks@*' --no-pager"
    echo -e "  Logs       : journalctl -u microsocks@${tp} --no-pager -n 20"
    echo ""
}

# ======================== MAIN ========================
main() {
    check_root
    detect_os

    local REMOVE=0 CUSTOM_COUNT=0

    while getopts "rn:p:h" opt; do
        case $opt in
            r) REMOVE=1 ;;
            n) CUSTOM_COUNT=$OPTARG ;;
            p) START_PORT=$OPTARG ;;
            h)
                echo "Usage: $0 [-n COUNT] [-p PORT] [-r] [-h]"
                exit 0
                ;;
            *) echo "Usage: $0 [-n COUNT] [-p PORT] [-r] [-h]"; exit 1 ;;
        esac
    done

    echo -e "${CYAN}"
    echo "  ============================================"
    echo "    IPv6 SOCKS5 Proxy Auto-Setup v${SCRIPT_VERSION}"
    echo "    Engine: microsocks + systemd"
    echo "  ============================================"
    echo -e "${NC}"

    [[ $REMOVE -eq 1 ]] && remove_all

    # Step 1: Ensure IPv6 is available
    ensure_ipv6

    # Step 2: Detect IPv6 config
    detect_ipv6
    check_ipv6_connectivity

    # Step 3: Calculate proxy count
    calculate_proxy_count
    if (( CUSTOM_COUNT > 0 )); then
        PROXY_COUNT=$CUSTOM_COUNT
        log_info "Custom count: ${PROXY_COUNT} proxies"
    fi

    # Step 4: Install deps
    install_deps

    # Step 5: Create proxies
    echo ""
    log_info "Generating ${PROXY_COUNT} proxies..."
    echo ""
    USED_IPS=()
    setup_proxies

    # Step 6: System config
    echo ""
    setup_ipv6_preference
    setup_ipv6_routing
    setup_ndp
    make_persistent
    configure_firewall

    # Step 7: Start
    echo ""
    start_all_proxies

    # Step 8: Verify
    sleep 2
    verify_proxies
    show_summary
}

main "$@"
