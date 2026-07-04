#!/bin/sh
# shellcheck disable=SC3043
# lib/journal.sh

JOURNAL_FILE="${JOURNAL_FILE:-/tmp/wg-molt.journal}"
LOCK_DIR="${LOCK_DIR:-/tmp/wg-molt.lock}"

journal_lock() {
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        return 1
    fi
    return 0
}

journal_unlock() {
    rm -rf "$LOCK_DIR"
}

journal_write() {
    local _tmp _tmp2 _arg _key _val _old_umask
    _tmp="${JOURNAL_FILE}.tmp.$$"
    _tmp2="${JOURNAL_FILE}.tmp2.$$"
    
    _old_umask=$(umask)
    umask 077
    
    if [ -f "$JOURNAL_FILE" ]; then
        cp "$JOURNAL_FILE" "$_tmp" || { umask "$_old_umask"; return 1; }
    else
        touch "$_tmp" || { umask "$_old_umask"; return 1; }
    fi
    
    for _arg in "$@"; do
        _key="${_arg%%=*}"
        _val="${_arg#*=}"
        
        # Safely filter out the old key. Do NOT swallow errors (prevent data loss)
        awk -v k="$_key" 'BEGIN{l=length(k)} substr($0,1,l+1) != k"=" {print}' "$_tmp" > "$_tmp2" || { umask "$_old_umask"; return 1; }
        printf '%s=%s\n' "$_key" "$_val" >> "$_tmp2" || { umask "$_old_umask"; return 1; }
        mv "$_tmp2" "$_tmp" || { umask "$_old_umask"; return 1; }
    done
    
    # Atomic replace
    mv "$_tmp" "$JOURNAL_FILE" || { umask "$_old_umask"; return 1; }
    
    umask "$_old_umask"
    return 0
}

journal_read() {
    local _key="$1"
    if [ -f "$JOURNAL_FILE" ]; then
        awk -v k="$_key" 'BEGIN{l=length(k)} substr($0,1,l+1) == k"=" {print substr($0,l+2)}' "$JOURNAL_FILE"
    fi
}

journal_clean() {
    rm -f "$JOURNAL_FILE" "${JOURNAL_FILE}.tmp."* "${JOURNAL_FILE}.tmp2."*
}
