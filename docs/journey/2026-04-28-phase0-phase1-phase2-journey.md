# Alioth Kernel — Phase 0 & Phase 1 工程日志

**记录时间：** 2026-04-28
**目标设备：** Xiaomi alioth (Redmi K40 / POCO F3 / Mi 11X)，sm8250
**目标内核：** Linux 4.19.325-cip128（LineageOS 23.2 nightly）
**目标产出：** 自编内核 + BTF + dynamic ftrace + kprobes + 最新 KernelSU v3.2.4

这份文档完整记录了完成 Phase 0（vanilla 重新编译）和 Phase 1（BTF + ftrace + KSU）过程中**踩过的坑**和**每一个修复**。给后来者看的——避免重蹈覆辙。

---

## 总体时间线（约 4 小时）

| 时间 | 事件 |
|---|---|
| 14:00 | 项目启动，工作区 + 脚本搭建 |
| 14:12 | Stock 镜像备份完成（boot/dtbo/vbmeta + 后补 vendor_boot） |
| 14:24 | 用户内核源码 clone 完成 |
| 14:30-15:30 | **5 次 fastboot boot 砖** + 长按电源恢复 — 排查 vermagic / config / packing / AVB 等 |
| 15:30 | **关键发现**：alioth 是 Virtual A/B 设备，slot _b 不能独立启动 |
| 16:08 | NDK r29 下载完成（r563880c 与 stock 完全同源） |
| 16:12 | Phase 0 vanilla 编译 + 启动成功 |
| 16:33 | Phase 1 第一次构建（BTF+ftrace 一起开） |
| 16:38-17:10 | **3 次 BTF 砖** — 定位 CONFIG_DEBUG_INFO_BTF=y 是元凶，切换为 detached BTF |
| 17:25-17:46 | 11 个 KSU 源文件兼容补丁，最终 v3.2.4 编译成功 |
| 17:46 | Phase 1 持久化到 boot_a；KSU module 加载 |

---

## Phase 0 — Vanilla 重编译：5 次砖手的故事

### 设计假设

我们以为：用相同源码 + 相同配置 + 兼容编译器 → 出一个能启动的内核。
**结果：连续 5 次 fastboot boot 之后设备完全无响应**，需要长按电源重启。

### 砖 1：系统 clang 21.1（Ubuntu）

**做了什么：** 用 Ubuntu 自带的 `clang-21` 编译

**结果：** 镜像 transferred OK，"Booting OKAY" 但 adb 永远不回，USB 整个掉线

**误判：** 一开始怀疑 vermagic 不匹配 / 配置漂移

**真相：** 验证后两者都和 stock **完全相同**——只有编译器版本元数据 6 行差异

**教训：** 同一个 LLVM 主版本（21）但不同 fork（Ubuntu vs Android）会产生不能启动的二进制

### 砖 2：AOSP clang-r584948（LLVM 22）

**做了什么：** sparse-checkout AOSP `prebuilts/clang/host/linux-x86`，得到 r584948（LLVM 22）

**结果：** 同样砖

**学到的：** r584948 比 stock 用的 r563880c **新一个主版本**——clang 21 → 22 之间的代码生成差异足以让 4.19+alioth 生态不能启动

### 误判：AVB 校验问题

**做了什么：** `fastboot --disable-verification flash vbmeta_a/b`，希望关掉 AVB 验证

**结果：** 还是砖

**事后分析：** vbmeta 本身的 `Flags=3` 已经包含 `VERIFICATION_DISABLED + HASHTREE_DISABLED`，再设一遍是 no-op

**教训：** AVB **不是**根因。可以浪费时间但不是阻塞项

### 关键诊断对照实验

为了证明问题不在 packing 流程：

```
实验 A: stock kernel + 我们的 packer  → ✅ 正常启动
实验 B: 我们的 kernel + stock 风格 packer → ❌ 砖
```

