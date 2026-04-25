## 2026-04-11 — Checkpoint Bennett: 66% wire reduction on SHA-256 (Bennett-an5)

### What was built

1. **GateGroup wire range tracking (`wire_start`/`wire_end`)**
   - Added `wire_start::Int` and `wire_end::Int` fields to `GateGroup` struct
   - Backward-compatible 5-arg constructor defaults to `(0, -1)` (empty range)
   - Wire ranges tracked at all 7 group-creation sites via `wa.next_wire` snapshots
   - Key insight: during `lower()`, `free!()` is never called, so WireAllocator
     allocates sequentially. `wire_start:wire_end` is contiguous and complete.
   - 3+1 agent review: two independent proposer agents, synthesised design

2. **`checkpoint_bennett(lr)` — per-group checkpointing**
   - New function in `src/pebbled_groups.jl`
   - Algorithm:
     - Phase 1: For each group: forward → CNOT-copy result to checkpoint → reverse
       (frees internal wires, only checkpoint stays)
     - Phase 2: CNOT-copy final output to permanent output wires
     - Phase 3: Cleanup in reverse order: re-forward → un-copy checkpoint → reverse → free checkpoint
   - Result: peak wires = inputs + copies + sum(checkpoints) + max(one group's internals)

### Key research findings

1. **The Knill recursion as previously implemented does NOT reduce peak wire count.**
   The implementation forwards ALL groups linearly at each recursion level without
   intermediate checkpointing. At the copy point, all 46 SHA-256 groups are live
   simultaneously — identical to full Bennett. The recursion trades TIME (re-computation)
   for nothing in this implementation.

2. **Per-group checkpointing IS the actual optimization.** By checkpointing each
   group's result (CNOT copy to fresh wires) then reversing (freeing internal wires),
   peak wires are bounded by checkpoints + max_one_group. Internal wires (carries,
   partial products, zero-padding) dominate: SHA-256 groups have 32-bit results but
   up to 512-bit internal wire ranges.

3. **PRS15's "353 qubits" is for 10 SHA-256 rounds, not 1.** The WORKLOG's prior
   session incorrectly stated "PRS15 achieves 353 wires for 1 round." Per-round
   extrapolation: ~35 qubits. PRS15 also uses in-place ops (Cuccaro), which we don't
   (SSA-based out-of-place). Apple-to-oranges comparison.

4. **Wire tracking is necessary but not sufficient.** Adding `wire_start`/`wire_end`
   to GateGroup enables proper wire remapping in `_replay_forward!`, but the
   algorithmic change (per-group checkpointing) is what produces the wire reduction.

### Wire reduction results

| Function | Full Bennett | Checkpoint | Reduction |
|----------|-------------|-----------|-----------|
| x+3 (i8) | 41 | 49 | -20% (overhead > savings for 2 groups) |
| polynomial (i8) | 265 | 233 | 12% |
| **SHA-256 round** | **5889** | **1985** | **66.3%** |

SHA-256 achieves 3.0x reduction (5889/1985). The reduction scales with group count
and internal-to-result wire ratio. Small functions (2-4 groups) don't benefit because
checkpoint overhead exceeds internal wire savings.

### Gotchas

1. **Checkpoint ordering matters.** Phase 3 cleanup must process groups in REVERSE
   topological order (reverse of Phase 1). When cleaning group i, its dependencies
   (groups j < i) must still have their checkpoints live for the re-forward.

2. **Checkpoint is NOT a group.** Checkpoint wires are managed separately from
   ActivePebble. After Phase 1 reverse of a group, its checkpoint is registered
   in `live_map` as an ActivePebble with empty internal_wires, enabling downstream
   groups to find dependency results.

3. **wire_count(wa) is the peak, not the live count.** Even when wires are freed
   (returned to free_list), `wa.next_wire` never decreases. The peak is determined
   by the maximum simultaneous allocation, not the final state.

4. **Small functions are worse.** With only 2 groups (increment), checkpoint overhead
   (1 checkpoint per group) exceeds internal wire savings. The break-even is ~4+ groups
   with significant internal wire usage (multiplier, additions).

### Bennett-mz8: Cuccaro default — CLOSED

Made `use_inplace=true` the default in `lower()`. Cuccaro routes dead-operand
additions through in-place adder (1 ancilla vs 2W). However, in-place results
have wires outside the group's wire range (they belong to a dependency), which
breaks checkpoint_bennett's forward-copy-reverse. Added guards: both
`checkpoint_bennett` and `pebbled_group_bennett` detect in-place results and
fall back to `bennett()`.

### Bennett-i7z: EAGER checkpoint cleanup — DEFERRED

Attempted EAGER: free dead checkpoints during Phase 1 when all consumers are
checkpointed. Prototype achieved 1057 wires (47% below 1985 non-EAGER) but
FAILED simulation — wire reference beyond n_wires.

**Root cause:** EAGER freeing during Phase 1 removes checkpoints that Phase 3
needs for re-forward. For a linear dependency chain (SHA-256's structure),
freeing group D means group G (which depends on D) can't re-forward during
Phase 3 cleanup. The dependency check `deps_available` prevents cascading but
doesn't protect downstream Phase 3 consumers.

**Fundamental tension:** EAGER checkpoint cleanup requires either:
1. Integrated forward-and-cleanup (no Phase 3 — cleanup immediately after each group)
2. Safe eager set via fixed-point analysis (only free groups whose ALL transitive
   descendants will also be eagerly freed)
3. Finer granularity (value-level, not group-level, matching PRS15's MDD approach)

SHA-256's mostly-linear dependency chain limits EAGER to ~10% savings (only a few
independent branches in sigma/ch/maj). The high complexity vs modest benefit led
to deferral. Bennett-2rh (intra-group cleanup) is higher priority: targets the
4000 internal wires directly.

### Bennett-2rh: Intra-group carry cleanup — DEFERRED

Attempted: add carry-reversal gates within lower_add! to zero carry wires
during the forward pass, then free them during _replay_forward!.

**Why it fails:** The reverse of the forward gates TARGETS carry wires. If
carry wires are freed after forward (and reused by checkpoint allocation),
the reverse gates corrupt the reused wires. The reverse NEEDS carry wires
at their computed values to properly undo the forward.

**Key insight:** Intra-group wire cleanup is fundamentally incompatible with
the per-group checkpoint-and-reverse pattern. You can't free wires between
forward and reverse if the reverse gates target those wires.

**What would work instead:**
1. Use Cuccaro in-place adders (no carry wires at all) — but incompatible
   with checkpoint_bennett due to in-place result wire ownership
2. Split adder into finer groups (one per carry stage) — but ~32 groups per
   add is impractical
3. Fundamentally different architecture: value-level pebbling (PRS15's MDD)
   that operates below the group level

Both Bennett-2rh and Bennett-i7z point to the same conclusion: the group-level
checkpoint approach has reached its practical limit at 3.0x reduction. Further
improvement requires either (a) PRS15-style MDD-level value pebbling, or
(b) making Cuccaro compatible with checkpointing.

### Prototype 0: Constant-fold fshl/fshr — COMPLETED (biggest win)

**Root cause found via wire breakdown analysis:** Carry wires are only 8.1% of SHA-256
allocation. The DOMINANT wire consumer (55.8%) is barrel-shifter MUX logic from
variable-amount shifts — caused by our fshl/fshr decomposition emitting `sub(32, const)`
as a runtime SSA value instead of constant-folding.

**Fix:** In `ir_extract.jl`, when decomposing `fshl(a, b, sh)` with constant `sh`,
compute `w - sh` at compile time: `iconst(w - sh.value)` instead of emitting a `sub`
instruction. Eliminates 6 barrel-shifter groups (3072 wires) and 6 subtraction groups
(960 wires) from SHA-256.

**Results:**

| Metric | Before | After | Reduction |
|--------|--------|-------|-----------|
| Full Bennett | 5889 | 2049 | 65% |
| Checkpoint | 1985 | 1761 | 11% |
| sigma0 alone | 2305 | 385 | 83% |

**Key lesson:** "Measure before optimizing." I spent hours on carry cleanup (8.1% of
wires) when the real bottleneck was barrel shifters (55.8%). The wire breakdown
analysis by the research subagent identified the correct target.

### Prototypes 2-5: EAGER and Cuccaro variants — all hit the same wall

Five architectures attempted for further wire reduction beyond checkpoint_bennett:

| Prototype | Approach | Result | Failure mode |
|-----------|----------|--------|-------------|
| 0 | Constant-fold fshl/fshr | **65% reduction** | SUCCESS |
| 2 | Wire-level EAGER (last-use) | 0% | Cleaned wires corrupt Phase 3 reverse controls |
| 3 | Group-level EAGER single-pass | 0% | Linear chains → all groups path to output → nothing cleanable |
| 4 | Cuccaro + checkpoint | Non-zero ancillae | In-place modifies shared function input wires |
| 5 | Sub-group splitting | Not attempted | Analysis showed carries are only 8.1% of wires |

**Root cause:** All approaches 2-4 fail because of the SSA/out-of-place representation.
PRS15 works on F# AST with explicit `mutable` variables (one wire mutated W times).
LLVM SSA produces fresh wires for every value (W wires, each written once). The cleanup
strategies (EAGER, checkpoint, pebbling) operate ABOVE this representation and cannot
overcome the constant factor difference.

### Architectural comparison: Bennett.jl vs PRS15 (REVS)

**The gap is a constant factor (~4-5x), not asymptotic.** Both are O(T) gates, O(S) space.
The constant factor is the price of generality.

**Bennett.jl advantages over PRS15:**
- **Any LLVM language** (Julia, C, C++, Rust, Fortran) vs F# only
- **Full LLVM optimization pipeline** inherited (constant fold, DCE, CSE)
- **34 opcodes + 12 intrinsics** vs "a subset of F#"
- **Full IEEE 754 float** (soft-float: add/sub/mul/div/cmp, bit-exact) vs none
- **Arbitrary CFGs** via path-predicate phi resolution vs straight-line only
- **No source annotation** required — plain Julia in, reversible circuit out
- **Post-optimization** (like Enzyme) vs pre-optimization (AST level)

**PRS15 advantage:** ~4-5x fewer qubits on arithmetic-heavy functions due to in-place
operations with MDD mutation tracking. This advantage shrinks for bitwise-heavy functions
(XOR, AND, shifts are already 1 wire per bit in SSA).

**Decision:** Accept the constant factor. The Enzyme analogy holds — Enzyme also pays a
constant factor vs hand-written adjoints but wins on coverage, automation, and
composability. The 5x overhead is irrelevant for a researcher who wants
`when(qubit) do f(x) end` on arbitrary Julia code without rewriting anything.

### Final SHA-256 round wire counts (this session)

| Strategy | Wires | vs Original |
|----------|-------|-------------|
| Full Bennett (original) | 5889 | baseline |
| + constant-fold fshl/fshr | 2049 | **65% reduction** |
| + checkpoint_bennett | 1761 | **70% reduction** |
| + Cuccaro (full Bennett) | 1545 | 74% reduction |
| PRS15 EAGER (1 round) | ~704 | 88% (different arch) |
| PRS15 EAGER (10 rounds) | 353 | 94% (constant space) |

### Test results

- Full test suite: all tests pass, zero regressions
- SHA-256: correct output, all ancillae verified zero

---

## 2026-04-12 — Fix _narrow_inst(IRCast) (Bennett-z9y)

### The bug

`src/Bennett.jl:75` had `_narrow_inst(inst::IRCast, W::Int) = IRCast(inst.dest, inst.op, inst.src_width, W, inst.operand)` — two errors: IRCast has no `src_width` field (it's `from_width`/`to_width`), and the positional order was wrong (`src_width` at position 3 where `operand` belongs). Any `bit_width > 0` compile of a function whose LLVM IR contained a cast hit `FieldError`. Reported by Sturm.jl agent — blocks Sturm's `oracle(f, x::QInt{W})` path for any predicate with a comparison or literal coercion.

### The subtlety the external report missed

External report proposed `IRCast(inst.dest, inst.op, inst.operand, W, W)` — narrow both widths to W. This compiles but crashes at `lower_cast!` with `BoundsError` for casts from `i1`. LLVM emits `zext i1 %cmp to i8` for `Int8(x == 5 ? 1 : 0)`; the operand is a 1-bit comparison result. If we lie to `resolve!` that the source is W bits wide, it returns a 1-element vector and the CNOT copy loop over `1:W` overruns.

**Correct rule: preserve i1, narrow everything else** — same pattern as `_narrow_inst(::IRPhi)` at line 77.

```julia
_narrow_inst(inst::IRCast, W::Int) = IRCast(inst.dest, inst.op, inst.operand,
                                             inst.from_width > 1 ? W : 1,
                                             inst.to_width > 1 ? W : 1)
```

### Lesson

External bug reports get you halfway. The reporter correctly identified the field/ordering error but hadn't traced what `_narrow_inst` means for each opcode shape in practice. Always reproduce first, then check the *second* failure mode before landing a fix — fix-first thinking misses the class of bugs that only surface once the first-order bug is gone.

### Regression test

Added to `test/test_narrow.jl` — the exact reproduction case (`Int8(x == 5 ? 1 : 0)` at `bit_width=3`).

### Files changed

- `src/Bennett.jl` line 75: one-line fix
- `test/test_narrow.jl`: regression testset
- `WORKLOG.md`: this entry

## 2026-04-12 — Fix _narrow_inst for IRBinOp/IRICmp/IRSelect on i1 (Bennett-wl8)

### The bug

Same class as Bennett-z9y, different instruction types. `_narrow_inst` for `IRBinOp`, `IRICmp`, `IRSelect` unconditionally replaced `width` with W. For i1 boolean values (icmp results, `&&`/`||` short-circuit, boolean ternaries), this is wrong — booleans don't narrow.

Concrete failure (reported by Sturm.jl): `Int8((x > 5 && (x & Int8(1)) == 1) ? 1 : 0)` at `bit_width=3`. Julia's `&&` on two `icmp` results lowers to `and i1 %0, %.not`. After narrowing, the `and` has `width=3` but its operands are still 1-wire icmp results — `lower_and!` loops `1:W` and over-indexes the 1-element operand vector.

### Fix

Same guard as `_narrow_inst(::IRPhi)` and `_narrow_inst(::IRCast)`:

```julia
_narrow_inst(inst::IRBinOp, W::Int) = IRBinOp(inst.dest, inst.op, inst.op1, inst.op2, inst.width > 1 ? W : 1)
_narrow_inst(inst::IRICmp, W::Int) = IRICmp(inst.dest, inst.predicate, inst.op1, inst.op2, inst.width > 1 ? W : 1)
_narrow_inst(inst::IRSelect, W::Int) = IRSelect(inst.dest, inst.cond, inst.op1, inst.op2, inst.width > 1 ? W : 1)
```

### Rule (for future narrowing-related code)

**i1 is logical width, not numeric width.** Any IR instruction with a `width` field that can be 1 (from boolean predicates) needs the `width > 1 ? W : 1` guard. This now covers every IR type in `_narrow_inst` that carries a width.

### Regression test

`test/test_narrow.jl`: `Int8((x != Int8(0) && x != Int8(5)) ? 1 : 0)` at `bit_width=3`. Uses `!=` so the predicate is width-agnostic (equality doesn't differ between signed and unsigned interpretations at narrow widths).

## 2026-04-12 — Memory plan T0.1: LLVM pass pipeline control (Bennett-3pa)

### What was built

`extract_parsed_ir` gains a `passes::Union{Nothing,Vector{String}}=nothing` kwarg. When supplied, the named LLVM New-Pass-Manager passes run on the parsed module before walking. Plumbing only; T0.2 will set defaults.

### API

```julia
extract_parsed_ir(f, T; passes=["sroa", "mem2reg", "simplifycfg"])
```

Pass names are canonical LLVM NPM pipeline strings (see llvm.org/docs/NewPassManager.html). Use `","`-separated subpipelines if needed; internally we join with `,` and hand to `NewPMPassBuilder` + `run!(pb, mod)`.

### LLVM.jl API we rely on

- `LLVM.NewPMPassBuilder()` — pass builder
- `LLVM.add!(pb, pipeline_string)` — register a pipeline
- `LLVM.run!(pb, mod)` — execute on a module

LLVM.jl 9.4.6 on Julia 1.12.3 has these as public API. The old legacy pass manager (`ModulePassManager`) is also present but deprecated in upstream LLVM; stick with NewPM.

### Test

`test/test_preprocessing.jl` (new): 263 assertions covering backward compat (`passes=nothing` matches old behavior), custom passes execute without error, empty pass list is a no-op, and `reversible_compile` still passes full 256-input sweep on `x + Int8(3)`.

## 2026-04-12 — Memory plan T0.2: preprocess kwarg + default pass set (Bennett-9jb)

### What was built

- `const DEFAULT_PREPROCESSING_PASSES = ["sroa", "mem2reg", "simplifycfg", "instcombine"]` — the curated set for eliminating alloca/store before IR extraction.
- `extract_parsed_ir(...; preprocess::Bool=false, passes=nothing)` — when `preprocess=true`, runs the default set. `preprocess` + explicit `passes` compose additively (default first, then explicit).

### Measurement

Tested on `f(x::Int8) = let arr = [x, x+Int8(1)]; arr[1] + arr[2]; end` which produces 5 allocas / 6 stores in raw LLVM IR (`optimize=false`). After `DEFAULT_PREPROCESSING_PASSES`: 0 allocas, 0 stores.

Even running just `"sroa"` alone eliminates all of them for this function; the added passes are cheap insurance. Order matters if loads depend on cross-pass canonicalization, but for our target (eliminate memory ops before IR walking) SROA is the workhorse.

### Gotchas

- `sprint(io -> show(io, mod))` is the way to dump an `LLVM.Module` back to IR text; `string(mod)` doesn't give the IR form.
- Julia's `code_llvm(..., optimize=false)` still runs some ahead-of-time optimization (Julia codegen emits SSA directly for most simple functions). You need a real allocating expression — like `[x, y]` — to actually observe allocas pre-pass.
- `preprocess=false` is intentionally the default: backward compat. Users opt in. When T1b wires memory support end-to-end, preprocess=true will become the default in `reversible_compile`.

