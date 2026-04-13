#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="firebase-spark-plus"
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

PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')"
ACCESS_TOKEN="$(gcloud auth print-access-token)"
FIREBASE_PARENT="projects/${PROJECT_ID}"

info "Project ID      : ${PROJECT_ID}"
info "Project Number  : ${PROJECT_NUMBER}"
info "Account         : ${ACCOUNT}"
info "Region          : ${REGION}"
info "App directory   : ${APP_DIR}"

info "Bật các API cần thiết..."
gcloud services enable \
  firebase.googleapis.com \
  firebasehosting.googleapis.com \
  firestore.googleapis.com \
  identitytoolkit.googleapis.com \
  firebaseextensions.googleapis.com \
  --project "${PROJECT_ID}"
ok "Đã bật API"

info "Thêm Firebase vào project (nếu chưa có)..."
firebase projects:addfirebase "${PROJECT_ID}" --non-interactive >/dev/null 2>&1 || true
ok "Firebase project sẵn sàng"

info "Kiểm tra Cloud Firestore default database..."
if gcloud firestore databases describe --database="(default)" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  ok "Cloud Firestore default database đã tồn tại"
else
  info "Tạo Cloud Firestore default database tại ${REGION}..."
  gcloud firestore databases create \
    --project="${PROJECT_ID}" \
    --database="(default)" \
    --location="${REGION}" \
    --type=firestore-native
  ok "Đã tạo Cloud Firestore default database"
fi

info "Tìm hoặc tạo Firebase Web App..."
WEB_APPS_JSON="$(curl -fsSL \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  "https://firebase.googleapis.com/v1beta1/${FIREBASE_PARENT}/webApps")"

WEB_APP_ID="$(printf '%s' "${WEB_APPS_JSON}" | jq -r '.apps[0].appId // empty')"

if [[ -z "${WEB_APP_ID}" ]]; then
  info "Chưa có Web App, đang tạo mới..."
  WEB_APP_ID="$(curl -fsSL \
    -X POST \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    "https://firebase.googleapis.com/v1beta1/${FIREBASE_PARENT}/webApps" \
    -d "{\"displayName\":\"${WEB_APP_NICKNAME}\"}" \
    | jq -r '.appId')"
  ok "Đã tạo Web App: ${WEB_APP_ID}"
else
  ok "Đã tìm thấy Web App: ${WEB_APP_ID}"
fi

info "Lấy cấu hình Web App..."
WEB_CONFIG_JSON="$(curl -fsSL \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  "https://firebase.googleapis.com/v1beta1/${FIREBASE_PARENT}/webApps/${WEB_APP_ID}/config")"

API_KEY="$(printf '%s' "${WEB_CONFIG_JSON}" | jq -r '.apiKey')"
AUTH_DOMAIN="$(printf '%s' "${WEB_CONFIG_JSON}" | jq -r '.authDomain')"
STORAGE_BUCKET="$(printf '%s' "${WEB_CONFIG_JSON}" | jq -r '.storageBucket // empty')"
MESSAGING_SENDER_ID="$(printf '%s' "${WEB_CONFIG_JSON}" | jq -r '.messagingSenderId')"
APP_ID="$(printf '%s' "${WEB_CONFIG_JSON}" | jq -r '.appId')"
MEASUREMENT_ID="$(printf '%s' "${WEB_CONFIG_JSON}" | jq -r '.measurementId // empty')"

mkdir -p "${APP_DIR}/public"

info "Tạo source app..."
cat > "${APP_DIR}/public/index.html" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width,initial-scale=1.0">
  <title>Firebase Spark Plus</title>
  <style>
    :root {
      --bg: #0f172a;
      --card: #111827;
      --line: #334155;
      --text: #e5e7eb;
      --muted: #94a3b8;
      --accent: #22c55e;
      --accent2: #38bdf8;
      --danger: #ef4444;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: Arial, sans-serif;
      background: linear-gradient(135deg, #020617, #0f172a);
      color: var(--text);
      min-height: 100vh;
      padding: 24px;
    }
    .wrap {
      max-width: 920px;
      margin: 0 auto;
      display: grid;
      gap: 20px;
    }
    .card {
      background: rgba(17,24,39,.92);
      border: 1px solid var(--line);
      border-radius: 18px;
      padding: 22px;
      box-shadow: 0 10px 30px rgba(0,0,0,.25);
    }
    h1, h2 { margin: 0 0 12px; }
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
      background: var(--accent);
      color: #052e16;
      font-weight: 700;
      cursor: pointer;
      margin-top: 12px;
    }
    button.secondary {
      background: var(--accent2);
      color: #082f49;
    }
    button.danger {
      background: var(--danger);
      color: white;
    }
    .row {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 16px;
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
      font-size: 13px;
      margin-top: 10px;
      color: var(--muted);
    }
    @media (max-width: 720px) {
      .row { grid-template-columns: 1fr; }
    }
  </style>
</head>
<body>
  <div class="wrap">
    <div class="card">
      <h1>🔥 Firebase Spark Plus</h1>
      <p>Hosting + Firestore + Web App config tự động. Project hiện tại: <code>${PROJECT_ID}</code></p>
      <div class="status" id="status">Đang khởi tạo...</div>
    </div>

    <div class="row">
      <div class="card">
        <h2>Thêm ghi chú</h2>
        <input id="name" placeholder="Tên của bạn" />
        <textarea id="message" rows="4" placeholder="Nhập nội dung..."></textarea>
        <button id="saveBtn">Lưu vào Firestore</button>
        <div class="status">Demo này ghi dữ liệu vào collection <code>guestbook</code>.</div>
      </div>

      <div class="card">
        <h2>Thông tin dự án</h2>
        <p><strong>Project ID:</strong> <code>${PROJECT_ID}</code></p>
        <p><strong>Region:</strong> <code>${REGION}</code></p>
        <p><strong>Web App ID:</strong> <code>${APP_ID}</code></p>
        <p><strong>Auth:</strong> API đã bật. Muốn login thật, bật provider trong Firebase Console.</p>
      </div>
    </div>

    <div class="card">
      <h2>Danh sách ghi chú realtime</h2>
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
      appId: "${APP_ID}"$( [[ -n "${MEASUREMENT_ID}" ]] && printf ',\n      measurementId: "%s"' "${MEASUREMENT_ID}" )
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
      statusEl.textContent = "Kết nối Firestore thành công.";
    }, (error) => {
      console.error(error);
      statusEl.textContent = "Firestore chưa sẵn sàng hoặc rules chưa cho phép.";
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
        alert("Không ghi được dữ liệu. Kiểm tra Firestore hoặc rules.");
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
  },
  "emulators": {
    "hosting": {
      "port": 5000
    },
    "firestore": {
      "port": 8080
    },
    "ui": {
      "enabled": true,
      "port": 4000
    }
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

cd "${APP_DIR}"

info "Deploy Firestore rules + Hosting..."
firebase deploy --only firestore,hosting --project "${PROJECT_ID}" --non-interactive

echo
ok "Triển khai hoàn tất"
echo "Project        : ${PROJECT_ID}"
echo "Web App ID     : ${WEB_APP_ID}"
echo "Hosting URL    : https://${PROJECT_ID}.web.app"
echo "Backup URL     : https://${PROJECT_ID}.firebaseapp.com"
echo "Firestore DB   : (default) @ ${REGION}"
echo
warn "Nếu muốn dùng đăng nhập Email/Password hoặc Google Sign-In:"
warn "Firebase Console -> Authentication -> Sign-in method -> Enable provider"
warn "Script này đã bật API, nhưng provider vẫn cần bật trong console."