**确凿结论：问题在我们编译的内核二进制里，与 packer / AVB 都无关**

### 砖 3-5：理解 Virtual A/B

**做了什么：** P0 vanilla 验证 3 次 fastboot boot 都好，开心地 `fastboot flash boot_b + --set-active=b`

**结果：** 设备没回来——必须长按

**根因发现：** alioth 是 **Virtual A/B 设备**：
```
$ adb shell ls /dev/block/mapper
odm_a, odm_a-cow, product_a, product_a-cow, system_a, system_a-cow, ...
```

只有 `_a` slot 有真正的 system / vendor / product 分区。`_b` slot 只有 COW snapshot 用于 OTA 增量合并——**不能独立启动**。

```
$ lpdump --slot 1
Header flags: virtual_ab_device
```

**教训：** A/B 设备 ≠ Virtual A/B 设备。前者两 slot 各自完整可启动，后者只有 _a 真实存在，_b 只在 OTA 流程里短暂有效。

**修复：** 改 `flash-commit.sh`，直接刷 `boot_a`（active slot），保留 stock 备份用于回退而不是用 `_b` 当备胎。

### 终极方案：NDK r29 = clang r563880c 完全匹配

stock kernel `/proc/version` 显示：
```
clang version 21.0.0 (... llvm-project 5e96669f06077099aa41290cdb4c5e6fa0f59349)
Android (14054515, +pgo, +bolt, +lto, +mlgo, based on r563880c)
```

NDK r29（2026 年 3 月发布的最新 NDK）内置 clang：
```
clang version 21.0.0 (... llvm-project 5e96669f06077099aa41290cdb4c5e6fa0f59349)
Android (13989888, +pgo, +bolt, +lto, +mlgo, based on r563880c)
```

**llvm-project commit 完全相同**，只 build number 不同。

**下载方式：** 直接 Google CDN
```bash
curl -fL -o /tmp/ndk.zip \
  "https://dl.google.com/android/repository/android-ndk-r29-linux.zip"
# 783MB, sha1=87e2bb7e9be5d6a1c6cdf5ec40dd4e0c6d07c30b
unzip /tmp/ndk.zip -d ~/Android/Sdk/ndk/
```

**再次编译 + 启动 → 第一次成功！**

字节差异从「错 clang 时」的 37.8M 直接降到「对的 clang」的 15.7M（剩下的是 build user / timestamp / paths 字符串差异，不影响功能）。

---

## Phase 1 — BTF + ftrace + KernelSU

### BTF 三连砖

**做了什么：** 加 `CONFIG_DEBUG_INFO_BTF=y` 到 defconfig overlay，重编

**第一次编译失败：** `link-vmlinux.sh` 调用 `tools/bpf/resolve_btfids` 但 4.19 没有这个工具

**修复 1：** `link-vmlinux.sh` 改成「工具不存在就跳过 BTFIDS 步骤」：
```diff
-${RESOLVE_BTFIDS} vmlinux
+if [ -x "${RESOLVE_BTFIDS}" ]; then ${RESOLVE_BTFIDS} vmlinux;
+else info "BTFIDS" "skipping (resolve_btfids not present in 4.19)"; fi
```

**编译过了，但 fastboot boot → 砖**

**砖 6, 7（BTF）：** 即便不带 ftrace 单独开 BTF，照样砖。

**根因：** `CONFIG_DEBUG_INFO_BTF=y` 让 pahole 把 `.BTF` section 嵌进 vmlinux，Image 从 47MB 涨到 58MB。这超过了 alioth bootloader 的某个隐式限制（fastboot boot 静默 fallback 到 flash 的 boot_a；flash 之后的 kernel 也无法启动）。

**Plan B：detached BTF**
- 保持 kernel 不开 `DEBUG_INFO_BTF`（仍 47MB 能启动）
- 单独跑一次 `DEBUG_INFO_BTF=y` 编译，从 vmlinux 提 BTF：
  ```bash
  llvm-objcopy --dump-section .BTF=vmlinux.btf vmlinux
  ```
