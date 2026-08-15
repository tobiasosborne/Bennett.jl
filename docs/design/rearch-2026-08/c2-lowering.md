# C2 — Lowering (ParsedIR → gates) and the arithmetic circuit library

Adversarial architecture review, 2026-08-15.
Scope: `src/lower.jl`, `src/lowering/*.jl` (9 files), `src/wire_allocator.jl`,
`src/adder.jl`, `src/qcla.jl`, `src/multiplier.jl`, `src/mul_qcla_tree.jl`,
`src/partial_products.jl`, `src/parallel_adder_tree.jl`, `src/divider.jl`.
Total ≈ 4,993 LOC. Read in full; coupling mapped by grep against callers.

---

## 1. What this area actually does

### 1.1 The advertised design

"`lower(parsed_ir)` maps each instruction to reversible gates." One function per
opcode, a wire allocator underneath, a library of literature-grade arithmetic
primitives beside it.

### 1.2 The real design

`lower()` is **a whole compiler back end fused into one 280-line function plus a
23-field mutable-by-convention context object**, doing seven jobs at once:

1. **CFG analysis** — `find_back_edges` (recursive DFS, `cfg.jl:8-40`) and
   `topo_sort` (Kahn, `cfg.jl:43-75`). There is *no dominator tree anywhere in the
   project*. Control-dependence is reconstructed incrementally: `preds` and
   `branch_info` are populated *as blocks are emitted* (`driver.jl:315-333`), so
   the CFG analysis and the code emission are the same pass and cannot be
   separated or tested independently.
2. **Predicate materialization** — a 1-bit "this block is live" wire per block,
   built by AND/OR/NOT gate trees over predecessors (`phi.jl:40-89`). This is
   if-conversion, done at gate level, computed on the fly.
3. **Instruction selection** — `_lower_inst!` type dispatch (`types.jl:237-286`)
   into per-opcode emitters that immediately re-flatten `ctx` back into positional
   arguments and kwargs, defeating the point of having a context.
4. **Register allocation** — `WireAllocator`, a bump allocator (`wire_allocator.jl`)
   whose free list is used by exactly three call sites in the whole repo
   (`qrom.jl:129`, `feistel.jl:123`, `pebbled_groups.jl:122-123,495`). The de-facto
   model is *allocate and never free; Bennett's global reverse pass cleans up*.
5. **Loop handling** — `lower_loop!` (`cfg.jl:152-412`) is a 260-line **second
   implementation of the block walk**, with iteration-local `preds` /
   `branch_info` / `block_pred` dicts, its own `LoweringCtx` construction
   (`cfg.jl:256-274`), a hard-coded `add=:ripple` override of the user's strategy
   (`cfg.jl:261`), a hard-coded empty liveness dict (`cfg.jl:258`), and a
   "(K+1)-th check-only pass" (`cfg.jl:382-401`) that re-lowers the header body
   *a second time, emitting real gates*, purely to derive a convergence bit.
6. **A memory model** — `lowering/memory.jl` is 1,165 LOC (23% of the area) and is
   not lowering at all: it is a reversible-store/load subsystem with four
   strategies (`:shadow`, `:mux_exch_NxW`, `:shadow_checkpoint`,
   `:persistent_tree`), an `@eval` code generator over 11 array shapes
   (`memory.jl:978-1072`), and a persistent-data-structure dispatcher that calls
   the *runtime* library at compile time to discover a bit width
   (`memory.jl:281-289`, `impl.pmap_new()`).
7. **A gate-level peephole/constant-folding optimizer** — `_fold_constants`
   (`driver.jl:407-510`), abstract interpretation over the flat gate list.

The arithmetic library (`adder.jl`, `qcla.jl`, `multiplier.jl`,
`mul_qcla_tree.jl`, `partial_products.jl`, `parallel_adder_tree.jl`,
`divider.jl` — 752 LOC total) is a *completely different quality of artifact*:
pure functions with the uniform signature
`(gates, wa, a::Vector{Int}, b::Vector{Int}, W) -> Vector{Int}`, zero dependency
on `ParsedIR`, `LoweringCtx`, or anything above them, each citing a paper and
regression-testing its published cost formula. This is the good half of the area
and it is already, accidentally, a separable library.

### 1.3 Data model

- `GateGroup` (9 fields, `types.jl:28-38`): SSA name → gate range + wire range +
  deps + a `is_self_reversing` producer tag.
- `LoweringResult` (9 fields, `types.jl:78-94`) + 2 convenience constructors.
- `LoweringCtx` (**23 positional fields**, `types.jl:115-183`), constructed at
  three sites (`driver.jl:521`, `cfg.jl:256`, `cfg.jl:384`) with fully positional
  arguments.
- `BlockLoweringOpts` (16 `@kwdef` fields, `types.jl:208-234`) — a *second* bundle
  of largely the same state, existing only to feed the first one.
- Gates: `Vector{ReversibleGate}` with `ReversibleGate` **abstract**
  (`gates.jl:4`) — a boxed, pointer-chasing array holding up to ~10⁵–10⁶ elements
  for Float64 programs.

