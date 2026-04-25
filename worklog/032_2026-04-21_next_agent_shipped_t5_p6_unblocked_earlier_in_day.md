## NEXT AGENT — 2026-04-21 (α+β+γ shipped; T5-P6 unblocked) — earlier in day

**This session shipped three infrastructure bugs that collectively unblock
Bennett-z2dj (T5-P6 `:persistent_tree` dispatcher arm). Next work: implement
T5-P6 proper.**

### Read these, in this order (~30 minutes)

1. **`CLAUDE.md`** — 13 principles, especially §1 (fail fast), §2 (3+1 for core),
   §3 (red-green TDD), §6 (gate counts are baselines), §7 (bugs are interlocked).
2. **`Bennett-Memory-T5-PRD.md`** — T5 vision, §6 success criteria, §11 risks.
3. **`docs/design/p6_consensus.md`** — the T5-P6 design. §2 research step is
   now RESOLVED (was blocked, now GREEN). §5 has the 13-step implementation
   plan — the starting point for next session.
4. **`src/lower.jl:1996-2042`** — current `_pick_alloca_strategy` body (the
   dispatcher). §2 of p6_consensus describes where the new arm plugs in.
5. **`src/persistent/linear_scan.jl`** — the winning impl per the 2026-04-20
   sweep. `_LS_MAX_N = 4`, state is `NTuple{9,UInt64}`. Branchless.
6. **`test/test_0c8o_vector_sret.jl:61-88`** — confirms
   `reversible_compile(f, NTuple{9,UInt64}, Int8, Int8)` works end-to-end post-β.
   Use this as the gate-count baseline sanity check for T5-P6.

### Concrete state of the world

**What works now that didn't before:**

```julia
# This used to hard-error. Now produces a valid reversible circuit.
using Bennett
f(s::NTuple{9,UInt64}, k::Int8, v::Int8) = Bennett.linear_scan_pmap_set(s, k, v)
c = reversible_compile(f, NTuple{9,UInt64}, Int8, Int8)
@assert verify_reversibility(c)
@assert c.input_widths == [576, 8, 8]
@assert c.output_elem_widths == fill(64, 9)
# Standalone-call gate count: ~22,494. Much higher than inlined _ls_demo (436).
```

**What still doesn't work (the T5-P6 scope):**

- `reversible_compile(f, Int8)` where `f` uses `Vector{Int8}() + push!` — blocked
  by `jl_array_push`-style LLVMGlobalAliasValueKind in `ir_extract`. Separate
  bead; out of T5-P6 scope.
- `Array{Int8}(undef, N)` dynamic-idx — blocked by `thread_ptr` GEP. cc0.5
  territory; out of T5-P6 scope.
- Hand-crafted `.ll` with `alloca i8, i32 %n` + store + load → **the T5-P6
  target**. Currently fails at `lower_alloca!` which rejects dynamic n_elems.

### Start here: implement T5-P6 (Bennett-z2dj)

**Bead status**: claimed by tobias. Unblocked as of 2026-04-21.

**Exact first move** — write the RED test per `docs/design/p6_consensus.md` §4.
The test exercises hand-crafted LLVM IR with a dynamic `alloca`:

```llvm
define i8 @julia_p6_roundtrip(i8 %n, i8 %k1, i8 %v1, ...) {
top:
  %nz = zext i8 %n to i32
  %p  = alloca i8, i32 %nz           ; ← dynamic n_elems — current fail site
  %k1z = zext i8 %k1 to i32
  %g1 = getelementptr i8, ptr %p, i32 %k1z
  store i8 %v1, ptr %g1
  ...
}
```

Put this in `test/test_t5_p6_persistent_dispatch.jl`. Use the `_compile_ir`
harness pattern from `test/test_universal_dispatch.jl:16-26`. Add
`include(...)` to `test/runtests.jl`. Confirm RED before any source change.

**Then follow `p6_consensus.md` §5** verbatim. Step list (paraphrased):

1. RED test as above.
2. Extend `LoweringCtx` with 3 Symbol fields (`mem`, `persistent_impl`,
   `hashcons`) + `persistent_info::Dict{Symbol, PersistentMapImpl}`. Backward-
   compat constructors default them.
3. Add `_pick_alloca_strategy_dynamic_n(ctx, inst)` sibling in `src/lower.jl`
   (DO NOT modify the existing `_pick_alloca_strategy` signature — see
   p6_consensus §1 and the M3a precedent).
