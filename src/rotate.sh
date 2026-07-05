#!/bin/sh
# shellcheck disable=SC3043
# src/rotate.sh

set -e

# Default paths
BASE_DIR="${BASE_DIR:-/jffs/addons/wg-molt}"
CONFIG_FILE="${CONFIG_FILE:-$BASE_DIR/config}"
export JOURNAL_FILE="${JOURNAL_FILE:-$BASE_DIR/journal}"
export LOCK_DIR="${LOCK_DIR:-$BASE_DIR/lock}"
STATE_FILE="${STATE_FILE:-$BASE_DIR/state}"
ACCOUNT_FILE=""

# Ensure cleanup on exit
trap 'rm -f "$JOURNAL_FILE.priv"' EXIT
# Abort immediately on kill signals to trigger the EXIT trap
trap 'exit 143' TERM
trap 'exit 130' INT

# Load libraries
# shellcheck disable=SC1091
. "$BASE_DIR/lib/log.sh"
# shellcheck disable=SC1091
. "$BASE_DIR/lib/journal.sh"
# shellcheck disable=SC1091
. "$BASE_DIR/lib/api.sh"
# shellcheck disable=SC1091
. "$BASE_DIR/lib/verify.sh"

_load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "Config file not found: $CONFIG_FILE"
        return 1
    fi
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
    
    if [ -z "$WG_UNIT" ]; then
        log_error "WG_UNIT not set in config."
        return 1
    fi
    if [ -z "$ACCOUNT_FILE" ] || [ ! -f "$ACCOUNT_FILE" ]; then
        log_error "ACCOUNT_FILE not set or not found."
        return 1
    fi
    
    # Export WG_UNIT for platform scripts
    export WG_UNIT
    
    # Load platform adapter
    # In v1.0, only merlin is supported
    # shellcheck disable=SC1091
    . "${BASE_DIR}/platform/merlin.sh"
}

_api_retry() {
    local _cmd="$1"
    shift
    local _i=0 _backoff=2 _rc=0 _out=""
    
    while [ "$_i" -lt 3 ]; do
        _rc=0
        _out=$("$_cmd" "$@") || _rc=$?
        
        if [ "$_rc" -eq 0 ]; then
            if [ -n "$_out" ]; then
                printf '%s\n' "$_out"
            fi
            return 0
        fi
        
        # 1 means API failure (like 401/400) or fail-closed parsing error (e.g. invalid JSON).
        # We must fail fast in all cases, per the spec.
        if [ "$_rc" -eq 1 ]; then
            return 1
        fi
        
        if [ "$_rc" -eq "$API_MAX_DEVICES" ]; then
            return "$API_MAX_DEVICES"
        fi
        
        # 42 means 429 Too Many Requests (rate limit). Other codes could be network timeouts (like curl's 28).
        log_warn "API error ($_rc) on $_cmd. Retrying in ${_backoff}s..."
        sleep "$_backoff"
        _backoff=$((_backoff * 2))
        _i=$((_i + 1))
    done
    return "$_rc"
}

_check_age() {
    if [ ! -f "$STATE_FILE" ]; then
        return 0 # Never rotated
    fi
    
    local _last_rotation _now _diff _rotate_sec
    _last_rotation=$(awk -F= '$1=="last_rotation"{print $2}' "$STATE_FILE")
    if [ -z "$_last_rotation" ]; then
        return 0
    fi
    
    _now=$(date +%s)
    _diff=$(( _now - _last_rotation ))
    _rotate_sec=$(( ${ROTATE_DAYS:-7} * 86400 ))
    
    if [ "$_diff" -ge "$_rotate_sec" ]; then
        return 0
    fi

    log_info "Skipping rotation: last rotation was ${_diff}s ago, next due in $(( (_rotate_sec - _diff) / 3600 ))h."
    return 1 # Too young
}

_save_state() {
    local _pubkey="$1"
    local _now
    _now=$(date +%s)
    
    local _tmp="${STATE_FILE}.tmp"
    printf 'last_rotation=%s\n' "$_now" > "$_tmp"
    printf 'pubkey=%s\n' "$_pubkey" >> "$_tmp"
    mv "$_tmp" "$STATE_FILE"
}