- 把 `vmlinux.btf` push 到 `/data/local/tmp/vmlinux.btf`
- BPF 工具用 `--btf /data/local/tmp/vmlinux.btf` 显式指向

**结果：CO-RE 工具能用，kernel 不砖**

### CONFIG_KPROBES 暗坑

**问题：** overlay 写了 `CONFIG_KPROBE_EVENTS=y`，编译完发现 `/sys/kernel/tracing/kprobe_events` 不存在

**原因：** `KPROBE_EVENTS depends on KPROBES` 而原生 alioth defconfig 没开 `CONFIG_KPROBES`。`merge_config.sh` 静默把 KPROBE_EVENTS 重置为不开。

**修复：** overlay 多加一行 `CONFIG_KPROBES=y`，依赖链顺过来

### tracefs 路径变化

**踩坑：** 教程写 `/sys/kernel/debug/tracing/`，alioth Android 16 实际在 `/sys/kernel/tracing/`（tracefs 单独 mount）

### 概率小但确实出现的：probe 误报

**踩坑：**
```bash
adb shell 'dmesg | grep -iE "BUG:|Oops|kernel panic"'
```
返回 "ramoops"（匹配 "Oops"）和 "spmi_pmic_arb_debug"（匹配 "BUG"）—— **大小写不敏感的子串匹配会误报**

**修复：** 改用空格定界：
```bash
grep -E "BUG: |Unable to handle kernel|Kernel panic| Oops "
```
（toybox grep 不支持 `\b` 字边界）

### KernelSU 适配地狱

我们尝试了 4 个 KSU 版本：

| 版本 | 时间 | 错误 |
|---|---|---|
| master (v3.2.4-22-g7fb5fd3e) | latest | MODULE_IMPORT_NS / iopoll / REMAP_FILE_DEDUP / handle_inode_event / TWA_RESUME / SECCOMP_ARCH_NATIVE_NR / 'uapi/linux/mount.h' / selinux_state.policy / filename_trans_key / tasklist_lock |
| v2.0.0 | 2025-11-05 | 同上少量减去 file_wrapper |
| v1.0.0 | 2024-06 | 仍要 SELinux 5.7+ 重构后的 API |
| **回到 v3.2.4，逐一兼容** | | 11 文件补丁，最终成功 |

详细每个文件的修法见 [`KSU-PATCHES.md`](../runbook/2026-04-28-ksu-patches.md)

#### 简短的修复模式

每个不兼容的 .c 文件都按以下模式包：
```c
#include <linux/version.h>

#if LINUX_VERSION_CODE >= KERNEL_VERSION(<X>, <Y>, 0)
/* 原代码 */
[原全部内容]
#else
/* 4.x stubs */
[空实现，签名匹配头文件] 
#endif
```

需要 stub 的导出函数：每个公开 API 都要给 4.19 提供一个 no-op 版本，**否则链接器报 undefined symbol**。这是大量机械工作。

#### KSU 启动时挂死 → bisect

KSU 编译过了，但 fastboot boot 砖。验证下来 KSU `module_init` 期间**某个调用让 kernel 挂死**。

**bisect 方法：** 在 `kernelsu_init` 函数最前面加 `return 0;`，验证其余 kernel 部分是否完好——结果**正常启动**，证明问题在 KSU 内部。

**渐进恢复：** 一次启用一组 init 调用，**最后定位**到 `ksu_syscall_hook_init()` 和 `ksu_syscall_hook_manager_init()` 是元凶。

这两个函数：
- `ksu_syscall_hook_init`: 修改 syscall table 用 patch_memory.c 写代码段
- `ksu_syscall_hook_manager_init`: 注册 kretprobe 在 syscall_regfunc/unregfunc，并通过 ksu_register_syscall_hook 替换 sys_call_table 的对应项

