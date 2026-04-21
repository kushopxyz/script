#!/usr/bin/env bash
# ==============================================================================
# IPv6 SOCKS5 Proxy Auto-Setup Script
# Version: 2.2.0
# Creates multiple SOCKS5 proxies, each with a unique public IPv6 address
# Supports: Ubuntu, Debian, CentOS, AlmaLinux, Rocky Linux
# Uses: microsocks (lightweight, proven IPv6 support)
#
# Architecture (v2.2.0):
#   - Each proxy runs as a proper systemd unit: microsocks@<port>.service
#   - IPv6 address setup is a separate oneshot: socks5-ipv6-setup.service
#   - Watchdog uses systemctl restart, not background spawning
#   - No orphan processes — systemd supervises everything with Restart=always
#
# Usage:
#   ./socks5_ipv6_proxy.sh              # Auto-detect and create proxies
#   ./socks5_ipv6_proxy.sh -n 20        # Create exactly 20 proxies
#   ./socks5_ipv6_proxy.sh -p 20000     # Ports start at 20000
#   ./socks5_ipv6_proxy.sh -r           # Remove everything
# ==============================================================================
SCRIPT_VERSION="2.2.0"

set -Eeuo pipefail
trap 'echo -e "\033[0;31m[ERROR]\033[0m Line $LINENO: $BASH_COMMAND" >&2' ERR

# ======================== CONFIGURATION ========================
WORK_DIR="/root/socks5-ipv6"
INSTANCES_DIR="${WORK_DIR}/instances"
OUTPUT_FILE="/root/socks5_ipv6_proxies.txt"
START_PORT=10000

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ======================== HELPERS ========================
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
            apt-get install -y -qq curl net-tools openssl python3 iproute2 microsocks >/dev/null 2>&1
            ;;
        dnf)
            dnf install -y -q curl net-tools openssl python3 iproute gcc git make >/dev/null 2>&1
            ;;
    esac

    # Verify microsocks is available, compile if not
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