---

## 2. Antipatterns and accidental complexity

I separate these into *genuine defects*, *accidental complexity*, and
*justified-by-domain*.

### 2.A Genuine antipatterns / defects

**A1. `add=:cuccaro` is broken and the guard that was supposed to protect it is
dead code.**
`_pick_add_strategy` (`arith.jl:20-26`) takes four arguments and ignores three of
them; `:auto` unconditionally returns `:ripple`, and an explicit `:cuccaro`
returns `:cuccaro` *without consulting `op2_dead`*. Meanwhile `op2_dead`
(`arith.jl:204-205`) is computed from `compute_ssa_liveness` on every add. Cuccaro
returns `b`'s wire vector as the result (`adder.jl:145`), so `vw[dest]` aliases
`vw[op2]` and op2's SSA value is silently clobbered. Reproduced:

```
f(x::Int8, y::Int8) = (x + y) + y
reversible_compile(f, Tuple{Int8,Int8}; add=:cuccaro, optimize=false, fold_constants=false)
# → ERROR: input wire 10 changed from true to false — Bennett input-preservation invariant violated
```
(`add=:ripple` and `add=:qcla` give 0 mismatches on the same function.) It fails
loud, which is the good news; the bad news is that a documented public kwarg is
unsound for any live second operand and the liveness machinery that was designed
to prevent this is never consulted.

**A2. The entire liveness subsystem is dead.**
`compute_ssa_liveness` (`operand.jl:116-146`) is computed by default
(`driver.jl:154`), threaded through `BlockLoweringOpts`, `LoweringCtx`, and
`lower_binop!`'s kwargs — and its only consumer ignores it (A1). Worse, the two
index spaces disagree: `compute_ssa_liveness` counts terminators and walks
`parsed.blocks` in *source order*; `ctx.inst_counter` skips terminators and
advances in *topological order* (`driver.jl:531`). Even if a consumer existed, the
comparison `liveness[name] <= inst_idx` would be meaningless.

**A3. Silent skips in the most correctness-critical function.**
`_compute_block_pred!` line `phi.jl:58`: `haskey(block_pred, p) || continue  # skip
if predecessor has no predicate (loop)`. A missing predecessor silently drops a
term from the OR, weakening the block predicate. `_edge_predicate!`
(`phi.jl:120-130`) has the same shape: if `src_block` has `branch_info` but
neither target equals `phi_block`, it falls through to `return block_pred[src_block]`
— i.e. it returns the *block* predicate where an *edge* predicate was required.
That over-approximation is precisely the false-path-sensitization failure mode
CLAUDE.md names as the project's #1 risk, sitting as an unguarded fallthrough
in a function whose docstring promises "correct for arbitrary CFGs". Both should
be `error()` per CLAUDE.md §1.

**A4. `_lower_load_legacy!` silently returns on an unknown pointer.**
`aggregate.jl:533-536`: `# Load from unknown pointer — skip (may be pgcstack safepoint
load)` → `return`. The instruction produces no `vw[inst.dest]`, so the failure
surfaces later as an "undefined SSA variable" from `resolve!` at an unrelated
place, or not at all. This is the exact pattern the extractor was hardened
against in Bennett-bjdg; the lowerer still has it.

**A5. `fold_constants=true` (the default) silently disables three Bennett
strategies.** `_fold_constants` returns `GateGroup[]` (`driver.jl:507-509`) because
folding invalidates gate ranges. `value_eager`, `pebbled_group`, and `checkpoint`
strategies all read `lr.gate_groups` (`pebble/value_eager.jl:46`,
`pebble/pebbled_groups.jl:290,395`) and "fall back to full Bennett if gate_groups
is empty". So the documented default configuration makes half the strategy
surface a no-op, silently. Two supposedly-independent knobs are secretly coupled.

**A6. `lower_call!` throws away every compile option.**
`call.jl:97`: `callee_lr = lower(callee_parsed; max_loop_iterations=64)`. The
callee is lowered with `add=:auto`, `mul=:auto`, `target=:gate_count`,
`fold_constants=true`, `mem=:auto` — regardless of what the user asked for. Since
*all* of soft-float, soft-div, and the persistent-map operations are inlined
callees, `reversible_compile(f, Float64; target=:depth, mul=:qcla_tree)` applies
the depth-optimised multiplier to *nothing that matters*. The `64` is a magic
number the code itself flags as "a known smell" (`call.jl:92-96`).

**A7. No callee lowering cache.** `_extract_parsed_ir_cached`
(`extract/callees.jl:52`) memoizes *extraction* only. Every call site re-runs the
full `lower()` of the callee. A soft-float expression with 20 `soft_fmul` calls
lowers `soft_fmul` 20 times. `lower_call!` then also *copies the whole gate
vector* per site (`call.jl:152-155`).

