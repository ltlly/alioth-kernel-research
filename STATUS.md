# Alioth Kernel Project — Status

| Phase | State | Notes |
|---|---|---|
| Pre-Phase | DONE | deps + scripts + stock backup + kernel source pinned to a5b3099017ae |
| Phase 0 (vanilla) | in-progress | Boot working with NDK r29 (clang r563880c, exact match for stock). Several earlier attempts hung — attributed to wrong clang (system clang-21, AOSP r584948 LLVM 22). Also confirmed AVB is not blocking (vbmeta_a was flashed with --disable-verification, didn't help — the issue was purely the clang version). Verified `sys.boot_completed=1`, `/proc/version` shows `claude@research`, no dmesg panics. Need 2 more flash-test passes + user manual sanity test. |
| Phase 1 (BTF+ftrace+KSU) | pending | |
| Phase 2 (BPF backport) | pending | |

## Current device state

- Active slot: `_a` (stock LineageOS 23.2 kernel 4.19.325-cip128)
- Slot `_b`: not yet touched
- Stock backup taken: YES (2026-04-28, sha256 in `workspace/stock-images/SHA256SUMS`)
