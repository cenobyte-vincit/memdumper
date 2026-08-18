#!/usr/bin/env bash
#
# t006-missing-dylib.sh - attach.sh without memdumper.dylib in cwd must fail.
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

	local tmpdir=""
	local rc=0
	local out=""

	tmpdir="$(mktemp -d "/tmp/${__progname}.XXXXXX")"
	[ -d "${tmpdir}" ] || \
		errx "mktemp -d"

	out="$(cd "${tmpdir}" && \
	    "${ATTACH_SH}" -p 1 /usr/bin/true 2>&1)" || rc=$?
	rm -rf -- "${tmpdir}"

	[[ "${rc}" -eq 0 ]] && \
		errx "expected non-zero exit, got 0"
	[[ ! "${out}" =~ memdumper.dylib\ not\ found ]] && \
		errx "output missing 'memdumper.dylib not found': ${out}"

	echo "PASS ${__progname}"
}

main "$@"
