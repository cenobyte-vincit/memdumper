#!/usr/bin/env bash
#
# t004-missing-command.sh - PID without an entitled binary must fail.
#
set -euo pipefail
IFS=$'\n\t'

# shellcheck disable=SC2155
readonly __progname="$(basename "${BASH_SOURCE[0]}")"
readonly PATH="/usr/sbin:/usr/bin:/sbin:/bin"

errx() {
	echo -e "${__progname}: $*" >&2

	exit 1
}

main() {
	[[ -z "${ATTACH_SH:-}" ]] && \
		errx "ATTACH_SH not set"
	[[ -z "${REPO_ROOT:-}" ]] && \
		errx "REPO_ROOT not set"

	local rc=0
	local out=""

	out="$(cd "${REPO_ROOT}" && "${ATTACH_SH}" -p 1 2>&1)" || rc=$?

	[[ "${rc}" -eq 0 ]] && \
		errx "expected non-zero exit, got 0"
	[[ ! "${out}" =~ command\ required ]] && \
		errx "output missing 'command required': ${out}"

	echo "PASS ${__progname}"
}

main "$@"
