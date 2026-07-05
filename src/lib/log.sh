#!/bin/sh
# shellcheck disable=SC3043
# lib/log.sh

_log_write() {
    local _level="$1"
    local _priority="$2"
    shift 2
    
    local _msg _old_umask
    # Redact base64 keys, 16-digit accounts, and mva_ tokens
    _msg=$(printf '%s\n' "$*" | sed 's/[A-Za-z0-9+/]\{43\}=/<REDACTED>/g; s/[0-9]\{16\}/<REDACTED>/g; s/mva_[A-Za-z0-9_-]*/<REDACTED>/g')
    
    logger -t wg-molt -p "$_priority" "$_level: $_msg" 2>/dev/null || true
    
    if [ -n "${LOG_FILE:-}" ]; then
        _old_umask=$(umask)
        umask 077
        
        printf '%s %s: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$_level" "$_msg" >> "$LOG_FILE"
        
        local _size
        _size=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
        if [ "$_size" -gt 51200 ]; then
            mv "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null || true
        fi
        
        umask "$_old_umask"
    fi
}

log_info() {
    _log_write "INFO" "user.info" "$@"
}

log_warn() {
    _log_write "WARN" "user.warning" "$@"
}

log_error() {
    _log_write "ERROR" "user.err" "$@"
}
