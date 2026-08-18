/*
 * hold-string.c - Sleeping fixture that keeps a known needle in memory.
 *
 * Used by the live jspawnhelper search test. Adhoc-signed by the build
 * host cc so Hardened Runtime is off. Not part of the product dylib.
 */

#include <unistd.h>

static char needle[] = "MEMDUMPER_FIXTURE_NEEDLE_9f3a";

int
main(void)
{
	volatile char keep;

	keep = needle[0];
	(void)keep;
	for (;;)
		(void)pause();
	return (0);
}
