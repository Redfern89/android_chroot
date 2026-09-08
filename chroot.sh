#!/usr/bin/env sh

ROOTFS_FULL=$(realpath "$1")
ROOTFS_BASE=$(basename "$1")
PWD=$(cd "$(dirname "$0")" && pwd)

if [ -f "${PWD}/banner" ]; then
	sh "${PWD}/banner" "chroot mount"
fi

. "${PWD}/misc-helpers.sh"

log_print "i" "Running as: $(whoami)"

if ! check_root; then
	log_print "!" "Not root. Aborted"
	exit 1
fi

# Настройки окружения
export PATH=$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
#export USER=root
#export HOME=/root
export TERM=xterm-256color
export PS1="(chroot) ${PS1}"

# Параметры и переменные
DEBUG="true"
DEF_HOST=fck-phone
TMPFS_SIZE=500M
LOCAL_DIR="/data/local"
KERNEL_CONFIG_FILE=""
SHELLS="sh ash bash zsh"
CLEANUP_DIRS="home/* root"
BIND_FS_PATHS="dev dev/pts sys proc"
FILES_TO_REMOVE=".bash_history .zsh_history .zcompdump .local/share/mc/history"
DIRS_TO_REMOVE=".cache .ssh"
ABS_DIRS_TO_REMOVE="var/lib/apt/lists"
HAL_BINDERS="binder hwbinder vndbinder"
CLEANUP_BINDERS="dev/binder dev/hwbinder dev/vndbinder dev/pts tmp sys proc dev"
EXTERNAL_STORAGE_PARTS=""
USE_LOOP_DEV=""
LOOP_MOUNT_POINT="/data/local"
KERNEL_CHECK_FEATURE_CMD=""
ROOTFS_PATH=""
SHELLS="sh bash zsh su"
FOUND_SHELLS=""
SHELL_COUNT=0
USERS_COUNT=0
IS_ANDROID="false"

[ -f "$ROOTFS_FULL" ] && USE_LOOP_DEV="true"
[ -d "$ROOTFS_FULL" ] && USE_LOOP_DEV="false"
[ -d "$ROOTFS_FULL" ] && ROOTFS_PATH="$ROOTFS_FULL"

if [ -z "$USE_LOOP_DEV" ]; then
	log_print "!" "Path ${ROOTFS_FULL} is not blockdevice or rootfs directory. Aborted"
	exit 1
fi

[ "${USE_LOOP_DEV}" = "true" ] && log_print "i" "Input file: ${ROOTFS_BASE}, size=$(du -sh ${ROOTFS_FULL} | cut -f1)"

if check_util getprop; then
	IS_ANDROID="true"
	log_print "i" "Device: $(getprop ro.product.model) ($(getprop ro.product.product.device))"
	log_print "i" "Vendor: $(getprop ro.product.manufacturer)"
	log_print "i" "Android version: $(getprop ro.vendor.build.version.release)"
else
	log_print "-" "Possibly running outside Android. Ignoring"
fi

if [ -f "${PWD}/android" ] && [ "${IS_ANDROID}" = "true" ]; then
	sh "${PWD}/android"
fi

if check_util magisk; then
	log_print "i" "Magisk version: $(magisk -v)"
fi

log_print "i" "Arch: $(uname -m)"
log_print "i" "CPU: $(get_cpu)"
log_print "i" "Kernel: $(uname -r)"
log_print "i" "Utils: $(get_coreutils)"
log_print "i" "Terminal: $(get_term)"
log_print "i" "Fetching shell colors $(fetch_shell_colors)"

if [ -f "/boot/config-$(uname -r)" ]; then
	KERNEL_CHECK_FEATURE_CMD="cat"
	KERNEL_CONFIG_FILE="/boot/config-$(uname -r)"
elif [ -f "/proc/config.gz" ]; then
	KERNEL_CONFIG_FILE="/proc/config.gz"

	if check_util zcat; then
		KERNEL_CHECK_FEATURE_CMD="zcat"
	elif check_util gzip; then
		KERNEL_CHECK_FEATURE_CMD="gzip -dc"
	fi
fi

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

if [ "${IS_ANDROID}" = "true" ]; then
	if check_kernel_feature 'SECURITY_SELINUX'; then
		# Fucking SE Linux
		if check_util getenforce; then
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
fi

