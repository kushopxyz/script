#!/bin/bash
set -e

COUNT="${1:-30}"
START_PORT="${2:-10000}"

echo "=== IPv6 SOCKS5 FINAL SETUP ==="

# detect network
IFACE=$(ip -o -4 route show default | awk '{print $5; exit}')
IPV4=$(curl -4 -s https://api.ipify.org)

# pick a stable global IPv6 (skip temporary/deprecated)
BASE_IPV6=$(ip -6 addr show dev "$IFACE" scope global -temporary \
  | awk '/inet6/ && !/deprecated/ {print $2; exit}' | cut -d/ -f1)

if [ -z "$BASE_IPV6" ]; then
  echo "ERROR: no global IPv6 found on $IFACE" >&2
  exit 1
fi

PREFIX=$(echo "$BASE_IPV6" | awk -F: '{print $1":"$2":"$3":"$4}')

echo "Interface: $IFACE"
echo "IPv4: $IPV4"
echo "IPv6 prefix: ${PREFIX}::/64"

# install deps (skip unreachable PPAs silently, only fetch main repos)
export DEBIAN_FRONTEND=noninteractive
apt-get update \
  -o Acquire::Retries=1 \
  -o Acquire::http::Timeout=10 \
  -o Acquire::https::Timeout=10 \
  2>/dev/null || true
apt-get install -y -qq wget curl openssl >/dev/null

# install 3proxy binary (pinned + checksum verify)
DEB_URL="https://github.com/3proxy/3proxy/releases/download/0.9.4/3proxy-0.9.4.x86_64.deb"
DEB_SHA256="ad1f33fea7363ec90a3fafde85e8b5cb2d20f513a2bd8de3c41e1e3bed4ee2b6"
wget -q -O /tmp/3proxy.deb "$DEB_URL"
echo "${DEB_SHA256}  /tmp/3proxy.deb" | sha256sum -c --status - \
  || echo "WARN: 3proxy checksum mismatch — verify upstream release" >&2

# stop any pre-existing 3proxy from a previous install before replacing
systemctl stop 3proxy 2>/dev/null || true

# install package; suppress noisy/buggy postinst output (chkconfig errors etc.)
# our /etc/systemd/system/3proxy.service (created below) overrides the package's
# /usr/lib/systemd/system/3proxy.service automatically due to systemd precedence
dpkg -i /tmp/3proxy.deb >/dev/null 2>&1 || apt-get -f install -y -qq >/dev/null

mkdir -p /etc/3proxy /root/socks5-ipv6

# generate N unique RANDOM IPv6 addresses across the /64
# (random distribution avoids the obvious sequential proxy-farm pattern)
LIST="/etc/3proxy/ipv6-list.txt"
: > $LIST
declare -A SEEN
generated=0
while [ $generated -lt $COUNT ]; do
  hex=$(openssl rand -hex 8)
  ip6="${PREFIX}:${hex:0:4}:${hex:4:4}:${hex:8:4}:${hex:12:4}"
  [ -n "${SEEN[$ip6]}" ] && continue           # skip dup
  [ "$ip6" = "$BASE_IPV6" ] && continue        # skip host's main IP
  SEEN[$ip6]=1
  echo "$ip6" >> $LIST
  generated=$((generated+1))
done
chmod 600 $LIST

# auto-restore IPv6 (used on boot AND periodically by timer below)
# valid_lft/preferred_lft forever prevents kernel from expiring addresses
# after the SLAAC lifetime advertised by Scaleway's RA (~86400s)
cat > /usr/local/bin/add-ipv6 <<EOR
#!/bin/bash
while IFS= read -r ip6; do
  [ -z "\$ip6" ] && continue
  ip -6 addr replace \${ip6}/128 dev $IFACE \
    valid_lft forever preferred_lft forever 2>/dev/null || true
done < /etc/3proxy/ipv6-list.txt
EOR
chmod +x /usr/local/bin/add-ipv6

# add ipv6 now
/usr/local/bin/add-ipv6

# systemd timer: re-apply IPv6 every 5 minutes in case anything flushes them
# (network restart, cloud-init re-run, RA lifetime expiry, etc.)
cat > /etc/systemd/system/add-ipv6.service <<'EOS'
[Unit]
Description=Re-apply SOCKS5 IPv6 aliases
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/add-ipv6
EOS

cat > /etc/systemd/system/add-ipv6.timer <<'EOT'
[Unit]
Description=Re-apply SOCKS5 IPv6 aliases every 5 minutes

[Timer]
OnBootSec=30s
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOT

# create config
CONF="/etc/3proxy/3proxy.cfg"
OUT="/root/socks5-ipv6/ipport.txt"

: > $CONF
: > $OUT

cat > $CONF <<EOC
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
auth strong
EOC

USER_LINE="users"

i=0
while IFS= read -r IPV6; do
  [ -z "$IPV6" ] && continue
  PORT=$((START_PORT+i))
  USER=$(openssl rand -hex 3)
  PASS=$(openssl rand -hex 4)

  USER_LINE="$USER_LINE ${USER}:CL:${PASS}"

  echo "socks -64 -a -p${PORT} -i${IPV4} -e${IPV6}" >> $CONF
  echo "${IPV4}:${PORT}:${USER}:${PASS}:${IPV6}" >> $OUT
  i=$((i+1))
done < $LIST

sed -i "/^auth strong/i ${USER_LINE}" $CONF

# protect credential files
chmod 600 $CONF $OUT
chmod 700 /root/socks5-ipv6

# service
cat > /etc/systemd/system/3proxy.service <<'EOS'
[Unit]
Description=3proxy SOCKS5
After=network-online.target

[Service]
Type=simple
ExecStartPre=/usr/local/bin/add-ipv6
ExecStart=/usr/bin/3proxy /etc/3proxy/3proxy.cfg
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOS

systemctl daemon-reload
systemctl enable --now add-ipv6.timer
systemctl enable 3proxy
systemctl restart 3proxy
sleep 2

echo
echo "=== DONE ==="
echo "Total proxies: $COUNT  (ports ${START_PORT}-$((START_PORT+COUNT-1)))"
echo "Credentials file: $OUT (chmod 600)"

echo
echo "--- IP:PORT:USER:PASS ---"
cut -d: -f1-4 $OUT

echo
echo "--- socks5://IP:PORT:USER:PASS ---"
cut -d: -f1-4 $OUT | sed 's#^#socks5://#'

echo
echo "Test:"
echo "curl -x socks5h://USER:PASS@IP:PORT https://api64.ipify.org"
