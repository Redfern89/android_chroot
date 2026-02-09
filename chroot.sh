#!/usr/bin/env sh

ROOTFS_FULL=$(realpath "$1")
ROOTFS_BASE=$(basename "$1")
PWD=$(cd "$(dirname "$0")" && pwd)

if [ -f "${PWD}/banner.sh" ]; then
    sh "${PWD}/banner.sh"
fi

log_print() {
    color="\033[0m"

    [ "$1" = "+" ] && color="\033[1;32m"
    [ "$1" = "-" ] && color="\033[1;35m"
    [ "$1" = "!" ] && color="\033[1;31m"
    [ "$1" = "i" ] && color="\033[1;33m"
    [ "$1" = "?" ] && color="\033[1;36m"
    [ "$1" = "*" ] && color="\033[1;33m"
    [ "$1" = "@" ] && color="\033[1;34m"
    
    if [ "$3" = true ]; then
    	echo -n "${color}[${1}]\033[0m $2"
    else
        echo "${color}[${1}]\033[0m $2"
    fi
}

log_print "i" "Running as: $(whoami)"

if [ "$(id -u)" -ne 0 ]; then
    log_print "!" "Not root. Aborted"
    exit 1
fi

# Настройки окружения
export PATH=$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export USER=root
export HOME=/root
export HOST=fck-phone
export TERM=xterm-256color
export PS1="(chroot) ${PS1}"

# Параметры и переменные
TMPFS_SIZE=500M
LOCAL_DIR="/data/local"
KERNEL_CONFIG_FILE=""
SHELLS="sh ash bash zsh"
BIND_FS_PATHS="dev dev/pts sys proc"
HAL_BINDERS="binder hwbinder vndbinder"
CLEANUP_BINDERS="dev/binder dev/hwbinder dev/vndbinder dev/pts tmp sys poc dev"
EXTERNAL_STORAGE_PARTS=""
USE_LOOP_DEV=""
LOOP_MOUNT_POINT="/data/local"
KERNEL_CONFIG_FILE=""
KERNEL_CHECK_FEATURE_CMD=""
ROOTFS_PATH=""
SHELLS="sh bash zsh su"
FOUND_SHELLS=""
SHELL_COUNT=0
IS_ANDROID="false"

[ -f "$ROOTFS_FULL" ] && USE_LOOP_DEV="true"
[ -d "$ROOTFS_FULL" ] && USE_LOOP_DEV="false"
[ -d "$ROOTFS_FULL" ] && ROOTFS_PATH="$ROOTFS_FULL"

if [ -z "$USE_LOOP_DEV" ]; then
    log_print "!" "Path ${ROOTFS_FULL} is not blockdevice or rootfs directory. Aborted"
    exit 1
fi

if [ -f "/boot/config-$(uname -r)" ]; then
    KERNEL_CHECK_FEATURE_CMD="cat"
    KERNEL_CONFIG_FILE="/boot/config-$(uname -r)"
elif [ -f "/proc/config.gz" ]; then
    KERNEL_CONFIG_FILE="/proc/config.gz"

    if command -v zcat > /dev/null 2>&1; then
        KERNEL_CHECK_FEATURE_CMD="zcat"
    elif command -v gzip > /dev/null 2>&1; then
        KERNEL_CHECK_FEATURE_CMD="gzip -dc"
    fi
fi

check_kernel_feature() {
    if [ -n "${KERNEL_CHECK_FEATURE_CMD}" ]; then
        ${KERNEL_CHECK_FEATURE_CMD} "${KERNEL_CONFIG_FILE}" 2>/dev/null | grep -Eq "^CONFIG_$1=(y|m)$"
    else
        return 1
    fi
}

get_loop_dev_file() {
    losetup -j "$1" | head -n1 | cut -d: -f1
}

get_loop_dev() {
    losetup "$1" | sed 's/^.*(//;s/)$//'
}

is_mounted() {
    grep -q " $1 " /proc/mounts
}

get_coreutils() {
    if command -v busybox > /dev/null 2>&1; then
        busybox | head -n 1
    elif command -v toybox > /dev/null 2>&1; then
        toybox --version
    elif command -v toolbox > /dev/null 2>&1; then
        toolbox --version
    else
        echo "Unknown"
    fi
}

get_ppid() {
    local pid=${1:-$PPID}
    grep -i "PPid:" "/proc/$pid/status" | tr -cd '0-9'
}

