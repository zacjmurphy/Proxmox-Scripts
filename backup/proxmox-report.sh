#!/usr/bin/env bash

#
#  _____  _____  _____  __ __
# |__   //  _  \/     \/  |  \
#  /  _/ |  _  ||  |--||  _  |
# /_____|\__|__/\_____/\__|__/
#

# Proxmox owner report and structural snapshot

set -uo pipefail
umask 077

SCRIPT_VERSION='5.1.1'
FRAME='+------------------------------------------------------------------------------+'
CONFIG_FILE="${CONFIG_FILE:-/etc/proxmox-report.conf}"
SOURCE_ROOT="${SOURCE_ROOT:-/}"
START_EPOCH="$(date +%s)"
HOST="$(hostname -s)"
TIMESTAMP="$(date '+%Y-%m-%d_%H-%M')"
STARTED_AT="$(date '+%Y-%m-%d %H:%M:%S %Z')"
WORK_DIR=''
SNAPSHOT_DIR=''
DISCORD_RESPONSE=''
DISCORD_STATUS='Not Configured'
ARCHIVE_STATUS='Not Built'
ARCHIVE_SIZE='N/A'
VERBOSE=0
QUIET=0
PROGRESS_INTERVAL="${PROGRESS_INTERVAL:-5}"
CHAPTER_TOTAL=7
CURRENT_PHASE=''
CURRENT_PHASE_START=0
declare -a PHASE_NAMES=()
declare -a PHASE_SECONDS=()
LIVE_STATUS_ACTIVE=0
MEDIA_WALK_SECONDS=0
MEDIA_SORT_SECONDS=0

usage() {
    cat <<'EOF'
Usage: proxmox-report.sh [options]

  -v, --verbose    Show additional stage details
  -q, --quiet      Show warnings and the final summary only
      --no-color   Disable terminal colours
  -h, --help       Show this help
EOF
}

while (( $# > 0 )); do
    case "$1" in
        -v|--verbose) VERBOSE=1 ;;
        -q|--quiet) QUIET=1 ;;
        --no-color) NO_COLOR=1 ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'Unknown Option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

if (( VERBOSE && QUIET )); then
    printf '%s\n' '--verbose and --quiet cannot be used together.' >&2
    exit 2
fi

# Preserve environment overrides before loading the config file.
CONFIG_KEYS=(
    MEDIA_DIR REPORT_DIR SCAN_TMP_BASE SORT_BUFFER DISCORD_WEBHOOK
    DISCORD_FILE_LIMIT_BYTES JOURNAL_LINES RETENTION_DAYS PROGRESS_INTERVAL
    INCLUDE_PVE_PRIV INCLUDE_ROOT_SSH INCLUDE_SSH_HOST_KEYS INCLUDE_API_TOKENS
    INCLUDE_PASSWORD_FILES INCLUDE_CLOUD_INIT_SECRETS INCLUDE_PRIVATE_KEYS
)
declare -A ENV_OVERRIDES=()
for key in "${CONFIG_KEYS[@]}"; do
    if [[ ${!key+x} ]]; then
        ENV_OVERRIDES["$key"]="${!key}"
    fi
done

# Terminal output.
if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-}" != 'dumb' ]]; then
    C_GREEN=$'\033[0;32m'
    C_YELLOW=$'\033[1;33m'
    C_RED=$'\033[0;31m'
    C_CYAN=$'\033[0;36m'
    C_DIM=$'\033[2m'
    C_RESET=$'\033[0m'
else
    C_GREEN=''
    C_YELLOW=''
    C_RED=''
    C_CYAN=''
    C_DIM=''
    C_RESET=''
fi

panel_row() {
    printf '| %-76.76s |\n' "$*"
}

panel_header() {
    printf '%s\n' "$FRAME"
    printf '| %b%-76.76s%b |\n' "$C_CYAN" "$1" "$C_RESET"
    printf '%s\n' "$FRAME"
}

clear_live_status() {
    (( LIVE_STATUS_ACTIVE )) || return 0
    printf '\r%-79s\r' ''
    LIVE_STATUS_ACTIVE=0
}

status_style() {
    case "$1" in
        work) printf '%s\t%s' '....' "$C_DIM" ;;
        scan) printf '%s\t%s' 'SCAN' "$C_CYAN" ;;
        wait) printf '%s\t%s' 'WAIT' "$C_YELLOW" ;;
        ok)   printf '%s\t%s' ' OK ' "$C_GREEN" ;;
        warn) printf '%s\t%s' 'WARN' "$C_YELLOW" ;;
        fail) printf '%s\t%s' 'FAIL' "$C_RED" ;;
        *)    printf '%s\t%s' '----' '' ;;
    esac
}

status_line() {
    local state="$1"
    shift
    local styled tag colour

    if (( QUIET )) && [[ "$state" != 'warn' && "$state" != 'fail' ]]; then
        return
    fi

    clear_live_status
    styled="$(status_style "$state")"
    tag="${styled%%$'\t'*}"
    colour="${styled#*$'\t'}"

    printf '[%s] %b[%s]%b %s\n' "$(date '+%H:%M:%S')" "$colour" "$tag" "$C_RESET" "$*"
}

progress_line() {
    local state="$1"
    shift
    local styled tag colour message

    (( QUIET )) && return 0

    if [[ -t 1 && "$VERBOSE" -eq 0 ]]; then
        styled="$(status_style "$state")"
        tag="${styled%%$'\t'*}"
        colour="${styled#*$'\t'}"
        message="$*"
        printf '\r[%s] %b[%s]%b %-61.61s' \
            "$(date '+%H:%M:%S')" "$colour" "$tag" "$C_RESET" "$message"
        LIVE_STATUS_ACTIVE=1
    else
        status_line "$state" "$@"
    fi
}

verbose_line() {
    (( VERBOSE )) || return 0
    clear_live_status
    printf '[%s] %b[VERB]%b %s\n' "$(date '+%H:%M:%S')" "$C_DIM" "$C_RESET" "$*"
}

finish_phase() {
    local now elapsed

    [[ -n "$CURRENT_PHASE" ]] || return 0
    now="$(date +%s)"
    elapsed=$((now - CURRENT_PHASE_START))
    PHASE_NAMES+=("$CURRENT_PHASE")
    PHASE_SECONDS+=("$elapsed")
    CURRENT_PHASE=''
}

