#!/bin/sh
# shellcheck disable=SC3043
# platform/merlin.sh

# Requirements: WG_UNIT must be set (e.g., wgc1)

_discover_nvram() {
    [ -n "$NVRAM_VAR_PRIVKEY" ] && return 0
    
    local _privkey _ip4 _ip6 _nvram_dump _match
    _privkey=$(wg show "$WG_UNIT" private-key 2>/dev/null)
    _ip4=$(ip -4 addr show dev "$WG_UNIT" 2>/dev/null | awk '$1 == "inet" { split($2, a, "/"); print a[1]; exit }')
    _ip6=$(ip -6 addr show dev "$WG_UNIT" scope global 2>/dev/null | awk '$1 == "inet6" { split($2, a, "/"); print a[1]; exit }')
    
    _nvram_dump=$(nvram show 2>/dev/null | grep "^${WG_UNIT}_")
    
    if [ -n "$_privkey" ]; then
        _match=$(printf '%s\n' "$_nvram_dump" | grep -F "=$_privkey" | head -n1)
        if [ -n "$_match" ]; then
            NVRAM_VAR_PRIVKEY="${_match%%=*}"
        fi
    fi
    
    if [ -n "$_ip4" ]; then
        _match=$(printf '%s\n' "$_nvram_dump" | awk -v ip="$_ip4" -F= '
            {
                if ($2 == ip || substr($2, 1, length(ip)+1) == ip "/") {
                    print $0
                    exit
                }
            }
        ')
        if [ -n "$_match" ]; then
            NVRAM_VAR_IPV4="${_match%%=*}"
        fi
    fi
    
    if [ -n "$_ip6" ]; then
        _match=$(printf '%s\n' "$_nvram_dump" | awk -v ip="$_ip6" -F= '
            {
                val = tolower($2)
                ip_lower = tolower(ip)
                if (val == ip_lower || substr(val, 1, length(ip_lower)+1) == ip_lower "/") {
                    print $0
                    exit
                }
            }
        ')
        if [ -n "$_match" ]; then
            NVRAM_VAR_IPV6="${_match%%=*}"
        fi
    fi
    
    if [ -z "$NVRAM_VAR_PRIVKEY" ]; then
        log_error "Could not dynamically discover NVRAM variables for $WG_UNIT."
        return 1
    fi
    
    return 0
}

platform_read_config() {
    # Ler pubkey atual da interface ativa (fonte de verdade viva)
    CURRENT_PUBKEY=$(wg show "$WG_UNIT" public-key 2>/dev/null)
    if [ -z "$CURRENT_PUBKEY" ]; then
        log_error "Interface $WG_UNIT not found or has no public key."
        return 1
    fi
    
    _discover_nvram || return 1
}

platform_apply_runtime() {
    local _privkey_file="$1"
    local _ipv4="$2"
    local _ipv6="$3"
    
    [ -z "$_ipv4" ] && return 1
    
    wg set "$WG_UNIT" private-key "$_privkey_file" || return 1
    
    ip -4 addr flush dev "$WG_UNIT"
    ip -4 addr add "$_ipv4/32" dev "$WG_UNIT" || return 1
    
    if [ -n "$_ipv6" ]; then
        ip -6 addr flush dev "$WG_UNIT" 2>/dev/null || true
        ip -6 addr add "$_ipv6/128" dev "$WG_UNIT" 2>/dev/null || true
    fi
}

platform_persist_config() {
    local _privkey_file="$1"
    local _ipv4="$2"
    local _ipv6="$3"
    local _privkey
    
    _privkey=$(cat "$_privkey_file")
    
    # SECURITY NOTE: Asuswrt-Merlin nvram utility inherently leaks CLI arguments to ps.
    # Passing the private key via argv is unavoidable here without custom binaries.
    nvram set "$NVRAM_VAR_PRIVKEY"="$_privkey"
    
    if [ -n "$NVRAM_VAR_IPV4" ]; then
        local _old_ipv4_val _old_ip _new_ipv4_val
        _old_ipv4_val=$(nvram get "$NVRAM_VAR_IPV4")
        _old_ip="${_old_ipv4_val%%/*}"
        _new_ipv4_val="${_ipv4}${_old_ipv4_val#"$_old_ip"}"
        nvram set "$NVRAM_VAR_IPV4"="$_new_ipv4_val"
    fi
    
    if [ -n "$NVRAM_VAR_IPV6" ] && [ -n "$_ipv6" ]; then
        local _old_ipv6_val _old_ip6 _new_ipv6_val
        _old_ipv6_val=$(nvram get "$NVRAM_VAR_IPV6")
        _old_ip6="${_old_ipv6_val%%/*}"
        _new_ipv6_val="${_ipv6}${_old_ipv6_val#"$_old_ip6"}"
        nvram set "$NVRAM_VAR_IPV6"="$_new_ipv6_val"
    fi
    
    nvram commit
}

platform_schedule() {
    local _action="$1"
    local _script_path="$2"
    local _cron_name="wg-molt"
    local _services_start="${SVC_START:-/jffs/scripts/services-start}"
    
    if [ "$_action" = "install" ]; then
        local _seed _min _hr
        _seed=$(awk '{print int($1*100)}' /proc/uptime 2>/dev/null)
        if [ -z "$_seed" ]; then
            _seed=$(date +%N 2>/dev/null | sed 's/^0*//' || echo "12345")
        fi
        _min=$(awk -v s="$_seed" 'BEGIN{srand(s); print int(rand()*60)}')
        _hr=$(awk -v s="$_seed" 'BEGIN{srand(s+1); print int(rand()*3) + 3}')
        
        local _cron_job="$_min $_hr * * * \"$_script_path\""
        
        cru a "$_cron_name" "$_cron_job"
        
        if [ ! -f "$_services_start" ]; then
            echo "#!/bin/sh" > "$_services_start"
            chmod a+rx "$_services_start"
        fi
        
        # Remove old block first
        sed -i '/# --- BEGIN wg-molt ---/d; /cru a wg-molt/d; /rotate\.sh.*--reconcile-only/d; /# --- END wg-molt ---/d' "$_services_start"
        
        cat <<EOF >> "$_services_start"
# --- BEGIN wg-molt ---
cru a wg-molt "$_cron_job"
"$_script_path" --reconcile-only &
# --- END wg-molt ---
EOF
    elif [ "$_action" = "remove" ]; then
        cru d "$_cron_name" >/dev/null 2>&1 || true
        if [ -f "$_services_start" ]; then
            sed -i '/# --- BEGIN wg-molt ---/d; /cru a wg-molt/d; /rotate\.sh.*--reconcile-only/d; /# --- END wg-molt ---/d' "$_services_start"
        fi
    fi
}
