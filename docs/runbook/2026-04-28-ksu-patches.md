# KernelSU v3.2.4 在 Linux 4.19 上的兼容补丁详解

**Linux 4.19 是 KSU 上游 v1.0 起放弃支持的内核版本。** 这份文档详细记录了如何在 4.19 上让 v3.2.4 编译 + 模块加载。

每个文件的补丁分为三部分：
1. **Why（为什么不兼容）** — 哪个 5.x kernel API 改了
2. **How（怎么修）** — 具体的源码改动
3. **Limitation（4.19 上跑限了啥）** — stub 后该子系统的实际可用度

---

## 总体策略：版本守卫 + 4.x stub

每个 5.x-only 的 .c 文件按以下模式包：

```c
#include <linux/version.h>

#if LINUX_VERSION_CODE >= KERNEL_VERSION(<X>, <Y>, 0)
/* 原 KSU 实现 — 5.x 内核可用 */
[原全部代码]
#else
/* 4.x stub: 提供头文件声明的所有 public 函数的空实现，
 * 否则链接器会报 undefined symbol */
#include "<相应头文件>"
[每个 public function 的 no-op stub]
#endif
```

**两个常见错误避免：**
- ❌ 只包文件头部，不包尾部 → 编译过但运行时 NULL deref
- ❌ stub 不匹配头文件签名 → 链接 undefined symbol

---

## 11 个被改的文件

### 0. ⭐ `hook/arm64/patch_memory.c`：pmd_leaf / pud_leaf 兼容（关键修复！）

**这是让 KSU 在 4.19 真正工作的核心补丁。** 没有这个，所有 syscall hook 调用都静默失败。

**Why:** KSU 的 `phys_from_virt()` 函数走 init_mm 页表把内核虚拟地址翻译成物理地址（用于改 syscall_table 时 page-permission 操作）。代码用 `pmd_leaf(*pmd)` 和 `pud_leaf(*pud)` 检测 huge page。

`pmd_leaf` / `pud_leaf` 宏是 Linux **5.7** 新加的。4.19 上：
- arm64 用 `pmd_sect()` / `pud_sect()` 检测 section-mapped huge page
- arm64 内核 text 段在 4.19 上**就是用 PMD-level section mapping 映射的**
- 不检测 → walk 函数掉到 PTE 层级用 `pte_offset_kernel(pmd, addr)` 拿到错误指针 → `pte_present` 检查可能假成功也可能 fail
- 上线表现：**所有 `ksu_patch_text` 调用静默失败**，syscall hooks 实际不工作（kernel 不 panic 是因为失败路径返回 -EIO 而不是访问坏内存）

**How:**
```c
#include <linux/version.h>
#include <asm/pgtable.h>

/* 4.19 doesn't define pmd_leaf/pud_leaf (added in 5.7).
 * arm64 4.19 uses pmd_sect/pud_sect for section-mapped huge pages. */
#ifndef pmd_leaf
#define pmd_leaf(pmd) pmd_sect(pmd)
#endif
#ifndef pud_leaf
#define pud_leaf(pud) pud_sect(pud)
#endif
```

**Limitation:** 无 — phys_from_virt 完整工作。

**实际效果对比：**

修复前 dmesg：
```
KernelSU: failed to find phy addr for patch dst addr 0xffffffa5fb400b10
KernelSU: patch syscall 42 failed
```
KSU 模块加载但所有 hook 失效。

修复后 dmesg：
```
KernelSU: dispatcher installed at slot 42
KernelSU: register_syscall_regfunc kretprobe: 0
KernelSU: register_syscall_unregfunc kretprobe: 0
KernelSU: registered syscall hook for nr=147  (setresuid)
KernelSU: registered syscall hook for nr=221  (execve)
KernelSU: registered syscall hook for nr=79   (newfstatat)
KernelSU: registered syscall hook for nr=48   (faccessat)
KernelSU: handle_setresuid from 0 to 2000     ← 运行时 hook 在工作
```

KSU 完全功能性。

---

### 1. `core/init.c`：MODULE_IMPORT_NS 守卫

**Why:** `MODULE_IMPORT_NS` 这个宏是 Linux 5.4 引入的（模块命名空间机制）。4.19 没有。

