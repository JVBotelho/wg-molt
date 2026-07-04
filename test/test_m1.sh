#!/bin/sh
set -e

# Setup test environment
export LOG_FILE="/tmp/wg-molt-test.log"
export JOURNAL_FILE="/tmp/wg-molt-test.journal"
export LOCK_DIR="/tmp/wg-molt-test.lock"

rm -f "$LOG_FILE" "$JOURNAL_FILE"
rm -rf "$LOCK_DIR"

cd "$(dirname "$0")"

# Source the files
# shellcheck disable=SC1091
. ../src/lib/log.sh
# shellcheck disable=SC1091
. ../src/lib/journal.sh

echo "Running M1 tests..."

# Test log.sh redaction
log_info "Test key is aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789aBcDeFg= Account 1234567890123456 Token mva_abc123XYZ"
logged_msg=$(cat "$LOG_FILE")
if echo "$logged_msg" | grep -q "aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789aBcDeFg="; then
    echo "FAIL: log.sh failed to redact base64 key"
    exit 1
fi
if echo "$logged_msg" | grep -q "1234567890123456"; then
    echo "FAIL: log.sh failed to redact account"
    exit 1
fi
if echo "$logged_msg" | grep -q "mva_abc123XYZ"; then
    echo "FAIL: log.sh failed to redact token"
    exit 1
fi
if ! echo "$logged_msg" | grep -q "<REDACTED>"; then
    echo "FAIL: log.sh did not insert <REDACTED>"
    exit 1
fi
echo "PASS: log.sh redaction"

# Test journal.sh
if ! journal_lock; then
    echo "FAIL: journal_lock failed"
    exit 1
fi
if journal_lock; then
    echo "FAIL: journal_lock should fail when already locked"
    exit 1
fi
journal_unlock
if [ -d "$LOCK_DIR" ]; then
    echo "FAIL: journal_unlock failed to remove lock dir"
    exit 1
fi
echo "PASS: journal lock/unlock"

journal_write fase="KEYED" privkey_nova="newkey=" pubkey_nova="pubkey="
if [ ! -f "$JOURNAL_FILE" ]; then
    echo "FAIL: journal_write failed to create file"
    exit 1
fi

val=$(journal_read "fase")
if [ "$val" != "KEYED" ]; then
    echo "FAIL: journal_read returned '$val' instead of 'KEYED'"
    exit 1
fi

journal_write fase="PUT_SENT"
val=$(journal_read "fase")
if [ "$val" != "PUT_SENT" ]; then
    echo "FAIL: journal_write failed to update existing key, got '$val'"
    exit 1
fi

# Ensure old keys remain
val=$(journal_read "privkey_nova")
if [ "$val" != "newkey=" ]; then
    echo "FAIL: journal_write wiped existing keys, got '$val'"
    exit 1
fi
echo "PASS: journal write/read"

journal_clean
if [ -f "$JOURNAL_FILE" ]; then
    echo "FAIL: journal_clean failed"
    exit 1
fi
echo "PASS: journal clean"

echo "ALL M1 TESTS PASSED"
