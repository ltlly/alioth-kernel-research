# Phase 2 Survey — Findings (2026-04-28)

## TL;DR

CIP-128 已经把 Phase 2 计划的 5 个 backport 系列**几乎全部**带进 4.19。
真正没解锁的是 `tracing/ext/lsm` 三个 prog type，它们卡在缺 in-kernel BTF。
所以 Phase 2 的实际工作面收缩成**一个**：让 `btf_vmlinux` 在 4.19 上可用，且不增加内核 Image 大小。

## 源码侧（kernel/bpf/）已存在

| 系列 | 文件 / 符号 | 状态 |
|---|---|---|
| Series 1 — bpf_link | `kernel/bpf/syscall.c` 中 `bpf_link_init/prime/settle/cleanup/inc/put/new_fd`；`include/linux/bpf.h` 完整 struct + ops | ✅ 已存在（245 处引用） |
| Series 2 — bpf_iter | `kernel/bpf/bpf_iter.c`、`task_iter.c`、`map_iter.c` | ✅ 已存在 |
| Series 3 — BPF trampoline | `kernel/bpf/trampoline.c`、`arch/arm64/net/bpf_jit_comp.c` 中 `arch_prepare_bpf_trampoline` | ✅ 已存在 |
| Series 4 — struct_ops | `kernel/bpf/bpf_struct_ops.c`、`BPF_PROG_TYPE_STRUCT_OPS`、`BPF_MAP_TYPE_STRUCT_OPS` | ✅ 已存在 |
| Series 5 — sleepable | `BPF_F_SLEEPABLE`、`prog->aux->sleepable`（verifier.c:10535/12445/12500） | ✅ 已存在 |
| BPF_BTF_LOAD syscall | `kernel/bpf/syscall.c:3833` | ✅ 已存在 |

UAPI 中 `BPF_PROG_TYPE_TRACING / EXT / LSM`、`BPF_LINK_TYPE_TRACING / ITER` 都已定义。
`include/linux/bpf_types.h` 一共有 65 个 prog/map/link 类型条目。

## .config 侧（在跑的内核）

```
CONFIG_BPF=y
CONFIG_BPF_LSM=y
CONFIG_BPF_SYSCALL=y
CONFIG_BPF_JIT=y
CONFIG_BPF_JIT_ALWAYS_ON=y
CONFIG_BPF_EVENTS=y
CONFIG_KPROBES=y
CONFIG_FUNCTION_TRACER=y
CONFIG_DYNAMIC_FTRACE=y
CONFIG_FTRACE_SYSCALLS=y
CONFIG_DEBUG_INFO_BTF  ❌ 未设置（启用就把 alioth bootloader 撑爆）
```

## 设备运行时实测（`bpftool feature probe`）

**29 个 prog type 已可用**：
socket_filter, kprobe, sched_cls, sched_act, tracepoint, xdp, perf_event,
cgroup_skb, cgroup_sock, lwt_in, lwt_out, lwt_xmit, sock_ops, sk_skb,
cgroup_device, sk_msg, raw_tracepoint, cgroup_sock_addr, lwt_seg6local,
sk_reuseport, flow_dissector, cgroup_sysctl, raw_tracepoint_writable,
cgroup_sockopt, **struct_ops**, sk_lookup

**不可用**：
- ❌ `tracing` (fentry/fexit) ← 卡在缺 btf_vmlinux
- ❌ `ext` ← 同上
- ❌ `lsm` ← 同上
- ❌ `syscall` ← 5.14+，未 backport
- ❌ `netfilter` ← 6.x，未 backport
- ❌ `lirc_mode2` ← IR 设备相关，无关

## 卡点根因（一行）

`kernel/bpf/btf.c:4198`:
```c
extern char __weak __start_BTF[];
extern char __weak __stop_BTF[];
```

只在 `CONFIG_DEBUG_INFO_BTF=y` 时由 vmlinux linker script (`include/asm-generic/vmlinux.lds.h:596`) 填充。
否则 `__start_BTF == __stop_BTF == 0`，`btf_parse_vmlinux()` 拿到空 buffer → 失败 → `btf_vmlinux=NULL` → tracing/ext/lsm 永远跑不起来。

## 候选解锁路径

### Plan A — 收缩内核到 bootloader 限制以内（不确定）
启用 `CONFIG_LTO_CLANG_THIN`、删非必要 driver。可能拿不到 -10MB，每次 trial flash 都有砖机风险。

### Plan B — Patch `btf_parse_vmlinux()` 改为按需 firmware 加载（推荐）
- 改 `kernel/bpf/btf.c::btf_parse_vmlinux()`：当 `__start_BTF == __stop_BTF` 时，
  通过 `kernel_read_file_from_path("/lib/firmware/vmlinux.btf", ...)` 加载 BTF
- 9.7MB BTF 文件放到 `/system/etc/firmware/` 或 `/vendor/firmware/`
- 内核 Image **零增长**（避开 bootloader 限制）
- 改动量：~50 行 btf.c + 一个 init.rc 拷贝 entry
- 副作用：tracing prog 首次 load 时延迟 ~50ms（一次性 BTF 解析）

### Plan C — 走 BPF_BTF_LOAD（不通）
`BPF_BTF_LOAD` 只能给单个 program 提供 attach BTF，不会写到全局 `btf_vmlinux`。
不够触发 tracing/lsm/ext 解锁。✗

## 决定

**走 Plan B。** 下一步：实现 patch + 把 vmlinux.btf 推到 firmware path。
