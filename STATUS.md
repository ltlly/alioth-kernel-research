# Alioth Kernel Project — Status

| Phase | State | Notes |
|---|---|---|
| Pre-Phase | DONE | deps + scripts + stock backup + kernel source pinned to a5b3099017ae |
| Phase 0 (vanilla) | DONE | Research kernel flashed to boot_a (slot _a, active). Built with NDK r29 clang r563880c (exact stock match). Discovered alioth is Virtual A/B (slot _b is COW-only, can't boot standalone) — flashed boot_a directly. Recovery: `fastboot flash boot_a workspace/stock-images/boot_a-original.img`. Both vbmetas have `--disable-verification`. |
| Phase 1 (BTF+ftrace+KSU) | pending | |
| Phase 2 (BPF backport) | pending | |

## Current device state

- Active slot: `_a` (research kernel: P0 vanilla, built locally with NDK r29 clang)
- Slot `_b`: virtual A/B COW-only (cannot boot standalone), unused
- Stock backup taken: YES (2026-04-28, sha256 in `workspace/stock-images/SHA256SUMS`)
  - `boot_a-original.img` is the canonical "restore to stock" image
  - `vendor_boot_a-original.img` also captured (was missing from initial backup)
- AVB: vbmeta_a and vbmeta_b both flashed with `fastboot --disable-verification` (one-time setup)
