#!/usr/bin/env bash
#
# seagate-xbig-menu.sh
#
# Editable policy/UI layer for the Seagate Business Storage Windows Server
# 4-bay NAS front panel (MSS0731 family).
#
# ARCHITECTURE
# ------------------
# This script deliberately contains no GPIO/LCD hardware implementation.
# The persistent FreePascal process `seagate-xbig-frontpanel` owns the Fintek
# GPIO lines, drives the HD44780-compatible LCD, controls the backlight and
# polls/debounces the two physical buttons.  Communication is a small line-based
# stdin/stdout protocol documented in PROTOCOL.md.
#
# This shell script remains intentionally easy to modify.  It owns only UI
# policy and Linux status collection:
#
#   idle/inactive       -> home screen, backlight level 2 (Light/dim)
#   first button press  -> level 3 (Strong/bright), wake only; stay on home
#   later short press   -> enter/navigate menu
#   hold UP 0.95 s      -> enter/select
#   hold DOWN 0.95 s    -> back
#   30 s inactivity     -> return home, level 2
#
# Screen-type marker in column 16 of line 1:
#   # = home, % = menu, * = detail
#
# Button polling is entirely in the Pascal hardware process (defaults:
# 150 ms IDLE, 10 ms ACTIVE).  The shell sleeps on the Pascal stdout pipe and
# wakes only for a button event or one of its own UI timers.
#
# Menu:
#   Network, Storage, Temperatures, Fan, Uptime, Alerts, About
#
# Run as root on the normal NAS setup after compiling the Pascal source:
#
#   fpc -O2 seagate-xbig-frontpanel.pas
#   ./seagate-xbig-menu.sh
#

MENU_VERSION=0.9
PROTOCOL_VERSION=1.0

# ---------------------------------------------------------------------------
# Locate the persistent front-panel hardware process
# ---------------------------------------------------------------------------

MENU_SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

if [[ -n ${XBIG_FRONTPANEL_BIN:-} ]]; then
    FRONTPANEL_BIN=$XBIG_FRONTPANEL_BIN
elif [[ -x $MENU_SCRIPT_DIR/seagate-xbig-frontpanel ]]; then
    FRONTPANEL_BIN=$MENU_SCRIPT_DIR/seagate-xbig-frontpanel
elif [[ -x /usr/local/sbin/seagate-xbig-frontpanel ]]; then
    FRONTPANEL_BIN=/usr/local/sbin/seagate-xbig-frontpanel
elif [[ -x /usr/local/bin/seagate-xbig-frontpanel ]]; then
    FRONTPANEL_BIN=/usr/local/bin/seagate-xbig-frontpanel
else
    printf 'ERROR: cannot find executable seagate-xbig-frontpanel\n' >&2
    printf 'Compile seagate-xbig-frontpanel.pas or set XBIG_FRONTPANEL_BIN.\n' >&2
    return 1 2>/dev/null || exit 1
fi

# ---------------------------------------------------------------------------
# User-tunable UI policy
# ---------------------------------------------------------------------------

BACKLIGHT_OFF=1
BACKLIGHT_DIM=2
BACKLIGHT_BRIGHT=3
IDLE_BACKLIGHT=$BACKLIGHT_DIM
ACTIVE_BACKLIGHT=$BACKLIGHT_BRIGHT

INACTIVITY_TIMEOUT_MS=30000
LONG_PRESS_MS=950
ACTIVE_REFRESH_SECONDS=5
IDLE_REFRESH_SECONDS=60

STORAGE_DISKS=${STORAGE_DISKS:-}
BAY_ATA_PORTS=(1 2 3 4)
OS_USM_ATA_PORT=5
ALERT_HELPER=${ALERT_HELPER:-/usr/local/libexec/seagate-xbig-alerts}

# ---------------------------------------------------------------------------
# UI state
# ---------------------------------------------------------------------------

MENU_ITEMS=(Network Storage Temperatures Fan Uptime Alerts About Reboot Poweroff)
MENU_INDEX=0
DETAIL_INDEX=0
DETAIL_LINE1=()
DETAIL_LINE2=()

UI_STATE=idle                   # idle | menu | detail
UI_ACTIVE=0                     # 0 = dim/inactive, 1 = bright/interactive
LAST_ACTIVITY_MS=0
LAST_ACTIVE_REFRESH=0
LAST_IDLE_REFRESH=0

LAST_LCD_LINE1=$'\001'
LAST_LCD_LINE2=$'\001'

PRESS_BUTTON=0                  # 0 none, 1 UP, 2 DOWN
PRESS_START_MS=0
PRESS_CONSUMED=0
PRESS_HOLD_INTERRUPTED=0
WAKE_GUARD=0                    # consume the physical press that woke the panel

PANEL_IN_FD=
PANEL_OUT_FD=
PANEL_PROCESS_PID=
PANEL_STARTED=0

# ---------------------------------------------------------------------------
# Small generic helpers
# ---------------------------------------------------------------------------

menu_log() {
    printf '%s\n' "$*" >&2
}

menu_die() {
    menu_log "ERROR: $*"
    exit 1
}

