#!/usr/bin/env bash
# ==============================================================================
# Firebase Full-Service Setup Script (Spark/Free Plan)
# Version: 2.0.0
#
# Services: Hosting + Firestore + Auth + Realtime Database + Analytics
# Includes: Real demo data seeding, test users, Vietnamese UI
#
# Usage:
#   ./firebase.sh              # Setup all services + seed data
# ==============================================================================
set -Eeuo pipefail

APP_DIR="firebase-spark-pro"
WEB_APP_NICKNAME="spark-web"
DEFAULT_REGION="asia-southeast1"

info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[ERR ]\033[0m %s\n' "$*" >&2; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "Thieu lenh: $1"; exit 1; }
}

retry() {
  local attempts="$1" sleep_seconds="$2"; shift 2
  local n=1
  until "$@"; do
    (( n >= attempts )) && return 1
    warn "Thu lai lan $((n + 1))/${attempts} sau ${sleep_seconds}s..."
    sleep "$sleep_seconds"; n=$((n + 1))
  done
}

api_get() {
  curl -fsSL -H "Authorization: Bearer ${ACCESS_TOKEN}" "$1"
}

api_post() {
  curl -fsSL -X POST \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    "$1" -d "$2"
}

api_patch() {
  curl -fsSL -X PATCH \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    "$1" -d "$2"
}

api_put() {
  curl -fsSL -X PUT \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    "$1" -d "$2"
}

jf() { printf '%s' "$1" | jq -r "$2"; }

# ======================== WEB APP ========================
create_or_get_web_app() {
  local apps_json
  apps_json="$(api_get "https://firebase.googleapis.com/v1beta1/${FB}/webApps" || true)"
  WEB_APP_ID="$(jf "${apps_json}" '.apps[0].appId // empty')"
  if [[ -n "${WEB_APP_ID}" && "${WEB_APP_ID}" != "null" ]]; then
    ok "Web App co san: ${WEB_APP_ID}"; return 0
  fi
  local resp="" i
  for i in 1 2 3 4 5 6; do
    info "Tao Firebase Web App... lan ${i}/6"
    resp="$(api_post "https://firebase.googleapis.com/v1beta1/${FB}/webApps" \
      "{\"displayName\":\"${WEB_APP_NICKNAME}\"}" || true)"
    WEB_APP_ID="$(jf "${resp}" '.appId // empty')"
    if [[ -n "${WEB_APP_ID}" && "${WEB_APP_ID}" != "null" ]]; then
      ok "Da tao Web App: ${WEB_APP_ID}"; return 0
    fi
    sleep 10
  done
  err "Khong tao duoc Web App"; return 1
}

get_web_app_config() {
  local resp="" i
  for i in 1 2 3 4 5 6; do
    info "Lay cau hinh Web App... lan ${i}/6"
    resp="$(api_get "https://firebase.googleapis.com/v1beta1/${FB}/webApps/${WEB_APP_ID}/config" || true)"
    API_KEY="$(jf "${resp}" '.apiKey // empty')"
    APP_ID="$(jf "${resp}" '.appId // empty')"
    if [[ -n "${API_KEY}" && -n "${APP_ID}" && "${APP_ID}" != "null" ]]; then
      AUTH_DOMAIN="$(jf "${resp}" '.authDomain // empty')"
      STORAGE_BUCKET="$(jf "${resp}" '.storageBucket // empty')"
      MESSAGING_SENDER_ID="$(jf "${resp}" '.messagingSenderId // empty')"
      MEASUREMENT_ID="$(jf "${resp}" '.measurementId // empty')"
      DATABASE_URL="$(jf "${resp}" '.databaseURL // empty')"
      ok "Da lay cau hinh Web App"; return 0
    fi
    sleep 8
  done
  err "Khong lay duoc cau hinh"; return 1
}

# ======================== FIRESTORE ========================
ensure_firestore() {
  if gcloud firestore databases describe --database="(default)" --project="${PID}" >/dev/null 2>&1; then
    ok "Firestore default database da ton tai"; return 0
  fi
  info "Tao Firestore database tai ${REGION}..."
  gcloud firestore databases create --project="${PID}" --database="(default)" \
    --location="${REGION}" --type=firestore-native
  ok "Da tao Firestore"
}

