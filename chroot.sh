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
    mount | grep " $1 " | sed 's/.*(\(.*\)).*/\1/' | head -n1
}

check_mount_flag() {
    if mount_flags "$1" | grep -q "$2"; then
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
UMOUNT_DONE="dev/binder dev/hwbinder dev/vndbinder dev/pts tmp sys poc dev"
FILE_ABS=$(realpath "$FILE")
DISTRO_NAME=$(echo "${FILE_ABS}" | sed 's/.*\///; s/\.[^.]*$//')
ROOTFS_PATH="${LOCAL_DIR}/${DISTRO_NAME}"
LOOP_PATH=$(losetup -j "${FILE_ABS}" | cut -d: -f1)
TMPFS_SIZE=500M
USE_NS_KERNEL=false
EXTERNAL_STORAGE_PARTS=""
image_directory="${PWD}/components"
GZ_CMD=""

if command -v zcat > /dev/null 2>&1; then
    GZ_CMD="zcat"
else
    if command -v gzip > /dev/null 2>&1; then
        GZ_CMD="gzip -dc"
    fi
fi

check_kernel_feature() {
    if [ -n "${GZ_CMD}" ]; then
        ${GZ_CMD} "${KERNEL_CONFIG}" 2>/dev/null | grep -Eq "^CONFIG_$1=(y|m)$"
    else
        return 1
    fi
}

if command -v getprop > /dev/null 2>&1; then
    log_print "i" "Device: $(getprop ro.product.model)"
    log_print "i" "Vendor: $(getprop ro.product.manufacturer)"
    log_print "i" "Android version: $(getprop ro.vendor.build.version.release)"
else
    log_print "i" "Possibly running outside Android. Ignoring"
fi

log_print "i" "Kernel: $(uname -r)"
log_print "i" "Terminal: $(get_term)"

[ -z "${GZ_CMD}" ] && log_print "-" "GZIP Utils required to check kernel. Ignoring"

# /proc/config.gz checking
if [ -f "${KERNEL_CONFIG}" ] && [ -n "${GZ_CMD}" ]; then
    log_print "+" "Checking kernel features"

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

    check_kernel_feature 'EXT2_FS' && log_print "+" "ext2 fileystem supported"
    check_kernel_feature 'EXT3_FS' && log_print "+" "ext3 fileystem supported"
    check_kernel_feature 'EXT4_FS' && log_print "+" "ext4 fileystem supported"
    check_kernel_feature 'F2FS_FS' && log_print "+" "f2fs fileystem supported"
    check_kernel_feature 'VXFS_FS' && log_print "+" "vxfs fileystem supported"
    check_kernel_feature 'XFS_FS' && log_print "+" "xfs fileystem supported"
    check_kernel_feature 'JFS_FS' && log_print "+" "jfs fileystem supported"
    check_kernel_feature 'SQUASHFS' && log_print "+" "squashfs fileystem supported"

    if check_kernel_feature 'SECURITY_SELINUX'; then
        # Fucking SE Linux
        if command -v getenforce > /dev/null 2>&1; then
            selinux_state=$(getenforce | tr '[:upper:]' '[:lower:]')
            log_lvl="+"
            log_state="All is oaky"
            if [ "${selinux_state}" = "enforcing" ]; then
                log_lvl="!"
                log_state="There may be problems"

            fi
            log_print "${log_lvl}" "SELinux in ${selinux_state} state. ${log_state}"
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

#
#  НАХУЙ!!! НЕ ИСПОЛЬЗОВАТЬ ЭТОТ КОД! ЛОМАЕТ ANDROID! ЭТО ВКЛЮЧАТЬ ОПАСНО!
#
# Checking internal /sdcard partition
#if [ -d "/storage/emulated/0" ]; then
#    log_print "+" "Found /sdcard partition, mounted to /mnt/sdcard"
#    mkdir -p "${ROOTFS_PATH}/mnt/sdcard"
#    mount -o bind /storage/emulated/0 "${ROOTFS_PATH}/mnt/sdcard"
#fi

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
                    log_print "+" "Found external storage at ${dir}, mounted to ${ROOTFS_PATH}/mnt/${base}"
                fi
            fi
        fi
    done
fi

# Монтирование дополнительных образов (если есть)
if [ -d "${image_directory}" ]; then
    for FILESYSTEM in squashfs ext4 ext3 ext2 xfs vxfs jffs2 f2fs jfs dir; do
        for IMAGE in "${image_directory}"/*."${FILESYSTEM}"; do
            [ -e "$IMAGE" ] || continue 
            
            base=$(basename "${IMAGE}")
            target_mount="${ROOTFS_PATH}/mnt/${base}"

            mkdir -p "$target_mount"
            
            if mount -t "${FILESYSTEM}" "$(realpath "$IMAGE")" "$target_mount" 2>/dev/null; then
                log_print "+" "Mounting loopback: $base"
                EXTERNAL_STORAGE_PARTS="${EXTERNAL_STORAGE_PARTS}${target_mount}
"
            else
                log_print "!" "Failed to mount $base"
            fi
        done
    done
fi

log_print "*" "Entering into chroot ${ROOTFS_PATH} as super user"
if [ -e "${ROOTFS_PATH}/bin/sudo" ]; then
    chroot "${ROOTFS_PATH}" /bin/sudo su
else
    chroot "${ROOTFS_PATH}" /bin/su -
fi

################ ЧИСТКА ТРУПОВ ################

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
    log_print "+" "Unmounting ${m}"
    umount "$m"
    if ! is_mounted "$m"; then
        rm -rf "$m"
    fi
done

for umnt_path in $UMOUNT_DONE; do
    [ -d "${ROOTFS_PATH}/${umnt_path}" ] && umount -l "${ROOTFS_PATH}/${umnt_path}"
    if ! is_mounted "${ROOTFS_PATH}/${umnt_path}"; then
        log_print "+" "Unmounting ${umnt_path}"
    else
        log_print "!" "Error umounting: ${umnt_path}"
    fi
done

umount -l "${ROOTFS_PATH}"
if ! is_mounted "${ROOTFS_PATH}"; then
    rm -rf "${ROOTFS_PATH}"
    if [ ! -d  "${ROOTFS_PATH}" ]; then
        log_print "+" "Directory ${ROOTFS_PATH} removed"
    else
        log_print "!" "RootFS cleanup error"
    fi
fi

sleep 1

#log_print "+" "Removing loopback device ${LOOP_PATH}"
if [ -b "${LOOP_PATH}" ]; then
    losetup -d "${LOOP_PATH}" 2>/dev/null || log_print "!" "Loopback busy, will be cleared on reboot. Strange"
fi

log_print "+" "Syncing"
sync

log_print "+" "Done"
echo "Return to shell\n\n"
