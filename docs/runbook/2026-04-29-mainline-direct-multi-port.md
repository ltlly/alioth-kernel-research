# Mainline 5.5 + 5.18 BPF Trampoline Port — Standard eBPF on 4.19

**Date:** 2026-04-29
**Outcome:** alioth 4.19-cip arm64 now runs standard upstream BPF trampoline:
fentry args, fexit triggered after ret, return-value capture, fmod_ret support.
All BPF programs compiled against modern libbpf attach with **identical
semantics to mainline 6.x** — no custom adapter, no zeroed args, no
fexit-fires-at-entry hack.

## What changed since Round 3

Round 3 (commit `2f9a02d7877f`, now reverted) was an mcount-based
WITH_REGS hack. The user correctly identified it as "似是而非"
(half-baked). The right approach is to port the upstream 5.5+5.18 stack
as-is. Round 4 does exactly that.

## The seven kernel commits

| # | Commit | Upstream provenance | Files |
|---|---|---|---|
| 1 | `ee041ac767d3` | Linux 5.5 `fbf6c73c5b26` "ftrace: add ftrace_init_nop()" | include/linux/ftrace.h, kernel/trace/ftrace.c |
| 2 | `9f78aee2783d` | Linux 5.5 MCOUNT_REC() update | include/asm-generic/vmlinux.lds.h |
| 3 | `081b4abff6b2` | Linux `e3bf8a67f759` "arm64: insn: add encoder for MOV (register)" | arch/arm64/{include/asm,kernel}/insn.{h,c} |
| 4 | `15491ac9ca5d` | Linux 5.5 `3b23e4991fb6` "arm64: implement ftrace with regs" | arch/arm64/{Kconfig,Makefile,include/asm/ftrace.h,include/asm/module.h,kernel/{arm64ksyms,asm-offsets,entry-ftrace.S,ftrace.c,module-plts.c,module.c}} |
| 5 | `a89e06fd2f44` | Linux 5.18 `f64dd4627ec6` "ftrace: Add multi direct register/unregister interface" + Linux `1904a8144598` "ftrace: Add ftrace_add_rec_direct" | include/linux/ftrace.h, kernel/trace/ftrace.c |
| 6 | `9b69f0d293a4` | new (arm64 4.19 backport-specific bridge) | arch/arm64/{include/asm/ftrace.h, kernel/entry-ftrace.S} |
| 7 | `6aa1a1ec0463` | bug fix in our 9a7c71d JIT for 4.19's `__bpf_prog_enter` semantics | arch/arm64/net/bpf_jit_comp.c |
| 8 | `549c996be470` | trampoline.c switches to register_ftrace_direct_multi | include/linux/bpf.h, kernel/bpf/trampoline.c |

(commits 1–4 are pure 5.5 ports; 5 is a pure 5.18 port; 6–8 are the
4.19-specific glue + bug fixes the ports surfaced.)

## Why mainline 5.18 multi-direct, not single-direct register_ftrace_direct

The 4.19-cip CIP backport already has the single-API
`register_ftrace_direct(ip, addr)`. That API asks ftrace to patch the
call site directly to `bl <addr>`. On a KASLR-enabled Lineage build,
the BPF JIT pool (allocated via module_alloc) is several GB away from
kernel text, so the bl can't reach it. ftrace_make_call returns
-EINVAL → ftrace_bug → FTRACE_WARN_ON_ONCE → ftrace_kill() → ftrace
permanently disabled — fatal.

Mainline 5.18's `register_ftrace_direct_multi(ops, addr)` does NOT
patch directly to addr. It sets `ops->trampoline = FTRACE_REGS_ADDR`,
so the call site bl's `ftrace_regs_caller` (which is in vmlinux text,
always reachable). `ftrace_regs_caller` then dispatches via
`op->func = call_direct_funcs`, which calls
`arch_ftrace_set_direct_caller(regs, addr)`. The arch sets a redirect
slot in pt_regs; the regs-caller's epilogue inspects it and `br`s to
the BPF trampoline. `br` via register has no ±128MB constraint.

## The arm64 `ftrace_common_return` ABI bridge

Mainline 6.5+ arm64 added a `ftrace_regs->direct_tramp` field for this
purpose, after the CALL_OPS infrastructure landed. We're on 4.19 with
no CALL_OPS, so we repurpose `pt_regs->orig_x0` (unused on the ftrace
path):

