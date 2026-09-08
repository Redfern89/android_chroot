#!/usr/bin/env sh

ROOTFS_FULL=$(realpath "${1}")
ROOTFS_BASE=$(basename "${1}")
FORMAT="${2}"
PWD=$(cd "$(dirname "$0")" && pwd)
BUILD_DIR=$(realpath "${ROOTFS_FULL}/${ROOTFS_BASE}-build")

[ -z "${FORMAT}" ] && FORMAT=squashfs

BUILD_FILE_PATH="${BUILD_DIR}/filesystem.${FORMAT}" 

. "${PWD}"/misc-helpers.sh

if [ -f "${PWD}/banner" ]; then
    sh "${PWD}/banner" "live build"
fi

if ! is_rootfs "${ROOTFS_FULL}"; then
    log_print "!" "${ROOTFS_FULL} is not a RootFS"
    exit 1
fi

log_print "i" "Running as: $(whoami)"
if ! check_root; then
    log_print "!" "Not root. Aborted"
    exit 1
fi
log_print "i" "Rootfs: $(get_rootfs_name ${ROOTFS_FULL})"

if [ ! -d "${BUILD_DIR}" ]; then
    mkdir "${BUILD_DIR}"
fi

if [ -d "${ROOTFS_FULL}/boot" ]; then
    log_print "i" "Checking /boot in RootFS"

    for file in "${ROOTFS_FULL}"/boot/*; do
        boot_file=$(basename "${file}")
        
        case "${boot_file}" in
            vmlinuz*)
                log_print "+" "Found kernel: ${boot_file} ($(get_size "${file}"))"
                cp "${file}" "${BUILD_DIR}/${boot_file}"
                ;;
            initrd*)
                log_print "+" "Found initrd: ${boot_file} ($(get_size "${file}"))"
                cp "${file}" "${BUILD_DIR}/${boot_file}"
                ;;
        esac
    done
else
    log_print "-" "/boot directory not found. Kernel unavailable"
fi

if check_util mksquashfs && [ "${FORMAT}" = squashfs ]; then
    build_dir="${ROOTFS_BASE}-build"
    
    for file in squashfs packages; do
        if [ -f "${BUILD_DIR}/filesystem.${file}" ]; then
            log_print "W" "Removed existing file filesystem.${file}"
            rm -f ${BUILD_DIR}/filesystem.${file}
        fi
    done

    chroot "${ROOTFS_FULL}" dpkg-query -W -f='${Package} ${Version}\n' > "${BUILD_DIR}/filesystem.packages"
    if [ -f "${BUILD_DIR}/filesystem.packages" ]; then
        log_print "+" "Created ${BUILD_DIR}/filesystem.packages"
    else
        log_print "!" "${BUILD_DIR}/filesystem.packages not created. Very fucked strange. Aborted"
        exit 1
    fi

    log_print "*" "Running mksquashfs with XZ compression"
    mksquashfs "${ROOTFS_FULL}" "${BUILD_FILE_PATH}" -e boot "${build_dir}"
    if [ -f "${BUILD_FILE_PATH}" ]; then
        log_print "+" "${BUILD_FILE_PATH} created"
        echo ""
        log_print "+" "Live system created at ${BUILD_DIR}"
    else
        log_print "!" "Failed to create root system"
        exit 1
    fi
fi

