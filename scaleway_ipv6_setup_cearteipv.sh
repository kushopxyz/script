#!/bin/bash
# proxy-ctl — Scaleway IPv6 SOCKS5 proxy farm manager
# Source of truth: /etc/3proxy/state.tsv
# Backward compat: `bash <this> [COUNT]` runs install + setup with COUNT proxies.

set -euo pipefail

STATE_DIR="/etc/3proxy"
STATE_FILE="$STATE_DIR/state.tsv"
CONF_FILE="$STATE_DIR/3proxy.cfg"
IPV6_LIST="$STATE_DIR/ipv6-list.txt"
OUT_DIR="/root/socks5-ipv6"
OUT_FILE="$OUT_DIR/ipport.txt"
PORT_MIN=20000
PORT_MAX=65000
DEB_URL="https://github.com/3proxy/3proxy/releases/download/0.9.4/3proxy-0.9.4.x86_64.deb"

die()     { echo "ERROR: $*" >&2; exit 1; }
info()    { echo "$*"; }
need_root() { [ "$(id -u)" -eq 0 ] || die "must run as root"; }

usage() {
  cat <<EOF
proxy-ctl — Scaleway IPv6 SOCKS5 proxy manager

Commands:
  install                       Install 3proxy + systemd units (idempotent)
  setup    [--count N]          First-time proxy creation on default IPv4
           [--ipv4 IP]
  extend   [--count N]          Add N proxies. Auto-picks an IPv4 on the
           [--ipv4 IP]          interface that is not yet in state, or use --ipv4
  list                          Print all proxies (2 formats)
  rebuild                       Regenerate config from state.tsv, reload 3proxy
  remove   --ipv4 IP            Remove all proxies for given IPv4
  test                          curl-test each proxy, report OK/FAIL
  status                        Show summary (IPv4 groups + count)
  help                          This help

State file:  $STATE_FILE   (format: IPv4<TAB>PORT<TAB>USER<TAB>PASS<TAB>IPv6)

Examples:
  bash $(basename "$0")                         # quick start: install + setup 30
  bash $(basename "$0") install
  proxy-ctl setup --count 30
  proxy-ctl extend --count 30                   # after attaching new Flex IP
  proxy-ctl extend --count 20 --ipv4 1.2.3.4
  proxy-ctl list
  proxy-ctl test
EOF
}

# ---------- detection helpers ----------

detect_iface() { ip -o -4 route show default | awk '{print $5; exit}'; }

