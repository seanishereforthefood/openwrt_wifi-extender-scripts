#!/bin/sh
# OpenWrt Client Mode (STA) Setup - Use wifi as uplink for LAN/WAN ports on device 

# ============================================
# Configuration
# ============================================
LOG_FILE="/tmp/wifi_client_setup.log"
SAFE_5G_CHANNEL="36"
SAFE_2G_CHANNEL="1"
DEBUG_MODE=${DEBUG:-0}

# Signal filtering defaults
DEFAULT_SIGNAL_THRESHOLD=-85
SIGNAL_THRESHOLD=$DEFAULT_SIGNAL_THRESHOLD
FILTER_ENABLED=1

# ============================================
# Parse Command Line Arguments
# ============================================
parse_arguments() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -s|--no-filter)
                FILTER_ENABLED=0
                write_log "[INFO] Signal filtering disabled"
                ;;
            -S|--signal-threshold)
                shift
                if [ -n "$1" ] && [ "$1" -eq "$1" ] 2>/dev/null; then
                    # Ensure it's negative
                    if [ "$1" -gt 0 ]; then
                        SIGNAL_THRESHOLD=$((-1 * $1))
                    else
                        SIGNAL_THRESHOLD=$1
                    fi
                    write_log "[INFO] Signal threshold set to ${SIGNAL_THRESHOLD} dBm"
                else
                    echo "Error: -S requires a numeric signal threshold"
                    show_usage
                    exit 1
                fi
                ;;
            -d|--debug)
                DEBUG_MODE=1
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
        shift
    done
}

show_usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  -s, --no-filter           Disable signal strength filtering
  -S, --signal-threshold N  Set signal threshold (default: -85 dBm)
                           Networks weaker than N dBm will be filtered
  -d, --debug              Enable debug mode
  -h, --help               Show this help message

Examples:
  $0                    # Use default filtering (-85 dBm or better)
  $0 -s                 # Show all visible networks
  $0 -S 70              # Only show -70 dBm or better
  $0 -S -75             # Only show -75 dBm or better
EOF
}

# ============================================
# Utility Functions
# ============================================

write_log() {
    echo "$1" | tee -a "$LOG_FILE" >&2
}

debug_log() {
    if [ "$DEBUG_MODE" -eq 1 ]; then
        echo "[DEBUG] $1" | tee -a "$LOG_FILE" >&2
    fi
}

# Proper numeric comparison for negative dBm values
signal_meets_threshold() {
    local signal=$1
    local threshold=$2

    # Disabled filter always returns true
    if [ "$FILTER_ENABLED" -eq 0 ]; then
        return 0
    fi

    # Force numeric comparison by using arithmetic evaluation
    # -51 is better than -85 (greater when comparing negative numbers)
    if [ $(($signal)) -ge $(($threshold)) ]; then
        return 0  # Signal is strong enough
    else
        return 1  # Signal is too weak
    fi
}

is_dfs_channel() {
    local channel=$1
    [ "$channel" -ge 52 ] && [ "$channel" -le 144 ]
}

# ============================================
# Radio Preparation Functions
# ============================================

save_current_config() {
    write_log "[INFO] Saving current configuration..."
    rm -f /tmp/wifi_saved_state

    for radio in $ALL_RADIOS; do
        local channel=$(uci get wireless.${radio}.channel 2>/dev/null || echo "auto")
        local disabled=$(uci get wireless.${radio}.disabled 2>/dev/null || echo "0")
        echo "${radio}:${channel}:${disabled}" >> /tmp/wifi_saved_state
        debug_log "Saved $radio: channel=$channel disabled=$disabled"
    done
}

set_radios_to_non_dfs() {
    write_log "[INFO] Setting radios to non-DFS channels..."

    for radio in $ALL_RADIOS; do
        local band=$(uci get wireless.${radio}.band 2>/dev/null || "")
        local new_channel=""

        if [ "$band" = "2g" ]; then
            new_channel="$SAFE_2G_CHANNEL"
        else
            new_channel="$SAFE_5G_CHANNEL"
        fi

        uci set wireless.${radio}.channel="$new_channel"
        uci set wireless.${radio}.disabled='0'
        write_log "  [$radio] Set to channel $new_channel"
    done
}

