# Worklog chunk 110 — 2026-10-03 — wide campaign over the Astra queue (4 concurrent workers)

## Session log — 2026-10-03 — batch 2 landed: Bennett-iys2 (61e18a6), Bennett-3vji (d27a383), Bennett-4ddk (4f29c91), Bennett-retr (75f8969)

**Bennett-iys2 — soft_pow(-1, y) returned +1 for every y** (61e18a6). The last step of `soft_pow`
forced 1.0 when |x| == 1, but C99/POSIX make pow(x, y) = 1 unconditional only for x = +1.
Fix (src/softfloat/fpow.jl only): test `x == +1`; new overrides before NaN propagation give
pow(-1, odd) = -1, pow(-1, even or +-Inf) = +1 (set directly, not via the log/exp path, for
|y| >= 2^63); non-integer y and NaN y already fell into the NaN overrides. Two tests had pinned
the wrong values (test_softfpow.jl:85-89, test_emv_llvm_pow_dispatch.jl:56) and were fixed. New
test_iys2_pow_negative_one.jl (36 exponents bit-exact vs Base, ULP sweep, llvm.pow circuit
through verify_reversibility): red 32 failures before the fix; targeted run 1147/1147. No
pinned gate-count baseline covers soft_pow; the circuit gains a few gates from the overrides.