4.19 的 syscall table 布局 / patch_memory 期望和 5.10+ 不同，导致 patch_memory 写到错的地方 → kernel panic / 死锁 → 启动挂

**最终方案：** 这两个函数在 init 里跳过，KSU 模块仍加载，feature_init / sulog / adb_root 等 handler 注册成功，但**没有 execve / setresuid 拦截**

### 最终交付物

```
boot_a (持久):
  Linux 4.19.325-cip128-st12-perf-ga5b3099017ae-dirty
  (claude@research) Tue Apr 28 17:46:14 CST 2026
  + dynamic ftrace (68942 functions)
  + kprobe events
  + uprobe events  
  + KernelSU module (partial — see caveats)

/data/local/tmp/vmlinux.btf (持久):
  9.7MB BTF for libbpf CO-RE programs
```

---

## 防火与回滚

### 三层兜底

**L1 - fastboot boot 测试**（早期诊断阶段用过）
- 镜像不写 flash，加载到 RAM 临时启动
- 砖了 → 长按电源 → 回 stock
- **限制：** 大于 ~50MB 的 boot.img 会被 alioth bootloader 静默拒绝（fall back 到 flashed boot_a）

**L2 - 直接刷 boot_a，保留本地 stock 镜像**
- `recover.sh` 实现：检测设备入 fastboot 后 `fastboot flash boot_a workspace/stock-images/boot_a-original.img`
- 任何砖只要还能进 bootloader → 1 命令恢复

**L3 - EDL 紧急下载（未触发）**
- alioth 有测试点短接 EDL 的方法
- 这次没用到，但是终极保险

### 备份清单（不可变）

```
workspace/stock-images/SHA256SUMS:
  f34bc07a... boot_a-original.img (192MB)
  f34bc07a... boot_b-original.img (= a)
  d99f80d8... dtbo_a-original.img (32MB)
  d99f80d8... dtbo_b-original.img (= a)
  0b0737f3... vbmeta_a-original.img (128KB)
  fa8ddf56... vbmeta_b-original.img
  be2b3a27... vendor_boot_a-original.img (96MB)
  be2b3a27... vendor_boot_b-original.img (= a)
```

文件设了 chmod -w 防止误删。

---

## 本次工程的关键学习

1. **A/B 设备和 Virtual A/B 设备完全不同** —— 看 `lpdump` 的 `virtual_ab_device` flag。Virtual A/B 不能用「双 slot 备胎」策略。
2. **同主版本 LLVM 不等于二进制兼容** —— Ubuntu clang 21.1 和 AOSP r563880c 的 LLVM 21 都能编出 vmlinux，但只有后者产物能在 alioth 启动。NDK 是最方便的 AOSP clang 来源。
3. **alioth bootloader 对 boot.img 大小有静默限制** —— 推测 ~50MB。超过后 fastboot boot **不报错**，直接 fallback 到 flashed boot_a。诊断时极度迷惑。开 `CONFIG_DEBUG_INFO_BTF=y` 是最常见的触发原因。
4. **CONFIG_DEBUG_INFO_BTF=y 在 4.19 + 大型 vendor 树上是个炸弹** —— 详见 BTF 三连砖。Detached BTF 是干净的退路。
5. **Module CRC 不是问题** —— `CONFIG_MODVERSIONS=y` 算的 CRC 来自 C 类型信息（与编译器无关），同源码 = 同 CRC，vendor 模块能正常加载。
6. **AVB 在 unlocked 状态下不阻 fastboot boot** —— 这次诊断浪费了一些时间但学到了 vbmeta 标志的实际行为。
7. **KernelSU 在 v1.0+ 真的不支持非 GKI** —— 不是文档严不严格的问题，是 5.7+ 的 SELinux 重构让代码语义层面无法兼容。需要 fork 维护一个独立分支。

---

## 可重现的最终命令链

从一台干净的 alioth + LineageOS 23.2 环境开始：

