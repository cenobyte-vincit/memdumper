/*
 * test-parse.c - Unit tests for pid_from_env and max_regions_from_env.
 *
 * Compiles memdumper.c with MEMDUMPER_NO_CTOR so the insert constructor
 * does not run. No live attach and no jspawnhelper required.
 */

#define MEMDUMPER_NO_CTOR
#include "../../memdumper.c"

#include <stdio.h>
#include <stdlib.h>

#define TEST_ASSERT(cond) do { \
	if (!(cond)) { \
		fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
		return (1); \
	} \
} while (0)

/*
 * Accept a whole positive PID; reject empty, zero, junk, and overflow.
 */
static int
test_pid_from_env(void)
{
	TEST_ASSERT(pid_from_env(NULL) == (pid_t)-1);
	TEST_ASSERT(pid_from_env("") == (pid_t)-1);
	TEST_ASSERT(pid_from_env("1") == (pid_t)1);
	TEST_ASSERT(pid_from_env("42") == (pid_t)42);
	TEST_ASSERT(pid_from_env("0") == (pid_t)-1);
	TEST_ASSERT(pid_from_env("-5") == (pid_t)-1);
	TEST_ASSERT(pid_from_env("12abc") == (pid_t)-1);
	TEST_ASSERT(pid_from_env("abc") == (pid_t)-1);
	return (0);
}

/*
 * Honour a positive MEMDUMPER_MAX_REGIONS; fall back to 100 otherwise.
 */
static int
test_max_regions_from_env(void)
{
	(void)unsetenv("MEMDUMPER_MAX_REGIONS");
	TEST_ASSERT(max_regions_from_env() == 100);

	TEST_ASSERT(setenv("MEMDUMPER_MAX_REGIONS", "", 1) == 0);
	TEST_ASSERT(max_regions_from_env() == 100);

	TEST_ASSERT(setenv("MEMDUMPER_MAX_REGIONS", "50", 1) == 0);
	TEST_ASSERT(max_regions_from_env() == 50);

	TEST_ASSERT(setenv("MEMDUMPER_MAX_REGIONS", "10000", 1) == 0);
	TEST_ASSERT(max_regions_from_env() == 10000);

	TEST_ASSERT(setenv("MEMDUMPER_MAX_REGIONS", "0", 1) == 0);
	TEST_ASSERT(max_regions_from_env() == 100);

	TEST_ASSERT(setenv("MEMDUMPER_MAX_REGIONS", "-1", 1) == 0);
	TEST_ASSERT(max_regions_from_env() == 100);

	TEST_ASSERT(setenv("MEMDUMPER_MAX_REGIONS", "abc", 1) == 0);
	TEST_ASSERT(max_regions_from_env() == 100);

	TEST_ASSERT(setenv("MEMDUMPER_MAX_REGIONS", "10001", 1) == 0);
	TEST_ASSERT(max_regions_from_env() == 100);

	(void)unsetenv("MEMDUMPER_MAX_REGIONS");
	return (0);
}

int
main(void)
{
	if (test_pid_from_env() != 0)
		exit (1);
	if (test_max_regions_from_env() != 0)
		exit (1);
	printf("PASS\n");
	return (0);
}