disable_all_ap_interfaces() {
    write_log "[INFO] Disabling AP interfaces..."

    local all_ifaces=$(uci show wireless 2>/dev/null | grep "=wifi-iface" | cut -d. -f2 | cut -d= -f1)

    for iface in $all_ifaces; do
        local mode=$(uci get wireless.${iface}.mode 2>/dev/null)
        if [ "$mode" = "ap" ]; then
            uci set wireless.${iface}.disabled='1'
            debug_log "Disabled AP interface: $iface"
        fi
    done
}

wait_for_radios() {
    write_log "[INFO] Waiting for radios to initialize..."

    local min_wait=8
    local max_wait=15
    local elapsed=0

    while [ $elapsed -lt $max_wait ]; do
        if [ $elapsed -lt $min_wait ]; then
            printf "  Initializing... %ds\r" "$elapsed" >&2
            sleep 1
            elapsed=$((elapsed + 1))
            continue
        fi

        local all_ready=1
        for radio in $ALL_RADIOS; do
            if iwinfo "$radio" scan 2>&1 | head -2 | grep -q "Scanning not possible"; then
                all_ready=0
                break
            fi
        done

        if [ $all_ready -eq 1 ]; then
            printf "\n" >&2
            write_log "[OK] All radios ready after ${elapsed}s"
            return 0
        fi

        printf "  Waiting for radios... %ds\r" "$elapsed" >&2
        sleep 1
        elapsed=$((elapsed + 1))
    done

    printf "\n" >&2
    write_log "[WARN] Proceeding after ${elapsed}s"
}

prepare_for_scanning() {
    write_log ""
    write_log "=== Preparing Radios ==="

    save_current_config
    set_radios_to_non_dfs
    disable_all_ap_interfaces

    uci commit wireless
    wifi reload 2>/dev/null

    wait_for_radios

    write_log "[OK] Radios prepared"
    write_log ""
}

# ============================================
# Shell-Based Scanning with Numeric Comparison
# ============================================

scan_radio_with_retry() {
    local radio=$1
    local output_file=$2
    local max_attempts=3
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        debug_log "Scan attempt $attempt for $radio"

        iwinfo "$radio" scan > "$output_file" 2>&1

        if [ $? -eq 0 ] && \
           ! grep -q "Scanning not possible" "$output_file" && \
           grep -q "Cell [0-9]" "$output_file"; then
            local count=$(grep -c "Cell [0-9]" "$output_file")
            write_log "  [OK] Found $count cells"
            return 0
        fi

        if [ $attempt -lt $max_attempts ]; then
            write_log "  [RETRY] Attempt $attempt failed, waiting 2s..."
            sleep 2
        fi

        attempt=$((attempt + 1))
    done

    write_log "  [FAIL] Could not scan"
    return 1
}

