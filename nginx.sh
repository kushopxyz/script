#!/usr/bin/env bash
# =========================
# PRODUCTION NGINX SETUP
# Ubuntu 24.04
# No domain, IP access only
# =========================

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run this script as root: sudo bash $0"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

WEB_ROOT="/var/www/html"
NGINX_MAIN_CONF="/etc/nginx/nginx.conf"
DEFAULT_SITE_CONF="/etc/nginx/sites-available/default"
BACKUP_DIR="/root/nginx-backup-$(date +%F-%H%M%S)"

echo "==> Creating backup directory: ${BACKUP_DIR}"
mkdir -p "${BACKUP_DIR}"

echo "==> Updating package index"
apt update -y

echo "==> Installing packages"
apt install -y nginx ufw curl

echo "==> Backing up existing Nginx config"
cp -a /etc/nginx "${BACKUP_DIR}/nginx-full-backup"

echo "==> Creating web root"
mkdir -p "${WEB_ROOT}"

cat > "${WEB_ROOT}/index.html" <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width,initial-scale=1.0">
  <title>Nginx Production Ready</title>
  <style>
    body {
      margin: 0;
      background: #0f172a;
      color: #e5e7eb;
      font-family: Arial, sans-serif;
      display: grid;
      place-items: center;
      height: 100vh;
    }
    .card {
      background: #111827;
      padding: 32px;
      border-radius: 16px;
      box-shadow: 0 10px 30px rgba(0,0,0,.35);
      text-align: center;
      max-width: 720px;
    }
    h1 { margin: 0 0 12px; }
    p  { margin: 0; color: #9ca3af; }
    code {
      background: #1f2937;
      padding: 2px 8px;
      border-radius: 6px;
      color: #93c5fd;
    }
  </style>
</head>
<body>
  <div class="card">
    <h1>Nginx is running</h1>
    <p>This server is configured for production baseline on Ubuntu 24.04.</p>
  </div>
</body>
</html>
EOF

echo "==> Writing optimized nginx.conf"
cat > "${NGINX_MAIN_CONF}" <<'EOF'
user www-data;
worker_processes auto;
worker_rlimit_nofile 65535;
pid /run/nginx.pid;

events {
    worker_connections 4096;
    multi_accept on;
    use epoll;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # Basic settings
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    server_tokens off;
    types_hash_max_size 2048;
    client_max_body_size 20M;
    keepalive_timeout 15;
    keepalive_requests 1000;
    reset_timedout_connection on;

    # Timeouts
    client_body_timeout 12;
    client_header_timeout 12;
    send_timeout 10;

    # Logging
    log_format main '$remote_addr - $remote_user [$time_local] '
                    '"$request" $status $body_bytes_sent '
                    '"$http_referer" "$http_user_agent" '
                    'rt=$request_time ua="$upstream_addr" '
                    'us="$upstream_status" ut="$upstream_response_time" '
                    'ul="$upstream_response_length"';
    access_log /var/log/nginx/access.log main;
    error_log /var/log/nginx/error.log warn;

    # Gzip
    gzip on;
    gzip_comp_level 5;
    gzip_min_length 1024;
    gzip_proxied any;
    gzip_vary on;
    gzip_types
        text/plain
        text/css
        text/xml
        text/javascript
        application/json
        application/javascript
        application/xml+rss
        application/xml
        image/svg+xml;

    # Hide nginx version in fastcgi/proxy headers if used later
    proxy_hide_header X-Powered-By;
    fastcgi_hide_header X-Powered-By;

    # Rate limiting
    limit_req_zone $binary_remote_addr zone=req_limit_per_ip:10m rate=10r/s;
    limit_conn_zone $binary_remote_addr zone=conn_limit_per_ip:10m;

    # Include configs
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF

echo "==> Writing production default site config"
cat > "${DEFAULT_SITE_CONF}" <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    root /var/www/html;
    index index.html;

    charset utf-8;

    access_log /var/log/nginx/default_access.log main;
    error_log /var/log/nginx/default_error.log warn;

    # Rate limiting
    limit_req zone=req_limit_per_ip burst=20 nodelay;
    limit_conn conn_limit_per_ip 20;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;

    # Disable access to hidden files except .well-known if needed later
    location ~ /\.(?!well-known).* {
        deny all;
        access_log off;
        log_not_found off;
    }

    location / {
        try_files $uri $uri/ =404;
    }

    # Static asset caching example
    location ~* \.(css|js|jpg|jpeg|png|gif|ico|svg|webp|woff|woff2)$ {
        expires 7d;
        add_header Cache-Control "public, max-age=604800, immutable";
        access_log off;
    }
}
EOF

echo "==> Ensuring sites-enabled/default points to sites-available/default"
rm -f /etc/nginx/sites-enabled/default
ln -s /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default

echo "==> Testing Nginx configuration"
nginx -t

echo "==> Enabling and restarting Nginx"
systemctl enable nginx
systemctl restart nginx

echo "==> Configuring firewall"
ufw allow OpenSSH
ufw allow 'Nginx Full'
ufw --force enable

IP_ADDR="$(hostname -I | awk '{print $1}')"

echo
echo "========================================"
echo "Nginx production baseline setup complete"
echo "Backup: ${BACKUP_DIR}"
echo "URL: http://${IP_ADDR}"
echo "========================================"
