# Architecture

memdumper has no entitlements of its own. It is a dylib whose constructor runs inside an entitled binary that has `com.apple.security.cs.debugger`, `com.apple.security.cs.allow-dyld-environment-variables`, and `com.apple.security.cs.disable-library-validation`. dyld honours `DYLD_INSERT_LIBRARIES` because of the second entitlement. `disable-library-validation` is what lets the process load a dylib that would otherwise fail library validation. The constructor then calls `task_for_pid` as that binary. Unless that process is root, `taskgated` still decides the call.

`attach.sh` is the in-tree starter. The constructor is the payload: it is the dump. The entitled binary is existing software on the target, not a stage.

## Hosts

The **build host** has Xcode Command Line Tools (or Xcode), `clang`, `make`, and `shellcheck`. `make` and `shellcheck` are build-host only.

The **runtime host** is the **target**. It runs `attach.sh` and `memdumper.dylib` as root with a stock macOS userland. No compiler, Xcode, or Homebrew. Developer Mode (`DevToolsSecurity`) is not assumed.

Colocated build-and-run on one Mac is the usual development setup. It is not a clean-runtime proof.

Verification is `make` (build plus cppcheck and shellcheck) and `make test` on the build host. Unit tests compile `memdumper.c` with `MEMDUMPER_NO_CTOR` so the insert constructor does not run. Functional tests cover attach.sh argument errors, a non-root refusal, and two live injects: they `find` `jspawnhelper` under `/opt/homebrew/Cellar` and `/usr/local/Cellar` (no version pin) and inject into a `hold-string` fixture as uid 0. One run searches for a needle; the other hex-dumps regions (`-n 5`, no `-s`). The live injects exit 77 (skip) if `find` has no hit or if the suite is not uid 0, so a non-root `make test` does not present Developer Tool Access. The non-root refusal test skips if the suite is already uid 0. That is not a clean-runtime proof. Backup and restore are N/A: there is no data store.

Place the artefact by copying `attach.sh` and `memdumper.dylib` onto the target. There is no install. The same dylib can be injected by other code that sets `DYLD_INSERT_LIBRARIES` and the `MEMDUMPER_*` variables.

The core is serial: one target PID per invocation. There is no in-process fan-out.

## The insert

`attach.sh` checks that the target PID exists (`ps`) and that `memdumper.dylib` is in the current working directory. It then runs `codesign -dv` on the target's on-disk image (path from `lsof`) and greps for `runtime`. A hit is treated as Hardened Runtime and aborts unless `--force`. If `lsof` cannot resolve the path, the Hardened Runtime check is skipped. After those checks it requires uid 0. A non-root caller is refused (`root required`) before the entitled binary is started, so `taskgated` does not present the Developer Tool Access dialog.

It exports `MEMDUMPER_TARGET_PID`, optional `MEMDUMPER_SEARCH`, and `MEMDUMPER_MAX_REGIONS`, then starts the caller-supplied entitled binary with `DYLD_INSERT_LIBRARIES` set to `$(pwd)/memdumper.dylib`. Standard error is merged onto standard output (`2>&1`). After a successful insert the constructor `_exit`s, so that stream is only the dylib. If the insert fails, the entitled binary's own stdout is what remains.

The entitled binary is not inspected for the three entitlements. A missing `allow-dyld-environment-variables` or `disable-library-validation` means the insert does not happen. A missing `debugger` entitlement means the insert can succeed and `task_for_pid` still fails. With the entitlement, a non-root caller still hits `taskgated`.

The constructor (`__attribute__((constructor))`) prints the injector PID, UID, and `proc_pidpath` of the entitled binary, then reads `MEMDUMPER_TARGET_PID`. After `test_target` returns it flushes stdio and `_exit(0)`s. The entitled binary never reaches `main`, so `jspawnhelper` does not print its usage banner. Extra argv after the image stay on the exec that an EDR records. If the insert fails, dyld never runs the constructor and that binary's `main` runs as usual.

The process exit code is 0 after a successful insert. Dump outcome is the `[RESULT]` line.

## The three entitlements

| Entitlement | What it gates |
|-------------|---------------|
| `com.apple.security.cs.debugger` | `task_for_pid` and `ptrace` against another same-UID process |
| `com.apple.security.cs.allow-dyld-environment-variables` | dyld honours `DYLD_INSERT_LIBRARIES` on this signed image |
| `com.apple.security.cs.disable-library-validation` | The process may load an unsigned or foreign-team dylib |

All three are required on the entitled binary. Root on the runtime host skips the `taskgated` password dialog. It does not skip Hardened Runtime or System Integrity Protection (SIP). Hardened Runtime on the *target* still blocks the Mach and `ptrace` calls even when that binary has all three.

OpenJDK's `jspawnhelper` is the usual entitled binary because a Homebrew or Oracle JDK install commonly ships all three. Homebrew's copy is adhoc-signed. It is third-party software often present on developer Macs, not a stock Apple binary.

The Makefile does not codesign the dylib. `disable-library-validation` on the entitled binary is what lets the process load it when the dylib is unsigned or from another team.

## taskgated and Authorization Services

`com.apple.security.cs.debugger` lets the entitled binary call `task_for_pid` and `ptrace`. It does not grant the Mach task port by itself. After the kernel's preliminary checks, `taskgated` decides the call. For that entitlement, `taskgated` evaluates the Authorization Services right `system.privilege.taskport`.

`system.privilege.taskport` lives in the authorization database (`security authorizationdb read system.privilege.taskport`). On a stock host it authenticates the user, is scoped to the `_developer` group, and lasts 36000 seconds (ten hours) after a successful password. The dialog is "Developer Tool Access is trying to take control of another process". Cancelling it fails `task_for_pid`. `ptrace(PT_ATTACHEXC)` hits the same gate. `taskgated` has other rights for Apple-private debugger entitlements; `jspawnhelper` uses the public entitlement, so this is the right that fires.