now_ms() {
    # Bash 5 provides EPOCHREALTIME.  Debian 12 uses Bash 5.x.  Keep a normal
    # date(1) fallback for portability.
    local t sec frac

    if [[ -n ${EPOCHREALTIME:-} ]]; then
        t=$EPOCHREALTIME
        sec=${t%%.*}
        frac=${t#*.}
        frac=${frac}000
        frac=${frac:0:3}
        NOW_MS=$(( 10#$sec * 1000 + 10#$frac ))
    else
        sec=$(date +%s)
        NOW_MS=$(( sec * 1000 ))
    fi
}

format_bytes_decimal() {
    # Disk vendors and Windows normally express raw disk capacity in decimal
    # SI units.  One decimal place is plenty for a 16-character LCD.
    local bytes=$1 unit suffix whole tenth

    if (( bytes >= 1000000000000 )); then
        unit=1000000000000; suffix=TB
    elif (( bytes >= 1000000000 )); then
        unit=1000000000; suffix=GB
    elif (( bytes >= 1000000 )); then
        unit=1000000; suffix=MB
    else
        printf '%d B\n' "$bytes"
        return
    fi

    whole=$(( bytes / unit ))
    tenth=$(( (bytes % unit) * 10 / unit ))
    printf '%d.%d %s\n' "$whole" "$tenth" "$suffix"
}

# ---------------------------------------------------------------------------
# Front-panel protocol helpers
# ---------------------------------------------------------------------------

panel_send() {
    (( PANEL_STARTED == 1 )) || menu_die "front-panel process is not running"
    printf '%s\n' "$1" >&"$PANEL_IN_FD" || menu_die "cannot write to front-panel process"
}

panel_line() {
    local line=$1 text=$2
    [[ $line == 0 || $line == 1 ]] || menu_die "internal LCD line must be 0 or 1"
    # Protocol text is the remainder after the line number, so leading spaces in
    # menu row 2 are preserved exactly.
    panel_send "LINE $line $text"
}

panel_backlight() {
    panel_send "BACKLIGHT $1"
}

panel_mode() {
    panel_send "MODE $1"
}

# ---------------------------------------------------------------------------
# LCD rendering
# ---------------------------------------------------------------------------

invalidate_lcd_cache() {
    LAST_LCD_LINE1=$'\001'
    LAST_LCD_LINE2=$'\001'
}

render_lines() {
    local line1=$1
    local line2=$2
    local order=${3:-top-first}

    # The Pascal hardware process handles 16-character truncation/padding and
    # character mapping, but deliberately performs every LINE command it receives.
    # This UI owns duplicate-line suppression, so only changed lines are sent.
    #
    # The Pascal/libgpiod backend is much faster than the old per-gpioset shell
    # backend, but preserving a safe row write order also avoids transient duplicate rows.  Menu scrolling therefore chooses the write order so the old and
    # new screens never temporarily show the same menu item on both LCD rows.
    if [[ $order == bottom-first ]]; then
        if [[ $line2 != "$LAST_LCD_LINE2" ]]; then
            panel_line 1 "$line2"
            LAST_LCD_LINE2=$line2
        fi
        if [[ $line1 != "$LAST_LCD_LINE1" ]]; then
            panel_line 0 "$line1"
            LAST_LCD_LINE1=$line1
        fi
    else
        if [[ $line1 != "$LAST_LCD_LINE1" ]]; then
            panel_line 0 "$line1"
            LAST_LCD_LINE1=$line1
        fi
        if [[ $line2 != "$LAST_LCD_LINE2" ]]; then
            panel_line 1 "$line2"
            LAST_LCD_LINE2=$line2
        fi
    fi
}

get_hostname_short() {
    local h
    h=$(hostname -s 2>/dev/null || hostname 2>/dev/null || true)
    printf '%s\n' "${h:-Linux NAS}"
}

get_primary_ipv4() {
    # `ip route get` only asks the kernel routing table; it does not send a
    # packet to 1.1.1.1.
    local route ipaddr

    if command -v ip >/dev/null 2>&1; then
        route=$(ip -4 route get 1.1.1.1 2>/dev/null || true)
        if [[ $route =~ [[:space:]]src[[:space:]]([^[:space:]]+) ]]; then
            printf '%s\n' "${BASH_REMATCH[1]}"
            return
        fi
    fi

    # Fallback if the route lookup did not contain a source address.
    ipaddr=$(hostname -I 2>/dev/null || true)
    ipaddr=${ipaddr%% *}
    printf '%s\n' "${ipaddr:-No network}"
}

render_idle() {
    local host ipaddr line1
    host=$(get_hostname_short)
    ipaddr=$(get_primary_ipv4)

    # Column 16 is a screen-type indicator.  Keep the visible payload to the
    # first 15 columns so the marker can never be displaced by long text.
    printf -v line1 '%-15.15s%s' "$host" '#'
    render_lines "$line1" "$ipaddr"
}

render_menu() {
    local direction=${1:-normal}
    local next count order=top-first line1
    count=${#MENU_ITEMS[@]}
    next=$(( (MENU_INDEX + 1) % count ))

    # Showing the selected entry plus the next entry makes the two-line display
    # feel like a tiny scrolling menu without needing arrows/custom glyphs.
    # The leading '>' remains the selected-item marker; column 16 '%' identifies
    # the screen itself as the menu view.
    #
    # When scrolling down, write the lower row first.  Example:
    #   old: >Network /  Storage
    #   new: >Storage /  Temperatures
    # Updating the top row first would briefly show Storage on both rows.
    # Scrolling up has the opposite safe order.
    [[ $direction == down ]] && order=bottom-first
    printf -v line1 '%-15.15s%s' ">${MENU_ITEMS[MENU_INDEX]}" '%'
    render_lines "$line1" " ${MENU_ITEMS[next]}" "$order"
}

add_detail_page() {
    DETAIL_LINE1+=("$1")
    DETAIL_LINE2+=("$2")
}

render_detail() {
    local count=${#DETAIL_LINE1[@]} line1

    if (( count == 0 )); then
        printf -v line1 '%-15.15s%s' "${MENU_ITEMS[MENU_INDEX]}" '*'
        render_lines "$line1" "No data"
        return
    fi

    (( DETAIL_INDEX < count )) || DETAIL_INDEX=$((count - 1))
    (( DETAIL_INDEX >= 0 )) || DETAIL_INDEX=0

    printf -v line1 '%-15.15s%s' "${DETAIL_LINE1[DETAIL_INDEX]}" '*'
    render_lines "$line1" "${DETAIL_LINE2[DETAIL_INDEX]}"
}

# ---------------------------------------------------------------------------
# Data collection: Network
# ---------------------------------------------------------------------------

build_network_pages() {
    DETAIL_LINE1=()
    DETAIL_LINE2=()

    local line idx ifname family cidr rest addr

    if command -v ip >/dev/null 2>&1; then
        while IFS= read -r line; do
            [[ -n $line ]] || continue
            read -r idx ifname family cidr rest <<< "$line"
            [[ $family == inet ]] || continue
            ifname=${ifname%@*}
            addr=${cidr%/*}
            add_detail_page "$ifname" "$addr"
        done < <(ip -o -4 addr show scope global 2>/dev/null || true)
    fi

    if (( ${#DETAIL_LINE1[@]} == 0 )); then
        add_detail_page "Network" "No IPv4 address"
    fi
}

# ---------------------------------------------------------------------------
# Data collection: Storage
# ---------------------------------------------------------------------------

DATA_DISKS=()
DATA_DISK_SIZES=()

collect_data_disks() {
    DATA_DISKS=()
    DATA_DISK_SIZES=()

    command -v lsblk >/dev/null 2>&1 || return 0

    local -A root_disks=()
    local root_source name type size

    # Find every physical disk underneath /.  This also works through common
    # dm/LVM/md stacks because lsblk -s walks towards the parents.
    if command -v findmnt >/dev/null 2>&1; then
        root_source=$(findmnt -n -o SOURCE / 2>/dev/null || true)
        if [[ $root_source == /dev/* ]]; then
            while read -r name type; do
                [[ $type == disk ]] && root_disks["$name"]=1
            done < <(lsblk -snrpo NAME,TYPE "$root_source" 2>/dev/null || true)
        fi
    fi

    if [[ -n $STORAGE_DISKS ]]; then
        # Explicit override is intentionally simple: whitespace-separated /dev
        # paths.  Device names do not contain spaces.
        for name in $STORAGE_DISKS; do
            [[ -b $name ]] || continue
            type=$(lsblk -dn -o TYPE "$name" 2>/dev/null || true)
            [[ $type == disk ]] || continue
            size=$(lsblk -bdn -o SIZE "$name" 2>/dev/null || true)
            [[ $size =~ ^[0-9]+$ ]] || continue
            DATA_DISKS+=("$name")
            DATA_DISK_SIZES+=("$size")
        done
        return
    fi

    while read -r name type size; do
        [[ $type == disk ]] || continue
        [[ $size =~ ^[0-9]+$ ]] || continue
        [[ -z ${root_disks[$name]+x} ]] || continue

        DATA_DISKS+=("$name")
        DATA_DISK_SIZES+=("$size")
    done < <(lsblk -bdnpo NAME,TYPE,SIZE 2>/dev/null || true)
}

build_storage_pages() {
    DETAIL_LINE1=()
    DETAIL_LINE2=()

    collect_data_disks

    local count=${#DATA_DISKS[@]}
    local total=0 size capacity

    for size in "${DATA_DISK_SIZES[@]}"; do
        total=$(( total + size ))
    done

    capacity=$(format_bytes_decimal "$total")
    add_detail_page "Disks: $count" "Capacity: $capacity"
}

# ---------------------------------------------------------------------------
# Physical bay / data-disk helpers
# ---------------------------------------------------------------------------

# Fallback presentation number if a disk cannot be resolved through by-path.
# Normal operation on this MSS0731 should resolve all four front disks by their
# stable ATA port and therefore display Bay 1..Bay 4 instead.
disk_number_for_block_name() {
    local block=$1 i

    for ((i=0; i<${#DATA_DISKS[@]}; i++)); do
        if [[ ${DATA_DISKS[i]##*/} == "$block" ]]; then
            printf '%d\n' "$((i + 1))"
            return 0
        fi
    done
    return 1
}

# Resolve a Linux block name (sda, sdb, ...) to the stable ata-N component from
# /dev/disk/by-path.  Match only the canonical ...-ata-N link, not its duplicate
# ...-ata-N.0 or partition links.
ata_port_for_block_name() {
    local block=$1 link target port

    for link in /dev/disk/by-path/*-ata-[0-9]; do
        [[ -L $link ]] || continue
        target=$(readlink -f "$link" 2>/dev/null || true)
        [[ $target == "/dev/$block" ]] || continue

        port=${link##*-ata-}
        [[ $port =~ ^[0-9]+$ ]] || continue
        printf '%s\n' "$port"
        return 0
    done
    return 1
}

bay_number_for_block_name() {
    local block=$1 port i

    port=$(ata_port_for_block_name "$block" 2>/dev/null || true)
    [[ -n $port ]] || return 1

    for ((i=0; i<${#BAY_ATA_PORTS[@]}; i++)); do
        if [[ ${BAY_ATA_PORTS[i]} == "$port" ]]; then
            printf '%d\n' "$((i + 1))"
            return 0
        fi
    done
    return 1
}

disk_label_for_block_name() {
    local block=$1 bay disk_no port

    # ata-5 is the internal/top USM SATA connector carrying the OS SSD.
    # Detect it by the stable physical ATA port rather than /dev/sdX.
    port=$(ata_port_for_block_name "$block" 2>/dev/null || true)
    if [[ -n $port && $port == "$OS_USM_ATA_PORT" ]]; then
        printf 'OS/USM\n'
        return 0
    fi

    bay=$(bay_number_for_block_name "$block" 2>/dev/null || true)
    if [[ -n $bay ]]; then
        printf 'Bay %s\n' "$bay"
        return 0
    fi

    disk_no=$(disk_number_for_block_name "$block" 2>/dev/null || true)
    if [[ -n $disk_no ]]; then
        printf 'Disk %s\n' "$disk_no"
        return 0
    fi

    printf '%s\n' "$block"
}

# A drivetemp hwmon device is normally a child of the SCSI disk device and that
# parent exposes its Linux block name below device/block/.
drivetemp_block_name() {
    local hw=$1 block

    for block in "$hw"/device/block/*; do
        [[ -e $block ]] || continue
        printf '%s\n' "${block##*/}"
        return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# hwmon compatibility helpers
# ---------------------------------------------------------------------------

# Most modern hwmon drivers expose name and sensor attributes directly below
# /sys/class/hwmon/hwmonN.  Debian 12's older f71882fg driver instead registers
# a mostly-empty hwmon class device and leaves name/fan/temp attributes below
# hwmonN/device/.  Support both layouts without special-casing a numbered hwmonN.
HWMON_CHIP_NAME=
HWMON_SENSOR_DIR=

hwmon_get_chip_name() {
    local hw=$1 name_file

    HWMON_CHIP_NAME=
    for name_file in "$hw/name" "$hw/device/name"; do
        [[ -r $name_file ]] || continue
        IFS= read -r HWMON_CHIP_NAME < "$name_file" || HWMON_CHIP_NAME=
        [[ -n $HWMON_CHIP_NAME ]] && return 0
    done
    return 1
}

hwmon_find_sensor_dir() {
    local hw=$1 pattern=$2

    HWMON_SENSOR_DIR=
    if compgen -G "$hw/$pattern" >/dev/null; then
        HWMON_SENSOR_DIR=$hw
        return 0
    fi
    if [[ -d $hw/device ]] && compgen -G "$hw/device/$pattern" >/dev/null; then
        HWMON_SENSOR_DIR=$hw/device
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Data collection: Temperatures
# ---------------------------------------------------------------------------

add_hwmon_temperature_pages() {
    local hw chip sensor_dir input stem sensor label raw temp_milli temp_c fault_file fault
    local block disk_label
    local have_drivetemp=0

    for hw in /sys/class/hwmon/hwmon*; do
        hwmon_get_chip_name "$hw" || continue
        chip=$HWMON_CHIP_NAME
        hwmon_find_sensor_dir "$hw" 'temp*_input' || continue
        sensor_dir=$HWMON_SENSOR_DIR

        # Resolve drivetemp through the stable ATA by-path.  The four front
        # links become Bay 1..4 and ata-5 becomes OS/USM.  Ignore unrelated
        # block devices rather than presenting unstable /dev/sdX labels.
        block=
        disk_label=
        if [[ $chip == drivetemp ]]; then
            block=$(drivetemp_block_name "$hw" 2>/dev/null || true)
            [[ -n $block ]] || continue
            disk_label=$(disk_label_for_block_name "$block")
            [[ $disk_label == Bay\ * || $disk_label == Disk\ * || $disk_label == OS/USM ]] || continue
            have_drivetemp=1
        fi

        for input in "$sensor_dir"/temp*_input; do
            [[ -r $input ]] || continue
            stem=${input%_input}
            sensor=${stem##*/}            # temp1, temp2, ...

            IFS= read -r raw < "$input" || continue
            [[ $raw =~ ^-?[0-9]+$ ]] || continue
            temp_milli=$raw
            temp_c=$(( temp_milli / 1000 ))

            # Skip any sensor which the hwmon driver explicitly marks faulty.
            # On this F71889ED, temp3_fault=1 and temp3_input=-128000 because
            # the third external temperature channel is not connected.
            fault_file=${stem}_fault
            if [[ -r $fault_file ]]; then
                IFS= read -r fault < "$fault_file" || fault=0
                [[ $fault == 1 ]] && continue
            fi

            # Also retain the F71889ED's -128 C sentinel guard in case a kernel
            # exposes the bogus value without a tempN_fault attribute.
            case $chip in
                f71882fg|f71889*)
                    (( temp_milli <= -127000 )) && continue
                    ;;
            esac

            if [[ $chip == drivetemp ]]; then
                label=$disk_label
            else
                label=
                if [[ -r ${stem}_label ]]; then
                    IFS= read -r label < "${stem}_label" || label=
                fi

                if [[ -z $label ]]; then
                    case $chip in
                        coretemp)
                            label="CPU ${sensor#temp}"
                            ;;
                        f71882fg|f71889*)
                            # Seagate/XBig's sensor model and the Fintek register
                            # mapping line up as temp1=CPU-area and temp2=board.
                            # These are external F71889ED channels, distinct from
                            # the CPU's internal digital coretemp sensors.
                            case ${sensor#temp} in
                                1) label="Fintek CPU" ;;
                                2) label="Fintek Board" ;;
                                *) label="Fintek ${sensor#temp}" ;;
                            esac
                            ;;
                        *)
                            label="$chip ${sensor#temp}"
                            ;;
                    esac
                fi
            fi

            add_detail_page "$label" "$temp_c C"
        done
    done

    HWMON_HAS_DRIVETEMP=$have_drivetemp
}

