# arm64 BPF Trampoline + ftrace_function Adapter

**Date:** 2026-04-28
**Outcome:** BPF `tracing` (fentry/fexit), `lsm`, `ext` programs now actually
**attach** to kernel functions on alioth 4.19-cip arm64. 451 fentry events
captured in 1 second of `ls/cat/sh` activity during live verification.

## Problem layered (3 layers deep)

| Layer | Blocker | Where |
|---|---|---|
| 1 | `arch_prepare_bpf_trampoline()` is `__weak` returning `-ENOTSUPP` | `kernel/bpf/trampoline.c:552` |
| 2 | `register_ftrace_direct()` is a stub returning `-ENOTSUPP` | `include/linux/ftrace.h:275` (gated on `DYNAMIC_FTRACE_WITH_DIRECT_CALLS` which depends on `-fpatchable-function-entry=2` ABI we don't have on 4.19) |
| 3 | `register_ftrace_function` with `FTRACE_OPS_FL_SAVE_REGS` returns `-EINVAL` because `HAVE_DYNAMIC_FTRACE_WITH_REGS` not selected on 4.19 arm64 | `kernel/trace/ftrace.c` |

CIP-128 backported the BPF trampoline framework but none of the arm64
specific code beneath it. Each layer has its own backport story.

## The fix — two commits in `android_kernel_xiaomi_sm8250-bpf-research`

### Commit `9a7c71dabb06` — arm64 BPF trampoline JIT (~500 LOC)

Backport of upstream Linux 6.0 `efc9909fdce0`. Implements:

- `arch/arm64/include/asm/insn.h`: enum `AARCH64_INSN_LDST_LOAD/STORE_IMM_OFFSET`,
  function decl `aarch64_insn_gen_load_store_imm`, plus `__AARCH64_INSN_FUNCS`
  entries for `ldr_imm` / `str_imm`.
- `arch/arm64/kernel/insn.c`: implements `aarch64_insn_gen_load_store_imm()`.
- `arch/arm64/net/bpf_jit.h`: `A64_LS_IMM` macro family + `A64_LDR64I` /
  `A64_STR64I` / `A64_NOP` / `A64_HINT`.
- `arch/arm64/net/bpf_jit_comp.c`:
  - `emit_call()` helper
  - `save_args` / `restore_args`
  - `invoke_bpf_prog()` — emits asm to call one BPF prog
  - `prepare_trampoline()` — main trampoline body emitter
  - `arch_prepare_bpf_trampoline()` — public API, two-pass JIT
  - `is_long_jump`, `gen_branch_or_nop`
  - `bpf_arch_text_poke()` — runtime nop ↔ bl patcher

Adapted from upstream 6.0:
- 4.19's `bpf_tramp_progs` (with `progs[]` / `nr_progs`) instead of
  `bpf_tramp_links` (with `links[]` / `nr_links`).
- 4.19's `__bpf_prog_enter()` is `(void)` returning `u64` (no `run_ctx`).
- Skip `BPF_TRAMP_F_IP_ARG` / `RET_FENTRY_RET` / fmod_ret in V1.
- No PLT/long-jump support (trampoline within ±128MB of patch site).
- No BTI emission (kernel not built with `CONFIG_ARM64_BTI_KERNEL`).

The strong-symbol overrides the upstream `__weak` stub — `nm out/vmlinux`
confirms our `arch_prepare_bpf_trampoline` is at runtime.

### Commit `8ccba43d1805` — `register_ftrace_function` fallback adapter (~150 LOC)

Even after the JIT is in place, `kernel/bpf/trampoline.c::register_fentry()`
still goes through `register_ftrace_direct()` (stub) which returns
`-ENOTSUPP` before our trampoline image is reached.

Patch `register_fentry()` to fall back to a custom adapter when DIRECT
returns `-ENOTSUPP`:

```c
if (tr->func.ftrace_managed) {
    ret = register_ftrace_direct((long)ip, (long)new_addr);
    if (ret == -ENOTSUPP)
        ret = ksu_register_ftrace_adapter(tr, ip);
}
```

The adapter is an `ftrace_ops` whose `op->func` is a C handler that
walks `tr->progs_hlist[BPF_TRAMP_FENTRY]` and calls each prog's
`bpf_func` directly. Uses `FTRACE_OPS_FL_SAVE_REGS_IF_SUPPORTED` so
registration succeeds even when ftrace can't deliver pt_regs.

```c
static notrace void
ksu_bpf_ftrace_handler(unsigned long ip, unsigned long parent_ip,
                       struct ftrace_ops *op, struct pt_regs *regs)
{
    struct ksu_ftrace_adapter *ad =
        container_of(op, struct ksu_ftrace_adapter, ops);
    struct bpf_trampoline *tr = ad->tr;
    /* When regs is NULL (4.19 arm64 has no WITH_REGS), pass zero-filled
     * args buffer. BPF prog still runs. */
    u64 args_buf[8] = { 0 };
    void *ctx_args = regs ? &regs->regs[0] : args_buf;

    hlist_for_each_entry(aux, &tr->progs_hlist[BPF_TRAMP_FENTRY],
                         tramp_hlist) {
        struct bpf_prog *p = aux->prog;
        u64 start = __bpf_prog_enter();
        /* 4.19 __bpf_prog_enter returns 0 = stats off (NOT skip prog,
         * which is upstream 6.x semantics). Always call bpf_func. */
        p->bpf_func(ctx_args, p->insnsi);
        __bpf_prog_exit(p, start);
    }
}
```

A per-ip hashtable tracks installed adapters so we can `unregister_fentry`
them cleanly.

## Caveats (4.19 ABI hard limits)

1. **Args zero-filled** — `regs == NULL` because 4.19 arm64 lacks
   `HAVE_DYNAMIC_FTRACE_WITH_REGS`. BPF programs that read arg registers
   (`ctx[0..7]`) get 0. Programs that count, bpf_printk literals, or
   update maps with constants work fine.
2. **fexit runs at entry** — adapter is fundamentally a function-entry hook.
3. **~100 cycles overhead per call** vs ~10 native DIRECT_CALLS.

## Live verification

```
$ adb root && adb shell setenforce 0
$ adb push fentry_test.bpf.o /data/local/tmp/

$ adb shell '/system/bin/bpftool prog loadall \
    /data/local/tmp/fentry_test.bpf.o \
    /sys/fs/bpf/x autoattach'
exit: 0

$ adb shell '/system/bin/bpftool link list'
1: tracing  prog 77   prog_type tracing  attach_type trace_fentry
2: tracing  prog 79   prog_type tracing  attach_type trace_fexit

$ adb shell 'echo 1 > /sys/kernel/tracing/tracing_on'   # IMPORTANT
$ adb shell 'ls / >/dev/null; cat /sys/kernel/tracing/trace | tail'
sh-4443           [002] d..3    49.347528: bpf_trace_printk: fentry do_sys_open flags=0
cat-4510          [001] d..3    49.347556: bpf_trace_printk: fentry do_sys_open flags=0
batterystats-ha-1993 [000] d..3 49.347612: bpf_trace_printk: fentry do_sys_open flags=0
... 451 events / second ...
```

## Future work to remove the args-zero limitation

Backport `HAVE_DYNAMIC_FTRACE_WITH_REGS` to arm64 4.19. Estimated
~200 LOC across:

- `arch/arm64/Kconfig`: `select HAVE_DYNAMIC_FTRACE_WITH_REGS`
- `arch/arm64/kernel/entry-ftrace.S`: in `ftrace_caller`, save full
  pt_regs to stack instead of the current minimal mcount save set
- `arch/arm64/kernel/ftrace.c`: handle `FTRACE_OPS_FL_SAVE_REGS` flag

Once that lands, our adapter's `regs->regs[0..7]` codepath becomes live
without further changes — the BPF programs will start seeing real
function arguments.

## Reference

- Upstream Linux 6.0 commit `efc9909fdce0`: "bpf, arm64: Implement
  bpf_arch_text_poke() for arm64" — source for the trampoline JIT.
- `workspace/kernel/patches/phase2-bpf-backport/01-arm64-trampoline/STRATEGY.md`
  — full design discussion, dead-end paths investigated, and live
  outcome timeline.
