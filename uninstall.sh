#!/bin/sh
# uninstall.sh
# wg-molt uninstaller for Asuswrt-Merlin

set -e

TARGET_DIR="${TARGET_DIR:-/jffs/addons/wg-molt}"
CRU_PATH="${CRU_PATH:-/usr/sbin/cru}"

if [ ! -d "$TARGET_DIR" ]; then
    echo "wg-molt is not installed in $TARGET_DIR."
    exit 0
fi

# 1. Check for orphaned journal
if [ -e "$TARGET_DIR/journal" ]; then
    if [ "$1" != "--force" ]; then
        echo "ERROR: Pending journal found (rotation was interrupted)."
        echo "Removing wg-molt now could permanently lose the new WireGuard key if it was already sent to Mullvad."
        echo "Please run '$TARGET_DIR/rotate.sh --reconcile-only' to complete the rotation."
        echo "Or use '$0 --force' to ignore this warning and uninstall anyway."
        exit 1
    else
        echo "WARNING: --force flag used. Ignoring pending journal."
    fi
fi

# 2. Remove hooks via platform adapter
if [ -f "$TARGET_DIR/platform/merlin.sh" ]; then
    # shellcheck disable=SC1091
    . "$TARGET_DIR/platform/merlin.sh"
    echo "Removing cron job and cleaning services-start..."
    platform_schedule "remove" "$TARGET_DIR/rotate.sh"
fi

# 4. Remove directories
echo "Removing $TARGET_DIR..."
rm -rf "$TARGET_DIR"

echo "=== wg-molt uninstalled successfully! ==="