**A8. Latent wire-aliasing bug in `lower_call!`.** `call.jl:137-139` (and the
compact twin at `:102-104`) does `wire_offset = wire_count(wa)` then
`allocate!(wa, callee_lr.n_wires)`, and remaps callee gate `w` to `w + wire_offset`.
This assumes `allocate!` returns the contiguous block `[offset+1, offset+n]`. But
`allocate!` pops the free list first (`wire_allocator.jl:19-22`), and `free!` *is*
called during lowering — `qrom.jl:129`, reached from `lower_var_gep!` →
`_emit_qrom_from_gep!` on any constant global table. A function that does a
constant-table lookup and then calls a registered callee will remap the callee's
gates onto *live* wires. Not currently reproduced (the QROM path and the callee
path rarely meet in the test corpus), but it is a real invariant violation, and
the fix is not local: the whole design assumes contiguity that the allocator does
not promise.

**A9. `target=:depth` only steers `mul`.** `driver.jl:142-144` pre-resolves
`mul=:auto → :qcla_tree` under `target=:depth`, but `_pick_add_strategy` has no
`target` parameter at all, so `x+y` under `target=:depth` still gets the ripple
adder with O(W) Toffoli depth — when `lower_add_qcla!` (O(log W) depth) is sitting
right there and is what the depth-optimal multiplier itself uses internally. The
objective is honoured for one opcode and ignored for the other.

**A10. Stranded ancillae by construction in the QCLA add path.**
`arith.jl:211`: `lower_add_qcla!(gates, wa, a, b, W)[1:W]  # drop carry-out`. `Z[W+1]`
holds the carry-out and is non-zero; it is simply abandoned. Correct only because
Bennett's outer reverse pass uncomputes everything. The same pattern recurs at
`arith.jl:249` (`full[1:W]` on the qcla_tree mul, explicitly documented as
stranding W dirty wires) and `aggregate.jl:119-132` (`result64` high bits). This
is a systemic consequence of §2.C1 below.

### 2.B Accidental complexity (fixable by design, not defects per se)

**B1. Six copy-pastes of the gate-group bookkeeping ritual.** The pattern
```julia
_ws = wa.next_wire; _gs = length(gates) + 1
<emit>
if length(gates) >= _gs; push!(gate_groups, GateGroup(name, _gs, length(gates), …, _ws, wa.next_wire - 1)); end
```
appears at `driver.jl:239-246, 249-256, 291-298, 307-314, 317-324, 339-346` and
again at `driver.jl:533-544`. It should be one `@grouped` macro or a
`with_group(f, name)` do-block. As written, each copy can (and one does) diverge:
the `lower_block_insts!` copy is the only one that guards on
`hasproperty(inst, :dest)` (`driver.jl:539`), so `IRStore` never produces a group
— the dependency graph fed to the group-based strategies is therefore *incomplete*
even when `fold_constants=false`.

**B2. Two parallel state bundles.** `BlockLoweringOpts` (16 `@kwdef` fields) exists
only to be splatted into `LoweringCtx` (23 positional fields) at
`driver.jl:521-529`. Every new knob costs an edit in both plus three construction
sites. `LoweringCtx`'s positional construction is a live hazard: inserting a field
in the middle silently mis-wires all three sites (they pass bare `Ref(0)`,
`Ref(false)`, and several `Dict`s that are structurally interchangeable).

**B3. `_lower_inst!` defeats its own abstraction.** `types.jl:237-286`: every
method immediately destructures `ctx` back into `(ctx.gates, ctx.wa, ctx.vw, …)`
plus 4–8 keyword arguments. The context is a bag that gets unpacked at every use.
Either pass the context down (and let emitters read what they need) or don't have
one.

**B4. Synthetic SSA names as a string namespace.** `lower_divrem!` fabricates
`Symbol("__div_a64_$(inst.dest)")` and stuffs it into `vw` to reuse `lower_call!`
(`aggregate.jl:93-101`). `memory.jl` does the same with `__mux_load_arr_$tag`,
`__mux_store_pred_$tag`, `__persistent_state_$alloca_$n`
(`memory.jl:1000-1004, 1042-1045, 413, 503`). Uniqueness is argued from a
monotonic counter plus a "globally-unique hint" (`driver.jl:515-518`). A real
value-ID type would make this structural rather than lexical.

**B5. The `width == 0` pointer sentinel.** Pointer-typed phi and select are
handled by an early-return branch *inside* `lower_phi!` (`phi.jl:170-200`, 31
lines) and `lower_select!` (`arith.jl:485-514`, 30 lines) keyed on
`inst.width == 0`. Two unrelated computations (wire MUX vs. provenance-set merge)
share one function because the IR uses a magic width instead of a type. Both
branches then hard-code a fan-out budget of `8` (`phi.jl:195`, `arith.jl:509`,
`aggregate.jl:423`, `memory.jl:611`) — four independent copies of the same magic
number.

**B6. `_bvmd_reject_normalised_alloca!`** (`driver.jl:1-102`): a 43-line docstring
and a 58-line fixpoint analysis, executed on *every* `lower()` call, whose entire
purpose is to detect that an *extraction-phase* flag (`ptr_cells`) produced IR the
*gate backend* cannot consume. It is an honest fail-fast, and the docstring is
excellent forensics — but it is a monument to a layering violation. The real fix
is stated in its own text (relax the shadow-tape width check to span
`width ÷ elem_width` slots) and was deferred.

