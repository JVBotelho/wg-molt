#!/bin/sh
# install.sh
# wg-molt installer for Asuswrt-Merlin

set -e
umask 077

CRU_PATH="${CRU_PATH:-/usr/sbin/cru}"
NVRAM_PATH="${NVRAM_PATH:-nvram}"

# 1. Platform Detection
if [ ! -x "$CRU_PATH" ]; then
    echo "ERROR: $CRU_PATH not found."
    echo "wg-molt currently only supports Asuswrt-Merlin."
    echo "Support for OpenWrt or generic Linux will be added in future versions."
    exit 1
fi

_jffs_scripts=$("$NVRAM_PATH" get jffs2_scripts 2>/dev/null || echo "0")
if [ "$_jffs_scripts" != "1" ]; then
    echo "ERROR: Custom JFFS scripts are not enabled."
    echo "Please enable them in the Asuswrt-Merlin WebUI:"
    echo "Administration -> System -> Enable JFFS custom scripts and configs"
    exit 1
fi

# 2. Interactive Prompts
echo "=== wg-molt Installer ==="
if [ -z "$ACCOUNT" ]; then
    printf "Enter your Mullvad account number (16 digits, no spaces): "
    stty -echo
    read -r ACCOUNT
    stty echo
    echo ""
fi

# Validate 16 digits
if ! printf '%s' "$ACCOUNT" | grep -qE '^[0-9]{16}$'; then
    echo "ERROR: Account number must be exactly 16 digits."
    exit 1
fi

if [ -z "$WG_UNIT" ]; then
    printf "Enter your WireGuard interface [wgc1]: "
    read -r WG_UNIT
    WG_UNIT=${WG_UNIT:-wgc1}
fi

if ! printf '%s' "$WG_UNIT" | grep -qE '^[a-zA-Z0-9_]+$'; then
    echo "ERROR: WG_UNIT contains invalid characters."
    exit 1
fi

ROTATE_DAYS=${ROTATE_DAYS:-7}
if ! printf '%s' "$ROTATE_DAYS" | grep -qE '^[0-9]+$'; then
    echo "ERROR: ROTATE_DAYS must be a number."
    exit 1
fi
if [ "$ROTATE_DAYS" -lt 1 ] || [ "$ROTATE_DAYS" -gt 30 ]; then
    echo "ERROR: ROTATE_DAYS must be between 1 and 30."
    exit 1
fi

# 3. Create Structure
TARGET_DIR="${TARGET_DIR:-/jffs/addons/wg-molt}"
echo "Creating structure in $TARGET_DIR..."
mkdir -p "$TARGET_DIR" "$TARGET_DIR/lib" "$TARGET_DIR/platform"

# Note: In the repo, the scripts are in src/. In a release tarball, they might be in the root.
# We will copy from ./src if it exists, otherwise from ./
if [ -d "$(dirname "$0")/src" ]; then
    _src_dir="$(dirname "$0")/src"
else
    _src_dir="$(dirname "$0")"
fi

_src_abs="$(cd "$_src_dir" && pwd)"
_tgt_abs="$(cd "$TARGET_DIR" && pwd)"

if [ "$_src_abs" != "$_tgt_abs" ]; then
    cp "$_src_dir/rotate.sh" "$TARGET_DIR/"
    cp "$_src_dir/uninstall.sh" "$TARGET_DIR/" 2>/dev/null || true
    cp "$_src_dir"/lib/*.sh "$TARGET_DIR/lib/"
    cp "$_src_dir"/platform/*.sh "$TARGET_DIR/platform/"
fi

chmod +x "$TARGET_DIR/rotate.sh"

echo "Creating config and account files..."
cat <<EOF > "$TARGET_DIR/config"
ACCOUNT_FILE="$TARGET_DIR/account.txt"
WG_UNIT="$WG_UNIT"
ROTATE_DAYS=$ROTATE_DAYS
EOF

echo "$ACCOUNT" > "$TARGET_DIR/account.txt"
chmod 600 "$TARGET_DIR/account.txt" "$TARGET_DIR/config"

# 4. Install Hooks via Platform Adapter
# shellcheck disable=SC1091
. "$TARGET_DIR/platform/merlin.sh"
echo "Installing cron job and startup hook..."
platform_schedule "install" "$TARGET_DIR/rotate.sh"

echo "=== wg-molt installed successfully! ==="
echo "You can test the rotation safely by running:"
echo "$TARGET_DIR/rotate.sh --dry-run"
