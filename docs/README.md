# Alioth Kernel Research — 文档索引

把最新 KernelSU + 完整标准 eBPF 塞进 Linux 4.19-cip 的 alioth
(Redmi K40 / POCO F3 / Mi 11X)。

## 文档结构

### 推荐入口
- [`FINAL-ACHIEVEMENTS.md`](FINAL-ACHIEVEMENTS.md) — **整个项目一页纸总结**
- [`/STATUS.md`](../STATUS.md) — 当前 device 状态 + 完整 commit 列表

### 设计与计划
- [`superpowers/specs/2026-04-28-alioth-bpf-kernelsu-design.md`](superpowers/specs/2026-04-28-alioth-bpf-kernelsu-design.md) — 设计规范（项目目标、阶段划分、风险、DoD）
- [`superpowers/plans/2026-04-28-alioth-bpf-kernelsu.md`](superpowers/plans/2026-04-28-alioth-bpf-kernelsu.md) — 实施计划
- [`research/2026-04-28-ebpf-feature-survey.md`](research/2026-04-28-ebpf-feature-survey.md) — eBPF 特性调研（5.5 → 6.12 时间线）

### 工程日志
- [`journey/2026-04-28-phase0-phase1-phase2-journey.md`](journey/2026-04-28-phase0-phase1-phase2-journey.md) — **完整时间线：5 次砖 + 13 个 KSU 兼容补丁 + Phase 2 5 个 round（含一个被撤销的 mcount hack 教训）**

### Runbook（按依赖顺序）
- [`runbook/2026-04-28-ksu-patches.md`](runbook/2026-04-28-ksu-patches.md) — KSU v3.2.4 在 4.19 的每个 patch 解释
- [`runbook/2026-04-28-btf-firmware-loader.md`](runbook/2026-04-28-btf-firmware-loader.md) — **Round 1**: BTF firmware loader（verifier-level 解锁 tracing/lsm/ext）
- [`runbook/2026-04-28-arm64-bpf-trampoline.md`](runbook/2026-04-28-arm64-bpf-trampoline.md) — **Round 2**: arm64 BPF trampoline JIT (Linux 6.0 backport)
- [`runbook/2026-04-29-mainline-direct-multi-port.md`](runbook/2026-04-29-mainline-direct-multi-port.md) — **Round 4**: mainline 5.5 + 5.18 BPF trampoline 完整移植（标准 eBPF: fentry/fexit/return value）
- [`runbook/2026-04-28-recovery-runbook.md`](runbook/2026-04-28-recovery-runbook.md) — 设备砖了怎么救

### Phase 2 patch 工件
- `workspace/kernel/patches/phase2-bpf-backport/00-survey/STRATEGY.md` — Phase 2 调研：CIP 已 backport 哪些
- `workspace/kernel/patches/phase2-bpf-backport/00-survey/btf-fw/vmlinux.btf` — 4.19-strict BTF（含 bpf_shtab fix；用 `scripts/install-btf-to-persist.sh` 部署）
- `workspace/kernel/patches/phase2-bpf-backport/01-arm64-trampoline/STRATEGY.md` — Round 2 设计 + 踩坑日志

## 快速导航

| 需求 | 看这个 |
|---|---|
| 整个项目做了什么 | [FINAL-ACHIEVEMENTS](FINAL-ACHIEVEMENTS.md) |
| 我刷砖了 | [recovery-runbook](runbook/2026-04-28-recovery-runbook.md) |
| 在另一台 4.19 设备复现 KSU 兼容补丁 | [ksu-patches](runbook/2026-04-28-ksu-patches.md) |
| BTF firmware loader 怎么做的 | [btf-firmware-loader](runbook/2026-04-28-btf-firmware-loader.md) |
| BPF fentry/fexit/return-value 怎么真正达到上游标准 | [mainline-direct-multi-port](runbook/2026-04-29-mainline-direct-multi-port.md) |
| 为什么走到现在的方案（含一次被撤销的 mcount hack 教训） | [phase0-phase1-phase2-journey](journey/2026-04-28-phase0-phase1-phase2-journey.md) |
| Phase 2 实际做了哪些 vs 计划 | [STRATEGY.md](../workspace/kernel/patches/phase2-bpf-backport/00-survey/STRATEGY.md) |
| 当前 active boot_a 跑啥版本 | [STATUS.md](../STATUS.md) |