if [ "${USE_LOOP_DEV}" = "true" ]; then
	if ! check_util losetup; then
		log_print "!" "losetup unavilable. Aborted"
		exit 1
	fi

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
			log_print "-" "Mountpoint ${TARGET_MOUNT} is busy. Fucked strange."
			BUSY_MNT=$(get_mountpoint_by_dev "${LOOP_PATH}")
			if [ "${BUSY_MNT}" = "${TARGET_MOUNT}" ]; then
				ROOTFS_PATH="${TARGET_MOUNT}"
				log_print "+" "Mountpoint ${TARGET_MOUNT} used by ${LOOP_PATH}, okay"
			else
				log_print "!" "Mountpoint ${TARGET_MOUNT} used by ${LOOP_PATH}. Aborted"
				exit 1
			fi
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
if [ "${IS_ANDROID}" = "true" ]; then
	log_print "i" "Masking HAL binders"
	for HAL_BINDER in $HAL_BINDERS; do
		if [ -e "/dev/${HAL_BINDER}" ]; then
			mount -t tmpfs tmpfs -o mode=000 ${ROOTFS_PATH}/dev/${HAL_BINDER} 2>/dev/null
			echo "    [${HAL_BINDER}]"
		else
			log_print "-" "HAL Binder '${HAL_BINDER}' not found, ignoring"
		fi
	done
fi

# tmpfs
if ! is_mounted "${ROOTFS_PATH}/tmp"; then
	mount -t tmpfs -o size="${TMPFS_SIZE}" tmpfs "${ROOTFS_PATH}/tmp"
	if is_mounted "${ROOTFS_PATH}/tmp"; then
		log_print "+" "Mounted tmpfs at ${ROOTFS_PATH}/tmp (size=${TMPFS_SIZE})"
	fi
else
	log_print "-" "${ROOTFS_PATH}/tmp was mounted before. Fucking strange. Skipping"
fi


# НАХУЙ!!!! ЛОМАЕТ ВСЕ!!!
# Checking internal storage
#if [ -d /storage/emulated ]; then
#	if [ ! -d "${ROOTFS_PATH}/mnt/emulated" ]; then
#		mkdir "${ROOTFS_PATH}/mnt/emulated"
#	fi
#	mount -o bind /storage/emulated "${ROOTFS_PATH}/mnt/emulated"
#fi

