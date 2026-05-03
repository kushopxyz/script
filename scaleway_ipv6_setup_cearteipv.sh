#!/bin/bash
# proxy-ctl — Scaleway IPv6 SOCKS5 proxy farm manager
# Source of truth: /etc/3proxy/state.tsv
# Backward compat: `bash <this> [COUNT]` runs install + setup with COUNT proxies.

set -euo pipefail

STATE_DIR="/etc/3proxy"
STATE_FILE="$STATE_DIR/state.tsv"
CONF_FILE="$STATE_DIR/3proxy.cfg"
IPV6_LIST="$STATE_DIR/ipv6-list.txt"
PREFIX_FILE="$STATE_DIR/prefixes.txt"
OUT_DIR="/root/socks5-ipv6"
OUT_FILE="$OUT_DIR/ipport.txt"
PORT_MIN=20000
PORT_MAX=65000
DEB_URL="https://github.com/3proxy/3proxy/releases/download/0.9.4/3proxy-0.9.4.x86_64.deb"

die()     { echo "ERROR: $*" >&2; exit 1; }
info()    { echo "$*"; }
need_root() { [ "$(id -u)" -eq 0 ] || die "must run as root"; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

# write content from stdin to file only if different (returns 0 if changed)
write_if_diff() {
  local target=$1 tmp
  tmp=$(mktemp)
  cat > "$tmp"
  if [ -f "$target" ] && cmp -s "$tmp" "$target"; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$target"
  return 0
}

usage() {
  cat <<EOF
proxy-ctl — Scaleway IPv6 SOCKS5 proxy manager

Commands:
  install  [--force]            Install 3proxy + systemd units (idempotent;
                                --force reinstalls deps + 3proxy package)
  setup    [--count N]          First-time proxy creation on default IPv4.
           [--ipv4 IP]          --prefix pins all new proxies to one /64 (default
           [--prefix P]         spreads randomly across all registered prefixes).
  extend   [--count N]          Add N proxies. Auto-picks an IPv4 on the interface
           [--ipv4 IP]          that is not yet in state, or use --ipv4. --prefix
           [--prefix P]         pins to one /64; default is random spread.
  list                          Print all proxies (2 formats)
  rebuild                       Regenerate config from state.tsv, reload 3proxy
  remove   --ipv4 IP            Remove all proxies for given IPv4
  add-prefix    <PREFIX>        Register an extra /64 prefix routed to this VPS.
           [--count N]          --count creates N proxies immediately (random
           [--ipv4 IP]          spread). Add --pin to use ONLY the just-added
           [--pin]              prefix for those new N proxies.
  remove-prefix <PREFIX>        Unregister a /64 prefix from the pool
  list-prefixes                 Show all /64 prefixes available for proxy generation
  test                          curl-test each proxy, report OK/FAIL
  status                        Show summary (IPv4 + prefix groups + count)
  help                          This help

State file:  $STATE_FILE   (format: IPv4<TAB>PORT<TAB>USER<TAB>PASS<TAB>IPv6)

Examples:
  bash $(basename "$0")                         # quick start: install + setup 30
  bash $(basename "$0") install
  proxy-ctl setup --count 30
  proxy-ctl extend --count 30                   # after attaching new Flex IP
  proxy-ctl extend --count 20 --ipv4 1.2.3.4
  proxy-ctl add-prefix 2001:bc8:5050:abcd                    # register only
  proxy-ctl add-prefix 2001:bc8:5050:abcd --count 30         # +30 random spread
  proxy-ctl add-prefix 2001:bc8:5050:abcd --count 30 --pin   # +30 ALL on new prefix
  proxy-ctl extend --count 30                                # +30 on new IPv4 (random)
  proxy-ctl extend --count 30 --prefix 2001:bc8:5050:abcd    # +30 pinned to one prefix
  proxy-ctl list
  proxy-ctl test
EOF
}

# ---------- detection helpers ----------

detect_iface() { ip -o -4 route show default | awk '{print $5; exit}'; }

detect_default_ipv4() { curl -4 -s --max-time 5 https://api.ipify.org || true; }

detect_ipv6_prefix() {
  # legacy: returns the FIRST /64 prefix detected on the interface
  local iface=$1 base
  base=$(ip -6 addr show dev "$iface" scope global -temporary 2>/dev/null \
         | awk '/inet6/ && !/deprecated/ {print $2; exit}' | cut -d/ -f1)
  [ -n "$base" ] || die "no global IPv6 found on $iface"
  echo "$base" | awk -F: '{print $1":"$2":"$3":"$4}'
}

# Returns ALL /64 prefixes available for proxy generation, one per line.
# Priority:
#   1. /etc/3proxy/prefixes.txt if present and non-empty (user-managed list)
#   2. Otherwise, fall back to detecting the single prefix on the interface.
get_prefixes() {
  if [ -s "$PREFIX_FILE" ]; then
    grep -vE '^\s*(#|$)' "$PREFIX_FILE"
    return
  fi
  detect_ipv6_prefix "$(detect_iface)"
}

# Validate prefix format: 4 hextets like "2001:bc8:4064:2be"
validate_prefix() {
  local p=$1
  [[ "$p" =~ ^[0-9a-fA-F]{1,4}:[0-9a-fA-F]{1,4}:[0-9a-fA-F]{1,4}:[0-9a-fA-F]{1,4}$ ]]
}

# Strip "::/64" or "::" suffix if user pasted full notation
clean_prefix() {
  echo "$1" | sed -E 's#::?/?[0-9]*$##' | sed -E 's#:0:0:0:0$##'
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

# Random IPv6 picking a random /64 prefix from $1 (newline-separated list),
# skip suspicious patterns and duplicates.
gen_ipv6() {
  local prefixes=$1 used=$2 hex h1 h2 h3 h4 ip6 prefix nprefix nidx
  nprefix=$(echo "$prefixes" | grep -c .)
  [ "$nprefix" -eq 0 ] && die "no /64 prefix available — run 'add-prefix' or check interface"
  while :; do
    nidx=$(( $(od -An -N2 -tu2 /dev/urandom | tr -d ' \n') % nprefix + 1 ))
    prefix=$(echo "$prefixes" | sed -n "${nidx}p")
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
  local count=$1 ipv4=$2 prefix_pin=${3:-}
  local iface prefixes nprefix
  iface=$(detect_iface)

  # warn if ipv4 not on interface (proxy will not bind successfully)
  if ! list_iface_ipv4 "$iface" | grep -qxF "$ipv4"; then
    info "WARN: $ipv4 is not on $iface — 3proxy may fail to bind. Continuing anyway."
  fi

  if [ -n "$prefix_pin" ]; then
    local all
    all=$(get_prefixes)
    grep -qxF "$prefix_pin" <<<"$all" \
      || die "prefix $prefix_pin not registered — run 'add-prefix $prefix_pin' first"
    prefixes="$prefix_pin"
    info "Pinning all $count proxies to prefix: $prefix_pin"
  else
    prefixes=$(get_prefixes)
    nprefix=$(echo "$prefixes" | grep -c .)
    info "Using $nprefix /64 prefix(es): $(echo "$prefixes" | tr '\n' ' ')"
  fi

  local used_ports used_ipv6
  used_ports=$(state_ports)
  used_ipv6=$(state_ipv6)

  local i port user pass ipv6
  for i in $(seq 1 "$count"); do
    port=$(gen_port "$used_ports")
    used_ports="$used_ports"$'\n'"$port"
    ipv6=$(gen_ipv6 "$prefixes" "$used_ipv6")
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
  local force=0
  [ "${1:-}" = "--force" ] && force=1

  # 1. apt deps — skip if all binaries present
  if [ $force -eq 1 ] || ! { have_cmd wget && have_cmd curl && have_cmd openssl; }; then
    info "=== Installing dependencies ==="
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -o Acquire::Retries=1 \
                   -o Acquire::http::Timeout=10 \
                   -o Acquire::https::Timeout=10 2>/dev/null || true
    apt-get install -y -qq wget curl openssl >/dev/null
  else
    info "deps OK (wget/curl/openssl) — skipping apt"
  fi

  # 2. 3proxy package — skip if installed
  if [ $force -eq 1 ] || ! { dpkg -l 3proxy 2>/dev/null | grep -q '^ii' && [ -x /usr/bin/3proxy ]; }; then
    info "=== Installing 3proxy ==="
    wget -q -O /tmp/3proxy.deb "$DEB_URL"
    systemctl stop 3proxy 2>/dev/null || true
    dpkg -i /tmp/3proxy.deb >/dev/null 2>&1 || apt-get -f install -y -qq >/dev/null
  else
    info "3proxy already installed — skipping"
  fi

  mkdir -p "$STATE_DIR" "$OUT_DIR"
  [ -f "$STATE_FILE" ] || touch "$STATE_FILE"
  chmod 600 "$STATE_FILE"
  chmod 700 "$OUT_DIR"

  # 3. systemd units + add-ipv6 — only daemon-reload if any file changed
  local changed=0

  write_if_diff /usr/local/bin/add-ipv6 <<EOR && changed=1 || true
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

  write_if_diff /etc/systemd/system/add-ipv6.service <<EOS && changed=1 || true
[Unit]
Description=Re-apply SOCKS5 IPv6 aliases
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/add-ipv6
EOS

  write_if_diff /etc/systemd/system/add-ipv6.timer <<EOT && changed=1 || true
[Unit]
Description=Re-apply SOCKS5 IPv6 aliases every 5 minutes

[Timer]
OnBootSec=30s
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOT

  write_if_diff /etc/systemd/system/3proxy.service <<EOX && changed=1 || true
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

  if [ $changed -eq 1 ]; then
    info "systemd units updated, reloading"
    systemctl daemon-reload
  else
    info "systemd units unchanged — skip daemon-reload"
  fi

  systemctl is-enabled add-ipv6.timer >/dev/null 2>&1 \
    || systemctl enable --now add-ipv6.timer >/dev/null
  systemctl is-enabled 3proxy >/dev/null 2>&1 \
    || systemctl enable 3proxy >/dev/null

  # install self as proxy-ctl for convenience
  if [ -f "$0" ] && [ "$0" != "/usr/local/bin/proxy-ctl" ]; then
    cp -f "$0" /usr/local/bin/proxy-ctl
    chmod +x /usr/local/bin/proxy-ctl
  fi

  info ""
  info "Install complete."
}

cmd_setup() {
  need_root
  local count=30 ipv4="" prefix=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --count)  count=$2;  shift 2;;
      --ipv4)   ipv4=$2;   shift 2;;
      --prefix) prefix=$(clean_prefix "$2"); shift 2;;
      *) die "unknown arg: $1";;
    esac
  done

  [ -s "$STATE_FILE" ] && die "state.tsv already has entries — use 'extend'"
  [ -z "$ipv4" ] && ipv4=$(detect_default_ipv4)
  [ -z "$ipv4" ] && die "could not detect default IPv4 — pass --ipv4"

  info "=== Setup: $count proxies for IPv4 $ipv4 ==="
  add_proxies "$count" "$ipv4" "$prefix"
  build_config
  /usr/local/bin/add-ipv6
  reload_3proxy
}

