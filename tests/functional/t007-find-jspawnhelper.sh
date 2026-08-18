#!/usr/bin/env bash
#
# t007-find-jspawnhelper.sh - Locate jspawnhelper under Homebrew Cellar.
#
# Uses find(1) on /opt/homebrew/Cellar and /usr/local/Cellar. No version
# pin. Checks the three entitlements the insert needs. Exits 77 (skip)
# if no helper is installed.
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
	local -r testdir="$(cd "$(dirname "${__script_path}")" && pwd)"
	# shellcheck source=tests/functional/lib/common.sh
	source "${testdir}/lib/common.sh"

	local helper=""
	local ents=""

	helper="$(find_jspawnhelper)" || \
		skip_no_jspawnhelper
	[ ! -f "${helper}" ] && \
		errx "find_jspawnhelper returned a missing path: ${helper}"

	ents="$(codesign -d --entitlements - "${helper}" 2>&1)"
	[[ ! "${ents}" =~ com.apple.security.cs.debugger ]] && \
		errx "missing debugger entitlement: ${helper}"
	[[ ! "${ents}" =~ com.apple.security.cs.allow-dyld-environment-variables ]] && \
		errx "missing allow-dyld-environment-variables: ${helper}"
	[[ ! "${ents}" =~ com.apple.security.cs.disable-library-validation ]] && \
		errx "missing disable-library-validation: ${helper}"

	echo "PASS ${__progname} (${helper})"
}

main "$@"