**B7. `_resolve_persistent_impl`** (`memory.jl:209-267`): four arms that the
comments themselves call "byte-template duplicate of the :okasaki wiring", each
with an identical `hashcons === :none` check and an identical NYI throw. 59 lines
that should be a 4-entry `Dict{Tuple{Symbol,Symbol}, Impl}`.

**B8. `@eval`-generated shape helpers.** `memory.jl:978-1072` generates 22
functions plus 3 const dispatch dicts over `_MUX_SHAPES_NW`. The consolidation
(Bennett-lm3x) was the right call versus 22 hand-written copies, but the underlying
question — why is there a fixed table of `(N,W)` shapes at all? — was never asked.
The whole path exists to pack an array into a single `UInt64` and call a
soft-float-style Julia kernel; `_wires_to_u64!` (`memory.jl:1139-1147`) burns 64
fresh wires per operand per access to do it.

**B9. Duplicated compact/non-compact call bodies.** `call.jl:99-135` and
`call.jl:136-171` are ~35 lines each, differing only in `bennett(callee_lr)` vs
`callee_lr` and `loop_check_wires` vs `loop_guards`.

**B10. `lower_loop!`'s (K+1)-th check pass emits real gates.** `cfg.jl:394-401`
re-dispatches every header-body instruction a second time to compute the
convergence bit. The DEVIATION comment (`cfg.jl:365-381`) is first-rate engineering
writing and the analysis is correct — but the *implementation* pays a full extra
copy of the header body in gates rather than restructuring the unroll so the exit
condition is evaluated on post-K state naturally.

**B11. No constant CSE.** `resolve!(::ConstOperand)` (`operand.jl:22-43`) allocates
`width` fresh wires and emits a NOT per set bit, **every time the same constant is
used**. `_fold_constants` mops most of it up afterwards, which is why the default
is `true` — a gate-level optimizer compensating for a missing IR-level one.

### 2.C Complexity that is genuinely justified by the domain

**C1. "Allocate and never free" ancilla discipline.** Under Bennett's construction
the reverse pass restores every ancilla; freeing early is *unsound* unless you also
uncompute early. The docstring at `aggregate.jl:159-172` records an actual failed
attempt (Cuccaro-based `free!` rewrite broke correctness in a way that
`verify_reversibility` did not catch) and correctly identifies the missing
foundation ("Bennett-aware `free!`", Bennett-vt0a). This is not laziness; it is
the correct conservative choice given the absence of a lifetime model. See §5(c).

**C2. Speculative execution of both arms + MUX.** Reversible circuits have no
branches. Computing both sides and selecting is *the* technique. The costs are
real and unavoidable in kind: `h(x,y)` with a 4-arm nested conditional over two
Int8s compiles to 982 gates / 350 wires; the arms alone are ~40 gates each. What
is *not* justified is doing the predicate algebra at gate level (see §5(a)).

**C3. The identity peephole layer** (`arith.jl:59-165`). Detecting `x*1`, `x+0`,
`x&mask` *before* `resolve!` materialises constant wires is exactly right — the
comment's example (`x * Int8(1)` = 692 gates → W CNOTs) is a 30× win, and the
"purely syntactic on IROperand" safety argument is sound. Keep verbatim.

**C4. The fail-loud assertion density.** `resolve!`'s width contract
(`operand.jl:14-18`), the `block_pred` width-1 invariant (`phi.jl:62-64, 117-119`),
`lower_phi!`'s incoming-width validation (`phi.jl:208-213`), the double-free
detector (`wire_allocator.jl:39-50`), `_check_const_shift` (`arith.jl:301-303`).
Each is a scar from a real bug. Port every one.

**C5. The arithmetic library's structure.** Papers cited, cost formulas stated and
regression-tested, non-obvious scheduling decisions proved in comments (the
reverse-level uncompute proof at `parallel_adder_tree.jl:30-49` is genuinely a
correctness argument, not a note). This is what the rest of the codebase should
look like.

---

## 3. Version coupling (Julia 1.12 / current LLVM)

This area is *downstream* of extraction, so direct LLVM-API coupling is nil. The
coupling that exists is of three kinds:

**3.1 Julia reflection internals — the sharpest edge.**
`call.jl:20-47` uses `methods(f)`, `m.sig.parameters`, `Base.isvarargtype`,
and computes arity as `length(params) - 1`. This is undocumented-internal
territory: `Method.sig` shape, `Vararg` representation, and the `typeof(f)`-first
convention are all things that have moved across Julia minors before. On 1.13 this
is the single most likely thing in the area to break. It is also unnecessary:
callees are *registered* (`src/callees.jl`), so the arg-type tuple could be stored
at registration time instead of recovered by reflection.

**3.2 LLVM/Julia IR-shape assumptions baked into lowering.**
- `mul` operand and result widths are equal (`arith.jl:228-243` — 16 lines of
  comment explaining that the `length(full) == W` branch is *unreachable* because
  of this).
