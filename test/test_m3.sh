#!/bin/sh
set -e

cd "$(dirname "$0")"

# Dummy functions for Merlin platform

wg() {
    if [ "$1" = "show" ] && [ "$2" = "wgc1" ]; then
        if [ "$3" = "private-key" ]; then
            echo "oldprivkey="
        elif [ "$3" = "public-key" ]; then
            echo "oldpubkey="
        fi
        return 0
    elif [ "$1" = "set" ] && [ "$2" = "wgc1" ] && [ "$3" = "private-key" ]; then
        cat "$4" > /tmp/wg_set_privkey
        return 0
    fi
    return 1
}

ip() {
    if [ "$1" = "-4" ] && [ "$2" = "addr" ] && [ "$3" = "show" ]; then
        echo "    inet 10.0.0.1/32 scope global wgc1"
        return 0
    elif [ "$1" = "-6" ] && [ "$2" = "addr" ] && [ "$3" = "show" ]; then
        echo "    inet6 fd00::1/128 scope global wgc1"
        return 0
    elif echo "$*" | grep -q "flush dev"; then
        echo "FLUSH" >> /tmp/ip_cmds
        return 0
    elif echo "$*" | grep -q "add 10.0.0.3/32 dev wgc1"; then
        echo "ADD4" >> /tmp/ip_cmds
        return 0
    elif echo "$*" | grep -q "add fd00::3/128 dev wgc1"; then
        echo "ADD6" >> /tmp/ip_cmds
        return 0
    fi
    return 1
}

nvram() {
    if [ "$1" = "show" ]; then
        echo "wgc1_priv=oldprivkey="
        echo "wgc1_addr=10.0.0.1/32"
        echo "wgc1_ipv6=fd00::1/128"
        echo "wgc1_peer=..."
        return 0
    elif [ "$1" = "set" ]; then
        echo "$2" >> /tmp/nvram_sets
        return 0
    elif [ "$1" = "get" ]; then
        if [ "$2" = "wgc1_addr" ]; then echo "10.0.0.1/32"
        elif [ "$2" = "wgc1_ipv6" ]; then echo "fd00::1/128"
        fi
        return 0
    elif [ "$1" = "commit" ]; then
        echo "COMMIT" >> /tmp/nvram_sets
        return 0
    fi
    return 1
}

cru() {
    echo "CRU $*" >> /tmp/cru_cmds
    return 0
}

log_error() {
    echo "ERROR: $*" >&2
}

# Source the merlin module
# shellcheck disable=SC1091
export WG_UNIT="wgc1"
# shellcheck disable=SC1091
. ../src/platform/merlin.sh

echo "Running M3 tests (Merlin platform)..."

rm -f /tmp/wg_set_privkey /tmp/ip_cmds /tmp/nvram_sets /tmp/cru_cmds /tmp/services-start

# Test 1: Config Discovery
platform_read_config
if [ "$CURRENT_PUBKEY" != "oldpubkey=" ]; then
    echo "FAIL: expected CURRENT_PUBKEY=oldpubkey=, got $CURRENT_PUBKEY"
    exit 1
fi
if [ "$NVRAM_VAR_PRIVKEY" != "wgc1_priv" ]; then
    echo "FAIL: expected NVRAM_VAR_PRIVKEY=wgc1_priv, got $NVRAM_VAR_PRIVKEY"
    exit 1
fi
if [ "$NVRAM_VAR_IPV4" != "wgc1_addr" ]; then
    echo "FAIL: expected NVRAM_VAR_IPV4=wgc1_addr, got $NVRAM_VAR_IPV4"
    exit 1
fi
if [ "$NVRAM_VAR_IPV6" != "wgc1_ipv6" ]; then
    echo "FAIL: expected NVRAM_VAR_IPV6=wgc1_ipv6, got $NVRAM_VAR_IPV6"
    exit 1
fi
echo "PASS: config discovery"

# Test 2: Apply Runtime
echo "newprivkey=" > /tmp/newpriv
platform_apply_runtime "/tmp/newpriv" "10.0.0.3" "fd00::3"
if [ "$(cat /tmp/wg_set_privkey)" != "newprivkey=" ]; then
    echo "FAIL: wg set failed"
    exit 1
fi
if [ "$(cat /tmp/ip_cmds)" != "FLUSH
ADD4
FLUSH
ADD6" ]; then
    echo "FAIL: ip commands incorrect: $(cat /tmp/ip_cmds)"
    exit 1
fi
echo "PASS: runtime apply"

# Test 3: Persist config
platform_persist_config "/tmp/newpriv" "10.0.0.3" "fd00::3"
if ! grep -q "wgc1_priv=newprivkey=" /tmp/nvram_sets; then
    echo "FAIL: nvram privkey set failed"
    exit 1
fi
if ! grep -q "wgc1_addr=10.0.0.3/32" /tmp/nvram_sets; then
    echo "FAIL: nvram ipv4 set failed"
    exit 1
fi
if ! grep -q "wgc1_ipv6=fd00::3/128" /tmp/nvram_sets; then
    echo "FAIL: nvram ipv6 set failed"
    exit 1
fi
if ! grep -q "COMMIT" /tmp/nvram_sets; then
    echo "FAIL: nvram commit missing"
    exit 1
fi
echo "PASS: persist config"

# Test 4: Schedule
mkdir -p /tmp/jffs/scripts
cp ../src/platform/merlin.sh /tmp/merlin_test.sh
sed -i 's|/jffs/scripts/services-start|/tmp/services-start|g' /tmp/merlin_test.sh

# shellcheck disable=SC1091
. /tmp/merlin_test.sh
platform_schedule "install" "/path/to/rotate.sh"

if ! grep -q "CRU a wg-molt " /tmp/cru_cmds; then
    echo "FAIL: cru a failed"
    exit 1
fi
if ! grep -q "\"/path/to/rotate.sh\" --reconcile-only &" /tmp/services-start; then
    echo "FAIL: services-start not updated"
    exit 1
fi
echo "PASS: schedule"

echo "ALL M3 TESTS PASSED"