smartctl_disk_temperature() {
    local dev=$1
    local out rc=0 temp=

    SMART_TEMP_STATE=
    SMART_TEMP_VALUE=

    command -v smartctl >/dev/null 2>&1 || return 1

    # -n standby is important on a NAS: do NOT spin up a sleeping disk merely
    # because someone opened the LCD temperature menu.
    out=$(smartctl -n standby -A "$dev" 2>&1) || rc=$?

    if [[ $out == *STANDBY* || $out == *standby* ]]; then
        SMART_TEMP_STATE=standby
        return 0
    fi

    # Common ATA SMART format: attribute 194's raw value is normally the final
    # numeric field.  Also accept smartctl's newer generic "Temperature:" line.
    while IFS= read -r line; do
        if [[ $line =~ ^[[:space:]]*194[[:space:]]+Temperature_Celsius ]]; then
            local -a fields
            read -r -a fields <<< "$line"
            # Standard ATA SMART columns place RAW_VALUE at field 10
            # (zero-based Bash array index 9).  Extra Min/Max text may follow,
            # so deliberately do not use the final field.
            if (( ${#fields[@]} >= 10 )); then
                temp=${fields[9]}
                [[ $temp =~ ^[0-9]+$ ]] && break
                temp=
            fi
        elif [[ $line =~ ^Temperature:[[:space:]]+([0-9]+) ]]; then
            temp=${BASH_REMATCH[1]}
            break
        elif [[ $line =~ Current[[:space:]]Drive[[:space:]]Temperature:[[:space:]]+([0-9]+) ]]; then
            temp=${BASH_REMATCH[1]}
            break
        fi
    done <<< "$out"

    if [[ $temp =~ ^[0-9]+$ ]]; then
        SMART_TEMP_VALUE=$temp
        return 0
    fi

    # smartctl has many non-temperature exit-status bits; absence of a parsed
    # temperature is simply treated as "no data" rather than a fatal UI error.
    : "$rc"
    return 1
}

add_smart_disk_temperature_pages() {
    # If the kernel already exposes drivetemp through hwmon, avoid showing the
    # same physical disk temperature twice.
    (( ${HWMON_HAS_DRIVETEMP:-0} == 0 )) || return 0

    collect_data_disks

    local dev block label i
    for ((i=0; i<${#DATA_DISKS[@]}; i++)); do
        dev=${DATA_DISKS[i]}
        block=${dev##*/}
        label=$(disk_label_for_block_name "$block")
        if smartctl_disk_temperature "$dev"; then
            if [[ -n $SMART_TEMP_VALUE ]]; then
                add_detail_page "$label" "$SMART_TEMP_VALUE C"
            elif [[ $SMART_TEMP_STATE == standby ]]; then
                add_detail_page "$label" "standby"
            fi
        fi
    done
}

build_temperature_pages() {
    DETAIL_LINE1=()
    DETAIL_LINE2=()
    HWMON_HAS_DRIVETEMP=0

    collect_data_disks
    add_hwmon_temperature_pages
    add_smart_disk_temperature_pages

    if (( ${#DETAIL_LINE1[@]} == 0 )); then
        add_detail_page "Temperatures" "No sensor data"
    fi
}

# ---------------------------------------------------------------------------
# Data collection: Fan
# ---------------------------------------------------------------------------

fintek_hwmon_present() {
    local hw chip
    for hw in /sys/class/hwmon/hwmon*; do
        hwmon_get_chip_name "$hw" || continue
        chip=$HWMON_CHIP_NAME
        case $chip in
            f71882fg|f71889*) return 0 ;;
        esac
    done
    return 1
}

check_fintek_hwmon() {
    # f71882fg is configured by the system (for example via /etc/modules or
    # /etc/modules-load.d).  The menu only consumes hwmon data; it does not load
    # or unload the sensor driver itself.
    if ! fintek_hwmon_present; then
        menu_log "WARNING: F71889ED hwmon device not present; fan/board sensors unavailable"
    fi
    return 0
}

build_fan_pages() {
    DETAIL_LINE1=()
    DETAIL_LINE2=()

    local hw chip sensor_dir input stem sensor label raw

    for hw in /sys/class/hwmon/hwmon*; do
        hwmon_get_chip_name "$hw" || continue
        chip=$HWMON_CHIP_NAME
        hwmon_find_sensor_dir "$hw" 'fan*_input' || continue
        sensor_dir=$HWMON_SENSOR_DIR

        for input in "$sensor_dir"/fan*_input; do
            [[ -r $input ]] || continue
            stem=${input%_input}
            sensor=${stem##*/}
            IFS= read -r raw < "$input" || continue
            [[ $raw =~ ^[0-9]+$ ]] || continue

            label=
            if [[ -r ${stem}_label ]]; then
                IFS= read -r label < "${stem}_label" || label=
            fi

            # This MSS0731 chassis has one physical rear fan.  On its F71889ED,
            # fan1 is that tachometer; fan2/fan3 are unused and normally read 0.
            # Keep fan1 visible even at 0 RPM (useful failure information), but
            # suppress zero-valued unused Fintek channels.
            case $chip in
                f71882fg|f71889*)
                    if [[ $sensor == fan1 ]]; then
                        [[ -n $label ]] || label="Rear Fan"
                    elif (( raw == 0 )); then
                        continue
                    fi
                    ;;
            esac

            [[ -n $label ]] || label="Fan ${sensor#fan}"
            add_detail_page "$label" "$raw RPM"
        done
    done

    if (( ${#DETAIL_LINE1[@]} == 0 )); then
        if fintek_hwmon_present; then
            add_detail_page "Fan" "No tach inputs"
        else
            add_detail_page "Fan" "hwmon missing"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Data collection: Uptime
# ---------------------------------------------------------------------------

build_uptime_pages() {
    DETAIL_LINE1=()
    DETAIL_LINE2=()

    local uptime rest seconds days hours minutes text
    IFS=' ' read -r uptime rest < /proc/uptime
    seconds=${uptime%%.*}

    days=$(( seconds / 86400 ))
    hours=$(( (seconds % 86400) / 3600 ))
    minutes=$(( (seconds % 3600) / 60 ))

    if (( days > 0 )); then
        printf -v text '%dd %02dh %02dm' "$days" "$hours" "$minutes"
    else
        printf -v text '%02dh %02dm' "$hours" "$minutes"
    fi

    add_detail_page "Uptime" "$text"
}

# ---------------------------------------------------------------------------
# Data collection: Alerts
# ---------------------------------------------------------------------------

get_alerts() {
    # Intentionally small integration boundary.
    #
    # We do not guess at an OMV internal database/API here.  When an OMV alert
    # source is chosen, either replace this function or install ALERT_HELPER.
    # Each non-empty line emitted by the helper is one alert string.
    ALERT_ITEMS=()

    if [[ -x $ALERT_HELPER ]]; then
        local line
        while IFS= read -r line; do
            [[ -n $line ]] && ALERT_ITEMS+=("$line")
        done < <("$ALERT_HELPER" 2>/dev/null || true)
    fi
}

build_alert_pages() {
    DETAIL_LINE1=()
    DETAIL_LINE2=()

    local -a ALERT_ITEMS=()
    get_alerts

    local count=${#ALERT_ITEMS[@]} i
    if (( count == 0 )); then
        add_detail_page "Alerts" "No alerts"
        return
    fi

    for ((i=0; i<count; i++)); do
        add_detail_page "Alert $((i + 1))/$count" "${ALERT_ITEMS[i]}"
    done
}

# ---------------------------------------------------------------------------
# Data collection: About
# ---------------------------------------------------------------------------

build_about_pages() {
    DETAIL_LINE1=()
    DETAIL_LINE2=()

    local os_name=Linux version_id= codename=
    local line1
    local -a os_meta=()

    if [[ -r /etc/os-release ]]; then
        # Read standard OS metadata in a subshell so /etc/os-release variables do
        # not alter the menu process environment.
        mapfile -t os_meta < <(
            # shellcheck disable=SC1091
            source /etc/os-release
            printf '%s\n%s\n%s\n' \
                "${NAME:-Linux}" "${VERSION_ID:-}" "${VERSION_CODENAME:-}"
        )
        os_name=${os_meta[0]:-Linux}
        version_id=${os_meta[1]:-}
        codename=${os_meta[2]:-}
    fi

    case $os_name in
        "Debian GNU/Linux") os_name=Debian ;;
    esac

    if [[ -n $version_id ]]; then
        line1="$os_name $version_id"
    else
        line1=$os_name
    fi

    [[ -n $codename ]] || codename="No codename"
    add_detail_page "$line1" "$codename"
}

# ---------------------------------------------------------------------------
# Detail page dispatcher
# ---------------------------------------------------------------------------

build_current_detail_pages() {
    case ${MENU_ITEMS[MENU_INDEX]} in
        Network)      build_network_pages ;;
        Storage)      build_storage_pages ;;
        Temperatures) build_temperature_pages ;;
        Fan)          build_fan_pages ;;
        Uptime)       build_uptime_pages ;;
        Alerts)       build_alert_pages ;;
        About)        build_about_pages ;;
        *)
            DETAIL_LINE1=("Unknown")
            DETAIL_LINE2=("menu entry")
            ;;
    esac
}

refresh_detail() {
    local old_index=$DETAIL_INDEX
    build_current_detail_pages

    if (( ${#DETAIL_LINE1[@]} == 0 )); then
        DETAIL_INDEX=0
    elif (( old_index >= ${#DETAIL_LINE1[@]} )); then
        DETAIL_INDEX=$((${#DETAIL_LINE1[@]} - 1))
    else
        DETAIL_INDEX=$old_index
    fi

    render_detail
}

# ---------------------------------------------------------------------------
# Persistent Pascal front-panel process
# ---------------------------------------------------------------------------

start_frontpanel() {
    local hello status

    coproc PANEL { exec "$FRONTPANEL_BIN"; }
    PANEL_OUT_FD=${PANEL[0]}
    PANEL_IN_FD=${PANEL[1]}
    PANEL_PROCESS_PID=$PANEL_PID
    PANEL_STARTED=1

    if IFS= read -r -t 5 -u "$PANEL_OUT_FD" hello; then
        case $hello in
            "READY $PROTOCOL_VERSION") ;;
            ERROR\ *) menu_die "front-panel startup: ${hello#ERROR }" ;;
            *) menu_die "unexpected front-panel greeting: $hello" ;;
        esac
    else
        status=$?
        menu_die "front-panel did not become ready (read status $status)"
    fi

    # Commands are processed in order, so there is no need to wait for each OK.
    panel_send INIT
    panel_backlight "$IDLE_BACKLIGHT"
    panel_mode IDLE
}

stop_frontpanel() {
    (( PANEL_STARTED == 1 )) || return 0

    # Best effort: restore normal idle brightness before asking the child to
    # release its persistent GPIO requests.
    printf '%s\n' "BACKLIGHT $IDLE_BACKLIGHT" >&"$PANEL_IN_FD" 2>/dev/null || true
    printf '%s\n' QUIT >&"$PANEL_IN_FD" 2>/dev/null || true

    # Keep stdout open while the child handles QUIT so its final OK reply cannot
    # SIGPIPE it before the Pascal finally block restores level 2 and releases
    # the GPIO requests.  Only a couple of acknowledgement lines can be queued.
    if [[ -n ${PANEL_PROCESS_PID:-} ]]; then
        wait "$PANEL_PROCESS_PID" 2>/dev/null || true
    fi

    if [[ -n ${PANEL_IN_FD:-} ]]; then
        eval "exec ${PANEL_IN_FD}>&-" 2>/dev/null || true
    fi
    if [[ -n ${PANEL_OUT_FD:-} ]]; then
        eval "exec ${PANEL_OUT_FD}<&-" 2>/dev/null || true
    fi

    PANEL_STARTED=0
}

handle_panel_message() {
    local msg=$1

    case $msg in
        'BUTTON UP PRESS')
            button_pressed 1
            ;;
        'BUTTON DOWN PRESS')
            button_pressed 2
            ;;
        'BUTTON UP RELEASE')
            button_released 1
            ;;
        'BUTTON DOWN RELEASE')
            button_released 2
            ;;
        'BUTTON UP INTERRUPT')
            (( PRESS_BUTTON == 1 )) && PRESS_HOLD_INTERRUPTED=1
            ;;
        'BUTTON DOWN INTERRUPT')
            (( PRESS_BUTTON == 2 )) && PRESS_HOLD_INTERRUPTED=1
            ;;
        'BUTTON BOTH PRESS'|'BUTTON BOTH RELEASE'|'BUTTON BOTH INTERRUPT')
            # The hardware protocol exposes the simultaneous-button chord for
            # custom UIs.  The reference menu intentionally assigns it no action.
            ;;
        OK\ *|BUTTONS\ *)
            # Normal command acknowledgement / diagnostic reply.
            ;;
        ERROR\ *)
            menu_die "front-panel: ${msg#ERROR }"
            ;;
        READY\ *)
            # READY is consumed during startup; ignore a duplicate defensively.
            ;;
        *)
            menu_log "Ignoring unknown front-panel message: $msg"
            ;;
    esac
}

