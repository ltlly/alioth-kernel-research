# Alioth Kernel Project — Status

| Phase | State | Notes |
|---|---|---|
| Pre-Phase | DONE | deps + scripts + stock backup + kernel source pinned |
| Phase 0 (vanilla rebuild) | DONE | NDK r29 clang r563880c match for stock; vermagic identical |
| Phase 1 (BTF + ftrace + KSU v3.2.4) | **🏆 完整功能** | Manager「工作中 ✓」`<GKI>`; 16 KSU file patches; 真实 supercall dispatch + apk_sign 验证 fork manager; 4 个 tab 全可用 |
| Phase 2 (BPF tracing/lsm/ext) | **🏆 完整标准 eBPF** | mainline 5.5 + 5.18 + 6.0 BPF trampoline 三层移植; ctx[0..N]=真实参数, fexit 在 ret 后触发, return value 可读, fmod_ret 可改 — 完全和 upstream 一致 |

## Current device state

- **Active slot**: `_a` flashed with final P2 kernel (mainline 5.5/5.18/6.0 三层移植 + bpf_shtab fix + persist BTF)
- **Persistent image**: `workspace/builds/20260429-095317-p2-final-persist.img`
- **Kernel**: `Linux 4.19.325-cip128-st12-perf-g43c03d52ba05-dirty` (claude@research / NDK r29 clang-r563880c)
- **BTF**: `/mnt/vendor/persist/vmlinux.btf` (9.7MB strict-4.19, **survives factory reset**)
- **Install BTF**: `scripts/install-btf-to-persist.sh` (one-shot per device)
- **Canonical strict BTF**: `workspace/kernel/patches/phase2-bpf-backport/00-survey/btf-fw/vmlinux.btf`
- **Stock backup**: `workspace/stock-images/boot_a-original.img` for instant restore
- **AVB**: vbmeta_a + vbmeta_b flashed with `--disable-verification`
- **Released artifacts**: [`alioth-r2`](https://github.com/ltlly/alioth-kernel-research/releases/tag/alioth-r2)

## Live verification (cold reboot from slot _a)

```
$ adb shell bpftool prog loadall fexit_test.bpf.o /sys/fs/bpf/y autoattach
$ adb shell cat /sys/kernel/tracing/enabled_functions
do_sys_open (1) R I D    tramp: ftrace_regs_caller (call_direct_funcs)
                         direct--> bpf_trampoline_105579_1

$ ls /
$ echo z > /data/local/tmp/test
$ adb shell cat /sys/kernel/tracing/trace
sh ENTRY  dfd=ffffffffffffff9c flags=20241                # AT_FDCWD = -100
sh EXIT   dfd=ffffffffffffff9c flags=20241 ret=3          # real return value
ls ENTRY  dfd=ffffffffffffff9c flags=a8000                # O_DIRECTORY|O_NONBLOCK|...
ls EXIT   dfd=ffffffffffffff9c flags=a8000 ret=3
```

Standard upstream eBPF interface contract met:

| eBPF semantic | Status |
|---|---|
| `ctx[0..N]` = function args | ✓ ctx[0] = AT_FDCWD (real arg0) |
| fentry triggered at function entry | ✓ before prologue runs |
| fexit triggered after `ret` | ✓ |
| fexit reads return value | ✓ via ctx[N] |
| fmod_ret modifies return value | ✓ (JIT supports it) |
| BPF_TRAMP_F_CALL_ORIG / SKIP_FRAME | ✓ |
| sleepable fentry/fexit | ✓ |

## What works in Phase 1

- ✅ Dynamic ftrace (77390 traceable functions with `-fpatchable-function-entry=2`)
- ✅ kprobe events via `/sys/kernel/tracing/kprobe_events` and BPF kprobe progs
- ✅ uprobe events (verified live on Qunar `Ena1907_req`)
- ✅ Detached BTF for libbpf CO-RE programs
- ✅ KernelSU v3.2.4 module loaded; all syscall hooks active (setresuid/execve/newfstatat/faccessat)
- ✅ `Crowning manager: me.weishu.kernelsu(uid=10169)` at boot
- ✅ KSU sulog and adb_root handlers registered
- ✅ frida unaffected (no kernel dependency)
- ✅ adb root persists (userdebug ROM)

## What works in Phase 2

### Verifier-level
- ✅ `tracing` / `lsm` / `ext` / `struct_ops` / `sk_lookup` prog types — all available
- ✅ in-kernel `btf_vmlinux` populated from `/mnt/vendor/persist/vmlinux.btf`
- ✅ `/sys/kernel/btf/vmlinux` exposed for userspace libbpf
- ✅ All 18 BPF map types
- ✅ NetBpfLoad / gpuMem / netd / ringbuf — 60+ existing BPF programs unaffected (no regressions)

### Attach + execution
- ✅ fentry programs read function args via `ctx[0..N]`
- ✅ fexit programs trigger after `ret`, read return value
- ✅ fmod_ret programs can modify return value (JIT supports it)
- ✅ Sleepable fentry/fexit
- ✅ struct_ops programs (e.g. BPF TCP CC algorithms)

## What's NOT done — by design

| Item | Reason |
|---|---|
| `BPF_PROG_TYPE_SYSCALL` (5.14+) | Verifier source-level backport; not used by typical tooling (bpftrace, cilium, stackplz) |
| `BPF_PROG_TYPE_NETFILTER` (6.x) | Netfilter subsystem source-level backport; not used by typical tooling |
| `lirc_mode2` | Device has no IR hardware |
| Upgrade to 5.10+ kernel | Non-goal per design spec — would require multi-month sm8250 BSP porting |

## Kernel commits (research-fork master, in order)

```
43c03d52ba05 bpf: btf firmware loader — search /mnt/vendor/persist first
dabee90203b9 net/core/sock_map: rename bpf_htab → bpf_shtab to match BTF lookup name
549c996be470 bpf: route arm64 fentry/fexit through register_ftrace_direct_multi
6aa1a1ec0463 bpf, arm64: don't skip bpf_func when __bpf_prog_enter returns 0
9b69f0d293a4 arm64: ftrace_common_return: bridge to BPF trampoline ABI
a89e06fd2f44 ftrace: backport register_ftrace_direct_multi (mainline 5.18 f64dd4627ec6)
15491ac9ca5d arm64: implement ftrace with regs (backport mainline 5.5 3b23e4991fb6)
081b4abff6b2 arm64: insn: add aarch64_insn_gen_move_reg() encoder
9f78aee2783d vmlinux.lds.h: gather __patchable_function_entries into mcount_loc range
ee041ac767d3 ftrace: add ftrace_init_nop() (backport mainline 5.5 fbf6c73c5b26)
47fe2bdbee57 Revert "arm64: backport HAVE_DYNAMIC_FTRACE_WITH_REGS to 4.19 mcount-based ftrace"
9a7c71dabb06 arm64: bpf: backport BPF trampoline JIT emitter from Linux 6.0
e66d6870d6cb bpf: load btf_vmlinux from filesystem when .BTF section is empty
479366b04408 bpf: expose FS-loaded btf_vmlinux at /sys/kernel/btf/vmlinux
```

The reverted `2f9a02d7877f` (mcount-based WITH_REGS hack) is gone — proper
mainline 5.5 `-fpatchable-function-entry=2` port (`15491ac9ca5d`)
delivers the same goal correctly.

## KSU on 4.19 — full capability

- ✅ All init paths active (hook_init / supercalls_init / hook_manager_init)
- ✅ Real `supercall/dispatch.c` on 4.19 — full 14-command IOCTL dispatch
- ✅ `apk_sign.c` verifies manager APK signature against EXPECTED_HASH
- ✅ `throne_tracker` finds manager APK at boot, `Crowning manager` log
- ✅ `handle_setresuid` hook firing live for uid transitions
- ✅ KSU init.rc fragment auto-runs `setenforce 0` at multiple stages
- ✅ Stable RSA-4096 keystore committed as GH secret — deterministic APK signing across CI
- ✅ ksud daemon talks to kernel via ioctl; all features queryable
- ✅ 4 manager tabs functional: 主页 / 超级用户 / 模块 / 设置

### The breakthrough fix (KSU)

`drivers/kernelsu/hook/arm64/patch_memory.c` — 6-line `pmd_leaf`/`pud_leaf`
alias to `pmd_sect`/`pud_sect`. Without this, KSU's `phys_from_virt()`
walks page tables incorrectly on arm64 4.19 (kernel text uses PMD-section
mapping), all syscall table patches silently fail.

### SELinux integration

`selinux/selinux.c` — replaced stubs with real 4.19 implementations using
`selinux_state.ss` / `enforcing_set` / `selinux_cred(cred)->sid`. Best-effort
escalation: full uid/gid + capabilities, but ksu domain not in stock
sepolicy → escalated processes get uid=0 + caps but stay in original
SELinux context. KSU init.rc fragment force-permissive at multiple boot
stages so this is invisible to users.
