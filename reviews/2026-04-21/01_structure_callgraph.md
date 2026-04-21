# Bennett.jl — Structure, Module Boundaries, Call-Graph Review
**Reviewer jurisdiction:** structure, module boundaries, dependency order, call-graph hotspots, layering, legacy cruft, naming, test layout
**Date:** 2026-04-21
**Scope:** `src/` (~13,300 LOC, 30 top-level files + `softfloat/` + `persistent/`), `test/` (~11,300 LOC, ~110 files), `README.md`, `CLAUDE.md`, `docs/src/architecture.md`.

---

## Executive summary

The pipeline shape (`extract → lower → bennett → simulate`) is sound and the core data types (`ParsedIR`, `LoweringResult`, `ReversibleCircuit`) are well-chosen. But the project is showing unmistakable signs of organic accretion without a corresponding re-organisation pass. The headlines:

1. **`src/lower.jl` is 2,662 lines and 93 top-level definitions in a single flat file.** It is the single biggest file in the repo and is structurally indistinguishable from a junk drawer.
2. **`src/ir_extract.jl` is 2,394 lines with `_convert_instruction` spanning lines 1086–1734 (~650 lines in one function).** That is the textbook definition of a god function.
3. **`src/Bennett.jl` is 297 lines and doing real work** — Float64 dispatch, IR narrowing, `_narrow_inst` dispatch table, 37 `register_callee!` calls, three distinct `reversible_compile` methods. The module file is acting as a feature-file rather than a façade.
4. **The file `bennett.jl` does not exist** — it is `bennett_transform.jl`. `CLAUDE.md` (line 91), `docs/src/architecture.md` (lines 78, 114, 126), and the VISION/PRD docs all reference a `bennett.jl` that was apparently renamed without updating the documentation. This is actively misleading for new agents.
5. **`ir_parser.jl` (168 lines) is still `include`d, still exported (`parse_ir`), but only used by `test_parse.jl` and `test_branch.jl`/`test_loop.jl` for a diagnostic printout.** CLAUDE.md says "legacy regex parser (backward compat)". It is dead code dragged along the critical path.
6. **Forward-reference hell in `src/Bennett.jl` include order.** `lower.jl` is included before `qrom.jl`, `shadow_memory.jl`, `divider.jl`, `mul_qcla_tree.jl`, `softfloat/`, yet calls into all of them (`emit_qrom!`, `emit_shadow_store!`, `soft_udiv`, `lower_mul_qcla_tree!`). Julia's late binding tolerates it, but the dependency graph is backward.
7. **Five pebbling/Bennett-variant files (`bennett_transform.jl`, `pebbling.jl`, `eager.jl`, `value_eager.jl`, `pebbled_groups.jl`, `sat_pebbling.jl`) plus `dep_dag.jl` all do variations on the same theme.** They collectively re-implement the "given `LoweringResult`, produce `ReversibleCircuit` with some cleanup strategy" operation with zero shared abstraction. The `_build_circuit` helper (`bennett_transform.jl:9`) is shared, but every other piece is copy-pasted.
8. **`_gate_target` / `_gate_controls` are defined in `dep_dag.jl` but used from `diagnostics.jl` and `eager.jl`.** These belong on `gates.jl` (nearest-conceptual-home). The current situation gives a semantic import: "to compute `peak_live_wires`, I first need the dependency-DAG module."
9. **Two different `_remap_gate` functions with different semantics** — one in `lower.jl:1992` (wire-offset remapping for inlined callees) and one in `pebbled_groups.jl:19` (wire-map remapping for pebble replay). Julia's multiple dispatch hides the collision (different arities) but a reader hits one definition and assumes it's the canonical one.
10. **Test layout does not mirror source layout.** 110 test files are organised by feature (opcode, scenario, bug ticket) not by src file. `bennett_transform.jl`, `simulator.jl`, `gates.jl`, `ir_types.jl`, `ir_extract.jl`, `lower.jl`, `diagnostics.jl` have NO direct unit-level tests — only integration coverage. There is no `test_bennett.jl` proper.
11. **There is test-suite archaeology: bug-ID-keyed test files** (`test_0c8o_vector_sret.jl`, `test_atf4_lower_call_nontrivial_args.jl`, `test_cc04_repro.jl`, `test_cc06_error_context.jl`, `test_cc07_repro.jl`, `test_uyf9_memcpy_sret.jl`, `test_p5a_*`, `test_p5b_*`, `test_p5_fail_loud.jl`). These are regression tests named for bd issues — fine to keep but unclear they exercise a useful partition of behaviour.
12. **The `src/softfloat/softfloat.jl` file is a plain `include`-list, not a module.** CLAUDE.md describes it as "module definition". There is no `module SoftFloat … end`. All soft-float functions live at the top-level `Bennett` module namespace.
13. **`src/persistent/persistent.jl` is also an include-list, not a module.** The persistent-map impls' exported surface area is enormous (~15 exports in `Bennett.jl` lines 38–43), bleeding into the top-level namespace alongside compiler primitives.
14. **`lower_call!` calls `extract_parsed_ir` which creates an embedded `ir_extract → lower → bennett` recursion from inside the compiler.** This is probably correct (gate-level inlining), but it means the "pipeline" is not linear: it's a tree, and the failure modes multiply accordingly. No obvious cache of `extract_parsed_ir` results keyed on `(f, arg_types)`, so a callee used N times is re-extracted N times.
15. **`unused import`/leak: LLVM.jl leaks beyond `ir_extract.jl`.** `memssa.jl` has `using LLVM` via a `LLVM.Context()` / `LLVM.add!` block. Fine within the IR-front-end layer, but should be grouped with the rest of IR extraction, not sitting alone next to `feistel.jl`.

Details and prioritized findings follow.

---

## Findings by severity

### CRITICAL

None. Nothing in this jurisdiction is merge-blocking or a correctness risk. The structural problems are maintainability and velocity risks, not correctness risks.

---

### HIGH