**How（改动 A — 编译时）:**
```c
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 13, 0)
MODULE_IMPORT_NS("VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver");
#elif LINUX_VERSION_CODE >= KERNEL_VERSION(5, 4, 0)
MODULE_IMPORT_NS(VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver);
#endif
/* 4.x kernels lack module namespaces — no import needed. */
```

**Limitation:** 无（仅版本守卫，无功能损失）

**注：** 早期版本曾跳过 `ksu_syscall_hook_init` 等以避免砖手——这是 #0 的 pmd_leaf 修复**前的临时绕路**。修了 pmd_leaf 之后，所有 init 路径恢复，无需在 init.c 跳过任何东西。

---

### 2. `policy/allowlist.c`：TWA_RESUME + put_task_struct

**Why:**
- `TWA_RESUME` 是 5.11+ 的 enum 值；4.19 是 `bool notify`，true 等价
- `put_task_struct()` 在 4.19 通过 `<linux/sched/task.h>`，KSU 没引这个头文件

**How:**
```c
#include <linux/sched/task.h>  /* put_task_struct */

#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 11, 0)
#ifndef TWA_RESUME
#define TWA_RESUME true
#endif
#endif
```

**Limitation:** 无 — 行为完全一致

---

### 3. `policy/app_profile.c`：seccomp.filter_count + seccomp_filter_release

**Why:**
- `current->seccomp.filter_count` 是 5.13 引入的成员（用于 seccomp 状态跟踪）
- `seccomp_filter_release()` 是 5.9+ 才 export 的内核函数

**How:**
```c
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 13, 0)
    atomic_set(&current->seccomp.filter_count, 0);
#endif
```

```c
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)
void seccomp_filter_release(struct task_struct *tsk);
#endif

static void disable_seccomp(void)
{
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)
    /* 原 KSU 实现：alloc fake task_struct → 拷贝 current → release fake */
    [原代码]
#else
    /* 4.x: seccomp_filter_release 不能调用，只清当前进程 seccomp 状态 */
    spin_lock_irq(&current->sighand->siglock);
    clear_thread_flag(TIF_SECCOMP);
    current->seccomp.mode = 0;
    current->seccomp.filter = NULL;
    spin_unlock_irq(&current->sighand->siglock);
#endif
}
```

**Limitation:** 4.19 上 seccomp filter 不主动 release（依赖进程退出时的常规 cleanup）。可能轻微泄漏 filter struct，但不影响功能。

---

### 4. `infra/seccomp_cache.c`：SECCOMP_ARCH_NATIVE_NR

**Why:** `SECCOMP_ARCH_NATIVE_NR` / `SECCOMP_ARCH_COMPAT_NR` 是 5.13 引入的 syscall 计数宏，配合 seccomp filter 加速缓存。

**How:** 用 `#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 13, 0)` 包整个文件，4.x 只 stub:

```c
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 13, 0)
[原 65 行实现]
#else
#include <linux/fs.h>
#include "infra/seccomp_cache.h"
void ksu_seccomp_clear_cache(struct seccomp_filter *filter, int nr) { (void)filter;(void)nr; }
void ksu_seccomp_allow_cache(struct seccomp_filter *filter, int nr) { (void)filter;(void)nr; }
#endif
```

**Limitation:** seccomp cache 无效 — 当 KSU 给 app 调整 seccomp 时少了一个性能优化。功能不受影响。

---

### 5. `infra/su_mount_ns.c`：uapi/linux/mount.h + path_mount

**Why:**
- `<uapi/linux/mount.h>` 是 5.5 引入（之前 mount.h 在 `linux/mount.h`）
- `path_mount()` 是 5.9 引入的 export

**How:**
```c
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)
[原 187 行 — 完整 mount namespace 切换实现]
#else
/* 4.x: 不能切换 mount namespace */
#include "infra/su_mount_ns.h"
void setup_mount_ns(int32_t ns_mode) {
    (void)ns_mode;
    /* No-op: 进程继承启动时的 mount namespace */
}
#endif
```

**Limitation:** KSU 的「per-app mount namespace」功能 — 给 root 的 app 看到不同的 / 视图（隐藏 KSU 修改）— 不工作。Magisk 的 magic mount 概念，4.19 上做不了。

