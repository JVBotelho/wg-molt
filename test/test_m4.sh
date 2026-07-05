#!/bin/sh
set -e

cd "$(dirname "$0")"

# Mock env
export BASE_DIR="/tmp/mullvad-key-rotate"
mkdir -p "$BASE_DIR/lib" "$BASE_DIR/platform"
export CONFIG_FILE="$BASE_DIR/config"
export JOURNAL_FILE="$BASE_DIR/journal"
export LOCK_DIR="/tmp/wg-molt.lock"
export STATE_FILE="$BASE_DIR/state"

cat <<EOF > "$CONFIG_FILE"
ACCOUNT_FILE="$BASE_DIR/account"
WG_UNIT="wgc1"
ROTATE_DAYS=7
EOF

echo "1234567890123456" > "$BASE_DIR/account"

# Provide mock dependencies
# Real log.sh will be copied

cp ../src/lib/log.sh "$BASE_DIR/lib/"
cp ../src/lib/journal.sh "$BASE_DIR/lib/"
cp ../src/lib/api.sh "$BASE_DIR/lib/"
cp ../src/lib/verify.sh "$BASE_DIR/lib/"

# Mock platform
cat <<EOF > "$BASE_DIR/platform/merlin.sh"
CURRENT_PUBKEY="oldpubkey="
platform_read_config() { return 0; }
platform_apply_runtime() { echo "APPLY: \$1 \$2 \$3" >> /tmp/m4_log; return 0; }
platform_persist_config() { echo "PERSIST: \$1 \$2 \$3" >> /tmp/m4_log; return 0; }
EOF

# Mock curl and wg and ip
cat <<EOF > /tmp/mock_bin_m4.sh
#!/bin/sh
cmd="\$(basename "\$0")"
if [ "\$cmd" = "curl" ]; then
    if echo "\$*" | grep -q "token"; then
        echo '{"access_token":"token"}'
        echo "200"
    elif echo "\$*" | grep -q "devices/dev1"; then
        echo '{"ipv4_address":"10.0.0.5", "ipv6_address":"fd00::5"}'
        echo "200"
    elif echo "\$*" | grep -q "/devices"; then
        echo '[{"id":"dev1","pubkey":"oldpubkey="}]'
        echo "200"
    fi
elif [ "\$cmd" = "wg" ]; then
    if [ "\$1" = "genkey" ]; then echo "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="; fi
    if [ "\$1" = "pubkey" ]; then echo "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="; fi
    if [ "\$1" = "show" ] && [ "\$3" = "latest-handshakes" ]; then echo "wgc1 \$(date +%s)"; fi
elif [ "\$cmd" = "ip" ]; then
    exit 0
fi
EOF

export PATH="/tmp/mock_bin:$PATH"
mkdir -p /tmp/mock_bin
ln -sf /tmp/mock_bin_m4.sh /tmp/mock_bin/curl
ln -sf /tmp/mock_bin_m4.sh /tmp/mock_bin/wg
ln -sf /tmp/mock_bin_m4.sh /tmp/mock_bin/ip
chmod +x /tmp/mock_bin_m4.sh

# Wrap rotate.sh
cp ../src/rotate.sh /tmp/rotate.sh
chmod +x /tmp/rotate.sh

echo "Running M4 tests (State Machine)..."

# Test 1: First run
rm -f /tmp/m4_log "$STATE_FILE" "$JOURNAL_FILE"
/tmp/rotate.sh
if [ ! -f "$STATE_FILE" ]; then
    echo "FAIL: state file not created"
    exit 1
fi
if ! grep -q "APPLY: .* 10.0.0.5 fd00::5" /tmp/m4_log; then
    echo "FAIL: apply not called"
    exit 1
fi
if ! grep -q "PERSIST: .* 10.0.0.5 fd00::5" /tmp/m4_log; then
    echo "FAIL: persist not called"
    exit 1
fi
echo "PASS: Normal rotation"

# Test 2: Check age
rm -f /tmp/m4_log
/tmp/rotate.sh
if [ -f /tmp/m4_log ]; then
    echo "FAIL: should not rotate if too young"
    exit 1
fi
echo "PASS: Age check"

# Test 3: Reconcile ORPHAN journal (PUT_SENT, server has new key)
rm -f /tmp/m4_log
# Mock api.sh to resolve to NEW key
cat <<EOF > /tmp/mock_bin_m4.sh
#!/bin/sh
cmd="\$(basename "\$0")"
if [ "\$cmd" = "curl" ]; then
    if echo "\$*" | grep -q "token"; then
        echo '{"access_token":"token"}'
        echo "200"
    elif echo "\$*" | grep -q "devices/dev1"; then
        echo '{"ipv4_address":"10.0.0.5", "ipv6_address":"fd00::5"}'
        echo "200"
    elif echo "\$*" | grep -q "/devices"; then
        echo '[{"id":"dev1","pubkey":"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="}]'
        echo "200"
    fi
elif [ "\$cmd" = "wg" ]; then
    if [ "\$1" = "show" ] && [ "\$3" = "latest-handshakes" ]; then echo "wgc1 \$(date +%s)"; fi
fi
EOF

# Create orphaned journal
. "$BASE_DIR/lib/journal.sh"
journal_write "fase=PUT_SENT" "privkey_nova=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" "pubkey_nova=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=" "pubkey_antiga=oldpubkey="

/tmp/rotate.sh
if [ -f "$JOURNAL_FILE" ]; then
    echo "FAIL: journal not cleaned up after reconcile"
    exit 1
fi
if ! grep -q "APPLY: .* 10.0.0.5 fd00::5" /tmp/m4_log; then
    echo "FAIL: reconcile apply not called"
    exit 1
fi
echo "PASS: Reconcile PUT_SENT (server has new key)"

echo "ALL M4 TESTS PASSED"