# ======================== IPv6 DETECTION & VALIDATION ========================
detect_ipv6() {
    log_info "Detecting IPv6 configuration..."

    command -v python3 &>/dev/null || log_error "python3 is required but not found."

    # --- Step 1: Detect default IPv6 interface ---
    IPV6_IFACE=$(ip -6 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
    if [[ -z "$IPV6_IFACE" ]]; then
        IPV6_IFACE=$(ip -6 addr show scope global | awk -F'[ :]+' '/^[0-9]/{print $2}' | head -1)
    fi
    [[ -n "$IPV6_IFACE" ]] || log_error "Cannot detect IPv6 network interface."
    log_info "Default IPv6 interface: ${IPV6_IFACE}"

    # --- Step 2: List all global IPv6 on this interface, pick best prefix ---
    # BUG FIX (v2.1.0): Old code used 'head -1' which grabbed /128 first.
    # New logic: collect all global addresses, sort by prefix length ascending,
    # and pick the one with the smallest prefix (<= 64) so we get the real subnet.
    local all_addrs best_line
    all_addrs=$(ip -6 addr show dev "$IPV6_IFACE" scope global 2>/dev/null \
        | grep -oP 'inet6 \K[0-9a-f:]+/[0-9]+' || true)

    if [[ -z "$all_addrs" ]]; then
        log_error "No global IPv6 address found on ${IPV6_IFACE}."
    fi

    # Sort by prefix length (numeric on field after '/'), pick smallest prefix
    best_line=$(echo "$all_addrs" | awk -F'/' '{print $2, $0}' \
        | sort -n | awk '{print $2}' | head -1)

    local best_prefix="${best_line##*/}"

    if (( best_prefix > 64 )); then
        # All addresses are /128 (or larger than /64) — no usable subnet
        log_error "No usable IPv6 subnet found on ${IPV6_IFACE}.
  All addresses have prefix >64 (smallest: /${best_prefix}).
  This script needs at least one /64 (or shorter) prefix to generate proxy IPs.
  Addresses found:
$(echo "$all_addrs" | head -10)"
    fi

    IPV6_ADDR="${best_line%%/*}"
    IPV6_PREFIX="$best_prefix"

    # Verify chosen address actually belongs to this interface (defensive check)
    if ! ip -6 addr show dev "$IPV6_IFACE" | grep -q "$IPV6_ADDR"; then
        log_error "Selected address ${IPV6_ADDR} not found on interface ${IPV6_IFACE}."
    fi

    IPV6_NET=$(python3 -c "
import ipaddress
net = ipaddress.IPv6Network('${IPV6_ADDR}/${IPV6_PREFIX}', strict=False)
print(str(net.network_address))
")

    # Show what we found for transparency
    local total_addrs
    total_addrs=$(echo "$all_addrs" | wc -l)
    log_ok "Found ${total_addrs} global IPv6 addresses on ${IPV6_IFACE}"
    log_ok "Selected : ${IPV6_ADDR}/${IPV6_PREFIX} (best usable prefix)"
    log_ok "Subnet   : ${IPV6_NET}/${IPV6_PREFIX}"
    log_ok "Interface: ${IPV6_IFACE}"
}

check_ipv6_connectivity() {
    log_info "Testing IPv6 connectivity..."
    if ping -6 -c 1 -W 5 google.com &>/dev/null; then
        log_ok "IPv6 internet reachable"
    elif ping -6 -c 1 -W 5 2001:4860:4860::8888 &>/dev/null; then
        log_ok "IPv6 connectivity OK (ICMP blocked but route exists)"
    else
        log_warn "IPv6 ping failed. Continuing (firewall may block ICMP)..."
    fi
}

test_ipv6_assignment() {
    log_info "Testing IPv6 address assignment + outgoing connectivity..."

    local test_ip
    test_ip=$(generate_random_ipv6)
    ip -6 addr add "${test_ip}/64" dev "$IPV6_IFACE" 2>/dev/null || log_error "Cannot assign IPv6 to ${IPV6_IFACE}."
    sleep 1

    # Test actual TCP outgoing from this IPv6
    local result
    result=$(curl -s -m 10 --interface "$test_ip" https://api64.ipify.org 2>/dev/null || true)

    ip -6 addr del "${test_ip}/64" dev "$IPV6_IFACE" 2>/dev/null || true

    if [[ "$result" == "$test_ip" ]]; then
        log_ok "IPv6 ${test_ip} is routable and shows correct outgoing IP"
    elif [[ -n "$result" ]]; then
        log_warn "IPv6 assigned but outgoing shows: ${result} (NDP proxy may help)"
    else
        log_warn "IPv6 connectivity test inconclusive (will configure NDP proxy)"
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

    # microsocks uses ~0.5MB per instance - very lightweight
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

# ======================== CREATE PROXIES ========================
setup_proxies() {
    # Clean previous installation if exists
    if [[ -d "$WORK_DIR" ]]; then
        log_warn "Previous installation found. Stopping..."
        stop_all_proxies
        rm -rf "$WORK_DIR"
    fi

    mkdir -p "$WORK_DIR" "$INSTANCES_DIR"

    local public_ipv4
    public_ipv4=$(curl -s -4 -m 5 ifconfig.me 2>/dev/null || curl -s -4 -m 5 api.ipify.org 2>/dev/null || echo "N/A")
    PUBLIC_IPV4="$public_ipv4"

    # ---- Proxy data file ----
    # Format: PORT|USER|PASS|IPV6
    > "$WORK_DIR/proxies.conf"

    # ---- Output files ----
    > "${WORK_DIR}/url.txt"
    > "${WORK_DIR}/ipport.txt"

    # ---- Disable DAD (Duplicate Address Detection) to avoid tentative state ----
    sysctl -w "net.ipv6.conf.${IPV6_IFACE}.accept_dad=0" &>/dev/null || true
    sysctl -w "net.ipv6.conf.${IPV6_IFACE}.dad_transmits=0" &>/dev/null || true

    # ---- Generate proxies ----
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

        # Assign IPv6 to host interface (nodad = skip tentative state)
        # Only write config if the address was actually added
        if ip -6 addr add "${ipv6}/64" dev "$IPV6_IFACE" nodad 2>/dev/null || \
           ip -6 addr add "${ipv6}/64" dev "$IPV6_IFACE" 2>/dev/null; then

            # Main config (used by watchdog and cleanup)
            echo "${port}|${user}|${pass}|${ipv6}" >> "$WORK_DIR/proxies.conf"

            # Per-instance env file for systemd EnvironmentFile=
            cat > "${INSTANCES_DIR}/${port}.env" <<ENVEOF
PORT=${port}
SOCKS_USER=${user}
SOCKS_PASS=${pass}
IPV6=${ipv6}
ENVEOF

            # Output files
            echo "socks5://${user}:${pass}@${public_ipv4}:${port}" >> "${WORK_DIR}/url.txt"
            echo "socks5://${public_ipv4}:${port}:${user}:${pass}" >> "${WORK_DIR}/ipport.txt"
            printf "  ${GREEN}[%3d/%d]${NC} :%d -> %s\n" "$i" "$PROXY_COUNT" "$port" "$ipv6"
        else
            printf "  ${RED}[%3d/%d]${NC} :%d -> %s (failed to assign, skipped)\n" "$i" "$PROXY_COUNT" "$port" "$ipv6"
        fi
    done

    # Update PROXY_COUNT to actual number created
    PROXY_COUNT=$(wc -l < "$WORK_DIR/proxies.conf")

    # Combine into main output file
    {
        echo "# ===== Format: socks5://user:pass@ip:port ====="
        cat "${WORK_DIR}/url.txt"
        echo ""
        echo "# ===== Format: socks5://IP:Port:Username:Password ====="
        cat "${WORK_DIR}/ipport.txt"
    } > "$OUTPUT_FILE"

    # Wait for all IPv6 addresses to be fully ready
    log_info "Waiting for IPv6 addresses to settle..."
    sleep 3
}

# ======================== START / STOP PROXIES ========================
start_all_proxies() {
    log_info "Starting ${PROXY_COUNT} microsocks services..."

    local -a units=()
    while IFS='|' read -r port _user _pass _ipv6; do
        units+=("microsocks@${port}.service")
    done < "$WORK_DIR/proxies.conf"

    if (( ${#units[@]} == 0 )); then
        log_error "No proxies to start (proxies.conf empty)."
    fi

    # Enable + start all units (systemd handles batching)
    systemctl enable "${units[@]}" &>/dev/null 2>&1
    systemctl start "${units[@]}" 2>/dev/null || true

    log_info "Waiting for services to bind..."
    sleep 3

    # Check status
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
        log_ok "All ${listening} proxies running (systemd supervised, Restart=always)"
    fi
}

stop_all_proxies() {
    # Stop all microsocks@ template instances via proxies.conf
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
    # Fallback: kill any orphaned microsocks processes
    pkill -f "microsocks -p" 2>/dev/null || true
    sleep 1
    pkill -9 -f "microsocks -p" 2>/dev/null || true
}

# ======================== FORCE IPv6 PREFERENCE ========================
setup_ipv6_preference() {
    log_info "Configuring system to prefer IPv6 for outgoing connections..."

    # gai.conf controls getaddrinfo() address sorting — this makes all
    # DNS-resolving programs (including microsocks) prefer AAAA over A records
    cat > /etc/gai.conf <<'GAIEOF'
# Prefer IPv6 over IPv4 for outgoing connections
# Generated by socks5_ipv6_proxy.sh
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
GAIEOF

    log_ok "IPv6 preferred over IPv4 (gai.conf)"
}

# ======================== IPv6 SOURCE ROUTING ========================
setup_ipv6_routing() {
    log_info "Setting up per-address source routing..."

    local gw iface
    gw=$(ip -6 route show default | awk '{print $3}' | head -1)
    iface=$(ip -6 route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)

    if [[ -z "$gw" || -z "$iface" ]]; then
        log_warn "Cannot detect IPv6 gateway. Source routing skipped."
        return
    fi

    log_info "IPv6 gateway: ${gw} dev ${iface}"

    local table_id=100
    for ipv6 in "${USED_IPS[@]}"; do
        table_id=$((table_id + 1))
        ip -6 rule del from "$ipv6" table "$table_id" 2>/dev/null || true
        ip -6 rule add from "$ipv6" table "$table_id" prio "$table_id"
        ip -6 route replace default via "$gw" dev "$iface" src "$ipv6" table "$table_id" 2>/dev/null || true
    done

    IPV6_GW="$gw"
    log_ok "Source routing configured for ${#USED_IPS[@]} addresses (tables 101-${table_id})"
}

# ======================== NDP PROXY ========================
setup_ndp() {
    log_info "Configuring NDP proxy..."

    sysctl -w net.ipv6.conf.all.proxy_ndp=1 &>/dev/null
    sysctl -w "net.ipv6.conf.${IPV6_IFACE}.proxy_ndp=1" &>/dev/null

    cat > /etc/sysctl.d/99-socks5-ndp.conf <<SYSCTL
net.ipv6.conf.all.proxy_ndp=1
net.ipv6.conf.${IPV6_IFACE}.proxy_ndp=1
SYSCTL

    for ipv6 in "${USED_IPS[@]}"; do
        ip -6 neigh add proxy "$ipv6" dev "$IPV6_IFACE" 2>/dev/null || true
    done

    log_ok "NDP proxy enabled for ${#USED_IPS[@]} addresses"
}

# ======================== PERSISTENCE ========================
make_persistent() {
    log_info "Making configuration persistent..."

    # ---------- Layer 1: Network config (ifcfg/interfaces.d) ----------
    write_network_config

    # ---------- Layer 2: Boot script for IPv6 + NDP (oneshot) ----------
    cat > /usr/local/bin/socks5-ipv6-setup.sh <<HEADER
#!/bin/bash
# Auto-generated by socks5_ipv6_proxy.sh v${SCRIPT_VERSION}
# Adds proxy IPv6 addresses and NDP entries on boot
sysctl -w net.ipv6.conf.${IPV6_IFACE}.accept_dad=0 &>/dev/null || true
sysctl -w net.ipv6.conf.${IPV6_IFACE}.dad_transmits=0 &>/dev/null || true
HEADER

    local boot_table_id=100
    local boot_gw
    boot_gw=$(ip -6 route show default | awk '{print $3}' | head -1)

    for ipv6 in "${USED_IPS[@]}"; do
        boot_table_id=$((boot_table_id + 1))
        cat >> /usr/local/bin/socks5-ipv6-setup.sh <<LINE
ip -6 addr add ${ipv6}/64 dev ${IPV6_IFACE} nodad 2>/dev/null || ip -6 addr add ${ipv6}/64 dev ${IPV6_IFACE} 2>/dev/null || true
ip -6 neigh add proxy ${ipv6} dev ${IPV6_IFACE} 2>/dev/null || true
ip -6 rule add from ${ipv6} table ${boot_table_id} prio ${boot_table_id} 2>/dev/null || true
ip -6 route replace default via ${boot_gw} dev ${IPV6_IFACE} src ${ipv6} table ${boot_table_id} 2>/dev/null || true
LINE
    done
    chmod +x /usr/local/bin/socks5-ipv6-setup.sh

    # ---------- Layer 3: Systemd units ----------
    # 3a: IPv6 setup service (oneshot — only manages addresses, no processes)
    cat > /etc/systemd/system/socks5-ipv6-setup.service <<UNIT
[Unit]
Description=SOCKS5 IPv6 Address & NDP Setup
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/socks5-ipv6-setup.sh

[Install]
WantedBy=multi-user.target
UNIT

    # 3b: Template unit — each proxy is a real supervised process
    cat > /etc/systemd/system/microsocks@.service <<UNIT
[Unit]
Description=MicroSocks SOCKS5 proxy on port %i
After=network-online.target socks5-ipv6-setup.service
Wants=network-online.target
Requires=socks5-ipv6-setup.service

[Service]
Type=simple
EnvironmentFile=${INSTANCES_DIR}/%i.env
ExecStart=${MICROSOCKS_BIN} -p \$PORT -u \$SOCKS_USER -P \$SOCKS_PASS -b \$IPV6
Restart=always
RestartSec=2
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable socks5-ipv6-setup.service &>/dev/null

    # ---------- Layer 4: Watchdog ----------
    setup_watchdog

    log_ok "Persistence enabled (systemd template: microsocks@<port>.service)"
}

# ======================== NETWORK CONFIG ========================
write_network_config() {
    log_info "Writing IPv6 to network config..."

    if command -v netplan &>/dev/null; then
        # Skip netplan to avoid conflicts with cloud-init managed configs.
        # Boot script (socks5-ipv6-setup.sh) handles re-adding IPv6 addresses.
        log_ok "Netplan detected — skipping (boot script handles persistence)"

    elif [[ -d /etc/sysconfig/network-scripts ]]; then
        local ifcfg_file="/etc/sysconfig/network-scripts/ifcfg-${IPV6_IFACE}-socks5-ipv6"
        cat > "$ifcfg_file" <<IFCFG
# Auto-generated by socks5_ipv6_proxy.sh
DEVICE=${IPV6_IFACE}
IPV6ADDR_SECONDARIES="$(printf '%s/64 ' "${USED_IPS[@]}")"
IFCFG
        log_ok "ifcfg config: ${ifcfg_file}"

    elif [[ -d /etc/network/interfaces.d ]]; then
        local iface_file="/etc/network/interfaces.d/socks5-ipv6"
        > "$iface_file"
        for ipv6 in "${USED_IPS[@]}"; do
            echo "iface ${IPV6_IFACE} inet6 static" >> "$iface_file"
            echo "    address ${ipv6}/64" >> "$iface_file"
            echo "" >> "$iface_file"
        done
        log_ok "interfaces.d config: ${iface_file}"

    else
        log_warn "Unknown network config. IPv6 relies on boot script + watchdog."
    fi
}

# ======================== WATCHDOG ========================
setup_watchdog() {
    log_info "Setting up watchdog..."

    # Watchdog reads proxies.conf, checks IPv6 + service health,
    # and uses systemctl restart for dead proxies (not background spawning)
    local wd_gw
    wd_gw=$(ip -6 route show default | awk '{print $3}' | head -1)

    cat > /usr/local/bin/socks5-ipv6-watchdog.sh <<WDEOF
#!/bin/bash
# Auto-generated watchdog — recovers lost IPv6, routing rules, and restarts dead proxy units
IFACE="${IPV6_IFACE}"
CONF="${WORK_DIR}/proxies.conf"
GW="${wd_gw}"
RECOVERED=0
TABLE_ID=100

[[ -f "\$CONF" ]] || exit 0

while IFS='|' read -r port user pass ipv6; do
    TABLE_ID=\$((TABLE_ID + 1))
    # Check and re-add missing IPv6 address
    if ! ip -6 addr show dev "\$IFACE" | grep -q "\$ipv6"; then
        ip -6 addr add "\${ipv6}/64" dev "\$IFACE" nodad 2>/dev/null || true
        ip -6 neigh add proxy "\$ipv6" dev "\$IFACE" 2>/dev/null || true
        RECOVERED=\$((RECOVERED + 1))
        logger -t socks5-watchdog "Recovered IPv6: \$ipv6"
    fi
    # Check and re-add missing routing rule
    if ! ip -6 rule show | grep -q "from \$ipv6"; then
        ip -6 rule add from "\$ipv6" table "\$TABLE_ID" prio "\$TABLE_ID" 2>/dev/null || true
        ip -6 route replace default via "\$GW" dev "\$IFACE" src "\$ipv6" table "\$TABLE_ID" 2>/dev/null || true
        RECOVERED=\$((RECOVERED + 1))
        logger -t socks5-watchdog "Recovered route for: \$ipv6"
    fi
    # Check and restart dead proxy service
    if ! systemctl is-active --quiet "microsocks@\${port}.service" 2>/dev/null; then
        systemctl restart "microsocks@\${port}.service" 2>/dev/null || true
        RECOVERED=\$((RECOVERED + 1))
        logger -t socks5-watchdog "Restarted microsocks@\${port}"
    fi
done < "\$CONF"

if (( RECOVERED > 0 )); then
    logger -t socks5-watchdog "Total recovered: \$RECOVERED"
fi
WDEOF

    chmod +x /usr/local/bin/socks5-ipv6-watchdog.sh

    cat > /etc/systemd/system/socks5-ipv6-watchdog.service <<WDSVC
[Unit]
Description=SOCKS5 IPv6 Proxy - Watchdog

[Service]
Type=oneshot
ExecStart=/usr/local/bin/socks5-ipv6-watchdog.sh
WDSVC

    cat > /etc/systemd/system/socks5-ipv6-watchdog.timer <<WDTIMER
[Unit]
Description=SOCKS5 IPv6 Proxy - Watchdog Timer

[Timer]
OnBootSec=120
OnUnitActiveSec=60
AccuracySec=10

[Install]
WantedBy=timers.target
WDTIMER

    systemctl daemon-reload
    systemctl enable --now socks5-ipv6-watchdog.timer &>/dev/null
    log_ok "Watchdog active (checks every 60s, uses systemctl restart)"
}

# ======================== FIREWALL ========================
configure_firewall() {
    local first_port=$START_PORT
    local last_port=$(( START_PORT + PROXY_COUNT - 1 ))

    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        log_info "Configuring UFW..."
        ufw allow "${first_port}:${last_port}"/tcp &>/dev/null
        log_ok "UFW: opened ports ${first_port}-${last_port}"

    elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
        log_info "Configuring firewalld..."
        firewall-cmd --permanent --add-port="${first_port}-${last_port}"/tcp &>/dev/null
        firewall-cmd --reload &>/dev/null
        log_ok "Firewalld: opened ports ${first_port}-${last_port}"

    else
        log_warn "No active firewall detected. Ensure ports ${first_port}-${last_port} are accessible."
    fi
}

# ======================== REMOVE ALL ========================
remove_all() {
    log_warn "Removing all IPv6 SOCKS5 proxies..."

    # Stop and disable all microsocks@ units
    stop_all_proxies
    log_ok "Proxy processes stopped"

    # Remove IPv6 addresses
    if [[ -f /usr/local/bin/socks5-ipv6-setup.sh ]]; then
        while IFS= read -r line; do
            if [[ "$line" == *"addr add"* ]]; then
                local addr iface
                addr=$(echo "$line" | grep -oP 'add \K[0-9a-f:]+')
                iface=$(echo "$line" | grep -oP 'dev \K\S+')
                ip -6 addr del "${addr}/64" dev "$iface" 2>/dev/null || true
                ip -6 neigh del proxy "$addr" dev "$iface" 2>/dev/null || true
            fi
        done < /usr/local/bin/socks5-ipv6-setup.sh
        log_ok "IPv6 addresses removed"
    fi

    # Remove source routing rules (tables 101-600)
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
    systemctl daemon-reload 2>/dev/null || true
    log_ok "Systemd units removed"

    # Remove legacy units from pre-v2.2.0 if present
    rm -f /etc/systemd/system/socks5-ipv6.service
    rm -f /usr/local/bin/socks5-ipv6-start.sh

    # Remove network config
    rm -f /etc/netplan/60-socks5-ipv6.yaml
    netplan apply 2>/dev/null || true
    rm -f /etc/sysconfig/network-scripts/ifcfg-*-socks5-ipv6 2>/dev/null || true
    rm -f /etc/network/interfaces.d/socks5-ipv6 2>/dev/null || true
    log_ok "Network config removed"

    # Remove gai.conf (restore IPv6/IPv4 default)
    rm -f /etc/gai.conf
    log_ok "gai.conf removed (system default restored)"

    # Remove sysctl
    rm -f /etc/sysctl.d/99-socks5-ndp.conf
    sysctl --system &>/dev/null || true

    # Remove firewall rules (best effort)
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        local proxy_count
        proxy_count=$(wc -l < "$WORK_DIR/proxies.conf" 2>/dev/null || echo 0)
        if (( proxy_count > 0 )); then
            local first_port last_port
            first_port=$(head -1 "$WORK_DIR/proxies.conf" | cut -d'|' -f1)
            last_port=$(tail -1 "$WORK_DIR/proxies.conf" | cut -d'|' -f1)
            ufw delete allow "${first_port}:${last_port}/tcp" 2>/dev/null || true
        fi
    fi

    # Remove work dir and output
    rm -rf "$WORK_DIR" "$OUTPUT_FILE"
    # Remove legacy PID dir if present
    rm -rf /run/socks5-ipv6

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
        log_ok "Proxy verified: outgoing IPv6 = ${result}"
    elif [[ -n "$result" ]]; then
        log_warn "Proxy works but outgoing IP: ${result} (expected ${ipv6})"
    else
        log_warn "Proxy verification timed out (may still work for IPv4 targets)"
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
        echo -e "${YELLOW}  ${actual}/${PROXY_COUNT} PROXIES STARTED (${fails} FAILED)${NC}"
        echo -e "${YELLOW}  systemd Restart=always will auto-recover failed ones${NC}"
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
    echo -e "${YELLOW}Quick test:${NC}"
    local first_line
    first_line=$(head -1 "$WORK_DIR/proxies.conf")
    local tp tu tps tv6
    IFS='|' read -r tp tu tps tv6 <<< "$first_line"
    echo -e "  curl -x socks5h://${tu}:${tps}@${PUBLIC_IPV4}:${tp} https://api64.ipify.org"
    echo ""
    echo -e "${YELLOW}Management:${NC}"
    echo -e "  Remove all    : $0 -r"
    echo -e "  Status (all)  : systemctl list-units 'microsocks@*' --no-pager"
    echo -e "  Status (one)  : systemctl status microsocks@${tp}"
    echo -e "  Restart (one) : systemctl restart microsocks@${tp}"
    echo -e "  Logs (one)    : journalctl -u microsocks@${tp} --no-pager -n 20"
    echo -e "  Watchdog log  : journalctl -t socks5-watchdog"
    echo ""
}

# ======================== MAIN ========================
main() {
    check_root
    detect_os

    local REMOVE=0
    local CUSTOM_COUNT=0

    while getopts "rn:p:h" opt; do
        case $opt in
            r) REMOVE=1 ;;
            n) CUSTOM_COUNT=$OPTARG ;;
            p) START_PORT=$OPTARG ;;
            h)
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  -n COUNT   Number of proxies (default: auto based on RAM)"
                echo "  -p PORT    Start port (default: ${START_PORT})"
                echo "  -r         Remove all proxies and cleanup"
                echo "  -h         Show this help"
                exit 0
                ;;
            *) echo "Usage: $0 [-r] [-n count] [-p port] [-h]"; exit 1 ;;
        esac
    done

    echo -e "${CYAN}"
    echo "  ============================================"
    echo "    IPv6 SOCKS5 Proxy Auto-Setup v${SCRIPT_VERSION}"
    echo "    Engine: microsocks + systemd"
    echo "  ============================================"
    echo -e "${NC}"

    [[ $REMOVE -eq 1 ]] && remove_all

    # Step 1: Detect & validate IPv6
    detect_ipv6
    check_ipv6_connectivity

    # Step 2: Calculate proxy count
    calculate_proxy_count
    if (( CUSTOM_COUNT > 0 )); then
        PROXY_COUNT=$CUSTOM_COUNT
        log_info "Using custom count: ${PROXY_COUNT} proxies"
    fi

    # Step 3: Install dependencies
    install_deps

    # Step 4: Test IPv6
    test_ipv6_assignment

    # Step 5: Create & assign proxies + per-instance env files
    echo ""
    log_info "Generating ${PROXY_COUNT} proxies with unique IPv6 addresses..."
    echo ""
    USED_IPS=()
    setup_proxies

    # Step 6: IPv6 preference + routing + NDP + persistence + firewall
    echo ""
    setup_ipv6_preference
    setup_ipv6_routing
    setup_ndp
    make_persistent
    configure_firewall

    # Step 7: Start all proxies via systemd
    echo ""
    start_all_proxies

    # Step 8: Verify
    sleep 2
    verify_proxies
    show_summary
}

main "$@"
