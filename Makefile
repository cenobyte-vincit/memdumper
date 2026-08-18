CC =		clang
CFLAGS =	-std=c17 -Wall -Wextra -Werror -pedantic
LDFLAGS =	-dynamiclib -framework CoreFoundation
CPPCHECK ?=	cppcheck

TARGETS =	memdumper.dylib
HOLD_STRING =	tests/functional/fixtures/hold-string
HOLD_SRC =	tests/functional/fixtures/hold-string.c
UNIT_BINS =	tests/unit/test-parse
TEST_SCRIPTS =	tests/functional/run-tests.sh \
		tests/functional/t001-no-args.sh \
		tests/functional/t002-unknown-flag.sh \
		tests/functional/t003-missing-pid.sh \
		tests/functional/t004-missing-command.sh \
		tests/functional/t005-dead-pid.sh \
		tests/functional/t006-missing-dylib.sh \
		tests/functional/t007-find-jspawnhelper.sh \
		tests/functional/t008-search-jspawnhelper.sh \
		tests/functional/t009-dump-jspawnhelper.sh \
		tests/functional/t010-not-root.sh
SH_SCRIPTS =	attach.sh ${TEST_SCRIPTS}

.PHONY: all clean check lint check-cppcheck check-shellcheck \
	test test-unit test-functional

all: ${TARGETS} check

memdumper.dylib: memdumper.c
	${CC} ${CFLAGS} ${LDFLAGS} -o $@ memdumper.c

${HOLD_STRING}: ${HOLD_SRC}
	${CC} ${CFLAGS} -o $@ ${HOLD_SRC}

tests/unit/test-parse: tests/unit/test-parse.c memdumper.c
	${CC} ${CFLAGS} -o $@ tests/unit/test-parse.c

check-cppcheck:
	@command -v ${CPPCHECK} >/dev/null 2>&1 || { \
		echo "cppcheck not found: install it (see README)" >&2; exit 1; }
	${CPPCHECK} --enable=warning,performance,portability \
		--error-exitcode=1 -I. memdumper.c ${HOLD_SRC}

check-shellcheck:
	@command -v shellcheck >/dev/null 2>&1 || { \
		echo "shellcheck not found: install it (see README)" >&2; exit 1; }
	shellcheck -e SC2155 attach.sh
	shellcheck -x ${TEST_SCRIPTS} tests/functional/lib/common.sh
	@for s in ${SH_SCRIPTS}; do bash -n "$$s" || exit 1; done

lint: check-cppcheck check-shellcheck
check: lint

test-unit: ${UNIT_BINS}
	@for t in ${UNIT_BINS}; do \
		echo "==> $$t"; \
		./$$t || exit 1; \
	done

test-functional: ${TARGETS} ${HOLD_STRING}
	@./tests/functional/run-tests.sh

test: test-unit test-functional

clean:
	rm -f ${TARGETS} ${HOLD_STRING} ${UNIT_BINS}