chapter() {
    local number="$1"
    local title="$2"
    local width=40
    local percent filled empty bar_fill bar_empty
    local label prefix dash_count dashes

    finish_phase
    CURRENT_PHASE="$title"
    CURRENT_PHASE_START="$(date +%s)"

    (( QUIET )) && return 0

    clear_live_status
    percent=$((number * 100 / CHAPTER_TOTAL))
    filled=$((number * width / CHAPTER_TOTAL))
    empty=$((width - filled))

    printf -v bar_fill '%*s' "$filled" ''
    printf -v bar_empty '%*s' "$empty" ''
    bar_fill="${bar_fill// /#}"
    bar_empty="${bar_empty// /.}"

    label="$(printf '%02d/%02d %s' "$number" "$CHAPTER_TOTAL" "${title^^}")"
    prefix="+--[ ${label} ]"
    dash_count=$((79 - ${#prefix}))
    (( dash_count < 1 )) && dash_count=1
    printf -v dashes '%*s' "$dash_count" ''
    dashes="${dashes// /-}"

    printf '\n+--[ %b%s%b ]%s+\n' "$C_CYAN" "$label" "$C_RESET" "$dashes"
    panel_row "$(printf 'Run Progress  [%s%s] %3d%%' "$bar_fill" "$bar_empty" "$percent")"
    printf '%s\n' "$FRAME"
}

scan_heartbeat() {
    local done_file="$1"
    local progress_file="$2"
    local started="$3"
    local entries=0 files=0 dirs=0 elapsed rate
    local last_entries=-1

    while [[ ! -e "$done_file" ]]; do
        sleep "$PROGRESS_INTERVAL"
        [[ -e "$done_file" ]] && break

        elapsed=$(( $(date +%s) - started ))
        if [[ -s "$progress_file" ]]; then
            read -r entries files dirs < "$progress_file" || true
            rate=0
            (( elapsed > 0 )) && rate=$((entries / elapsed))
            if (( entries > last_entries )); then
                progress_line scan "${entries} entries | ${rate}/s | ${files} files | ${dirs} dirs | $(format_duration "$elapsed")"
            else
                progress_line wait "No new entries | ${entries} seen | $(format_duration "$elapsed")"
            fi
            last_entries="$entries"
        else
            progress_line wait "Waiting for filesystem I/O | $(format_duration "$elapsed")"
        fi
    done
}

elapsed_heartbeat() {
    local done_file="$1"
    local label="$2"
    local started="$3"
    local elapsed

    while [[ ! -e "$done_file" ]]; do
        sleep "$PROGRESS_INTERVAL"
        [[ -e "$done_file" ]] && break
        elapsed=$(( $(date +%s) - started ))
        status_line work "${label}: $(format_duration "$elapsed") elapsed"
    done
}

warn() {
    clear_live_status
    printf '[%s] %b[WARN]%b %s\n' "$(date '+%H:%M:%S')" "$C_YELLOW" "$C_RESET" "$*" >&2
}

fatal() {
    clear_live_status
    printf '[%s] %b[FAIL]%b %s\n' "$(date '+%H:%M:%S')" "$C_RED" "$C_RESET" "$*" >&2
    exit 1
}

section() {
    echo
    echo '----------------------------------------------------------------------'
    echo "$*"
    echo '----------------------------------------------------------------------'
}

run_cmd() {
    echo
    printf '+ '
    printf '%q ' "$@"
    echo
    "$@" 2>&1 || true
}

format_duration() {
    local seconds="$1"
    local minutes=$((seconds / 60))
    local remain=$((seconds % 60))

    if (( minutes > 0 )); then
        printf '%dm %02ds' "$minutes" "$remain"
    else
        printf '%ds' "$remain"
    fi
}

source_path() {
    printf '%s%s' "${SOURCE_ROOT%/}" "$1"
}

copy_host_file() {
    local source="$1"
    local target="$2"
    local path
    path="$(source_path "$source")"

    [[ -f "$path" ]] || return 0
    mkdir -p -- "$(dirname "$target")"
    cp -aL -- "$path" "$target"
}

copy_host_tree() {
    local source="$1"
    local target="$2"
    local path
    path="$(source_path "$source")"

    [[ -d "$path" ]] || return 0
    mkdir -p -- "$target"
    cp -aL -- "$path"/. "$target"/
}

capture_cmd() {
    local target="$1"
    shift
    mkdir -p -- "$(dirname "$target")"
    "$@" > "$target" 2>&1 || true
}

print_vm_config() {
    local vmid="$1"

    if [[ "$INCLUDE_CLOUD_INIT_SECRETS" == '1' ]]; then
        qm config "$vmid" 2>&1 || true
    else
        qm config "$vmid" 2>&1 |
            sed -E 's/^(cipassword:).*/\1 [redacted]/I' || true
    fi
}

cleanup() {
    [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]] && rm -rf -- "$WORK_DIR"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

# Root is required for host configuration and SMART data.
if [[ "$EUID" -ne 0 ]]; then
    fatal 'This script must be ran as root...'
fi

# Load root-owned configuration.
if [[ -f "$CONFIG_FILE" ]]; then
    config_owner="$(stat -c '%u' "$CONFIG_FILE" 2>/dev/null || echo -1)"
    config_mode="$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null || echo 777)"
    if [[ "$config_owner" != '0' || ! "$config_mode" =~ ^[4567]00$ ]]; then
        fatal "Config file must be root-owned and root-only: $CONFIG_FILE"
    fi
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

# Restore explicit environment values.
for key in "${!ENV_OVERRIDES[@]}"; do
    printf -v "$key" '%s' "${ENV_OVERRIDES[$key]}"
done

MEDIA_DIR="${MEDIA_DIR:-}"
REPORT_DIR="${REPORT_DIR:-/var/backups/proxmox-reports}"
SCAN_TMP_BASE="${SCAN_TMP_BASE:-$REPORT_DIR}"
SORT_BUFFER="${SORT_BUFFER:-512M}"
DISCORD_WEBHOOK="${DISCORD_WEBHOOK:-}"
DISCORD_FILE_LIMIT_BYTES="${DISCORD_FILE_LIMIT_BYTES:-$((19 * 1024 * 1024))}"
JOURNAL_LINES="${JOURNAL_LINES:-300}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"
PROGRESS_INTERVAL="${PROGRESS_INTERVAL:-5}"

INCLUDE_PVE_PRIV="${INCLUDE_PVE_PRIV:-0}"
INCLUDE_ROOT_SSH="${INCLUDE_ROOT_SSH:-0}"
INCLUDE_SSH_HOST_KEYS="${INCLUDE_SSH_HOST_KEYS:-0}"
INCLUDE_API_TOKENS="${INCLUDE_API_TOKENS:-0}"
INCLUDE_PASSWORD_FILES="${INCLUDE_PASSWORD_FILES:-0}"
INCLUDE_CLOUD_INIT_SECRETS="${INCLUDE_CLOUD_INIT_SECRETS:-0}"
INCLUDE_PRIVATE_KEYS="${INCLUDE_PRIVATE_KEYS:-0}"

for flag in \
    INCLUDE_PVE_PRIV INCLUDE_ROOT_SSH INCLUDE_SSH_HOST_KEYS INCLUDE_API_TOKENS \
    INCLUDE_PASSWORD_FILES INCLUDE_CLOUD_INIT_SECRETS INCLUDE_PRIVATE_KEYS
do
    [[ "${!flag}" == '0' || "${!flag}" == '1' ]] || fatal "$flag must be 0 or 1."
done
[[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] || fatal 'RETENTION_DAYS must be a non-negative integer.'
[[ "$JOURNAL_LINES" =~ ^[0-9]+$ ]] || fatal 'JOURNAL_LINES must be a non-negative integer.'
[[ "$DISCORD_FILE_LIMIT_BYTES" =~ ^[0-9]+$ ]] || fatal 'DISCORD_FILE_LIMIT_BYTES must be a non-negative integer.'
[[ "$PROGRESS_INTERVAL" =~ ^[1-9][0-9]*$ ]] || fatal 'PROGRESS_INTERVAL must be a positive integer.'

# First-run setup.
if [[ -z "$MEDIA_DIR" || -z "$DISCORD_WEBHOOK" ]]; then
    if [[ ! -t 0 ]]; then
        fatal "First run needs setup. Run interactively once or set MEDIA_DIR and DISCORD_WEBHOOK."
    fi

    panel_header 'FIRST RUN SETUP'

    if [[ -z "$MEDIA_DIR" ]]; then
        read -r -p 'Media directory [/mnt/hdd6]: ' setup_media
        MEDIA_DIR="${setup_media:-/mnt/hdd6}"
    fi

    if [[ -z "$DISCORD_WEBHOOK" ]]; then
        read -r -s -p 'Discord webhook: ' DISCORD_WEBHOOK
        echo
        [[ -n "$DISCORD_WEBHOOK" ]] || fatal 'Discord Webhook Cannot be Empty...'
    fi

    mkdir -p -- "$(dirname "$CONFIG_FILE")"
    {
        echo '# Proxmox Report Configuration.'
        printf 'MEDIA_DIR=%q\n' "$MEDIA_DIR"
        printf 'REPORT_DIR=%q\n' "$REPORT_DIR"
        printf 'DISCORD_WEBHOOK=%q\n' "$DISCORD_WEBHOOK"
        printf 'RETENTION_DAYS=%q\n' "$RETENTION_DAYS"
        printf 'PROGRESS_INTERVAL=%q\n' "$PROGRESS_INTERVAL"
        echo
        echo '# Sensitive Snapshot Options. Disabled by Default.'
        echo 'INCLUDE_PVE_PRIV=0'
        echo 'INCLUDE_ROOT_SSH=0'
        echo 'INCLUDE_SSH_HOST_KEYS=0'
        echo 'INCLUDE_API_TOKENS=0'
        echo 'INCLUDE_PASSWORD_FILES=0'
        echo 'INCLUDE_CLOUD_INIT_SECRETS=0'
        echo 'INCLUDE_PRIVATE_KEYS=0'
    } > "$CONFIG_FILE" || fatal "Cannot Write Config File: $CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    status_line ok "Configuration Saved to $CONFIG_FILE"
fi

if (( ! QUIET )); then
    panel_header 'PROXMOX OWNER REPORT'
    panel_row "Version    $SCRIPT_VERSION"
    panel_row "Host       $HOST"
    panel_row "Started    $STARTED_AT"
    panel_row "Media      $MEDIA_DIR"
    panel_row "Reports    $REPORT_DIR"
    if (( VERBOSE )); then
        panel_row 'Mode       verbose'
    else
        panel_row 'Mode       standard'
    fi
    printf '%s\n' "$FRAME"
fi

chapter 1 'Pre-Flight Checklist'

mkdir -p -- "$REPORT_DIR" || fatal "Cannot Create Report Directory: $REPORT_DIR"

required_commands=(
    awk cp curl date df du find findmnt free head hostname ip journalctl lscpu lsblk
    mktemp numfmt pct pvesh pvesm pveversion python3 qm sed sort stat systemctl tr uptime wc
)
missing_commands=()
for command_name in "${required_commands[@]}"; do
    command -v "$command_name" >/dev/null 2>&1 || missing_commands+=("$command_name")
done
if (( ${#missing_commands[@]} > 0 )); then
    fatal "Missing Required Commands: ${missing_commands[*]}"
fi

# mawk buffers pipe input unless interactive mode is enabled.
AWK_STREAM=(awk)
AWK_VERSION="$(awk -W version 2>&1 | sed -n '1p' || true)"
if [[ "$AWK_VERSION" == mawk* ]]; then
    AWK_STREAM=(awk -W interactive)
fi

if [[ ! -d "$MEDIA_DIR" ]]; then
    warn "Media Directory Not Found: $MEDIA_DIR"
fi

WORK_DIR="$(mktemp -d "${SCAN_TMP_BASE%/}/.proxmox-report.XXXXXX" 2>/dev/null)" || {
    warn "Cannot create work directory under $SCAN_TMP_BASE; using /tmp."
    mktemp -d /tmp/.proxmox-report.XXXXXX
}
[[ -d "$WORK_DIR" ]] || fatal 'Cannot Create Work Directory...'
DISCORD_RESPONSE="${WORK_DIR}/discord-response.txt"
SNAPSHOT_DIR="${WORK_DIR}/snapshot"

# Avoid same-minute overwrites.
RUN_STAMP="$TIMESTAMP"
RUN_INDEX=2
while :; do
    REPORT_FILE="${REPORT_DIR}/proxmox-report-${HOST}-${RUN_STAMP}.txt"
    MEDIA_REPORT="${REPORT_DIR}/media-inventory-${HOST}-${RUN_STAMP}.txt"
    SNAPSHOT_ARCHIVE="${REPORT_DIR}/proxmox-snapshot-${HOST}-${RUN_STAMP}.zip"

    if [[ ! -e "$REPORT_FILE" && ! -e "$MEDIA_REPORT" && ! -e "$SNAPSHOT_ARCHIVE" ]]; then
        break
    fi

    RUN_STAMP="${TIMESTAMP}-$(printf '%02d' "$RUN_INDEX")"
    ((RUN_INDEX++))
done

status_line ok 'Pre-flight Checks Complete...'
verbose_line "Work Directory: $WORK_DIR"
verbose_line "Sort Buffer: $SORT_BUFFER"
verbose_line "Progress Interval: ${PROGRESS_INTERVAL}s"

chapter 2 'Node Overview'
status_line work 'Collecting Node Summary...'

ROOT_USAGE="$(df -h / 2>/dev/null | awk 'NR==2 {print $5 " used (" $3 " / " $2 ")"}')"
[[ -n "$ROOT_USAGE" ]] || ROOT_USAGE='N/A'

MEMORY_USAGE="$(free -h 2>/dev/null | awk '/^Mem:/ {print $3 " / " $2}')"
[[ -n "$MEMORY_USAGE" ]] || MEMORY_USAGE='N/A'

SWAP_USAGE="$(free -h 2>/dev/null | awk '/^Swap:/ {print $3 " / " $2}')"
[[ -n "$SWAP_USAGE" ]] || SWAP_USAGE='N/A'

UPTIME="$(uptime -p 2>/dev/null || true)"
[[ -n "$UPTIME" ]] || UPTIME='N/A'

LOAD_AVG="$(awk '{print $1 " / " $2 " / " $3}' /proc/loadavg 2>/dev/null || true)"
[[ -n "$LOAD_AVG" ]] || LOAD_AVG='N/A'

FAILED_SERVICES="$(systemctl --failed --no-legend --no-pager 2>/dev/null | awk 'NF {count++} END {print count+0}')"
ERROR_COUNT="$(journalctl -p err --since '24 hours ago' --no-pager 2>/dev/null | awk '!/^--/ && NF {count++} END {print count+0}')"

VM_LIST="$(qm list 2>/dev/null || true)"
VM_COUNT="$(printf '%s\n' "$VM_LIST" | awk 'NR>1 && NF {count++} END {print count+0}')"
VM_RUNNING="$(printf '%s\n' "$VM_LIST" | awk 'NR>1 && tolower($3)=="running" {count++} END {print count+0}')"

LXC_LIST="$(pct list 2>/dev/null || true)"
LXC_COUNT="$(printf '%s\n' "$LXC_LIST" | awk 'NR>1 && NF {count++} END {print count+0}')"
LXC_RUNNING="$(printf '%s\n' "$LXC_LIST" | awk 'NR>1 && tolower($2)=="running" {count++} END {print count+0}')"

STORAGE_TABLE="$(pvesm status 2>/dev/null || true)"
STORAGE_STATUS="$(printf '%s\n' "$STORAGE_TABLE" | awk 'NR>1 && NF {printf "%s=%s ", $1, $NF}')"
STORAGE_STATUS="${STORAGE_STATUS% }"
[[ -n "$STORAGE_STATUS" ]] || STORAGE_STATUS='N/A'

ZFS_STATUS='N/A'
if command -v zpool >/dev/null 2>&1; then
    ZFS_STATUS="$(zpool list -H -o name,health 2>/dev/null | awk 'NF {printf "%s=%s ", $1, $2}')"
    ZFS_STATUS="${ZFS_STATUS% }"
    [[ -n "$ZFS_STATUS" ]] || ZFS_STATUS='No pools'
fi

CLUSTER_STATUS='Standalone'
if command -v pvecm >/dev/null 2>&1; then
    cluster_output="$(pvecm status 2>/dev/null || true)"
    cluster_name="$(printf '%s\n' "$cluster_output" | awk -F: 'tolower($1) ~ /^[[:space:]]*name$/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}')"
    [[ -n "$cluster_name" ]] && CLUSTER_STATUS="$cluster_name"
fi

status_line ok 'Node Summary Collected...'
chapter 3 'Media Inventory'
status_line work 'Scanning Media Inventory...'
verbose_line "Media Root: $MEDIA_DIR"

TOTAL_MEDIA_SIZE='N/A'
TOTAL_MEDIA_FILES=0
TOTAL_MEDIA_DIRS=0

DIRS_RAW="${WORK_DIR}/dirs.raw"
FILES_RAW="${WORK_DIR}/files.raw"
META_RAW="${WORK_DIR}/meta.raw"
EXT_RAW="${WORK_DIR}/ext.raw"
COUNTS_RAW="${WORK_DIR}/counts.raw"
ALLOC_TOTAL="${WORK_DIR}/alloc.total"
ALLOC_TOP="${WORK_DIR}/alloc.top"

DIRS_SORTED="${WORK_DIR}/dirs.sorted"
FILES_SORTED="${WORK_DIR}/files.sorted"
META_SORTED="${WORK_DIR}/meta.sorted"
EXT_SORTED="${WORK_DIR}/ext.sorted"
TOP_SORTED="${WORK_DIR}/top.sorted"

touch "$DIRS_RAW" "$FILES_RAW" "$META_RAW" "$EXT_RAW" "$COUNTS_RAW" \
    "$ALLOC_TOTAL" "$ALLOC_TOP" "$DIRS_SORTED" "$FILES_SORTED" "$META_SORTED" \
    "$EXT_SORTED" "$TOP_SORTED"

if [[ -d "$MEDIA_DIR" ]]; then
    SCAN_PROGRESS="${WORK_DIR}/scan.progress"
    SCAN_DONE="${WORK_DIR}/scan.done"
    : > "$SCAN_PROGRESS"
    SCAN_STARTED="$(date +%s)"

    MEDIA_SCAN_ROOT="${MEDIA_DIR%/}"
    [[ -n "$MEDIA_SCAN_ROOT" ]] || MEDIA_SCAN_ROOT='/'

    verbose_line 'Starting Single-pass metadata and allocation walk...'
    (
        set -o pipefail
        # Prune excluded media paths before metadata collection.
        find "$MEDIA_SCAN_ROOT" -regextype posix-extended \
            \( -iname '*.trickplay' -prune \) -o \
            \( -type d \( \
                -iname 'Downloads' -o \
                -iname 'Incomplete' -o \
                -iname 'Pre-Rolls' -o \
                -iname 'Home Photos' -o \
                -iname 'System Volume Information' \
            \) -prune \) -o \
            \( -type f \( \
                -iname '*.nfo' -o \
                -iname 'backdrop.jpg' -o \
                -iname 'banner.jpg' -o \
                -iname 'folder.jpg' -o \
                -iname 'landscape.jpg' -o \
                -iname 'logo.png' -o \
                -iregex '.*/season[0-9]+-poster[.]jpg' \
            \) -prune \) -o \
            -printf '%y\001%TY-%Tm-%Td %TH:%TM:%TS\001%s\001%b\001%D\001%i\001%n\001%p\n' \
            2>/dev/null |
            "${AWK_STREAM[@]}" \
                -F '\001' \
                -v root="$MEDIA_SCAN_ROOT" \
                -v dirsf="$DIRS_RAW" \
                -v filesf="$FILES_RAW" \
                -v metaf="$META_RAW" \
                -v extf="$EXT_RAW" \
                -v countsf="$COUNTS_RAW" \
                -v totalf="$ALLOC_TOTAL" \
                -v topf="$ALLOC_TOP" \
                -v progressf="$SCAN_PROGRESS" '
            function add_alloc(path, type, blocks, dev, ino, links, key, rel, slash, top, bytes) {
                # Hard-link aware allocated-size accounting.
                if (type != "d" && links > 1) {
                    key = dev ":" ino
                    if (seen_inode[key]++)
                        return
                }

                bytes = blocks * 512
                total_alloc += bytes

                if (path == root)
                    return

                if (root == "/")
                    rel = substr(path, 2)
                else if (substr(path, 1, length(root) + 1) == root "/")
                    rel = substr(path, length(root) + 2)
                else
                    return

                slash = index(rel, "/")
                top = slash ? substr(rel, 1, slash - 1) : rel
                if (top != "")
                    top_alloc[top] += bytes
            }

            {
                type = $1
                mtime = $2
                size = $3 + 0
                blocks = $4 + 0
                dev = $5
                ino = $6
                links = $7 + 0
                path = $8

                add_alloc(path, type, blocks, dev, ino, links)

                if (type == "d") {
                    print path > dirsf
                    nd++
                } else if (type == "f") {
                    nf++
                    print path > filesf
                    printf "%s | %12d bytes | %s\n", mtime, size, path > metaf

                    base = path
                    sub(/^.*\//, "", base)
                    n = split(base, parts, ".")
                    if (n > 1)
                        ext = tolower(parts[n])
                    else
                        ext = "[no extension]"
                    ext_count[ext]++
                }

                entries = nf + nd
                now = systime()
                if (entries == 1 || now != last_progress) {
                    printf "%d %d %d\n", entries, nf + 0, nd + 0 > progressf
                    close(progressf)
                    last_progress = now
                }
            }
            END {
                for (e in ext_count)
                    printf "%7d %s\n", ext_count[e], e > extf

                printf "%d %d\n", nf + 0, nd + 0 > countsf
                printf "%.0f\t%s\n", total_alloc + 0, root > totalf

                for (top in top_alloc) {
                    if (substr(top, 1, 1) == ".")
                        continue

                    if (root == "/")
                        path = "/" top
                    else
                        path = root "/" top

                    printf "%.0f\t%s\n", top_alloc[top], path > topf
                }

                printf "%d %d %d\n", nf + nd, nf + 0, nd + 0 > progressf
                close(progressf)
            }'
    ) &
    scan_pid=$!
    scan_heartbeat "$SCAN_DONE" "$SCAN_PROGRESS" "$SCAN_STARTED" &
    scan_heartbeat_pid=$!

    scan_failed=0
    wait "$scan_pid" || scan_failed=1
    touch "$SCAN_DONE"
    kill "$scan_heartbeat_pid" 2>/dev/null || true
    wait "$scan_heartbeat_pid" 2>/dev/null || true
    MEDIA_WALK_SECONDS=$(( $(date +%s) - SCAN_STARTED ))
    (( scan_failed == 0 )) || warn 'Media Metadata Scan Reported An Error...'

    if [[ -s "$COUNTS_RAW" ]]; then
        read -r TOTAL_MEDIA_FILES TOTAL_MEDIA_DIRS < "$COUNTS_RAW"
    fi
    status_line ok "Single Media Walk Complete: $((TOTAL_MEDIA_FILES + TOTAL_MEDIA_DIRS)) entries in $(format_duration "$MEDIA_WALK_SECONDS")"

    PROCESS_DONE="${WORK_DIR}/processing.done"
    PROCESS_STARTED="$(date +%s)"
    status_line work 'Sorting Cached Indexes...'
    verbose_line 'Starting directory sort'
    LC_ALL=C sort -S "$SORT_BUFFER" -T "$WORK_DIR" -o "$DIRS_SORTED" "$DIRS_RAW" &
    pid_dirs=$!
    verbose_line 'Starting File Sort...'
    LC_ALL=C sort -S "$SORT_BUFFER" -T "$WORK_DIR" -o "$FILES_SORTED" "$FILES_RAW" &
    pid_files=$!
    verbose_line 'Starting Metadata Sort...'
    LC_ALL=C sort -S "$SORT_BUFFER" -T "$WORK_DIR" -o "$META_SORTED" "$META_RAW" &
    pid_meta=$!

    elapsed_heartbeat "$PROCESS_DONE" 'Index sorting' "$PROCESS_STARTED" &
    process_heartbeat_pid=$!

    wait "$pid_dirs" || warn 'Directory Sort Failed...'
    wait "$pid_files" || warn 'File Sort Failed...'
    wait "$pid_meta" || warn 'Metadata Sort Failed...'
    touch "$PROCESS_DONE"
    kill "$process_heartbeat_pid" 2>/dev/null || true
    wait "$process_heartbeat_pid" 2>/dev/null || true
    MEDIA_SORT_SECONDS=$(( $(date +%s) - PROCESS_STARTED ))

    [[ -s "$EXT_RAW" ]] && LC_ALL=C sort -nr "$EXT_RAW" > "$EXT_SORTED"

    if [[ -s "$ALLOC_TOTAL" ]]; then
        TOTAL_MEDIA_SIZE="$(
            numfmt -d $'\t' --field=1 --to=iec --round=up < "$ALLOC_TOTAL" 2>/dev/null |
                awk -F '\t' 'NR==1 {print $1}'
        )"
        [[ -n "$TOTAL_MEDIA_SIZE" ]] || TOTAL_MEDIA_SIZE='N/A'
    fi

    if [[ -s "$ALLOC_TOP" ]]; then
        numfmt -d $'\t' --field=1 --to=iec --round=up < "$ALLOC_TOP" 2>/dev/null |
            LC_ALL=C sort -h > "$TOP_SORTED"
    fi

    status_line ok "Index Sorting Complete in $(format_duration "$MEDIA_SORT_SECONDS")..."
fi

status_line ok "Media Scan Complete: ${TOTAL_MEDIA_FILES} files, ${TOTAL_MEDIA_DIRS} directories, ${TOTAL_MEDIA_SIZE}"
chapter 4 'Detailed Reports'
status_line work 'Writing Reports...'

# Media report.
{
    echo '----------------------------------------------------------------------'
    echo 'MEDIA INVENTORY'
    echo '----------------------------------------------------------------------'
    echo
    echo 'SUMMARY'
    echo '-------'
    printf 'Host:        %s\n' "$HOST"
    printf 'Generated:   %s\n' "$STARTED_AT"
    printf 'Directory:   %s\n' "$MEDIA_DIR"
    printf 'Files:       %s\n' "$TOTAL_MEDIA_FILES"
    printf 'Directories: %s\n' "$TOTAL_MEDIA_DIRS"
    printf 'Total Size:  %s\n' "$TOTAL_MEDIA_SIZE"
    printf 'Scan Time:   %s\n' "$(format_duration "$MEDIA_WALK_SECONDS")"
    printf 'Sort Time:   %s\n' "$(format_duration "$MEDIA_SORT_SECONDS")"
    echo
    echo 'Inventory Only. Media Content is not copied.'
    echo
    echo '----------------------------------------------------------------------'
    echo 'DIRECTORY TREE / FILE LIST'
    echo '----------------------------------------------------------------------'
    echo

    if [[ -d "$MEDIA_DIR" ]]; then
        echo 'DIRECTORIES:'
        echo '------------'
        cat "$DIRS_SORTED" 2>/dev/null
        echo
        echo
        echo 'FILES:'
        echo '------'
        cat "$FILES_SORTED" 2>/dev/null
        echo
        echo
        section 'FILES WITH SIZE AND MODIFICATION DATE'
        echo
        cat "$META_SORTED" 2>/dev/null
        echo
        echo
        section 'FILE COUNTS BY EXTENSION'
        echo
        cat "$EXT_SORTED" 2>/dev/null
        echo
        echo
        section 'TOTAL MEDIA SIZE'
        echo
        printf '%s\t%s\n' "$TOTAL_MEDIA_SIZE" "$MEDIA_DIR"
        echo
        echo
        section 'TOP LEVEL DIRECTORIES'
        echo
        cat "$TOP_SORTED" 2>/dev/null
    else
        echo "ERROR: $MEDIA_DIR does not exist..."
    fi

    echo
    echo '----------------------------------------------------------------------'
    echo 'END OF MEDIA INVENTORY'
    echo '----------------------------------------------------------------------'
} > "$MEDIA_REPORT"

# System report.
{
    echo '----------------------------------------------------------------------'
    echo 'PROXMOX SYSTEM REPORT'
    echo '----------------------------------------------------------------------'
    echo
    echo 'SUMMARY'
    echo '-------'
    printf 'Host:            %s\n' "$HOST"
    printf 'Generated:       %s\n' "$STARTED_AT"
    printf 'Uptime:          %s\n' "$UPTIME"
    printf 'Load:            %s\n' "$LOAD_AVG"
    printf 'Root Disk:       %s\n' "$ROOT_USAGE"
    printf 'Memory:          %s\n' "$MEMORY_USAGE"
    printf 'Swap:            %s\n' "$SWAP_USAGE"
    printf 'Failed Services: %s\n' "$FAILED_SERVICES"
    printf 'Errors (24h):    %s\n' "$ERROR_COUNT"
    printf 'Cluster:         %s\n' "$CLUSTER_STATUS"
    printf 'VMs:             %s total, %s running\n' "$VM_COUNT" "$VM_RUNNING"
    printf 'LXC:             %s total, %s running\n' "$LXC_COUNT" "$LXC_RUNNING"
    printf 'Storage:         %s\n' "$STORAGE_STATUS"
    printf 'ZFS:             %s\n' "$ZFS_STATUS"
    printf 'Media Files:     %s\n' "$TOTAL_MEDIA_FILES"
    printf 'Media Dirs:      %s\n' "$TOTAL_MEDIA_DIRS"
    printf 'Media Size:      %s\n' "$TOTAL_MEDIA_SIZE"
    printf 'Media Walk:      %s\n' "$(format_duration "$MEDIA_WALK_SECONDS")"
    printf 'Media Sorting:   %s\n' "$(format_duration "$MEDIA_SORT_SECONDS")"

    section 'PROXMOX VERSION'
    run_cmd pveversion --verbose

    section 'NODE STATUS'
    run_cmd pvesh get /nodes/"$HOST"/status

    section 'MEMORY'
    run_cmd free -h

    section 'CPU'
    run_cmd lscpu

    section 'FILESYSTEM USAGE'
    run_cmd df -hT

    section 'BLOCK DEVICES'
    run_cmd lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINTS,MODEL,SERIAL

    section 'ZFS STATUS'
    if command -v zpool >/dev/null 2>&1; then
        run_cmd zpool status
        run_cmd zpool list
    else
        echo 'ZFS tools not available...'
    fi

    section 'ZFS DATASETS'
    if command -v zfs >/dev/null 2>&1; then
        run_cmd zfs list
    else
        echo 'ZFS tools not available...'
    fi

    section 'PROXMOX STORAGE STATUS'
    run_cmd pvesm status

    section 'PROXMOX STORAGE CONFIG'
    storage_cfg="$(source_path /etc/pve/storage.cfg)"
    if [[ -f "$storage_cfg" ]]; then
        cat "$storage_cfg"
    else
        echo '/etc/pve/storage.cfg not found...'
    fi

    section 'VIRTUAL MACHINES'
    printf '%s\n' "$VM_LIST"
    echo
    echo '--- VM CONFIGURATIONS ---'
    while read -r vmid; do
        [[ -z "$vmid" ]] && continue
        echo
        echo '----------------------------------------------------------------------'
        echo "VM $vmid"
        echo '----------------------------------------------------------------------'
        print_vm_config "$vmid"
    done < <(printf '%s\n' "$VM_LIST" | awk 'NR>1 && NF {print $1}')

    section 'LXC CONTAINERS'
    printf '%s\n' "$LXC_LIST"
    echo
    echo '--- LXC CONFIGURATIONS ---'
    while read -r ctid; do
        [[ -z "$ctid" ]] && continue
        echo
        echo '----------------------------------------------------------------------'
        echo "LXC $ctid"
        echo '----------------------------------------------------------------------'
        pct config "$ctid" 2>&1 || true
    done < <(printf '%s\n' "$LXC_LIST" | awk 'NR>1 && NF {print $1}')

    section 'NETWORK INTERFACES'
    run_cmd ip -br addr

    section 'NETWORK ROUTES'
    run_cmd ip route

    section 'BRIDGES'
    if command -v bridge >/dev/null 2>&1; then
        run_cmd bridge link
    else
        echo 'bridge command not available...'
    fi

    section 'MOUNTS'
    run_cmd findmnt

    section 'IMPORTANT SERVICES'
    for service in pve-cluster pvedaemon pveproxy pvestatd pve-ha-lrm pve-ha-crm corosync ssh smartd; do
        if systemctl list-unit-files "$service.service" >/dev/null 2>&1; then
            echo
            echo "--- $service ---"
            systemctl is-active "$service" 2>&1 || true
            systemctl is-enabled "$service" 2>&1 || true
        fi
    done

    section 'FAILED SYSTEMD SERVICES'
    run_cmd systemctl --failed --no-pager

    section 'RECENT PROXMOX JOURNAL'
    journalctl -u pve-cluster -u pvedaemon -u pveproxy -u pvestatd \
        --since '24 hours ago' --no-pager -n "$JOURNAL_LINES" 2>&1 || true

    section 'RECENT SYSTEM ERRORS'
    journalctl -p err --since '24 hours ago' --no-pager -n "$JOURNAL_LINES" 2>&1 || true

    section 'SMART DISK HEALTH'
    if command -v smartctl >/dev/null 2>&1; then
        while read -r disk; do
            [[ -z "$disk" ]] && continue
            echo
            echo '----------------------------------------------------------------------'
            echo "SMART: $disk"
            echo '----------------------------------------------------------------------'
            smartctl -H "$disk" 2>&1 || true
        done < <(lsblk -dn -o NAME,TYPE 2>/dev/null | awk '$2=="disk" {print "/dev/"$1}')
    else
        echo 'smartctl Not Installed...'
    fi

    section 'MEDIA INVENTORY'
    printf 'Media Directory: %s\n' "$MEDIA_DIR"
    printf 'Full Inventory:  %s\n' "$MEDIA_REPORT"
    echo
    echo 'Inventory Size:'
    du -h "$MEDIA_REPORT" 2>/dev/null || true

    echo
    echo '----------------------------------------------------------------------'
    echo 'END OF PROXMOX SYSTEM REPORT'
    echo '----------------------------------------------------------------------'
} > "$REPORT_FILE"

chmod 600 "$REPORT_FILE" "$MEDIA_REPORT" 2>/dev/null || true
status_line ok 'Reports Written...'
chapter 5 'Structural Snapshot'
status_line work 'Building Structural Snapshot...'
verbose_line 'Creating Snapshot Layout...'

# Build the structural snapshot.
mkdir -p \
    "$SNAPSHOT_DIR/summary" \
    "$SNAPSHOT_DIR/system" \
    "$SNAPSHOT_DIR/proxmox/vms" \
    "$SNAPSHOT_DIR/proxmox/lxc" \
    "$SNAPSHOT_DIR/proxmox/config" \
    "$SNAPSHOT_DIR/host-config" \
    "$SNAPSHOT_DIR/media"

cp -- "$REPORT_FILE" "$SNAPSHOT_DIR/system/proxmox-report.txt"
cp -- "$MEDIA_REPORT" "$SNAPSHOT_DIR/media/media-inventory.txt"

verbose_line 'Capturing System Inventory...'
capture_cmd "$SNAPSHOT_DIR/system/pveversion.txt" pveversion --verbose
printf '%s\n' "$STORAGE_TABLE" > "$SNAPSHOT_DIR/system/storage-status.txt"
capture_cmd "$SNAPSHOT_DIR/system/filesystems.txt" df -hT
capture_cmd "$SNAPSHOT_DIR/system/block-devices.txt" lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINTS,MODEL,SERIAL
capture_cmd "$SNAPSHOT_DIR/system/mounts.txt" findmnt
capture_cmd "$SNAPSHOT_DIR/system/network.txt" ip -br addr
capture_cmd "$SNAPSHOT_DIR/system/routes.txt" ip route
capture_cmd "$SNAPSHOT_DIR/system/failed-services.txt" systemctl --failed --no-pager
capture_cmd "$SNAPSHOT_DIR/system/services.txt" systemctl list-units --type=service --all --no-pager

if command -v dpkg-query >/dev/null 2>&1; then
    dpkg-query -W -f='${binary:Package}\t${Version}\n' > "$SNAPSHOT_DIR/system/packages.txt" 2>&1 || true
else
    echo 'dpkg-query Not Available...' > "$SNAPSHOT_DIR/system/packages.txt"
fi

by_id_dir="$(source_path /dev/disk/by-id)"
if [[ -d "$by_id_dir" ]]; then
    find "$by_id_dir" -maxdepth 1 -type l -printf '%f -> %l\n' 2>/dev/null | sort > "$SNAPSHOT_DIR/system/disk-by-id.txt"
else
    echo '/dev/disk/by-id Not Available...' > "$SNAPSHOT_DIR/system/disk-by-id.txt"
fi

if command -v pvecm >/dev/null 2>&1; then
    capture_cmd "$SNAPSHOT_DIR/system/cluster-status.txt" pvecm status
else
    echo 'Standalone or PVECM Unavailable...' > "$SNAPSHOT_DIR/system/cluster-status.txt"
fi

if command -v ha-manager >/dev/null 2>&1; then
    capture_cmd "$SNAPSHOT_DIR/system/ha-status.txt" ha-manager status
else
    echo 'HA-Manager Not Available...' > "$SNAPSHOT_DIR/system/ha-status.txt"
fi

if command -v pvesr >/dev/null 2>&1; then
    capture_cmd "$SNAPSHOT_DIR/system/replication.txt" pvesr status
else
    echo 'PVESR Not Available...' > "$SNAPSHOT_DIR/system/replication.txt"
fi

if command -v pve-firewall >/dev/null 2>&1; then
    capture_cmd "$SNAPSHOT_DIR/system/firewall-status.txt" pve-firewall status
else
    echo 'PVE-Firewall Not Available...' > "$SNAPSHOT_DIR/system/firewall-status.txt"
fi

if command -v zpool >/dev/null 2>&1; then
    capture_cmd "$SNAPSHOT_DIR/system/zfs-status.txt" zpool status
    capture_cmd "$SNAPSHOT_DIR/system/zfs-pools.txt" zpool list
else
    echo 'ZFS Tools Not Available...' > "$SNAPSHOT_DIR/system/zfs-status.txt"
    echo 'ZFS Tools Not Available...' > "$SNAPSHOT_DIR/system/zfs-pools.txt"
fi

if command -v zfs >/dev/null 2>&1; then
    capture_cmd "$SNAPSHOT_DIR/system/zfs-datasets.txt" zfs list
else
    echo 'ZFS Tools Not Available...' > "$SNAPSHOT_DIR/system/zfs-datasets.txt"
fi

: > "$SNAPSHOT_DIR/system/smart-health.txt"
if command -v smartctl >/dev/null 2>&1; then
    while read -r disk; do
        [[ -z "$disk" ]] && continue
        printf '%s\n' "--- $disk ---" >> "$SNAPSHOT_DIR/system/smart-health.txt"
        smartctl -H "$disk" >> "$SNAPSHOT_DIR/system/smart-health.txt" 2>&1 || true
        echo >> "$SNAPSHOT_DIR/system/smart-health.txt"
    done < <(lsblk -dn -o NAME,TYPE 2>/dev/null | awk '$2=="disk" {print "/dev/"$1}')
else
    echo 'SmartCTL Not Available...' > "$SNAPSHOT_DIR/system/smart-health.txt"
fi

if command -v lspci >/dev/null 2>&1; then
    capture_cmd "$SNAPSHOT_DIR/system/pci-devices.txt" lspci -nnk
fi
if command -v lsusb >/dev/null 2>&1; then
    capture_cmd "$SNAPSHOT_DIR/system/usb-devices.txt" lsusb
fi

# VM and LXC configs.
verbose_line 'Capturing VM and LXC Configuration...'
while read -r vmid; do
    [[ -z "$vmid" ]] && continue
    print_vm_config "$vmid" > "$SNAPSHOT_DIR/proxmox/vms/${vmid}.conf"
done < <(printf '%s\n' "$VM_LIST" | awk 'NR>1 && NF {print $1}')

while read -r ctid; do
    [[ -z "$ctid" ]] && continue
    pct config "$ctid" > "$SNAPSHOT_DIR/proxmox/lxc/${ctid}.conf" 2>&1 || true
done < <(printf '%s\n' "$LXC_LIST" | awk 'NR>1 && NF {print $1}')

# Safe Proxmox configuration.
verbose_line 'Capturing Proxmox Configuration...'
for cfg in storage.cfg datacenter.cfg jobs.cfg replication.cfg vzdump.cron user.cfg corosync.conf; do
    copy_host_file "/etc/pve/$cfg" "$SNAPSHOT_DIR/proxmox/config/$cfg"
done
copy_host_tree '/etc/pve/firewall' "$SNAPSHOT_DIR/proxmox/config/firewall"
copy_host_tree '/etc/pve/ha' "$SNAPSHOT_DIR/proxmox/config/ha"
copy_host_tree '/etc/pve/mapping' "$SNAPSHOT_DIR/proxmox/config/mapping"
copy_host_file '/etc/vzdump.conf' "$SNAPSHOT_DIR/proxmox/config/vzdump.conf"

# Host configuration.
verbose_line 'Capturing Host Configuration...'
copy_host_file '/etc/network/interfaces' "$SNAPSHOT_DIR/host-config/interfaces"
copy_host_tree '/etc/network/interfaces.d' "$SNAPSHOT_DIR/host-config/interfaces.d"
copy_host_file '/etc/fstab' "$SNAPSHOT_DIR/host-config/fstab"
copy_host_file '/etc/hosts' "$SNAPSHOT_DIR/host-config/hosts"
copy_host_file '/etc/resolv.conf' "$SNAPSHOT_DIR/host-config/resolv.conf"
copy_host_file '/etc/hostname' "$SNAPSHOT_DIR/host-config/hostname"
copy_host_file '/etc/default/grub' "$SNAPSHOT_DIR/host-config/grub"
copy_host_file '/etc/kernel/cmdline' "$SNAPSHOT_DIR/host-config/kernel-cmdline"
copy_host_file '/etc/modules' "$SNAPSHOT_DIR/host-config/modules"
copy_host_tree '/etc/modules-load.d' "$SNAPSHOT_DIR/host-config/modules-load.d"
copy_host_tree '/etc/modprobe.d' "$SNAPSHOT_DIR/host-config/modprobe.d"
copy_host_file '/etc/sysctl.conf' "$SNAPSHOT_DIR/host-config/sysctl.conf"
copy_host_tree '/etc/sysctl.d' "$SNAPSHOT_DIR/host-config/sysctl.d"
copy_host_tree '/etc/udev/rules.d' "$SNAPSHOT_DIR/host-config/udev-rules.d"
copy_host_file '/etc/apt/sources.list' "$SNAPSHOT_DIR/host-config/apt/sources.list"
copy_host_tree '/etc/apt/sources.list.d' "$SNAPSHOT_DIR/host-config/apt/sources.list.d"

proc_cmdline="$(source_path /proc/cmdline)"
if [[ -f "$proc_cmdline" ]]; then
    cp -a -- "$proc_cmdline" "$SNAPSHOT_DIR/host-config/proc-cmdline.txt"
elif [[ -r /proc/cmdline ]]; then
    cp -- /proc/cmdline "$SNAPSHOT_DIR/host-config/proc-cmdline.txt"
fi

# Sensitive data is opt-in.
verbose_line 'Checking optional sensitive data'
if [[ "$INCLUDE_PVE_PRIV" == '1' ]]; then
    copy_host_tree '/etc/pve/priv' "$SNAPSHOT_DIR/sensitive/pve-priv"
fi

if [[ "$INCLUDE_ROOT_SSH" == '1' ]]; then
    copy_host_tree '/root/.ssh' "$SNAPSHOT_DIR/sensitive/root-ssh"
fi

if [[ "$INCLUDE_SSH_HOST_KEYS" == '1' ]]; then
    mkdir -p "$SNAPSHOT_DIR/sensitive/ssh-host-keys"
    shopt -s nullglob
    for key_file in "$(source_path /etc/ssh)"/ssh_host_*_key; do
        cp -a -- "$key_file" "$SNAPSHOT_DIR/sensitive/ssh-host-keys/"
    done
    shopt -u nullglob
fi

if [[ "$INCLUDE_API_TOKENS" == '1' ]]; then
    copy_host_file '/etc/pve/priv/token.cfg' "$SNAPSHOT_DIR/sensitive/api-tokens/token.cfg"
fi

if [[ "$INCLUDE_PASSWORD_FILES" == '1' ]]; then
    copy_host_file '/etc/pve/priv/shadow.cfg' "$SNAPSHOT_DIR/sensitive/password-files/shadow.cfg"
    storage_priv="$(source_path /etc/pve/priv/storage)"
    if [[ -d "$storage_priv" ]]; then
        shopt -s nullglob
        for password_file in "$storage_priv"/*.pw; do
            mkdir -p "$SNAPSHOT_DIR/sensitive/password-files/storage"
            cp -a -- "$password_file" "$SNAPSHOT_DIR/sensitive/password-files/storage/"
        done
        shopt -u nullglob
    fi
fi

if [[ "$INCLUDE_PRIVATE_KEYS" == '1' ]]; then
    copy_host_tree '/etc/ssl/private' "$SNAPSHOT_DIR/sensitive/private-keys/etc-ssl-private"
    copy_host_file "/etc/pve/nodes/$HOST/pve-ssl.key" "$SNAPSHOT_DIR/sensitive/private-keys/pve-ssl.key"
    copy_host_file "/etc/pve/nodes/$HOST/pveproxy-ssl.key" "$SNAPSHOT_DIR/sensitive/private-keys/pveproxy-ssl.key"
    copy_host_file '/etc/pve/pve-www.key' "$SNAPSHOT_DIR/sensitive/private-keys/pve-www.key"
    copy_host_file '/etc/pve/priv/pve-root-ca.key' "$SNAPSHOT_DIR/sensitive/private-keys/pve-root-ca.key"
    copy_host_file '/etc/pve/priv/authkey.key' "$SNAPSHOT_DIR/sensitive/private-keys/authkey.key"
    storage_priv="$(source_path /etc/pve/priv/storage)"
    if [[ -d "$storage_priv" ]]; then
        shopt -s nullglob
        for encryption_key in "$storage_priv"/*.enc; do
            mkdir -p "$SNAPSHOT_DIR/sensitive/private-keys/storage"
            cp -aL -- "$encryption_key" "$SNAPSHOT_DIR/sensitive/private-keys/storage/"
        done
        shopt -u nullglob
    fi
fi

SENSITIVE_ENABLED=()
[[ "$INCLUDE_PVE_PRIV" == '1' ]] && SENSITIVE_ENABLED+=('pve-priv')
[[ "$INCLUDE_ROOT_SSH" == '1' ]] && SENSITIVE_ENABLED+=('root-ssh')
[[ "$INCLUDE_SSH_HOST_KEYS" == '1' ]] && SENSITIVE_ENABLED+=('ssh-host-keys')
[[ "$INCLUDE_API_TOKENS" == '1' ]] && SENSITIVE_ENABLED+=('api-tokens')
[[ "$INCLUDE_PASSWORD_FILES" == '1' ]] && SENSITIVE_ENABLED+=('password-files')
[[ "$INCLUDE_CLOUD_INIT_SECRETS" == '1' ]] && SENSITIVE_ENABLED+=('cloud-init-secrets')
[[ "$INCLUDE_PRIVATE_KEYS" == '1' ]] && SENSITIVE_ENABLED+=('private-keys')
if (( ${#SENSITIVE_ENABLED[@]} > 0 )); then
    SENSITIVE_SUMMARY="${SENSITIVE_ENABLED[*]}"
else
    SENSITIVE_SUMMARY='none'
fi

BUILD_SECONDS=$(( $(date +%s) - START_EPOCH ))
BUILD_TIME="$(format_duration "$BUILD_SECONDS")"

{
    printf 'Host:            %s\n' "$HOST"
    printf 'Generated:       %s\n' "$STARTED_AT"
    printf 'Uptime:          %s\n' "$UPTIME"
    printf 'Load:            %s\n' "$LOAD_AVG"
    printf 'Root Disk:       %s\n' "$ROOT_USAGE"
    printf 'Memory:          %s\n' "$MEMORY_USAGE"
    printf 'Swap:            %s\n' "$SWAP_USAGE"
    printf 'Failed Services: %s\n' "$FAILED_SERVICES"
    printf 'Errors (24h):    %s\n' "$ERROR_COUNT"
    printf 'Cluster:         %s\n' "$CLUSTER_STATUS"
    printf 'VMs:             %s total, %s running\n' "$VM_COUNT" "$VM_RUNNING"
    printf 'LXC:             %s total, %s running\n' "$LXC_COUNT" "$LXC_RUNNING"
    printf 'Storage:         %s\n' "$STORAGE_STATUS"
    printf 'ZFS:             %s\n' "$ZFS_STATUS"
    printf 'Media:           %s files, %s dirs, %s\n' "$TOTAL_MEDIA_FILES" "$TOTAL_MEDIA_DIRS" "$TOTAL_MEDIA_SIZE"
    printf 'Media Walk:      %s\n' "$(format_duration "$MEDIA_WALK_SECONDS")"
    printf 'Media Sorting:   %s\n' "$(format_duration "$MEDIA_SORT_SECONDS")"
    printf 'Build Time:      %s\n' "$BUILD_TIME"
    printf 'Sensitive:       %s\n' "$SENSITIVE_SUMMARY"
} > "$SNAPSHOT_DIR/summary/overview.txt"

{
    echo 'Proxmox Structural Snapshot.'
    echo
    echo 'Contains system reports, VM/LXC configuration, host configuration and media inventory.'
    echo 'Does not contain VM disks, container filesystems or media content.'
    echo "Sensitive categories: $SENSITIVE_SUMMARY"
    echo 'The Discord webhook and report config file are not included.'
} > "$SNAPSHOT_DIR/README.txt"

chapter 6 'ZIP + Verification'
status_line work 'Building Manifest and Checksums...'
verbose_line 'Hashing Snapshot Files...'

# Manifest and checksums.
python3 - "$SNAPSHOT_DIR" <<'PY'
from __future__ import annotations

import hashlib
import os
import sys
from pathlib import Path

root = Path(sys.argv[1])
summary = root / 'summary'
manifest = summary / 'manifest.txt'
checksums = summary / 'checksums.sha256'

files = sorted(p for p in root.rglob('*') if p.is_file() and p not in {manifest, checksums})
with manifest.open('w', encoding='utf-8') as fh:
    for path in files:
        rel = path.relative_to(root).as_posix()
        fh.write(f'{path.stat().st_size:12d}  {rel}\n')

files = sorted(p for p in root.rglob('*') if p.is_file() and p != checksums)
with checksums.open('w', encoding='utf-8') as fh:
    for path in files:
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        rel = path.relative_to(root).as_posix()
        fh.write(f'{digest}  {rel}\n')
PY

# Create and verify ZIP.
SNAPSHOT_FILE_COUNT="$(find "$SNAPSHOT_DIR" -type f | wc -l)"
SNAPSHOT_RAW_SIZE="$(du -sh "$SNAPSHOT_DIR" 2>/dev/null | awk 'NR==1 {print $1}')"
[[ -n "$SNAPSHOT_RAW_SIZE" ]] || SNAPSHOT_RAW_SIZE='N/A'
status_line work "Compressing snapshot: ${SNAPSHOT_FILE_COUNT} files, ${SNAPSHOT_RAW_SIZE} uncompressed"
if python3 - "$SNAPSHOT_DIR" "$SNAPSHOT_ARCHIVE" <<'PY'
from __future__ import annotations

import sys
import zipfile
from pathlib import Path

root = Path(sys.argv[1])
archive = Path(sys.argv[2])

with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as zf:
    for path in sorted(root.rglob('*')):
        if path.is_file():
            zf.write(path, arcname=path.relative_to(root).as_posix())

with zipfile.ZipFile(archive) as zf:
    bad = zf.testzip()
    if bad is not None:
        raise RuntimeError(f'ZIP integrity failure: {bad}')
PY
then
    chmod 600 "$SNAPSHOT_ARCHIVE" 2>/dev/null || true
    ARCHIVE_STATUS='Ready'
    ARCHIVE_SIZE="$(du -h "$SNAPSHOT_ARCHIVE" 2>/dev/null | awk 'NR==1 {print $1}')"
    [[ -n "$ARCHIVE_SIZE" ]] || ARCHIVE_SIZE='N/A'
    status_line ok "Snapshot Ready: ${SNAPSHOT_ARCHIVE##*/} (${ARCHIVE_SIZE})"
else
    ARCHIVE_STATUS='Failed'
    rm -f -- "$SNAPSHOT_ARCHIVE"
    warn 'Snapshot ZIP Creation Failed.'
fi

BUILD_SECONDS=$(( $(date +%s) - START_EPOCH ))
BUILD_TIME="$(format_duration "$BUILD_SECONDS")"

DISCORD_MESSAGE="# Proxmox Report

Host: ${HOST}
Time: $(date '+%Y-%m-%d %H:%M')
Uptime: ${UPTIME}
Load: ${LOAD_AVG}
Root: ${ROOT_USAGE}
Memory: ${MEMORY_USAGE}
Swap: ${SWAP_USAGE}
Failed Services: ${FAILED_SERVICES}
Errors (24h): ${ERROR_COUNT}

## PROXMOX
Cluster: ${CLUSTER_STATUS}
VMs: ${VM_RUNNING}/${VM_COUNT} running
LXC: ${LXC_RUNNING}/${LXC_COUNT} running
Storage: ${STORAGE_STATUS}
ZFS: ${ZFS_STATUS}

## MEDIA
Path: ${MEDIA_DIR}
Files: ${TOTAL_MEDIA_FILES}
Directories: ${TOTAL_MEDIA_DIRS}
Size: ${TOTAL_MEDIA_SIZE}
Inventory: $(format_duration "$((MEDIA_WALK_SECONDS + MEDIA_SORT_SECONDS))")

## SNAPSHOT
Archive: ${SNAPSHOT_ARCHIVE##*/}
Archive Size: ${ARCHIVE_SIZE}
Build Time: ${BUILD_TIME}"

chapter 7 'Discord + Cleanup'

# Discord upload.
if [[ -n "$DISCORD_WEBHOOK" ]]; then
    JSON_PAYLOAD="$(python3 -c 'import json, sys; print(json.dumps({"content": sys.argv[1]}))' "${DISCORD_MESSAGE:0:1900}")"

    if [[ "$DISCORD_WEBHOOK" == *'?'* ]]; then
        DISCORD_POST_URL="${DISCORD_WEBHOOK}&wait=true"
    else
        DISCORD_POST_URL="${DISCORD_WEBHOOK}?wait=true"
    fi

    status_line work "Uploading Discord Report (${ARCHIVE_SIZE})..."
    HTTP_CODE='000'

    if [[ -f "$SNAPSHOT_ARCHIVE" ]]; then
        ARCHIVE_BYTES="$(stat -c '%s' "$SNAPSHOT_ARCHIVE" 2>/dev/null || echo 0)"
        if (( ARCHIVE_BYTES <= DISCORD_FILE_LIMIT_BYTES )); then
            HTTP_CODE="$(curl -sS --connect-timeout 15 --max-time 60 \
                -o "$DISCORD_RESPONSE" -w '%{http_code}' -X POST \
                --form-string "payload_json=$JSON_PAYLOAD" \
                -F "files[0]=@$SNAPSHOT_ARCHIVE;type=application/zip" \
                "$DISCORD_POST_URL" 2>/dev/null)" || HTTP_CODE='000'
        else
            warn 'Snapshot exceeds the Discord attachment limit; sending summary only.'
            HTTP_CODE="$(curl -sS --connect-timeout 15 --max-time 60 \
                -o "$DISCORD_RESPONSE" -w '%{http_code}' \
                -H 'Content-Type: application/json' -X POST \
                --data-binary "$JSON_PAYLOAD" "$DISCORD_POST_URL" 2>/dev/null)" || HTTP_CODE='000'
            DISCORD_STATUS='Sent Summary Only...'
        fi
    else
        HTTP_CODE="$(curl -sS --connect-timeout 15 --max-time 60 \
            -o "$DISCORD_RESPONSE" -w '%{http_code}' \
            -H 'Content-Type: application/json' -X POST \
            --data-binary "$JSON_PAYLOAD" "$DISCORD_POST_URL" 2>/dev/null)" || HTTP_CODE='000'
        DISCORD_STATUS='Sent Summary Only...'
    fi

    if [[ "$HTTP_CODE" == '200' || "$HTTP_CODE" == '204' ]]; then
        if [[ "$DISCORD_STATUS" == 'Sent summary only' ]]; then
            status_line ok 'Discord Summary Sent...'
        else
            DISCORD_STATUS='Sent with snapshot'
            status_line ok 'Discord Report Sent...'
        fi
    else
        DISCORD_STATUS="Failed (HTTP $HTTP_CODE)"
        warn "Discord Webhook Returned HTTP $HTTP_CODE."
        if [[ -s "$DISCORD_RESPONSE" ]]; then
            RESPONSE_PREVIEW="$(head -c 300 "$DISCORD_RESPONSE" 2>/dev/null | tr '\r\n' '  ')"
            [[ -n "$RESPONSE_PREVIEW" ]] && warn "Discord Response: $RESPONSE_PREVIEW"
        fi
    fi
else
    warn 'DISCORD_WEBHOOK is not configured; skipping Discord upload.'
fi

# Retention only touches this script's files.
status_line work 'Cleaning old reports...'
verbose_line "Retention: ${RETENTION_DAYS} days"
find "$REPORT_DIR" -maxdepth 1 -type f -mtime +"$RETENTION_DAYS" \
    \( -name 'proxmox-report-*.txt' -o -name 'media-inventory-*.txt' -o -name 'proxmox-snapshot-*.zip' \) \
    -delete 2>/dev/null || warn 'Old report cleanup did not complete cleanly.'
status_line ok 'Cleanup Complete...'
finish_phase

TOTAL_SECONDS=$(( $(date +%s) - START_EPOCH ))
TOTAL_TIME="$(format_duration "$TOTAL_SECONDS")"

printf '\n'
panel_header 'OWNER SUMMARY'
panel_row "System Report   ${REPORT_FILE##*/}"
panel_row "Media Report    ${MEDIA_REPORT##*/}"
panel_row "Snapshot        ${SNAPSHOT_ARCHIVE##*/} (${ARCHIVE_SIZE})"
panel_row "VMs             ${VM_COUNT} total, ${VM_RUNNING} running"
panel_row "LXC             ${LXC_COUNT} total, ${LXC_RUNNING} running"
panel_row "Failed Services ${FAILED_SERVICES}"
panel_row "Errors (24h)    ${ERROR_COUNT}"
panel_row "Media           ${TOTAL_MEDIA_FILES} files, ${TOTAL_MEDIA_DIRS} dirs, ${TOTAL_MEDIA_SIZE}"
panel_row "Media Walk      $(format_duration "$MEDIA_WALK_SECONDS")"
panel_row "Media Sorting   $(format_duration "$MEDIA_SORT_SECONDS")"
panel_row "Build Time:     ${TOTAL_TIME}"
panel_row "Discord         ${DISCORD_STATUS}"
printf '%s\n' "$FRAME"

panel_header 'STAGE TIMINGS'
for i in "${!PHASE_NAMES[@]}"; do
    panel_row "$(printf '%-20s %s' "${PHASE_NAMES[$i]}" "$(format_duration "${PHASE_SECONDS[$i]}")")"
done
panel_row "$(printf '%-20s %s' '  Media walk' "$(format_duration "$MEDIA_WALK_SECONDS")")"
panel_row "$(printf '%-20s %s' '  Media sorting' "$(format_duration "$MEDIA_SORT_SECONDS")")"
printf '%s\n' "$FRAME"