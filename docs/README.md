# Alioth Kernel Research — 文档索引

这个项目把最新 KernelSU + 完整 BPF 工具链塞进 Linux 4.19-cip 的 alioth (Redmi K40 / POCO F3 / Mi 11X)。

## 文档结构

### 设计与计划
- [`superpowers/specs/2026-04-28-alioth-bpf-kernelsu-design.md`](superpowers/specs/2026-04-28-alioth-bpf-kernelsu-design.md) — 设计规范（项目目标、阶段划分、风险、DoD）
- [`superpowers/plans/2026-04-28-alioth-bpf-kernelsu.md`](superpowers/plans/2026-04-28-alioth-bpf-kernelsu.md) — 实施计划（每步 bite-sized 任务）
- [`research/2026-04-28-ebpf-feature-survey.md`](research/2026-04-28-ebpf-feature-survey.md) — eBPF 特性调研（5.5 → 6.12 时间线）

### 工程日志（Phase 0 + Phase 1 完成）
- [`journey/2026-04-28-phase0-phase1-journey.md`](journey/2026-04-28-phase0-phase1-journey.md) — **完整工程日志：5 次砖手 + 11 个 KSU 兼容补丁的故事**

### Runbook
- [`runbook/2026-04-28-ksu-patches.md`](runbook/2026-04-28-ksu-patches.md) — **每个 KSU 文件改动的详细解释**
- [`runbook/2026-04-28-recovery-runbook.md`](runbook/2026-04-28-recovery-runbook.md) — **设备砖了怎么救**

### 项目级状态
- [`/STATUS.md`](../STATUS.md) — 当前 phase 进度、device 状态、下一步

## 快速导航

| 需求 | 看这个 |
|---|---|
| 我刷砖了 | [recovery-runbook](runbook/2026-04-28-recovery-runbook.md) |
| 想在另一台 4.19 设备复现 KSU 兼容补丁 | [ksu-patches](runbook/2026-04-28-ksu-patches.md) |
| 想理解为什么走到现在的方案（5 次砖的故事） | [phase0-phase1-journey](journey/2026-04-28-phase0-phase1-journey.md) |
| Phase 2（BPF backport）路线 | [feature-survey](research/2026-04-28-ebpf-feature-survey.md) §5 |
| 当前 active boot_a 跑啥版本 | [STATUS.md](../STATUS.md) |
