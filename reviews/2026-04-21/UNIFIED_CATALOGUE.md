# UNIFIED CATALOGUE — 2026-04-21 mother-of-all review

**Source:** 19 independent review reports under `reviews/2026-04-21/01_*.md` through `19_*.md`. Extracted by 19 parallel second-pass subagents; this file dedupes, ranks, and cross-references their findings into one actionable triage sheet.

**Known false alarm:** Sturm.jl integration (#02 F6 flagged as such). Sturm hosts integration; Bennett-side is not a deliverable. Filtered out of every section below.

**Scope:** actionable findings only (no philosophy). Existing open beads noted where a finding overlaps; "propose bead" = no existing bead covers it.

**Severity legend:**
- **CRIT** — invariant violation / silent correctness corruption / silent data loss.
- **HIGH** — user-visible bug or documented-but-broken API; structural debt that actively produces bugs.
- **MED** — taste / refactor / architectural drift; docstring vs behaviour drift with correctness impact.
- **LOW / NIT** — doc drift, cosmetic, hygiene.

Dedup key format: `U##` = unified ID. Cross-references: `#NN.F#` = reviewer NN, finding F#.

---

## Executive summary — the must-fix list

Every reviewer independently flagged the same spine of issues. The consensus top-10, in approximate dependency order:

1. **`verify_reversibility` is a tautology** (U01) — fixes expose U02-U05 below.
2. **`value_eager_bennett` leaks ancillae on every branching function, 100%** (U02).
3. **`self_reversing=true` has no runtime check** (U03) — unchecked trust boundary.
4. **`checkpoint_bennett`/`pebbled_group_bennett` crash on any branching code** (U04) — no fallback.
5. **`lower_loop!` silently drops every non-arith body instruction** (U05) — `max_loop_iterations` effectively a no-op for real loops.
6. **`soft_fmul` wrong on subnormals** (U06) — 2-line fix (`_sf_normalize_to_bit52`).
7. **Five `ir_extract` silent-corruption bugs** (U09-U13): i128 truncation; extractvalue on Struct; switch-phi patching incomplete + duplicate-target; GEP offset=raw-index; IRVarGEP.elem_width default 8.
8. **NaN payload/sign canonicalised across every soft-float op** (U08) + sNaN quieting missing in `fpext`/`trunc`/`floor`/`ceil` — violates CLAUDE.md §14 bit-exact.
9. **HAMT silently drops 9th distinct-hash key; `cf_reroot` breaks on key=0; `soft_feistel_int8` not a bijection** (U20-U22) — makes U79 (EoL half the persistent-map shelf) much more urgent.
10. **`:auto` add dispatcher is strictly worse than `:ripple` on i32+** (U27) and `fold_constants=false` is the default despite being safe (U28) — silent gate-count pessimisation.

**Blast-radius verdict:** U01 is the meta-bug that hides U02-U04, U23, U80 in CI. Fixing it first is load-bearing — otherwise every subsequent "fix" is validated by the broken oracle.

---

## Section A — CRITICAL

### U01 `verify_reversibility` is tautological — never checks ancilla-zero
- **Severity:** CRIT (meta-bug — hides U02/U03/U04/U23/U80 in CI)
- **Sites:** `src/diagnostics.jl:145-161`, mirrored for ControlledCircuit at `src/controlled.jl:89-107`.
- **Reviewers:** #03 F1, #05 F1, #09 F1, #09 F12, #13 implicit, #16 F14.
- **Claim:** Runs `forward;reverse(forward)` and asserts bits return to input. Self-inverse for any NOT/CNOT/Toffoli sequence regardless of ancilla state. Ancilla-zero check lives only in `simulate` at `src/simulator.jl:30-32`, but ~256 `verify_reversibility` call sites across 75 test files do NOT pair it with a spanning `simulate` sweep.
- **Repro:** `c = ReversibleCircuit(3, [NOTGate(3), CNOTGate(1,2)], [1],[2],[3],[1],[1]); @assert verify_reversibility(c)==true; simulate(c,0) # ERRORs`.
- **Fix:** Run forward-only on zero-ancilla input across a spanning input set; assert every ancilla wire is zero. Also fix `verify_reversibility` contract asymmetry (#16 F14): return `Bool` consistently or always raise.
- **Bead:** **propose P0 bead** (precondition for everything else).

### U02 `value_eager_bennett` leaks ancillae on ANY branching function
- **Severity:** CRIT
- **Sites:** `src/value_eager.jl:29-137` (esp. 96-135); producers at `src/lower.jl:379,389` (`_compute_block_pred!`).
- **Reviewers:** #09 F2.
- **Claim:** Phase-3 Kahn topological uncompute walks `input_ssa_vars`; synthetic `__pred_*` groups have `input_ssa_vars = Symbol[]`, so predicate-wire cross-group deps are invisible and the entry-block predicate gets reversed before later consumers. 256/256 Int8 inputs fail on `x>0 ? x+1 : x-1`.
- **Fix:** Safer option — refuse the Phase-3 Kahn path whenever any `__pred_*` group exists and fall back to `bennett(lr)`. Harder — register predicate-to-predicate SSA deps on `__pred_*` groups so Kahn respects them.
- **Bead:** **propose P0**, depends on U01.

### U03 `self_reversing=true` is an unchecked trust boundary
- **Severity:** CRIT
- **Sites:** `src/bennett_transform.jl:23-30`; callers including `src/mul_qcla_tree.jl:60-74`.
- **Reviewers:** #09 F3, #09 F5 (umbrella), #14 F8.
- **Claim:** When `lr.self_reversing==true`, `bennett()` returns forward gates with no copy-out, no reverse, no ancilla assertion. Repro: forge `LoweringResult(..., self_reversing=true)` on gates that leave ancillae dirty → `bennett(lr)` accepts it silently.
- **Fix:** In the fast path, simulate forward gates on zero-ancilla input (O(|gates|)) and assert ancillae are zero before accepting. Document "UNCHECKED, callee must prove cleanliness" until this lands.
- **Bead:** **propose P0**, depends on U01.

### U04 `checkpoint_bennett` / `pebbled_group_bennett` / `pebbled_bennett` crash or misbehave on branching code
- **Severity:** CRIT
- **Sites:** `src/pebbled_groups.jl:16` (error), `:273-332, 351-452` (dispatch, missing branching-aware fallback); `src/pebbling.jl:152-192` (pebbled_bennett no validation).
- **Reviewers:** #09 F4, #09 F5, #09 F7.
- **Claim:** Fallback triggers don't include "contains phi/branching CFG". Diamond CFG → `Unmapped wire N in gate remapping`. `pebbled_bennett` runs Knill recursion over gate ranges assuming per-gate fresh target wires — any in-place emitter (Cuccaro `b+=a`, `emit_shadow_store!`) silently breaks it.
- **Fix:** Add precondition refusing non-pure-SSA / branching `LoweringResult`, or fall back to `bennett(lr)` when branching groups detected. Mark these strategies "not safe on branching" in their docstrings until fixed.
- **Bead:** **propose P1**, depends on U01.

### U05 `lower_loop!` silently drops non-arithmetic body instructions
- **Severity:** CRIT
- **Sites:** `src/lower.jl:692-782`, especially `:744-748` (4-of-~12 IR types covered), `:307` (`max_loop_iterations` kwarg), `:762`.
- **Reviewers:** #04 F1, #04 F3, #13 F4, #18 F9; consequence: #09 F13.
- **Claim:** Loop body `if inst isa IRBinOp elseif IRICmp elseif IRSelect elseif IRCast` covers only scalar arith. `IRCall`/`IRStore`/`IRLoad`/`IRPhi` in the body silently skipped; `Undefined SSA variable` at deep `resolve!`. Every soft-float-in-loop workload compiles wrong. `max_loop_iterations` effectively a no-op for real loops — identical gate count for K=3 and K=30.
- **Repro:** `reversible_compile((x::Int8,n::Int8)->begin a=0; while i<n; a=a+x end; a end, Int8, Int8; max_loop_iterations=5, optimize=false)` → `ERROR: Undefined SSA variable: %__v7`.
- **Fix:** Dispatch loop-body instructions through full `_lower_inst!` and re-resolve phis per iteration; at minimum add an `else error(...)` guard.
- **Bead:** **propose P1**.

### U06 `soft_fmul` skips subnormal pre-normalisation — 11-20% ULP drift
- **Severity:** CRIT (CLAUDE.md §14 violation)
- **Sites:** `src/softfloat/fmul.jl:44-49` (fix site after line 50); 53×53 extractor at lines 127-182. Compare against working `src/softfloat/fdiv.jl:42-43` and `fma.jl:67-69`.
- **Reviewers:** #07 F1, #07 F2 (bit extractor precondition), #07 F13 (one-line test would have caught), #11 F1.
- **Claim:** Subnormal operand's leading 1 sits below bit 52. 53×53 multiply computes wrong MSB position; `_sf_normalize_clz` can't recover already-truncated bits. ~110/966 random normal×subnormal pairs off by 1-2 ULP (seed 42).
- **Repro:** `a=0xE4D9C356E967BECD, b=0x8000B051DB6FC2B8; hw=0x24B1BE88A451D1E8, soft=0x24B1BE88A451D1E6` (2 ULP low).
- **Fix:** 2-line insert — `(ma, ea_eff) = _sf_normalize_to_bit52(ma, ea_eff)` and matching line for `mb` before the 53×53 multiply. Re-record fmul gate-count baseline (will rise by ~6 stages × mantissa width).
- **Bead:** **propose P0** (small, high-value, unblocks U08 verification).

### U07 `soft_fpext` (f32→f64) does not quiet sNaN
- **Severity:** CRIT (IEEE 754-2019 §5.4.1 violation; ~50% of f32 NaN inputs)
- **Sites:** `src/softfloat/fpconv.jl:62`. Sibling `fptrunc` at `fpconv.jl:148` does this correctly.
- **Reviewers:** #11 F2.
- **Claim:** `nan_result = sign64 | UInt64(0x7FF0000000000000) | (UInt64(fa) << 29)` omits quiet bit 51. 497/1000 NaN inputs differ from hardware (seed 123).
- **Fix:** Replace `0x7FF0000000000000` with `0x7FF8000000000000`.
- **Bead:** **propose P1**.

### U08 NaN sign / payload canonicalised across every soft-float op
- **Severity:** CRIT (CLAUDE.md §14 violation)
- **Sites:** `src/softfloat/fadd.jl:133`, `fmul.jl:203`, `fdiv.jl:95`, `fsqrt.jl`, `fma.jl`, `fsub.jl`; `trunc/floor/ceil` at `src/softfloat/fround.jl:38-42`. Related: `soft_fptosi` returns 0 on Inf/NaN/OOB at `src/softfloat/fptosi.jl:15-57` while hardware saturates to INT_MIN.
- **Reviewers:** #04 F2, #04 F9, #04 F18 (`isnan()` tests mask this); #07 F3, #11 F3, #11 F4 (trunc/floor/ceil), #11 F5 (fptosi), #11 F17 (Inf×0 sign).
- **Claim:** Every NaN-output operation canonicalises to `0x7FF8000000000000`; hardware produces `-NaN` (`0xFFF8...`) for invalid ops (Inf−Inf, Inf·0, 0/0, sqrt(neg)) and propagates input qNaN payloads. `fptosi` silently wraps overflow.
- **Fix:** Per-op NaN-input passthrough stage: if either operand is NaN, return `(operand | QUIET_BIT)`; invalid-op producers emit `0xFFF8...`. In `trunc/floor/ceil` special branch return `a | 0x0008000000000000`. `fptosi` saturate to `0x8000000000000000` on exponent≥63 or NaN. Land with U61 (bit-pattern tests replacing `isnan()` checks).
- **Bead:** **propose P1**.

### U09 i128 ConstantInt truncation to low 64 bits
- **Severity:** CRIT
- **Sites:** `src/ir_extract.jl:2340` (`convert(Int, val)` on LLVM.ConstantInt).
- **Reviewers:** #10 F1.
- **Claim:** `2^127` compiles to `0`.
- **Fix:** Widen `IROperand.value` to `Int128`/`BigInt`; update `src/lower.jl:177` `resolve!` to iterate widened value; use `LLVMConstIntGetZExtValue/SExtValue`; fail-loud for >64-bit until BigInt lands.
- **Bead:** **propose P1**.

### U10 `extractvalue`/`insertvalue` on StructType → raw UndefRefError
- **Severity:** CRIT
- **Sites:** `src/ir_extract.jl:1189, 1202` — assumes `ArrayType`, calls `LLVM.eltype(agg_type)`.
- **Reviewers:** #10 F2.
- **Claim:** Crashes on literal `{iN, i1}` structs — every `.with.overflow` intrinsic, `cmpxchg`, mixed-width tuples.
- **Fix:** Guard with `agg_type isa LLVM.ArrayType`; on StructType, `_ir_error(inst, "extractvalue/insertvalue on StructType aggregates not supported")`.
- **Bead:** **propose P1**.

### U11 Switch phi patching incomplete + duplicate-target overwrite
- **Severity:** CRIT
- **Sites:** `src/ir_extract.jl:1053-1078`, `:994-1082` (specifically 1045).
- **Reviewers:** #10 F3, #04 F10.
- **Claim:** `_expand_switches` only patches phis in already-appended `result[j]`; later successors unpatched. `phi_remap::Dict{Symbol,Symbol}` keyed by target label — multiple cases sharing a target overwrite each other, phi gets wrong incomings.
- **Fix:** Run phi-patching as final sweep over all `result` blocks after collection; key `phi_remap` as `(switch_block, target) → source` to handle duplicate targets.
- **Bead:** **propose P1**.

### U12 GEP `offset_bytes` stores raw index not bytes
- **Severity:** CRIT
- **Sites:** `src/ir_extract.jl:1519`; consumer `src/lower.jl:1528` multiplies by 8 as if bytes.
- **Reviewers:** #10 F4.
- **Claim:** `getelementptr i32, ptr %p, i64 1` yields `offset_bytes=1` instead of 4.
- **Fix:** Read `LLVMGetGEPSourceElementType`; compute `stride_bytes = _type_width(elt_ty)÷8`; store `offset_bytes = index * stride_bytes`.
- **Bead:** **propose P1**.

### U13 `IRVarGEP.elem_width` defaults to 8 for non-integer source types
- **Severity:** CRIT
- **Sites:** `src/ir_extract.jl:1526, 1537`; consumer `src/lower.jl:1607`.
- **Reviewers:** #10 F5.
- **Claim:** `ew = src_type isa IntegerType ? width(src_type) : 8` silently substitutes 8 for `double` GEPs (actual stride 64). Index 1 reads bit 2 not double 2.
- **Fix:** Fail-loud when source element isn't integer; never silently substitute 8.
- **Bead:** **propose P1**.

### U14 Atomic/volatile load/store silently dropped
- **Severity:** CRIT
- **Sites:** `src/ir_extract.jl:1552, 1700`.
- **Reviewers:** #10 F6.
- **Fix:** `_ir_error` on atomic/volatile load/store at extract; improve fence error to name opcode rather than width-query failure.
- **Bead:** **propose P2**.

### U15 Inline-asm call / unregistered callee silently dropped
- **Severity:** CRIT
- **Sites:** `src/ir_extract.jl:1508` (inline-asm path + user-fn path).
- **Reviewers:** #10 F7, #10 F13.
- **Claim:** `_lookup_callee("")` returns nothing → call dropped → dest SSA undefined → crashes deep in `lower.jl` as "Undefined SSA variable". CLAUDE.md §1 violation.
- **Fix:** `_ir_error(inst, "call to $cname has no registered callee handler")`; require explicit `register_callee_stub!` to silence.
- **Bead:** **propose P2**.

### U16 Multi-index GEP (struct field / global array) silently dropped
- **Severity:** CRIT
- **Sites:** `src/ir_extract.jl:1516, 1533, 1555`.
- **Reviewers:** #10 F8, #10 F11 (global 3-idx GEP), #10 F12 (direct load ptr @g).
- **Fix:** Handle 3+ index GEP by walking types and accumulating byte offset; at minimum `_ir_error` rather than silent-drop. Recognise GlobalVariable in load pointer operand.
- **Bead:** **propose P2**.

### U17 `_get_deref_bytes` function-wide regex fallback
- **Severity:** CRIT
- **Sites:** `src/ir_extract.jl:2326-2334`.
- **Reviewers:** #10 F9.
- **Claim:** Regex matches `dereferenceable(N)` anywhere on `define` line then applies N to every pointer param; non-deref pointer args get phantom input wires.
- **Fix:** Anchor regex to each param name: `dereferenceable\((\d+)\)\s+%<paramname>`; fix primary `LLVM.parameter_attributes(func, idx)` path.
- **Bead:** **propose P2**.

### U18 cc0.3 catch string-matches "PointerType" / "Unknown value kind" — swallows unrelated bugs
- **Severity:** CRIT
- **Sites:** `src/ir_extract.jl:896-907`; related wide pattern across `src/ir_extract.jl:338,340,342,343,491,957,1218,1794,1888,1966,1990` (9 bare try/catch).
- **Reviewers:** #08 F1, #08 F5, #10 F10, #06 F12.
- **Fix:** Narrow each catch to `LLVM.LLVMException` (or specific type); match on structural failure not substring. Let anything else propagate.
- **Bead:** **propose P1**.

### U19 `simulate` has no arity check on tuple overload
- **Severity:** CRIT
- **Sites:** `src/simulator.jl:5-14` (`_simulate`); mirror gap in `_simulate_ctrl`.
- **Reviewers:** #16 F1.
- **Claim:** `simulate(c_single_arg, (x,y))` silently reads first tuple element and returns garbage.
- **Fix:** Assert `length(inputs) == length(circuit.input_widths)` at entry with `ArgumentError`. Also add tuple-length check, per-input bit-width bounds, `n_wires > 0` guard (#08 F9).
- **Bead:** **propose P1**.

### U20 `hamt_pmap_set` silently drops 9th distinct-hash key
- **Severity:** CRIT
- **Sites:** `src/persistent/hamt.jl:230-236`.
- **Reviewers:** #19 F1.
- **Claim:** With 8 filled slots, 9th distinct-hash insertion computes `idx=8` matching no slot in the unrolled 0..7 chain; new key lost while bitmap mutated → bitmap inconsistent with compressed array.
- **Fix:** Clamp like linear_scan does, or error. Moot under U79 (EoL HAMT).
- **Bead:** **Bennett-cc0** epic touches this; **propose bead under cc0** or fold into U79.

### U21 `cf_reroot` uses key=0 as empty-slot sentinel; corrupts Int8(0) overwrite-reroot
- **Severity:** CRIT
- **Sites:** `src/persistent/cf_semi_persistent.jl:350-357`.
- **Reviewers:** #19 F2.
- **Claim:** `r_key == UInt64(0)` treated as "slot never allocated"; Int8(0) is a valid protocol key. `set(0,99); set(0,42); reroot` wrongly decrements `arr_count` and loses key=0.
- **Fix:** Use separate `in_use` bit not key=0 sentinel. Moot under U79 (EoL CF). Also fix harness (#19 F7) to test key=0.
- **Bead:** fold into U79.

### U22 `soft_feistel_int8` "perfect hash" claim is false — 256 → 207 images
- **Severity:** CRIT (docstring + dependent code)
- **Sites:** `src/persistent/hashcons_feistel.jl:14-17, 67-72`; test `test/test_persistent_hashcons.jl:151-158` admits weakly.
- **Reviewers:** #04 F4, #19 F3.
- **Claim:** Zero-extend → Feistel → truncate-to-low-byte destroys bijectivity. Docstring + dependent HAMT+Feistel analysis false.
- **Fix:** Either widen image to UInt16/UInt32, or rewrite docstring to "low-collision hash" and pin exact collision count.
- **Bead:** **propose P1**.

### U23 5 test files compile circuits with no ancilla-zero check
- **Severity:** CRIT (depends on U01; currently masked)
- **Sites:** `test/test_constant_wire_count.jl`, `test_dep_dag.jl`, `test_gate_count_regression.jl`, `test_negative.jl`, `test_toffoli_depth.jl`.
- **Reviewers:** #03 F2; systemic per #09 F6 (256 `verify_reversibility` sites, 11 `ancilla_count` sites across 6 files).
- **Fix:** After U01 lands, add `@test verify_reversibility(c)` + one `simulate(c, 0)` sanity call; audit all `verify_reversibility`-only call sites for paired `simulate` sweeps.
- **Bead:** **propose P1** (depends on U01).

### U24 `WireAllocator.allocate!(wa, -1)` silent empty return
- **Severity:** CRIT
- **Sites:** `src/wire_allocator.jl:8-20`; `.22` (`free!` also no double-free check).
- **Reviewers:** #08 F2; related #04 F17, #14 F13.
- **Claim:** Negative/zero `n` passes through; empty wire vector propagates into `bennett()` and blows up as `BoundsError` later.
- **Fix:** `n >= 0 || error(...)`; add in-use set for `free!` double-free detection (honor-system precondition).
- **Bead:** **propose P2**.

### U25 `reversible_compile` lacks type / bit_width validation
- **Severity:** CRIT
- **Sites:** `src/Bennett.jl:50`, `:120` (`_narrow_ir`); see also U15 at ir_extract side.
- **Reviewers:** #08 F3, #16 F6.
- **Claim:** Non-integer types and negative `bit_width` reach internals before failing; `bit_width=-5` silently produces 26-wire circuit returning 1 on input 0; `bit_width=200` on Int8 also silently accepted.
- **Fix:** Up-front `ArgumentError` if tuple elements not in `{Int8/16/32/64, UInt8/16/32/64, Float64, Bool}`; `bit_width ∈ (0, 8, 16, 32, 64)`; `max_loop_iterations ≥ 0`. Fix error messages to user-facing not LLVM-internal (#16 F15, #08 F6).
- **Bead:** **propose P1**.

### U26 `register_callee!` mutates module-global dict without locking
- **Severity:** CRIT (latent race under multi-threaded compile)
- **Sites:** `src/ir_extract.jl:220`; load-time calls `src/Bennett.jl:163-208`.
- **Reviewers:** #16 F7.
- **Fix:** `ReentrantLock` wrap, move to `CompileContext` field, or doc "single-threaded init only".
- **Bead:** **propose P3**.

### U27 `:auto` add dispatcher is strictly worse than `:ripple` for 2-operand adds
- **Severity:** CRIT (silent gate-count pessimisation; CLAUDE.md §6 regression invisible)
- **Sites:** `src/lower.jl` `_pick_add_strategy`.
- **Reviewers:** #17 F1.
- **Claim:** `(x,y)->x+y` i32 auto=410 / T-depth=124 vs ripple=350 / T-depth=64; i64 auto=826/252 vs ripple=702/128. Cuccaro's 1-ancilla win doesn't compound because Bennett copy-out doubles ancilla anyway.
- **Fix:** Change `:auto` to prefer ripple unless sequential adds create ancilla pressure; width-aware policy.
- **Bead:** **propose P2**.

### U28 `fold_constants=false` is the default despite being strictly safe
- **Severity:** CRIT (silent pessimisation; affects persistent-DS sweep)
- **Sites:** `src/lower.jl:308`.
- **Reviewers:** #17 F4.
- **Claim:** x*1 optimize=false: 692→156 gates (4.4×) when enabled; x+1 unchanged.
- **Fix:** Flip default to `true`; document if any edge case requires off.
- **Bead:** **propose P2**.

### U29 Divergent kwargs across `reversible_compile` overloads
- **Severity:** CRIT
- **Sites:** `src/Bennett.jl:58` (tuple), `:105` (ParsedIR), `:268` (Float64).
- **Reviewers:** #16 F5, #06 F5.
- **Claim:** Tuple has `optimize/bit_width/add/mul/strategy`; ParsedIR drops `optimize/bit_width/strategy`; Float64 drops `bit_width/add/mul`. Unsupported kwarg → raw `MethodError`. Docstring inconsistency.
- **Fix:** Route all three through one implementation; unrecognised kwargs → `ArgumentError` naming supported set. Or `CompileOptions` struct (see U48).
- **Bead:** **propose P2**.

### U30 `:auto` mul dispatcher never picks `:qcla_tree` / `:karatsuba`
- **Severity:** HIGH (promoted by user's BENCHMARKS framing)
- **Sites:** `src/lower.jl:1088-1094` `_pick_mul_strategy`.
- **Reviewers:** #17 F2.
- **Claim:** Defaults to `shift_add` unconditionally. i32 shift_add T-depth=190 vs qcla_tree=56; i64 382 vs 64. README's 6× T-depth win locked behind opt-in.
- **Fix:** Route `:auto` to `qcla_tree` for W≥32 when optimising T-depth; add `target=:gate_count|:depth|:ancilla` kwarg.
- **Bead:** **propose P2**, pairs with U27.

### U31 `fptoui` routed through `soft_fptosi`; `soft_fptoui` missing
- **Severity:** HIGH
- **Sites:** `src/ir_extract.jl:1594-1615`.
- **Reviewers:** #04 F8, #04 F19, #04 F13 (fpext/fptrunc unimplemented).
- **Fix:** Add `soft_fptoui` + dispatch; implement fpext/fptrunc or reject loud.
- **Bead:** **propose P2**.

---

## Section B — HIGH

### U40 `src/lower.jl` is 2,662 LOC / 93 top-level defs
- **Severity:** HIGH (unreviewable; phi correctness risk buried)
- **Reviewers:** #01 F1, #06 F1, #12 F2, #13 F10, #14 F16.
- **Fix:** Split along existing `# ---- section ----` headers into `src/lowering/{core,phi,arith,memory,call,aggregate}.jl`. #01 gives exact line-range map; #13 gives function-count sizes (~600+150+300+200 + base).
- **Bead:** **propose P2**, requires 3+1 per CLAUDE.md §2.

### U41 `_convert_instruction` is a 649-line opcode god-function
- **Severity:** HIGH
- **Sites:** `src/ir_extract.jl:1086-1734`; sibling `_convert_vector_instruction` at `:2063-2299`.
- **Reviewers:** #01 F2, #06 F1, #12 F1; vector mirror #06 F9, #17 F9.
- **Fix:** Dispatch table `_OPCODE_HANDLERS::Dict{Opcode,Function}` + `_INTRINSIC_HANDLERS::Dict{String,Function}`; each handler ~10-20 LOC; routing ~30 LOC. Share per-opcode helpers between scalar and vector dispatchers (or unify via lane-count trait).
- **Bead:** **propose P2**, 3+1.

### U42 `ir_parser.jl` is dead legacy, violates CLAUDE.md §5, still exported
- **Severity:** HIGH
- **Sites:** `src/ir_parser.jl` (168 LOC); `src/Bennett.jl:5,36` (include + export); users `test/test_parse.jl`, `test_branch.jl:16`, `test_loop.jl:11` (diagnostic `println` only).
- **Reviewers:** #01 F6, #06 F2, #18 F8, #05 F20, #17 F18 (legacy text `extract_ir`).
- **Fix:** Port the 3 tests to `extract_parsed_ir`; delete `ir_parser.jl`; drop `parse_ir` export. Also delete empty `_reset_names!()` stub at `src/ir_extract.jl:255` (#12 F15).
- **Bead:** **propose P2**.

### U43 `LoweringCtx` has 3 `::Any` hot-path fields + 4 back-compat constructors
- **Severity:** HIGH (type instability on every dispatch; reader-hostile)
- **Sites:** `src/lower.jl:50-119`; related `ParsedIR::memssa::Any` at `src/ir_types.jl:180` (circular include).
- **Reviewers:** #02 F9, #06 F7, #12 F4, #13 F3, #14 F15, #17 F5, #18 F2; also U44 below.
- **Claim:** `preds::Any`, `branch_info::Any`, `block_order::Any` with "accept any dict shape" comment. 16 fields, 4 constructors (7/12/13/14-arg) accreting M2a→M3a milestones. Sentinel `entry_label = Symbol("")` guards semantic distinction in `_lower_store_via_shadow!`. `ParsedIR::memssa::Any` justified by circular dependency — fix by moving `MemSSAInfo` definition to `ir_types.jl`.
- **Fix:** Concretise to `Dict{Symbol,Vector{Symbol}}` / `Dict{Symbol,Tuple{...}}` / `Vector{Symbol}` (they always are). Collapse to one kwarg constructor. Split `LoweringCtx` vs `MemCtx` if memory-less paths don't carry memory state. Expected 10-30% lowering speedup.
- **Bead:** **propose P2**, 3+1.

### U44 `ParsedIR::memssa::Any` due to circular include
- **Severity:** HIGH (subset of U43 but separate fix)
- **Sites:** `src/ir_types.jl:180`.
- **Reviewers:** #06 F16.
- **Fix:** Move `MemSSAInfo` definition to `ir_types.jl` (or `memssa_types.jl`); have `memssa.jl` include it.
- **Bead:** fold into U43 or file standalone P3.

### U45 Error monoculture — 190+ `error(...)` all throw `ErrorException`
- **Severity:** HIGH
- **Sites:** whole `src/`; zero `ArgumentError`/`DimensionMismatch`/`DomainError`/`AssertionError` usage.
- **Reviewers:** #06 F12 (specific catches), #08 F5/F7, #18 F3/F4.
- **Fix:** Codemod: bad-arg→`ArgumentError`, wire-length→`DimensionMismatch`, invariants→`AssertionError`, IR coverage gaps→`ErrorException`. Tests tighten to `@test_throws ArgumentError`. Convert ~2 `@assert` + ~121 `error()` skew to proper split (#18 F4).
- **Bead:** **propose P3**, chore-scope (like cc0.6).

### U46 Many `error()` sites in core have no `@test_throws` coverage
- **Severity:** HIGH
- **Sites:** `src/lower.jl` (81 errors, ~6 tested); `src/ir_extract.jl` (20 errors, ~3 tested).
- **Reviewers:** #03 F4, #03 F5, #05 F7, #08 F19.
- **Fix:** New `test_lower_errors.jl` + test file for ir_extract. Hand-craft `ParsedIR`/LLVM modules triggering ~10 load-bearing errors each. Pairs with U45 (once `ArgumentError` split lands, per-category tests).
- **Bead:** **propose P3**.

### U47 Type instability in hot paths — boxed returns, abstract vectors
- **Severity:** HIGH
- **Sites:** `src/simulator.jl` (`simulate` returns Union{Int8,...,Tuple}); `_convert_instruction` returns 17-arm Union + Vector; abstract `Vector{ReversibleGate}` boxes pointers (~56 MB overhead on 1.4M-gate circuits); `src/tabulate.jl:158-168` uses `Vector{Any}`; `_gate_controls` allocates `Vector{Int}` per call.
- **Reviewers:** #13 F6 (simulate boxed), #17 F7 (gate storage), #17 F9 (_convert_instruction union), #18 F11 (_gate_controls alloc), #18 F13 (tabulate Any), #02 F10.
- **Fix:** Typed `simulate(c, ::Type{T}, ...)::T` overload; split `_convert_instruction_single` vs `_convert_instruction_expand!`; `_gate_controls` return `Tuple` not `Vector{Int}`; tabulate rewrite as NTuple-parametric.
- **Bead:** **propose P2**, multiple cuts, 3+1 for any storage layout change.

### U48 Callee IR re-extracted per call reference (no cache)
- **Severity:** HIGH
- **Sites:** `src/lower.jl:1864, 1935, 1928-1989`.
- **Reviewers:** #01 F10, #13 F1, #17 F15.
- **Claim:** `lower_call!` re-runs `extract_parsed_ir` per callee reference at ~21 ms each; 10-fadd circuit pays ~200 ms redundant. `_callee_arg_types` also re-derives via `methods()`. Plus `:auto + tabulate` re-extracts IR under `reversible_compile`.
- **Fix:** `Dict{Tuple{Function,Type{<:Tuple}},ParsedIR}` cache in `LoweringCtx` or module-scoped; pre-populate at load time via `register_callee!`.
- **Bead:** **propose P2**.

### U49 No CI workflow — regressions land silently
- **Severity:** HIGH (load-bearing for every invariant claim)
- **Sites:** no `.github/workflows/`.
- **Reviewers:** #05 F2, #13 F13, #17 F6, #18 F19.
- **Fix:** `.github/workflows/test.yml` running `Pkg.test()` on Julia 1.10/1.11/nightly. Pin LLVM. Cache `~/.julia/artifacts`. Nightly benchmark workflow diffing against `expected_results.jsonl` (U107) — U54 baselines become CI-enforced.
- **Bead:** **propose P1** (cheap, high-leverage).

### U50 `Project.toml` version/compat drift — `0.4.0`, `julia = "1.6"`, `LLVM = "9.4.6"` exact pin
- **Severity:** HIGH
- **Sites:** `Project.toml`.
- **Reviewers:** #16 F3, #16 F4, #18 F6, #18 F7.
- **Fix:** Bump to `0.5.0`/`0.5.0-dev`; `julia = "1.10"`; relax `LLVM = "9, 10"` and `PicoSAT = "0.4"`. Add `CHANGELOG.md`. Also: `git rm --cached Manifest.toml` (library, gitignored) — #18 F5.
- **Bead:** **propose P2**, could combine with U64 (release-readiness).

### U51 Exports vs public-docs drift
- **Severity:** HIGH
- **Sites:** `src/Bennett.jl:36-48` vs `docs/src/api.md`.
- **Reviewers:** #06 F11, #16 F2, #16 F10, #16 F11, #16 F16, #16 F17, #16 F18 (ControlledCircuit), #16 F19 (9 undocumented), #19 F14 (LS not exported while HAMT/CF/Okasaki are).
- **Claim:** `NOTGate`/`CNOTGate`/`ToffoliGate`/`ReversibleGate` documented public, not exported → `UndefVarError`. `ParsedIR`/`LoweringResult` return types unexported. `lower_add_cuccaro!`-class primitives in api.md unexported. Meanwhile 25+ persistent-DS research names (`AbstractPersistentMap`, `PersistentMapImpl`, 4 `*_IMPL` sentinels, 12 `*_pmap_*`, `OkasakiState`, `cf_reroot`, `pmap_demo_oracle`) and 21 soft-float primitives leak publicly with no stable ABI. `ControlledCircuit` exported with no docstring/`show`. `simulate`/`gate_count`/`ancilla_count`/`depth`/`print_circuit` missing docstrings despite being user-facing.
- **Fix:** Export `NOTGate/CNOTGate/ToffoliGate/ReversibleGate/ParsedIR/LoweringResult`. Move persistent-DS → `Bennett.Persistent` submodule; soft-float → `Bennett.SoftFloat` submodule. Add docstrings on every exported fn. Remove primitives from api.md if keeping unexported.
- **Bead:** **propose P2**.

### U52 No precompile workload — 12-15s cold TTFX
- **Severity:** HIGH
- **Sites:** no `PrecompileTools` / `@compile_workload` in `src/`.
- **Reviewers:** #13 F2, #17 F16.
- **Fix:** `@setup_workload` in `Bennett.jl` running `reversible_compile(x->x+Int8(1), Int8)`, Float64 add, Int32 mul, one SHA-256 round.
- **Bead:** **propose P3**.

### U53 CLAUDE.md §6 baselines stale (86/174/350/702 vs actual 100/204/412/828)
- **Severity:** HIGH (actively misleads regression triage)
- **Sites:** `CLAUDE.md:27`; also `bennett.jl`/`bennett_transform.jl` rename missed in `CLAUDE.md`, `docs/src/architecture.md:78,126`, `Bennett-VISION-PRD.md:104`.
- **Reviewers:** #13 F12, #15 F1, #15 F2, #15 F3, #01 F4.
- **Fix:** Replace with current numbers citing `BENCHMARKS.md` as canonical; update File Structure block (now 31 src + 16 softfloat + 10 persistent, ~100 tests). Rename all `bennett.jl` references.
- **Bead:** **propose P3** (chore).

### U54 Persistent-DS EoL recommendation — delete CF / Okasaki / HAMT / popcount / Jenkins (~1,500 LOC)
- **Severity:** HIGH (scope bloat + harbour for U20/U21/U22)
- **Sites:** `src/persistent/cf_semi_persistent.jl` (385), `okasaki_rbt.jl` (397), `hamt.jl` (309) + `popcount.jl` (72, HAMT-only), `hashcons_jenkins.jl` (100). Keep `linear_scan.jl`, `hashcons_feistel.jl`, `interface.jl`, `harness.jl`.
- **Reviewers:** #19 F20, #02 F5, #14 F11; supported by 2026-04-20 sweep data: CF set at N=64 = 272,791 gates vs LS = 1,395 (196×); HAMT 222×; Okasaki 249×.
- **Claim:** Four of five impls are dominated by `linear_scan` at every N up to 1000. Bennett-z2dj (T5-P6 MVP) already returns NYI on the losers.
- **Fix:** Option A (reviewer preference) — delete losing impls, move briefs to `docs/literature/memory/`. Option B — relocate to `src/persistent/research/` with opt-in tests. Ties to `Bennett-cc0.1` (Okasaki delete was blocking — now moot if deleted) and `Bennett-cc0.2` (HAMT insert/delete — same).
- **Bead:** **propose P2**; subsumes U20/U21/U22 fixes.

### U55 Five `*_bennett` variants / strategy sprawl
- **Severity:** HIGH
- **Sites:** `src/bennett_transform.jl`, `src/eager.jl`, `src/value_eager.jl`, `src/pebbling.jl`, `src/pebbled_groups.jl`; exports at `src/Bennett.jl:36-48`.
- **Reviewers:** #01 F3, #06 F8, #12 F8, #16 F20.
- **Claim:** `bennett`, `eager_bennett`, `value_eager_bennett`, `pebbled_bennett`, `pebbled_group_bennett`, `checkpoint_bennett` share Phase 1/2/3 scaffolding but orthogonality untestable. Copy-wire allocation and CNOT-copy emission copy-pasted 4-6×. `_gate_controls`/`_gate_target` live in wrong file.
- **Fix:** Introduce `abstract type BennettStrategy` + concrete singletons; one generic `bennett(lr; strategy=DefaultStrategy())` dispatching internally. Extract `src/bennett/common.jl` with shared `allocate_copy_wires`, `emit_copy_gates!`, `finalize_circuit`. Deprecate the five aliases for one minor version.
- **Bead:** **propose P2**, 3+1 (core change).

### U56 MUX load/store hand-written vs `@eval`-generated duplication
- **Severity:** HIGH
- **Sites:** `src/lower.jl:1748` (hand-written 4x8), `:1773` (8x8), `:2453-2521, 2530-2606` (hand-written store twins), `:2530` (@eval generator for 2x8/2x16/4x16/2x32). Shape set `{(8,2),(8,4),(8,8),(16,2),(16,4),(32,2)}` hardcoded twice.
- **Reviewers:** #06 F4, #06 F19, #12 F7.
- **Fix:** Generate all 6 shapes via `@eval`; delete hand-written; unify error strings. Make `const MUX_SHAPES = [...]` the single source.
- **Bead:** **propose P3** (cleanup once U51 stabilises exports).

### U57 Trivial-identity peepholes missing (x+0, x*1, x|0)
- **Severity:** HIGH (20-40% gate reduction on persistent-DS sweep)
- **Sites:** `src/lower.jl` `lower_add!`, `lower_mul!`, `_fold_constants` at `:473-566`.
- **Reviewers:** #17 F3; related #04 F20 (dead-code lowering waste).
- **Claim:** x+0 → 98 gates; x*1 → 692 gates (156 with fold_constants=true); fold pass misses x+0 entirely.
- **Fix:** Peepholes on known-zero / known-one operands emit only CNOT copy-out; fix `_fold_constants` whole-operand-zero detection. Combine with DCE pre-pass for unused-dest instructions.
- **Bead:** **propose P2**.

### U58 Simulator does not verify Bennett input-preservation invariant
- **Severity:** HIGH
- **Sites:** `src/bennett_transform.jl`; `src/simulator.jl:30-31`.
- **Reviewers:** #07 F5, #09 F19 (ancilla partition unasserted).
- **Claim:** `_compute_ancillae` excludes inputs so the ancilla-zero assertion never verifies inputs return unchanged. Also `ancilla_wires` not checked against `input_wires ∪ output_wires` partition — nonsensical `output_wires` silently shrinks ancilla set.
- **Fix:** Snapshot `state[input_wires]` pre-simulate and assert bit-identical post. Assert ancilla+input+output partition equal `Set(1:n_wires)` in inner constructor.
- **Bead:** **propose P2**, pairs with U01 fix.

### U59 No `compose(c1, c2)` / `chain` API
- **Severity:** HIGH (blocks Sturm `when(q) do f(x) end` integration; blocks controlled-of-composite use cases)
- **Sites:** absent.
- **Reviewers:** #05 F3, #16 F13.
- **Fix:** Design `compose(c1::ReversibleCircuit, c2::ReversibleCircuit)::ReversibleCircuit` with documented wire-aliasing semantics; export.
- **Bead:** **propose P2**.

### U60 `isnan()`-only tests mask NaN payload bugs (U08)
- **Severity:** HIGH
- **Sites:** every `test/test_softf*.jl` — `test_softfmul.jl:11-12`, `test_softfsub.jl:59`, etc.
- **Reviewers:** #04 F18, #11 F16.
- **Fix:** Compare bit-patterns including NaN payloads; remove `isnan`-only branch once U08 lands. Add cross-op identities (`fma(a,b,0)==fmul(a,b)`). Add raw-bits sweep helper.
- **Bead:** **propose P2**, pairs with U08.

### U61 Soft-float fuzzing narrowly in [-100,100]; no subnormals / NaN / extreme exponents
- **Severity:** HIGH (this is why U06 survived)
- **Sites:** `test/test_softfmul.jl:85`, `test_softfdiv.jl:48`, `test_softfloat.jl:93,112`, `test_softfsub.jl:59`, `test_softfma.jl:175,259`, `test_softfcmp.jl:83`, `test_float_circuit.jl:52,94,143`.
- **Reviewers:** #03 F10, #05 F8, #05 F16, #11 F14; pairs with `Bennett-fnxg` (subnormal test convention).
- **Fix:** `raw_bits_sweep(rng, op_soft, op_native; n=100_000)` using `reinterpret(Float64, rand(rng, UInt64))`; template already in `test_softfdiv_subnormal.jl`. Call for fadd/fsub/fmul/fdiv/fma/fsqrt.
- **Bead:** Bennett-fnxg already open — expand scope.

### U62 T5 corpus (Julia TJ1/TJ2/TJ4; C TC1-3; Rust TR1-3) still `@test_throws`
- **Severity:** HIGH (PRD §6.1 non-negotiable)
- **Sites:** `test/test_t5_corpus_julia.jl`, `test_t5_corpus_c.jl`, `test_t5_corpus_rust.jl`; `test_p5a_ll_ingest.jl`, `test_p5b_bc_ingest.jl` only cover trivial fixtures.
- **Reviewers:** #02 F7, #02 F8, #05 F4.
- **Fix:** Land T5-P6 (Bennett-z2dj already in-flight) or amend T5-PRD §6.1. Add non-trivial C + Rust fixture compiling end-to-end.
- **Bead:** Bennett-z2dj in progress; unblock after U01-U05 land.

### U63 `depth` exported / documented / never tested
- **Severity:** HIGH
- **Sites:** `src/diagnostics.jl:14-24`; export `src/Bennett.jl:47`.
- **Reviewers:** #03 F3.
- **Fix:** `@testset "depth basic shapes"`: empty→0, sequential same-wire→N, parallel disjoint→1, mixed.
- **Bead:** **propose P3**.

### U64 `optimize=true` default contradicts CLAUDE.md §5
- **Severity:** HIGH (hides U05)
- **Sites:** `src/Bennett.jl:59, 269`.
- **Reviewers:** #04 F5.
- **Fix:** Flip default to `false`, or add CI matrix running full suite under both. Land alongside U49.
- **Bead:** **propose P2**.

### U65 Key test-coverage gaps
- **Severity:** HIGH (multiple)
- **Sites & reviewers:**
  - `test_karatsuba.jl` orphaned from `runtests.jl` (#03 F6).
  - SHA-256 round tested on 2 inputs only (#03 F8, #05 F15).
  - `test_two_args.jl` covers 266/65536 Int8×Int8 pairs (#03 F9).
  - `test_mul_dispatcher.jl` 12 pairs (#03 F16); `test_add_dispatcher` × `test_mul_dispatcher` never cross (#05 F9).
  - `test_vector_ir.jl` 6-12 inputs (#03 F15).
  - `test_controlled.jl` never composed with memory-backed / soft-float (#05 F13).
  - `test_dep_dag.jl` smoke-only (#03 F7).
  - `test_feistel.jl` bijectivity not truly checked, tolerates 3% collision (#03 F14).
  - `test_constant_wire_count.jl` only checks `>= 0/1` (#03 F13).
  - Persistent-map sanity bounds 100×-1000× wide (#03 F11).
  - Testsets with 0 `@test` (`test_eager_bennett.jl:99-108`, `test_ancilla_reuse.jl:19,29`, `test_liveness.jl:39`) — #03 F12.
  - `use_memory_ssa=true` never validated end-to-end (#05 F5).
  - External tool tests silent-skip (#03 F17, #05 F14).
  - `runtests.jl` no outer `@testset`; slow tests mid-list (#03 F20, #05 F6).
  - Loop tests Int8-only (#05 F19).
- **Fix:** One-by-one cleanup under a single "test hygiene" epic.
- **Bead:** **propose P2 epic** gathering these.

### U66 `controlled(circuit)` untested on branching callees
- **Severity:** HIGH
- **Sites:** `src/controlled.jl:16-37`; `test/test_controlled.jl`.
- **Reviewers:** #09 F9.
- **Fix:** Exhaustive Int8 sweep compiling branching function, wrapping in `controlled`, simulating both ctrl=0/1; verify output correctness.
- **Bead:** **propose P2**.

### U67 `lower_call!` with `compact=true` not tested on non-trivial callees
- **Severity:** HIGH
- **Sites:** `src/lower.jl:1938-1964`.
- **Reviewers:** #09 F8, #06 F13 (duplicated compact/non-compact arms).
- **Fix:** Spanning-input test for `compact=true` calling branching/ancilla-using callee (e.g. soft_fmul); factor the 25-char-duplicate compact/non-compact arms into `_splice_callee_gates!`.
- **Bead:** **propose P3**.

### U68 `IROperand` primitive-obsession tagged union
- **Severity:** HIGH
- **Sites:** `src/ir_types.jl:1-10`; 45 `.kind == :ssa|:const` sites codebase-wide.
- **Reviewers:** #06 F6, #18 F1; `OPAQUE_PTR_SENTINEL` piggybacks on it (#18 F16, #08 F12).
- **Fix:** `abstract type IROperand` + `struct SSAOperand`/`struct ConstOperand`/`struct OpaquePtrSentinel`; collapses `_ssa_operands` cascades (`lower.jl:195-261`) to ~20 LOC.
- **Bead:** **propose P2**, 3+1 (core type change).

### U69 Dead legacy phi resolver coexists with live code
- **Severity:** HIGH (phi is THE correctness-risk per CLAUDE.md §47-61)
- **Sites:** `src/lower.jl:972-1060` (`resolve_phi_muxes!`, `has_ancestor`, `on_branch_side`, `_is_on_side` — 90 LOC unreferenced); live dispatcher `lower_phi!` at `:928` dispatches only to `resolve_phi_predicated!` at `:905`.
- **Reviewers:** #12 F3, #13 F14; already flagged in earlier Torvalds review (reviews/05_torvalds_review.md:255).
- **Fix:** Delete the four legacy functions; git retains history. Complete the phi-resolution migration so no future contributor extends the wrong path.
- **Bead:** **propose P2**, pairs with U40.

### U70 WORKLOG drift / bloat
- **Severity:** HIGH
- **Sites:** `WORKLOG.md` (8,193 LOC, 415KB, 85 session logs, no TOC, two NEXT-AGENT headers at `:3` and `:1055`).
- **Reviewers:** #15 F7, #15 F8, #12 F17, #15 F19 (session logs duplicate git log).
- **Fix:** Delete/rename stale NEXT-AGENT at `:1055`. Add auto-generated TOC via `scripts/regenerate_worklog_toc.sh`. Plan year/quarter split beyond 1MB. New session-log template separates `Shipped (refer to git log)` from `Gotchas/Lessons/Rejected alternatives/Next agent starts here`.
- **Bead:** **propose P3**.

### U71 docs/design/ archive sprawl (45 files, ~1.6 MB of proposer docs)
- **Severity:** HIGH
- **Sites:** `docs/design/*_proposer_A.md`, `*_proposer_B.md`.
- **Reviewers:** #02 F19, #15 F6.
- **Fix:** Move proposer docs to `docs/design/archive/`; keep consensus + INDEX.md with one-line summary per consensus doc + bead/commit. Stops stale gate-counts propagating through proposer docs in perpetuity.
- **Bead:** **propose P3**.

### U72 `gpucompiler/` untracked at repo root
- **Severity:** HIGH (hygiene)
- **Sites:** `/home/tobias/Projects/Bennett.jl/gpucompiler/`.
- **Reviewers:** #02 F18, #13 F16, #15 F20.
- **Fix:** Commit + document, add to `.gitignore`, or delete. Also `chmod 700 .beads/` to silence permission warning.
- **Bead:** **propose P3**.

### U73 PRD governance drift
- **Severity:** HIGH
- **Sites:** `Bennett-VISION-PRD.md`, `Bennett-Memory-PRD.md`, `Bennett-Memory-T5-PRD.md`, `docs/prd/*.md`; CLAUDE.md §11.
- **Reviewers:** #02 F4, #02 F16 (§4 vs §9 contradict), #15 F4, #15 F5, #15 F14.
- **Fix:** Either amend CLAUDE.md §11 to allow ship-plus-PRD (documenting why), or enforce. Move `Bennett-Memory-PRD.md` and `Bennett-Memory-T5-PRD.md` to `docs/prd/`. Add `**STATUS: COMPLETED v0.N**` headers to v0.1-0.5 PRDs. Reconcile §4 "100% coverage" vs §9 non-goals.
- **Bead:** **propose P3**.

### U74 BENCHMARKS.md MD5 headline stale; Memory-PRD §6.1 unmet
- **Severity:** HIGH
- **Sites:** `BENCHMARKS.md:120` (MD5 ~48k; target ≤27,520); `:147` MD5 ratio (1.75×) pre-Cuccaro-self-reversing; `:159-166` memory-plan missing T5 / multi-lang.
- **Reviewers:** #02 F3, #15 F18.
- **Fix:** Record pivot to T5 as PRD amendment + WORKLOG entry, or land T4 optimisations to reach target. Re-run MD5; update memory-plan.
- **Bead:** **propose P3**.

### U75 Persistent-map research surface leaks to top-level namespace
- **Severity:** HIGH (subset of U51, but structurally distinct)
- **Sites:** `src/Bennett.jl:36-48`.
- **Reviewers:** #16 F16; overlaps U51, U54.
- **Fix:** Move into `Bennett.Persistent` sub-module; do this alongside U54 EoL decision.
- **Bead:** fold into U51+U54.

---

## Section C — MEDIUM

(Numbered tightly; each is a single-site finding with a concrete fix.)

- **U80** — `ir_extract.jl` ConstantFP/ConstantPointerNull/Poison/Undef in scalar operand position → misleading "unknown operand ref" error. `src/ir_extract.jl:2338`. #10 F15.
- **U81** — void-return non-sret crashes inside `_type_width` with generic message. `src/ir_extract.jl:796, 2373`. #10 F16.
- **U82** — vector-valued returns → misleading "width query" error. `src/ir_extract.jl:2362, 2372`. #10 F17.
- **U83** — `_expand_switches` synthetic labels collide on re-run; `:__unreachable__` is global phantom. `src/ir_extract.jl:1014, 1209-1210`. #10 F18, #10 F19.
- **U84** — phi with 0 incoming / mixed widths not validated. `src/ir_extract.jl:1137`. #10 F20.
- **U85** — `_narrow_inst` fallback silently passes unknown types. `src/Bennett.jl:139-160` (line 160). #06 F17.
- **U86** — `_reset_names!()` empty no-op left after migration. `src/ir_extract.jl:255`. #12 F15.
- **U87** — `LoweringResult` 7-arg / 8-arg compat constructors. `src/lower.jl:36-47`. #12 F6.
- **U88** — `lower_block_insts!` 15 kwargs (missing-struct smell). `src/lower.jl:568-587`. #06 F18.
- **U89** — `src/lower.jl` forward-refs 6 modules included after it (cannot standalone-load). `src/Bennett.jl:11-33`; `src/lower.jl:1140,1458,1935,1941,2260`. #01 F5.
- **U90** — `softfloat/softfloat.jl` and `persistent/persistent.jl` are bare `include` lists, not modules; ~40 helpers leak to `Bennett` top-level. `src/softfloat/softfloat.jl`, `src/persistent/persistent.jl`; CLAUDE.md:107 wrong. #01 F8.
- **U91** — `src/Bennett.jl` is a 297-line junk drawer (3 `reversible_compile` methods, 11 `_narrow_inst`, 37 `register_callee!`, SoftFloat wrapper + 18 op methods). Target ≤ 80 LOC. #01 F9.
- **U92** — `ParsedIR._instructions_cache` + `Base.getproperty` hack (compat for pre-block callers). `src/ir_types.jl:167-221`. #01 F14, #12 F8, #13 F17, #14 F14.
- **U93** — 9 bare `try/catch nothing` in `ir_extract.jl`. `src/ir_extract.jl:335, 338, 343, 491, 957, 1218, 1794, 1980, 1990`. #06 F12, #08 F5.
- **U94** — `_get_deref_bytes` returns 0 for 3 distinct failure modes. `src/ir_extract.jl:2304-2336`. #08 F10.
- **U95** — `_extract_const_globals` bare-catches `LLVM.initializer` (swallows OOM). `src/ir_extract.jl:955-959`. #08 F11.
- **U96** — `OPAQUE_PTR_SENTINEL` compiled through as zero-valued constant; `_fold_constexpr_operand` ptr icmp loses provenance. `src/ir_extract.jl:1760, 1915-1957`. #08 F12, #08 F13.
- **U97** — `lower.jl` error sites lack cc0.6 file prefix; pebbling budget wording inconsistent; reversibility-check error lacks wire indices. `src/lower.jl:164,172,349,680,713-714,728,828,849,1059,1149,1277,1408,1522,1605`; `src/pebbling.jl:163` vs `src/pebbled_groups.jl:174`; `src/diagnostics.jl:158`. #08 F8, #08 F14, #08 F15, #08 F16.
- **U98** — `controlled.jl` assumes contiguous wire allocation (wire-index invariant not asserted). `src/controlled.jl:18-19`. #08 F18, #12 F8.
- **U99** — `ir_types.jl` constructors accept garbage fields; no `op` symbol set / `width ≥ 1` asserts. #08 F17.
- **U100** — `simulate` loses signedness: `UInt8` input returns `Int8`; tuple outputs widened to `Int64`. `src/simulator.jl:57-68`. #16 F8, #16 F9.
- **U101** — `ReversibleCircuit` lacks `Base.length`/`iterate`/`eltype`/`getindex`. `src/gates.jl:31-39`. #18 F12.
- **U102** — NTuple input broken at `reversible_compile` entry. `src/Bennett.jl`. #16 F12.
- **U103** — Multi-lang fixtures silently skip without toolchains; no CI-mode guard. `test/test_t5_corpus_rust.jl:33`, `test_t5_corpus_c.jl:29`, `test_p5b_bc_ingest.jl:18`. #03 F17, #05 F14.
- **U104** — Runtests no outer `@testset`; slow tests mid-list. `test/runtests.jl`. #03 F20, #05 F6.
- **U105** — Simulator scalar bit-at-a-time (180 µs/input for soft_fadd × 100 runs = wait). No `simulate!(buffer, ...)` variant. `src/simulator.jl`. #13 F5, #17 F11.
- **U106** — `register_callee!` registry 40+ entries unstructured. `src/Bennett.jl:163-208`. #02 F11.
- **U107** — No compile-time benchmarks / `benchmark/regression_check.jl`. #17 F13, #17 F17.
- **U108** — `_gate_controls` allocates `Vector{Int}` per call on hot paths (depth/peak_live/extract_dep_dag/liveness/pebbling). `src/dep_dag.jl:90-96`. #18 F11.
- **U109** — No `sizehint!` in `lower.jl`, `ir_extract.jl`, `adder.jl`, `multiplier.jl` (142+69 push! sites, 0 hints). #17 F8.
- **U110** — `_compute_block_pred!` OR-folds without mutual-exclusion assertion; `_edge_predicate!` no width-1 assert on `block_pred`. `src/lower.jl:876-893`, around `:849`. #07 F9, #07 F10.
- **U111** — Raw `shl`/`lshr`/`ashr` with shift ≥ width mis-shift; width-64 mask relies on Julia shift-saturation. `src/lower.jl:1208,1224,1240`, `:176`. #04 F15, #04 F16.
- **U112** — `_cond_negate_inplace!` leaks per-bit carry ancillae. `src/lower.jl:1496-1513`. #04 F14.
- **U113** — `_pick_alloca_strategy` case-match explosion / shape set hardcoded twice. `src/lower.jl:2084-2107`, `:2530`. #02 F10, #06 F19.
- **U114** — `_convert_instruction` result-type filter returns `nothing`, silent drop for stores; violates fail-loud. `src/ir_extract.jl:1508,1548,1561,1705,1706,1720`. #08 F6.
- **U115** — `_detect_sret` returns ad-hoc `NamedTuple`; `_collect_sret_writes` is 173-line special-case soup. `src/ir_extract.jl:412-416, 467-640`. #18 F14, #06 F10.
- **U116** — `ir_extract.jl` 2,394 LOC / repeated bugs pattern. #14 F17.
- **U117** — `softfloat` MD5 / `soft_fma` (447,728 gates) compiled but not in BENCHMARKS.md. #17 F12; also #02 F17 (soft_fma 2× over v0.5-PRD estimate).
- **U118** — `triple-redundant integer division` (`lower_binop` vs soft_udiv vs unregistered callee silent skip). `src/lower.jl:1422`, `src/ir_extract.jl:1508`. #06 F14.
- **U119** — `typemin ÷ -1` silently wraps; `x ÷ 0` returns impl-defined garbage. `src/divider.jl:8-35`. #04 F6, #04 F7, #07 F4.
- **U120** — `linear_scan_pmap_get` collides absent-key with stored-zero. `src/persistent/linear_scan.jl:80, 98`. #04 F12.
- **U121** — Persistent-DS harness gaps: no persistent-update invariant test (pmap_set old vs new); never tests key=0. `src/persistent/harness.jl:43-87, 38`. #19 F6, #19 F7.
- **U122** — `cf_pmap_set` silently overwrites past max_n. `src/persistent/cf_semi_persistent.jl:199-201,209-211,252-258`. #19 F8.
- **U123** — HAMT single-level only; popcount 2,782 gates alone makes "log32 N" asymptotic never materialise. `src/persistent/hamt.jl:17-31`. #19 F10. Moot under U54.
- **U124** — popcount gate baseline not regression-anchored. `docs/memory/persistent_ds_scaling.md:140-147`. #19 F15.
- **U125** — Hashcons test seed protects latent collision bug (oracle shares compile bug). `test/test_persistent_hashcons.jl:20, 119-125`. #19 F17.
- **U126** — Okasaki delete deferred, Kahrs 2001 never implemented. `src/persistent/okasaki_rbt.jl:39-45`. #19 F9. Moot under U54 (Bennett-cc0.1 moot).
- **U127** — `_fold_constants` mixes three concerns via shared `known` dict; 93-line pass off-by-default without benchmarks. `src/lower.jl:473-566`. #12 F10, #13 F8.
- **U128** — `resolve!` silently discards `width` arg on SSA path (no length assert). `src/lower.jl:168-186`. #12 F5.
- **U129** — `@assert` vs `error()` skew: 2 vs 121; invariant checks with string-format in hotpath (`emit_shadow_store_guarded!`). `src/shadow_memory.jl:101-103`. #13 F7.
- **U130** — `IRCall` `arg_widths` invariant not checked in constructor; `lower_divrem!` hardcodes 64-bit widening that bypasses `_assert_arg_widths_match`. `src/lower.jl:1427-1438, 1934-1936`. #13 F9.
- **U131** — No debuggability tooling (--dump-ir, --dump-gates, verbose, `diagnose_nonzero`). `src/simulator.jl:32`. #13 F11.
- **U132** — Only 4 of 14 LLVM fcmp predicates implemented (missing ogt/oge/one/ord/uno/ueq/ult/ule/ugt/uge). `src/softfloat/fcmp.jl`. #11 F7.
- **U133** — `_sf_handle_subnormal` flush-to-zero boundary may drop round-up case. `src/softfloat/softfloat_common.jl:100-118`. #11 F8.
- **U134** — `soft_exp` off-by-1-ULP ~0.9% vs `Base.exp`; `soft_exp_julia` is bit-exact. Rename or retire. `src/softfloat/fexp.jl:358-418`. #11 F6.
- **U135** — `_sf_normalize_to_bit52` pathological on m=0, caller-trusted. `src/softfloat/softfloat_common.jl:14-31`. #11 F13.
- **U136** — `soft_round` (roundToIntegralTiesToEven) not implemented. #11 F9.
- **U137** — Float32 native arithmetic absent; fpext→f64→fptrunc double-rounds. #11 F10.
- **U138** — `soft_fdiv` dead `_overflow_result` binding; `soft_floor`/`soft_ceil` NaN propagation untested. `src/softfloat/fdiv.jl:82-87`. #11 F12, #07 F12.
- **U139** — Zero-ancilla in-place ops (Cuccaro `b+=a`, trunc high bits) dirty-bit hygiene documented only implicitly. `src/lower.jl` lower_cast trunc branch. #07 F8.
- **U140** — `lower_add_cuccaro!` docstring advertises `2n Toffoli, 5n CNOT, 2n negations`; reality `2W−2 Toffoli, 4W CNOT, 0 NOT`. `src/adder.jl:25-62`. #07 F6, #07 F7, #14 F1, #14 F2.
- **U141** — Missing WHY comments at load-bearing invariants (QCLA depth formula unasserted; HAMT is_occupied+is_new=1 disjoint-one-hot; Okasaki RB post-insert invariant; parallel-adder A3 reverse-uncompute proof; popcount cost). `src/qcla.jl:17`, `src/persistent/hamt.jl`, `src/persistent/okasaki_rbt.jl:269-273`, `src/parallel_adder_tree.jl:24-38, 98-108`, `src/persistent/popcount.jl`. #14 F3, #14 F5, #14 F6, #14 F9, #14 F10, #14 F11.
- **U142** — Missing citations: Bennett 1973 in `bennett_transform.jl`; Meuli 2019 + Sinz 2005 in `sat_pebbling.jl`. #14 F7, #14 F12.
- **U143** — `pebbling.jl` uses `typemax(Int)÷2` sentinel. `src/pebbling.jl:37`. #14 F18.
- **U144** — `soft_fdiv` correctness deferred to WORKLOG, not self-contained. `src/softfloat/soft_fdiv.jl:53-62`. #14 F19.
- **U145** — No `@example`/`julia>` doctests anywhere. #14 F20.
- **U146** — Bennett integration test for stated vision (`controlled ∘ reversible_compile` end-to-end through small statevector sim) absent. #02 F15.
- **U147** — No hand-built `ParsedIR → lower` seam test (bypasses LLVM). #05 F12.
- **U148** — `tabulate.jl` (202 LOC) not scoped by any PRD; uses `Vector{Any}` in hot path. #02 F13, #18 F13.
- **U149** — `sat_pebbling.jl` (197 LOC) unwired with PicoSAT dep; Bennett-fg2 P2 exists. #02 F12.
- **U150** — Regression baselines block default-strategy evolution (CLAUDE.md §6 vs research-arena framing). #02 F14.
- **U151** — soft_fma ~447k gates ≈ 2× v0.5-PRD §9 estimate. #02 F17.
- **U152** — CLAUDE.md two "Session Completion" sections contradict. `CLAUDE.md:~119, ~170`. #02 F20, #15 F13.
- **U153** — README Project-status 2 weeks stale (does not mention T5-P6 frontier). `README.md:270`. #15 F11.
- **U154** — README test-suite time claim stale (90s → 4m06s). #13 F15.
- **U155** — No "start here" path for human contributor; no `Contributing` section. #15 F12.
- **U156** — docs/memory/ investigation docs don't indicate shipped implementations. `docs/memory/memssa_investigation.md:4`. #15 F17.
- **U157** — Docstrings missing on exported `simulate/gate_count/ancilla_count/depth/print_circuit/verify_reversibility/ControlledCircuit`; 9 total. `src/simulator.jl:5,10`, `src/diagnostics.jl:1-36`, `src/controlled.jl`. #15 F9, #16 F18, #16 F19.
- **U158** — docs/ Documenter-shaped but `docs/make.jl` absent. #15 F10, #18 F15; Bennett-5ec already open.
- **U159** — Test layout does not mirror src; no per-file unit tests (`test_bennett.jl`, `test_lower.jl`, etc). #01 F11.
- **U160** — Five pebbling/eager files with inconsistent naming. #01 F12.
- **U161** — Three `reversible_compile` methods with divergent kwarg surfaces (see U29); unify with `CompileOptions` struct (#06 F5, #12 F12).
- **U162** — HAMT slot 0..7 logic copy-pasted 16× (keys + values); one slot (nk0_ins) drops an else-branch others have → possible latent bug masked by boilerplate. `src/persistent/hamt.jl:118-241`. #18 F10. Moot under U54.
- **U163** — 200+ LOC manual 128-bit arithmetic to avoid `__udivti3`/`__umodti3`; teach `ir_extract` to register them, use native `UInt128`. `src/softfloat/softfloat_common.jl:156-375`. #12 F14.
- **U164** — `_remap_gate` defined twice with different semantics (offset vs wiremap); `lower_load!` defined twice. `src/lower.jl:1992, 1646, 1799`; `src/pebbled_groups.jl:19`. #01 F18, #01 F20.
- **U165** — `ReversibleCircuit` `peak_live_wires` not in `show`; `peak_live_wires` only in 2 benchmark files despite being quantum-relevant scalar. #17 F19.

---

## Section D — LOW / NIT

### Hygiene / messages
- **U200** `bennett_transform.jl` defensive `copy(lr.gates)` allocates wastefully. `src/bennett_transform.jl:25-28`. #01 F19.
- **U201** Gate-type accessor duplication: `_gate_target`/`_gate_controls` live in `dep_dag.jl` but consumed by diagnostics/eager. `src/dep_dag.jl:90-96`. #01 F7.
- **U202** `simulator.jl` error "Bennett construction bug" misleads when constructor is `value_eager_bennett`. `src/simulator.jl:31`. #09 F17.
- **U203** `self_reversing` branch lacks "UNCHECKED" inline comment. `src/bennett_transform.jl:27-30`. #09 F18.
- **U204** QCLA `n_anc` guard `W >= 4` unexplained. `src/qcla.jl:43`. #14 F4.
- **U205** `ir_parser.jl` parse errors surface as `Base.InvalidValue`. `src/ir_parser.jl:125`. #08 F20.
- **U206** `extract_parsed_ir` uses `Union{Nothing, Vector{String}}` default. #18 F18.
- **U207** `hashcons_jenkins.jl` header says "24 mix ops", body "18". `src/persistent/hashcons_jenkins.jl:5, 57-81`. #19 F16. Moot under U54.

### Infra gaps
- **U210** No `Aqua.jl` / `JET.jl` in test. #18 F19.
- **U211** Benchmarks not using BenchmarkTools/PkgBenchmark. #18 F20.
- **U212** `benchmark/sweep_persistent_impls_gen.jl` 17,815 auto-generated LOC checked in. #17 F20, #19 F19.
- **U213** `persistent/persistent.jl` include order confusing (harness before popcount; popcount before hamt). #19 F18.
- **U214** dolt-cache commits pollute git log (~half of last 60 commits). #12 F16.
- **U215** WORKLOG duplicates git-log summaries; session-log template lacks structure. #15 F19.
- **U216** Test `test_parse.jl` tests legacy regex parser path (CLAUDE.md §5 tension). #05 F20. Moot under U42.
- **U217** `liveness × :auto` add dispatcher combination untested; loop tests Int8-only. #05 F18, #05 F19.
- **U218** README has no `Extending Bennett.jl` guide. #15 F16.

### Softfloat NITs
- **U220** `soft_exp_fast` / `soft_exp2_fast` FTZ documented only implicitly. #11 F11.
- **U221** Gate-count baseline bump expected after U06 fix. #11 F15.
- **U222** NaN tests/ancilla/cross-op coverage already covered by U60+U61+U65.

---

## Section E — Cross-cutting themes & recommended sequencing

### Themes (dedup signal)

| Theme | Unified IDs | Reviewer support |
|---|---|---|
| verify_reversibility tautology + cascade | U01 → U02, U03, U04, U23, U58, U80 | #03, #05, #09, #13, #16 |
| `lower.jl` god-file / architectural debt | U40, U43, U44, U69, U87, U89, U91 | #01, #06, #12, #13, #14 |
| `ir_extract.jl` silent-corruption bugs | U09-U18, U80-U84, U114 | #04, #08, #10 |
| Soft-float correctness gaps | U06, U07, U08, U31, U60, U61, U132-U138 | #04, #07, #11 |
| Persistent-DS end-of-life | U20, U21, U22, U54, U75, U120-U126, U162, U207 | #02, #14, #19 |
| Error-handling / fail-loud discipline | U18, U45, U46, U93-U97, U114 | #06, #08 |
| Test coverage hygiene | U23, U46, U47, U60, U63, U65, U103, U104, U146, U147 | #03, #05, #09 |
| Export/docs drift | U42, U51, U53, U70, U71, U75, U90, U91, U102, U157, U158 | #01, #06, #15, #16, #18 |
| Dispatch / strategy pessimisation | U27, U28, U30, U57, U64, U150 | #04, #17 |
| Type instability / perf | U43, U47, U48, U52, U105, U108, U109 | #13, #17, #18 |
| Project.toml / CI / release-readiness | U49, U50, U52, U81 | #13, #16, #17, #18 |

### Recommended sequencing (for the NEXT AGENT)

**Phase 0 — load-bearing invariant fix (must land first, blocks trust in everything else):**
1. **U01** — fix `verify_reversibility` (one function, ~20 LOC). P0.
2. **U49** — add CI workflow so U01's new coverage is enforced. P1.

**Phase 1 — exposing correctness debt:**
3. **U02** — `value_eager_bennett` branching fallback (refuse path). Small fix, huge safety win.
4. **U03** — `self_reversing=true` runtime assertion.
5. **U04** — `checkpoint_bennett`/`pebbled_group_bennett` branching guard.
6. **U06** — `soft_fmul` subnormal pre-norm (2-line + test; small, high-value).
7. **U19** — `simulate` arity check (trivial; surfaced during test hygiene).
8. **U25** — `reversible_compile` type/bit_width validation.
9. **U05** — `lower_loop!` body-block dispatch through `_lower_inst!`. Medium — needs test matrix.

**Phase 2 — ir_extract silent-corruption sweep (single 3+1 epic, ≈10 findings):**
10. **U09-U13** — the 5 CRITICAL ir_extract bugs (i128, extractvalue/Struct, switch phi, GEP offset, IRVarGEP elem_width).
11. **U14-U17, U18** — atomic/volatile, inline-asm/unregistered, multi-idx GEP, deref regex, catch narrowing.

**Phase 3 — soft-float bit-exactness rebase:**
12. **U07** — `soft_fpext` sNaN quieting.
13. **U08** — NaN payload/sign preservation across all ops + trunc/floor/ceil.
14. **U60 + U61** — bit-pattern tests replacing `isnan()`; raw-bits sweeps including subnormals.
15. **U31, U62** — fptoui + fpext/fptrunc missing.
16. **U132** — remaining fcmp predicates.

**Phase 4 — persistent-DS EoL + T5-P6 landing:**
17. **U54** — accept EoL recommendation; delete CF/Okasaki/HAMT/popcount/Jenkins; update Bennett-cc0.1 / cc0.2 to closed-as-wontfix. Subsumes U20-U22, U120-U126, U162, U207.
18. **Bennett-z2dj** (T5-P6) — now unblocked by U54 simplification + U01 trust. Use linear_scan default per 2026-04-20 sweep.

**Phase 5 — architectural refactor (requires 3+1 per CLAUDE.md §2):**
19. **U43, U44, U69** — LoweringCtx concretise + delete legacy phi resolver.
20. **U68** — IROperand abstract-type refactor.
21. **U40, U41, U42** — split `lower.jl` / `_convert_instruction` dispatch tables / delete `ir_parser.jl`.
22. **U55** — collapse 5 `*_bennett` variants into `BennettStrategy`.

**Phase 6 — dispatcher + perf:**
23. **U27, U28, U30, U57, U64** — dispatcher fix + fold_constants default + peepholes.
24. **U47, U48, U52, U105** — type instability + caching + precompile + simulate!.

**Phase 7 — polish:**
25. **U45, U46** — error-monoculture codemod + test coverage.
26. **U49 (done), U50, U51** — Project.toml bump, exports cleanup (after U54 submodule move).
27. **U53, U54 continuation, U70, U71, U72, U73** — docs / worklog / PRD governance.

### Recommended bead filing

**P0 (do first):**
- U01 — fix `verify_reversibility` (propose new)
- U06 — `soft_fmul` subnormal (propose new)
- U02 — `value_eager_bennett` fallback (propose new)
- U03 — `self_reversing` validation (propose new)

**P1:**
- U04, U05, U07, U08, U09, U10, U11, U12, U13, U18, U19, U25, U49 — propose each
- U23 — test audit (depends on U01)

**P2:**
- U14-U17 (ir_extract robustness)
- U27-U30 (dispatcher)
- U40, U41, U43, U55, U68 (refactor — 3+1 each)
- U47, U48, U52, U57, U58, U59, U66, U67
- U50, U51, U54 (EoL), U64
- U65 (test hygiene epic)
- Bennett-fnxg expansion (U61)

**P3:**
- U22, U26, U42, U45, U46, U53, U56, U63, U69 (phi migration), U70-U74 (docs/worklog)
- U132-U138 (soft-float completeness)
- Medium-section findings (U80-U165)

**Close / fold / wontfix:**
- Bennett-0s0 (Sturm) — close as wontfix per CLAUDE.md NEXT-AGENT-header note.
- Bennett-cc0.1 (Okasaki delete) — moot under U54 option A.
- Bennett-cc0.2 (HAMT insert/delete) — moot under U54 option A.
- Bennett-i3nj (Rust cross-context parser) — stays blocked on z2dj.

---

## Appendix — per-review extraction map

| # | Slug | Findings returned | Headline claims |
|---|---|---:|---|
| 01 | structure_callgraph | 20 | lower.jl 2,662 LOC; _convert_instruction 649 LOC; bennett.jl name drift; ir_parser dead |
| 02 | vision_scope | 20 | two competing north-stars; no authoritative STATUS.md; MD5 target missed silently; T5 corpus RED; advanced-arith + T5 PRDs post-hoc |
| 03 | test_coverage | 20 | verify_reversibility tautology; 5 files no ancilla check; depth untested; 81 errors in lower.jl, 6 tested |
| 04 | edge_cases | 20 | lower_loop drops body insts; NaN payload erased; soft_feistel not bijective; `typemin ÷ -1` wraps; `x ÷ 0` garbage |
| 05 | integration_tests | 20 | verify_reversibility tautology; no CI; no compose API; T5 corpus mostly @test_throws; use_memory_ssa untested |
| 06 | antipatterns | 20 | _convert_instruction god fn; ir_parser dead; strategy ladders duplicated; MUX hand+@eval dup; kwarg explosion |
| 07 | arithmetic_bugs | 13 | soft_fmul subnormal; fptosi no saturation; soft_u/u}div silent on 0; Cuccaro docstring wrong |
| 08 | error_handling | 20 | cc0.3 catch regex swallow; WireAllocator(-1) silent; reversible_compile no validation; error monoculture; bare try/catch |
| 09 | reversibility_invariants | 19 | verify_reversibility tautology; value_eager 100% fail; self_reversing trust; pebbled/checkpoint crash on branching |
| 10 | llvm_ir_robustness | 20 | 5 CRITICALs: i128, extractvalue/Struct, switch phi, GEP offset, IRVarGEP elem_width + 5 more HIGH drops |
| 11 | softfloat | 17 | soft_fmul subnormal; fpext sNaN; NaN payload canonicalised; soft_fptosi; missing fcmp preds |
| 12 | torvalds | 17 | lower.jl split; dead legacy phi resolver; LoweringCtx Any; MUX dup; ir_parser dead |
| 13 | carmack | 17 | callee re-extraction; TTFX 10s; LoweringCtx drift; lower_loop drops insts; scalar simulator; no CI |
| 14 | knuth | 20 | Cuccaro docstring wrong; QCLA depth unasserted; parallel-adder proof missing; HAMT/Okasaki invariants unstated |
| 15 | docs_worklog | 20 | CLAUDE.md baselines stale; bennett.jl rename; two NEXT-AGENT headers; docs/design 45 files no index |
| 16 | api_surface | 20 | simulate no arity; NOTGate not exported; Project.toml 0.4.0/1.6; reversible_compile kwargs divergent |
| 17 | performance | 20 | :auto add worse than :ripple; :auto mul never qcla_tree; fold_constants default off; LoweringCtx::Any |
| 18 | julia_idioms | 20 | IROperand tagged union; LoweringCtx::Any; ErrorException monoculture; Manifest commit+gitignore |
| 19 | persistent_memory | 20 | hamt 9th-key drop; cf_reroot key=0; feistel not bijective; EoL recommendation: delete 1500 LOC |

**Total raw findings extracted:** ~367. **Unified issues after dedup:** 165 actionable (U01-U165, U200-U222). Headline CRITICAL count: 32. HIGH: 36. MEDIUM: 80+. LOW/NIT: ~20.

---

*Catalogue produced 2026-04-22 by orchestrator + 19 parallel extraction subagents. Source reports at `reviews/2026-04-21/01-19_*.md` remain authoritative for full prose; this file is the triage index.*
