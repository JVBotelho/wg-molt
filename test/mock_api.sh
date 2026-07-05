#!/bin/sh
# shellcheck disable=SC3043
# test/mock_api.sh

FIXTURE_TOKEN='{"access_token":"mva_mock123","expiry":"2030-01-01T00:00:00Z"}'
FIXTURE_DEVICES='[
  {
    "id": "dev-001",
    "pubkey": "oldkey=",
    "ipv4_address": "10.0.0.1",
    "ipv6_address": "fd00::1"
  },
  {
    "id": "dev-002",
    "pubkey": "otherkey=",
    "ipv4_address": "10.0.0.2",
    "ipv6_address": null
  }
]'
FIXTURE_PUT_SUCCESS='{
  "id": "dev-001",
  "pubkey": "newkey=",
  "ipv4_address": "10.0.0.3",
  "ipv6_address": "fd00::3"
}'
FIXTURE_PUT_MAX='{"type":"MAX_DEVICES_REACHED"}'

export MOCK_SCENARIO="happy"

curl() {
    local _method=""
    local _url=""
    local _has_stdin=0
    
    while [ $# -gt 0 ]; do
        case "$1" in
            -X) _method="$2"; shift 2 ;;
            -d) 
                if [ "$2" = "@-" ]; then _has_stdin=1; fi
                shift 2 ;;
            -K)
                if [ "$2" = "-" ]; then _has_stdin=1; fi
                shift 2 ;;
            https://*) _url="$1"; shift 1 ;;
            *) shift 1 ;;
        esac
    done
    
    # consume stdin only if data or config is passed via stdin
    if [ "$_has_stdin" = 1 ]; then
        cat >/dev/null 2>&1 || true
    fi
    
    case "$MOCK_SCENARIO" in
        "timeout")
            echo "curl: (28) Operation timed out" >&2
            return 28
            ;;
        "429")
            printf '{"type":"RATE_LIMIT"}\n429\n'
            return 0
            ;;
        "invalid_json")
            printf '{"invalid": "json\n200\n'
            return 0
            ;;
        "max_devices")
            if [ "$_method" = "PUT" ]; then
                printf '%s\n403\n' "$FIXTURE_PUT_MAX"
                return 0
            fi
            ;;
        "generic_error")
            printf '{"error":"ROTATION_TOO_FREQUENT"}\n409\n'
            return 0
            ;;
    esac
    
    if echo "$_url" | grep -q "auth/v1/token"; then
        printf '%s\n200\n' "$FIXTURE_TOKEN"
        return 0
    elif echo "$_url" | grep -q "accounts/v1/devices$"; then
        printf '%s\n200\n' "$FIXTURE_DEVICES"
        return 0
    elif echo "$_url" | grep -q "accounts/v1/devices/.*/pubkey"; then
        printf '%s\n200\n' "$FIXTURE_PUT_SUCCESS"
        return 0
    fi
    
    echo "Mock error: unknown endpoint $_url" >&2
    return 1
}