```bash
# 0. Bootstrap
cd ~/Code/kernel_research
git init
mkdir -p workspace/{toolchain,kernel,stock-images,builds,tests} scripts/probes runs

# 1. 系统依赖
sudo apt install -y bison flex bc ccache lz4 cpio python3-dev libssl-dev libelf-dev clang gawk dwarves lld llvm

# 2. NDK r29（exact match for stock kernel's clang r563880c）
mkdir -p ~/Android/Sdk/ndk
cd ~/Android/Sdk/ndk
curl -fL -o /tmp/ndk.zip "https://dl.google.com/android/repository/android-ndk-r29-linux.zip"
unzip -q /tmp/ndk.zip

# 3. mkbootimg / avbtool
cd ~/Code/kernel_research/workspace/toolchain
git clone --depth 1 --quiet https://android.googlesource.com/platform/system/tools/mkbootimg
git clone --depth 1 --quiet https://android.googlesource.com/platform/external/avb avbtool-src
ln -sf "$PWD/avbtool-src/avbtool.py" "$PWD/mkbootimg/avbtool.py"

# 4. Kernel source
cd ~/Code/kernel_research/workspace/kernel
git clone --depth 50 --branch lineage-23.2 \
  https://github.com/LineageOS/android_kernel_xiaomi_sm8250.git

# 5. KernelSU integration
cd android_kernel_xiaomi_sm8250
bash ~/Code/kernel_research/workspace/kernel/KernelSU/kernel/setup.sh main

# 6. Apply 11 compatibility patches (see KSU-PATCHES.md)
# 7. Backup device images, configure recovery script
# 8. Build with NDK r29 clang, pack, flash boot_a
# 9. Push detached BTF to /data/local/tmp/vmlinux.btf
```

详细每个补丁见 [`docs/runbook/2026-04-28-ksu-patches.md`](../runbook/2026-04-28-ksu-patches.md)。

---

## Phase 2 — BPF tracing/lsm/ext 解锁（同日下午 21:00 - 21:50）

### 调研发现：CIP 已经做了大半工作

进入 Phase 2 之前的设计文档假设要 cherry-pick 5 个 patch 系列（bpf_link 5.7、bpf_iter 5.6、trampoline 5.5、struct_ops 5.6、sleepable 5.10）。**实际跑 grep 后才发现 CIP-128 已经全部 backport 了**：

```
$ grep -rn "bpf_link\|BPF_LINK_TYPE" kernel/bpf/ include/linux/bpf.h | wc -l
245
$ ls kernel/bpf/{bpf_iter,trampoline,bpf_struct_ops}.c
存在
$ grep "BPF_F_SLEEPABLE\|prog->aux->sleepable" kernel/bpf/verifier.c
12500: if (prog->aux->sleepable && ...
```

而且 UAPI 里 `BPF_PROG_TYPE_TRACING / EXT / LSM` 都是定义好的、`BPF_LINK_TYPE` 7 个全的。

### 真正的卡点：`bpftool feature probe` 报告

| Prog type | 状态 | 卡在哪里 |
|---|---|---|
| `tracing` (fentry/fexit) | NOT available | `btf_vmlinux` 没填充 |
| `lsm` (BPF_PROG_TYPE_LSM) | NOT available | 同上 |
| `ext` (extensions) | NOT available | 同上 |
| `struct_ops` | available | OK |
| `bpf_iter` 配套 | 26 个全 OK | OK |

`grep "btf_vmlinux = btf_parse_vmlinux"` 找到一行：

```c
// kernel/bpf/verifier.c:12562
if (!btf_vmlinux && IS_ENABLED(CONFIG_DEBUG_INFO_BTF)) {
    btf_vmlinux = btf_parse_vmlinux();
}
```

**整个 BPF 高级 prog type 解锁卡在一个 IS_ENABLED 守卫。** 而 `CONFIG_DEBUG_INFO_BTF=y` 又会让 Image 长 10MB，触发我们 Phase 1 三次砖的同一个问题。