# Shell-based parser with proper numeric comparison
parse_scan_shell() {
    local radio=$1
    local scan_file=$2
    local input_file=$3

    debug_log "Parsing scan for $radio (shell-based)"

    local bssid=""
    local ssid=""
    local channel=""
    local signal="-99"
    local encryption="Open"
    local saved=0
    local filtered=0
    local skipped=0

    while IFS= read -r line; do
        # Check for new cell
        if echo "$line" | grep -q "^Cell [0-9]* - Address:"; then
            # Save previous network if complete
            if [ -n "$bssid" ] && [ -n "$ssid" ] && [ -n "$channel" ]; then
                # Skip hidden networks
                if [ "$ssid" = "unknown" ] || [ "$ssid" = "" ]; then
                    skipped=$((skipped + 1))
                    debug_log "Skipped hidden network: $bssid"
                # Check signal strength with numeric comparison
                elif signal_meets_threshold "$signal" "$SIGNAL_THRESHOLD"; then
                    # Sanitize SSID
                    ssid=$(echo "$ssid" | tr -d '|`$"\\' | cut -c1-32)
                    # Save to file
                    echo "${radio}|${ssid}|${bssid}|${signal}|${channel}|${encryption}" >> "$scan_file"
                    saved=$((saved + 1))
                    debug_log "Saved: $ssid ($signal dBm)"
                else
                    filtered=$((filtered + 1))
                    debug_log "Filtered: $ssid ($signal dBm < $SIGNAL_THRESHOLD dBm)"
                fi
            fi

            # Extract BSSID from current line
            bssid=$(echo "$line" | grep -oE "([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}" | head -1)

            # Reset fields
            ssid=""
            channel=""
            signal="-99"
            encryption="Open"
        fi

        # Extract SSID
        if echo "$line" | grep -q "ESSID:"; then
            # Try quoted format first
            ssid=$(echo "$line" | sed -n 's/.*ESSID: *"\([^"]*\)".*/\1/p')
            # Check for unquoted "unknown"
            if [ -z "$ssid" ] && echo "$line" | grep -q "ESSID: *unknown"; then
                ssid="unknown"
            fi
        fi

        # Extract Channel
        if echo "$line" | grep -q "Channel:"; then
            channel=$(echo "$line" | sed 's/.*Channel: *\([0-9]*\).*/\1/')
        fi

        # Extract Signal (force to be negative)
        if echo "$line" | grep -q "Signal:"; then
            signal=$(echo "$line" | grep -oE "\-[0-9]+" | head -1)
            # Ensure it's negative
            if [ -n "$signal" ]; then
                signal="${signal#-}"  # Remove any existing minus
                signal="-${signal}"   # Add minus back
            fi
        fi

        # Extract Encryption
        if echo "$line" | grep -q "Encryption:"; then
            if echo "$line" | grep -q "WPA3\|SAE"; then
                encryption="WPA3"
            elif echo "$line" | grep -q "mixed WPA2/WPA3"; then
                encryption="WPA2/3"
            elif echo "$line" | grep -q "WPA2"; then
                encryption="WPA2"
            elif echo "$line" | grep -q "WPA"; then
                encryption="WPA"
            elif echo "$line" | grep -q "WEP"; then
                encryption="WEP"
            elif echo "$line" | grep -q "none"; then
                encryption="Open"
            fi
        fi
    done < "$input_file"

    # Don't forget the last network
    if [ -n "$bssid" ] && [ -n "$ssid" ] && [ -n "$channel" ]; then
        if [ "$ssid" = "unknown" ] || [ "$ssid" = "" ]; then
            skipped=$((skipped + 1))
        elif signal_meets_threshold "$signal" "$SIGNAL_THRESHOLD"; then
            ssid=$(echo "$ssid" | tr -d '|`$"\\' | cut -c1-32)
            echo "${radio}|${ssid}|${bssid}|${signal}|${channel}|${encryption}" >> "$scan_file"
            saved=$((saved + 1))
            debug_log "Saved: $ssid ($signal dBm)"
        else
            filtered=$((filtered + 1))
            debug_log "Filtered: $ssid ($signal dBm < $SIGNAL_THRESHOLD dBm)"
        fi
    fi

    write_log "  [INFO] Saved: $saved, Filtered: $filtered, Hidden: $skipped"
}

perform_scanning() {
    write_log "=== Scanning All Radios ==="
    write_log "[INFO] Hidden networks will be ignored"

    if [ "$FILTER_ENABLED" -eq 1 ]; then
        write_log "[INFO] Signal filter: ${SIGNAL_THRESHOLD} dBm or better"
        write_log "[INFO] Example: -51 dBm is kept (better), -90 dBm is filtered (worse)"
    else
        write_log "[INFO] Signal filter: disabled (showing all visible networks)"
    fi
    write_log ""

    local scan_file="/tmp/wifi_networks_$$.txt"
    > "$scan_file"

    for radio in $ALL_RADIOS; do
        local band=$(uci get wireless.$radio.band 2>/dev/null || "unknown")
        write_log "Scanning $radio (${band} band)..."

        local temp_scan="/tmp/scan_${radio}_$$.tmp"

        if scan_radio_with_retry "$radio" "$temp_scan"; then
            # Save debug copy if needed
            if [ "$DEBUG_MODE" -eq 1 ]; then
                cp "$temp_scan" "/tmp/debug_${radio}_scan.txt"
                debug_log "Raw scan saved to /tmp/debug_${radio}_scan.txt"
                local raw_count=$(grep -c "ESSID:" "$temp_scan")
                debug_log "Raw networks in scan: $raw_count"
            fi

            # Parse with shell-based parser
            parse_scan_shell "$radio" "$scan_file" "$temp_scan"

            local count=$(grep -c "^${radio}|" "$scan_file" 2>/dev/null || echo "0")
            write_log "  [RESULT] $count visible networks from $radio"
        fi

        rm -f "$temp_scan"
        write_log ""
    done

    # Debug: show scan file stats
    if [ "$DEBUG_MODE" -eq 1 ]; then
        debug_log "Final scan file: $scan_file"
        debug_log "Total networks: $(wc -l < "$scan_file")"
        if [ -f "$scan_file" ] && [ $(wc -l < "$scan_file") -gt 0 ]; then
            debug_log "Sample entries:"
            head -3 "$scan_file" | while IFS='|' read -r r s b si c e; do
                debug_log "  $s: ${si}dBm on ch$c"
            done
        fi
    fi

    # Only output filename to stdout
    echo "$scan_file"
}