compute_wait_timeout() {
    # Sleep on the Pascal stdout pipe until the nearest UI-policy deadline.
    # There is no shell-side GPIO polling.
    local wait_ms=60000 rem now_s

    now_ms

    if (( PRESS_BUTTON == 1 || PRESS_BUTTON == 2 )); then
        if (( PRESS_CONSUMED == 0 && PRESS_HOLD_INTERRUPTED == 0 )); then
            rem=$(( PRESS_START_MS + LONG_PRESS_MS - NOW_MS ))
            (( rem < wait_ms )) && wait_ms=$rem
        fi
    fi

    if (( UI_ACTIVE == 1 )); then
        rem=$(( LAST_ACTIVITY_MS + INACTIVITY_TIMEOUT_MS - NOW_MS ))
        (( rem < wait_ms )) && wait_ms=$rem
    fi

    now_s=${EPOCHSECONDS:-$(date +%s)}
    if (( UI_ACTIVE == 1 )); then
        if [[ $UI_STATE == detail ]]; then
            rem=$(( (LAST_ACTIVE_REFRESH + ACTIVE_REFRESH_SECONDS - now_s) * 1000 ))
            (( rem < wait_ms )) && wait_ms=$rem
        fi
    else
        rem=$(( (LAST_IDLE_REFRESH + IDLE_REFRESH_SECONDS - now_s) * 1000 ))
        (( rem < wait_ms )) && wait_ms=$rem
    fi

    (( wait_ms < 1 )) && wait_ms=1
    printf '%d.%03d\n' "$((wait_ms / 1000))" "$((wait_ms % 1000))"
}