get_process_name() {
    if [ -f "/proc/${1:-$PPID}/comm" ]; then
       cat "/proc/${1:-$PPID}/comm"
    fi
}

get_term() {
    term=""
    # Начинаем с родителя текущего процесса
    current_pid=$PPID
    process_name=$(get_process_name $current_pid)

    while [ -z "$term" ]; do
        case "$process_name" in
            zsh|bash|su|sh|screen|newgrp|sudo)
                # Это оболочки, поднимаемся выше
                current_pid=$(get_ppid $current_pid)
                process_name=$(get_process_name $current_pid)
                
                if [ "$current_pid" -le 1 ]; then
                    term="unknown"
                fi
            ;;
            *)
                term="$process_name"
            ;;
        esac
    done
    
    echo "$term"
}

get_rootfs_name() {
    local release_file="$1/etc/os-release"
    local version=""

    if [ -f "$release_file" ]; then
        version=$(. "$release_file" && echo "$PRETTY_NAME")
    fi

    if [ -z "$version" ]; then
        version="Unknown"
    fi

    echo "$version"
}

get_cpu() {
    if [ -f "/proc/cpuinfo" ]; then
        cpu=$(awk -F '\\s*: | @' \
            '/model name|Hardware|Processor|^cpu model|chip type|^cpu type/ {
            cpu=$2; if ($1 == "Hardware") exit } END { print cpu }' "/proc/cpuinfo")
        [ ! -z "${cpu}" ] && echo "${cpu}"
        [ -z "${cpu}" ] && echo "Unknown"
    else
        echo "Unknown"
    fi
}

[ "${USE_LOOP_DEV}" = "true" ] && log_print "i" "Input file: ${ROOTFS_BASE}, size=$(du -sh ${ROOTFS_FULL} | cut -f1)"

if command -v getprop > /dev/null 2>&1; then
    IS_ANDROID="true"
    log_print "i" "Device: $(getprop ro.product.model) ($(getprop ro.product.product.device))"
    log_print "i" "Vendor: $(getprop ro.product.manufacturer)"
    log_print "i" "Android version: $(getprop ro.vendor.build.version.release)"
else
    log_print "-" "Possibly running outside Android. Ignoring"
fi

if [ -f "${PWD}/android" ]; then
    sh "${PWD}/android"
fi

exit 1

command -v magisk > /dev/null 2>&1 && log_print "i" "Magisk version: $(magisk -v)"

log_print "i" "Arch: $(uname -m)"
log_print "i" "CPU: $(get_cpu)"
log_print "i" "Kernel: $(uname -r)"
log_print "i" "Utils: $(get_coreutils)"
log_print "i" "Terminal: $(get_term)"
log_print "i" "Fetching shell colors"

for i in $(seq 0 15); do
    [ $i -lt 8 ] && color_code=$((40 + i)) || color_code=$((100 + i - 8))
    echo -n "\033[${color_code}m   \033[0m"
    [ $i -eq 7 ] && echo ""
done

echo ""

if [ ! -z "${KERNEL_CONFIG_FILE}" ] && [ ! -z "${KERNEL_CHECK_FEATURE_CMD}" ]; then
    log_print "+" "Checking kernel features (Using: ${KERNEL_CONFIG_FILE})"

    if check_kernel_feature 'NAMESPACES'; then
        log_print "+" "This kernel uses a namespaces"
        USE_NS_KERNEL=true
    else
        log_print "-" "This kernel not uses a namespaces. Cleanup required"
    fi

    if ! check_kernel_feature 'BLK_DEV_LOOP'; then
        log_print "-" "Loopback block devices not supported."
    else
        log_print "+" "Loopback block devices supported."
    fi

    if [ "${IS_ANDROID}" = "true" ]; then
        if check_kernel_feature 'ANDROID_PARANOID_NETWORK'; then
            log_print "-" "ANDROID_PARANOID_NETWORK enabled. Network is stuck"
        else
            log_print "+" "ANDROID_PARANOID_NETWORK disabled. Network sockets alive"
        fi
    fi

    if check_kernel_feature 'SECURITY_SELINUX'; then
        # Fucking SE Linux
        if command -v getenforce > /dev/null 2>&1; then
            selinux_state=$(getenforce | tr '[:upper:]' '[:lower:]')
            log_lvl="+"
            log_state="All is oaky"
            color="\033[1;32m"
            if [ "${selinux_state}" = "enforcing" ]; then
                log_lvl="-"
                log_state="There may be problems"
                color="\033[1;31m"
            fi
            log_print "${log_lvl}" "SELinux in ${color}${selinux_state}\033[0m state. ${log_state}"
        else
            log_print "-" "getenforce not available. Ignoring"
        fi
    fi
