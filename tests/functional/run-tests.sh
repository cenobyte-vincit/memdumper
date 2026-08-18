#!/usr/bin/env bash
#
# run-tests.sh - Run memdumper functional tests in order.
#
# Usage: ./tests/functional/run-tests.sh
# Requires macOS. Runs from the repository root (memdumper.dylib in cwd
# for attach.sh). Exports REPO_ROOT, ATTACH_SH, HOLD_STRING_BIN, NEEDLE.
# Stops only after a full summary; exits 1 if any scenario fails.
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

# Resolve a path to an absolute path (must already exist).
abs_path() {
	local -r raw="${1}"

	if [[ "${raw}" = /* ]]; then
		echo "${raw}"
		return 0
	fi

	echo "$(cd "$(dirname "${raw}")" && pwd)/$(basename "${raw}")"
}

main() {
	[[ "$#" -ne 0 ]] && \
		errx "usage: ${__progname}"

	[[ ! "$(uname -s)" =~ ^Darwin ]] && \
		errx "macOS (Darwin) required"

	for bin in find sort tail codesign mktemp grep kill sleep ps; do
		! command -v "${bin}" >/dev/null 2>&1 && \
			errx "cannot find '${bin}' in 'PATH=${PATH}'"
	done

	local -r testdir="$(cd "$(dirname "${__script_path}")" && pwd)"
	local -r repo_root="$(cd "${testdir}/../.." && pwd)"
	local -r attach="${repo_root}/attach.sh"
	local -r dylib="${repo_root}/memdumper.dylib"
	local -r hold="${testdir}/fixtures/hold-string"

	[[ ! -x "${attach}" ]] && \
		errx "not executable: ${attach}"
	[[ ! -f "${dylib}" ]] && \
		errx "missing ${dylib}: run make first"
	[[ ! -x "${hold}" ]] && \
		errx "hold-string fixture missing: ${hold}"

	export REPO_ROOT ATTACH_SH HOLD_STRING_BIN NEEDLE
	REPO_ROOT="${repo_root}"
	ATTACH_SH="$(abs_path "${attach}")"
	HOLD_STRING_BIN="$(abs_path "${hold}")"
	NEEDLE="MEMDUMPER_FIXTURE_NEEDLE_9f3a"

	local passed=0
	local failed=0
	local skipped=0
	local t=""
	local rc=0
	local base=""

	cd "${repo_root}"

	shopt -s nullglob
	for t in "${testdir}"/t[0-9][0-9][0-9]-*.sh; do
		base="$(basename "${t}")"
		[[ ! -x "${t}" ]] && \
			errx "scenario not executable: ${t}"

		rc=0
		"${t}" || rc=$?
		if [[ "${rc}" -eq 0 ]]; then
			passed=$((passed + 1))
		elif [[ "${rc}" -eq 77 ]]; then
			skipped=$((skipped + 1))
		else
			echo "FAIL ${base}"
			failed=$((failed + 1))
		fi
	done
	shopt -u nullglob

	echo ""
	echo "summary: ${passed} passed, ${failed} failed, ${skipped} skipped"

	[[ "${failed}" -ne 0 ]] && \
		exit 1

	[[ "${passed}" -eq 0 && "${skipped}" -eq 0 ]] && \
		errx "no scenario scripts found under ${testdir}"

	exit 0
}

main "$@"