# ---------------------------------------------------------------------------
# Button/UI state machine
# ---------------------------------------------------------------------------

mark_activity() {
    now_ms
    LAST_ACTIVITY_MS=$NOW_MS
}

wake_for_interaction() {
    if (( UI_ACTIVE == 0 )); then
        UI_ACTIVE=1
        UI_STATE=idle
        PRESS_CONSUMED=1
        WAKE_GUARD=1

        # Wake only: brighten the current home screen.  Do not open the menu or
        # change its selection until a later, separate button press.
        panel_backlight "$ACTIVE_BACKLIGHT"
        panel_mode ACTIVE
        render_idle
    fi

    mark_activity
}

enter_detail() {
    UI_STATE=detail
    DETAIL_INDEX=0
    refresh_detail
    LAST_ACTIVE_REFRESH=${EPOCHSECONDS:-0}
}

leave_detail() {
    UI_STATE=menu
    render_menu
}

handle_short_press() {
    local button=$1 count

    case $UI_STATE in
        idle)
            # The first press after dimming is consumed by wake_for_interaction().
            # A later short press opens the menu at the remembered selection,
            # without also moving it on that same press.
            UI_STATE=menu
            render_menu
            ;;

        menu)
            count=${#MENU_ITEMS[@]}
            if (( button == 1 )); then
                MENU_INDEX=$(( (MENU_INDEX - 1 + count) % count ))
                render_menu up
            else
                MENU_INDEX=$(( (MENU_INDEX + 1) % count ))
                render_menu down
            fi
            ;;

        detail)
            count=${#DETAIL_LINE1[@]}
            (( count > 0 )) || return
            if (( button == 1 )); then
                DETAIL_INDEX=$(( (DETAIL_INDEX - 1 + count) % count ))
            else
                DETAIL_INDEX=$(( (DETAIL_INDEX + 1) % count ))
            fi
            render_detail
            ;;
    esac
}