That dialog is Authorization Services, not Transparency, Consent, and Control (TCC). TCC is the Privacy database behind System Settings > Privacy & Security. Developer Tools TCC (`kTCCServiceDeveloperTool`) is a separate consent for running software that does not meet system integrity policy. It is not the password dialog and it does not replace the `system.privilege.taskport` check.

`DevToolsSecurity -enable` turns on Developer Mode. `DevToolsSecurity(8)` limits that change to Apple-code-signed debugger and performance-analysis tools. After `-enable`, `security authorizationdb read` shows two different rights. `system.privilege.taskport` (public `com.apple.security.cs.debugger`) still has `authenticate-user` true, `group` `_developer`, and a 36000-second timeout. It is same-user only. That is the right Homebrew `jspawnhelper` hits. `system.privilege.taskport.debug` (Apple-private `com.apple.private.cs.debugger`) is a k-of-n 1 rule of `is-admin`, `is-developer`, or `authenticate-developer`. That is the no-password path for `lldb` and Instruments.

A colocated run with Developer Mode enabled, the caller in both `admin` and `_developer`, and Homebrew OpenJDK 26 `jspawnhelper` (adhoc, no Team ID) still presented Developer Tool Access on `task_for_pid` against a same-UID `nano`. The insert itself succeeded: the constructor printed UID 501. `DevToolsSecurity -status` is not a reason to drop the uid 0 check on `attach.sh`. A successful password is cached on `system.privilege.taskport` for ten hours; that quiet retry is the cache, not Developer Mode covering this helper. A macOS upgrade, including to Tahoe, commonly leaves Developer Mode off. The target is not assumed to have it.

The runtime host is used as root. As uid 0 the kernel grants the task port without presenting that dialog. SIP still keeps protected system processes out of reach.

## The three methods

`test_target` always runs the three calls in order. `[RESULT] n/3` counts how many returned success. Only the first path reads target memory.

`task_for_pid(mach_task_self(), target, &task)` is the Mach task port. On success the dylib prints `task_info` (virtual and resident size) and `task_threads`, then either searches or dumps. `mach_vm_region` walks the map. `mach_vm_read_overwrite` reads each readable region (`VM_PROT_READ`).

Without `MEMDUMPER_SEARCH`, `dump_memory_regions` walks the map until it ends or 10000 regions and hex-dumps the first 256 bytes of each readable region until `MEMDUMPER_MAX_REGIONS` (default 100) displayed regions. A missing, non-numeric, or out-of-range value falls back to 100.

With `MEMDUMPER_SEARCH`, `search_memory` walks at most 1000 regions, reads at most 10 MiB of each readable region, and prints a 64-byte hex context around every `memcmp` hit. `MEMDUMPER_MAX_REGIONS` is unused on this path.

`ptrace(PT_ATTACHEXC, ...)` attaches, polls `waitpid(..., WNOHANG)` briefly, then `PT_DETACH`. PT_ATTACHEXC delivers a Mach exception, not a POSIX stop, so a blocking `waitpid` never returns. It does not read memory. A failed detach is a failed method. The entitled binary's own PID is refused so this call cannot attach to self.

`proc_pidinfo(..., PROC_PIDTASKALLINFO, ...)` prints virtual size, resident size, and thread count. It does not read memory.

## What an EDR records

Process events name the entitled binary (`jspawnhelper`, `java`, or whatever image was exec'd). The dylib is not a process. Parent and command-line fields therefore do not name `attach.sh` as the memory reader; they name the entitled binary. `attach.sh` itself is still a process event (the shell that execs that binary).

CrowdStrike Falcon for macOS logs process environment variables. `DYLD_INSERT_LIBRARIES` pointing at `memdumper.dylib` is visible on that channel even when the process tree only shows the entitled binary.

## Build

```text
clang -std=c17 -Wall -Wextra -Werror -pedantic -dynamiclib -framework CoreFoundation -o memdumper.dylib memdumper.c
```

Native `clang`, host slice, no `-arch`, no universal binary. The dylib includes `<mach/mach.h>`, `<mach/mach_vm.h>`, `<libproc.h>`, and `<sys/ptrace.h>`. It does not call CoreFoundation; the link line still passes `-framework CoreFoundation`.

No SDK deployment-target pin. No codesign step.

## Limits

- Hardened Runtime on the target refuses `task_for_pid` and `ptrace`. `attach.sh` greps `codesign -dv` for the substring `runtime`. That matches a `Runtime Version=` line if one is present.
- The runtime host is used as root. As uid 0 the kernel grants the task port without the Developer Tool Access dialog. A non-root same-UID attach still hits `taskgated` and Authorization Services right `system.privilege.taskport`, including when Developer Mode is on and the caller is in `admin` and `_developer`. SIP keeps protected system processes out of reach.
- Developer Mode (`DevToolsSecurity`) rewrites `system.privilege.taskport.debug` for Apple-signed debugger tools. It leaves `system.privilege.taskport` authenticating. The target is not assumed to have Developer Mode enabled.
- Some processes, including `bash`, refuse the attach through checks that are not Hardened Runtime.
- `attach.sh` resolves `memdumper.dylib` only in the current working directory.
- The dump walk and the search walk use different caps (10000 regions / 256-byte preview versus 1000 regions / 10 MiB). `-n` only limits how many readable regions are hex-dumped.
- `ptrace` and `proc_pidinfo` are reachability probes. They are not additional dump paths.

## See also

- README.md: operator CLI, including root on the runtime host
- AGENTS.md: build host versus target