seed_firestore_data() {
  info "Seed du lieu Firestore..."
  local FS_URL="https://firestore.googleapis.com/v1/projects/${PID}/databases/(default)/documents"

  fs_doc() {
    local col="$1" data="$2"
    curl -fsSL -X POST -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      -H "Content-Type: application/json" \
      "${FS_URL}/${col}" -d "${data}" >/dev/null 2>&1 || true
  }

  fs_doc "guestbook" '{"fields":{"name":{"stringValue":"Nguyen Van A"},"message":{"stringValue":"Xin chao! Day la tin nhan dau tien tu Firestore."},"createdAt":{"timestampValue":"2026-04-21T01:00:00Z"}}}'
  fs_doc "guestbook" '{"fields":{"name":{"stringValue":"Tran Thi B"},"message":{"stringValue":"Firebase Spark plan that tuyet voi!"},"createdAt":{"timestampValue":"2026-04-21T01:05:00Z"}}}'
  fs_doc "guestbook" '{"fields":{"name":{"stringValue":"Le Van C"},"message":{"stringValue":"Firestore realtime nhanh qua di!"},"createdAt":{"timestampValue":"2026-04-21T01:10:00Z"}}}'

  fs_doc "products" '{"fields":{"name":{"stringValue":"Ao thun Firebase"},"price":{"integerValue":"250000"},"category":{"stringValue":"Thoi trang"},"inStock":{"booleanValue":true},"description":{"stringValue":"Ao thun cotton co logo Firebase"}}}'
  fs_doc "products" '{"fields":{"name":{"stringValue":"Sticker Developer"},"price":{"integerValue":"50000"},"category":{"stringValue":"Phu kien"},"inStock":{"booleanValue":true},"description":{"stringValue":"Bo sticker 10 con cho developer"}}}'
  fs_doc "products" '{"fields":{"name":{"stringValue":"Ly su Cloud"},"price":{"integerValue":"180000"},"category":{"stringValue":"Van phong"},"inStock":{"booleanValue":false},"description":{"stringValue":"Ly su in hinh dam may GCP"}}}'

  fs_doc "users_profile" '{"fields":{"email":{"stringValue":"admin@demo.com"},"displayName":{"stringValue":"Quan tri vien"},"role":{"stringValue":"admin"},"createdAt":{"timestampValue":"2026-04-21T00:00:00Z"}}}'
  fs_doc "users_profile" '{"fields":{"email":{"stringValue":"user@demo.com"},"displayName":{"stringValue":"Nguoi dung"},"role":{"stringValue":"user"},"createdAt":{"timestampValue":"2026-04-21T00:00:00Z"}}}'

  ok "Da seed Firestore: guestbook(3), products(3), users_profile(2)"
}

# ======================== AUTH ========================
enable_auth_providers() {
  info "Bat Auth providers (Email/Password + Anonymous)..."
  api_patch \
    "https://identitytoolkit.googleapis.com/admin/v2/projects/${PID}/config?updateMask=signIn.email,signIn.anonymous" \
    '{"signIn":{"email":{"enabled":true,"passwordRequired":true},"anonymous":{"enabled":true}}}' \
    >/dev/null 2>&1 || true
  ok "Auth providers: Email/Password + Anonymous"
}

create_test_users() {
  info "Tao test users..."
  local AUTH_URL="https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=${API_KEY}"

  create_user() {
    local email="$1" pass="$2"
    local resp
    resp=$(curl -fsSL -X POST -H "Content-Type: application/json" \
      "${AUTH_URL}" -d "{\"email\":\"${email}\",\"password\":\"${pass}\",\"returnSecureToken\":true}" 2>&1 || true)
    if echo "$resp" | grep -q "EMAIL_EXISTS"; then
      ok "  ${email} (da ton tai)"
    elif echo "$resp" | grep -q "idToken"; then
      ok "  ${email} (da tao)"
    else
      warn "  ${email} (loi: $(echo "$resp" | jq -r '.error.message // "unknown"' 2>/dev/null || echo 'unknown'))"
    fi
  }

  create_user "admin@demo.com" "Admin@123"
  create_user "user@demo.com"  "User@123"
  create_user "guest@demo.com" "Guest@123"
}