handle_long_press() {
    local button=$1

    # Physical top/UP button = enter / confirm.
    # Physical bottom/DOWN button = back.
    # There is no level below a detail page, so long UP there is a no-op.
    #
    # The Poweroff/Reboot entries are the only menu items whose long-UP action
    # performs a system command instead of opening a detail page.
    if (( button == 1 )); then
        if [[ $UI_STATE == menu ]]; then
            case ${MENU_ITEMS[MENU_INDEX]} in
                Poweroff)
                    render_lines "Shutting down..." ""
                    sleep 0.2
                    poweroff
                    ;;
                Reboot)
                    render_lines "Rebooting..." ""
                    sleep 0.2
                    reboot
                    ;;
                *)
                    enter_detail
                    ;;
            esac
        fi
        return 0
    fi

    if (( button == 2 )); then
        if [[ $UI_STATE == detail ]]; then
            leave_detail
        elif [[ $UI_STATE == menu ]]; then
            UI_ACTIVE=0
            UI_STATE=idle
            panel_backlight "$IDLE_BACKLIGHT"
            panel_mode IDLE
            render_idle
            LAST_IDLE_REFRESH=${EPOCHSECONDS:-0}
        fi
    fi
}

button_pressed() {
    local button=$1

    PRESS_BUTTON=$button
    PRESS_CONSUMED=0
    PRESS_HOLD_INTERRUPTED=0
    now_ms
    PRESS_START_MS=$NOW_MS

    # Brighten immediately on the physical press.  If the display was idle,
    # this press is intentionally consumed as the Windows-like wake-up action.
    wake_for_interaction
}

