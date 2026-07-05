#!/bin/sh
# shellcheck disable=SC3043,SC2086
# lib/api.sh

API_BASE="${API_BASE:-https://api.mullvad.net}"
CURL_OPTS="-sSL --connect-timeout 10 --max-time 30"

export API_RATE_LIMIT=142
export API_MAX_DEVICES=143

_api_request() {
    local _in_data="$1"
    local _url="$2"
    shift 2
    
    local _out _status _curl_rc _body
    _out=$(printf '%s\n' "$_in_data" | curl $CURL_OPTS -w "\n%{http_code}" "$@" "$_url")
    _curl_rc=$?
    
    if [ "$_curl_rc" -ne 0 ]; then
        return "$_curl_rc"
    fi
    
    _status=$(printf '%s\n' "$_out" | tail -n1 | tr -cd '0-9')
    _body=$(printf '%s\n' "$_out" | sed '$d')
    
    if [ "$_status" = "200" ] || [ "$_status" = "201" ]; then
        printf '%s\n' "$_body"
        return 0
    elif [ "$_status" = "429" ]; then
        return 142
    else
        if printf '%s\n' "$_body" | grep -q "MAX_DEVICES_REACHED"; then
            return 143
        fi
        # Surface the real status/body for diagnostics -- callers only see a
        # generic rc=1, which on its own tells you nothing about what Mullvad
        # actually rejected. Guarded: api.sh must not assume log.sh is loaded.
        if command -v log_error >/dev/null 2>&1; then
            log_error "Mullvad API request failed: HTTP ${_status:-unknown} - $(printf '%s' "$_body" | tr '\n' ' ' | cut -c1-200)"
        fi
        return 1
    fi
}

api_post_token() {
    local _account
    _account=$(printf '%s' "$1" | tr -cd '0-9')
    local _res _token _rc
    
    _res=$(_api_request "{\"account_number\":\"$_account\"}" "${API_BASE}/auth/v1/token" -X POST -H "Content-Type: application/json" -H "Accept: application/json" -d @-)
    _rc=$?
    [ "$_rc" -eq 0 ] || return "$_rc"
    
    if which jq >/dev/null 2>&1; then
        _token=$(printf '%s\n' "$_res" | jq -r '.access_token // empty')
    else
        _token=$(printf '%s\n' "$_res" | sed -n 's/.*"access_token"[ \t]*:[ \t]*"\([^"]*\)".*/\1/p')
    fi
    
    _token=$(printf '%s' "$_token" | tr -cd 'A-Za-z0-9_=-')
    [ -n "$_token" ] || return 1
    printf '%s\n' "$_token"
}

api_get_device_id() {
    local _token _pubkey
    _token=$(printf '%s' "$1" | tr -cd 'A-Za-z0-9_=-')
    _pubkey=$(printf '%s' "$2" | tr -cd 'A-Za-z0-9+/=')
    local _res _id _rc _config
    
    _config=$(printf 'header = "Authorization: Bearer %s"\n' "$_token")
    _res=$(_api_request "$_config" "${API_BASE}/accounts/v1/devices" -X GET -H "Accept: application/json" -K -)
    _rc=$?
    [ "$_rc" -eq 0 ] || return "$_rc"
        
    if which jq >/dev/null 2>&1; then
        _id=$(printf '%s\n' "$_res" | jq -r --arg pk "$_pubkey" '.[] | select(.pubkey == $pk) | .id // empty')
    else
        _id=$(printf '%s\n' "$_res" | pk="$_pubkey" awk '
            BEGIN { pk=ENVIRON["pk"]; RS="{" }
            {
                gsub(/[ \t\n\r]+/, "", $0)
                if (index($0, "\"pubkey\":\"" pk "\"")) {
                    match($0, /"id":"[^"]+"/)
                    if (RSTART > 0) {
                        print substr($0, RSTART+6, RLENGTH-7)
                    }
                }
            }
        ')
    fi
    
    _id=$(printf '%s' "$_id" | tr -cd 'A-Za-z0-9-')
    if [ -n "$_id" ]; then
        printf '%s\n' "$_id"
    fi
}

api_put_pubkey() {
    local _token _device_id _new_pubkey
    _token=$(printf '%s' "$1" | tr -cd 'A-Za-z0-9_=-')
    _device_id=$(printf '%s' "$2" | tr -cd 'A-Za-z0-9-')
    _new_pubkey=$(printf '%s' "$3" | tr -cd 'A-Za-z0-9+/=')
    local _res _ipv4 _ipv6 _rc _config
    
    _config=$(printf 'header = "Authorization: Bearer %s"\ndata = "{\\"pubkey\\":\\"%s\\"}"\n' "$_token" "$_new_pubkey")
    _res=$(_api_request "$_config" "${API_BASE}/accounts/v1/devices/${_device_id}/pubkey" -X PUT -H "Content-Type: application/json" -H "Accept: application/json" -K -)
    _rc=$?
    [ "$_rc" -eq 0 ] || return "$_rc"
        
    if which jq >/dev/null 2>&1; then
        _ipv4=$(printf '%s\n' "$_res" | jq -r '.ipv4_address // empty')
        _ipv6=$(printf '%s\n' "$_res" | jq -r '.ipv6_address // empty')
    else
        _ipv4=$(printf '%s\n' "$_res" | sed -n 's/.*"ipv4_address"[ \t]*:[ \t]*"\([^"]*\)".*/\1/p')
        _ipv6=$(printf '%s\n' "$_res" | sed -n 's/.*"ipv6_address"[ \t]*:[ \t]*"\([^"]*\)".*/\1/p')
    fi
    
    _ipv4=$(printf '%s' "$_ipv4" | sed 's/\/.*//' | tr -cd '0-9.')
    _ipv6=$(printf '%s' "$_ipv6" | sed 's/\/.*//' | tr -cd '0-9a-fA-F:')
    
    [ -n "$_ipv4" ] || return 1
    
    if [ -n "$_ipv6" ] && [ "$_ipv6" != "null" ]; then
        printf '%s,%s\n' "$_ipv4" "$_ipv6"
    else
        printf '%s\n' "$_ipv4"
    fi
}
