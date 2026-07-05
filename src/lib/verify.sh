#!/bin/sh
# shellcheck disable=SC3043
# lib/verify.sh

verify_tunnel() {
    local _iface="$1"
    local _i=0
    
    while [ "$_i" -lt 3 ]; do
        sleep 2
        local _latest _now _diff
        _latest=$(wg show "$_iface" latest-handshakes 2>/dev/null | awk '{print $2}')
        if [ -n "$_latest" ] && [ "$_latest" != "0" ]; then
            _now=$(date +%s)
            _diff=$((_now - _latest))
            if [ "$_diff" -le 30 ]; then
                # Check mullvad connection
                if curl --interface "$_iface" -fsSL --connect-timeout 5 "https://am.i.mullvad.net/connected" >/dev/null 2>&1; then
                    return 0
                fi
            else
                log_warn "Handshake is too old ($_diff s), waiting for new handshake..."
            fi
        fi
        log_warn "Verification failed, retrying..."
        _i=$((_i + 1))
    done
    return 1
}