cmd_extend() {
  need_root
  local count=30 ipv4="" prefix=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --count)  count=$2;  shift 2;;
      --ipv4)   ipv4=$2;   shift 2;;
      --prefix) prefix=$(clean_prefix "$2"); shift 2;;
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
  add_proxies "$count" "$ipv4" "$prefix"
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

cmd_add_prefix() {
  need_root
  local raw="" count=0 ipv4="" pin=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --count) count=$2; shift 2;;
      --ipv4)  ipv4=$2;  shift 2;;
      --pin)   pin=1; shift;;
      -*) die "unknown flag: $1";;
      *) [ -z "$raw" ] && raw=$1 || die "unexpected arg: $1"; shift;;
    esac
  done
  [ -z "$raw" ] && die "usage: proxy-ctl add-prefix <PREFIX> [--count N] [--ipv4 IP]"
  local prefix
  prefix=$(clean_prefix "$raw")
  validate_prefix "$prefix" || die "invalid prefix '$raw' — expected 4 hextets like 2001:bc8:5050:abcd"

  mkdir -p "$STATE_DIR"
  # bootstrap: if file empty/missing, seed with currently detected prefix first
  if [ ! -s "$PREFIX_FILE" ]; then
    local current
    current=$(detect_ipv6_prefix "$(detect_iface)" 2>/dev/null || true)
    [ -n "$current" ] && echo "$current" > "$PREFIX_FILE"
  fi

  if grep -qxF "$prefix" "$PREFIX_FILE" 2>/dev/null; then
    info "prefix $prefix already in $PREFIX_FILE — no change"
  else
    echo "$prefix" >> "$PREFIX_FILE"
    chmod 600 "$PREFIX_FILE"
    info "Added prefix: $prefix"
    info "Total prefixes: $(grep -c . "$PREFIX_FILE")"
  fi

  # if --count given, create N proxies right away
  if [ "$count" -gt 0 ]; then
    [ -z "$ipv4" ] && ipv4=$(detect_default_ipv4)
    [ -z "$ipv4" ] && die "could not detect IPv4 — pass --ipv4"
    local pin_prefix=""
    [ "$pin" -eq 1 ] && pin_prefix="$prefix"
    info ""
    if [ -n "$pin_prefix" ]; then
      info "=== Creating $count proxies for IPv4 $ipv4 (PINNED to $pin_prefix) ==="
    else
      info "=== Creating $count proxies for IPv4 $ipv4 (spread across all prefixes) ==="
    fi
    add_proxies "$count" "$ipv4" "$pin_prefix"
    build_config
    /usr/local/bin/add-ipv6
    reload_3proxy
  else
    info ""
    info "Next: proxy-ctl extend --count N    (or rerun with --count N [--pin] --ipv4 IP)"
  fi
}

