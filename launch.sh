#!/bin/sh
PAK_DIR="$(dirname "$0")"
PAK_NAME="$(basename "$PAK_DIR")"
PAK_NAME="${PAK_NAME%.*}"
set -x

rm -f "$LOGS_PATH/$PAK_NAME.txt"
exec >>"$LOGS_PATH/$PAK_NAME.txt"
exec 2>&1

echo "$0" "$@"
cd "$PAK_DIR" || exit 1
mkdir -p "$USERDATA_PATH/$PAK_NAME"

architecture=arm
if uname -m | grep -q '64'; then
    architecture=arm64
fi

export PATH="$PAK_DIR/bin/$architecture:$PAK_DIR/bin/$PLATFORM:$PAK_DIR/bin:$PATH"

SERVICE_NAME="wireguard-go"
HUMAN_READABLE_NAME="WireGuard VPN"

WG_INTERFACE="wg0"
WG_CONFIG_FILE="$SDCARD_PATH/wg0.conf"
WG_STATE_DIR="$USERDATA_PATH/$PAK_NAME"
WG_SAVED_CONFIG="$WG_STATE_DIR/wg0.conf"
WG_RESOLV_BACKUP="$WG_STATE_DIR/resolv.conf.bak"

show_message() {
    message="$1"
    seconds="$2"

    if [ -z "$seconds" ]; then
        seconds="forever"
    fi

    killall minui-presenter >/dev/null 2>&1 || true
    echo "$message" 1>&2
    if [ "$seconds" = "forever" ]; then
        minui-presenter --message "$message" --timeout -1 &
    else
        minui-presenter --message "$message" --timeout "$seconds"
    fi
}

disable_start_on_boot() {
    sed -i "/${PAK_NAME}.pak-on-boot/d" "$SDCARD_PATH/.userdata/$PLATFORM/auto.sh"
    sync
    return 0
}

enable_start_on_boot() {
    if [ ! -f "$SDCARD_PATH/.userdata/$PLATFORM/auto.sh" ]; then
        echo '#!/bin/sh' >"$SDCARD_PATH/.userdata/$PLATFORM/auto.sh"
        echo '' >>"$SDCARD_PATH/.userdata/$PLATFORM/auto.sh"
    fi

    echo "test -f \"$PAK_DIR/bin/on-boot\" && \"$PAK_DIR/bin/on-boot\" # ${PAK_NAME}.pak-on-boot" >>"$SDCARD_PATH/.userdata/$PLATFORM/auto.sh"
    chmod +x "$SDCARD_PATH/.userdata/$PLATFORM/auto.sh"
    sync
    return 0
}