_reconcile() {
    local _fase _j_priv _j_pub _j_oldpub _account _token _id _rc
    _fase=$(journal_read "fase")
    [ -z "$_fase" ] && return 0 # No journal to reconcile
    
    log_warn "Found orphaned journal (fase=$_fase). Reconciling..."
    
    _j_pub=$(journal_read "pubkey_nova")
    _j_oldpub=$(journal_read "pubkey_antiga")
    _j_priv=$(journal_read "privkey_nova")
    
    if [ -z "$_j_pub" ] || [ -z "$_j_oldpub" ] || [ -z "$_j_priv" ]; then
        log_error "Journal is corrupt. Missing keys."
        return 1
    fi
    
    _account=$(cat "$ACCOUNT_FILE")
    _token=$(_api_retry api_post_token "$_account") || {
        log_error "Failed to auth during reconcile."
        return 1
    }
    
    # Try to resolve by new key first
    _rc=0
    _id=$(_api_retry api_get_device_id "$_token" "$_j_pub") || _rc=$?
    
    if [ "$_rc" -eq 0 ] && [ -n "$_id" ]; then
        log_info "Server has NEW pubkey. Resuming from S8 (APPLY)."
        journal_write "fase=PUT_SENT"
        _do_put_and_apply "$_token" "$_id" "$_j_priv" "$_j_pub"
        return $?
    elif [ "$_rc" -eq 0 ] && [ -z "$_id" ]; then
        # Try to resolve by old key
        _id=$(_api_retry api_get_device_id "$_token" "$_j_oldpub")
        if [ -n "$_id" ]; then
            log_info "Server has OLD pubkey. Resuming from S7 (PUT)."
            journal_write "fase=PUT_SENT"
            _do_put_and_apply "$_token" "$_id" "$_j_priv" "$_j_pub"
            return $?
        else
            log_error "Neither old nor new pubkey found on server. Account state altered externally."
            return 1
        fi
    else
        log_error "Failed to resolve devices during reconcile (code $_rc). See preceding API error line for the actual HTTP status."
        return 1
    fi
}

_do_put_and_apply() {
    local _token="$1"
    local _id="$2"
    local _priv="$3"
    local _pub="$4"
    local _ips _ipv4 _ipv6 _rc _priv_file
    
    _rc=0
    _ips=$(_api_retry api_put_pubkey "$_token" "$_id" "$_pub") || _rc=$?
    
    if [ "$_rc" -ne 0 ]; then
        if [ "$_rc" -eq 43 ]; then
            log_error "Max devices reached! Account limit exceeded."
        else
            log_error "PUT pubkey failed after retries (code $_rc). See preceding API error line for the actual HTTP status."
        fi
        return 1
    fi
    
    journal_write "fase=API_DONE"
    
    _ipv4="${_ips%%,*}"
    case "$_ips" in
        *,*) _ipv6="${_ips#*,}" ;;
        *) _ipv6="" ;;
    esac
    
    log_info "Applying new configuration to runtime..."
    
    _priv_file="${JOURNAL_FILE}.priv"
    # Ensure umask for the private key file
    rm -f "$_priv_file"
    ( umask 077 && set -C && printf '%s\n' "$_priv" > "$_priv_file" )
    
    local _apply_time
    local _apply_ok=0
    local _i=0
    while [ "$_i" -lt 3 ]; do
        _apply_time=$(date +%s)
        if platform_apply_runtime "$_priv_file" "$_ipv4" "$_ipv6"; then
            _apply_ok=1
            break
        fi
        log_warn "Failed to apply runtime, retrying..."
        sleep 2
        _i=$((_i + 1))
    done

    local _verify_ok=0
    if [ "$_apply_ok" -eq 1 ]; then
        if verify_tunnel "$WG_UNIT" "$_apply_time"; then
            _verify_ok=1
        else
            log_error "Verification failed after retries. Proceeding to persist anyway (forward recovery)."
        fi
    else
        log_error "Apply failed after 3 retries. Proceeding to persist anyway (forward recovery)."
    fi
    
    log_info "Persisting configuration..."
    if ! platform_persist_config "$_priv_file" "$_ipv4" "$_ipv6"; then
        log_error "Failed to persist configuration!"
        rm -f "$_priv_file"
        return 1
    fi
    
    rm -f "$_priv_file"
    
    if [ "$_apply_ok" -eq 0 ] || [ "$_verify_ok" -eq 0 ]; then
        log_warn "Triggering aggressive restart of WireGuard client (forward recovery step 3)..."
        if which service >/dev/null 2>&1; then
            service "restart_${WG_UNIT}" || true
        fi
        if [ -n "$NOTIFY_HOOK" ] && [ -x "$NOTIFY_HOOK" ]; then
            "$NOTIFY_HOOK" "WG Rotation Failed" "Forward recovery in progress for $WG_UNIT" || true
        fi
        # We persisted, but runtime/verify failed. Return error so cron runs again if needed or alerts.
        return 1
    fi
    
    _save_state "$_pub"
    journal_clean
    journal_unlock
    log_info "Key rotation successful."
    return 0
}

