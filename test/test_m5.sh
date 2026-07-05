#!/bin/sh
set -e

cd "$(dirname "$0")"

export BASE_DIR="/tmp/wg-molt-tests"
export TARGET_DIR="$BASE_DIR/wg-molt"
export CRU_PATH="$BASE_DIR/cru"
export NVRAM_PATH="$BASE_DIR/nvram"
export SVC_START="$BASE_DIR/services-start"

mkdir -p "$BASE_DIR"
touch "$SVC_START"
chmod +x "$SVC_START"

# Mock cru
cat <<EOF > "$CRU_PATH"
#!/bin/sh
echo "CRU: \$@" >> "$BASE_DIR/cru.log"
EOF
chmod +x "$CRU_PATH"
export PATH="$BASE_DIR:$PATH"

# Mock nvram
cat <<EOF > "$NVRAM_PATH"
#!/bin/sh
if [ "\$1" = "get" ] && [ "\$2" = "jffs2_scripts" ]; then
    echo "1"
else
    echo ""
fi
EOF
chmod +x "$NVRAM_PATH"

# Provide inputs for install
export ACCOUNT="1234567890123456"
export WG_UNIT="wgc2"

echo "Running install.sh..."
sh ../install.sh >/dev/null

echo "Checking install results..."
[ -d "$TARGET_DIR" ] || exit 1
[ -x "$TARGET_DIR/rotate.sh" ] || exit 1
[ -f "$TARGET_DIR/config" ] || exit 1
[ -f "$TARGET_DIR/account.txt" ] || exit 1

# Check services-start injection
grep -q "cru a wg-molt" "$SVC_START" || exit 1
grep -q "rotate.sh\" --reconcile-only" "$SVC_START" || exit 1
[ -x "$SVC_START" ] || exit 1

echo "Testing install idempotency..."
sh ../install.sh >/dev/null
# Ensure block is not duplicated
_count=$(grep -c "# --- BEGIN wg-molt ---" "$SVC_START")
if [ "$_count" -ne 1 ]; then
    echo "Idempotency failed! Block duplicated."
    exit 1
fi

echo "Testing uninstall block protection..."
touch "$TARGET_DIR/journal"
if sh ../uninstall.sh >/dev/null 2>&1; then
    echo "Uninstall should have failed due to orphaned journal!"
    exit 1
fi

echo "Testing uninstall force..."
sh ../uninstall.sh --force
[ ! -d "$TARGET_DIR" ] || exit 1
# Check services-start cleaned
if grep -q "wg-molt" "$SVC_START"; then
    cat "$SVC_START"
    echo "services-start not cleaned properly"
    exit 1
fi

echo "Testing uninstall idempotency..."
sh ../uninstall.sh >/dev/null

echo "PASS: Install/Uninstall tests"

rm -rf "$BASE_DIR"