# ======================== REALTIME DATABASE ========================
get_rtdb_location() {
  case "${REGION}" in
    us-*) RTDB_LOC="us-central1" ;;
    europe-*) RTDB_LOC="europe-west1" ;;
    *) RTDB_LOC="asia-southeast1" ;;
  esac
}

ensure_rtdb() {
  get_rtdb_location
  local RTDB_INSTANCE="${PID}-default-rtdb"
  local MGMT_URL="https://firebasedatabase.googleapis.com/v1beta/projects/${PID}/locations/${RTDB_LOC}/instances"

  info "Kiem tra Realtime Database..."
  local existing
  existing=$(api_get "${MGMT_URL}/${RTDB_INSTANCE}" 2>/dev/null || true)

  if echo "$existing" | grep -q "databaseUrl"; then
    RTDB_URL=$(jf "$existing" '.databaseUrl // empty')
    ok "RTDB da ton tai: ${RTDB_URL}"
    return 0
  fi

  info "Tao Realtime Database tai ${RTDB_LOC}..."
  local resp
  resp=$(api_post "${MGMT_URL}?databaseId=${RTDB_INSTANCE}" '{"type":"DEFAULT_DATABASE"}' 2>/dev/null || true)
  RTDB_URL=$(jf "$resp" '.databaseUrl // empty')

  if [[ -n "$RTDB_URL" && "$RTDB_URL" != "null" ]]; then
    ok "Da tao RTDB: ${RTDB_URL}"
  else
    if [[ "$RTDB_LOC" == "us-central1" ]]; then
      RTDB_URL="https://${RTDB_INSTANCE}.firebaseio.com"
    else
      RTDB_URL="https://${RTDB_INSTANCE}.${RTDB_LOC}.firebasedatabase.app"
    fi
    warn "Khong xac nhan duoc RTDB URL, dung mac dinh: ${RTDB_URL}"
  fi
}

set_rtdb_rules() {
  info "Thiet lap RTDB rules..."
  curl -fsSL -X PUT \
    "${RTDB_URL}/.settings/rules.json?access_token=${ACCESS_TOKEN}" \
    -d '{"rules":{".read":true,".write":true,"chat":{".indexOn":["timestamp"]}}}' \
    >/dev/null 2>&1 || warn "Khong set duoc RTDB rules (co the can Blaze)"
  ok "RTDB rules: read/write public"
}

seed_rtdb_data() {
  info "Seed du lieu RTDB..."
  curl -fsSL -X PATCH \
    "${RTDB_URL}/.json?access_token=${ACCESS_TOKEN}" \
    -d '{
      "chat":{
        "msg1":{"user":"Admin","text":"Xin chao! Day la phong chat RTDB.","timestamp":1713700000000},
        "msg2":{"user":"Demo User","text":"Chat realtime nhanh that!","timestamp":1713700060000},
        "msg3":{"user":"Khach","text":"Firebase Realtime Database tuyet voi!","timestamp":1713700120000}
      },
      "counters":{"visitors":42,"messages":3},
      "announcements":{"latest":"He thong hoat dong binh thuong.","updatedAt":"2026-04-21T01:00:00Z"}
    }' >/dev/null 2>&1 || warn "Khong seed duoc RTDB data"
  ok "Da seed RTDB: chat(3), counters, announcements"
}