detect_default_ipv4() { curl -4 -s --max-time 5 https://api.ipify.org || true; }

detect_ipv6_prefix() {
  local iface=$1 base
  base=$(ip -6 addr show dev "$iface" scope global -temporary 2>/dev/null \
         | awk '/inet6/ && !/deprecated/ {print $2; exit}' | cut -d/ -f1)
  [ -n "$base" ] || die "no global IPv6 found on $iface"
  echo "$base" | awk -F: '{print $1":"$2":"$3":"$4}'
}

list_iface_ipv4() {
  local iface=$1
  ip -o -4 addr show dev "$iface" 2>/dev/null \
    | awk '{print $4}' | cut -d/ -f1 | grep -v '^127\.' || true
}

state_ipv4()  { [ -f "$STATE_FILE" ] && awk -F'\t' '{print $1}' "$STATE_FILE" | sort -u || true; }
state_ports() { [ -f "$STATE_FILE" ] && awk -F'\t' '{print $2}' "$STATE_FILE" || true; }
state_ipv6()  { [ -f "$STATE_FILE" ] && awk -F'\t' '{print $5}' "$STATE_FILE" || true; }

# ---------- generators ----------

gen_port() {
  # $1 = newline-separated already-used ports
  local used=$1 p
  while :; do
    p=$(( $(od -An -N2 -tu2 /dev/urandom | tr -d ' \n') \
          % (PORT_MAX - PORT_MIN + 1) + PORT_MIN ))
    grep -qxF "$p" <<<"$used" && continue
    echo "$p"; return
  done
}

# random IPv6 in /64, skip suspicious patterns + dup
gen_ipv6() {
  local prefix=$1 used=$2 hex h1 h2 h3 h4 ip6
  while :; do
    hex=$(openssl rand -hex 8)
    h1=${hex:0:4}; h2=${hex:4:4}; h3=${hex:8:4}; h4=${hex:12:4}
    # skip mostly-zero host part (looks like reserved/scan target)
    [[ "$h1$h2" == "00000000" ]] && continue
    # skip EUI-64 stamp (xx:xxff:fexx:xxxx)
    [[ "$h3" == "fffe" ]] && continue
    [[ "${h2: -2}" == "ff" && "${h3:0:2}" == "fe" ]] && continue
    ip6="$prefix:$h1:$h2:$h3:$h4"
    grep -qxF "$ip6" <<<"$used" && continue
    echo "$ip6"; return
  done
}

gen_user() { openssl rand -hex 3; }
gen_pass() { openssl rand -hex 4; }

# ---------- config builder ----------

build_config() {
  mkdir -p "$STATE_DIR" "$OUT_DIR"
  : > "$CONF_FILE"
  : > "$IPV6_LIST"
  : > "$OUT_FILE"

  cat > "$CONF_FILE" <<EOH
nscache 65536
nserver 1.1.1.1
nserver 8.8.8.8
timeouts 1 5 30 60 180 1800 15 60
maxconn 200
EOH

  if [ -s "$STATE_FILE" ]; then
    # users line first (3proxy needs `users` before `auth strong`)
    local user_line="users"
    while IFS=$'\t' read -r ipv4 port user pass ipv6; do
      [ -z "${ipv4:-}" ] && continue
      user_line="$user_line ${user}:CL:${pass}"
    done < "$STATE_FILE"
    echo "$user_line" >> "$CONF_FILE"
    echo "auth strong" >> "$CONF_FILE"

    while IFS=$'\t' read -r ipv4 port user pass ipv6; do
      [ -z "${ipv4:-}" ] && continue
      echo "$ipv6" >> "$IPV6_LIST"
      echo "${ipv4}:${port}:${user}:${pass}:${ipv6}" >> "$OUT_FILE"
      echo "socks -64 -a -p${port} -i${ipv4} -e${ipv6}" >> "$CONF_FILE"
    done < "$STATE_FILE"
  fi

  chmod 600 "$CONF_FILE" "$STATE_FILE" "$IPV6_LIST" "$OUT_FILE" 2>/dev/null || true
  chmod 700 "$OUT_DIR" 2>/dev/null || true
}

reload_3proxy() {
  if systemctl is-active --quiet 3proxy; then
    systemctl reload 3proxy 2>/dev/null \
      || systemctl restart 3proxy
  else
    systemctl restart 3proxy
  fi
}

# ---------- core: append N proxies for one IPv4 ----------

add_proxies() {
  local count=$1 ipv4=$2 iface prefix
  iface=$(detect_iface)
  prefix=$(detect_ipv6_prefix "$iface")

  # warn if ipv4 not on interface (proxy will not bind successfully)
  if ! list_iface_ipv4 "$iface" | grep -qxF "$ipv4"; then
    info "WARN: $ipv4 is not on $iface — 3proxy may fail to bind. Continuing anyway."
  fi

  local used_ports used_ipv6
  used_ports=$(state_ports)
  used_ipv6=$(state_ipv6)

  local i port user pass ipv6
  for i in $(seq 1 "$count"); do
    port=$(gen_port "$used_ports")
    used_ports="$used_ports"$'\n'"$port"
    ipv6=$(gen_ipv6 "$prefix" "$used_ipv6")
    used_ipv6="$used_ipv6"$'\n'"$ipv6"
    user=$(gen_user); pass=$(gen_pass)
    printf "%s\t%s\t%s\t%s\t%s\n" "$ipv4" "$port" "$user" "$pass" "$ipv6" >> "$STATE_FILE"
  done

  info ""
  info "=== Added $count proxies for $ipv4 ==="
  info "--- IP:PORT:USER:PASS ---"
  tail -n "$count" "$STATE_FILE" | awk -F'\t' '{print $1":"$2":"$3":"$4}'
  info ""
  info "--- socks5://IP:PORT:USER:PASS ---"
  tail -n "$count" "$STATE_FILE" | awk -F'\t' '{print "socks5://"$1":"$2":"$3":"$4}'
}

# ---------- subcommands ----------

cmd_install() {
  need_root
  info "=== Installing dependencies ==="
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -o Acquire::Retries=1 \
                 -o Acquire::http::Timeout=10 \
                 -o Acquire::https::Timeout=10 2>/dev/null || true
  apt-get install -y -qq wget curl openssl >/dev/null

  info "=== Installing 3proxy ==="
  wget -q -O /tmp/3proxy.deb "$DEB_URL"
  systemctl stop 3proxy 2>/dev/null || true
  dpkg -i /tmp/3proxy.deb >/dev/null 2>&1 || apt-get -f install -y -qq >/dev/null

  mkdir -p "$STATE_DIR" "$OUT_DIR"
  touch "$STATE_FILE"
  chmod 600 "$STATE_FILE"
  chmod 700 "$OUT_DIR"

  cat > /usr/local/bin/add-ipv6 <<EOR
#!/bin/bash
[ -f $IPV6_LIST ] || exit 0
IFACE=\$(ip -o -4 route show default | awk '{print \$5; exit}')
while IFS= read -r ip6; do
  [ -z "\$ip6" ] && continue
  ip -6 addr replace \${ip6}/128 dev \$IFACE \\
    valid_lft forever preferred_lft forever 2>/dev/null || true
done < $IPV6_LIST
EOR
  chmod +x /usr/local/bin/add-ipv6

  cat > /etc/systemd/system/add-ipv6.service <<EOS
[Unit]
Description=Re-apply SOCKS5 IPv6 aliases
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/add-ipv6
EOS

  cat > /etc/systemd/system/add-ipv6.timer <<EOT
[Unit]
Description=Re-apply SOCKS5 IPv6 aliases every 5 minutes

[Timer]
OnBootSec=30s
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOT

  cat > /etc/systemd/system/3proxy.service <<EOX
[Unit]
Description=3proxy SOCKS5 (proxy-ctl managed)
After=network-online.target

[Service]
Type=simple
ExecStartPre=/usr/local/bin/add-ipv6
ExecStart=/usr/bin/3proxy $CONF_FILE
ExecReload=/bin/kill -USR1 \$MAINPID
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOX

  systemctl daemon-reload
  systemctl enable --now add-ipv6.timer >/dev/null
  systemctl enable 3proxy >/dev/null

  # install self as proxy-ctl for convenience
  if [ -f "$0" ] && [ "$0" != "/usr/local/bin/proxy-ctl" ]; then
    cp -f "$0" /usr/local/bin/proxy-ctl
    chmod +x /usr/local/bin/proxy-ctl
  fi

  info ""
  info "Install complete. Next:"
  info "  proxy-ctl setup --count 30"
}

cmd_setup() {
  need_root
  local count=30 ipv4=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --count) count=$2; shift 2;;
      --ipv4)  ipv4=$2;  shift 2;;
      *) die "unknown arg: $1";;
    esac
  done

  [ -s "$STATE_FILE" ] && die "state.tsv already has entries — use 'extend'"
  [ -z "$ipv4" ] && ipv4=$(detect_default_ipv4)
  [ -z "$ipv4" ] && die "could not detect default IPv4 — pass --ipv4"

  info "=== Setup: $count proxies for IPv4 $ipv4 ==="
  add_proxies "$count" "$ipv4"
  build_config
  /usr/local/bin/add-ipv6
  reload_3proxy
}

