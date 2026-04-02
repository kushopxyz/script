#!/usr/bin/env bash
set -euo pipefail

APP_DIR="firebase-auto-app"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "❌ Thiếu lệnh: $1"
    exit 1
  }
}

need_cmd gcloud
need_cmd firebase

PROJECT_ID="$(gcloud config get-value project 2>/dev/null || true)"
if [ -z "$PROJECT_ID" ] || [ "$PROJECT_ID" = "(unset)" ]; then
  read -r -p "👉 Nhập PROJECT_ID: " PROJECT_ID
  gcloud config set project "$PROJECT_ID" >/dev/null
fi

echo "==> Project hiện tại: $PROJECT_ID"

echo "==> Bật Firebase Management API"
gcloud services enable firebase.googleapis.com --project "$PROJECT_ID"

echo "==> Bật Firebase Hosting API"
gcloud services enable firebasehosting.googleapis.com --project "$PROJECT_ID" || true

echo "==> Chờ API propagate"
sleep 20

echo "==> Add Firebase vào project"
firebase projects:addfirebase "$PROJECT_ID" || true

echo "==> Tạo source Hosting"
mkdir -p "$APP_DIR/public"

cat > "$APP_DIR/public/index.html" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width,initial-scale=1.0">
  <title>Hello Firebase</title>
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
    }
  </style>
</head>
<body>
  <div class="card">
    <h1>🔥 Hello World from Firebase Hosting</h1>
    <p>Project: $PROJECT_ID</p>
  </div>
</body>
</html>
EOF

cat > "$APP_DIR/firebase.json" <<'EOF'
{
  "hosting": {
    "public": "public",
    "ignore": [
      "firebase.json",
      "**/.*",
      "**/node_modules/**"
    ],
    "cleanUrls": true
  }
}
EOF

cd "$APP_DIR"

echo "==> Deploy Hosting"
firebase deploy --only hosting --project "$PROJECT_ID" --non-interactive

echo
echo "====================================="
echo "✅ Deploy xong"
echo "Project : $PROJECT_ID"
echo "URL     : https://$PROJECT_ID.web.app"
echo "Backup  : https://$PROJECT_ID.firebaseapp.com"
echo "====================================="
