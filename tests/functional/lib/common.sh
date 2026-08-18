# shellcheck shell=bash
#
# common.sh - Shared helpers for memdumper functional tests.
#
# Sourced by scenario scripts. Do not execute. Omits set -euo pipefail so
# it does not change the caller's shell options. Locates jspawnhelper with
# find(1) under Homebrew Cellar prefixes; no version pin.
#

# Print one jspawnhelper path from /opt/homebrew or /usr/local Cellar.
# Prefers the last sorted path in the first prefix that has a hit.
find_jspawnhelper() {
	local prefix cellar candidate
	local found=""

	for prefix in /opt/homebrew /usr/local; do
		cellar="${prefix}/Cellar"
		[ ! -d "${cellar}" ] && \
			continue
		candidate="$(find "${cellar}" -name jspawnhelper -type f \
		    2>/dev/null | sort | tail -n 1)"
		[ -z "${candidate}" ] && \
			continue
		found="${candidate}"
		break
	done

	[ -z "${found}" ] && \
		return 1
	printf '%s\n' "${found}"
}

# Print SKIP and exit 77. Call from the test process, not from $().
skip_no_jspawnhelper() {
	echo "SKIP ${__progname:-test} (jspawnhelper not found under /opt/homebrew/Cellar or /usr/local/Cellar)"
	exit 77
}

# Live inject needs uid 0 so attach.sh does not refuse and taskgated
# does not present Developer Tool Access.
skip_not_root() {
	echo "SKIP ${__progname:-test} (root required for live inject)"
	exit 77
}

# The non-root refusal cannot be exercised while already uid 0.
skip_already_root() {
	echo "SKIP ${__progname:-test} (already uid 0)"
	exit 77
}