#### H1 — `src/lower.jl` (2,662 lines) is architecturally over-loaded.
**Evidence.** `src/lower.jl` has 93 top-level definitions and mixes at least seven distinct concerns:
- Data types (`GateGroup`, `LoweringResult`, `LoweringCtx` + four legacy constructors)
- Top-level lowering orchestration (`lower`, `_fold_constants`, `lower_block_insts!`, `lower_loop!`)
- Per-opcode lowering (`lower_binop!`, `lower_icmp!`, `lower_select!`, `lower_cast!`, `lower_phi!`, `lower_extractvalue!`, `lower_insertvalue!`, `lower_call!`)
- Primitive gate emission (`lower_and!`, `lower_or!`, `lower_xor!`, `lower_shl!`, `lower_lshr!`, `lower_ashr!`, `lower_var_lshr!`, `lower_var_shl!`, `lower_var_ashr!`, `lower_eq!`, `lower_ult!`, `lower_slt!`, `lower_not1!`, `lower_mux!`)
- Division as a wrapped soft-call (`lower_divrem!`, `_cond_negate_inplace!`)
- Pointer/memory lowering with its own 600-line sub-subsystem (`lower_ptr_offset!`, `lower_var_gep!`, `lower_load!` (×2), `lower_alloca!`, `lower_store!`, `_lower_store_single_origin!`, `_emit_store_via_shadow_guarded!`, `_lower_store_via_shadow!`, `_lower_store_via_shadow_checkpoint!`, `_lower_load_via_shadow_checkpoint!`, `_emit_idx_eq_const!`, `_lower_load_multi_origin!`, `_lower_load_via_mux!`, `_lower_load_via_shadow!`, `_lower_load_via_mux_4x8!`, `_lower_load_via_mux_8x8!`, `_lower_store_via_mux_4x8!`, `_lower_store_via_mux_8x8!`, and N more 2x8/2x16/4x16/2x32 variants alluded to in `_pick_alloca_strategy`)
- Path-predicate computation (`_compute_block_pred!`, `_edge_predicate!`, `_and_wire!`, `_or_wire!`, `_not_wire!`, `resolve_phi_predicated!`, `resolve_phi_muxes!`, `has_ancestor`, `on_branch_side`, `_is_on_side`)
- Strategy dispatch (`_pick_add_strategy`, `_pick_mul_strategy`, `_pick_alloca_strategy`)
- Utility (`_callee_arg_types`, `_assert_arg_widths_match`, `_remap_gate`, `_entry_predicate_wire`, `_wires_to_u64!`, `_operand_to_u64!`, `_mux_store_pred_sym!`, `compute_ssa_liveness`, `_ssa_operands` × 15 methods)

**Why it matters.** Any agent asked to change lowering must scroll through 2,662 lines in one file to build a mental model. The phi-resolution functions, the multi-origin pointer code, the MUX-store variants, and the ripple-carry primitives all compete for attention. The `resolve_phi_muxes!` / `resolve_phi_predicated!` code is exactly the "CORRECTNESS RISK" code called out in CLAUDE.md, and it is buried between `lower_not1!` and `_pick_add_strategy`.

**Suggested fix.** Split into at least:
- `src/lowering/ctx.jl` — `LoweringCtx`, `LoweringResult`, `GateGroup`, constructors, dispatch tables (lines 1–165 of the current file).
- `src/lowering/orchestrator.jl` — `lower`, `lower_block_insts!`, `lower_loop!`, `topo_sort`, `find_back_edges`, `_fold_constants`, `compute_ssa_liveness` (lines 273–706).
- `src/lowering/phi.jl` — path-predicate + phi-resolution (lines 787–1071). **This is the file CLAUDE.md's "CORRECTNESS RISK" callout is really about.** It deserves to stand alone.
- `src/lowering/arith.jl` — `lower_binop!`, `lower_and!`/`_or!`/`_xor!`/`_shl!`/`_lshr!`/`_ashr!`/`_var_lshr!`/`_var_shl!`/`_var_ashr!`, `lower_icmp!`, `lower_eq!`, `lower_ult!`, `lower_slt!`, `lower_not1!`, `lower_select!`, `lower_mux!`, `lower_cast!`, `lower_divrem!`, `_cond_negate_inplace!` (lines 1072–1515).
- `src/lowering/memory.jl` — all pointer/alloca/store/load and their MUX-EXCH variants (lines 1516–1649 + 1799–1826 + 2014–2662).
- `src/lowering/call.jl` — `lower_call!`, `_callee_arg_types`, `_assert_arg_widths_match`, `_remap_gate` (lines 1864–2001).
- `src/lowering/aggregate.jl` — `lower_extractvalue!`, `lower_insertvalue!` (lines 1817–1863).

The test suite already organises along these lines (`test_branch.jl` + `test_predicated_phi.jl` exercise phi; `test_lower_store_alloca.jl` + `test_rev_memory.jl` + `test_soft_mux_mem*` exercise memory).

---

#### H2 — `_convert_instruction` in `ir_extract.jl` is ~650 lines of chained `if opc == LLVM.API.LLVM…`.
**Evidence.** `src/ir_extract.jl:1086-1734`. The function is a single linear if/elseif chain dispatching on LLVM opcodes and call-site name matches. Inside it are inline expansions for 15+ LLVM intrinsics: `llvm.umax`, `llvm.umin`, `llvm.smax`, `llvm.smin`, `llvm.abs`, `llvm.ctpop`, `llvm.ctlz`, `llvm.cttz`, `llvm.bitreverse`, `llvm.bswap`, `llvm.fshl`, `llvm.fshr`, `llvm.fabs`, `llvm.copysign`, `llvm.minnum`, `llvm.maxnum`, `llvm.floor`/`ceil`/`trunc`/`rint`/`round`. Each is a 10–40 line ad-hoc expansion emitting `IRInst` sub-sequences. `_convert_vector_instruction` (lines 2063–2299) is another 240 lines of the same pattern for vector opcodes.

**Why it matters.** Adding a new intrinsic means opening a 2,400-line file and finding the right branch inside a 650-line function. The expansions themselves have test coverage only via `test_intrinsics.jl` / `test_vector_ir.jl` — there's no per-intrinsic unit test isolating the expansion. This is exactly the file CLAUDE.md rule #5 ("LLVM IR is not stable") worries about: when LLVM changes intrinsic shapes, fixing this file requires archaeological work.

**Suggested fix.** Either:
(a) Extract a table `const _INTRINSIC_EXPANDERS = Dict{String, Function}(…)` where each entry maps `"llvm.bitreverse"` to a small function `(inst, names, counter) -> Vector{IRInst}`. The dispatch becomes `for (prefix, expander) in _INTRINSIC_EXPANDERS; startswith(cname, prefix) && return expander(inst, names, counter); end`. OR
(b) Move each intrinsic expander to its own file under `src/intrinsics/`, one file per concept family (int min/max, popcount/ctlz/cttz, bit-manipulation, float). The dispatch in `_convert_instruction` shrinks to a single loop over registered expanders.

