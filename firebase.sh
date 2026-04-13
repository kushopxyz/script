#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="firebase-spark-pro"
WEB_APP_NICKNAME="spark-web"
DEFAULT_REGION="asia-southeast1"

info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[ERR ]\033[0m %s\n' "$*" >&2; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    err "Thiếu lệnh: $1"
    exit 1
  }
}

retry() {
  local attempts="$1"
  local sleep_seconds="$2"
  shift 2

  local n=1
  until "$@"; do
    if [[ "$n" -ge "$attempts" ]]; then
      return 1
    fi
    warn "Lệnh thất bại. Thử lại lần $((n + 1))/${attempts} sau ${sleep_seconds}s..."
    sleep "$sleep_seconds"
    n=$((n + 1))
  done
}

api_get() {
  local url="$1"
  curl -fsSL \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    "$url"
}

api_post() {
  local url="$1"
  local data="$2"
  curl -fsSL \
    -X POST \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    "$url" \
    -d "$data"
}

json_field() {
  local json="$1"
  local expr="$2"
  printf '%s' "$json" | jq -r "$expr"
}

create_or_get_web_app() {
  local apps_json
  apps_json="$(api_get "https://firebase.googleapis.com/v1beta1/${FIREBASE_PARENT}/webApps" || true)"

  WEB_APP_ID="$(json_field "${apps_json}" '.apps[0].appId // empty')"
  if [[ -n "${WEB_APP_ID}" && "${WEB_APP_ID}" != "null" ]]; then
    ok "Đã tìm thấy Web App có sẵn: ${WEB_APP_ID}"
    return 0
  fi

  local resp=""
  local i
  for i in 1 2 3 4 5 6; do
    info "Tạo Firebase Web App... lần ${i}/6"
    resp="$(api_post \
      "https://firebase.googleapis.com/v1beta1/${FIREBASE_PARENT}/webApps" \
      "{\"displayName\":\"${WEB_APP_NICKNAME}\"}" || true)"

    WEB_APP_ID="$(json_field "${resp}" '.appId // empty')"

    if [[ -n "${WEB_APP_ID}" && "${WEB_APP_ID}" != "null" ]]; then
      ok "Đã tạo Web App: ${WEB_APP_ID}"
      return 0
    fi

    warn "Tạo Web App chưa thành công."
    printf '%s\n' "${resp}" | jq . 2>/dev/null || printf '%s\n' "${resp}"
    sleep 10
  done

  err "Không tạo được Firebase Web App sau nhiều lần thử."
  return 1
}

get_web_app_config() {
  local resp=""
  local i
  for i in 1 2 3 4 5 6; do
    info "Lấy cấu hình Web App... lần ${i}/6"
    resp="$(api_get \
      "https://firebase.googleapis.com/v1beta1/${FIREBASE_PARENT}/webApps/${WEB_APP_ID}/config" || true)"

    API_KEY="$(json_field "${resp}" '.apiKey // empty')"
    APP_ID="$(json_field "${resp}" '.appId // empty')"

    if [[ -n "${API_KEY}" && -n "${APP_ID}" && "${APP_ID}" != "null" ]]; then
      AUTH_DOMAIN="$(json_field "${resp}" '.authDomain // empty')"
      STORAGE_BUCKET="$(json_field "${resp}" '.storageBucket // empty')"
      MESSAGING_SENDER_ID="$(json_field "${resp}" '.messagingSenderId // empty')"
      MEASUREMENT_ID="$(json_field "${resp}" '.measurementId // empty')"
      ok "Đã lấy cấu hình Web App"
      return 0
    fi

    warn "Config chưa sẵn sàng."
    printf '%s\n' "${resp}" | jq . 2>/dev/null || printf '%s\n' "${resp}"
    sleep 8
  done

  err "Không lấy được cấu hình Web App."
  return 1
}

ensure_firestore() {
  if gcloud firestore databases describe \
      --database="(default)" \
      --project="${PROJECT_ID}" >/dev/null 2>&1; then
    ok "Cloud Firestore default database đã tồn tại"
    return 0
  fi

  info "Tạo Cloud Firestore default database tại ${REGION}..."
  gcloud firestore databases create \
    --project="${PROJECT_ID}" \
    --database="(default)" \
    --location="${REGION}" \
    --type=firestore-native

  ok "Đã tạo Cloud Firestore default database"
}