- Shift semantics: `arith.jl:295-303` and `arith.jl:333-346` accept `k == W` and
  implement mod-2^⌈log₂W⌉ variable shifts, explicitly relying on **Julia's**
  `<<`/`>>` wrappers emitting a guarded select. A non-Julia frontend (the T5
  C/Rust corpus already exists) gets different semantics from the same code. Julia
  1.13 changing that wrapper would silently change results, not error.
- Phi incoming blocks are direct predecessors (assumed by `_edge_predicate!`; the
  fallthrough at `phi.jl:129-130` is what happens when they are not).
- `sizeof(T)*8` as the bit width of a callee parameter (`call.jl:63`).

**3.3 Things Julia 1.13 would plausibly perturb.**
- `Memory`-backed arrays and the associated codegen changes affect the `alloca` /
  GEP shapes that `memory.jl`'s `_MUX_SHAPES_NW` table and `_pick_alloca_strategy`
  are tuned to. The shape table is a hard-coded lattice; a codegen change that
  emits `(2,64)` or `(16,8)` allocas routes to `:shadow_checkpoint` (O(N·W)
  Toffolis) or `:unsupported` with no warning.
- `_bvmd_reject_normalised_alloca!` exists *because* Julia codegen byte-addresses
  its own stack frames while the alloca arm word-reserves. That's exactly the sort
  of thing 1.13 renegotiates.
- The 22 `@eval`-generated methods plus 3 module-level `getfield(@__MODULE__, …)`
  dicts (`memory.jl:1089-1099`) interact with precompilation; `getfield` at module
  scope during load is fine today but is the kind of thing that trips new
  invalidation/precompile checks.

**3.4 What would get *simpler* on 1.13.** Nothing in this area is waiting on a
Julia feature. The simplifications available are all self-inflicted-complexity
removals, not version-gated ones. The one genuine opportunity is that a
from-scratch rewrite could target `Memory`/`MemoryRef` directly and use a
struct-of-arrays gate buffer without the `Vector{AbstractType}` boxing
(`gates.jl:4`) that costs a pointer chase per gate on a 10⁶-gate circuit.

---

## 4. From-scratch verdict

### 4.1 KEEP verbatim (port as-is, they are the asset)

**The arithmetic circuit library — all 752 lines.** These encode real literature
and real debugging. Precisely:

| File | What to port | Why |
|---|---|---|
| `adder.jl:2-18` | ripple-carry (`5W-2` gates, W carry ancilla) | the baseline every gate count is calibrated against |
| `adder.jl:64-146` | Cuccaro + the Bennett-gsxe §3.5 optimisation | the §3.5 trick (−1 Toffoli at every W≥2, with the W=2 special case) is a real derivation not in the paper; the wire-state contract at `:44-62` is the port spec |
| `adder.jl:149-172` | 2's-complement subtract | trivial but the carry-in NOT placement is load-bearing |
| `qcla.jl` (whole) | Draper-Kutin-Rains-Svore §4.1, all 5 phases in canonical order, `_qcla_level_offsets`, the `W>=4` `n_anc` threshold reasoning at `:49-58` | the crown jewel; cost formulas are stated *and* regression-tested at W∈{4,8,16,32,64} |
| `multiplier.jl:13-33` | shift-and-add widening multiply | plus the Karatsuba post-mortem comment at `:35-42` — port the *comment*, it's the reason not to re-add it |
| `partial_products.jl` | Sun-Borissov §II.C | 60 lines, all contract assertions |
| `parallel_adder_tree.jl` | §II.D + **the reverse-level uncompute schedule and its proof** (`:30-49`) | the paper's schedule is wrong-as-stated; this correction is original work |
| `mul_qcla_tree.jl` | Sun-Borissov Algorithm 3 assembly, 7 steps | the record-and-replay uncompute (`:62-74`) |
| `divider.jl` | `_soft_udiv_compile` / `_soft_urem_compile` as **plain Julia functions compiled through the pipeline** | this bootstrapping idea is the best structural idea in the area — see §4.3 |

Port surface: each is `(gate_sink, allocator, a::WireVec, b::WireVec, W) -> WireVec`,
with preconditions on lengths and a documented post-state for every input register.
None of them touch `ParsedIR`, `LoweringCtx`, `vw`, predicates, or blocks. **They
should be a separate package** (`ReversibleArith.jl`) with the gate sink and
allocator as two small interfaces. That would make the cost formulas testable
without a compiler and make the primitives reusable from Sturm.jl directly.

**Invariants to port as executable checks**, not prose:
- ancilla-zero + input-preservation after Bennett wrap (already enforced by
  `simulate`);
- `resolve!` width contract (`operand.jl:14-18`);
- block predicates are exactly 1 wire (`phi.jl:62-64`);
- WireAllocator: `n >= 0`, no double free (`wire_allocator.jl:15-16, 41-44`);
- constant shift `0 <= k <= W` (`arith.jl:301`);
- the `test_gboa_dirty_bit_hygiene` post-state contracts.