button_released() {
    local button=$1 duration

    [[ $PRESS_BUTTON == "$button" ]] || {
        PRESS_BUTTON=0
        PRESS_CONSUMED=0
        return
    }

    now_ms
    duration=$(( NOW_MS - PRESS_START_MS ))
    mark_activity

    if (( PRESS_CONSUMED == 0 )); then
        # Only treat it as a long press if the raw signal stayed continuously
        # asserted. This prevents two fast taps with a very short release from
        # being merged into one accidental long press by the debounce logic.
        if (( PRESS_HOLD_INTERRUPTED == 0 && duration >= LONG_PRESS_MS )); then
            handle_long_press "$button"
        else
            handle_short_press "$button"
        fi
    fi

    PRESS_BUTTON=0
    PRESS_CONSUMED=0
    PRESS_HOLD_INTERRUPTED=0
    WAKE_GUARD=0
}

# PRESS/RELEASE/INTERRUPT are already produced by the Pascal hardware process.
# The shell deliberately keeps long-press duration and action mapping as UI policy.

# Fire a long-press action as soon as the threshold is crossed while the button
# is still held.  The release then does nothing because PRESS_CONSUMED is set.
# This makes long DOWN/UP feel like real enter/back controls instead of waiting
# for the user to release the button before anything happens.
check_held_long_press() {
    (( PRESS_BUTTON == 1 || PRESS_BUTTON == 2 )) || return 0
    (( PRESS_CONSUMED == 0 )) || return 0
    (( PRESS_HOLD_INTERRUPTED == 0 )) || return 0

    now_ms
    if (( NOW_MS - PRESS_START_MS >= LONG_PRESS_MS )); then
        PRESS_CONSUMED=1
        mark_activity
        handle_long_press "$PRESS_BUTTON"
    fi
}