cmd_extend() {
  need_root
  local count=30 ipv4=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --count) count=$2; shift 2;;
      --ipv4)  ipv4=$2;  shift 2;;
      *) die "unknown arg: $1";;
    esac
  done

  [ -f "$STATE_FILE" ] || die "no state.tsv — run 'install' + 'setup' first"

  if [ -z "$ipv4" ]; then
    local iface existing ip
    iface=$(detect_iface)
    existing=$(state_ipv4)
    for ip in $(list_iface_ipv4 "$iface"); do
      grep -qxF "$ip" <<<"$existing" && continue
      ipv4=$ip; break
    done
    [ -z "$ipv4" ] && die "no new IPv4 detected on $iface — attach a Flex IP first or pass --ipv4"
    info "Auto-detected new IPv4: $ipv4"
  fi

  info "=== Extend: $count proxies for IPv4 $ipv4 ==="
  add_proxies "$count" "$ipv4"
  build_config
  /usr/local/bin/add-ipv6
  reload_3proxy
}

cmd_rebuild() {
  need_root
  build_config
  /usr/local/bin/add-ipv6
  reload_3proxy
  info "Rebuild done."
}

cmd_list() {
  [ -s "$STATE_FILE" ] || { info "No proxies configured."; return; }
  local n; n=$(wc -l < "$STATE_FILE")
  info "=== $n proxies total ==="
  info ""
  info "--- IP:PORT:USER:PASS ---"
  awk -F'\t' '{print $1":"$2":"$3":"$4}' "$STATE_FILE"
  info ""
  info "--- socks5://IP:PORT:USER:PASS ---"
  awk -F'\t' '{print "socks5://"$1":"$2":"$3":"$4}' "$STATE_FILE"
}

