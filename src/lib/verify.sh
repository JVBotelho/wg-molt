#!/bin/sh
# shellcheck disable=SC3043
# lib/verify.sh

# Waits for a WireGuard handshake at or after $_since (the epoch when the new
# key was applied). A private-key swap invalidates the prior session, but
# WireGuard only re-handshakes when it has something to send: real traffic or
# the PersistentKeepalive tick (commonly 25s for Mullvad configs). The
# retry budget below is sized to comfortably outlast that interval -- an
# absolute "age <= 30s" check is meaningless here, since a healthy, actively
# used tunnel only rekeys an existing session every ~120s (REKEY_AFTER_TIME)
# and can otherwise show a much older handshake age with nothing wrong.
verify_tunnel() {
    local _iface="$1"
    local _since="$2"
    local _i=0
    local _latest

    while [ "$_i" -lt 8 ]; do
        sleep 4
        _latest=$(wg show "$_iface" latest-handshakes 2>/dev/null | awk '{print $2}')
        if [ -n "$_latest" ] && [ "$_latest" != "0" ] && [ "$_latest" -ge $((_since - 1)) ]; then
            # Best-effort only: on some router setups, locally-originated
            # traffic never traverses the tunnel interface (killswitch /
            # policy routing scoped to LAN-forwarded traffic only), so a
            # failure here does not override a confirmed fresh handshake.
            if ! curl --interface "$_iface" -fsSL --connect-timeout 5 "https://am.i.mullvad.net/connected" >/dev/null 2>&1; then
                log_warn "Handshake confirmed since key rotation, but external connectivity check failed (informational only)."
            fi
            return 0
        fi
        log_warn "No handshake since key rotation yet, retrying..."
        _i=$((_i + 1))
    done
    return 1
}