write_files() {
  mkdir -p "${APP_DIR}/public"

  local measurement_line=""
  if [[ -n "${MEASUREMENT_ID}" && "${MEASUREMENT_ID}" != "null" ]]; then
    measurement_line="measurementId: \"${MEASUREMENT_ID}\","
  fi

  cat > "${APP_DIR}/public/index.html" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width,initial-scale=1.0">
  <title>Firebase Spark Pro</title>
  <style>
    :root {
      --bg: #020617;
      --panel: #111827;
      --line: #334155;
      --text: #e5e7eb;
      --muted: #94a3b8;
      --accent: #22c55e;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      background: linear-gradient(135deg, #020617, #0f172a);
      color: var(--text);
      font-family: Arial, sans-serif;
      min-height: 100vh;
      padding: 24px;
    }
    .wrap {
      max-width: 900px;
      margin: 0 auto;
      display: grid;
      gap: 18px;
    }
    .card {
      background: rgba(17,24,39,.95);
      border: 1px solid var(--line);
      border-radius: 18px;
      padding: 22px;
      box-shadow: 0 10px 30px rgba(0,0,0,.25);
    }
    h1,h2 { margin: 0 0 12px; }
    p { color: var(--muted); }
    input, textarea, button {
      width: 100%;
      border-radius: 12px;
      border: 1px solid var(--line);
      padding: 12px 14px;
      font-size: 14px;
    }
    input, textarea {
      background: #0b1220;
      color: var(--text);
      margin-top: 10px;
    }
    button {
      margin-top: 12px;
      background: var(--accent);
      color: #052e16;
      font-weight: 700;
      cursor: pointer;
    }
    ul {
      list-style: none;
      margin: 0;
      padding: 0;
      display: grid;
      gap: 12px;
    }
    li {
      padding: 14px;
      border-radius: 14px;
      background: #0b1220;
      border: 1px solid var(--line);
    }
    code {
      background: #0b1220;
      border: 1px solid var(--line);
      padding: 2px 6px;
      border-radius: 8px;
    }
    .status {
      color: var(--muted);
      font-size: 13px;
      margin-top: 8px;
    }
  </style>
</head>
<body>
  <div class="wrap">
    <div class="card">
      <h1>🔥 Firebase Spark Pro</h1>
      <p>Hosting + Firestore + auto Web App config</p>
      <p>Project: <code>${PROJECT_ID}</code></p>
      <div class="status" id="status">Đang kết nối Firebase...</div>
    </div>

    <div class="card">
      <h2>Ghi chú realtime</h2>
      <input id="name" placeholder="Tên của bạn" />
      <textarea id="message" rows="4" placeholder="Nhập nội dung..."></textarea>
      <button id="saveBtn">Lưu vào Firestore</button>
    </div>

    <div class="card">
      <h2>Dữ liệu mới nhất</h2>
      <ul id="list"></ul>
    </div>
  </div>

  <script type="module">
    import { initializeApp } from "https://www.gstatic.com/firebasejs/11.6.1/firebase-app.js";
    import {
      getFirestore,
      collection,
      addDoc,
      query,
      orderBy,
      limit,
      onSnapshot,
      serverTimestamp
    } from "https://www.gstatic.com/firebasejs/11.6.1/firebase-firestore.js";

    const firebaseConfig = {
      apiKey: "${API_KEY}",
      authDomain: "${AUTH_DOMAIN}",
      projectId: "${PROJECT_ID}",
      storageBucket: "${STORAGE_BUCKET}",
      messagingSenderId: "${MESSAGING_SENDER_ID}",
      appId: "${APP_ID}",
      ${measurement_line}
    };

    const app = initializeApp(firebaseConfig);
    const db = getFirestore(app);

    const statusEl = document.getElementById("status");
    const listEl = document.getElementById("list");
    const saveBtn = document.getElementById("saveBtn");

    const q = query(collection(db, "guestbook"), orderBy("createdAt", "desc"), limit(20));

    onSnapshot(q, (snapshot) => {
      listEl.innerHTML = "";
      snapshot.forEach((doc) => {
        const data = doc.data();
        const li = document.createElement("li");
        li.innerHTML = "<strong>" + (data.name || "Ẩn danh") + "</strong><br><span>" + (data.message || "") + "</span>";
        listEl.appendChild(li);
      });
      statusEl.textContent = "Firestore đã kết nối.";
    }, (error) => {
      console.error(error);
      statusEl.textContent = "Chưa đọc được Firestore. Kiểm tra rules.";
    });

    saveBtn.addEventListener("click", async () => {
      const name = document.getElementById("name").value.trim();
      const message = document.getElementById("message").value.trim();

      if (!message) {
        alert("Nhập nội dung trước.");
        return;
      }

      saveBtn.disabled = true;
      saveBtn.textContent = "Đang lưu...";

      try {
        await addDoc(collection(db, "guestbook"), {
          name: name || "Ẩn danh",
          message,
          createdAt: serverTimestamp()
        });
        document.getElementById("message").value = "";
        saveBtn.textContent = "Lưu vào Firestore";
      } catch (e) {
        console.error(e);
        alert("Không ghi được dữ liệu.");
        saveBtn.textContent = "Lưu vào Firestore";
      } finally {
        saveBtn.disabled = false;
      }
    });
  </script>
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
    "cleanUrls": true,
    "rewrites": [
      {
        "source": "**",
        "destination": "/index.html"
      }
    ]
  },
  "firestore": {
    "rules": "firestore.rules",
    "indexes": "firestore.indexes.json"
  }
}
EOF

  cat > "${APP_DIR}/firestore.rules" <<'EOF'
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    match /guestbook/{docId} {
      allow read: if true;
      allow write: if true;
    }
  }
}
EOF

  cat > "${APP_DIR}/firestore.indexes.json" <<'EOF'
{
  "indexes": [],
  "fieldOverrides": []
}
EOF

  cat > "${APP_DIR}/.firebaserc" <<EOF
{
  "projects": {
    "default": "${PROJECT_ID}"
  }
}
EOF
}