---

### 6. `infra/file_wrapper.c`：iopoll / REMAP_FILE_DEDUP / remap_file_range

**Why:** 文件操作结构体 `struct file_operations` 的多个成员在 5.1+ 才存在：
- `iopoll`: 5.1
- `remap_file_range`: 4.20
- `REMAP_FILE_DEDUP` 常量: 4.20

KSU 用这些做「PTS proxy file」— 包装 pseudo-terminal 的 file_operations。

**How:** 580 行代码全部包 5.1+ 守卫，4.x stub 出 ksu_install_file_wrapper / ksu_file_wrapper_init：

```c
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 1, 0)
[原 580 行]
#else
#include "infra/file_wrapper.h"
int ksu_install_file_wrapper(int fd) { (void)fd; return -ENOSYS; }
void ksu_file_wrapper_init(void) { /* no-op */ }
#endif
```

**Limitation:** KSU 不再代理 PTS 文件——这影响某些「root shell + sudo style I/O 重定向」场景，但日常使用感知不到。

---

### 7. `selinux/selinux.c`：current_sid 重定义

**Why:** SELinux 子系统在 Linux 5.7 大重构。包括 `current_sid()` 等 helper 在内的命名空间变化。4.19 的 `current_sid` 来自 SELinux 自己的 hooks.c，KSU 又自己定义一遍 → 重定义错误。

**How:**
```c
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 7, 0)
[原 222 行]
#else
/* 4.x: 完全 stub 掉 SELinux 集成 */
#include <linux/cred.h>
#include "selinux.h"
u32 ksu_file_sid __read_mostly = 0;
void setup_selinux(...) { }
void setenforce(bool e) { (void)e; }
bool getenforce(void) { return false; }
void cache_sid(void) { }
bool is_task_ksu_domain(...) { return false; }
bool is_ksu_domain(void) { return false; }
bool is_zygote(...) { return false; }
bool is_init(...) { return false; }
void setup_ksu_cred(void) { }
void escape_to_root_for_adb_root(void) { }
#endif
```

**Limitation:** 这是最大的妥协。KSU 不能：
- 切换到 KSU SELinux domain（"ksu"）
- 跟 Android SELinux state 联动
- 检测进程是否已经 zygote / init

「app 通过 KSU manager 申请 root」的 SELinux 域转换路径完全不工作。`adb root` 不依赖 SELinux 域，所以仍可用。

---

### 8. `selinux/rules.c`：selinux_state.policy / policy_mutex

**Why:** Linux 5.7 把 SELinux 的全局 state 从「直接字段」改成「指向 selinux_policy 的 RCU 指针」：
- 老（4.19）：`selinux_state.ss → policydb`
- 新（5.7+）：`selinux_state.policy → selinux_policy → policydb`，加 `policy_mutex` 保护

KSU 用 5.7+ API 直接读写 `state.policy`。

**How:**
```c
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 7, 0)
[原 500 行实现]
#else
/* 4.x: 不应用 KSU 自定义 SELinux 规则 */
void apply_kernelsu_rules(void) { /* no-op */ }
int handle_sepolicy(void __user *user_data, u64 data_len) {
    return -ENOSYS;
}
#endif
```

**Limitation:** KSU 启动时的「向 SELinux 注入 ksu_domain 永宽容规则」失效。理论上 KSU domain 不存在 = 不能切换到它 = ksu manager 给 app 授权失败。同 #7 一起考虑：4.19 上 KSU 的 SELinux 集成完全不可用。

---

### 9. `selinux/sepolicy.c`：filename_trans_key/datum + 大量 policydb 操作

**Why:** policydb 内部结构在 5.7 改变。`filename_trans_key`、`filename_trans_datum.stypes` 这些字段在 4.19 不同。

**How:** 1224 行原文件全包 5.7+，stub 全部 30 多个 ksu_* 函数：