check_inactivity_timeout() {
    (( UI_ACTIVE == 1 )) || return 0

    now_ms
    if (( NOW_MS - LAST_ACTIVITY_MS >= INACTIVITY_TIMEOUT_MS )); then
        UI_ACTIVE=0
        UI_STATE=idle
        PRESS_BUTTON=0
        PRESS_CONSUMED=0
        PRESS_HOLD_INTERRUPTED=0
        WAKE_GUARD=0
        panel_backlight "$IDLE_BACKLIGHT"
            panel_mode IDLE
        render_idle
        LAST_IDLE_REFRESH=${EPOCHSECONDS:-0}
    fi
}

periodic_refresh() {
    local now_s=${EPOCHSECONDS:-0}

    if (( UI_ACTIVE == 1 )); then
        if [[ $UI_STATE == detail ]] && \
           (( now_s - LAST_ACTIVE_REFRESH >= ACTIVE_REFRESH_SECONDS )); then
            refresh_detail
            LAST_ACTIVE_REFRESH=$now_s
        fi
    else
        if (( now_s - LAST_IDLE_REFRESH >= IDLE_REFRESH_SECONDS )); then
            render_idle
            LAST_IDLE_REFRESH=$now_s
        fi
    fi
}

# ---------------------------------------------------------------------------
# Startup / shutdown
# ---------------------------------------------------------------------------

menu_usage() {
    cat <<EOF_USAGE
Usage: ${BASH_SOURCE[0]##*/} [--help]

Seagate MSS0731 front-panel menu ($MENU_VERSION).

Environment overrides:
  XBIG_FRONTPANEL_BIN   path to compiled seagate-xbig-frontpanel
  STORAGE_DISKS         optional whitespace-separated data-disk list
  ALERT_HELPER          optional executable; one alert per output line

The hardware protocol is documented in PROTOCOL.md.
EOF_USAGE
}

menu_cleanup() {
    stop_frontpanel
}

menu_main() {
    local msg timeout status

    if (( $# > 0 )); then
        case $1 in
            -h|--help|help)
                menu_usage
                return 0
                ;;
            *)
                menu_usage >&2
                menu_die "unknown argument: $1"
                ;;
        esac
    fi

    check_fintek_hwmon
    start_frontpanel

    invalidate_lcd_cache
    render_idle
    LAST_IDLE_REFRESH=${EPOCHSECONDS:-0}

    now_ms
    LAST_ACTIVITY_MS=$NOW_MS

    menu_log "Seagate XBig menu $MENU_VERSION using $FRONTPANEL_BIN"
    menu_log "Controls: short UP/DOWN=navigate, hold UP 0.95s=enter, hold DOWN 0.95s=back"
    menu_log "Pascal button polling: IDLE 150 ms, ACTIVE 10 ms"

    while :; do
        # Service policy timers before sleeping so an expired deadline never
        # turns into a zero-time busy loop.
        check_held_long_press
        check_inactivity_timeout
        periodic_refresh

        timeout=$(compute_wait_timeout)
        if IFS= read -r -t "$timeout" -u "$PANEL_OUT_FD" msg; then
            handle_panel_message "$msg"
        else
            status=$?
            # Bash read returns >128 for timeout.  Any ordinary EOF/failure while
            # the child is gone is fatal; otherwise just service timers again.
            if (( status <= 128 )); then
                if ! kill -0 "$PANEL_PROCESS_PID" 2>/dev/null; then
                    menu_die "front-panel process exited unexpectedly"
                fi
            fi
        fi
    done
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    set -euo pipefail
    export LC_ALL=C

    trap 'exit 0' INT TERM
    trap menu_cleanup EXIT

    menu_main "$@"
fi
