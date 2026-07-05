#!/bin/sh
set -e

cd "$(dirname "$0")"

# shellcheck disable=SC1091
. ./mock_api.sh
# shellcheck disable=SC1091
. ../src/lib/api.sh

echo "Running M2 tests (API)..."

# Test 1: Happy path token
export MOCK_SCENARIO="happy"
token=$(api_post_token "1234567890123456")
if [ "$token" != "mva_mock123" ]; then
    echo "FAIL: api_post_token returned '$token'"
    exit 1
fi
echo "PASS: api_post_token"

# Test 2: Happy path get devices
dev_id=$(api_get_device_id "$token" "oldkey=")
if [ "$dev_id" != "dev-001" ]; then
    echo "FAIL: api_get_device_id returned '$dev_id' expected 'dev-001'"
    exit 1
fi
echo "PASS: api_get_device_id"

# Test 3: Happy path get devices with otherkey
dev_id=$(api_get_device_id "$token" "otherkey=")
if [ "$dev_id" != "dev-002" ]; then
    echo "FAIL: api_get_device_id returned '$dev_id' expected 'dev-002'"
    exit 1
fi
echo "PASS: api_get_device_id (multiple items)"

# Test 4: Happy path put pubkey
ips=$(api_put_pubkey "$token" "dev-001" "newkey=")
if [ "$ips" != "10.0.0.3,fd00::3" ]; then
    echo "FAIL: api_put_pubkey returned '$ips' expected '10.0.0.3,fd00::3'"
    exit 1
fi
echo "PASS: api_put_pubkey"

# Test 5: Timeout scenario
export MOCK_SCENARIO="timeout"
api_post_token "1234567890123456" >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 28 ]; then
    echo "FAIL: api_post_token should fail on timeout (28), got $rc"
    exit 1
fi
echo "PASS: timeout handling"

# Test 6: Invalid JSON scenario (fail-closed parsing)
export MOCK_SCENARIO="invalid_json"
rc=0
out=$(api_get_device_id "$token" "oldkey=") || rc=$?
if [ "$rc" -ne 0 ]; then
    echo "FAIL: api_get_device_id should not fail on invalid JSON (just return empty), got rc=$rc"
    exit 1
fi
if [ -n "$out" ]; then
    echo "FAIL: api_get_device_id should return empty on invalid JSON, got '$out'"
    exit 1
fi
echo "PASS: invalid json handling"

# Test 7: API returns 429
export MOCK_SCENARIO="429"
api_put_pubkey "$token" "dev-001" "newkey=" >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 42 ]; then
    echo "FAIL: api_put_pubkey should fail with 42 on 429, got $rc"
    exit 1
fi
echo "PASS: 429 handling"

# Test 8: API returns MAX_DEVICES_REACHED
export MOCK_SCENARIO="max_devices"
api_put_pubkey "$token" "dev-001" "newkey=" >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 43 ]; then
    echo "FAIL: api_put_pubkey should fail with 43 on max devices, got $rc"
    exit 1
fi
echo "PASS: max devices handling"

echo "ALL M2 TESTS PASSED"
