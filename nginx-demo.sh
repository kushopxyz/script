#!/usr/bin/env bash

set -e

echo "==> Tạo thư mục tạm"
mkdir -p nginx-demo/html

echo "==> Tạo file index.html"
cat > nginx-demo/html/index.html <<'EOF'
<!DOCTYPE html>
<html>
<head>
  <title>Hello Nginx</title>
</head>
<body style="background:#111;color:#0f0;font-family:monospace;text-align:center;margin-top:20%;">
  <h1>🚀 Hello World from Nginx (Docker)</h1>
</body>
</html>
EOF

echo "==> Tạo docker-compose.yml"
cat > nginx-demo/docker-compose.yml <<'EOF'
services:
  nginx:
    image: nginx:alpine
    container_name: nginx-demo
    ports:
      - "8080:80"
    volumes:
      - ./html:/usr/share/nginx/html:ro
    restart: unless-stopped
EOF

echo "==> Chạy Docker Compose"
cd nginx-demo
docker compose up -d

echo
echo "====================================="
echo "✅ Nginx đã chạy!"
echo "👉 Mở: http://localhost:8080"
echo "====================================="