will_start_on_boot() {
    if grep -q "${PAK_NAME}.pak-on-boot" "$SDCARD_PATH/.userdata/$PLATFORM/auto.sh" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

is_service_running() {
    if ! pgrep -fn "$SERVICE_NAME" >/dev/null 2>&1; then
        return 1
    fi
    if ! ip link show "$WG_INTERFACE" >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

wait_for_service() {
    max_counter="$1"
    counter=0

    while ! is_service_running; do
        counter=$((counter + 1))
        if [ "$counter" -gt "$max_counter" ]; then
            return 1
        fi
        sleep 1
    done
}

wait_for_service_to_stop() {
    max_counter="$1"
    counter=0

    while is_service_running; do
        counter=$((counter + 1))
        if [ "$counter" -gt "$max_counter" ]; then
            return 1
        fi
        sleep 1
    done
}

get_service_pid() {
    pgrep -fn "$SERVICE_NAME" 2>/dev/null | sort | head -n 1 || true
}

wg_is_configured() {
    if [ ! -f "$WG_SAVED_CONFIG" ] || [ ! -s "$WG_SAVED_CONFIG" ]; then
        return 1
    fi
    return 0
}

wg_get_ip_address() {
    ip -4 -o addr show "$WG_INTERFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n 1
}

wg_get_latest_handshake() {
    # Returns the endpoint (host:port) of the first peer that has handshaken,
    # i.e. the peer the tunnel is actually carrying traffic to. Empty if no
    # peer has handshaken yet.
    handshake_peer="$(wg show "$WG_INTERFACE" latest-handshakes 2>/dev/null | awk '$2 != 0 {print $1; exit}')"
    [ -z "$handshake_peer" ] && return 0
    wg show "$WG_INTERFACE" endpoints 2>/dev/null | awk -v p="$handshake_peer" '$1 == p {print $2; exit}'
}

# Pull config-section keys from an INI-style wg conf. Reads from $WG_SAVED_CONFIG.
wg_conf_get() {
    section="$1"   # Interface or Peer
    key="$2"
    awk -v section="[$section]" -v key="$key" '
        $0 ~ /^\[.*\]/ { in_section = ($0 == section); next }
        in_section {
            # strip leading/trailing whitespace
            line = $0
            sub(/^[ \t]+/, "", line); sub(/[ \t]+$/, "", line)
            if (line == "" || substr(line, 1, 1) == "#") next
            # split on first =
            pos = index(line, "=")
            if (pos == 0) next
            k = substr(line, 1, pos - 1); v = substr(line, pos + 1)
            sub(/[ \t]+$/, "", k); sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
            if (k == key) print v
        }
    ' "$WG_SAVED_CONFIG"
}

# Yield each Peer block's AllowedIPs lines, one CIDR per output line.
wg_conf_allowed_ips() {
    awk '
        $0 ~ /^\[.*\]/ { peer = ($0 == "[Peer]"); next }
        peer {
            line = $0
            sub(/^[ \t]+/, "", line); sub(/[ \t]+$/, "", line)
            if (line == "" || substr(line, 1, 1) == "#") next
            pos = index(line, "=")
            if (pos == 0) next
            k = substr(line, 1, pos - 1); v = substr(line, pos + 1)
            sub(/[ \t]+$/, "", k); sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
            if (k == "AllowedIPs") {
                n = split(v, parts, ",")
                for (i = 1; i <= n; i++) {
                    cidr = parts[i]
                    sub(/^[ \t]+/, "", cidr); sub(/[ \t]+$/, "", cidr)
                    if (cidr != "") print cidr
                }
            }
        }
    ' "$WG_SAVED_CONFIG"
}

# Persist the user's wg0.conf into the state dir, locked to mode 0600, and
# remove the SD-card copy (FAT32 has no permissions, so the private key would
# otherwise be world-readable).
wg_persist_config() {
    if [ ! -f "$WG_CONFIG_FILE" ] || [ ! -s "$WG_CONFIG_FILE" ]; then
        return 1
    fi
    mkdir -p "$WG_STATE_DIR"
    cp "$WG_CONFIG_FILE" "$WG_SAVED_CONFIG"
    chmod 600 "$WG_SAVED_CONFIG"
    rm -f "$WG_CONFIG_FILE"
    sync
    return 0
}

dns_apply() {
    dns_raw="$(wg_conf_get Interface DNS)"
    if [ -z "$dns_raw" ]; then
        return 0
    fi

    if [ ! -f "$WG_RESOLV_BACKUP" ] && [ -e /etc/resolv.conf ]; then
        cp /etc/resolv.conf "$WG_RESOLV_BACKUP" 2>/dev/null || true
    fi

    new_resolv="/tmp/${PAK_NAME}-resolv.conf"
    : >"$new_resolv"

    # DNS = can carry both nameserver IPs and search domains, comma-separated.
    echo "$dns_raw" | tr ',' '\n' | while IFS= read -r entry; do
        entry="$(echo "$entry" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -z "$entry" ] && continue
        if echo "$entry" | grep -Eq '^[0-9a-fA-F:.]+$'; then
            echo "nameserver $entry" >>"$new_resolv"
        else
            echo "search $entry" >>"$new_resolv"
        fi
    done

    if [ -s "$new_resolv" ]; then
        cp "$new_resolv" /etc/resolv.conf 2>/dev/null || true
    fi
    rm -f "$new_resolv"
}

dns_restore() {
    if [ -f "$WG_RESOLV_BACKUP" ]; then
        mv "$WG_RESOLV_BACKUP" /etc/resolv.conf 2>/dev/null || true
    fi
}

# Tear down the tunnel without wg-quick: restore DNS, drop the interface,
# kill the userspace daemon.
service_off() {
    dns_restore
    ip link del "$WG_INTERFACE" 2>/dev/null || true
    killall "$SERVICE_NAME" 2>/dev/null || true
    return 0
}

# Bring the tunnel up: spawn wireguard-go, apply the saved config, plumb
# addresses/routes, then optionally swap resolv.conf.
wg_start() {
    if ! wg_is_configured; then
        if ! wg_persist_config; then
            return 1
        fi
    fi

    chmod 600 "$WG_SAVED_CONFIG" 2>/dev/null || true

    if ip link show "$WG_INTERFACE" >/dev/null 2>&1; then
        ip link del "$WG_INTERFACE" 2>/dev/null || true
    fi

    "$PAK_DIR/bin/$architecture/$SERVICE_NAME" "$WG_INTERFACE" &

    # wireguard-go creates the TUN device a beat after fork; wait briefly.
    counter=0
    while ! ip link show "$WG_INTERFACE" >/dev/null 2>&1; do
        counter=$((counter + 1))
        if [ "$counter" -gt 10 ]; then
            echo "wireguard-go did not create $WG_INTERFACE" 1>&2
            return 1
        fi
        sleep 1
    done

    if ! wg setconf "$WG_INTERFACE" "$WG_SAVED_CONFIG"; then
        echo "wg setconf failed" 1>&2
        return 1
    fi

    addresses="$(wg_conf_get Interface Address)"
    if [ -z "$addresses" ]; then
        echo "wg0.conf has no Address line" 1>&2
        return 1
    fi
    echo "$addresses" | tr ',' '\n' | while IFS= read -r addr; do
        addr="$(echo "$addr" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -z "$addr" ] && continue
        ip addr add "$addr" dev "$WG_INTERFACE" 2>/dev/null || true
    done

    mtu="$(wg_conf_get Interface MTU)"
    if [ -n "$mtu" ]; then
        ip link set "$WG_INTERFACE" mtu "$mtu" 2>/dev/null || true
    fi

    ip link set "$WG_INTERFACE" up

    # Routes per peer AllowedIPs. Skip 0.0.0.0/0 in v0.1 — handheld users
    # rarely want a default-route VPN, and we don't yet have a UI toggle for it.
    wg_conf_allowed_ips | while IFS= read -r cidr; do
        case "$cidr" in
            ""|0.0.0.0/0|::/0)
                continue
                ;;
        esac
        ip route add "$cidr" dev "$WG_INTERFACE" 2>/dev/null || true
    done

    dns_apply
    return 0
}

current_settings() {
    minui_list_file="/tmp/${PAK_NAME}-settings.json"
    rm -f "$minui_list_file"

    jq -rM '{settings: .settings}' "$PAK_DIR/config.json" >"$minui_list_file"
    if is_service_running; then
        jq '.settings[0].selected = 1' "$minui_list_file" >"$minui_list_file.tmp"
        mv "$minui_list_file.tmp" "$minui_list_file"
    fi

    if will_start_on_boot; then
        jq '.settings[1].selected = 1' "$minui_list_file" >"$minui_list_file.tmp"
        mv "$minui_list_file.tmp" "$minui_list_file"
    fi

    cat "$minui_list_file"
}

main_screen() {
    settings="$1"
    minui_list_file="/tmp/${PAK_NAME}-minui-list.json"
    rm -f "$minui_list_file"

    echo "$settings" >"$minui_list_file"

    if is_service_running; then
        service_pid="$(get_service_pid)"
        jq --arg pid "$service_pid" '.settings[.settings | length] |= . + {"name": "PID", "options": [$pid], "selected": 0, "features": {"unselectable": true}}' "$minui_list_file" >"$minui_list_file.tmp"
        mv "$minui_list_file.tmp" "$minui_list_file"

        ip_address="$(wg_get_ip_address)"
        if [ -n "$ip_address" ]; then
            jq --arg ip "$ip_address" '.settings[.settings | length] |= . + {"name": "Address", "options": [$ip], "selected": 0, "features": {"unselectable": true}}' "$minui_list_file" >"$minui_list_file.tmp"
            mv "$minui_list_file.tmp" "$minui_list_file"
        fi

        peer="$(wg_get_latest_handshake)"
        if [ -n "$peer" ]; then
            jq --arg peer "$peer" '.settings[.settings | length] |= . + {"name": "Peer", "options": [$peer], "selected": 0, "features": {"unselectable": true}}' "$minui_list_file" >"$minui_list_file.tmp"
            mv "$minui_list_file.tmp" "$minui_list_file"
        fi
    fi

    minui-list --file "$minui_list_file" --format json --title "$HUMAN_READABLE_NAME" --confirm-text "SAVE" --item-key "settings" --write-value state
}

cleanup() {
    rm -f "/tmp/${PAK_NAME}-old-settings.json"
    rm -f "/tmp/${PAK_NAME}-new-settings.json"
    rm -f "/tmp/${PAK_NAME}-settings.json"
    rm -f "/tmp/${PAK_NAME}-minui-list.json"
    rm -f "/tmp/${PAK_NAME}-resolv.conf"
    rm -f /tmp/stay_awake
    killall minui-presenter >/dev/null 2>&1 || true
}

main() {
    echo "1" >/tmp/stay_awake
    trap "cleanup" EXIT INT TERM HUP QUIT

    if [ "$PLATFORM" = "tg3040" ] && [ -z "$DEVICE" ]; then
        export DEVICE="brick"
        export PLATFORM="tg5040"
    fi

    if ! command -v minui-list >/dev/null 2>&1; then
        show_message "minui-list not found." 2
        return 1
    fi

    if ! command -v minui-presenter >/dev/null 2>&1; then
        show_message "minui-presenter not found." 2
        return 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        show_message "jq not found." 2
        return 1
    fi

    if ! command -v wireguard-go >/dev/null 2>&1; then
        show_message "wireguard-go not found." 2
        return 1
    fi

    if ! command -v wg >/dev/null 2>&1; then
        show_message "wg not found." 2
        return 1
    fi

    chmod +x "$PAK_DIR/bin/$PLATFORM/minui-list" 2>/dev/null || true
    chmod +x "$PAK_DIR/bin/$PLATFORM/minui-presenter" 2>/dev/null || true
    chmod +x "$PAK_DIR/bin/$architecture/jq" 2>/dev/null || true
    chmod +x "$PAK_DIR/bin/$architecture/wireguard-go" 2>/dev/null || true
    chmod +x "$PAK_DIR/bin/$architecture/wg" 2>/dev/null || true
    chmod +x "$PAK_DIR/bin/on-boot" 2>/dev/null || true

    allowed_platforms="tg5040"
    if ! echo "$allowed_platforms" | grep -q "$PLATFORM"; then
        show_message "$PLATFORM is not a supported platform." 2
    fi

    while true; do
        settings="$(current_settings)"
        new_settings="$(main_screen "$settings")"
        exit_code=$?
        # exit codes: 2 = back button, 3 = menu button
        if [ "$exit_code" -ne 0 ]; then
            break
        fi

        echo "$settings" >"/tmp/${PAK_NAME}-old-settings.json"
        echo "$new_settings" >"/tmp/${PAK_NAME}-new-settings.json"

        old_enabled="$(jq -rM '.settings[0].selected' "/tmp/${PAK_NAME}-old-settings.json")"
        enabled="$(jq -rM '.settings[0].selected' "/tmp/${PAK_NAME}-new-settings.json")"

        old_start_on_boot="$(jq -rM '.settings[1].selected' "/tmp/${PAK_NAME}-old-settings.json")"
        start_on_boot="$(jq -rM '.settings[1].selected' "/tmp/${PAK_NAME}-new-settings.json")"

        if [ "$old_enabled" != "$enabled" ]; then
            if [ "$enabled" = "1" ]; then
                if ! wg_is_configured && [ ! -f "$WG_CONFIG_FILE" ]; then
                    show_message "No wg0.conf found. Copy one to SD card root and try again." 3
                    continue
                fi

                show_message "Starting $HUMAN_READABLE_NAME." 2

                if ! wg_start; then
                    show_message "Failed to start $HUMAN_READABLE_NAME." 2
                    service_off
                    continue
                fi

                if ! wait_for_service 10; then
                    show_message "Failed to start $HUMAN_READABLE_NAME." 2
                    service_off
                    continue
                fi

                killall minui-presenter >/dev/null 2>&1 || true
            else
                show_message "Disabling $HUMAN_READABLE_NAME." 2
                if ! service_off; then
                    show_message "Failed to disable $HUMAN_READABLE_NAME." 2
                fi

                show_message "Waiting for $HUMAN_READABLE_NAME to stop." forever
                if ! wait_for_service_to_stop 10; then
                    show_message "Failed to stop $HUMAN_READABLE_NAME." 2
                fi
                killall minui-presenter >/dev/null 2>&1 || true
            fi
        fi

        if [ "$old_start_on_boot" != "$start_on_boot" ]; then
            if [ "$start_on_boot" = "1" ]; then
                show_message "Enabling start on boot." 2
                if ! enable_start_on_boot; then
                    show_message "Failed to enable start on boot." 2
                fi
            else
                show_message "Disabling start on boot" 2
                if ! disable_start_on_boot; then
                    show_message "Failed to disable start on boot." 2
                fi
            fi
        fi
    done
}

main "$@"