else
    log_print "-" "Checking kernel features unavailable. Ignoring"
fi

if [ "${USE_LOOP_DEV}" = "true" ]; then
    LOOP_PATH=$(get_loop_dev_file "$ROOTFS_FULL")
    if [ -z "${LOOP_PATH}" ]; then
        LOOP_PATH=$(losetup -f --show "${ROOTFS_FULL}")

        if [ $? -ne 0 ]; then
            log_print "!" "Failed to create loopback device. Aborted"
            exit 1
        fi
        log_print "+" "Created loopback device: ${LOOP_PATH}"
    else
        log_print "+" "Found exists loopback device ${LOOP_PATH}"
    fi

    TARGET_MOUNT="${LOOP_MOUNT_POINT}/${ROOTFS_BASE}"
    [ ! -d "${TARGET_MOUNT}" ] && mkdir -p "${TARGET_MOUNT}"
    if [ -d "${TARGET_MOUNT}" ]; then
        if ! is_mounted "${TARGET_MOUNT}"; then
            mount "${LOOP_PATH}" "${TARGET_MOUNT}"
            if is_mounted "${TARGET_MOUNT}"; then
                log_print "+" "RootFS mounted to: ${TARGET_MOUNT}"
                log_print "i" "Verison: $(get_rootfs_name ${TARGET_MOUNT})"
                ROOTFS_PATH="${TARGET_MOUNT}"
            else
                log_print "!" "Failed to mount RootFS. Aborted"
                losetup -d "${LOOP_PATH}"
                exit 1
            fi
        else
            log_print "!" "Mountpoint ${TARGET_MOUNT} is busy. Aborted"
            exit 1
        fi
    fi
fi

log_print "+" "Start to mount binded filesystems"
for BIND_FS in $BIND_FS_PATHS; do
    [ ! -d "${ROOTFS_PATH}/${BIND_FS}" ] && mkdir -p "${ROOTFS_PATH}/${BIND_FS}"
    if ! is_mounted "${ROOTFS_PATH}/${BIND_FS}"; then
        mount --bind "/${BIND_FS}" "${ROOTFS_PATH}/${BIND_FS}"
        if is_mounted "${ROOTFS_PATH}/${BIND_FS}"; then
            echo "    [${BIND_FS}]"
        fi
    else
        log_print "-" "${BIND_FS} was mounted before. Fucking strange. Skipping"
    fi
done

# Прячем биндеры от греха подальше
log_print "+" "Masking HAL binders"
for MASKING_BINDER_FS in $HAL_BINDERS; do
    if [ -e "/dev/${MASKING_BINDER_FS}" ]; then 
        mount -t tmpfs tmpfs ${ROOTFS_PATH}/dev/${MASKING_BINDER_FS} 2>/dev/null
        echo "    [${MASKING_BINDER_FS}]"
    else
        log_print "-" "HAL Binder ${MASKING_BINDER_FS} not found, ignoring"
    fi
done

# tmpfs
mount -t tmpfs -o size="${TMPFS_SIZE}" tmpfs "${ROOTFS_PATH}/tmp"
if is_mounted "${ROOTFS_PATH}/tmp"; then
   log_print "+" "Mounted tmpfs as ${ROOTFS_PATH}/tmp (size=${TMPFS_SIZE})"
fi