### Plan B：FS firmware loader

不开 `CONFIG_DEBUG_INFO_BTF`，patch `btf_parse_vmlinux()` 改成「.BTF section 是空的就从文件加载」：

```c
if (btf->data_size == 0) {
    err = ksu_btf_load_from_fs(&btf->data, &btf->data_size);
    if (err) goto errout;
}
```

按顺序找 `/vendor/firmware/` → `/lib/firmware/` → `/data/local/tmp/vmlinux.btf`。
内核 Image 零增长，绕开 alioth bootloader 限制。

### 第二次踩坑：「kernel image 不更新」

v1 patch 放进去 build → flash-test → 启动正常。但跑 bpftool 时 tracing 仍然 NOT available。dmesg 里没有 BTF 加载日志。

排查：发现 `bpf_get_btf_vmlinux()` 里那个 `IS_ENABLED(CONFIG_DEBUG_INFO_BTF)` 守卫还在！需要去掉守卫才会调用 btf_parse_vmlinux。

去掉守卫，build v2 → fastboot boot → uname 显示 **OLD** kernel `#20 ... 20:25:38`，新构建 `#23` 没起来。Bootloader 把我们 v2 启动失败的内核打回 slot _a 的 P1+KSU。

为什么早启动会 panic？
- `bpf_get_btf_vmlinux()` 在 `bpf_check()` 里被调用，**每次 BPF 程序 load 都触发**
- Android `NetBpfLoad` 在 boot 后 ~5 秒内加载 sched_cls 程序
- 这时 `/data/local/tmp/` 还没挂载，文件读取失败 → btf_parse_vmlinux 返回 ERR_PTR
- ERR_PTR 被 cache 进 `btf_vmlinux` 全局变量
- 后续代码（如 `bpf_struct_ops_init`）用 `btf_type_by_id(btf_vmlinux, ...)` 直接解引用 ERR_PTR → kernel oops

修复 v3：
- **永远不缓存 ERR_PTR** 到 `btf_vmlinux`，只缓存有效指针或 NULL
- 失败的话 5 秒限速重试（防止失败 spin loop OOM 杀进程）

v3 启动正常。

### 第三次踩坑：BTF parse 失败

v3 装好后 dmesg 显示 BTF 文件被 9 次成功 loaded（说明 retry 起作用），但仍然没有 success 日志。在每个 parse 步骤前插 pr_warn 后定位到 `btf_check_all_metas failed err=-22`：

```
BPF:[1916] ENUM perf_event_state 
BPF:Invalid btf_info kind_flag
btf: btf_check_all_metas failed err=-22
```

我们的 BTF 文件是早些时候 `pahole -J --btf_gen_floats` 生成的，里面包含了 5.13+ 才有的 BTF kinds。4.19 的解析器只到 `BTF_KIND_DATASEC=15`，遇到 `FLOAT(16) / DECL_TAG(17) / TYPE_TAG(18) / ENUM64(19)` 一律 EINVAL。

重新生成 strict-4.19 BTF：

```bash
pahole -J --btf_features=encode_force,reproducible_build,var out/vmlinux
llvm-objcopy --dump-section=.BTF=vmlinux.btf out/vmlinux
```

注意 features 里**不能**包含 `float`。

### 第四次踩坑：file-static struct 被 pahole 优化掉

strict BTF 推上去后 `btf_check_all_metas` 过了，但 `btf_vmlinux_map_ids_init failed err=-2`。dmesg 显示：

```
btf: map_btf_name 'bpf_shtab' not in BTF (idx=18)
```

`bpf_shtab` 是 `net/core/sock_map.c` 里的 file-static struct（不被任何外部符号引用）。pahole 从 DWARF 只生成「被引用」的类型 BTF，文件内 static struct 被优化掉。

