#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${APP_DIR:-firebase-auto-app}"
PROJECT_ID="${PROJECT_ID:-}"
SITE_ID="${SITE_ID:-}"
NON_INTERACTIVE="${NON_INTERACTIVE:-0}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "❌ Thiếu lệnh: $1"
    exit 1
  }
}

ask_if_empty() {
  local var_name="$1"
  local prompt="$2"
  local current="${!var_name:-}"
  if [ -z "$current" ]; then
    if [ "$NON_INTERACTIVE" = "1" ]; then
      echo "❌ Thiếu giá trị bắt buộc: $var_name"
      exit 1
    fi
    read -r -p "$prompt" "$var_name"
    export "$var_name"="${!var_name}"
  fi
}

echo "==> Kiểm tra tool"
need_cmd gcloud
need_cmd firebase

echo "==> Kiểm tra account hiện tại"
ACTIVE_ACCOUNT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' | head -n1 || true)"
if [ -z "${ACTIVE_ACCOUNT}" ]; then
  echo "❌ Cloud Shell chưa có account active trong gcloud."
  echo "Chạy: gcloud auth login"
  exit 1
fi
echo "   Account: ${ACTIVE_ACCOUNT}"

echo "==> Lấy project hiện tại từ gcloud"
if [ -z "${PROJECT_ID}" ]; then
  PROJECT_ID="$(gcloud config get-value project 2>/dev/null || true)"
  if [ "${PROJECT_ID}" = "(unset)" ]; then
    PROJECT_ID=""
  fi
fi

if [ -z "${PROJECT_ID}" ]; then
  echo "⚠️  Chưa có project mặc định trong gcloud."
  if [ "$NON_INTERACTIVE" = "1" ]; then
    echo "❌ Không thể auto tiếp vì chưa có PROJECT_ID."
    exit 1
  fi

  echo "==> Danh sách project bạn đang có quyền:"
  gcloud projects list --format="table(projectId,name,lifecycleState)" || true
  read -r -p "👉 Nhập PROJECT_ID muốn deploy: " PROJECT_ID
  gcloud config set project "${PROJECT_ID}" >/dev/null
else
  echo "   Project: ${PROJECT_ID}"
fi

echo "==> Kiểm tra Firebase CLI có thấy project không"
if ! firebase projects:list >/dev/null 2>&1; then
  echo "⚠️  Firebase CLI chưa dùng được với session hiện tại."
  echo "   Thử đăng nhập bằng chế độ remote..."
  firebase login --no-localhost
fi

echo "==> Kiểm tra project đã add Firebase chưa"
if firebase target:apply hosting __probe__ "${PROJECT_ID}" >/dev/null 2>&1; then
  :
else
  echo "   Đang add Firebase vào project nếu chưa có..."
  set +e
  ADD_OUT="$(firebase projects:addfirebase "${PROJECT_ID}" 2>&1)"
  ADD_RC=$?
  set -e

  if [ $ADD_RC -ne 0 ]; then
    echo "${ADD_OUT}"
    echo
    echo "❌ Không add Firebase tự động được."
    echo "Lý do thường gặp:"
    echo "1) Tài khoản chưa accept Firebase Terms"
    echo "2) Bạn không có đủ quyền trên project"
    echo
    echo "Lưu ý: accept Firebase Terms chỉ làm được trong Firebase Console, không làm bằng CLI."
    exit 1
  fi
fi

echo "==> Tạo source Hosting"
mkdir -p "${APP_DIR}/public"

cat > "${APP_DIR}/public/index.html" <<EOF
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
      max-width: 720px;
    }
    h1 { margin: 0 0 12px; }
    p  { margin: 0; color: #9ca3af; }
  </style>
</head>
<body>
  <div class="card">
    <h1>🔥 Hello World from Firebase Hosting</h1>
    <p>Project: ${PROJECT_ID}</p>
  </div>
</body>
</html>
EOF

cat > "${APP_DIR}/firebase.json" <<'EOF'
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

cd "${APP_DIR}"

echo "==> Kiểm tra site hosting mặc định"
if [ -z "${SITE_ID}" ]; then
  SITE_ID="${PROJECT_ID}"
fi

echo "==> Deploy Hosting"
firebase deploy --only hosting --project "${PROJECT_ID}" --non-interactive

echo
echo "====================================="
echo "✅ Deploy xong"
echo "Project : ${PROJECT_ID}"
echo "URL     : https://${PROJECT_ID}.web.app"
echo "Backup  : https://${PROJECT_ID}.firebaseapp.com"
echo "====================================="