need_cmd gcloud
need_cmd firebase
need_cmd curl
need_cmd jq
need_cmd sed

PROJECT_ID="$(gcloud config get-value project 2>/dev/null || true)"
ACCOUNT="$(gcloud config get-value account 2>/dev/null || true)"
REGION="$(gcloud config get-value compute/region 2>/dev/null || true)"

if [[ -z "${PROJECT_ID}" || "${PROJECT_ID}" == "(unset)" ]]; then
  err "Chưa có project hiện tại."
  err "Chạy: gcloud config set project YOUR_PROJECT_ID"
  exit 1
fi

if [[ -z "${ACCOUNT}" || "${ACCOUNT}" == "(unset)" ]]; then
  err "Chưa có account đăng nhập."
  err "Chạy: gcloud auth login"
  exit 1
fi

if [[ -z "${REGION}" || "${REGION}" == "(unset)" ]]; then
  REGION="${DEFAULT_REGION}"
fi

ACCESS_TOKEN="$(gcloud auth print-access-token)"
FIREBASE_PARENT="projects/${PROJECT_ID}"

info "Project ID    : ${PROJECT_ID}"
info "Account       : ${ACCOUNT}"
info "Region        : ${REGION}"
info "App directory : ${APP_DIR}"

info "Bật các API cần thiết..."
gcloud services enable \
  firebase.googleapis.com \
  firebasehosting.googleapis.com \
  firestore.googleapis.com \
  identitytoolkit.googleapis.com \
  --project "${PROJECT_ID}"
ok "Đã bật API"

info "Thêm Firebase vào project..."
retry 3 10 firebase projects:addfirebase "${PROJECT_ID}" --non-interactive >/dev/null 2>&1 || true
ok "Đã gửi yêu cầu add Firebase"

info "Đợi Firebase provision..."
sleep 30

ensure_firestore

create_or_get_web_app
get_web_app_config

info "Tạo source code..."
write_files

cd "${APP_DIR}"

info "Deploy Hosting + Firestore..."
firebase deploy --only firestore,hosting --project "${PROJECT_ID}" --non-interactive

echo
ok "Triển khai hoàn tất"
echo "Project        : ${PROJECT_ID}"
echo "Web App ID     : ${WEB_APP_ID}"
echo "Hosting URL    : https://${PROJECT_ID}.web.app"
echo "Backup URL     : https://${PROJECT_ID}.firebaseapp.com"
echo "Firestore DB   : (default) @ ${REGION}"
echo
warn "Script này tối ưu cho Spark/free: Hosting + Firestore + Web App config."
warn "Nếu muốn Auth login thật, cần bật provider trong Firebase Console."