修复：改 `btf_vmlinux_map_ids_init()` 容错——找不到 map_btf_name 就 skip 不 fail：

```c
if (btf_id < 0) {
    pr_info("btf: map_btf_name '%s' not in BTF — map_ptr access disabled\n", ...);
    continue;  // 之前是 return
}
```

那几个 map type 失去 `map_ptr_access` 能力，但 tracing/lsm/ext 不依赖这个。

### v6：`btf_parse_vmlinux SUCCESS, 188258 types`

第六次构建（btf.c + verifier.c + 容错 + 限速 + 内存泄漏修复 + strict BTF）跑出来：

```
[59.684] btf: loaded vmlinux BTF from /data/local/tmp/vmlinux.btf (9762784 bytes)
[59.711] btf: btf_parse_vmlinux SUCCESS, 188258 types
```

`bpftool feature probe`：

```
eBPF program_type tracing is available    ← 新解锁
eBPF program_type lsm is available        ← 新解锁
eBPF program_type ext is available        ← 新解锁
```

🏆 **三个之前完全用不了的 prog type 全部上线。**

### Phase 2 时间线

| 时间 | 事件 |
|---|---|
| 21:00 | 用户决定进入 Phase 2 |
| 21:05 | 跑 grep 调查源码已存在情况 → 大惊喜 |
| 21:10 | 跑 `bpftool feature probe` → 确认是 BTF 卡点 |
| 21:11 | 写 STRATEGY.md，决定 Plan B |
| 21:15 | v1 patch（btf.c FS fallback）build OK，启动 OK，但 tracing 仍 NOT |
| 21:18 | 发现还要 patch verifier.c，去掉 IS_ENABLED 守卫 |
| 21:19 | v2 build → 砖（早启动 ERR_PTR 缓存导致 oops） |
| 21:20 | v3 加 system_state guard + 不缓存 ERR_PTR + 5 秒限速 → 启动 OK 但 BTF parse 失败 |
| 21:30 | 加 pr_warn 调试 → 定位 `btf_check_all_metas err=-22` |
| 21:34 | 重新 pahole 生成 strict-4.19 BTF（去掉 float） |
| 21:35 | 新错误 `btf_vmlinux_map_ids_init err=-2 (bpf_shtab not in BTF)` |
| 21:40 | 改 map_ids_init 容错 |
| 21:41 | v5 build OK，但仍有 vmalloc 泄漏 → 加 vfree on errout |
| 21:45 | v6 build OK + final BTF push → **全部 prog type 解锁** |
| 21:50 | 写 runbook + STATUS.md + FINAL-ACHIEVEMENTS.md |

### Phase 2 经验教训

1. **先跑 grep 再写 plan** —— 我们差点要 cherry-pick 几百个 commit。CIP 已经做了。验证现状是计划开始的第一步。
2. **`IS_ENABLED(CONFIG_X)` 守卫要小心** —— 有时候 backport 工作没做完不是因为代码不在，是因为一个 if 把整条路堵了。
3. **早启动加 kernel_read_file 是雷** —— 任何在 `bpf_check()` 这种「会被 NetBpfLoad 在 boot 5 秒内触发」的路径上加文件 IO 都要做好失败缓存策略。
4. **永远不要 cache ERR_PTR** 到一个其他代码会直接 deref 的全局指针。要么 NULL，要么有效指针。
5. **pahole 选 features 要严格** —— `--btf_gen_all` / `--btf_gen_floats` 都会生成 4.19 不认的 kind。`--btf_features=encode_force,reproducible_build,var` 是安全集。
6. **pahole 会优化掉 file-static struct** —— 这是合理的（DWARF 只看引用），但要做 graceful degradation 处理。
7. **每个 errout 都要清理资源** —— 我的 vmalloc 缓冲区漏掉了 vfree，每次 parse 失败漏 9.7MB，4 分钟内 OOM 把 bpftool 杀了。