4. Extend `lower_alloca!` with a dynamic-n branch that calls `pmap_new()` and
   records `persistent_info[inst.dest] = impl`.
5. Add `_lower_store_via_persistent!` + `_lower_load_via_persistent!` emitting
   `IRCall` to `linear_scan_pmap_set` / `linear_scan_pmap_get`.
6. Wire dispatcher early-out in `_lower_store_single_origin!` (at
   `src/lower.jl:2098`) and `_lower_load_via_mux!` (at `src/lower.jl:1701`).
7. `register_callee!(linear_scan_pmap_new/set/get)` in
   `src/Bennett.jl` (after line 209). `:okasaki/:hamt/:cf` stay unregistered
   in MVP — return NYI error from the dispatcher.
8. Early-return in `lower_ptr_offset!` / `lower_var_gep!` for persistent base.
9. `reversible_compile` kwargs: `mem=:auto`, `persistent_impl=:linear_scan`,
   `hashcons=:none`. Thread through to `lower(..., mem=...)`.
10. Add `validate_persistent_config` that pre-checks registrations.
11. SoftFloat wrapper threading (Bennett.jl:268-295).
12. Full `Pkg.test()` — every baseline below must stay byte-identical.
13. WORKLOG + close Bennett-z2dj + push.

**Expected size**: ~250 LOC in `src/lower.jl`, ~30 LOC in `src/Bennett.jl`,
~300 LOC new test file. Single atomic commit.

### Key invariants for T5-P6

- **Default `mem=:auto` must preserve byte-identical output** for every
  existing test. `mem=:persistent` is a PERMISSION for dynamic-n allocas, not
  a FORCING — const-n allocas still route through shadow/MUX/checkpoint.
- **Non-entry-block persistent stores MUST fail loud in MVP** (false-path
  sensitization risk). Diamond-CFG RED test should `@test_throws`.
- **Multi-origin ptr × persistent fails loud** too. Single-origin only in MVP.
- **`linear_scan` only in MVP**. `:okasaki/:hamt/:cf` and `hashcons=:naive/:feistel`
  get crisp NYI errors.

### Baselines that must stay byte-identical (run post-T5-P6)

```julia
julia --project -e '
using Bennett
@assert gate_count(reversible_compile(x -> x + Int8(1), Int8)).total == 100
@assert gate_count(reversible_compile(x -> x + Int8(1), Int8)).Toffoli == 28
@assert gate_count(reversible_compile(x -> x + Int16(1), Int16)).total == 204
@assert gate_count(reversible_compile(x -> x + Int32(1), Int32)).total == 412
@assert gate_count(reversible_compile(x -> x + Int64(1), Int64)).total == 828
println("arithmetic OK")
'
# Run test_persistent_interface.jl — _ls_demo = 436 total / 90 Toffoli
# Run test_persistent_cf.jl — CF demo = 11,078
# Run test_persistent_hashcons.jl — CF+Feistel = 65,198
# Run test_persistent_hamt.jl — HAMT demo = 96,788
# Run test_t5_corpus_julia.jl — TJ3 = 180
```

### Follow-up beads filed during this session

| Bead | Title | Priority | Status |
|---|---|---|---|
| **Bennett-atf4** (α) | `lower_call!` method-table arg types | P1 | ✓ closed |
| **Bennett-0c8o** (β) | vector-lane sret stores + vector loads | P1 | ✓ closed |
| **Bennett-uyf9** (γ) | auto-SROA for memcpy sret | P1 | ✓ closed |
| **Bennett-i3nj** | Rust cross-context LLVM parser | P3 | open (blocked on z2dj) |

### Known limitations to document in T5-P6 WORKLOG entry

1. **NTuple-input simulate gap** — `Bennett.simulate(c, (state::NTuple{9,UInt64}, ...))`
   can't pass 576-bit state through the `Tuple{Vararg{Integer}}` API (max 64
   bits per arg). The T5-P6 end-to-end test uses a scalar-input variant to
   validate semantics. Real fix: simulator accepts a `Vector{Bool}` or BigInt
   for wide inputs. File as a follow-up bead when T5-P6 ships.
2. **Standalone-call gate cost is high** — `f(s::NTuple{9,UInt64}, k, v) =
   pmap_set(s, k, v)` compiles to ~22,494 gates. That's the per-op cost for
   T5-P6; measure during T5-P7 Pareto-front work, don't target a budget here.

---

