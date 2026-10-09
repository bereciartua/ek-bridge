# Frozen 0.8.2 registry

Exact copies of `Sources/ClientRegistry.swift` and the files it needs, as
tagged `v0.8.2` (`git show v0.8.2:Sources/<file>`). Don't edit them.

`Tests/RollbackHarness.swift` compiles against these to prove that a data
folder written by the current code still loads in 0.8.2, the oldest version
users may roll back to (IMPLEMENTATION.md §2.4: never bump the registry
version, never write values 0.8.2 rejects). `test.sh` runs it on a folder the
current code writes; `scripts/rollback_check.sh` runs it on a copy of the
live-test copy's data folder.