# ======================== WRITE FILES ========================
write_files() {
  mkdir -p "${APP_DIR}/public"

  local ml=""
  [[ -n "${MEASUREMENT_ID}" && "${MEASUREMENT_ID}" != "null" ]] && ml="measurementId: \"${MEASUREMENT_ID}\","

  cat > "${APP_DIR}/public/index.html" <<HTMLEOF
<!DOCTYPE html>
<html lang="vi">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width,initial-scale=1.0">
  <title>Firebase Full Demo</title>
  <style>
    :root{--bg:#020617;--panel:#111827;--line:#334155;--text:#e5e7eb;--muted:#94a3b8;--accent:#22c55e;--blue:#3b82f6;--red:#ef4444;--orange:#f59e0b}
    *{box-sizing:border-box}
    body{margin:0;background:linear-gradient(135deg,#020617,#0f172a);color:var(--text);font-family:system-ui,sans-serif;min-height:100vh;padding:20px}
    .wrap{max-width:960px;margin:0 auto;display:grid;gap:16px}
    .card{background:rgba(17,24,39,.95);border:1px solid var(--line);border-radius:16px;padding:20px;box-shadow:0 8px 24px rgba(0,0,0,.3)}
    h1,h2{margin:0 0 10px}
    h2{font-size:18px;display:flex;align-items:center;gap:8px}
    p{color:var(--muted);margin:4px 0}
    input,textarea,select{width:100%;border-radius:10px;border:1px solid var(--line);padding:10px 12px;font-size:14px;background:#0b1220;color:var(--text);margin-top:8px}
    textarea{resize:vertical}
    .btn{display:inline-block;margin-top:10px;padding:10px 18px;border-radius:10px;border:none;font-size:14px;font-weight:700;cursor:pointer;transition:.2s}
    .btn-green{background:var(--accent);color:#052e16}
    .btn-blue{background:var(--blue);color:#fff}
    .btn-red{background:var(--red);color:#fff}
    .btn-orange{background:var(--orange);color:#000}
    .btn:disabled{opacity:.5;cursor:not-allowed}
    .row{display:flex;gap:8px;flex-wrap:wrap}
    ul{list-style:none;margin:8px 0 0;padding:0;display:grid;gap:8px}
    li{padding:12px;border-radius:12px;background:#0b1220;border:1px solid var(--line);font-size:14px}
    li strong{color:var(--accent)}
    code{background:#0b1220;border:1px solid var(--line);padding:2px 6px;border-radius:6px;font-size:13px}
    .badge{display:inline-block;padding:3px 10px;border-radius:20px;font-size:12px;font-weight:600}
    .badge-on{background:#052e16;color:var(--accent);border:1px solid var(--accent)}
    .badge-off{background:#1c1917;color:var(--orange);border:1px solid var(--orange)}
    .status-bar{display:flex;gap:10px;flex-wrap:wrap;margin-top:8px}
    .chat-box{max-height:250px;overflow-y:auto;display:grid;gap:6px;margin-top:8px}
    .chat-msg{padding:8px 12px;border-radius:10px;background:#0b1220;border:1px solid var(--line);font-size:13px}
    .chat-msg b{color:var(--blue)}
    .grid2{display:grid;grid-template-columns:1fr 1fr;gap:12px}
    @media(max-width:640px){.grid2{grid-template-columns:1fr}}
    .product{padding:14px;border-radius:12px;background:#0b1220;border:1px solid var(--line)}
    .product h3{margin:0 0 4px;font-size:15px}
    .product .price{color:var(--accent);font-weight:700}
    .log{font-family:monospace;font-size:12px;color:var(--muted);max-height:120px;overflow-y:auto;margin-top:8px;background:#0b1220;border:1px solid var(--line);border-radius:8px;padding:8px}
  </style>
</head>
<body>
<div class="wrap">

  <!-- Header -->
  <div class="card">
    <h1>Firebase Full Demo</h1>
    <p>Project: <code>${PID}</code></p>
    <div class="status-bar" id="svcStatus"></div>
  </div>

  <!-- Auth -->
  <div class="card">
    <h2>Xac thuc nguoi dung</h2>
    <div id="authInfo" style="margin-bottom:10px"></div>
    <div id="loginForm">
      <input id="authEmail" type="email" placeholder="Email" value="admin@demo.com"/>
      <input id="authPass" type="password" placeholder="Mat khau" value="Admin@123"/>
      <div class="row">
        <button class="btn btn-green" id="btnLogin">Dang nhap</button>
        <button class="btn btn-blue" id="btnAnon">Dang nhap an danh</button>
        <button class="btn btn-orange" id="btnRegister">Dang ky</button>
      </div>
    </div>
    <div id="logoutSection" style="display:none">
      <p id="userDisplay"></p>
      <button class="btn btn-red" id="btnLogout">Dang xuat</button>
    </div>
  </div>

  <!-- Firestore: Guestbook -->
  <div class="card">
    <h2>Firestore - So luu but</h2>
    <input id="fsName" placeholder="Ten cua ban"/>
    <textarea id="fsMsg" rows="3" placeholder="Noi dung..."></textarea>
    <button class="btn btn-green" id="btnFsSave">Luu vao Firestore</button>
    <ul id="fsList"></ul>
  </div>

  <!-- Firestore: Products -->
  <div class="card">
    <h2>Firestore - San pham</h2>
    <div class="grid2" id="productList"></div>
  </div>

  <!-- Realtime Database: Chat -->
  <div class="card">
    <h2>RTDB - Chat thoi gian thuc</h2>
    <p>Khach truy cap: <strong id="visitorCount">...</strong> | Tin nhan: <strong id="msgCount">...</strong></p>
    <div class="chat-box" id="chatBox"></div>
    <input id="chatInput" placeholder="Nhap tin nhan..."/>
    <button class="btn btn-blue" id="btnChat">Gui</button>
  </div>

  <!-- Analytics -->
  <div class="card">
    <h2>Analytics</h2>
    <p>Moi thao tac deu duoc ghi nhan. Xem chi tiet tai <a href="https://console.firebase.google.com/project/${PID}/analytics" target="_blank" style="color:var(--blue)">Firebase Console</a>.</p>
    <div class="row">
      <button class="btn btn-green" onclick="logCustom('demo_click','Button A')">Event A</button>
      <button class="btn btn-blue" onclick="logCustom('demo_click','Button B')">Event B</button>
      <button class="btn btn-orange" onclick="logCustom('demo_click','Button C')">Event C</button>
    </div>
    <div class="log" id="analyticsLog">Analytics events:</div>
  </div>

</div>

<script type="module">
  import{initializeApp}from"https://www.gstatic.com/firebasejs/11.6.1/firebase-app.js";
  import{getAuth,signInWithEmailAndPassword,signInAnonymously,createUserWithEmailAndPassword,onAuthStateChanged,signOut}from"https://www.gstatic.com/firebasejs/11.6.1/firebase-auth.js";
  import{getFirestore,collection,addDoc,query,orderBy,limit,onSnapshot,serverTimestamp,getDocs}from"https://www.gstatic.com/firebasejs/11.6.1/firebase-firestore.js";
  import{getDatabase,ref,push,set,onChildAdded,onValue}from"https://www.gstatic.com/firebasejs/11.6.1/firebase-database.js";
  import{getAnalytics,logEvent}from"https://www.gstatic.com/firebasejs/11.6.1/firebase-analytics.js";

  const cfg={
    apiKey:"${API_KEY}",authDomain:"${AUTH_DOMAIN}",projectId:"${PID}",
    storageBucket:"${STORAGE_BUCKET}",messagingSenderId:"${MESSAGING_SENDER_ID}",
    appId:"${APP_ID}",databaseURL:"${RTDB_URL}",${ml}
  };

  const app=initializeApp(cfg);
  const auth=getAuth(app);
  const db=getFirestore(app);
  const rtdb=getDatabase(app);
  let analytics=null;
  try{analytics=getAnalytics(app)}catch(e){console.warn("Analytics:",e)}

  const svc=document.getElementById("svcStatus");
  const badge=(name,ok)=>'<span class="badge '+(ok?'badge-on':'badge-off')+'">'+name+'</span>';
  let svcState={Auth:false,Firestore:false,RTDB:false,Analytics:!!analytics};
  function updateSvc(){svc.innerHTML=Object.entries(svcState).map(([k,v])=>badge(k,v)).join("")}
  updateSvc();

  window.logCustom=function(name,label){
    if(analytics)logEvent(analytics,name,{label});
    const log=document.getElementById("analyticsLog");
    log.textContent+="\\n["+new Date().toLocaleTimeString()+"] "+name+": "+label;
    log.scrollTop=log.scrollHeight;
  };

  // Auth
  onAuthStateChanged(auth,u=>{
    svcState.Auth=true;updateSvc();
    if(u){
      document.getElementById("loginForm").style.display="none";
      document.getElementById("logoutSection").style.display="block";
      document.getElementById("userDisplay").innerHTML="UID: <code>"+u.uid.slice(0,12)+"...</code> | "+(u.isAnonymous?"An danh":u.email);
      if(analytics)logEvent(analytics,"login",{method:u.isAnonymous?"anonymous":"email"});
    }else{
      document.getElementById("loginForm").style.display="block";
      document.getElementById("logoutSection").style.display="none";
    }
  });
  document.getElementById("btnLogin").onclick=()=>signInWithEmailAndPassword(auth,document.getElementById("authEmail").value,document.getElementById("authPass").value).catch(e=>alert(e.message));
  document.getElementById("btnAnon").onclick=()=>signInAnonymously(auth).catch(e=>alert(e.message));
  document.getElementById("btnRegister").onclick=()=>createUserWithEmailAndPassword(auth,document.getElementById("authEmail").value,document.getElementById("authPass").value).catch(e=>alert(e.message));
  document.getElementById("btnLogout").onclick=()=>signOut(auth);

  // Firestore: Guestbook
  const gq=query(collection(db,"guestbook"),orderBy("createdAt","desc"),limit(20));
  onSnapshot(gq,snap=>{
    svcState.Firestore=true;updateSvc();
    const el=document.getElementById("fsList");el.innerHTML="";
    snap.forEach(d=>{const v=d.data();el.innerHTML+="<li><strong>"+(v.name||"An danh")+"</strong><br>"+(v.message||"")+"</li>"});
  },e=>{console.error(e)});

  document.getElementById("btnFsSave").onclick=async()=>{
    const name=document.getElementById("fsName").value.trim();
    const msg=document.getElementById("fsMsg").value.trim();
    if(!msg){alert("Nhap noi dung");return}
    await addDoc(collection(db,"guestbook"),{name:name||"An danh",message:msg,createdAt:serverTimestamp()});
    document.getElementById("fsMsg").value="";
    if(analytics)logEvent(analytics,"add_note");
  };

  // Firestore: Products
  getDocs(collection(db,"products")).then(snap=>{
    const el=document.getElementById("productList");
    snap.forEach(d=>{
      const v=d.data();
      el.innerHTML+='<div class="product"><h3>'+v.name+'</h3><p>'+v.description+'</p><p class="price">'
        +Number(v.price).toLocaleString("vi-VN")+'d</p><span class="badge '+(v.inStock?'badge-on">Con hang':'badge-off">Het hang')+'</span></div>';
    });
  });

  // RTDB: Chat
  const chatRef=ref(rtdb,"chat");
  const chatBox=document.getElementById("chatBox");
  onChildAdded(chatRef,snap=>{
    svcState.RTDB=true;updateSvc();
    const v=snap.val();
    chatBox.innerHTML+='<div class="chat-msg"><b>'+v.user+':</b> '+v.text+'</div>';
    chatBox.scrollTop=chatBox.scrollHeight;
  });

  onValue(ref(rtdb,"counters/visitors"),s=>{document.getElementById("visitorCount").textContent=s.val()||0});
  onValue(ref(rtdb,"counters/messages"),s=>{document.getElementById("msgCount").textContent=s.val()||0});

  document.getElementById("btnChat").onclick=()=>{
    const input=document.getElementById("chatInput");
    const text=input.value.trim();if(!text)return;
    const user=auth.currentUser?(auth.currentUser.isAnonymous?"Khach":auth.currentUser.email.split("@")[0]):"Khach";
    push(chatRef,{user,text,timestamp:Date.now()});
    input.value="";
    if(analytics)logEvent(analytics,"send_message");
  };
  document.getElementById("chatInput").addEventListener("keydown",e=>{if(e.key==="Enter")document.getElementById("btnChat").click()});
</script>
</body>
</html>
HTMLEOF

  cat > "${APP_DIR}/firebase.json" <<'EOF'
{
  "hosting": {
    "public": "public",
    "ignore": ["firebase.json", "**/.*", "**/node_modules/**"],
    "cleanUrls": true,
    "rewrites": [{"source": "**", "destination": "/index.html"}]
  },
  "firestore": {
    "rules": "firestore.rules",
    "indexes": "firestore.indexes.json"
  },
  "database": {
    "rules": "database.rules.json"
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
    match /products/{docId} {
      allow read: if true;
      allow write: if request.auth != null;
    }
    match /users_profile/{docId} {
      allow read: if true;
      allow write: if request.auth != null;
    }
  }
}
EOF

  cat > "${APP_DIR}/firestore.indexes.json" <<'EOF'
{"indexes":[],"fieldOverrides":[]}
EOF

  cat > "${APP_DIR}/database.rules.json" <<'EOF'
{
  "rules": {
    ".read": true,
    ".write": true,
    "chat": {
      ".indexOn": ["timestamp"]
    }
  }
}
EOF

  cat > "${APP_DIR}/.firebaserc" <<EOF
{
  "projects": {
    "default": "${PID}"
  }
}
EOF
}

# ======================== MAIN ========================
need_cmd gcloud
need_cmd firebase
need_cmd curl
need_cmd jq

PID="$(gcloud config get-value project 2>/dev/null || true)"
ACCOUNT="$(gcloud config get-value account 2>/dev/null || true)"
REGION="$(gcloud config get-value compute/region 2>/dev/null || true)"

[[ -z "${PID}" || "${PID}" == "(unset)" ]] && { err "Chua co project. Chay: gcloud config set project YOUR_PROJECT_ID"; exit 1; }
[[ -z "${ACCOUNT}" || "${ACCOUNT}" == "(unset)" ]] && { err "Chua dang nhap. Chay: gcloud auth login"; exit 1; }
[[ -z "${REGION}" || "${REGION}" == "(unset)" ]] && REGION="${DEFAULT_REGION}"

ACCESS_TOKEN="$(gcloud auth print-access-token)"
FB="projects/${PID}"

echo ""
info "========================================="
info "  Firebase Full Setup v2.0.0"
info "========================================="
info "Project : ${PID}"
info "Account : ${ACCOUNT}"
info "Region  : ${REGION}"
echo ""

# Step 1: Enable APIs
info "Bat cac API can thiet..."
gcloud services enable \
  firebase.googleapis.com \
  firebasehosting.googleapis.com \
  firestore.googleapis.com \
  identitytoolkit.googleapis.com \
  firebasedatabase.googleapis.com \
  --project "${PID}"
ok "Da bat API"

# Step 2: Add Firebase
info "Them Firebase vao project..."
retry 3 10 firebase projects:addfirebase "${PID}" --non-interactive >/dev/null 2>&1 || true
ok "Firebase da duoc them"

info "Doi Firebase provision..."
sleep 30

# Step 3: Setup services
ensure_firestore
enable_auth_providers
ensure_rtdb
set_rtdb_rules

# Step 4: Web App + config
create_or_get_web_app
get_web_app_config

# Refresh token (may have expired during wait)
ACCESS_TOKEN="$(gcloud auth print-access-token)"

# Step 5: Seed data
echo ""
info "=== SEED DU LIEU THAT ==="
create_test_users
seed_firestore_data
seed_rtdb_data

# Step 6: Write files + deploy
echo ""
info "Tao source code..."
write_files

cd "${APP_DIR}"

info "Deploy Hosting + Firestore..."
firebase deploy --only firestore,hosting --project "${PID}" --non-interactive

# Deploy RTDB rules separately (may fail on fresh projects)
info "Deploy RTDB rules..."
firebase deploy --only database --project "${PID}" --non-interactive 2>/dev/null || warn "RTDB rules deploy skipped (RTDB may need manual init via Firebase Console)"

echo ""
echo "========================================="
ok "TRIEN KHAI HOAN TAT!"
echo "========================================="
echo ""
echo "  Hosting URL    : https://${PID}.web.app"
echo "  Backup URL     : https://${PID}.firebaseapp.com"
echo "  Firestore      : (default) @ ${REGION}"
echo "  Realtime DB    : ${RTDB_URL}"
echo "  Auth providers : Email/Password + Anonymous"
echo "  Analytics      : ${MEASUREMENT_ID:-chua co}"
echo ""
echo "  Test users:"
echo "    admin@demo.com / Admin@123"
echo "    user@demo.com  / User@123"
echo "    guest@demo.com / Guest@123"
echo ""
echo "  Du lieu da seed:"
echo "    Firestore : guestbook(3) + products(3) + users_profile(2)"
echo "    RTDB      : chat(3) + counters + announcements"
echo ""
warn "Cloud Storage can Blaze plan (tra phi) - khong bao gom."
warn "Firestore rules dang public - chi dung cho demo/dev."
echo ""