**Tests to port verbatim**: `test_qcla.jl` (the W→(Toffoli,CNOT,anc,tdepth,depth)
table), `test_parallel_adder_tree.jl`, `test_mul_qcla_tree_paper_match.jl`,
`test_zmw3_shift_bounds.jl`, `test_swee_wire_allocator_negative.jl`,
`test_predicated_phi.jl`, `test_s0tn_loop_overflow.jl`, and every exhaustive
256-input Int8 sweep. `test_gate_count_regression.jl` should be *re-derived*, not
copied — the numbers are characterization of the current lowering, and a new
lowering will legitimately produce different ones; what must survive is the
*scaling laws* (`total(2W) == 2·total(W) - 2`, `T(2W) == 2·T(W) + 4`), which are
structural and worth asserting on day one.

### 4.2 DISCARD

- `LoweringCtx` / `BlockLoweringOpts` duality (B2).
- `compute_ssa_liveness`, `op2_dead`, `use_inplace` (A2) — dead.
- `lower_loop!` as a second driver (§1.2.5) — replace with an IR-level unroll pass
  *before* lowering, so there is one block walk.
- `_fold_constants` as a *gate-level* pass (B11/A5) — do it on IR.
- `compact_calls` as a boolean kwarg — it's a call-lowering strategy, not a flag.
- The `width == 0` pointer sentinel (B5).
- `_lower_load_legacy!`'s silent skip (A4).
- `_bvmd_reject_normalised_alloca!` (B6) — fix the underlying width check instead.
- The `@eval` shape table (B8) and `_wires_to_u64!` packing — memory access should
  lower to a shape-generic QROM/QRAM primitive, not to a Julia kernel called
  through the function-inlining path.
- Reflection-based callee arg types (§3.1) — record at registration.
- `Vector{ReversibleGate}` with abstract eltype (`gates.jl:4`).

### 4.3 REDESIGN — the design I would choose today

**Four IRs, four passes, one direction.**

**(1) Normalize (LLVM → LLVM).** Run, before extraction: `mem2reg`, full unrolling
with an explicit trip-count assertion, scalarization, and — the key move —
**`StructurizeCFG` / if-conversion inside LLVM**, so what comes out is
single-entry/single-exit regions with `select`s rather than a general CFG with
phis. LLVM already has the passes; the project is currently reimplementing them
badly at gate level.

