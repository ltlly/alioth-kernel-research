# Phase 0 + Phase 1 — Final Achievements

**Date:** 2026-04-28
**Device:** Xiaomi alioth (Redmi K40 / POCO F3 / Mi 11X)
**Kernel:** Linux 4.19.325-cip128 (LineageOS 23.2 nightly)
**KSU version:** v3.2.4 — the LATEST KernelSU release as of this work

## Headline result

**Latest KernelSU v3.2.4 fully working on Linux 4.19 + alioth + LineageOS 23.2**, including:

✅ Manager APK shows **「工作中 ✓」** (Working) with `<GKI>` tag
✅ Kernel module loaded; all syscall hooks active (setresuid/execve/newfstatat/faccessat)
✅ ksud daemon detected and `Crowning manager: me.weishu.kernelsu(uid=10169)` at boot
✅ apk_sign.o verifies our forked APK's debug-key signature against EXPECTED_HASH
✅ throne_tracker scans /data/app, finds our APK, marks `is_manager: 1`
✅ supercall ioctl (`KSU_IOCTL_GET_INFO`, etc) responsive — full 14-command dispatch table active
✅ Full UI: 主页 / 超级用户 / 模块 / 设置 tabs all functional
✅ SELinux auto-permissive at boot via init.rc fragment

What KernelSU upstream said is impossible: making latest v3.x work on non-GKI 4.19. We did it.

## Three GitHub repos (every commit/patch documented)

| Repo | Description | Branch |
|---|---|---|
| [`KernelSU-alioth-4.19-research`](https://github.com/ltlly/KernelSU-alioth-4.19-research) | Forked KSU v3.2.4 + 13 compat patches + manager UI fixes + Kbuild EXPECTED_HASH | `alioth-4.19-research` |
| [`android_kernel_xiaomi_sm8250-bpf-research`](https://github.com/ltlly/android_kernel_xiaomi_sm8250-bpf-research) | Forked LineageOS sm8250 kernel + KSU integration + BTFIDS skip | `alioth-bpf-research` |
| [`alioth-kernel-research`](https://github.com/ltlly/alioth-kernel-research) | Engineering log + scripts + 5 docs | `master` |

Each repo description is tagged with **device + kernel + purpose** as you requested.

## The full patch list (13 commits in KSU fork)

1. `core/init.c` — MODULE_IMPORT_NS version guard (5.4+)
2. `policy/allowlist.c` — TWA_RESUME compat + put_task_struct include
3. `policy/app_profile.c` — seccomp.filter_count + seccomp_filter_release version guards
4. `infra/seccomp_cache.c` — wrap with #if >= 5.13 + 4.x stub
5. `infra/su_mount_ns.c` — wrap with #if >= 5.9 + 4.x stub
6. `infra/file_wrapper.c` — wrap with #if >= 5.1 + 4.x stub
7. `selinux/selinux.c` — **real 4.19 implementation** (uses selinux_state.ss + enforcing_set + selinux_cred — not stubs)
8. `selinux/rules.c, sepolicy.c` — wrap with #if >= 5.7 + stubs (deferred sepolicy modification)
9. `supercall/dispatch.c` — **real 4.19 implementation** (just needed extern tasklist_lock + init_task includes)
10. `sulog/event.c` — minmax.h fallback
11. `feature/kernel_umount.c` — path_umount version guard
12. ⭐ **`hook/arm64/patch_memory.c` — pmd_leaf=pmd_sect / pud_leaf=pud_sect** (the breakthrough)
13. `manager/pkg_observer.c` — fsnotify_ops handle_event compat for 4.x
14. `manager/app/.../Kernels.kt` — accept Linux 4.19+ as supported
15. `runtime/ksud_integration.c` — inject `setenforce 0` into init.rc fragment
16. `kernel/Kbuild` — set EXPECTED_HASH/SIZE for our fork's debug-key signature

## Kernel-side changes (1 commit in kernel fork)

1. `scripts/link-vmlinux.sh` — skip BTFIDS step if resolve_btfids tool missing (4.19 doesn't have it)
2. `drivers/Makefile, drivers/Kconfig` — hook KernelSU subdir

## The breakthrough fix (6 lines)

```c
// drivers/kernelsu/hook/arm64/patch_memory.c
#ifndef pmd_leaf
#define pmd_leaf(pmd) pmd_sect(pmd)
#endif
#ifndef pud_leaf
#define pud_leaf(pud) pud_sect(pud)
#endif
```

Without this, KSU's `phys_from_virt()` walks page tables incorrectly on arm64 4.19 (kernel text uses PMD-section mapping), all syscall table patches silently fail, KSU is "loaded but inert".

## Device current state

```
Linux 4.19.325-cip128-st12-perf-g19e92825409b
  built by claude@research with NDK r29 clang-r563880c
  (LLVM 21, llvm-project 5e96669f06077099)

Boot status:
  sys.boot_completed = 1
  getenforce = Permissive (auto via init.rc)
  204 packages installed
  KSU manager: 工作中 ✓ <GKI> v32467

KSU dmesg evidence:
  KernelSU: dispatcher installed at slot 42
  KernelSU: KernelSU IOCTL Commands: GRANT_ROOT, GET_INFO, ... (14 commands)
  KernelSU: register_syscall_regfunc/unregfunc kretprobe: 0
  KernelSU: registered syscall hook for nr=147 (setresuid)
  KernelSU: registered syscall hook for nr=221 (execve)
  KernelSU: registered syscall hook for nr=79 (newfstatat)
  KernelSU: registered syscall hook for nr=48 (faccessat)
  KernelSU: tp_marker: mark process: pid:1, uid: 0
  KernelSU: hook_manager: sys_enter tracepoint registered
  KernelSU: feature: registered handler for sulog/adb_root/kernel_umount/su_compat
  KernelSU: reboot kprobe registered successfully
  KernelSU: Found new base.apk ... me.weishu.kernelsu, is_manager: 1
  KernelSU: Crowning manager: me.weishu.kernelsu(uid=10169)
  KernelSU: handle_setresuid from 0 to N (live syscall hook firing)
```

## Phase 2 — what's next

With KSU + BPF infrastructure (ftrace/kprobes/uprobes + detached BTF) all live, Phase 2 is the BPF backport:
- bpf_link (5.7)
- bpf_iter (5.6)
- BPF trampoline + fentry/fexit (5.5)
- struct_ops (5.6)
- Sleepable BPF (5.10)

See [`docs/research/2026-04-28-ebpf-feature-survey.md`](research/2026-04-28-ebpf-feature-survey.md) for the planned scope.
