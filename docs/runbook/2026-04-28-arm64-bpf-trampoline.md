# arm64 BPF trampoline JIT — backport of upstream 6.0

**Date:** 2026-04-28 (initial JIT) → 2026-04-29 (integrated with mainline 5.18 direct_multi)
**Outcome:** `arch_prepare_bpf_trampoline()` and `bpf_arch_text_poke()` now have working
arm64 implementations on alioth 4.19-cip — the JIT layer underneath BPF
fentry/fexit/fmod_ret. Combined with the 5.5 patchable-fentry port and 5.18
register_ftrace_direct_multi port, this delivers fully standard upstream
eBPF behavior on alioth.

## What this commit provides

Backport of upstream Linux 6.0 commit `efc9909fdce0` ("bpf, arm64: Implement
bpf_arch_text_poke() for arm64") and its companion 6.0 BPF trampoline JIT,
landed on this branch as commit `9a7c71dabb06`:

- `arch/arm64/include/asm/insn.h` — enum
  `AARCH64_INSN_LDST_LOAD/STORE_IMM_OFFSET`, declaration of
  `aarch64_insn_gen_load_store_imm()`, plus `__AARCH64_INSN_FUNCS` entries
  for `ldr_imm` / `str_imm`.
- `arch/arm64/kernel/insn.c` — `aarch64_insn_gen_load_store_imm()` impl.
- `arch/arm64/net/bpf_jit.h` — `A64_LS_IMM` macro family + `A64_LDR64I` /
  `A64_STR64I` / `A64_NOP` / `A64_HINT`.
- `arch/arm64/net/bpf_jit_comp.c`:
  - `emit_call()` helper
  - `save_args()` / `restore_args()`
  - `invoke_bpf_prog()` — emits asm to call one BPF prog with
    `__bpf_prog_enter` / `__bpf_prog_exit` wrapping
  - `prepare_trampoline()` — main trampoline body emitter (handles
    fentry, optional `bl orig_call`, optional fexit, frame management)
  - `arch_prepare_bpf_trampoline()` — public API, two-pass JIT (size
    pass + emit pass)
  - `is_long_jump`, `gen_branch_or_nop`
  - `bpf_arch_text_poke()` — runtime nop ↔ bl patcher used by the BPF
    trampoline core (kernel/bpf/trampoline.c) to install/remove the
    trampoline at a function's patch site.

Adapted from upstream 6.0 with these 4.19-tree differences:

- Uses 4.19's `bpf_tramp_progs` (with `progs[]` / `nr_progs`) instead of
  upstream's `bpf_tramp_links` (with `links[]` / `nr_links`).
- Uses 4.19's `__bpf_prog_enter()` (no args, returns `u64`) instead of
  upstream's `__bpf_prog_enter(prog, run_ctx)`.
- Skips `BPF_TRAMP_F_IP_ARG` / `RET_FENTRY_RET` / fmod_ret machinery
  in V1.
- No PLT/long-jump support: the JIT'd trampoline must be within ±128MB of
  every patch site that calls it. With the mainline 5.18
  `register_ftrace_direct_multi` route added in commit `a89e06fd2f44`,
  this constraint is no longer binding — the patch site goes to
  `ftrace_regs_caller` (always reachable) and the regs-caller's epilogue
  performs an unconstrained `br x10` to reach the trampoline.
- No BTI emission (alioth kernel is built without `CONFIG_ARM64_BTI_KERNEL`).

The strong-symbol implementation overrides the upstream `__weak` stub —
`nm out/vmlinux` confirms our `arch_prepare_bpf_trampoline` is at runtime.

## Important: the C-side adapter has been removed

The original Round 2 work (commit `8ccba43d1805`) shipped with a C
fallback adapter — `ksu_register_ftrace_adapter` — registering an
ftrace_ops with `FTRACE_OPS_FL_SAVE_REGS_IF_SUPPORTED` whose `->func`
invoked the BPF programs from C. That fallback was needed because
`register_ftrace_direct` returned `-ENOTSUPP` (the 4.19 single-direct
path lacked arm64 support) and the BPF JIT trampoline path required
WITH_REGS-like context that 4.19 mcount-based ftrace couldn't deliver.

After Round 4 landed the proper mainline 5.5 + 5.18 backports
(`-fpatchable-function-entry=2` + `register_ftrace_direct_multi`), the
adapter is dead code and was deleted in commit `549c996be470`. The
ftrace_ops dispatch route for fentry/fexit on arm64 4.19 is now exactly
the upstream one: ftrace patch site → `ftrace_regs_caller` →
`call_direct_funcs` → `arch_ftrace_set_direct_caller` (writes
`regs->orig_x0`) → `ftrace_common_return` redirect → BPF trampoline JIT
(this file).

The JIT itself is unchanged from the original Round 2 implementation
except for one bug fix in commit `6aa1a1ec0463`: the upstream-mirrored
`CBZ x20, skip_exec` after `__bpf_prog_enter` was removed because 4.19's
`__bpf_prog_enter` returns 0 to mean "stats off" (the normal case), not
"skip recursion" as it does in upstream 6.x.

## Live verification

```
$ adb root && adb shell setenforce 0
$ adb push fexit_test.bpf.o /data/local/tmp/

$ adb shell '/system/bin/bpftool prog loadall \
    /data/local/tmp/fexit_test.bpf.o /sys/fs/bpf/y autoattach'
$ adb shell '/system/bin/bpftool link list'
1: tracing  prog 77   prog_type tracing  attach_type trace_fentry
2: tracing  prog 79   prog_type tracing  attach_type trace_fexit

$ adb shell 'echo 1 > /sys/kernel/tracing/tracing_on'
$ adb shell 'ls / >/dev/null; echo z > /data/local/tmp/test'
$ adb shell 'cat /sys/kernel/tracing/trace | tail'
sh ENTRY  dfd=ffffffffffffff9c flags=20241          # AT_FDCWD = -100, real flags
sh EXIT   dfd=ffffffffffffff9c flags=20241 ret=3    # real return value (fd 3)
ls ENTRY  dfd=ffffffffffffff9c flags=a8000
ls EXIT   dfd=ffffffffffffff9c flags=a8000 ret=3
```

ctx[0] is the real first arg (AT_FDCWD), fexit fires after ret with the
real return value — fully standard upstream eBPF behavior.

## See also

- `docs/runbook/2026-04-29-mainline-direct-multi-port.md` — full Round 4
  port (5.5 patchable-fentry + 5.18 direct_multi + arm64 ABI bridge in
  `ftrace_common_return`); covers everything end-to-end from why
  `register_ftrace_direct` was unusable on this branch up to the
  `regs->orig_x0` redirect mechanism.
- `docs/runbook/2026-04-28-btf-firmware-loader.md` — BTF firmware loader
  patch (Round 1) that unlocked the verifier-level acceptance of
  `tracing` / `lsm` / `ext` prog types.
- Upstream Linux 6.0 commit `efc9909fdce0` — original source of the JIT.
- `workspace/kernel/patches/phase2-bpf-backport/01-arm64-trampoline/STRATEGY.md`
  — Round 2 strategy and stop-by-stop debugging history.