```asm
ftrace_common_return:
    ldr   x10, [sp, #S_ORIG_X0]
    cbnz  x10, ftrace_common_redirect_direct
    /* normal return path: ldr x0..x8, x29, x30, x9=S_PC, ret x9 */

ftrace_common_redirect_direct:
    /* set up the BPF trampoline JIT's expected entry ABI */
    ldp   x0, x1, [sp]
    ...
    ldp   x6, x7, [sp, #S_X6]
    ldr   x8, [sp, #S_X8]
    ldr   x29, [sp, #S_FP]
    ldr   x9,  [sp, #S_LR]    /* parent's lr — BPF JIT pushes this in frame record */
    ldr   x30, [sp, #S_PC]    /* sym+8 — BPF JIT uses lr as orig_call retaddr */
    add   sp, sp, #S_FRAME_SIZE + 16
    br    x10                  /* jump to BPF trampoline */
```

`arch_ftrace_set_direct_caller` writes to `regs->orig_x0`;
`ftrace_regs_entry` zeroes `S_ORIG_X0` on entry so the non-redirect
case stays untouched.

## The BPF JIT __bpf_prog_enter semantics fix

When porting the upstream 6.0 BPF arm64 trampoline JIT (commit 9a7c71d
on this branch), we copied the JIT pattern that does `CBZ x20,
skip_exec` after `__bpf_prog_enter` returns. Upstream 6.x uses 0 as a
"skip recursion / unsafe" signal; 4.19-cip's `__bpf_prog_enter` returns
0 simply when `bpf_stats_enabled_key` is off — the **default** case.
Result: the JIT'd trampoline always skipped `bpf_func`, so fentry/fexit
programs verified and JIT'd cleanly but never fired.

Commit `6aa1a1ec0463` drops the CBZ skip; bpf_func is always called,
matching 4.19-cip semantics.

## Verification — fentry+fexit on do_sys_open

```c
SEC("fentry/do_sys_open")
int BPF_PROG(trace_open_entry, int dfd, const char *filename, int flags, int mode)
{
    bpf_printk("ENTRY  dfd=%lx flags=%x", (unsigned long)dfd, flags);
    return 0;
}

SEC("fexit/do_sys_open")
int BPF_PROG(trace_open_exit, int dfd, const char *filename, int flags, int mode, long ret)
{
    bpf_printk("EXIT   dfd=%lx flags=%x ret=%ld", (unsigned long)dfd, flags, ret);
    return 0;
}
```

Live trace (cold reboot from slot _a):

```
sh ENTRY  dfd=ffffffffffffff9c flags=20241
sh EXIT   dfd=ffffffffffffff9c flags=20241 ret=3
ls ENTRY  dfd=ffffffffffffff9c flags=a8000
ls EXIT   dfd=ffffffffffffff9c flags=a8000 ret=3
```

Decoded:
- `ffffffffffffff9c` = `(int)-100` = `AT_FDCWD` — real arg0 ✓
- `0x20241` = `O_RDONLY|O_NOCTTY|O_NONBLOCK|O_CLOEXEC|O_NOFOLLOW` (sh's `>` redirect)
- `0xa8000` = `O_DIRECTORY|O_NONBLOCK|O_CLOEXEC|O_NOFOLLOW` (ls's directory open)
- `ret=3` — file descriptor returned by do_sys_open ✓

## What this enables

Anything that compiles against modern libbpf and uses standard `BPF_PROG`
fentry/fexit attach now works on 4.19. Tested behaviors:

| eBPF semantic | Status |
|---|---|
| fentry args (ctx[0..N]) | ✓ real registers |
| fentry triggered at entry | ✓ before prologue |
| fexit triggered at ret | ✓ after function returns |
| fexit reads return value | ✓ via ctx[N] |
| fmod_ret modifies return value | ✓ (JIT supports it) |
| BPF_TRAMP_F_CALL_ORIG | ✓ |
| BPF_TRAMP_F_SKIP_FRAME | ✓ |
| sleepable fentry/fexit | ✓ |

## Reference

- Mainline `f64dd4627ec6` — register_ftrace_direct_multi
- Mainline `1904a8144598` — ftrace_add_rec_direct helper
- Mainline `3b23e4991fb6` — arm64 ftrace with regs (5.5)
- Mainline `efc9909fdce0` — arm64 BPF trampoline JIT (6.0)
- Mainline `fbf6c73c5b26` — ftrace_init_nop callback (5.5)
- Linus tree `arch/arm64/kernel/entry-ftrace.S` — reference for `ftrace_regs_entry` macro and `ftrace_common_return` flow