cmd_remove() {
  need_root
  local ipv4=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --ipv4) ipv4=$2; shift 2;;
      *) die "unknown arg: $1";;
    esac
  done
  [ -z "$ipv4" ] && die "usage: proxy-ctl remove --ipv4 IP"
  [ -f "$STATE_FILE" ] || die "no state.tsv"

  local n; n=$(awk -F'\t' -v ip="$ipv4" '$1==ip' "$STATE_FILE" | wc -l)
  [ "$n" -eq 0 ] && die "no proxies found for $ipv4"

  awk -F'\t' -v ip="$ipv4" '$1!=ip' "$STATE_FILE" > "$STATE_FILE.tmp"
  mv "$STATE_FILE.tmp" "$STATE_FILE"
  chmod 600 "$STATE_FILE"
  info "Removed $n proxies for $ipv4"

  build_config
  reload_3proxy
}

cmd_test() {
  [ -s "$STATE_FILE" ] || die "no proxies"
  local ok=0 fail=0
  while IFS=$'\t' read -r ipv4 port user pass ipv6; do
    if curl -s --max-time 8 -x "socks5h://${user}:${pass}@${ipv4}:${port}" \
       https://api64.ipify.org -o /dev/null 2>/dev/null; then
      printf "[OK]   %s:%s\n" "$ipv4" "$port"
      ok=$((ok+1))
    else
      printf "[FAIL] %s:%s\n" "$ipv4" "$port"
      fail=$((fail+1))
    fi
  done < "$STATE_FILE"
  info ""
  info "Summary: $ok OK, $fail FAIL"
}

cmd_status() {
  if [ ! -s "$STATE_FILE" ]; then
    info "No proxies configured."
    return
  fi
  local total iface
  total=$(wc -l < "$STATE_FILE")
  iface=$(detect_iface)
  info "Total proxies: $total"
  info "Interface:     $iface"
  info ""
  info "Proxies per IPv4:"
  awk -F'\t' '{print $1}' "$STATE_FILE" | sort | uniq -c \
    | awk '{printf "  %-20s %s\n", $2, $1" proxies"}'
  info ""
  info "3proxy:        $(systemctl is-active 3proxy 2>/dev/null || echo unknown)"
  info "add-ipv6.timer: $(systemctl is-active add-ipv6.timer 2>/dev/null || echo unknown)"
}

# ---------- dispatch ----------

# Backward compat: `bash <this> [COUNT]` => install + setup
if [ $# -eq 0 ] || [[ "${1:-}" =~ ^[0-9]+$ ]]; then
  count=${1:-30}
  cmd_install
  if [ -s "$STATE_FILE" ]; then
    info ""
    info "state.tsv already has entries — skipping setup. Use 'proxy-ctl extend' or 'proxy-ctl list'."
  else
    cmd_setup --count "$count"
  fi
  exit 0
fi

cmd=$1; shift || true
case "$cmd" in
  install) cmd_install "$@";;
  setup)   cmd_setup   "$@";;
  extend)  cmd_extend  "$@";;
  list)    cmd_list    "$@";;
  rebuild) cmd_rebuild "$@";;
  remove)  cmd_remove  "$@";;
  test)    cmd_test    "$@";;
  status)  cmd_status  "$@";;
  help|-h|--help) usage;;
  *) usage; exit 1;;
esac