main() {
    local _reconcile_only=0
    local _dry_run=0
    local _force=0
    local _rc
    local arg

    for arg in "$@"; do
        if [ "$arg" = "--reconcile-only" ]; then
            _reconcile_only=1
        elif [ "$arg" = "--dry-run" ]; then
            _dry_run=1
        elif [ "$arg" = "--force" ]; then
            _force=1
        fi
    done

    _load_config || exit 1
    
    # Initialize Log
    # ... assuming log_info works
    
    if ! journal_lock; then
        log_error "Another instance is running (lock exists)."
        exit 1
    fi
    
    # Check for orphaned journal
    if [ -e "$JOURNAL_FILE" ]; then
        if [ "$_dry_run" -eq 1 ]; then
            log_error "Cannot perform dry-run with pending journal."
            journal_unlock
            exit 1
        fi
        _reconcile
        _rc=$?
        if [ "$_reconcile_only" -eq 1 ]; then
            if [ -f "$JOURNAL_FILE" ]; then
                journal_unlock
            fi
            exit "$_rc"
        fi
        if [ "$_rc" -ne 0 ]; then
            journal_unlock
            exit 1
        fi
        # If reconcile succeeded, it cleans the journal and unlocks.
        # If we were not reconcile_only, we just finish, because a rotation just completed.
        if [ ! -f "$JOURNAL_FILE" ]; then
            exit 0
        fi
    fi
    
    if [ "$_reconcile_only" -eq 1 ]; then
        journal_unlock
        exit 0
    fi
    
    if [ "$_force" -eq 1 ]; then
        log_info "Forcing rotation (--force): skipping age check."
    elif [ "$_dry_run" -eq 0 ]; then
        if ! _check_age; then
            journal_unlock
            exit 0
        fi
    fi
    
    log_info "Starting Mullvad WireGuard key rotation..."
    
    # Preflight
    if ! which wg >/dev/null || ! which curl >/dev/null; then
        log_error "Preflight failed: wg or curl not found."
        journal_unlock
        exit 1
    fi
    
    local _year
    _year=$(date +%Y)
    if [ "$_year" -lt 2024 ]; then
        log_error "Preflight failed: System clock is not set (NTP failed)."
        journal_unlock
        exit 1
    fi
    
    if ! ip link show "$WG_UNIT" >/dev/null 2>&1; then
        log_error "Preflight failed: Interface $WG_UNIT does not exist."
        journal_unlock
        exit 1
    fi
    
    if ! platform_read_config; then
        log_error "Preflight failed: Could not read platform config."
        journal_unlock
        exit 1
    fi
    
    local _old_pubkey="$CURRENT_PUBKEY"
    
    # Keygen
    local _priv _pub
    _priv=$(umask 077 && wg genkey)
    _pub=$(printf '%s\n' "$_priv" | wg pubkey)
    
    if [ -z "$_pub" ] || [ -z "$_priv" ]; then
        log_error "Keygen failed."
        journal_unlock
        exit 1
    fi
    
    # Validate base64 length (usually 44 chars)
    if [ "${#_priv}" -ne 44 ] || [ "${#_pub}" -ne 44 ]; then
        log_error "Keygen output is not valid base64."
        journal_unlock
        exit 1
    fi
    
    if [ "$_dry_run" -eq 1 ]; then
        log_info "DRY-RUN: Skipping journal write (fase=KEYED)."
    else
        journal_write "fase=KEYED" "privkey_nova=$_priv" "pubkey_nova=$_pub" "pubkey_antiga=$_old_pubkey"
    fi
    
    # Auth
    local _account _token
    _account=$(cat "$ACCOUNT_FILE")
    _token=$(_api_retry api_post_token "$_account") || {
        log_error "Failed to auth to Mullvad API."
        journal_unlock
        exit 1
    }
    
    # Resolve
    local _id
    _rc=0
    _id=$(_api_retry api_get_device_id "$_token" "$_old_pubkey") || _rc=$?
    if [ "$_rc" -ne 0 ] || [ -z "$_id" ]; then
        log_error "Failed to resolve device by pubkey."
        journal_unlock
        exit 1
    fi
    
    if [ "$_dry_run" -eq 1 ]; then
        log_info "DRY-RUN completed successfully. Aborting before API and router mutation."
        journal_unlock
        exit 0
    fi
    
    journal_write "fase=PUT_SENT"
    
    _do_put_and_apply "$_token" "$_id" "$_priv" "$_pub" || {
        journal_unlock
        exit 1
    }
}

main "$@"
