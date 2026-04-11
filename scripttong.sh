#!/usr/bin/env bash
set -e

echo "======================================"
echo "🚀 START FULL SETUP"
echo "======================================"

# ====== CONFIG ======
BASE_URL="https://raw.githubusercontent.com/kushopxyz/script/refs/heads/main"

ALL_SCRIPT="all.sh"
BESTHUB_SCRIPT="besthub.sh"

# ====== STEP 1: DOWNLOAD ======
echo "📥 Downloading scripts..."

curl -fsSL "${BASE_URL}/${ALL_SCRIPT}" -o ${ALL_SCRIPT}
curl -fsSL "${BASE_URL}/${BESTHUB_SCRIPT}" -o ${BESTHUB_SCRIPT}

chmod +x ${ALL_SCRIPT} ${BESTHUB_SCRIPT}

echo "✅ Download complete"

# ====== STEP 2: RUN all.sh ======
echo "======================================"
echo "⚙️ Running all.sh"
echo "======================================"

if ./${ALL_SCRIPT}; then
  echo "✅ all.sh completed"
else
  echo "❌ all.sh failed"
  exit 1
fi

# ====== STEP 3: RUN besthub.sh ======
echo "======================================"
echo "⚙️ Running besthub.sh"
echo "======================================"

if ./${BESTHUB_SCRIPT}; then
  echo "✅ besthub.sh completed"
else
  echo "❌ besthub.sh failed"
  exit 1
fi

# ====== DONE ======
echo "======================================"
echo "🎉 ALL DONE SUCCESSFULLY"
echo "======================================"
