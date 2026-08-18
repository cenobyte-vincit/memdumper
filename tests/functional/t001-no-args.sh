#!/usr/bin/env bash
#
# t001-no-args.sh - Bare attach.sh must print usage and fail.
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
	[[ ! -x "${ATTACH_SH}" ]] && \
		errx "not executable: ${ATTACH_SH}"

	local rc=0
	local out=""

	out="$("${ATTACH_SH}" 2>&1)" || rc=$?

	[[ "${rc}" -eq 0 ]] && \
		errx "expected non-zero exit, got 0"
	[[ ! "${out}" =~ Usage: ]] && \
		errx "output missing 'Usage:': ${out}"

	echo "PASS ${__progname}"
}

main "$@"
