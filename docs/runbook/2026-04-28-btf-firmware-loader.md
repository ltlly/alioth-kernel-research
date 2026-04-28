# BTF Firmware Loader — Phase 2 BPF Unlock

**Date:** 2026-04-28
**Outcome:** `tracing` / `ext` / `lsm` BPF program types newly available on alioth 4.19-cip.

## Problem

CIP-128 已经把 `bpf_link` / `bpf_iter` / BPF trampoline / `struct_ops` / sleepable BPF 全部
backport 进 4.19。但 `BPF_PROG_TYPE_TRACING / EXT / LSM` 三个类型的 verifier 走 `btf_vmlinux`
路径，只有 `CONFIG_DEBUG_INFO_BTF=y` 时才填充。

`CONFIG_DEBUG_INFO_BTF=y` 在 alioth 上把 Image 大小从 58MB 推到 68MB（+10MB），bootloader
拒绝加载。所以传统的 in-kernel BTF 路径走不通。

## Solution

Patch `btf_parse_vmlinux()` 增加文件系统 fallback：
- 当 `__start_BTF == __stop_BTF`（无 .BTF section）时，
  `kernel_read_file_from_path()` 从下列路径按顺序找 BTF：
  1. `/vendor/firmware/vmlinux.btf` （Android 标准 firmware 路径）
  2. `/lib/firmware/vmlinux.btf`     （Linux 标准 firmware 路径）
  3. `/data/local/tmp/vmlinux.btf`   （研究/开发覆盖路径）
- 同步去掉 `bpf_get_btf_vmlinux()` 里的 `IS_ENABLED(CONFIG_DEBUG_INFO_BTF)` 守卫

## 实现细节（4 个改动）

### 1. `kernel/bpf/btf.c` — `btf_parse_vmlinux()` FS fallback

新增 `ksu_btf_load_from_fs()` helper + 在 `btf->data_size == 0` 时调用它。
errout 路径补漏：如果 btf->data 是 vmalloc 的（来自 FS），用 `vfree()` 释放，
避免每次 parse 失败漏 9.7MB。

### 2. `kernel/bpf/btf.c` — `btf_vmlinux_map_ids_init()` 容错

pahole 生成的 BTF 会优化掉 file-static 结构（如 `bpf_shtab`，sock_map.c 中静态
定义）。原始代码遇到一个找不到的 struct 名就 fail 整个 init。我们改成 skip 缺失项
继续跑——那些 map 类型的 `map_ptr_access` 不可用，但 tracing/lsm/ext 不依赖它。

### 3. `kernel/bpf/verifier.c` — `bpf_get_btf_vmlinux()` 解锁 + 限速

- 去掉 `IS_ENABLED(CONFIG_DEBUG_INFO_BTF)` 守卫
- 解析失败用 `ksu_btf_last_fail_jiffies` 5 秒限速重试，避免 spin loop OOM 杀进程
- 永远不存 ERR_PTR 进 `btf_vmlinux`（避免直接解引用的代码路径 oops）

### 4. BTF 文件生成

```bash
pahole -J --btf_features=encode_force,reproducible_build,var out/vmlinux
llvm-objcopy --dump-section=.BTF=vmlinux.btf out/vmlinux
```

注意 **不能**加：
- `--btf_gen_floats` （生成 BTF_KIND_FLOAT，4.19 解析器只到 KIND_MAX=15=DATASEC）
- `--btf_gen_all`     （隐含 ENUM64 等 6.x kind）

4.19 兼容 BTF kinds: INT(1) PTR(2) ARRAY(3) STRUCT(4) UNION(5) ENUM(6) FWD(7)
TYPEDEF(8) VOLATILE(9) CONST(10) RESTRICT(11) FUNC(12) FUNC_PROTO(13) VAR(14)
DATASEC(15). 5.13+ 起的 FLOAT(16) DECL_TAG(17) TYPE_TAG(18) ENUM64(19) 都不能有。

## 部署

将 strict BTF 文件放到设备的 `/data/local/tmp/vmlinux.btf`：

```bash
adb push workspace/kernel/patches/phase2-bpf-backport/00-survey/btf-fw/vmlinux.btf \
    /data/local/tmp/vmlinux.btf
```

加载时机是「首次 BPF 程序触发 verifier」。Android NetBpfLoad 在 boot 早期触发，
此时 `/data` 还没挂载——会失败一次。等用户级 `bpftool` 或 fentry 程序运行时，
`/data/local/tmp/` 已就位，加载成功。

## 验证

`bpftool feature probe` 输出：

```
eBPF program_type tracing is available    ← 新解锁
eBPF program_type ext is available        ← 新解锁
eBPF program_type lsm is available        ← 新解锁
eBPF program_type struct_ops is available
eBPF program_type sk_lookup is available
... （29 个全部 available）
eBPF program_type syscall is NOT available    ← 5.14+，未 backport
eBPF program_type netfilter is NOT available  ← 6.x，未 backport
```

dmesg 确认：

```
btf: loaded vmlinux BTF from /data/local/tmp/vmlinux.btf (9762784 bytes)
btf: btf_parse_vmlinux SUCCESS, 188258 types
```

## 已知限制

1. **BTF 文件不在 vendor 分区** — 用户需要手动 `adb push`，工厂复位后丢失。
   长期方案：把 BTF 烧到 `/vendor/firmware/`（需重新打包 vendor.img）。
2. **`bpf_shtab` 等 file-static 结构 BTF 缺失** — 几个 map 类型的 `map_ptr_access`
   不可用，但实际 tracing/lsm/ext 程序基本不需要这种内省。
3. **`syscall` 和 `netfilter` prog type 仍不可用** — 这俩属于真正需要源码 backport
   的 5.14+/6.x 特性，本次未做。
4. **加载有 ~50ms 延迟** — 第一个 tracing 程序加载时多一次 9.7MB 文件读取。

## 与现有功能的关系

P1 的 KSU、ftrace、kprobe、struct_ops 全部仍工作（无回归）。
device 上 60+ 个已加载 BPF 程序（NetBpfLoad / gpuMem / netd / ringbuf 等）
继续正常运行。

