# Agents

memdumper is a compiled C dylib plus `attach.sh`. The **build host** has the toolchain. The **runtime host** is the **target** and has no Xcode, compiler, Homebrew, or `shellcheck` unless they happen to be installed for other reasons.

`make`, `make test`, `clang`, **cppcheck**, and **shellcheck** are build-host only. Do not treat clone-and-compile as a deploy path onto the target. Copy `attach.sh` and `memdumper.dylib`.

Colocated build-and-run on one Mac is allowed. It is not a clean-runtime proof.

When the CrowdStrike EDR product appears in docs, comments, or CLI help, write **CrowdStrike Falcon**. Do not shorten it.

See README.md for the operator surface and ARCHITECTURE.md for entitlement inheritance and the three methods.
