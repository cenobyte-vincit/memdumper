#!/usr/bin/env bash
#
# t009-dump-jspawnhelper.sh - Dump fixture regions via found jspawnhelper.
#
# Starts hold-string, finds jspawnhelper under Homebrew Cellar, injects
# memdumper.dylib without -s, and asserts the region hex-dump path.
# A successful insert exits 0; jspawnhelper must not reach main.
# Exits 77 (skip) if no helper is installed or the suite is not uid 0.
#
set -euo pipefail
IFS=$'\n\t'

readonly __script_path="${BASH_SOURCE[0]}"
# shellcheck disable=SC2155
readonly __progname="$(basename "${__script_path}")"
readonly PATH="/usr/sbin:/usr/bin:/sbin:/bin"

errx() {
	echo -e "${__progname}: $*" >&2

	exit 1
}

main() {
	[[ -z "${REPO_ROOT:-}" ]] && \
		errx "REPO_ROOT not set"
	[[ -z "${ATTACH_SH:-}" ]] && \
		errx "ATTACH_SH not set"
	[[ -z "${HOLD_STRING_BIN:-}" ]] && \
		errx "HOLD_STRING_BIN not set"
	[[ ! -x "${HOLD_STRING_BIN}" ]] && \
		errx "not executable: ${HOLD_STRING_BIN}"

	local -r testdir="$(cd "$(dirname "${__script_path}")" && pwd)"
	# shellcheck source=tests/functional/lib/common.sh
	source "${testdir}/lib/common.sh"

	local helper=""
	local out=""
	local rc=0

	[[ "$(id -u)" -ne 0 ]] && \
		skip_not_root

	helper="$(find_jspawnhelper)" || \
		skip_no_jspawnhelper

	trap '[ -n "${FIXTURE_PID:-}" ] && kill "${FIXTURE_PID}" 2>/dev/null || true' EXIT

	"${HOLD_STRING_BIN}" &
	FIXTURE_PID=$!
	sleep 1
	! kill -0 "${FIXTURE_PID}" 2>/dev/null && \
		errx "fixture died before attach"

	out="$(cd "${REPO_ROOT}" && \
	    "${ATTACH_SH}" -n 5 -p "${FIXTURE_PID}" \
	    "${helper}" 2>&1)" || rc=$?

	[[ "${rc}" -ne 0 ]] && \
		errx "expected exit 0, got ${rc}: ${out}"
	[[ "${out}" =~ \[MEMORY\ SEARCH\] ]] && \
		errx "search path ran; expected dump (attach rc=${rc}): ${out}"
	[[ ! "${out}" =~ \[MEMORY\ DUMP\] ]] && \
		errx "no [MEMORY DUMP] in output (attach rc=${rc}): ${out}"
	[[ ! "${out}" =~ Region\  ]] && \
		errx "no Region line (attach rc=${rc}): ${out}"
	[[ ! "${out}" =~ prot: ]] && \
		errx "no prot: line (attach rc=${rc}): ${out}"
	[[ ! "${out}" =~ Read\  ]] && \
		errx "no Read line (attach rc=${rc}): ${out}"
	[[ ! "${out}" =~ \[RESULT\] ]] && \
		errx "no [RESULT] line (attach rc=${rc}): ${out}"
	[[ "${out}" =~ Incorrect\ number\ of\ arguments ]] && \
		errx "entitled binary reached main: ${out}"
	[[ "${out}" =~ not\ for\ general\ use ]] && \
		errx "entitled binary reached main: ${out}"

	kill "${FIXTURE_PID}" 2>/dev/null || true
	wait "${FIXTURE_PID}" 2>/dev/null || true
	FIXTURE_PID=""
	trap - EXIT

	echo "PASS ${__progname}"
}

main "$@"