**(2) RIR — Reversible IR (the new `ParsedIR` consumer).** Block-free, fully
predicated SSA. Every value carries: bit width, a *guard* (a predicate value, not
a wire), and a lifetime scope. Node kinds: arithmetic ops, `select`, `region`
(compute/uncompute scope, à la Q# `within/apply`, Quipper `with_computed`,
Silq's uncomputation), `alloc`/`consume` for ancilla registers. Two properties are
checkable *here*, without simulating gates:
   - **"exactly one guard fires"** for every select-merge, decidable by BDD/SAT over
     the predicate algebra. This kills the false-path-sensitization class by
     construction (see §5(a)).
   - **ancilla linearity**: every allocated register is either consumed by an
     uncompute or promoted to an output. A linear/affine type discipline on wire
     handles makes `free!` sound (see §5(c)).

**(3) Netlist IR — primitive invocations, not gates.** Instruction selection
targets *primitives* (`RippleAdd`, `QCLAAdd`, `SunBorissovMul`, `QROMLookup`, …),
chosen by a cost model, not by symbol kwargs. Optimizations live here where
structure is intact: identity peepholes, constant CSE, MUX-tree balancing
(log-depth instead of the current linear chain at `phi.jl:155-161`), common
subcircuit sharing, and — critically — *scheduling*, because Toffoli depth is a
scheduling property that the current flat gate list destroys.

**(4) Gate emission.** Netlist → struct-of-arrays gate buffer
(`op::UInt8, w1/w2/w3::Int32`). Reverse pass becomes a reversed memcpy. The
Bennett strategies (already nicely factored into `BennettStrategy` subtypes) plug
in here and consume the netlist's region structure instead of `GateGroup`s
reconstructed post-hoc from gate index ranges.

**Cost model instead of kwargs.** One function
`select(op, width, objective::Objective) -> Primitive`, where `Objective` is a
weight vector over (Toffoli count, Toffoli depth, qubit count). It is a pure
function, table-driven, and *itself unit-testable*. `add=:cuccaro` becomes
`Objective(qubits=1.0)` plus a linearity proof obligation that the compiler
discharges — not a user promise it can't keep.

---

## 5. Specific questions

### (a) Is MUX-based phi resolution after the fact the right design?

**No.** It is if-conversion implemented in the wrong IR, at the wrong time, with
the wrong data structure — and the bug class is a direct consequence of *where*,
not *what*.

The algorithm itself is defensible: path predicates + edge predicates + a MUX
chain, with "exactly one edge predicate fires" as the correctness argument
(`phi.jl:133-141`). It is essentially the standard predication used by VLIW
compilers (Park–Schlansker RK algorithm), and diamond CFGs do work today — I
verified a 4-arm nested conditional (`h`) and a nested-diamond constant select
exhaustively: 0 mismatches.

The problem is that **the mutual-exclusion property is an *argument in a
docstring*, not a checked invariant**, and it is discharged over a data structure
(`preds`/`branch_info`/`block_pred` dicts built incrementally during emission) on
which it cannot be checked. Concretely:

- The property depends on `preds` being exactly the CFG predecessor set, on
  `block_pred` being populated for every predecessor, and on every phi incoming
  block being a direct predecessor. Two of those three are handled by **silent
  fallthroughs** (`phi.jl:58`, `phi.jl:129-130`) rather than assertions.
- The predicates are *wires*. Once emitted you cannot ask "is `P_then ∧ P_else`
  unsatisfiable?" without simulating. The only oracle is exhaustive simulation,
  which is why the failure mode is "works on the tests we wrote, breaks on the
  soft-float overflow path".
- Loop unrolling builds a *separate, iteration-local* predicate world
  (`cfg.jl:251-254`), so the invariant has to hold twice, in two implementations.

**If-conversion at an earlier stage eliminates the class by construction**, in
two independent ways:

1. Do it *in LLVM* (`StructurizeCFG` + speculation), so the extractor never sees a
   phi over a non-trivial CFG — only `select`. `lower_select!` is 5 lines
   (`arith.jl:516-519`) and has no predicate algebra at all. Cost: some CFGs don't
   structurize; those should be refused loudly rather than handled by a fallthrough.
2. Do it *in RIR* with predicates as first-class *values*, and discharge
   "exactly one fires" with a BDD/SAT check over the predicate expressions before
   any gate exists. This is cheap (predicates are tiny boolean formulas over icmp
   results) and it is a *proof*, not a test.

I would do both: (1) for the common case, (2) as the backstop and as the
specification. Additional wins that fall out: the MUX chain becomes a balanced
tree (depth log N vs the current linear chain), `block_pred` disappears from the
23-field context, `_compute_block_pred!`/`_edge_predicate!`/`_and_wire!`/
`_or_wire!`/`_not_wire!` disappear (and with them the per-predicate ancilla wires
that are allocated and never freed, `phi.jl:4-29`), and `lower_loop!`'s
iteration-local predicate duplication disappears.

One caveat worth stating: the current design is *not* naive, and the worklog's
literature survey (`worklog/011_…false_path…`) correctly establishes that no
published reversible compiler solves N-way phi from arbitrary CFGs. The
recommendation is not "someone else solved this" — it is "don't solve it at gate
level; reduce it to a solved problem (structured control flow) upstream."

### (b) The strategy kwarg surface: extension point or combinatorial trap?

**Trap**, and the evidence is already in the repo.

`lower()` takes 13 kwargs (`driver.jl:104-116`) with five separate validation
blocks (`:117-138`). The cross product of `add(4) × mul(3) × target(2) × mem(3) ×
persistent_impl(4) × hashcons(3) × fold_constants(2) × auto_self_reversing(2) ×
compact_calls(2) × use_inplace(2)` is ~27,000 configurations, plus 6 Bennett
strategies above. Symptoms:

- `add=:auto` returns `:ripple` unconditionally (`arith.jl:25`) — the dispatcher is
  a no-op that still costs a threaded kwarg, a ctx field, and an opts field.
- `add=:cuccaro` is unsound (A1); the guard is dead (A2).
- `:karatsuba` shipped, was never selected, and was removed
  (`multiplier.jl:35-42`) — a whole strategy arm that existed only to be deleted.
- `target=:depth` steers `mul` but not `add` (A9).
- `fold_constants` silently disables three Bennett strategies (A5).
- `mem × persistent_impl × hashcons` = 24 combos of which 4 are wired; the other
  20 throw NYI from four byte-identical code arms (B7).
- The gate-count baselines had to be **re-pinned to explicit strategies**
  (CLAUDE.md §6, Bennett-hjwp) precisely because the `:auto` dispatcher's choices
  are not stable enough to regress against. That is the system telling you the
  dispatcher is not a design, it's an accumulation.

The `BennettStrategy` refactor (Bennett-i2ca: abstract type + 6 concrete subtypes
+ dispatch) is the model to follow — it made a symbol-kwarg into a value with a
type. Do the same for `add`/`mul`/`mem`: strategies become values implementing a
`Primitive` interface with declared cost formulas; `:auto` becomes
`select(op, W, objective)` — one pure, tested function. And enforce that every
strategy either satisfies the same contract (inputs preserved, ancillae clean) or
declares its precondition in a form the compiler *checks* (Cuccaro: "op2 must be
dead", checked by the linearity discipline, not promised in a docstring).

### (c) `wire_allocator` + `GateGroup` / `LoweringResult` / `LoweringCtx`: the ancilla-lifetime model

**There isn't one.** What exists is: a bump allocator, an essentially-unused free
list, and a post-hoc attempt to *recover* lifetimes from gate index ranges.

- `WireAllocator` (52 LOC) is a bump counter plus a descending-sorted free list
  with O(n) double-free detection (`wire_allocator.jl:39-50`). `free!` is called
  from 3 places in the entire repo, none in the main lowering path. Effective
  model: *allocate forever*. `lower_mux!` alone burns `2W` wires per invocation
  (`arith.jl:523-524`); `lower_ult!` burns `3W+1` (`arith.jl:450-460`);
  `_cond_negate_inplace!` burns `W+1` per call, three calls per signed division,
  documented as a deliberate leak (`aggregate.jl:150-172`). Measured: the 4-arm
  `h(x::Int8,y::Int8)` uses 350 wires; Int8 `sdiv` reportedly 279,416.
- `GateGroup.wire_start`/`wire_end`/`cleanup_wires` are the retrofit: reconstruct
  "which wires did this SSA op own" from allocator state before/after emission.
  It works only because allocation is monotone — the moment `free!` is used, the
  range is a lie. And the whole thing is discarded by the default
  `fold_constants=true` (A5).
- `LoweringResult` is immutable, so promoting one Bool requires rebuilding all 9
  fields (`driver.jl:368-371`).
- `LoweringCtx` has nothing to do with lifetimes; it's a 23-field parameter bag.

The docstring at `aggregate.jl:159-172` is the honest assessment and I agree with
it: a Cuccaro-based `free!` was tried, broke correctness, and
`verify_reversibility` did *not* catch it (ancilla-zero and input-preservation both
held; the result was negated). That is the strongest possible argument that the
current invariants are necessary but **not sufficient**, and that early freeing
needs a *structural* guarantee rather than a test.

**Redesign:** make ancilla lifetime a type-level property.
- Wire handles are **linear** (affine): a `Reg` must be either uncomputed
  (consumed by its inverse) or promoted to an output. Dropping one is a compile
  error, not a leak.
- Compute/uncompute **regions** in the IR (`within { compute } apply { use }`)
  give the allocator a scope; `free!` becomes sound *inside a closed region*
  because the region's inverse is emitted by construction.
- The allocator then becomes a real register allocator with a live-range interval
  model, and `peak_live_wires` becomes a computed property rather than a
  diagnostic measured after the fact.
- Keep the double-free assertion and the `n >= 0` check — both are scars worth
  keeping.

This is also what unblocks the pebbling strategies: they currently need
`gate_groups` (destroyed by default) and refuse branching LRs entirely
(`types.jl:57-71`). With regions they'd operate on a tree, which is what Knill's
and PRS15's algorithms actually assume.

### (d) The arithmetic circuits — port surface

**KEEP, unchanged, and extract into a standalone package.** Answered in detail in
§4.1. The precise port surface:

```
emit_<primitive>!(sink::GateSink, alloc::Allocator,
                  a::WireVec, b::WireVec, W::Int; opts...) -> WireVec
```
with, per primitive: (i) length preconditions on every input, (ii) a documented
post-state for *every* input register (unchanged / overwritten / dirty), (iii) a
closed-form cost formula in (Toffoli, CNOT, NOT, ancilla, depth, Toffoli-depth),
(iv) a `self_cleaning::Bool` property, (v) a paper citation. Four of the seven
files already have all five; `adder.jl` and `qcla.jl` have them at full rigour.

Two things to fix during the port, both currently pushed onto the caller:
- **Carry-out disposal.** `lower_add_qcla!` returns `W+1` wires and the caller
  slices `[1:W]` (`arith.jl:211`), stranding a dirty wire. Under a region model
  the primitive should either return the carry as a distinct handle the caller
  must consume, or offer a `mod2W` variant that uncomputes it.
- **Truncation.** The `qcla_tree` mul returns `2W` and the caller keeps `[1:W]`
  (`arith.jl:244-250`), stranding W wires and forfeiting the self-reversing
  property (30 lines of comment explain exactly this). A `mul_low` variant that
  uncomputes the high half would restore it.

`divider.jl` deserves special mention: implementing division as a *plain Julia
function* (`_soft_udiv_compile`) compiled through the same pipeline, rather than
as a hand-written gate emitter, is the best structural idea in the area — it is
the same bootstrapping trick as the soft-float library, it's testable against
`Base.div` directly, and it means the divider improves for free whenever the
compiler does. The `_compile`/public split (throw-free kernel for the circuit
path, `DivideError` wrapper for Julia callers, `divider.jl:23-88`) is exactly the
right factoring and should be the template for every future kernel.

---

## 6. Summary judgement

The arithmetic library (752 LOC) is excellent and should be lifted out intact.
The lowering driver (4,241 LOC) is a compiler back end that grew one bead at a
time: seven concerns fused into one pass, two parallel state bundles, two block
walkers, a dead liveness subsystem, a broken public strategy, a silently-coupled
pair of defaults, and a predicate algebra implemented in gates because there was
no IR to implement it in. Almost none of that is stupid — every piece has a
comment explaining exactly why it is there, and the forensics are unusually good —
but the *sum* is a system where the central correctness property (mutual exclusion
of path predicates) cannot be checked except by exhaustive simulation.

If code generation is free, the highest-leverage change is not a better phi
resolver: it is inserting an IR between `ParsedIR` and gates in which predicates
are values, ancillae are linear, and control flow is already structured.