Either fix makes intrinsic additions a one-file change and gives each expansion a natural home for its unit test.

---

#### H3 — Six Bennett-construction variant files with no shared abstraction.
**Evidence.**
- `bennett_transform.jl` (49 lines) — `bennett(lr)` + `_build_circuit` + `_compute_ancillae`
- `pebbling.jl` (209 lines) — `pebbled_bennett`, `knill_pebble_cost`, `knill_split_point`, `pebble_tradeoff`, `_pebble_with_copy!`
- `eager.jl` (119 lines) — `eager_bennett`, `compute_wire_mod_paths`, `compute_wire_liveness`
- `value_eager.jl` (137 lines) — `value_eager_bennett` (PRS15 Algorithm 2)
- `pebbled_groups.jl` (452 lines) — `pebbled_group_bennett`, `checkpoint_bennett`, `_replay_forward!`, `_replay_reverse!`, `_pebble_groups!`, `_emit_copy_gates!`, `_remap_gate`, `_remap_wire`, plus `ActivePebble`
- `sat_pebbling.jl` (197 lines) — `sat_pebble`, `_solve_pebbling`, `_add_at_most_k!`, `verify_pebble_schedule`

All six take a `LoweringResult` and return a `ReversibleCircuit`. They share the copy-wire-allocation, ancilla-computation, and circuit-building logic but only `_build_circuit` is actually reused. There is extensive duplication:

- Copy-wire allocation (`copy_start = lr.n_wires + 1; copy_wires = collect(copy_start:copy_start + n_out - 1); total = lr.n_wires + n_out`) appears verbatim in `bennett_transform.jl:33-35`, `eager.jl:91-94`, `value_eager.jl:87-90`, `pebbling.jl:113-117`, `pebbled_groups.jl:315-316`, `pebbled_groups.jl:375-376`.
- CNOT-copy emission loop (`for (i, w) in enumerate(lr.output_wires); push!(result, CNOTGate(w, copy_wires[i])); end`) appears in `bennett_transform.jl:41-43`, `eager.jl:96-98`, `value_eager.jl:91-94`, `pebbled_groups.jl:205-208` (variant), and `pebbled_groups.jl:419-422` (variant).

**Why it matters.** Four open-coded copies of the same copy-wire+CNOT-emit pattern means four places to fix when something changes (e.g. if copy wires ever need to be allocated via `WireAllocator` instead of by index arithmetic — pebbled_groups.jl already does this — the three others silently continue to use old indexing). Cross-agent review #3 (reviews/03_julia_idioms.md Finding F9/46/47) already flagged this independently.

**Suggested fix.** Create `src/bennett/common.jl` exporting:
```julia
allocate_copy_wires(lr::LoweringResult) -> (copy_wires::Vector{Int}, total::Int)
emit_copy_gates!(result, output_wires, copy_wires)
finalize_circuit(result, total, lr, copy_wires) -> ReversibleCircuit
```
Then `bennett`, `eager_bennett`, `value_eager_bennett`, `pebbled_bennett`, `checkpoint_bennett`, `pebbled_group_bennett` collapse from "~50 lines each with 15 lines of setup" to "~20 lines each with 1 line of setup". Would also be a good place to rename `bennett_transform.jl` back to `bennett.jl` and turn it into the header of this cluster (a single `src/bennett/bennett.jl` file that `includes` the variants).

---

