# alioth-kernel-research

**Goal:** Get **latest KernelSU (v3.2.4)** + **fully standard upstream eBPF behavior** running on **Linux 4.19-cip** for **Xiaomi alioth** (Redmi K40 / POCO F3 / Mi 11X), starting from LineageOS 23.2 nightly.

KernelSU upstream officially [dropped non-GKI support starting v1.0](https://kernelsu.org/zh_CN/guide/how-to-integrate-for-non-gki.html). This project re-enables it for 4.19 alioth via 13 source-level compat patches, including a critical [`pmd_leaf` fix](https://github.com/ltlly/KernelSU-alioth-4.19-research/blob/alioth-4.19-research/kernel/hook/arm64/patch_memory.c) that unlocks all syscall hooks on arm64 4.19.

Standard upstream eBPF on 4.19 is delivered by porting mainline 5.5 (`-fpatchable-function-entry=2` + ftrace with regs), 5.18 (`register_ftrace_direct_multi`), and 6.0 (BPF trampoline JIT) into 4.19-cip — preserving every upstream invariant.

## Companion repos

| Repo | Description |
|---|---|
| [`KernelSU-alioth-4.19-research`](https://github.com/ltlly/KernelSU-alioth-4.19-research) | Forked KernelSU v3.2.4 with 4.19 compat patches + manager UI fix |
| [`android_kernel_xiaomi_sm8250-bpf-research`](https://github.com/ltlly/android_kernel_xiaomi_sm8250-bpf-research) | LineageOS sm8250 kernel + KSU integration + mainline 5.5/5.18/6.0 BPF trampoline backports + BTF firmware loader |
| [`alioth-kernel-research`](https://github.com/ltlly/alioth-kernel-research) (this repo) | Engineering logs, build scripts, runbooks |

## Status

- ✅ **Phase 0** — vanilla kernel rebuild
- ✅ **Phase 1** — BTF + ftrace + KSU v3.2.4 (Manager「工作中 ✓」)
- ✅ **Phase 2** — fully standard eBPF on arm64 4.19 via mainline 5.5 + 5.18 + 6.0 backports
  - `ctx[0..N]` = real function args (e.g. `ctx[0]=AT_FDCWD` on `do_sys_open`)
  - fexit fires after `ret`, reads return value (e.g. `ret=3` for the file descriptor)
  - fmod_ret can modify return values
  - Identical semantics to upstream Linux 6.x

29 of 32 BPF prog types `available` per `bpftool feature probe`. The 3
not available are `syscall` (5.14+), `netfilter` (6.x), and `lirc_mode2`
(no IR hardware) — all explicit non-goals.

## Quick navigation

| Looking for | See |
|---|---|
| **One-page summary of everything** | [`docs/FINAL-ACHIEVEMENTS.md`](docs/FINAL-ACHIEVEMENTS.md) |
| Current device state + commit list | [`STATUS.md`](STATUS.md) |
| **Standard eBPF — mainline 5.5+5.18 BPF trampoline port** | [`docs/runbook/2026-04-29-mainline-direct-multi-port.md`](docs/runbook/2026-04-29-mainline-direct-multi-port.md) |
| BPF trampoline JIT (Linux 6.0 backport) | [`docs/runbook/2026-04-28-arm64-bpf-trampoline.md`](docs/runbook/2026-04-28-arm64-bpf-trampoline.md) |
| BTF firmware loader (verifier-level unlock) | [`docs/runbook/2026-04-28-btf-firmware-loader.md`](docs/runbook/2026-04-28-btf-firmware-loader.md) |
| Each KSU patch explained line-by-line | [`docs/runbook/2026-04-28-ksu-patches.md`](docs/runbook/2026-04-28-ksu-patches.md) |
| Engineering log: every brick + recovery + dead-end | [`docs/journey/2026-04-28-phase0-phase1-phase2-journey.md`](docs/journey/2026-04-28-phase0-phase1-phase2-journey.md) |
| Device bricked? Recovery steps | [`docs/runbook/2026-04-28-recovery-runbook.md`](docs/runbook/2026-04-28-recovery-runbook.md) |
| What CIP-128 already backported | [`workspace/kernel/patches/phase2-bpf-backport/00-survey/STRATEGY.md`](workspace/kernel/patches/phase2-bpf-backport/00-survey/STRATEGY.md) |
| Original eBPF feature survey (5.5 → 6.12 timeline) | [`docs/research/2026-04-28-ebpf-feature-survey.md`](docs/research/2026-04-28-ebpf-feature-survey.md) |
| Build scripts | [`scripts/`](scripts/) |
| **Install BTF on a fresh device** | `./scripts/install-btf-to-persist.sh` (one-shot) |

## Quick start (re-create on another alioth device)

Prerequisites:
- Xiaomi alioth (Redmi K40/POCO F3/Mi 11X) with **bootloader unlocked**
- LineageOS 23.2 nightly (kernel `4.19.325-cip128-st12-perf-...`)
- Linux build host with ~30GB free, sudo, NDK r29 (~800MB)

```bash
# 1. Get this repo
git clone https://github.com/ltlly/alioth-kernel-research.git
cd alioth-kernel-research

# 2. Install prereqs
sudo apt install -y bison flex bc ccache lz4 cpio python3-dev libssl-dev \
                    libelf-dev clang gawk dwarves lld llvm erofs-utils

# 3. Bootstrap workspace (TODO: one-shot script — manual sequence in docs/journey/)

# 4. Build kernel + pack boot.img
./scripts/build.sh final workspace/kernel/patches/phase1-btf-ftrace/p1-overlay.config
./scripts/pack-boot.sh final

# 5. Backup device images (CRITICAL — fastboot/recovery rescue depends on these)
./scripts/backup-device.sh

# 6. Test in RAM (no flash)
./scripts/flash-test.sh workspace/builds/$(cat workspace/builds/LATEST | head -1) \
                        --probe ./scripts/probes/boot-smoke.sh

# 7. Persist to slot _a (Virtual A/B — only _a is bootable)
./scripts/flash-commit.sh <image>

# 8. Install BTF to persist partition (survives factory reset)
./scripts/install-btf-to-persist.sh

# 9. Install KSU manager APK
adb install KernelSU.apk

# Recovery (any time):
fastboot flash boot_a workspace/stock-images/boot_a-original.img
```

## What this enables

Anything compiled against modern libbpf using standard `BPF_PROG()` /
`SEC("fentry/...")` / `SEC("fexit/...")` macros now works on alioth 4.19.
Verified prog types:

- `tracing` (fentry / fexit / fmod_ret) — args + return value
- `lsm` — security observability hooks
- `ext` — BPF program extensions
- `struct_ops` — TCP CC algorithms etc.
- `sk_lookup` — socket lookup hook
- `kprobe`, `tracepoint`, `raw_tracepoint`, `perf_event`, `xdp`,
  `sched_cls`, `cgroup_skb`, ... 24 more available types
- All 18 BPF map types

## Why this exists

Researcher needed standard upstream BPF + KernelSU on a 4.19 LineageOS
device. Upstream KSU said no for non-GKI; mainline arm64 BPF trampoline
required ABI changes 4.19 didn't have. This documents how to make it
work anyway, with every workaround traced back to its upstream commit.

## License

GPL-2.0 (matches kernel + KernelSU upstream).