cmd_remove_prefix() {
  need_root
  [ $# -eq 0 ] && die "usage: proxy-ctl remove-prefix <PREFIX>"
  [ -f "$PREFIX_FILE" ] || die "no prefix file"
  local raw=$1 prefix
  prefix=$(clean_prefix "$raw")
  grep -qxF "$prefix" "$PREFIX_FILE" || die "prefix $prefix not in list"

  # warn if proxies still use this prefix
  local in_use
  in_use=$(awk -F'\t' -v p="$prefix" 'index($5, p":")==1' "$STATE_FILE" 2>/dev/null | wc -l)
  if [ "$in_use" -gt 0 ]; then
    info "WARN: $in_use existing proxy(ies) still use prefix $prefix"
    info "      They will keep working but you should 'remove --ipv4 ...' if obsolete"
  fi

  grep -vxF "$prefix" "$PREFIX_FILE" > "$PREFIX_FILE.tmp"
  mv "$PREFIX_FILE.tmp" "$PREFIX_FILE"
  chmod 600 "$PREFIX_FILE"
  info "Removed prefix: $prefix"
}

cmd_list_prefixes() {
  if [ -s "$PREFIX_FILE" ]; then
    info "Prefixes from $PREFIX_FILE:"
    grep -vE '^\s*(#|$)' "$PREFIX_FILE" | nl -w2 -s'. '
  else
    info "No $PREFIX_FILE — falling back to interface detection:"
    detect_ipv6_prefix "$(detect_iface)"
  fi
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
  info "Proxies per /64 prefix:"
  awk -F'\t' '{n=split($5,a,":"); print a[1]":"a[2]":"a[3]":"a[4]}' "$STATE_FILE" \
    | sort | uniq -c \
    | awk '{printf "  %-30s %s\n", $2, $1" proxies"}'
  info ""
  info "3proxy:         $(systemctl is-active 3proxy 2>/dev/null || echo unknown)"
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
  install)         cmd_install        "$@";;
  setup)           cmd_setup          "$@";;
  extend)          cmd_extend         "$@";;
  list)            cmd_list           "$@";;
  rebuild)         cmd_rebuild        "$@";;
  remove)          cmd_remove         "$@";;
  add-prefix)      cmd_add_prefix     "$@";;
  remove-prefix)   cmd_remove_prefix  "$@";;
  list-prefixes|prefixes) cmd_list_prefixes "$@";;
  test)            cmd_test           "$@";;
  status)          cmd_status         "$@";;
  help|-h|--help)  usage;;
  *) usage; exit 1;;
esac