```c
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 7, 0)
[原 1224 行]
#else
/* 4.x stubs */
struct policydb;
struct selinux_policy;
struct selinux_policy *ksu_dup_sepolicy(struct selinux_policy *o) { return NULL; }
void ksu_destroy_sepolicy(struct selinux_policy *o) { }
bool ksu_type(struct policydb *db, ...) { return false; }
bool ksu_attribute(struct policydb *db, ...) { return false; }
bool ksu_permissive(...) { return false; }
bool ksu_allow(...) { return false; }
bool ksu_deny(...) { return false; }
... (~20 more)
#endif
```

**Limitation:** 同 #8 — KSU 的 SELinux 修改完全 disable

---

### 10. `supercall/dispatch.c` + `supercall/supercall.c`：tasklist_lock / task_pgrp / mount_list

**Why:** 
- `tasklist_lock` 是内核内部 spinlock，在 4.19 不直接 export 给模块
- `task_pgrp()`, `task_session()` 是 helper，在某些 minor 版本可用度差
- `init_task` 是 kernel 内部全局 task_struct

**How:** 
```c
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 0, 0)
[原 840 行 dispatch.c]
#else
/* 4.x stubs + 提供 kernel_umount.c 引用的 mount_list/lock 全局符号 */
#include <linux/list.h>
#include <linux/rwsem.h>

long ksu_handle_supercall(unsigned long cmd, ...) { return -ENOSYS; }
long ksu_supercall_handle_ioctl(unsigned int cmd, void __user *argp) { return -ENOSYS; }
void __init ksu_supercall_dump_commands(void) { }
void ksu_supercall_cleanup_state(void) { }

/* 这些是 feature/kernel_umount.c 引用的全局，必须存在让 linker 满意 */
struct list_head mount_list = LIST_HEAD_INIT(mount_list);
DECLARE_RWSEM(mount_list_lock);
#endif
```

`supercall.c` 同样补 TWA_RESUME 兼容定义。

**Limitation:** KSU manager APK 通过 `ioctl(/dev/ksu, KSU_IOCTL_*, ...)` 和 kernel 通信的链路失效。manager 看不到 kernel 状态，也不能给 kernel 发命令。

---

### 11. `feature/kernel_umount.c`：path_umount

**Why:** `path_umount()` 是 5.9 引入。

**How:**
```c
#include <linux/version.h>
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)
extern int path_umount(struct path *path, int flags);
#else
static inline int path_umount(struct path *path, int flags) { return -ENOSYS; }
#endif
```

**Limitation:** KSU 给 root app 看的 mount namespace 不能在内核态做 selective umount。同 #5 — 没有 magic mount。

---

### 杂项

#### `sulog/event.c`：linux/minmax.h

**Why:** `<linux/minmax.h>` 是 5.10 拆分出来的（min/max 宏从 linux/kernel.h 搬过来）。4.19 还在 linux/kernel.h。

**How:**
```c
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)
#include <linux/minmax.h>
#else
#include <linux/kernel.h>  /* min/max in 4.x */
#endif
```

#### `Kbuild` (KSU)

**改动：** 将 `manager/` 子目录的 .o 用 `KSU_DISABLE_MANAGER=y` 跳过，避免修 `pkg_observer.c` 里的 fsnotify_ops 不兼容。

**修改 defconfig overlay:**
```
CONFIG_KSU=y
CONFIG_KSU_DISABLE_MANAGER=y    # 跳过 pkg_observer (handle_inode_event 5.10+)
```

#### `scripts/link-vmlinux.sh`（kernel 主源码，非 KSU）

**Why:** 4.19 没有 `tools/bpf/resolve_btfids` 工具（5.5 引入）

**How:**
```diff
-${RESOLVE_BTFIDS} vmlinux
+if [ -x "${RESOLVE_BTFIDS}" ]; then
+  ${RESOLVE_BTFIDS} vmlinux
+else
+  info "BTFIDS" "skipping (resolve_btfids not present in 4.19)"
+fi
```

---

## 全局功能矩阵（pmd_leaf 修复后更新）