# ============================================
# Display Functions
# ============================================

display_networks() {
    local scan_file=$1

    if [ ! -f "$scan_file" ]; then
        write_log "[ERROR] Scan file not found: $scan_file"
        return 1
    fi

    local total=$(wc -l < "$scan_file" 2>/dev/null || echo "0")

    if [ "$total" -eq 0 ]; then
        write_log "[ERROR] No visible networks found"
        if [ "$FILTER_ENABLED" -eq 1 ]; then
            write_log "[HINT] Try -s to disable filter or -S 90 for weaker signals"
        fi
        return 1
    fi

    write_log "=== Found $total Visible Networks ==="
    write_log ""

    # Header
    printf "%-3s %-6s %-22s %-17s %-9s %-8s %-10s\n" \
        "#" "Radio" "SSID" "BSSID" "Signal" "Channel" "Security" >&2
    printf "%s\n" "----------------------------------------------------------------------" >&2

    # Sort by signal strength (numeric sort on field 4)
    sort -t'|' -k4 -rn "$scan_file" | head -30 | {
        local num=1
        while IFS='|' read -r radio ssid bssid signal channel encryption; do
            # Format channel
            local ch_display="$channel"
            if is_dfs_channel "$channel"; then
                ch_display="${channel}*"
            fi

            # Truncate SSID for display
            local display_ssid="$ssid"
            if [ ${#display_ssid} -gt 22 ]; then
                display_ssid=$(echo "$display_ssid" | cut -c1-19)...
            fi

            # Signal indicator (color-code in mind)
            local sig_display="${signal}dBm"

            printf "%-3d %-6s %-22s %-17s %-9s %-8s %-10s\n" \
                "$num" "$radio" "$display_ssid" "$bssid" "$sig_display" "$ch_display" "$encryption" >&2

            num=$((num + 1))
        done
    }

    echo "" >&2
    if is_dfs_channel 52; then
        echo "* = DFS channel (may require CAC wait if used as AP)" >&2
    fi

    return 0
}

# ============================================
# Configuration Functions
# ============================================

restore_original_config() {
    write_log "[INFO] Restoring configuration..."

    if [ ! -f /tmp/wifi_saved_state ]; then
        return 1
    fi

    while IFS=':' read -r radio channel disabled; do
        if [ -n "$channel" ] && [ "$channel" != "auto" ]; then
            uci set wireless.${radio}.channel="$channel"
        else
            uci delete wireless.${radio}.channel 2>/dev/null
        fi

        if [ "$disabled" = "1" ]; then
            uci set wireless.${radio}.disabled='1'
        else
            uci delete wireless.${radio}.disabled 2>/dev/null
        fi
    done < /tmp/wifi_saved_state

    # Re-enable AP interfaces
    local all_ifaces=$(uci show wireless 2>/dev/null | grep "=wifi-iface" | cut -d. -f2 | cut -d= -f1)
    for iface in $all_ifaces; do
        if [ "$(uci get wireless.${iface}.mode 2>/dev/null)" = "ap" ]; then
            uci delete wireless.${iface}.disabled 2>/dev/null
        fi
    done

    uci commit wireless
    wifi reload 2>/dev/null
    rm -f /tmp/wifi_saved_state
}

apply_sta_config() {
    local radio=$1
    local ssid=$2
    local bssid=$3
    local channel=$4
    local encryption=$5
    local password=$6
    local lan_ip=$7

    write_log "[INFO] Applying configuration..."

    # Network configuration
    uci set network.lan.ipaddr="$lan_ip"
    uci set network.wwan="interface"
    uci set network.wwan.proto="dhcp"
    uci add_list firewall.@zone[1].network="wwan" 2>/dev/null

    # Radio configuration
    uci set wireless.${radio}.disabled='0'
    uci set wireless.${radio}.channel="$channel"

    # Remove existing wwan interface
    uci delete wireless.wwan 2>/dev/null

    # Create new STA interface
    uci set wireless.wwan="wifi-iface"
    uci set wireless.wwan.device="$radio"
    uci set wireless.wwan.network="wwan"
    uci set wireless.wwan.mode="sta"
    uci set wireless.wwan.ssid="$ssid"
    uci set wireless.wwan.bssid="$bssid"

    # Set encryption
    case "$encryption" in
        WPA3|WPA2/3)
            uci set wireless.wwan.encryption="sae"
            ;;
        WPA2)
            uci set wireless.wwan.encryption="psk2"
            ;;
        WPA)
            uci set wireless.wwan.encryption="psk"
            ;;
        WEP)
            uci set wireless.wwan.encryption="wep"
            ;;
        *)
            uci set wireless.wwan.encryption="none"
            ;;
    esac

    if [ -n "$password" ] && [ "$encryption" != "Open" ]; then
        uci set wireless.wwan.key="$password"
    fi

    # Disable AP interfaces for client-only mode
    local all_ifaces=$(uci show wireless 2>/dev/null | grep "=wifi-iface" | cut -d. -f2 | cut -d= -f1)
    for iface in $all_ifaces; do
        if [ "$(uci get wireless.${iface}.mode 2>/dev/null)" = "ap" ]; then
            uci set wireless.${iface}.disabled='1'
        fi
    done

    uci commit
    write_log "[OK] Configuration saved"
}

