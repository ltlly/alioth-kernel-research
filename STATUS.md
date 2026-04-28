# Alioth Kernel Project — Status

| Phase | State | Notes |
|---|---|---|
| Pre-Phase | DONE | deps + scripts + stock backup + kernel source pinned |
| Phase 0 (vanilla) | DONE | NDK r29 clang r563880c match for stock; vermagic identical |
| Phase 1 (BTF+ftrace+KSU) | DONE (with caveats) | Latest KSU v3.2.4 compiled + module loaded on 4.19 |
| Phase 2 (BPF backport) | pending | |

## Current device state

- Active slot: `_a` (research kernel: P1 = ftrace + kprobes + KSU + detached BTF)
- `/proc/version` shows `(claude@research)` — our build
- KSU module: loaded, feature handlers registered
- BTF file at `/data/local/tmp/vmlinux.btf` (9.7MB, extracted from BTF-enabled build)
- Stock backup at `workspace/stock-images/boot_a-original.img` for instant restore
- AVB: vbmeta_a + vbmeta_b flashed with `--disable-verification`

## What works in Phase 1

✅ Dynamic ftrace (68942 traceable functions)
✅ kprobe events via `/sys/kernel/tracing/kprobe_events`
✅ uprobe events (already worked in stock)
✅ Detached BTF for libbpf CO-RE programs (use `--btf` flag pointing to `/data/local/tmp/vmlinux.btf`)
✅ KernelSU module loaded; `feature management` initialized
✅ KSU sulog and adb_root handlers registered
✅ frida unaffected (no kernel dependency)
✅ adb root persists (userdebug ROM)

## KSU limitations on 4.19 (deliberately disabled to allow boot)

⚠️ Syscall hooks disabled — KSU won't intercept execve to grant `su` to manager-allowlisted apps. Use `adb root` for testing.
⚠️ SELinux integration stubbed — `apply_kernelsu_rules`, `setup_selinux`, etc are no-ops (5.7+ refactored selinux_state.policy structure isn't on 4.19).
⚠️ supercall ioctl stubbed — KSU manager APK can't communicate with kernel via standard supercall ioctl.

To fully restore KSU functionality on 4.19 would require ~1-2 weeks of arch-specific work:
1. Reimplement syscall hook layer for 4.19 syscall table layout
2. Reimplement SELinux integration against 4.19's `selinux_state.ss` (vs 5.7's `.policy`)
3. Reimplement supercall ioctl with 4.19 task_pgrp/init_task semantics

For security research goals (frida, stackplz, bpftrace, BPF CO-RE): all work without these KSU features.

## Patches applied to KernelSU

Recorded in `workspace/kernel/android_kernel_xiaomi_sm8250/drivers/kernelsu/` git history. Files modified:
- core/init.c — MODULE_IMPORT_NS guard + bypass syscall hooks at runtime
- policy/allowlist.c — TWA_RESUME compat + put_task_struct include
- policy/app_profile.c — seccomp.filter_count guard + seccomp_filter_release fallback
- infra/seccomp_cache.c — wrapped 5.13+ guard
- infra/su_mount_ns.c — wrapped 5.9+ guard with 4.x stub
- infra/file_wrapper.c — wrapped 5.1+ guard with 4.x stub
- selinux/selinux.c, selinux/rules.c, selinux/sepolicy.c — wrapped 5.7+ guard with 4.x stubs
- supercall/dispatch.c — wrapped 5.0+ guard with 4.x stubs
- sulog/event.c, supercall/supercall.c — minmax.h + TWA_RESUME compat
- feature/kernel_umount.c — path_umount 5.9+ guard