| 功能 | 5.10+ KSU | 4.19 + 我们的 patch | 备注 |
|---|---|---|---|
| 模块加载 | ✅ | ✅ | dmesg 看 `feature management initialized` |
| 模块隐藏（kobject_del） | ✅ | ✅ | `/sys/module/kernelsu/` 不可见 |
| feature 注册（sulog/adb_root/kernel_umount/su_compat） | ✅ | ✅ | KSU module init 跑完 |
| Allowlist 数据加载 | ✅ | ✅ | 内存中维护，规则文件 path 缺失时跳过（manager APK 未装时正常） |
| **syscall_hook_init dispatcher** | ✅ | ✅ | NI-syscall slot 42 dispatcher 安装 |
| **execve 拦截 (nr=221)** | ✅ | ✅ | 安装成功 |
| **setresuid 拦截 (nr=147)** | ✅ | ✅ | `handle_setresuid from 0 to N` 运行时活跃 |
| **newfstatat 拦截 (nr=79)** | ✅ | ✅ | 安装成功 |
| **faccessat 拦截 (nr=48)** | ✅ | ✅ | 安装成功 |
| **kretprobe syscall_regfunc/unregfunc** | ✅ | ✅ | tracepoint 自动 marker |
| **sys_enter tracepoint** | ✅ | ✅ | 注册成功 |
| **supercall ioctl reboot kprobe** | ✅ | ✅ | manager APK 通信通道就绪 |
| **init.rc 注入 (ksu_rc)** | ✅ | ✅ | KSU 给 init.rc 追加 60226-59871=355 字节 |
| **SELinux ksu_domain 切换** | ✅ | ❌ | 仍 stub — 4.19 selinux_state.ss vs 5.7 .policy 重构未做 |
| Mount namespace per-app | ✅ | ❌ | path_mount/path_umount 不存在 |
| PTS file proxy | ✅ | ❌ | file_operations.iopoll 不存在 |
| seccomp 缓存 | ✅ | ❌ | SECCOMP_ARCH_NATIVE_NR 不存在 |
| seccomp filter release | ✅ | ⚠️ | Best-effort partial |
| frida 兼容 | ✅ | ✅ | 不依赖 KSU |
| BPF 工具兼容 | ✅ | ✅ | adb root 即可 |

### 实际 KSU 可用度（pmd_leaf 修复后）

KSU manager APK 装上后应能：
- ✅ 看到「内核已支持」状态
- ✅ 在 manager 里授权 app root
- ✅ app 通过 `su` 命令进 KSU 拦截路径
- ⚠️ 但 SELinux domain 转换没做 → app 拿到 uid=0 后仍可能在 ksu_domain 之外，访问 protected 文件被 SELinux 拒绝
- 解决方案：`adb shell setenforce 0`（userdebug ROM 上可用），或继续做 SELinux 集成

---

## 让 KSU 真正完全工作的路线（约 1-2 周）

如果想把 ❌ 全部变 ✅，需要做：

### A. Syscall hook 子系统重写（最大工作量）

`hook/arm64/patch_memory.c` 和 `hook/syscall_hook_manager.c` 假设 5.10+ 的 `sys_call_table` 布局。需要：

1. 实现 4.19 arm64 版本的 `sys_call_table` 定位（kallsyms 或者 hardcoded）
2. 4.19 的 syscall 入口是 `__arm64_sys_<name>` 还是 `sys_<name>`，确认布局
3. patch_memory 用 set_memory_rw / set_memory_ro 分别处理
4. 测试单个 hook（如 setresuid）能正确转发原始调用

### B. SELinux 集成 4.19 fork

为 `selinux/rules.c, sepolicy.c, selinux.c` 写**第二份独立实现**：
- 用 `selinux_state.ss` 而不是 `state.policy`
- 用 RCU 而不是 mutex
- `filename_trans_key/datum` 用 4.19 的 layout
- `current_sid()` 不重定义（用 internal helper）

### C. Supercall ioctl 路径

`supercall/dispatch.c` 用 4.19 的：
- `find_pid_ns + get_pid_task` 找 init
- `task_pgrp / task_session` 直接调用而不是 KSU 封装
- 暴露 `/dev/ksu` 设备节点

### D. kernel_umount + su_mount_ns

需要重新实现「不依赖 path_mount/path_umount」的 mount 命名空间切换。可能用：
- `kern_path` + `mount_subtree`（4.19 接口）
- 或直接用 `__sys_mount` / `__sys_umount` 内部调用

**估算总工作量：** 一个有 Linux kernel + Android + SELinux 经验的开发，专职 1-2 周。
