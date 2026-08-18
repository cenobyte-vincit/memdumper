#!/usr/bin/env bash
#
# t002-unknown-flag.sh - Unknown flag must fail before any attach.
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

	local rc=0
	local out=""

	out="$("${ATTACH_SH}" --not-a-flag 2>&1)" || rc=$?

	[[ "${rc}" -eq 0 ]] && \
		errx "expected non-zero exit, got 0"
	[[ ! "${out}" =~ unknown\ option ]] && \
		errx "output missing 'unknown option': ${out}"

	echo "PASS ${__progname}"
}

main "$@"