#### H4 — File `bennett.jl` does not exist; all documentation refers to it.
**Evidence.**
- `src/Bennett.jl:12` — `include("bennett_transform.jl")`
- No `src/bennett.jl` exists (`ls /home/tobiasosborne/Projects/Bennett.jl/src/bennett*.jl` yields only `bennett_transform.jl`)
- Files claiming `bennett.jl` exists:
  - `CLAUDE.md:91` — "bennett.jl            # Bennett construction: forward + copy + uncompute"
  - `docs/src/architecture.md:78` — "### Stage 3: Bennett Construction (`bennett.jl`)"
  - `docs/src/architecture.md:126` — "  bennett.jl            Bennett construction (forward + copy + reverse)"
  - `Bennett-VISION-PRD.md:104` — Pipeline diagram labels the stage "(bennett.jl)"
  - Multiple design docs under `docs/design/` ("Zero lines changed in bennett.jl" — it doesn't exist to change)

Additionally, `WORKLOG.md` references it, the `reviews/` files all reference it (they are consistent with each other and CLAUDE.md because they were written against an earlier state of the repo).

**Why it matters.** Every new agent starting from CLAUDE.md will look for `bennett.jl`, not find it, and not immediately know why. This is a trap set for future contributors. Principle #0 of CLAUDE.md says "MAINTAIN THE WORKLOG" — the natural corollary, "maintain CLAUDE.md file-structure block", has been neglected.

**Suggested fix.** Either rename `bennett_transform.jl` → `bennett.jl` (preferred — 49-line file, trivial rename, aligns with H3 reorganization), or update CLAUDE.md + docs to say `bennett_transform.jl`. The former is correct because the file's content IS the Bennett construction (`bennett()`, `_build_circuit`, `_compute_ancillae`) — "transform" is a misnomer for a construction whose most-cited function is literally `bennett(lr)`.

---

#### H5 — `lower.jl` forward-references 6 modules included after it.
**Evidence.** `src/Bennett.jl` include order:
```
line 11: include("lower.jl")
line 12: include("bennett_transform.jl")
line 22: include("divider.jl")         # defines soft_udiv/soft_urem
line 23: include("softfloat/softfloat.jl")  # defines soft_fadd, etc.
line 24: include("softmem.jl")         # defines soft_mux_*
line 25: include("qrom.jl")            # defines emit_qrom!
line 26: include("tabulate.jl")        # defines lower_tabulate
line 29: include("shadow_memory.jl")   # defines emit_shadow_store!
line 30: include("fast_copy.jl")       # defines emit_fast_copy!
line 31: include("partial_products.jl")
line 32: include("parallel_adder_tree.jl")
line 33: include("mul_qcla_tree.jl")   # defines lower_mul_qcla_tree!
```

Yet `lower.jl` calls: `lower_mul_qcla_tree!` (line 1140), `soft_udiv`/`soft_urem` (line 1458), `emit_shadow_store!` (line 2260), `emit_qrom!` (referenced in docstring line 1568, called elsewhere in `lower_var_gep!`). `lower_call!` calls `extract_parsed_ir` (line 1935, from `ir_extract.jl` — this one IS included first, OK) and `bennett` (line 1941, from `bennett_transform.jl` — forward reference).

**Why it matters.** Julia's method dispatch is lazy so this works at runtime, but the include order is a lie. If you open `Bennett.jl` and read top-to-bottom expecting to understand the dependency chain, you get a misleading picture: `lower.jl` is positioned as if it is "early" but it sits at the bottom of a deep dependency tree. This also means you cannot `include("lower.jl")` standalone in a REPL to test lowering — you must first include every primitive.

**Suggested fix.** The clean dependency order is:
```
ir_types.jl           # pure data
gates.jl              # pure data
wire_allocator.jl     # pure data
ir_extract.jl         # depends on ir_types
ir_parser.jl          # depends on ir_types (if kept at all; see H6)
# primitive gate emitters — all depend on gates + wire_allocator
adder.jl
qcla.jl
multiplier.jl
qrom.jl
shadow_memory.jl
fast_copy.jl
partial_products.jl
parallel_adder_tree.jl
mul_qcla_tree.jl
divider.jl            # pure Julia soft function, depends on nothing
softfloat/softfloat.jl  # pure Julia soft functions, depends on nothing
softmem.jl            # pure Julia soft functions, depends on nothing
feistel.jl
memssa.jl
# lowering — depends on IR + primitives
lower.jl (split per H1)
tabulate.jl
# bennett-variant constructions — depend on LoweringResult
bennett.jl
eager.jl
value_eager.jl
pebbling.jl
pebbled_groups.jl
sat_pebbling.jl
dep_dag.jl            # used by pebbling, eager
# post-processing
simulator.jl
diagnostics.jl
controlled.jl
persistent/persistent.jl  # independent concern
```

---

### MEDIUM

#### M1 — `ir_parser.jl` is dead legacy code still exported.
**Evidence.**
- `src/ir_parser.jl:130` — `parse_ir(ir::AbstractString)`
- `src/Bennett.jl:5` — `include("ir_parser.jl")` (unconditional)
- `src/Bennett.jl:36` — exports `parse_ir`
- Only callers: `test/test_parse.jl` (5 uses, all in one testset validating the parser itself), `test/test_branch.jl:16` (dumps IR for diagnostics), `test/test_loop.jl:11` (same).
- CLAUDE.md:85 and `docs/src/architecture.md:114` both describe it as "Legacy regex parser (backward compat)".
- The parser handles a small subset: `add/sub/mul/and/or/xor/shl/lshr/ashr`, `icmp`, `select`, `sext/zext/trunc`, `phi`, `br` (with/without cond), `ret`. It does NOT handle: `call`, `switch`, `extractvalue`, `insertvalue`, `getelementptr`, `load`, `store`, `alloca`, `bitcast`, vector instructions, intrinsics, unreachable. So `test_parse.jl` can only verify a handful of tiny functions.

**Why it matters.** 168 lines + 5 tests of maintenance surface for no useful coverage. If LLVM IR syntax changes in a way that breaks the regexes, nobody notices because no production code calls `parse_ir`. The `extract_parsed_ir` pathway handles everything `parse_ir` handles and ~30 other opcodes. Reviews 2, 3, 5, and 6 have all independently flagged this.

**Suggested fix.** Delete `src/ir_parser.jl`, delete `test/test_parse.jl`, remove `parse_ir` from exports in `src/Bennett.jl:36`. The diagnostic prints in `test_branch.jl:16` and `test_loop.jl:11` don't need `parse_ir` — they use it only for the `println` and could be removed entirely, or replaced with `extract_parsed_ir` if someone genuinely wants the parsed view.

---

#### M2 — `_gate_target` / `_gate_controls` defined in `dep_dag.jl` but used by `diagnostics.jl` and `eager.jl`.
**Evidence.**
- `src/dep_dag.jl:90-96` — defines `_gate_target(g::NOTGate) = g.target`, etc., and `_gate_controls(g::NOTGate) = Int[]`, etc.
- `src/diagnostics.jl:134` — calls `_gate_target(g)` inside `peak_live_wires`
- `src/eager.jl:23`, `eager.jl:41`, `eager.jl:74`, `eager.jl:103` — call `_gate_target` / `_gate_controls`

**Why it matters.** Semantically, asking "what wire does this gate target?" is a property of `gates.jl`, not of "dependency DAG extraction". If `dep_dag.jl` were renamed or deleted (e.g. if SAT pebbling subsumes it), `diagnostics.jl` silently breaks. `gate_wires` (which does something similar) IS already in `diagnostics.jl:10-12`. So the same project has two nearly-equivalent accessors (`gate_wires` returns a tuple of all wires; `_gate_target` returns just the target), each in a different file, with no cross-reference.

**Suggested fix.** Move `_gate_target` and `_gate_controls` to `gates.jl` (or a new `src/gates_accessors.jl` if `gates.jl` is kept minimal-by-design). Unify with `gate_wires`:
```julia
# gates.jl
gate_target(g::NOTGate) = g.target
gate_target(g::CNOTGate) = g.target
gate_target(g::ToffoliGate) = g.target

gate_controls(g::NOTGate) = ()
gate_controls(g::CNOTGate) = (g.control,)
gate_controls(g::ToffoliGate) = (g.control1, g.control2)

gate_wires(g::ReversibleGate) = (gate_controls(g)..., gate_target(g))
```
Drop the leading underscore — these are worth exporting.

---

#### M3 — `softfloat/softfloat.jl` and `persistent/persistent.jl` are NOT modules despite naming.
**Evidence.**
- `src/softfloat/softfloat.jl` contents: 16 lines, all `include(…)` of sibling files. No `module SoftFloat`, no `end`.
- `src/persistent/persistent.jl` contents: 18 lines, same pattern.
- CLAUDE.md:107 — "softfloat.jl        # module definition" (incorrect; it's just an include list)

All symbols from both subdirs end up in the top-level `Bennett` namespace. That's why `Bennett.jl:45` has 21 separate soft_* exports on one line, and 38–43 have 15+ persistent-map exports.

**Why it matters.** (i) The CLAUDE.md description is wrong. (ii) The top-level `Bennett` namespace is polluted with ~40 helper-function names (`soft_fadd`, `hamt_pmap_get`, `okasaki_pmap_new`, `cf_reroot`, `soft_popcount32`, `soft_jenkins96`, …). (iii) Downstream users doing `using Bennett` see a crowded completion list. (iv) The persistent-map implementations have no natural namespace in which to collide (e.g. each impl has a `pmap_new` that must be prefixed `okasaki_pmap_new`/`hamt_pmap_new`/`cf_pmap_new` — in a submodule they could just be `Okasaki.pmap_new`, `Hamt.pmap_new`, `CF.pmap_new`).

**Suggested fix.** Either:
(a) Actually make them submodules:
```julia
# src/softfloat/softfloat.jl
module SoftFloat
  include("softfloat_common.jl")
  include("fadd.jl")
  # ...
  export soft_fadd, soft_fsub, ...
end
using .SoftFloat
```
Then in `Bennett.jl`, only re-export the USER-facing names (soft_fadd via the SoftFloat dispatch, the mux callees don't need to be user-visible). OR
(b) Accept the flat namespace and stop calling it a "module definition" in CLAUDE.md / docs.

Option (a) is the right call but requires auditing every `register_callee!(...)` at `Bennett.jl:163-208` — those 40 callees expect the function to be at top-level so LLVM's `@j_soft_fadd` name lookup works.

---

#### M4 — `src/Bennett.jl` is a junk drawer, not a façade.
**Evidence.** `src/Bennett.jl` (297 lines) contains:
- All `include(…)` directives (lines 3–34)
- All top-level exports (lines 36–48)
- Three distinct `reversible_compile` methods (lines 58, 105, 268) — with different positional-vs-keyword schemes
- An internal `_narrow_ir` + 11 `_narrow_inst` methods (lines 120–160) — a visitor pattern with full IR knowledge
- 37 `register_callee!` calls (lines 163–208) — should live wherever each callee is defined, not all piled at the module bottom
- The `SoftFloat` wrapper struct + 18 operator methods (lines 220–249) — a self-contained concept
- The Float64 dispatch `reversible_compile` method that wraps user code with `@inline f(SoftFloat(x)).bits` (lines 268–295)

**Why it matters.** Conceptually `src/Bennett.jl` should be ~50 lines: module header, include list, export list, maybe a brief `reversible_compile(f, T)` trampoline. Instead it's 297 lines containing at least four distinct concerns. Adding a new callee requires editing this file. Changing IR narrowing requires editing this file. Changing Float64 dispatch requires editing this file. Every subsystem has hooks here.

**Suggested fix.** Extract:
- `_narrow_ir` + `_narrow_inst` → `src/narrow.jl` (its own file, included once)
- `SoftFloat` + its operators + the Float64 `reversible_compile` method → `src/softfloat_dispatch.jl` (separate from pure soft-float library under `src/softfloat/`)
- `register_callee!` calls → each soft_* file registers its own callee immediately after defining the function. `softfloat/fadd.jl` ends with `register_callee!(soft_fadd)`. `softmem.jl` registers its own callees. This keeps definition + registration local.

After extraction, `src/Bennett.jl` shrinks to ~80 lines: module, includes, exports, the two plain `reversible_compile` methods.

---

#### M5 — `lower_call!` re-extracts callee IR every time (no cache).
**Evidence.** `src/lower.jl:1928-1989`. `lower_call!` calls `extract_parsed_ir(inst.callee, arg_types)` on every `IRCall` instruction. For SHA-256 full (`test/test_sha256_full.jl`) which has many soft_fadd / soft_fmul calls, this means re-extracting the same callee dozens of times. `_callee_arg_types` also re-derives arg types via `methods()` on each call (`lower.jl:1864`).

**Why it matters.** Compile speed. Also, philosophical: the pipeline picture "extract once, lower, bennett" is not accurate — `lower` can call `extract` internally on arbitrary user functions, which triggers arbitrary Julia type inference. If a callee has uncached side effects (e.g. `eval` or module-ordering), the result of compilation becomes order-dependent.

**Suggested fix.** Introduce a `Dict{Tuple{Function, Type{<:Tuple}}, ParsedIR}` cache either module-scoped or threaded through `LoweringCtx`. Even a simple per-`lower()` cache would handle SHA-256's repeated callees.

---

#### M6 — Test layout does not mirror source layout.
**Evidence.** Test files:
- Named for opcodes: `test_bitwise.jl`, `test_branch.jl`, `test_compare.jl`, `test_switch.jl`, `test_predicated_phi.jl`, `test_extractvalue.jl`, `test_var_gep.jl`, `test_vector_ir.jl`
- Named for scenarios: `test_increment.jl`, `test_polynomial.jl`, `test_combined.jl`, `test_tuple.jl`, `test_ntuple_input.jl`, `test_two_args.jl`
- Named for types: `test_int16.jl`, `test_int32.jl`, `test_int64.jl`, `test_mixed_width.jl`, `test_narrow.jl`, `test_negative.jl`
- Named for bd issues: `test_0c8o_vector_sret.jl`, `test_atf4_lower_call_nontrivial_args.jl`, `test_cc04_repro.jl`, `test_cc06_error_context.jl`, `test_cc07_repro.jl`, `test_uyf9_memcpy_sret.jl`, `test_p5_fail_loud.jl`, `test_p5a_equivalence.jl`, `test_p5a_ll_ingest.jl`, `test_p5b_bc_ingest.jl`

No test files named for src files: no `test_bennett.jl`, no `test_lower.jl`, no `test_simulator.jl`, no `test_ir_extract.jl`, no `test_gates.jl`, no `test_diagnostics.jl`, no `test_ir_types.jl`, no `test_divider.jl`, no `test_multiplier.jl`, no `test_adder.jl`, no `test_softmem.jl`, no `test_bennett_transform.jl`.

**Why it matters.** (i) When a src file changes, you can't discover its tests by filename — you have to search. (ii) New contributors can't find "where do I add a test for a change to `bennett_transform.jl`?" — the answer is "look at any test using `reversible_compile` + `verify_reversibility`, which is all of them". (iii) The integration-heavy style means a lowering bug can fail 50 tests across 20 files, making root-cause-analysis painful.

**Suggested fix.** Not urgent — the test-by-feature approach works. But add an `INDEX.md` in `test/` mapping src files to their primary tests. Or introduce a per-src `test_<srcfile>.jl` that holds the isolated unit tests (e.g. `test_bennett.jl` for the forward+copy+reverse invariant on a hand-built trivial `LoweringResult`, bypassing lowering entirely).

---

#### M7 — Naming inconsistency: `pebbling.jl` vs `pebbled_groups.jl` vs `sat_pebbling.jl`; `eager.jl` vs `value_eager.jl`; `bennett_transform.jl` vs `bennett.jl` (docs).
**Evidence.**
- `pebbling.jl` — Knill recursion at the gate level (`pebbled_bennett`)
- `pebbled_groups.jl` — Knill recursion at the SSA-group level (`pebbled_group_bennett`) + `checkpoint_bennett`
- `sat_pebbling.jl` — SAT-encoded pebbling (`sat_pebble`)
- `eager.jl` — PRS15 gate-level dead-end cleanup (`eager_bennett`)
- `value_eager.jl` — PRS15 Algorithm 2 at the SSA-value level (`value_eager_bennett`)

**Why it matters.** One concept (space-optimized Bennett) across five files with three naming conventions. A reader cannot predict which file contains what from the name. Is "pebbling" the noun and the variants are adjectives (pebbled groups, SAT pebbling)? Or is "pebbling" the umbrella concept and "eager" a different branch? The current files put Knill and PRS15 at the same hierarchy level without saying so.

**Suggested fix.** Reorganise under `src/bennett/`:
```
src/bennett/bennett.jl          # entry: bennett(), _build_circuit, _compute_ancillae, common utilities
src/bennett/eager.jl            # PRS15 gate-level + value-level
  # contains eager_bennett + value_eager_bennett
src/bennett/pebbling.jl         # Knill-based
  # contains pebbled_bennett (gate-level) + pebbled_group_bennett + checkpoint_bennett + knill helpers
src/bennett/sat.jl              # SAT-based
  # contains sat_pebble, _solve_pebbling, verify_pebble_schedule
```
And `src/bennett/bennett.jl` is the common-utilities file recommended in H3.

---

### LOW

#### L1 — `dep_dag.jl` is consumed by `pebbling.jl` for `min_pebbles` but never by `eager.jl` despite `_gate_target` / `_gate_controls` living there.
**Evidence.** `dep_dag.jl` exports `DAGNode`, `DepDAG`, `extract_dep_dag`, `_gate_target`, `_gate_controls`. Only callers of `extract_dep_dag`: none in `src/`. Callers of `_gate_target` / `_gate_controls`: `diagnostics.jl`, `eager.jl` (see M2). So `DepDAG` and `extract_dep_dag` may actually be unused production code — check test/test_dep_dag.jl.

**Why it matters.** Possible dead code that looks like infrastructure.

**Suggested fix.** Verify whether `extract_dep_dag` has production callers (I see it referenced in tests but not elsewhere in `src/`). If unused in `src/`, move the DAG logic to `test/` or `docs/experimental/`.

---

#### L2 — `ir_types.jl` defines `ParsedIR` with a hack `Base.getproperty` for backward compat.
**Evidence.** `src/ir_types.jl:211-221`:
```julia
function Base.getproperty(p::ParsedIR, name::Symbol)
    if name === :instructions
        return getfield(p, :_instructions_cache)
    else
        return getfield(p, name)
    end
end
```
The caching field is named `_instructions_cache` but external code accesses `parsed.instructions`. The `propertynames` is manually overridden.

**Why it matters.** Backward-compat hack. Any reader of `ParsedIR` sees `_instructions_cache` in the struct definition and wonders if it's a private implementation detail. Plus `parsed.blocks` + flattened `parsed.instructions` duplicate the same information.

**Suggested fix.** Either (a) make `instructions` a plain function `instructions(p::ParsedIR) = p._instructions_cache` (explicit) or (b) drop `_instructions_cache` entirely and provide `instructions(p::ParsedIR) = Iterators.flatten((append!(copy(b.instructions), [b.terminator]) for b in p.blocks))` — lazy, no duplication. Callers using `parsed.instructions` in tight loops could keep the cache at the call site.

---

#### L3 — `Bennett.jl`'s three `reversible_compile` methods have divergent keyword signatures.
**Evidence.** `src/Bennett.jl`:
- Line 58: `reversible_compile(f, arg_types::Type{<:Tuple}; optimize, max_loop_iterations, compact_calls, bit_width, add, mul, strategy)` — 7 kwargs
- Line 105: `reversible_compile(parsed::ParsedIR; max_loop_iterations, compact_calls, add, mul)` — 4 kwargs
- Line 268: `reversible_compile(f, float_types::Type{Float64}...; optimize, max_loop_iterations, compact_calls, strategy)` — 4 kwargs (no `add`, no `mul`, no `bit_width`)

**Why it matters.** Users calling `reversible_compile(g, Float64; mul=:qcla_tree)` get a silent ignored kwarg... actually they'd get a `MethodError` because `mul` isn't a declared kwarg on the Float64 method. Users calling `reversible_compile(parsed; bit_width=16)` get a `MethodError` because `bit_width` only works for the `f, arg_types` variant.

**Suggested fix.** Document the matrix or unify to a common set of kwargs where the irrelevant ones are silently-accepted with no-op semantics. At minimum, `Float64` should accept `add` and `mul` because soft_fadd/soft_fmul internally call integer add/mul — currently those strategies can't be influenced from the Float64 entry point.

---

#### L4 — `verify_reversibility` is duplicated for `ReversibleCircuit` and `ControlledCircuit`.
**Evidence.** `src/diagnostics.jl:145-161` and `src/controlled.jl:89-107`. Different struct, same algorithm. Likewise `simulate` is defined twice in `simulator.jl:5-12` for `ReversibleCircuit` and in `controlled.jl:56-64` for `ControlledCircuit`.

**Why it matters.** Small enough to be fine, but any bug fix to one (e.g. if random-input distribution changes) must be mirrored in the other.

**Suggested fix.** Abstract via a `AbstractReversibleCircuit` interface with `get_inner_circuit(c)` so both share the algorithm.

---

#### L5 — `LoweringCtx` has four legacy constructors for back-compat.
**Evidence.** `src/lower.jl:50-119`. The struct has 16 fields; there are four increasingly-richer constructors (11-arg, 12-arg, 13-arg, and the struct default). Each comment says "backward-compatible, existing sites don't need to pass the new fields."

**Why it matters.** The explicit comment "Backward-compatible constructor" four times in a row suggests `LoweringCtx` has been grown by `git diff`-patch accumulation rather than rethought. If any caller in `src/` uses the 11-arg form, that caller has been broken with the 12-arg form under the hood and is now silently getting default `Dict`s.

**Suggested fix.** Audit callers. Grep for `LoweringCtx(` in `src/`:

```
src/lower.jl:588 (in lower_block_insts!)
```

Only one callsite. Collapse to one constructor; everything else is dead legacy.

---

### NIT

#### N1 — `ir_types.jl:82-106` has two-origin / single-origin commentary inline inside `LoweringCtx` that is conceptually about `PtrOrigin` defined in the same file.
**Evidence.** The long "Bennett-cc0 M2b" comment block is about pointer provenance semantics; it sits inside the struct definition rather than near `PtrOrigin` at `ir_types.jl:153`. Reading the struct takes three screens because the comments are longer than the code.

**Suggested fix.** Move the prose above `struct PtrOrigin`. Keep the struct fields annotated by one-liners.

#### N2 — `src/Bennett.jl:36-48` has exports on 13 separate `export` lines with seemingly random grouping.
**Evidence.** Line 36 mixes `reversible_compile`, `simulate`, `extract_ir`, `parse_ir`, `extract_parsed_ir`, `register_callee!` (core), while line 41 is just `export soft_popcount32` alone, line 43 is `soft_jenkins96, soft_jenkins_int8`, line 44 is `soft_feistel32, soft_feistel_int8`. The grouping is by development order, not conceptual cohesion.

**Suggested fix.** Group: core pipeline / IR / circuits / diagnostics / persistent-maps / soft-float / bennett-variants. One export block per group, one line per group (or labelled comment headers).

#### N3 — `pebbled_groups.jl` is 452 lines and contains both `pebbled_group_bennett` AND `checkpoint_bennett`.
**Evidence.** The two functions are conceptually distinct (Knill-recursion vs flat per-group checkpointing). The file docstring only mentions the former. `checkpoint_bennett` is also exported separately in `Bennett.jl:48`.

**Suggested fix.** Either split into `pebbled_groups.jl` + `checkpoint.jl`, or rename the file to `group_bennett.jl`. Current name under-describes contents.

#### N4 — `lower_load!` is defined twice in `lower.jl` (line 1646 ctx-based, line 1799 gates-based).
**Evidence.** `src/lower.jl:1646` takes `ctx::LoweringCtx`; `src/lower.jl:1799` takes `(gates, wa, vw, inst::IRLoad)`. The first calls the second via `lower_load!(ctx.gates, ctx.wa, ctx.vw, inst)` (line 1657) when there's no provenance info. It's Julia dispatch, not a duplication, but reading the file sequentially you encounter the bigger/smarter function first and assume it's the only one. Placed adjacent with a comment, it would be clearer.

**Suggested fix.** Rename the legacy form `_lower_load_flat!` or add a preceding comment `# Fallback lower_load! for direct callers without provenance info`.

#### N5 — Test file `test_parse.jl` has no `@testset` top-level name.
**Evidence.** `test/test_parse.jl:1-48` uses only inner `@testset` names ("Parse increment", "Parse polynomial"). A failing test output would say "Test Failed at test_parse.jl:7" with no parent context in `Test.DefaultTestSet`. Minor.

**Suggested fix.** Wrap the file in `@testset "IR Parsing (legacy regex)"`.

#### N6 — `bennett_transform.jl:25-28` — self-reversing short-circuit returns `copy(lr.gates)` rather than `lr.gates`. Allocates for no reason since the returned `ReversibleCircuit` owns the vector.
**Evidence.** `src/bennett_transform.jl:28`:
```julia
return _build_circuit(copy(lr.gates), lr.n_wires, lr.input_wires, ...)
```
If the caller holds `lr` and then mutates `circuit.gates` in-place, this copy is defensive. But every call site drops `lr` immediately. The `lr.gates` vector is also typed `Vector{ReversibleGate}` — a copy of an 11,000-element vector for SHA-256 is cheap but not free.

**Suggested fix.** Drop the `copy`. Convention: `bennett(lr)` consumes `lr`; any caller retaining `lr` knows to pass `deepcopy(lr)` explicitly.

---

## Call-graph hotspots (raw counts)

Running Grep across `src/`:

- **`CNOTGate(` / `ToffoliGate(` / `NOTGate(` constructors:** 182 occurrences across 17 files. Most fan-out in `lower.jl` (90), `adder.jl` (27), `qrom.jl` (11), `multiplier.jl` (10), `qcla.jl` (9), `pebbled_groups.jl` (7), `shadow_memory.jl` (7). Consistent: every lowering primitive goes through gate-struct constructors directly. No abstraction leak there.
- **`allocate!(wa, …)`:** 97 occurrences across 14 files. Heaviest in `lower.jl` (54), `multiplier.jl` (11), `pebbled_groups.jl` (6), `adder.jl` (6), `parallel_adder_tree.jl` (5), `qrom.jl` (5). Everyone who emits gates also allocates wires; this is the expected Julia idiom.
- **`resolve!`:** 29 total — 28 in `lower.jl`, 1 in `qrom.jl`. `qrom.jl:1` calling `resolve!` is the only leak of resolve-logic outside the lowering layer. Mild.
- **`_build_circuit`:** called from 6 files (`bennett_transform.jl`, `eager.jl`, `value_eager.jl`, `pebbling.jl`, `pebbled_groups.jl`). Defined once. Clean.
- **`LoweringResult`:** constructed/read in 7 files (all inside lowering or bennett-variants). Clean.
- **`ParsedIR`:** touched in 6 files (`ir_extract.jl`, `ir_parser.jl`, `lower.jl`, `tabulate.jl`, `Bennett.jl`, `ir_types.jl`). Clean.
- **`LLVM.` / `using LLVM`:** 3 files (`ir_extract.jl`, `memssa.jl`, `Bennett.jl`). The `Bennett.jl` hit is a docstring mention only. Real leak: `memssa.jl` has a `LLVM.Context()` + `LLVM.NewPMPassBuilder()` block. This is correct in spirit (running an LLVM pass) but means "IR extraction" is really a two-file subsystem (`ir_extract.jl` + `memssa.jl`), not one.

### God functions by size

(measured by lines between `function foo` and the next `function`)

1. `_convert_instruction` — `ir_extract.jl:1086-1734`, ~650 lines. **God function.** (See H2.)
2. `_convert_vector_instruction` — `ir_extract.jl:2063-2299`, ~240 lines. Cut down but still long; should fit the same "table of expanders" treatment.
3. `_module_to_parsed_ir_on_func` — `ir_extract.jl:777-935`, ~160 lines. Acceptable-ish; clearly phased (pass 1 / pass 2 / post-pass).
4. `lower` — `lower.jl:307-466`, ~160 lines. The main orchestration; acceptable.
5. `lower_call!` — `lower.jl:1928-1990`, 63 lines. Internally branches on `compact` with almost-identical body; worth deduplicating.
6. `lower_binop!` — `lower.jl:1096-1157`, 62 lines. Dispatches by `inst.op`. Should be a dispatch table keyed on `Val{:add}` / `Val{:mul}` / etc. — same refactor suggestion as H2.
7. `lower_store!` + `_lower_store_single_origin!` — ~75 lines combined. The single-origin/multi-origin split is clean; no complaint.
8. `_fold_constants` — `lower.jl:473-566`, 94 lines. The constant-folder reasons through four gate-type cases; fine as-is.

---

## Tests: src-coverage gaps

Files with NO matching `test_<basename>.jl`:
```
src/Bennett.jl                 (tested indirectly; everything uses it)
src/bennett_transform.jl       (tested indirectly via verify_reversibility on every circuit)
src/diagnostics.jl             (tested indirectly via gate_count assertions in most tests)
src/gates.jl                   (tested indirectly; any gate emission)
src/ir_extract.jl              (tested indirectly via every integration test)
src/ir_types.jl                (pure data; no behaviour)
src/lower.jl                   (tested via every opcode/feature test)
src/simulator.jl               (tested indirectly via every simulate() call)
src/adder.jl / src/multiplier.jl / src/divider.jl  (tested via arithmetic integration tests)
src/softmem.jl                 (tested via test_soft_mux_mem* — partial name match)
src/softfloat/*.jl              (tested via test_softf* — again partial)
src/persistent/*.jl             (tested via test_persistent_* — partial)
```

The partial-name matches are fine. The truly-missing files are `bennett_transform.jl`, `gates.jl`, `ir_types.jl`, `simulator.jl`, `diagnostics.jl` — pure-function primitives that would benefit from isolated tests (e.g. "construct a `ReversibleCircuit` by hand with 2 ancilla wires, call `gate_count` / `verify_reversibility` / `depth` — assert exact returns").

---

## Recommended reorganization (ordered by ROI)

1. **Rename `bennett_transform.jl` → `bennett.jl`** (H4). One-liner, unblocks documentation alignment.
2. **Delete `ir_parser.jl` + `test_parse.jl`** (M1). 168 lines gone, no behaviour lost.
3. **Move `_gate_target` / `_gate_controls` → `gates.jl`** (M2). Unblocks understanding of `eager.jl` and `diagnostics.jl`.
4. **Extract `_narrow_ir` + 11 `_narrow_inst` methods from `Bennett.jl` → `src/narrow.jl`** (M4). Reduces `Bennett.jl` by ~40 lines.
5. **Extract `SoftFloat` wrapper + Float64 `reversible_compile` → `src/softfloat_dispatch.jl`** (M4). Another ~70 lines out of `Bennett.jl`.
6. **Move `register_callee!(soft_…)` calls to the same file as each `soft_…` definition** (M4). Removes 37 lines from `Bennett.jl`, makes each file self-registering.
7. **Create `src/bennett/common.jl` with `allocate_copy_wires` + `emit_copy_gates!` + `finalize_circuit` helpers** (H3). Deduplicates 4 Bennett-variant files.
8. **Reorganise include order in `Bennett.jl` so `lower.jl` comes AFTER its dependencies** (H5). Requires (7) first.
9. **Split `lower.jl` into `src/lowering/*.jl`** (H1). Biggest payoff but most disruptive. Do after (1)–(8) to reduce merge conflict surface.
10. **Factor `_convert_instruction` into a dispatch table over intrinsic/opcode handlers** (H2). Do after the structural reorganisation settles.

Step 1 alone eliminates the most confusing artefact for new agents. Steps 1–6 take a weekend and produce a 20% line-count reduction in `Bennett.jl` while making every change mechanical and easily-reviewable. Steps 7–10 are more invasive and deserve a design doc + proposer pair per CLAUDE.md Principle #2.

---

## What the project is NOT doing wrong

Credit where due, because a skeptical review has to be honest:

- **Gate structs, `ParsedIR`, `ReversibleCircuit`, `LoweringResult` are well-factored.** Single responsibility, clear fields, tested via integration.
- **LLVM.jl is contained in `ir_extract.jl` + `memssa.jl`.** No leaks into `lower.jl`, `bennett_transform.jl`, etc.
- **`simulator.jl` is small (68 lines), pure, and does not leak into the compiler.** No cyclic dep.
- **The dispatch pattern `_lower_inst!(ctx, inst::IRPhi, label)` etc.** (lines 122–164 of `lower.jl`) is idiomatic Julia multiple-dispatch and cleanly separates instruction types from lowering logic.
- **`WireAllocator`** (31 lines, `src/wire_allocator.jl`) is a tidy module that does one thing.
- **Test suite is extensive.** 110 test files, 11,330 test lines vs 13,328 src lines — roughly 1:1 ratio, high density. The test-by-feature organisation works even if it doesn't mirror src layout.
- **`controlled.jl`** is a clean 107-line extension: one struct wrapping `ReversibleCircuit` + `promote_gate!` dispatch + `simulate(::ControlledCircuit, ...)`. Exemplary design.
- **The `bd`-issue-tracked test files** (e.g. `test_cc07_repro.jl`) are a visible record that bug fixes were accompanied by regression tests. This is exactly what CLAUDE.md Principle #3 (RED-GREEN TDD) asks for.

---

## Summary scorecard

| Concern | Grade | Notes |
|---|---|---|
| Pipeline clarity | B+ | Clean conceptually; docs describe a `bennett.jl` that doesn't exist |
| Module boundaries | C+ | `Bennett.jl` is a junk drawer; `softfloat/` and `persistent/` aren't real modules |
| Include order | C | `lower.jl` is included before its dependencies |
| Call-graph hotspots | C | `_convert_instruction` (~650 lines) + `lower.jl` (2,662 lines) are god-scale |
| Layering | B+ | LLVM.jl cleanly contained; simulator doesn't leak into compiler |
| Legacy cruft | D | `ir_parser.jl` dead code still exported |
| Naming consistency | C | `bennett_transform` vs `bennett`, `pebbling` vs `pebbled_groups`, `eager` vs `value_eager` |
| Extension points | B | Adding a new LLVM opcode = touch one big file; adding a callee = touch `Bennett.jl` + define function |
| Per-file size | C- | Two files >2,000 LOC, one function ~650 LOC |
| Test layout | B- | Extensive but organised by feature not by src; unit-tests for pipeline primitives missing |

Overall: **B-**. The pipeline works and is testable; the structure is visibly accreting and needs a reorganization pass before it hits the next 5,000 LOC.
