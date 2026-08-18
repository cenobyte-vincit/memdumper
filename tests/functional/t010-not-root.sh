#!/usr/bin/env bash
#
# t010-not-root.sh - attach.sh must refuse a non-root caller before exec.
#
# Starts hold-string so the PID and Hardened Runtime checks pass, then
# invokes attach.sh as a non-root user. Expects "root required" and no
# constructor output. Exits 77 (skip) if the suite is already uid 0.
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

	[[ "$(id -u)" -eq 0 ]] && \
		skip_already_root

	local out=""
	local rc=0

	trap '[ -n "${FIXTURE_PID:-}" ] && kill "${FIXTURE_PID}" 2>/dev/null || true' EXIT

	"${HOLD_STRING_BIN}" &
	FIXTURE_PID=$!
	sleep 1
	! kill -0 "${FIXTURE_PID}" 2>/dev/null && \
		errx "fixture died before attach"

	out="$(cd "${REPO_ROOT}" && \
	    "${ATTACH_SH}" -p "${FIXTURE_PID}" /usr/bin/true 2>&1)" || rc=$?

	kill "${FIXTURE_PID}" 2>/dev/null || true
	wait "${FIXTURE_PID}" 2>/dev/null || true
	FIXTURE_PID=""
	trap - EXIT

	[[ "${rc}" -eq 0 ]] && \
		errx "expected non-zero exit, got 0: ${out}"
	[[ ! "${out}" =~ root\ required ]] && \
		errx "output missing 'root required': ${out}"
	[[ "${out}" =~ \[MEMDUMPER\] ]] && \
		errx "constructor ran; expected refusal before exec: ${out}"

	echo "PASS ${__progname}"
}

main "$@"