# Checking external SD Card partitions
if [ -d "/storage" ]; then
	for dir in /storage/*; do
		base=$(basename "${dir}")
		if [ "${base}" != "emulated" ] && [ "${base}" != "self" ]; then
			if [ -d "${dir}" ]; then
				mkdir -p "${ROOTFS_PATH}/mnt/${base}"
				if ! is_mounted "${ROOTFS_PATH}/mnt/${base}"; then
					mount -o bind "${dir}" "${ROOTFS_PATH}/mnt/${base}"
					if is_mounted "${ROOTFS_PATH}/mnt/${base}"; then
						EXTERNAL_STORAGE_PARTS="${EXTERNAL_STORAGE_PARTS}${ROOTFS_PATH}/mnt/${base}"
						log_print "+" "Found external storage at ${dir}, mounted to /mnt/${base}"
					fi
				else
					log_print "-" "${dir} was mounted before. Fucking strange."
				fi
			fi
		fi
	done
fi

log_print "+" "Found hosts in this rootfs"
get_rootfs_hosts "${ROOTFS_PATH}"

if GET_HOSTNAME=$(get_rootfs_hostname "${ROOTFS_PATH}" 2>/dev/null); then
	DEF_HOST="${GET_HOSTNAME}"
fi

trap cleanup INT TERM HUP EXIT

log_print "?" "Enter hostname (default: ${DEF_HOST}): " true
while true; do
	read -r HOSTNAME

	if [ ! -z "${HOSTNAME}" ]; then
		export HOST="${HOSTNAME}"
		break
	else
		HOSTNAME="${DEF_HOST}"
		export HOST="${HOSTNAME}"
		break
	fi
done

set_rootfs_hostname "${ROOTFS_PATH}" "${HOSTNAME}"
log_print "+" "Hostname set to: ${HOSTNAME}"

cleanup() {
	trap - EXIT INT TERM HUP

	log_print "i" "Cleaning chroot rootfs temporary files"
	for pattern in ${CLEANUP_DIRS}; do
		for user_dir in "${ROOTFS_PATH}/"${pattern}; do
			[ ! -d "${user_dir}" ] && continue

			[ "${DEBUG}" = "true" ] && log_print "D" "Found dir: ${user_dir}"

			for rm_dir in ${DIRS_TO_REMOVE}; do
				if [ -d "${user_dir}/${rm_dir}" ]; then
				rm -rf "${user_dir}/${rm_dir}"
					[ ! -d "${user_dir}/${rm_dir}" ] && log_print "+" "Removed ${user_dir}/${rm_dir}"
					[ -d "${user_dir}/${rm_dir}" ] && log_print "W" "${user_dir}/${rm_dir} not removed. WTF???"
				fi
			done

			for file_pattern in ${FILES_TO_REMOVE}; do
				for target in "${user_dir}"/${file_pattern}*; do
					
					if [ -f "${target}" ]; then
						rm -f "${target}"
						[ ! -f "${target}" ] && log_print "+" "Removed ${target}"
						[ -f "${target}" ] && log_print "W" "${target} not removed. WTF???"
					fi
					
				done
			done
		done
	done
	
	log_print "i" "killing all chroot tails (running lsof)"
	#pids=$(lsof | grep "${ROOTFS_PATH}" | awk '{ print $2 }' | sort -u) # THIS IS A FUCKED CONTRUCTION
	pids=$(lsof -t +D "${ROOTFS_PATH}")

	if [ -n "${pids}" ]; then
		log_print "i" "Killing pids: (${pids})"
		#kill -9 ${pids} 2>/dev/null # THIS IS A VERY FUCKED FRAGILE CONTRUCTION
		echo "${pids}" | xargs kill -9 2>/dev/null

		sleep 1
		log_print "+" "Done"
	fi

	echo "$EXTERNAL_STORAGE_PARTS" | while IFS= read -r m; do
		[ -z "$m" ] && continue
		if [ -d "$m" ]; then
			log_print "+" "Cleanup ${m}"
			umount "$m"
			if ! is_mounted "$m"; then
				rm -rf "$m"
			fi
		else
			log_print "W" "Directory ${m} does not exists. WTF??!"
		fi
	done

	for umnt_path in $CLEANUP_BINDERS; do
		if [ -d "${ROOTFS_PATH}/${umnt_path}" ]; then
			umount -l "${ROOTFS_PATH}/${umnt_path}"
			if ! is_mounted "${ROOTFS_PATH}/${umnt_path}"; then
				log_print "+" "Cleanup ${ROOTFS_PATH}/${umnt_path}"
			else
				log_print "!" "Error umounting: ${umnt_path}"
			fi
		else
			log_print "W" "Directory ${ROOTFS_PATH}/${umnt_path} does not exists. WTF??!"
		fi
	done

	if [ "${USE_LOOP_DEV}" = "true" ]; then
		if [ -d "${ROOTFS_PATH}" ]; then
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
		else
			log_print "W" "Directory ${ROOTFS_PATH} does not exist. WTF??!"
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
	printf "Return to shell\n\n\n"

	exit 0
}


log_print "@" "Select shell to use"
for user in $(grep -Ff "${ROOTFS_PATH}/etc/shells" "${ROOTFS_PATH}/etc/passwd" | cut -d: -f1); do
	USERS_COUNT=$((USERS_COUNT + 1))
	echo "    ${USERS_COUNT}. ${user}"

	FOUND_USERS="$FOUND_USERS $user"
done

if [ "$USERS_COUNT" -eq 0 ]; then
	log_print "!" "No users found! Trying root anyway..."
	SELECTED_USER="root"
elif [ "$SHELL_COUNT" -eq 1 ]; then
	SELECTED_USER=$(echo "$FOUND_USERS" | xargs)
else   
	while true; do
		log_print "?" "Choice (1-$USERS_COUNT): " true
		read -r CHOICE
		
		case "$CHOICE" in
			*[!0-9]* | "")
				continue
				;;
		esac

		SELECTED_USER=$(echo "$FOUND_USERS" | cut -d' ' -f"$((CHOICE + 1))")

		if [ ! -z "$SELECTED_USER" ]; then
		   #log_print "*" "Entering into chroot ${ROOTFS_PATH} with $SELECTED_SHELL"
		   break
		fi
	done
fi

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
		   log_print "*" "Entering into chroot ${ROOTFS_PATH} with $SELECTED_SHELL as ${SELECTED_USER}"
		   break
		fi
	done
	
	if [ ! -z "$SELECTED_SHELL" ] && [ -x "${ROOTFS_PATH}/${SELECTED_SHELL}" ]; then
		chroot "${ROOTFS_PATH}" runuser -u "$SELECTED_USER" -- "$SELECTED_SHELL"
	else
		log_print "!" "Failed to find shell. Aborted"
		exit 1
	fi
fi