**Bennett-3vji — Eager dead-end cleanup replayed against changed controls** (d27a383).
`_eager_bennett_impl` (src/pebble/eager.jl) replayed a dead-end wire's modification path right
after its last write; a replayed gate only undoes itself if its controls still hold their
forward-pass values. Witnesses: Astra F9 fixture `CNOT(1,3), NOT(1), CNOT(1,3)` and
`(x+3)*(x+1)` with `add=:qcla, fold_constants=false` (wire 26, x=-128). Fix: new helper
`_controls_stable` (searchsortedfirst on each control's sorted mod path); early cleanup fires
only if no control of a path gate is targeted afterwards, else the wire is left to the Phase 3
reverse (still sound, the wire is never a control). Old "always correct" comment corrected.
New test_3vji_eager_control_stability.jl (265 pass; red: 3 + 129 errors, 18/300 random
sequences bad); targeted run 6831/6831. Gate baselines unchanged. Trade-off: eager may now use
Phase-3-ordered cleanup on some qcla wires, so its peak liveness can be slightly worse there.

**Bennett-4ddk — compile/extraction caches unsound** (4f29c91). `_parsed_ir_cache` and
`_compile_cache` keys do not change when a method or inlined callee is redefined (stale circuit
reproduced); the helper was typed `f::Function` (callables, F15); `_narrow_ir` built a fresh
ParsedIR each call so narrowed compiles never hit and were kept forever (F21); objectid keys can
match a recycled id. Fix (src/extract/callees.jl, src/Bennett.jl, a comment in julia_set.jl):
`_cache_world_gate!` empties a cache when the world counter changed; `_cache_insert_bounded!`
skips inserts if the world moved mid-compute and evicts above caps (256 parsed-IR, 32 compile);
untyped `f` plus a `bit_width` kwarg (5-tuple key) so narrowing is memoised; compile cache keys
on `parsed` itself. New test_4ddk_compile_cache_soundness.jl (2626 assertions over the cache
files); ej4n haskey assertions updated; targeted run 374036 pass / 1 broken / 0 fail. Gate
counts unchanged.

**Bennett-retr — add=:qcla with aliased operands (x+x)** (75f8969). `lower_add_qcla!`
(src/qcla.jl) uses `b` as its in-place propagate register; the `:qcla` branch of `lower_binop!`
(src/lowering/arith.jl) passed `a === b` through, and the Bennett-stwr alias guard covered only
Cuccaro. Fix: the branch CNOT-copies `b` to fresh wires (`_emit_copy_out!`) when
`!isdisjoint(a, b)`; `lower_add_qcla!` now throws a bead-named ArgumentError on overlapping or
repeated-wire operands (same as `lower_add_cuccaro!`). New test_retr_qcla_alias.jl: 5366 pass;
7-file filtered run 9589/9589. Ripple, cuccaro, shift_add, qcla_tree on x+x / x*x / z-z were
already correct and are pinned in the test. Gate counts unchanged.

**Gotchas.**
- retr: the bead's filed symptom (dirty ancillae, 254/256 inputs) had changed by the time it
  was fixed: Bennett-lcye landed in between, so x+x now throws `CNOTGate: control == target` at
  compile time. A filed witness can go stale without the bug being fixed; with lcye in, every
  "self-CNOT" bead fails at compile time, so re-run such witnesses before trusting the symptom.
  `optimize=true` hides it (LLVM rewrites x+x as shl).
- retr: `sext` lowering allocates fresh wires, so the `allunique` precondition is safe for
  valid IR.
- 4ddk: in Julia 1.12 the world counter moves on any method definition, on the first top-level
  assignment of a new global, and on reaching a top-level closure literal (+3 per closure,
  also inside a `@testset` body). Any of these empties both caches (sound, conservative; flush
  about 80 ms on a two-callee Float64 compile, 0.23 s -> 0.31 s). A `===` assertion must come
  before any closure literal in the same testset; a compile after an `@eval` redefinition must
  go through `Base.invokelatest`.
- 4ddk: `register_callee!` does not move the world; manual `_clear_*_cache!()` still needed.
- iys2: Base.:^ throws DomainError for a negative base with non-integer exponent (tests need a
  try/NaN reference); `Int64(reinterpret(UInt64, x))` throws InexactError, use
  `reinterpret(Int64, x)` for ULP distance.
- 3vji: `simulate` on a dirty circuit throws instead of returning, so random-sweep tests wrap
  each trial in try/catch and count failures rather than one `@test` per trial.
- 4ddk/iys2: a typed `f(x::Float64)` fails with the opaque VoidType message (SoftFloat wrapper
  calls `f(::SoftFloat)`); (-1.5)^-3 is 1 ULP off Base (soft_pow is <=2 ULP, not rule-13 exact).

**Filed:** Bennett-armp (P1) soft_pow within 2 ULP, not bit-exact, needs maintainer decision;
Bennett-7q9z (P2) register_callee! should invalidate both caches; Bennett-f69x (P3) precise
per-entry cache invalidation; Bennett-u1zi (P3) sign of underflowed negative odd power;
Bennett-0g4p (P3) audit in-place adder/subtractor primitives for overlap checks.
**Annotated:** Bennett-8aes — typed `f(x::Float64)` fails with the VoidType message.

## Session log — 2026-10-03 — batch 1 landed: Bennett-u91f (6665a60), Bennett-g6u9 (5b0ab97), Bennett-3wk7 (0cce5d9), Bennett-9k7n (9b04a87)

**Bennett-u91f — controlled() simulate misdecoded unsigned outputs** (6665a60). `_simulate_ctrl`
passed `(Int(ctrl), x...)` to `_simulate`; the zc50 signedness heuristic (all inputs Unsigned and
all widths equal) saw the signed 1-bit ctrl and always decoded signed, so
`simulate(controlled(identity-UInt8), true, 0xff) == -1`. Fix: heuristic factored into
`_infer_unsigned_out` (src/simulator.jl), `_simulate` / `_simulate_with_buffer!` take an
`unsigned_out` keyword, and src/controlled.jl runs it on the payload widths only. New
test_u91f_controlled_signedness.jl: 2613 pass; related controlled/zc50 files green. Two
test_controlled.jl cases (soft_fneg, soft_fmul-then-fneg) relied on the bug via
`reinterpret(UInt64, Int64(raw))` and now compare `raw === soft_fneg(x_bits)`. Gate counts
unchanged. Bead closed with one related case NOT fixed: typed `simulate(c8, UInt16, 0xffff)` on
`x%UInt8` returns 0xffff instead of 0x00ff (width-mismatched, needs output signedness stored on
the circuit); carved out into Bennett-13xy (P1).

**Bennett-g6u9 — mixed SoftFloat `==` miscompiled** (5b0ab97). `SoftFloat` is not a `Number` and
only SoftFloat==SoftFloat existed, so `SoftFloat(0.0) == 0.0` hit Base's `===` fallback, returned
false during tracing, and `x == 0.0 ? x + 1.0 : x` compiled to a 66-gate identity circuit that
still passed `verify_reversibility`. Fix (src/softfloat_dispatch.jl only): mixed `==` in both
orders; Float64 via `soft_fcmp_oeq`; Integer exact like Base (compare with `Float64(b)` and
require `Float64(b) == b`); other Reals throw an ArgumentError naming the bead. New
test_g6u9_softfloat_mixed_eq.jl: 2531 pass (host parity, plus seven compiled circuits bit-exact
on 50 inputs). Targeted run 9157/9157. Gate counts unchanged.

**Bennett-3wk7 — f32/f16 int<->float casts fell into a silent IRCast** (0cce5d9).
`_convert_instruction` (src/extract/instructions.jl) routed only `double` through the soft
casts; f32/f16 fell into a width-only `IRCast` reinterpreting float bits as an integer
(`unsafe_trunc(Int32, 1.5f0)` gave 1069547520). Reproduced from plain Julia; the bead's "raw .ll
only" text was wrong (Float32 intermediates reach it). Both fallbacks now call
`_int_fp_cast_error`, which raises a loud `_ir_error` naming Bennett-3wk7 / Bennett-3rph.
New test_3wk7_f32_cast_reject.jl: red 24 fail / 514 pass, green 538/538; f64 casts stay
bit-exact over all 256 inputs. Gate counts unchanged. Float32 fptosi via exact fpext left out of
scope (rejection matches the bead). Bennett-s6d6 confirmed still broken; not touched here.

**Bennett-9k7n — lower_call! callee wire remap vs free-list reuse** (9b04a87). `lower_call!`
(src/lowering/call.jl, compact and non-compact) took `wire_offset = wire_count(wa)`, discarded
`allocate!`'s returned vector and mapped callee wire k to `wire_offset + k`. `allocate!` serves
the free list first and QROM frees its scratch wires, so a table lookup followed by a call put
callee gates on unreserved wires (compact: wrong output with `verify_reversibility` true;
non-compact: dirty ancillae). Fix: `wmap = allocate!(wa, n)` and every callee wire, gate and
loop-guard maps through `wmap[k]`; `_remap_gate_offset` became `_remap_gate(g, wmap)`. With an
empty free list `wmap` is the old contiguous range, so gate counts are unchanged. New
test_9k7n_call_wire_remap_freelist.jl: 48/48 ParsedIR + 8/8 Julia witness; both red before the
fix. Targeted runs 4257/4257 and, after rebase, 586/586 including gate_count_regression.

**Gotchas.**
- 3wk7: `_type_width` maps float/half to 32/16, so only `src_w == 64` distinguished double; test
  `LLVM.value_type(...) isa LLVM.LLVMDouble`, not the width.
- g6u9: the 66-gate identity is the miscompile signature. An ArgumentError thrown while tracing
  surfaces as "VoidType reached _type_width (Bennett-dq8l / U81)", not the original message.
- g6u9: `isequal(SoftFloat, x)` falls back to `==`; NaN and +-0 disagree with Float64.
- 9k7n: the bug needs a constant table of >= 32 entries (size 16 passed before the fix); it shows
  with optimize=true in plain Julia, passes with optimize=false.
- 9k7n: a failing first top-level `@testset` aborts the file; run a testset alone to confirm red.
  `simulate` throws on dirty ancillae, so mismatch counters need `try`.
- u91f: any outside code using the `reinterpret(UInt64, Int64(raw))` workaround on controlled
  circuits now throws InexactError for results >= 2^63.

**Filed:** Bennett-13xy (P1) ReversibleCircuit output signedness (UInt16->UInt8 witness);
Bennett-ero9 (P2) SoftFloat isequal/hash; Bennett-l3a0 (P2) GateGroup wire ranges assume
contiguous allocation (includes the aggregate.jl:159-166 comment recheck); Bennett-ddap (P3) typed
simulate for ControlledCircuit; Bennett-ju3o (P3) f32 fptosi/fptoui via fpext; Bennett-n47e (P3)
int width > 64 guard on raw .ll casts.   **Annotated:** Bennett-8aes — tracing-time throws surface
as the VoidType wall.

## Session log — 2026-10-03 — campaign setup: four worktree slots, serialised landing, batched review

**Mode (maintainer, 2026-10-03).** Wide instead of serial: four coding subagents (Opus) work
concurrently, one bead each, land it, stop. Review (`codex exec -m gpt-6.1-sol`, effort high) is
launched by the orchestrator only after several items have landed, over the accumulated diff —
CLAUDE.md rule 2 reworded to say so. Sonnet subagents for triage and quick fixes. No Astra or
Fable subagents (quota). ONE full-suite run for the whole session, mid/late campaign; workers
run targeted files only. Work stays under quota pace (the `quota` skill, polled at checkpoints).

**Queue.** A Sonnet triage of the 196 open beads (98 P1/P2) classified them by the four verdict
classes of worklog/109 and by area, with likely files and size. Class-1 (recogniser) beads are
held back pending the V2-PRD D0 decision. Waves of four are chosen so the four beads touch
different files. Known same-file clusters that must run serially: `extract/callees.jl`
(4ddk, p9a0, wh1p); `softfloat_dispatch.jl` (g6u9, lgwa, 8aes, 19jw); the eager strategy files
(3vji, htu2, ui55, exb3, o23d); `diagnostics.jl` (u3b2, kk3y; 1f92 depends on u3b2); `cfg.jl`
(73gr, n9o8, next to the parked i5zn branch); `call.jl` (9k7n, 0a6f).

**Setup facts worth keeping (worktrees + Julia precompile):**
- `Manifest.toml` is gitignored, so a fresh `git worktree` has none and `julia --project` cannot
  load the deps. Copy the main tree's `Manifest.toml` into each worktree.
- Dependency caches are shared across worktrees (same manifest → same versions; Julia accepts a
  cache written under another active project). Bennett's own cache is per source path, so each
  worktree precompiles Bennett once per source change: **~51 s wall, ~2.9 GB RSS** on this box
  (64 cores, 62 GB). Four in parallel is fine here.
- Julia keeps at most 10 cache files per package name; each (worktree path × flag set) is one
  file. Four slots + main + default-vs-`--check-bounds=yes` would thrash, so the workers use ONE
  flag set (suite mode, `--check-bounds=yes`) through a wrapper that also sets
  `JULIA_MAX_NUM_PRECOMPILE_FILES=64`, `JULIA_PKG_OFFLINE=true` and a `timeout`. Fixed slot paths
  are reused across beads (`git checkout -B work/<bead> main`), so the cache count stays bounded.
- Slots were pre-warmed serially for the first one (it also proves the deps are cached under the
  flag set), then the other three in parallel, before any worker started.
- Workers never run `bd` (each worktree has its own copy of the tracked dolt store; `bd show`
  churns it), never run `Pkg` operations, and never touch `.beads/`, `worklog/`, `WORKLOG.md`,
  `CLAUDE.md`, `Manifest.toml`. Bead text is dumped once to files by the orchestrator.
- Landing is serialised by a `flock` script: refuse if the branch touches orchestrator-owned
  files → if `main` moved, rebase and hand back for a targeted re-test → otherwise
  `merge --ff-only` into the main tree and push. The orchestrator closes beads and writes the
  worklog in batches (single writer for `.beads/` and `worklog/`).
- New test files are registered with a `runfile(...)` line next to a related file, not at the
  end of `test/runtests.jl`, to keep four concurrent branches from colliding on one hunk.
- Codex's configured default model is `gpt-6-astra`; the reviewer must always be named
  explicitly (`-m gpt-6.1-sol -c model_reasoning_effort=high`).
