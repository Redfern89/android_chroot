#!/usr/bin/env sh

FILE=$1
PWD=$(dirname "$(realpath "$0")")

if [ -f "${PWD}/banner" ]; then
    cat "${PWD}/banner"
fi

log_print() {
    echo "[${1}] $2"
}

is_mounted() {
    grep -q " $1 " /proc/mounts
}

# Знаю, по идиотски, но умнее лень было придумывать. Потенциально fragile
mount_flags() {
    mount | grep "on $1 type" |  sed -n 's/.*(\(.*\)).*/\1/p'
}

check_mount_flag() {
    if mount_flags "$1" | grep -q "$2"; then
        return 0
    else
        return 1
    fi
}

check_kernel_feature() {
    if zcat "${KERNEL_CONFIG}" 2>/dev/null | grep -Eq "^CONFIG_$1=(y|m)$"; then
        return 0
    else
        return 1
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


log_print "i" "Running as: $(whoami)"

# Базовые проверки
if [ "$(id -u)" -ne 0 ]; then
    log_print "!" "Not root. Aborted"
    exit 1
fi

# 1. Проверка аргумента
if [ -z "$FILE" ]; then
    echo "Usage: $0 <path_to_file>"
    exit 1
fi

# Настройки окружения
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export USER=root
export HOME=/root
export HOST=fck-phone
export TERM=xterm-256color

# Параметры и переменные
LOCAL_DIR="/data/local"
KERNEL_CONFIG="/proc/config.gz"
BIND_FS_PATHS="dev sys proc"
MASKING_BINDERS="binder hwbinder vndbinder"
FILE_ABS=$(realpath "$FILE")
DISTRO_NAME=$(echo "${FILE_ABS}" | sed 's/.*\///; s/\.[^.]*$//')
ROOTFS_PATH="${LOCAL_DIR}/${DISTRO_NAME}"
LOOP_PATH=$(losetup -j "${FILE_ABS}" | cut -d: -f1)
TMPFS_SIZE=500M
USE_NS_KERNEL=false

if command -v getprop > /dev/null 2>&1; then
    log_print "i" "Device: $(getprop ro.product.model)"
    log_print "i" "Vendor: $(getprop ro.product.manufacturer)"
    log_print "i" "Android version: $(getprop ro.vendor.build.version.release)"
else
    log_print "i" "Possibly running outside Android. Ignoring"
fi

log_print "i" "Kernel: $(uname -r)"
log_print "i" "Terminal: $(get_term)"
log_print "+" "Checking kernel features"

# /proc/config.gz checking
if [ -f "${KERNEL_CONFIG}" ]; then

    if check_kernel_feature 'NAMESPACES'; then
        log_print "+" "This kernel uses a namespaces"
        USE_NS_KERNEL=true
    else
        log_print "-" "This kernel not uses a namespaces. Cleanup required"
    fi

    if ! check_kernel_feature 'BLK_DEV_LOOP'; then
        log_print "!" "Loopback block devices not supported. Aborted"
        exit 1
    else
        log_print "+" "Loopback block devices supported."
    fi

    if check_kernel_feature 'ANDROID_PARANOID_NETWORK'; then
        log_print "!" "ANDROID_PARANOID_NETWORK enabled. Network is stuck"
    else
        log_print "+" "ANDROID_PARANOID_NETWORK disabled. Network sockets workflow"
    fi

    if check_kernel_feature 'SECURITY_SELINUX'; then
        # Fucking SE Linux
        if command -v getenforce > /dev/null 2>&1; then
            ENFORCE_STATE=$(getenforce | tr '[:upper:]' '[:lower:]')
            log_lvl="+"
            log_state="All is oaky"
            if [ "${ENFORCE_STATE}" == "enforcing" ]; then
                log_lvl="!"
                log_state="There may be problems"

            fi
            log_print "${log_lvl}" "SELinux in ${ENFORCE_STATE} state. ${log_state}"
        else
            log_print "-" "getenforce not available, ignoring"
        fi
    fi
else
    log_print "!" "kernel configuration ${KERNEL_CONFIG} is not available. ignoring"
fi

# 2. Базовые проверки
if [ ! -d "${LOCAL_DIR}" ]; then
    log_print "!" "Directory ${LOCAL_DIR} not found. Aborted"
    exit 1
fi

if [ ! -d "${ROOTFS_PATH}" ]; then
    log_print "+" "Creating directory ${ROOTFS_PATH}"
    mkdir -p "${ROOTFS_PATH}"
fi

if is_mounted "/data"; then
    if check_mount_flag "/data" "nosuid"; then
        mount -o remount,dev,suid /data
        log_print "+" "/data remounted with fix FUCKING setuid issue"
    else
        log_print "+" "/data mounted without nosuid flag"
    fi
else
    log_print "-" "/data is not mounted, ignoring"
fi

# 3. Работа с Loop-устройством
if [ -z "${LOOP_PATH}" ]; then
    log_print "+" "Creating loopback for ${FILE_ABS}"
    LOOP_PATH=$(losetup -f --show "${FILE_ABS}")
    
    if [ $? -ne 0 ]; then
        log_print "!" "Failed to create loopback device. Aborted"
        exit 1
    fi
fi
log_print "+" "Using device: ${LOOP_PATH}"

# 4. Монтирование основной FS
log_print "+" "Mounting rootfs to ${ROOTFS_PATH}"
mount -t ext4 "${LOOP_PATH}" "${ROOTFS_PATH}"

if is_mounted "${ROOTFS_PATH}"; then
    #log_print "+" "RootFS mount done. (${ROOTFS_PATH})"
    log_print "i" "OK. RootFS Version: $(get_rootfs_name ${ROOTFS_PATH})"  
else
    log_print "!" "RootFS mount fail. Aborted"
    exit 1
fi

log_print "+" "Begin to mount binded filesystems"

# 5. Bind mount системных директорий
for fs in $BIND_FS_PATHS; do
    [ ! -d "${ROOTFS_PATH}/${fs}" ] && mkdir -p "${ROOTFS_PATH}/${fs}"
    mount --bind "/${fs}" "${ROOTFS_PATH}/${fs}"
    if is_mounted "${ROOTFS_PATH}/${fs}"; then
        echo "   * ${fs}"
    fi
done

# Прячем биндеры от греха подальше
log_print "+" "Masking HW binders"
for mask_fs in $MASKING_BINDERS; do
    mount -t tmpfs tmpfs ${ROOTFS_PATH}/dev/${mask_fs} 2>/dev/null
    echo "   * ${mask_fs}"
done

# /dev/pts
[ ! -d "${ROOTFS_PATH}/dev/pts" ] && mkdir -p "${ROOTFS_PATH}/dev/pts"
mount -t devpts devpts "${ROOTFS_PATH}/dev/pts"
if is_mounted "${ROOTFS_PATH}/dev/pts"; then
   log_print "+" "Mounted pts as ${ROOTFS_PATH}/dev/pts"
fi

# tmpfs
mount -t tmpfs -o size="${TMPFS_SIZE}" tmpfs "${ROOTFS_PATH}/tmp"
if is_mounted "${ROOTFS_PATH}/tmp"; then
   log_print "+" "Mounted tmpfs as ${ROOTFS_PATH}/tmp (size=${TMPFS_SIZE})"
fi

# Checking internal /sdcard partition
if [ -d "/storage/emulated/0" ]; then
    log_print "+" "Found /sdcard partition, mounted to /mnt/sdcard"
    mkdir -p "${ROOTFS_PATH}/mnt/sdcard"
    mount -o bind /storage/emulated/0 "${ROOTFS_PATH}/mnt/sdcard"
fi

# Checking external SD Card partitions
if [ -d "/storage" ]; then
    for dir in /storage/*; do
        base=$(basename "${dir}")
        if [ "${base}" != "emulated" ] && [ "${base}" != "self" ]; then
            if [ -d "${dir}" ]; then
                log_print "+" "Found external storage at ${dir}, mounted to ${ROOTFS_PATH}/mnt/${base}"
                mkdir -p "${ROOTFS_PATH}/mnt/${base}"
                mount -o bind "${dir}" "${ROOTFS_PATH}/mnt/${base}"
            fi
        fi
    done
fi

log_print "*" "Entering into chroot ${ROOTFS_PATH} as super user"
if [ -e "${ROOTFS_PATH}/bin/sudo" ]; then
    chroot "${ROOTFS_PATH}" /bin/sudo su
else
    chroot "${ROOTFS_PATH}" /bin/su -
fi

#################################################
#                                               #
#   Вот тут дальше идет не оптимизированный     #
#   участок кода, нужно доделать все правильно  #
#                                               #
#################################################

log_print "+" "killing all chroot tails"
pids=$(lsof | grep "${ROOTFS_PATH}" | awk '{ print $2 }' | sort -u)

if [ -n "${pids}" ]; then
    log_print "i" "Killing pids: (${pids})"
    kill -9 ${pids} 2>/dev/null
    sleep 1
    log_print "+" "Done"
fi

log_print "+" "Unmounting all"

for dir in /storage/*; do
    base=$(basename "${dir}")
    if [ base != "emulated" ] && [ base != "self" ]; then
        if [ -d "${dir}" ]; then
            if is_mounted "${ROOTFS_PATH}/mnt/${base}"; then
                umount -l "${ROOTFS_PATH}/mnt/${base}" 2>/dev/null
                rm -rf "${ROOTFS_PATH}/mnt/${base}"
            fi
        fi
    fi
done

if is_mounted "${ROOTFS_PATH}/mnt/sdcard"; then
    umount -l "${ROOTFS_PATH}/mnt/sdcard" 2>/dev/null
    rm -rf "${ROOTFS_PATH}/mnt/sdcard"
fi

umount -l "${ROOTFS_PATH}/dev/pts"

for fs in $BIND_FS_PATHS; do
    umount -l "${ROOTFS_PATH}/${fs}" 
done

for mask_fs in $MASKING_BINDERS; do
    [ -d "${ROOTFS_PATH}/dev/${mask_fs}" ] && umount -l "${ROOTFS_PATH}/dev/${mask_fs}" 2>/dev/null
done

[ -d "${ROOTFS_PATH}/tmp" ] && umount -l "${ROOTFS_PATH}/tmp" 2>/dev/null
umount -l "${ROOTFS_PATH}"

log_print "+" "Syncing"
sync

sleep 1

log_print "+" "Removing loopback device ${LOOP_PATH}"
if [ -b "${LOOP_PATH}" ]; then
    losetup -d "${LOOP_PATH}" 2>/dev/null || log_print "!" "Loopback busy, will be cleared on reboot. Strange"
fi

log_print "+" "Done"
echo "Return to shell\n\n"
