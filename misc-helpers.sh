#!/usr/bin/env sh

log_print() {
	color="\033[0m"

	[ "$1" = "+" ] && color="\033[1;32m"
	[ "$1" = "-" ] && color="\033[1;35m"
	[ "$1" = "!" ] && color="\033[1;31m"
	[ "$1" = "i" ] && color="\033[0;36m"
	[ "$1" = "?" ] && color="\033[1;36m"
	[ "$1" = "*" ] && color="\033[1;33m"
	[ "$1" = "@" ] && color="\033[1;34m"
	[ "$1" = "D" ] && color="\033[1;30m"
    [ "$1" = "W" ] && color="\033[1;33m"

	if [ "$3" = true ]; then
		echo -n "${color}[${1}]\033[0m $2"
	else
		echo "${color}[${1}]\033[0m $2"
	fi
}

get_size() {
	local file="${1}"
	du -h "${file}" | awk '{print $1}'
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

is_rootfs() {
    local rootfs_path="${1}"
    
    [ ! -d "${rootfs_path}" ] && return 1

    for dir in home sys dev proc tmp; do
        if [ ! -d "${rootfs_path}/${dir}" ]; then
            return 1
        fi
    done

    return 0
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        return 1
    fi

    return 0
}

check_util() {
    if command -v "${1}" > /dev/null 2>&1; then
        return 0
    fi

    return 1
}

check_kernel_feature() {
	if [ -n "${KERNEL_CHECK_FEATURE_CMD}" ]; then
		${KERNEL_CHECK_FEATURE_CMD} "${KERNEL_CONFIG_FILE}" 2>/dev/null | grep -Eq "^CONFIG_$1=(y|m)$"
	else
		return 1
	fi
}

get_mountpoint_by_dev() {
	grep "^$1[[:space:]]" /proc/mounts | head -n1 | cut -d' ' -f2
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


get_rootfs_hostname() {
	local rootfs="${1}"
	local hostname_file="${rootfs}/etc/hostname"

	if [ -f "${hostname_file}" ]; then
		tr -d '[:space:]' < "${hostname_file}"
	else
		return 1
	fi
}

get_rootfs_hosts() {
	local rootfs="${1}"
	local hosts_file="${rootfs}/etc/hosts"

	if [ -f "${hosts_file}" ]; then
		while IFS= read -r line; do
			[ -z "${line}" ] && continue
				
			case "${line}" in
				"#"*) continue ;;
			esac

			local ip=$(echo "${line}" | awk -F ' ' '{ print $1 }')
			local host=$(echo "${line}" | awk -F ' ' '{ print $2 }')
				
			[ "${ip}" = "127.0.1.1" ] && log_print "i" "Fund hostname: ${host}"

		done < "${hosts_file}"
	fi
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

set_rootfs_hostname() {
	local rootfs="${1}"
	local set_hostname="${2}"

	local hostname_file="${rootfs}/etc/hostname"
	local hosts_file="${rootfs}/etc/hosts"

	local host_exists=false

	if [ -d "${rootfs}/etc" ]; then
		echo "${set_hostname}" > "${hostname_file}"
	fi

	if [ -f "${hosts_file}" ]; then
		while IFS= read -r line; do
			[ -z "${line}" ] && continue
			
			case "${line}" in
				"#"*) continue ;;
			esac

			local ip=$(echo "${line}" | awk -F ' ' '{ print $1 }')
			local host=$(echo "${line}" | awk -F ' ' '{ print $2 }')
			
			[ "${host}" = "${set_hostname}" ] && [ "${ip}" = "127.0.1.1" ] && host_exists=true

		done < "${hosts_file}"
	else
		# Default hosts file with set hostname
		cat << EOF > "${hosts_file}"
127.0.0.1       localhost
127.0.1.1       ${set_hostname}

# The following lines are desirable for IPv6 capable hosts
::1             localhost ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
EOF
	fi

	if [ "${host_exists}" = false ]; then
		echo "127.0.1.1\t${set_hostname}" >> "${hosts_file}"
	fi
}

fetch_shell_colors() {
    for i in $(seq 0 15); do
        [ $i -lt 8 ] && color_code=$((40 + i)) || color_code=$((100 + i - 8))
        echo -n "\033[${color_code}m   \033[0m"
        [ $i -eq 7 ] && echo ""
    done
    echo ""
}