# Checking external SD Card partitions
if [ -d "/storage" ]; then
    for dir in /storage/*; do
        base=$(basename "${dir}")
        if [ "${base}" != "emulated" ] && [ "${base}" != "self" ]; then
            if [ -d "${dir}" ]; then
                mkdir -p "${ROOTFS_PATH}/mnt/${base}"
                mount -o bind "${dir}" "${ROOTFS_PATH}/mnt/${base}"
                if is_mounted "${ROOTFS_PATH}/mnt/${base}"; then
                    EXTERNAL_STORAGE_PARTS="${EXTERNAL_STORAGE_PARTS}${ROOTFS_PATH}/mnt/${base}
"
                    log_print "+" "Found external storage at ${dir}, mounted to /mnt/${base}"
                fi
            fi
        fi
    done
fi

cleanup() {
    trap - EXIT INT TERM HUP
    
    log_print "+" "killing all chroot tails"
    pids=$(lsof | grep "${ROOTFS_PATH}" | awk '{ print $2 }' | sort -u)

    if [ -n "${pids}" ]; then
        log_print "i" "Killing pids: (${pids})"
        kill -9 ${pids} 2>/dev/null
        sleep 1
        log_print "+" "Done"
    fi

    echo "$EXTERNAL_STORAGE_PARTS" | while IFS= read -r m; do
        [ -z "$m" ] && continue
        log_print "+" "Cleanup ${m}"
        umount "$m"
        if ! is_mounted "$m"; then
            rm -rf "$m"
        fi
    done

    for umnt_path in $CLEANUP_BINDERS; do
        [ -d "${ROOTFS_PATH}/${umnt_path}" ] && umount -l "${ROOTFS_PATH}/${umnt_path}"
        if ! is_mounted "${ROOTFS_PATH}/${umnt_path}"; then
            log_print "+" "Cleanup ${ROOTFS_PATH}/${umnt_path}"
        else
            log_print "!" "Error umounting: ${umnt_path}"
        fi
    done

    if [ "${USE_LOOP_DEV}" = "true" ]; then
        umount -l "${ROOTFS_PATH}"
        if ! is_mounted "${ROOTFS_PATH}"; then
            rm -rf "${ROOTFS_PATH}"
            if [ ! -d  "${ROOTFS_PATH}" ]; then
                log_print "+" "Cleanup ${ROOTFS_PATH}"
            else
                log_print "!" "RootFS cleanup error"
            fi
        else
            log_print "!" "Error unmount RootFS"
        fi

        sleep 1

        log_print "+" "Removing loopback device (${LOOP_PATH})"
        if [ -b "${LOOP_PATH}" ]; then
            losetup -d "${LOOP_PATH}" 2>/dev/null || log_print "-" "The loopback device is busy or removed before, may be cleared on reboot. Strange"
        fi
    fi

    log_print "+" "Syncing"
    sync

    log_print "+" "Done"
    echo "Return to shell\n\n"

    exit 0
}

trap cleanup INT TERM HUP EXIT

log_print "@" "Select shell to use"
for shell in $SHELLS; do
    if [ -x "${ROOTFS_PATH}/bin/$shell" ]; then
        SHELL_PATH="/bin/$shell"
    elif [ -x "${ROOTFS_PATH}/usr/bin/$shell" ]; then
        SHELL_PATH="/usr/bin/$shell"
    else
        continue
    fi
    
    SHELL_COUNT=$((SHELL_COUNT + 1))
    if echo "$SHELL_PATH" | grep -q "su"; then
        echo "    ${SHELL_COUNT}. \033[1;31m$SHELL_PATH\033[0m [ROOT]"
    else
        echo "    ${SHELL_COUNT}. $SHELL_PATH"
    fi
    FOUND_SHELLS="$FOUND_SHELLS $SHELL_PATH"
done

if [ "$SHELL_COUNT" -eq 0 ]; then
    log_print "!" "No shells found! Trying /bin/sh anyway..."
    SELECTED_SHELL="/bin/sh"
elif [ "$SHELL_COUNT" -eq 1 ]; then
    SELECTED_SHELL=$(echo "$FOUND_SHELLS" | xargs)
else   
    while true; do
        log_print "?" "Choice (1-$SHELL_COUNT): " true
        read -r CHOICE
        
        case "$CHOICE" in
            *[!0-9]* | "")
                continue
                ;;
        esac
        
        SELECTED_SHELL=$(echo "$FOUND_SHELLS" | cut -d' ' -f"$((CHOICE + 1))")
        
        if [ ! -z "$SELECTED_SHELL" ] && [ -f "${ROOTFS_PATH}/${SELECTED_SHELL}" ]; then
           log_print "*" "Entering into chroot ${ROOTFS_PATH} with $SELECTED_SHELL"
           break
        fi
    done
    
    if [ ! -z "$SELECTED_SHELL" ] && [ -x "${ROOTFS_PATH}/${SELECTED_SHELL}" ]; then
        chroot "${ROOTFS_PATH}" "$SELECTED_SHELL"
    else
        log_print "!" "Failed to find shell. Aborted"
        exit 1
    fi
fi