check_connection() {
    local channel=$1
    write_log "=== Checking Connection ==="

    local wait_time=10
    if is_dfs_channel "$channel"; then
        wait_time=12
        write_log "[INFO] DFS channel $channel (STA mode, no CAC required)"
    fi

    write_log "[INFO] Waiting ${wait_time}s for connection..."
    sleep $wait_time

    if iwinfo 2>/dev/null | grep -q "ESSID:"; then
        write_log "[OK] Wireless connected"
        iwinfo 2>/dev/null | grep -A3 "ESSID:" | head -5 >&2
    else
        write_log "[WARN] Not connected yet (may need more time)"
    fi

    if ubus call network.interface.wwan status 2>/dev/null | grep -q '"up": true'; then
        write_log "[OK] Network interface up"
    fi

    if ping -c 2 -W 5 8.8.8.8 >/dev/null 2>&1; then
        write_log "[OK] Internet reachable"
    else
        write_log "[INFO] Internet not reachable yet"
    fi
}

# ============================================
# Main Script
# ============================================

main() {
    echo "" >&2
    echo "============================================" >&2
    echo "     OpenWrt WiFi Client Setup v24" >&2
    echo "     Shell-based with numeric comparison" >&2
    echo "============================================" >&2
    echo "" >&2

    SSH_CLIENT_IP=$(echo "$SSH_CLIENT" | awk '{print $1}')
    CURRENT_LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null || echo "192.168.1.1")

    if [ -n "$SSH_CLIENT_IP" ]; then
        write_log "[WARN] SSH connection from: $SSH_CLIENT_IP"
        write_log "[INFO] Current LAN IP: $CURRENT_LAN_IP"
        write_log ""
    fi

    # Menu
    echo "Select mode:" >&2
    echo "  [S] Scan only" >&2
    echo "  [C] Configure client mode" >&2
    echo "  [D] Debug scan" >&2
    echo "  [Q] Quit" >&2
    echo "" >&2
    printf "Choice: " >&2
    read -r choice

    case "$choice" in
        [Ss]) SCAN_ONLY=1 ;;
        [Cc]) SCAN_ONLY=0 ;;
        [Dd]) SCAN_ONLY=1; DEBUG_MODE=1 ;;
        *) exit 0 ;;
    esac

    # Discover radios
    write_log ""
    write_log "Discovering wireless radios..."
    ALL_RADIOS=$(uci show wireless 2>/dev/null | awk -F'[.=]' '/^wireless\.[^.]*=wifi-device$/{print $2}')

    if [ -z "$ALL_RADIOS" ]; then
        write_log "[ERROR] No wireless radios found"
        exit 1
    fi

    radio_count=$(echo "$ALL_RADIOS" | wc -w)
    write_log "[OK] Found $radio_count radio(s): $ALL_RADIOS"

    # Prepare and scan
    prepare_for_scanning
    scan_file=$(perform_scanning)

    # Display results
    if ! display_networks "$scan_file"; then
        restore_original_config
        rm -f "$scan_file"
        exit 1
    fi

    if [ $SCAN_ONLY -eq 1 ]; then
        write_log ""
        write_log "[INFO] Scan complete"
        restore_original_config
        rm -f "$scan_file"
        exit 0
    fi

    # Get user selection
    echo "" >&2
    printf "Select network (1-30) or [Q] to quit: " >&2
    read -r selection

    if [ "$selection" = "Q" ] || [ "$selection" = "q" ]; then
        restore_original_config
        rm -f "$scan_file"
        exit 0
    fi

    # Validate selection
    if ! [ "$selection" -eq "$selection" ] 2>/dev/null || [ "$selection" -lt 1 ] || [ "$selection" -gt 30 ]; then
        write_log "[ERROR] Invalid selection"
        restore_original_config
        rm -f "$scan_file"
        exit 1
    fi

    # Get selected network
    SELECTED=$(sort -t'|' -k4 -rn "$scan_file" | sed -n "${selection}p")
    if [ -z "$SELECTED" ]; then
        write_log "[ERROR] Invalid selection"
        restore_original_config
        rm -f "$scan_file"
        exit 1
    fi

    # Parse selection
    RADIO=$(echo "$SELECTED" | cut -d'|' -f1)
    SSID=$(echo "$SELECTED" | cut -d'|' -f2)
    BSSID=$(echo "$SELECTED" | cut -d'|' -f3)
    SIGNAL=$(echo "$SELECTED" | cut -d'|' -f4)
    CHANNEL=$(echo "$SELECTED" | cut -d'|' -f5)
    ENCRYPTION=$(echo "$SELECTED" | cut -d'|' -f6)

    # Get password if needed
    PASSWORD=""
    if [ "$ENCRYPTION" != "Open" ]; then
        echo "" >&2
        printf "Enter password for '%s': " "$SSID" >&2
        read -r PASSWORD
    fi

    # Get LAN IP
    echo "" >&2
    echo "Current LAN IP: $CURRENT_LAN_IP" >&2
    printf "New LAN IP (press Enter to keep current): " >&2
    read -r LAN_IP
    [ -z "$LAN_IP" ] && LAN_IP="$CURRENT_LAN_IP"

    # Confirm configuration
    echo "" >&2
    echo "============================================" >&2
    echo "Configuration Summary:" >&2
    echo "  SSID:       $SSID" >&2
    echo "  BSSID:      $BSSID" >&2
    echo "  Radio:      $RADIO" >&2
    echo "  Channel:    $CHANNEL$(is_dfs_channel $CHANNEL && echo ' [DFS]')" >&2
    echo "  Signal:     $SIGNAL dBm" >&2
    echo "  Security:   $ENCRYPTION" >&2
    echo "  LAN IP:     $LAN_IP" >&2
    echo "============================================" >&2
    echo "" >&2
    printf "Apply this configuration? (y/n): " >&2
    read -r confirm

    if [ "$confirm" != "y" ]; then
        write_log "[INFO] Configuration cancelled"
        restore_original_config
        rm -f "$scan_file"
        exit 0
    fi

    # Apply configuration
    apply_sta_config "$RADIO" "$SSID" "$BSSID" "$CHANNEL" "$ENCRYPTION" "$PASSWORD" "$LAN_IP"

    # Clean up
    rm -f "$scan_file" /tmp/wifi_saved_state /tmp/scan_*.tmp

    # Restart services
    write_log ""
    write_log "Restarting network services..."
    /etc/init.d/network restart
    wifi reload 2>/dev/null

    # Check if LAN IP changed
    if [ "$LAN_IP" != "$CURRENT_LAN_IP" ]; then
        echo "" >&2
        echo "============================================" >&2
        echo "IMPORTANT: LAN IP has changed!" >&2
        echo "Reconnect SSH to: $LAN_IP" >&2
        echo "============================================" >&2
        exit 0
    fi

    # Check connection
    check_connection "$CHANNEL"

    echo "" >&2
    echo "============================================" >&2
    echo "Setup complete!" >&2
    echo "" >&2
    echo "Commands to check status:" >&2
    echo "  wifi status    - Check WiFi status" >&2
    echo "  iwinfo         - Show wireless details" >&2
    echo "  logread -f     - Monitor system logs" >&2
    echo "============================================" >&2
}

# ============================================
# Entry Point
# ============================================

# Initialize log
> "$LOG_FILE"

# Parse command line arguments
parse_arguments "$@"

# Run main
main

