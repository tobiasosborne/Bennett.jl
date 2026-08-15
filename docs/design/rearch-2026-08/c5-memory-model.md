# c5 — The reversible memory model, end to end

Adversarial architecture review, area C5. Read-only pass over `src/softmem.jl`,
`src/shadow_memory.jl`, `src/fast_copy.jl`, `src/qrom.jl`, `src/tabulate.jl`,
`src/memssa.jl`, `src/lowering/memory.jl`, `src/lowering/aggregate.jl` (load half),
`src/persistent/**`, `src/extract/{heap,dict_vm,vector_vm*}.jl`, plus
`src/callees.jl`, `BENCHMARKS.md`, `benchmark/codegen_sweep_impls.jl` and the
memory test corpus.

---

## 1. What this area actually does

### 1.1 The real model: memory is not modelled

There is no memory model in Bennett.jl. There is a **hand-rolled mem2reg with a
provenance side-table**, plus six unrelated escape hatches that were each bolted
on when the previous one hit a wall.

The core mechanism is this: `LoweringCtx.vw :: Dict{Symbol,Vector{Int}}` maps SSA
names to wire vectors. An `alloca` allocates `elem_width * n_elems` wires and
records `ctx.alloca_info[dest] = (elem_width, n)` plus a `ptr_provenance` entry
(`src/lowering/memory.jl:34-51`). A `store` **rebinds** `ctx.vw[alloca_dest]` to a
new wire vector representing the post-store state
(`memory.jl:1068`, `memory.jl:432`). A `load` reads whatever `ctx.vw[alloca_dest]`
currently points at. Pointers are not values; they are *names carrying a
`Vector{PtrOrigin}`*, where `PtrOrigin = (alloca_dest, idx_op, predicate_wire)`.
GEPs are pure index arithmetic on that side-table
(`src/lowering/aggregate.jl:252-278`, `:336-354`).

That is functional-SSA memory, i.e. exactly what LLVM's own `sroa` + `mem2reg`
produce — and the project *has* those passes wired
(`DEFAULT_PREPROCESSING_PASSES` at `src/extract/entry.jl:23`) but **defaults them
off** (`preprocess=false`). So the compiler reimplements promotion-to-register
badly rather than asking LLVM to do it well. The tiering doc calls this "T0
preprocess"; in practice T0 is dead and everything falls through to T1–T5.

### 1.2 The six models a user program can land in

| # | Trigger | Mechanism | Where |
|---|---|---|---|
| 1 | alloca + **const** index | shadow tape: 3W CNOT store, W CNOT load, one fresh tape slot per store | `shadow_memory.jl:38`, `memory.jl:732` |
| 2 | alloca + **dynamic** index, N·W ≤ 64 | pack all wires into a 64-wire block, `IRCall` a *pure Julia function* `soft_mux_store_NxW`, inline its entire compiled body | `softmem.jl`, `memory.jl:978-1072` |
| 3 | alloca + dynamic index, N·W > 64 | shadow-checkpoint: N per-slot `idx==k` AND-trees × guarded shadow stores, emitted as gates directly | `memory.jl:856-944` |
| 4 | GEP off a **constant global** | QROM (Babbush–Gidney unary iteration) | `qrom.jl:42`, `aggregate.jl:299-305` |
| 5 | dynamic-n alloca under `mem=:persistent` | slab of 576 wires + `IRCall` to `linear_scan_pmap_set/get`; the **array index becomes a map key** | `memory.jl:75-98, 352-576` |
| 6 | anything else pointer-shaped | `_lower_load_legacy!` CNOT-copies from a wire slice, or **silently returns** | `aggregate.jl:531-547` |

On top of that sit two *extraction-phase* models that rewrite the program before
lowering ever sees it:

- `mem=:heap` (`extract/heap.jl`, 2 863 LOC): recognises Julia's GC/`Memory{T}`
  skeleton around a `Vector`/`Array`, proves it dead-or-partitionable, and either
  deletes it wholesale (M1) or **re-roots the element traffic onto a synthetic
  constant-N alloca** (M2/M3) so models 1/3 above can handle it.
- `mem=:vm` (`extract/dict_vm.jl`, `extract/vector_vm*.jl`, ~1 490 LOC):
  recognises `Dict` mutation callees → `IRMapInsert/Get/Delete`, or a dynamic
  `Vector` → `IRAlloca(dyn)+IRVarGEP`. **Bennett cannot lower either.** These node
  types have no handler in `src/lowering/`; they are a feed for a separate
  project (BennettVM). `mem=:vm` isn't even accepted by `reversible_compile`
  (`Bennett.jl:232` allows only `:auto, :persistent, :heap`).

And one orphan: `src/memssa.jl` parses LLVM's `print<memoryssa>` output into
`ParsedIR.memssa`, which **no consumer reads** (grep: only `test_memssa*.jl`
touches it).

`fast_copy.jl` and `tabulate.jl` are not memory at all. `emit_fast_copy!` is a
broadcast primitive for the Sun–Borissov multiplier. `lower_tabulate` is a
whole-function strategy that evaluates `f` on all 2^W inputs and emits one QROM —
it *bypasses* memory entirely and is arguably the most successful "memory"
feature in the tree.

### 1.3 The cost picture (the part that should decide v2)

From `BENCHMARKS.md:96-133` and `worklog/024:91`:

- Shadow store (const idx): **3W CNOT, 0 Toffoli**. W=8 → 24 gates.
- MUX-EXCH store `4x8` (32 bits of state, dynamic idx): **7 122 gates, 2 040
  Toffoli, 2 753 wires** — for one write into a 4-byte array.
- MUX-EXCH store `8x8`: **14 026 gates, 3 952 Toffoli, 5 185 wires**.
- Shadow-checkpoint, 256 slots × 8 bits, one store **and** one load: **48 090
  gates, 13 849 wires** → ≈188 gates per slot per (store+load).

Extrapolating the last row to N=8 gives ≈1 500 gates for store+load, versus
**23 616** gates for the same shape through MUX-EXCH. **The dispatcher's stated
priority rule — "MUX EXCH is preferred for shapes with N·W ≤ 64 (cheaper per-op
cost)" (`memory.jl:143-146`) — is empirically backwards by roughly an order of
magnitude.** Nobody ever benchmarked the two arms against each other on a shared
shape, because `:shadow_checkpoint` is unreachable for N·W ≤ 64 by construction
(`memory.jl:157`).

The reason MUX-EXCH is so expensive is structural, not incidental: the strategy
routes an O(N·W)-gate primitive through a *general-purpose Julia function
compiled by the whole pipeline*, after zero-extending three operands to 64 bits
each (`memory.jl:1139-1166`) and, in the guarded case, promoting one predicate
bit to a 64-wire register (`memory.jl:1127-1134`). Meanwhile `qrom.jl` shows that
the project already knows how to do table lookup in `2(L-1)` Toffoli with
`O(log L)` ancillae, and `benchmark/bc3_qrom_vs_mux.jl` exists specifically to
document that QROM beats MUX trees. That knowledge was never applied to the
writable path.

---

## 2. Antipatterns, tech debt, accidental complexity

I separate genuine defects from complexity the domain forces.

### 2.1 Genuine antipatterns

**(A1) "Soft callee" as a lowering strategy.** `softmem.jl` (354 LOC, 22
registered callees at `callees.jl:85-114`) implements array read/write as pure
Julia functions on `UInt64`, which are then recompiled through extract→lower→
inline for *every store site*. This is a clever trick reused from the soft-float
work, where it is correct (IEEE-754 semantics are genuinely a big program). For
memory it is a category error: a MUX-EXCH is ~N·W Toffolis of *gate structure*,
not an algorithm. The trick costs 50–100× and drags in the 64-bit ABI, the
constant-materialisation path (`_operand_to_u64!`, `memory.jl:1151`), and 22
entries in the global callee registry. It also forces the `N·W ≤ 64` shape
lattice to exist at all — a limit with no physical meaning in a reversible
circuit.

**(A2) Four "single sources of truth" for the same shape list.**
`memory.jl:1082` states "The single source of truth for valid shapes is
`_MUX_SHAPES_NW`". In fact the shape set is written out independently in:
`softmem.jl:285` (load/store generation), `softmem.jl:323-327` (guarded stores),
`memory.jl:967-976` (`_MUX_SHAPES_NW`), and `callees.jl:85-114` (registration, by
hand, one line per callee). Adding a shape requires four coordinated edits; three
of them fail silently (an unregistered callee dies at `lower_call!` time, deep in
an unrelated stack).

**(A3) `mem` is one kwarg with two disjoint meanings.** Extraction-side
`mem ∈ {:auto,:heap,:vm}`; lowering-side `mem ∈ {:auto,:persistent}`
(`lowering/driver.jl:127`). The seam is a literal fudge:
`lower_mem = mem === :heap ? :auto : mem` (`Bennett.jl:367`). Two different
validation functions accept two different symbol sets, and `:vm` is reachable
only by calling `extract_parsed_ir` directly. This is a namespace collision
presented as a feature.

**(A4) `_resolve_persistent_impl` is a 59-line four-way copy-paste**
(`memory.jl:209-267`). The comments themselves say "byte-template duplicate of
the :okasaki wiring" three times. Every arm is `if hashcons === :none; return
X_IMPL; else; throw(NYI); end`. This should be a `Dict{Symbol,Impl}`. Worse, the
`hashcons` kwarg it validates is **entirely dead** — no value other than `:none`
is accepted by any arm, so `hashcons=:feistel` is unreachable public API, and
`src/persistent/hashcons_feistel.jl` (89 LOC, exported) is dead code.

**(A5) `ctx.vw` conflates owned wires with aliases.** `lower_ptr_offset!` sets
`vw[dest] = base_wires[(bit_offset+1):end]` (`aggregate.jl:235`) — an alias into
another value's storage — while `allocate!` results are owned. Nothing in the
type distinguishes them. `emit_shadow_store!` zeroes the primal in step 2
(`shadow_memory.jl:48-50`) before XOR-ing the value in step 3; if `val` ever
aliases `primal`, the store silently writes zero. Today the provenance path makes
that unreachable, but it is unreachable by *accident of routing*, not by
construction. In a system whose stated catastrophe mode is silent miscompile,
that is a real defect.

**(A6) Silent failure in the load path.** `_lower_load_legacy!` returns without
binding `inst.dest` when the pointer is unknown (`aggregate.jl:533-536`) with the
comment "may be pgcstack safepoint load". This directly violates CLAUDE.md §1
(FAIL FAST, FAIL LOUD) and is the single most dangerous line in the area: a
dropped load leaves a dangling SSA name whose later use either crashes far away
or resolves to something stale.

**(A7) Ancilla hygiene is "allocate and forget".** `free!` exists
(`wire_allocator.jl:39`) and is used in exactly two places — `qrom.jl:129` and
`feistel.jl:123`. No memory path frees anything: every shadow store leaks a W-wire
tape, every MUX-EXCH store leaks 4×64 wires plus the callee's entire internal
ancilla set, every shadow-checkpoint store leaks N×W tape wires (L10: 13 849
wires for one store+load). Bennett's reverse pass returns them to zero, but peak
wire count — the metric that matters for the quantum target — is unmanaged.

**(A8) MemorySSA: 143 LOC of regex-parsed, stderr-hijacked, unused analysis.**
`memssa.jl:23-26` regex-matches LLVM's *textual annotation output*, keyed by line
number; `_run_memssa_on_ir` redirects the process's stderr into a pipe to capture
it (`memssa.jl:123-143`). This violates CLAUDE.md §5 ("the LLVM.jl C API walker is
the source of truth — not regex parsing") in the most literal way available, and
the result is never read by any consumer. Delete.

**(A9) Documentation drift where it matters.** `CLAUDE.md:202-207` says
`src/persistent/research/` is "NOT loaded by the Bennett module"; in fact
`persistent/persistent.jl:37-57` unconditionally includes `okasaki_rbt.jl`,
`popcount.jl`, `hamt.jl` and `cf_semi_persistent.jl` — 1 367 LOC of "research"
code on the production load path, reachable from a public kwarg. Similarly
`memory.jl:1082` cites "line 84-95" for an arm now at line 157, and the
strategy-table key order is `(W, N)` while every name is `NxW`
(`memory.jl:1085-1087`) — a transposition trap sitting in the one table that
decides which lowering you get.

**(A10) The persistent arm silently changes semantics.** Under `mem=:persistent`,
an `alloca` of runtime length becomes a *map*, and the GEP index becomes a
**key** into that map (`memory.jl:420-423`: `origin.idx_op` is passed as the
`pmap_set` key). Array semantics and map semantics differ: `linear_scan` stores at
most `max_n = 4` distinct keys and clamps on overflow
(`linear_scan.jl:47-51`), and "absent" is indistinguishable from "stored zero" by
design (`interface.jl:26-33`). So `a[i] = x` for a 100-element array compiles to
a 4-entry map that silently drops writes. There is no capacity check anywhere on
this path. This is the most serious correctness-adjacent finding in the area:
it is not a miscompile of the IR, but it is a miscompile of the *program's
meaning*, and it is reachable from a documented public kwarg.

**(A11) Arbitrary magic numbers as scope boundaries.** `length(origins) <= 8`
for multi-origin store fan-out (`memory.jl:611`) and load
(`aggregate.jl:423`), with the error text "exceeds M2b budget; file a bd issue".
Eight is not a property of anything; it is where someone stopped.

### 2.2 Complexity that is justified

- **QROM's recursive unary-iteration tree with flag free-listing**
  (`qrom.jl:89-131`) is genuinely intricate and genuinely necessary: it is the
  literature-optimal construction, it is self-uncomputing, and it keeps ancilla
  peak at O(log L). Keep verbatim.
- **The shadow-store 3-CNOT protocol** (`shadow_memory.jl:38-55`) is the minimal
  correct reversible write. Its guarded variant (Toffoli per CNOT,
  `shadow_memory.jl:98-120`) is the correct way to make a write conditional.
  Both earn their existence.
- **Predicate-guarding stores in non-entry blocks** is *mandatory*, not
  incidental. In a circuit every block executes; an unguarded store in a
  not-taken branch is a false-path miscompile (CLAUDE.md's named failure mode).
  The M2c/M2d work is real correctness work. What is unjustified is that the
  guard is threaded as an optional `block_label::Symbol=Symbol("")` kwarg through
  six emitters with a "sentinel means entry block" convention
  (`memory.jl:589, 732, 856, 1031`) instead of being a property of the IR.
- **The heap/vm recognisers' fail-loud discipline** is exemplary given the goal.
  The taint-closure-then-prove structure (`heap.jl:551-699`), the explicit
  soundness argument attached to each seed (`heap.jl:602-610`), and the
  "purely subtractive, only ever rejects" invariant are the right way to build a
  recogniser you cannot fully verify. The *strategy* is wrong (see §4); the
  *engineering* is not.
- **Branchless soft callees for soft-float** are justified; the same pattern
  applied to memory (A1) is not. The difference is whether the callee encodes an
  algorithm or a wiring pattern.

---

## 3. Version coupling

**Hard pins to Julia 1.12.** `heap.jl:139-144` asserts
`(VERSION.major, VERSION.minor) == (1, 12)` and errors otherwise. This gate is
called by `_detect_gc_preamble!` (`heap.jl:415`), by `_dict_vm_extract`
(`dict_vm.jl:157`) and by `_vec_vm_extract` (`vector_vm_emit.jl:~37`). **On Julia
1.13, all of `mem=:heap`, `mem=:vm` Dict and `mem=:vm` Vector fail immediately by
design.** That is roughly 4 350 LOC — the entire heap/VM front end — that is dead
on day one of a 1.13 port until someone re-derives the layout constants.

What specifically breaks or must be re-validated:

- `_GC_LAYOUT_TLS_PGCSTACK_OFF = -8`, `_GC_LAYOUT_PTLS_FIELD_OFF = 16`,
  `_GC_LAYOUT_TAG_OFF = -1` (`heap.jl:60-62`) — Julia object/GC-frame layout.
- Mangled-callee regexes: `^j_#_growend!##\d+_\d+$` (`heap.jl:53`),
  `^j_setindex!_\d+$`, `^j__growat!_\d+$`, `^j__deleteat!_\d+$`
  (`heap.jl:281-283`), `^j_getindex_\d+$`, `^j_delete!_\d+$`
  (`dict_vm.jl:89-91`), `^j_throw_inexacterror_\d+$` (`vector_vm.jl:82`). These
  are Julia's *internal name mangling*, not an interface.
- Runtime symbol names: `ijl_gc_small_alloc`, `jl_alloc_genericmemory_unchecked`,
  `julia.gc_loaded`, `julia.gc_alloc_obj`, `julia.get_pgcstack`
  (`vector_vm.jl:76-81`). The `Memory{T}` rework landed in 1.11 and is still
  moving; `gc_loaded`/`gc_alloc_obj` are precisely the parts most likely to
  change shape.
- Inline-asm allowlist `("movq %fs:0, $0", "=r")` (`heap.jl:40-42`) — x86-64
  only. On Apple Silicon or any aarch64 host, `mem=:heap`/`:vm` never worked and
  never will without a second allowlist entry. This is a *host* coupling, not a
  version coupling, and it is not documented in CLAUDE.md.
- The IR shape assumptions are pinned to `optimize=false` for Case A
  (`vector_vm.jl:22-23`: "O2 is a different, SIMD-vectorised program") and to
  `optimize=true` for the heap M1/M2 skeletons (`heap.jl:59`). So the two
  recognisers require *opposite* optimisation settings on the same compiler.

**LLVM coupling.** `memssa.jl` depends on the textual format of
`print<memoryssa>` and on `LLVM.NewPMPassBuilder` (`memssa.jl:134`), plus a
`redirect_stderr` hack that assumes LLVM's raw ostream maps to fd 2. Any LLVM
upgrade can silently change annotation formatting; because nothing consumes the
result, the breakage would be invisible.

**What actually simplifies on 1.13.** Nothing in this area gets easier
automatically. The one genuine opportunity: if v2 abandons IR-recognition of
Julia containers (§4, §5b), all of the above coupling disappears at once, and the
remaining LLVM surface is `alloca`/`load`/`store`/`getelementptr` — the most
stable instructions in the language.

---

## 4. From-scratch verdict

Assume codegen is free. The question is what the right 2026 design is.

### 4.1 KEEP (port close to verbatim)

1. **`qrom.jl` in full** — algorithm, recursion, flag free-listing, the
   power-of-two/width guards, and `test/test_qrom.jl` + `benchmark/bc3`. This is
   the one primitive that is state-of-the-art.
2. **The shadow store/load protocol** (`shadow_memory.jl`) as the *semantics
   definition* of a reversible write, and its guarded Toffoli variant.
3. **`emit_fast_copy!`** — 39 LOC, correct, log-depth broadcast. It belongs next
   to the multiplier, not in the memory tier.
4. **The tabulate strategy idea** (`tabulate.jl`) — "if the input domain is
   small, evaluate classically and emit one QROM" is a genuinely good compiler
   decision and generalises (it should also apply to *sub-expressions*, not just
   whole functions). Keep `_tabulate_auto_picks`'s two-factor heuristic as a
   starting point.
5. **`test/test_memory_corpus.jl`** — the L0–L10 ladder is the closest thing this
   project has to a memory *specification*. Port it verbatim as the v2
   conformance suite, including the RED entries.
6. **Fail-loud recogniser discipline** — if v2 keeps any IR recognition at all,
   keep the "positively classify every instruction; anything unclassified
   rejects" invariant and the per-seed soundness argument.
7. **`verify_pmap_persistence_invariant`'s idea** (`harness.jl:117`) — testing
   that an old snapshot is unchanged after a write is exactly the right test for
   any value-semantics memory. Keep the idea, drop the map.
8. **The gate-count regression discipline** — pinned baselines per explicit
   strategy. This is what makes A1-style regressions detectable at all.

### 4.2 DISCARD

- **`softmem.jl` entirely** (354 LOC) and its 22 callee registrations.
- **`memssa.jl` entirely** (143 LOC) plus `ParsedIR.memssa` and
  `use_memory_ssa`.
- **`src/persistent/**` entirely** (~1 900 LOC incl. research/) — see §5c.
- **`hashcons_feistel.jl`** and the `hashcons` kwarg (dead surface).
- **The `_MUX_EXCH_*` dispatch tables and the `N·W ≤ 64` shape lattice.**
- **The multi-origin ≤ 8 fan-out path** — replaced by making pointers real
  values (§4.4).
- **`extract/heap.jl` as a supported mode** (2 863 LOC). Keep the *file* in an
  `experiments/` directory for its reject messages, which are excellent
  documentation of what Julia's heap looks like; do not ship it as a compile
  path.
- **`_lower_load_legacy!`'s silent-skip branch** — replace with an error.

### 4.3 REDESIGN — the model I would choose

**One memory abstraction: the reversible register file, as a first-class SSA
value.**

```
RegFile{N, W}          # N cells of W bits, N and W statically known
read  : RegFile{N,W} × Idx        -> RegFile{N,W} × Word{W}   (pure)
write : RegFile{N,W} × Idx × Word -> RegFile{N,W}             (value semantics)
```

Properties that make everything else fall out:

- **Memory is a value threaded in SSA form.** No pointers, no aliasing, no
  provenance side-table, no `ptr_provenance`/`PtrOrigin`/`synth_ptr_provenance`,
  no multi-origin fan-out, no ownership ambiguity in `vw`. A pointer-phi becomes
  a value-phi over `RegFile`, handled by the *existing* phi machinery. Note that
  the persistent arm already discovered this — it threads state through
  `IRCall(pmap_set)` and rebinds (`memory.jl:432`) — it just wrapped it in a map
  abstraction it didn't need.
- **Two primitives, both unary-iteration.** `read` is exactly `qrom.jl`'s tree
  with the data CNOTs replaced by CNOTs from the addressed cell's wires:
  `2(N-1)` Toffoli + `N·W` CNOT, ancilla peak `O(log N)`, **T-count independent
  of W**. `write` is the same tree with the leaf action replaced by the
  3-CNOT shadow exchange controlled on the leaf flag: `2(N-1)` Toffoli for the
  tree + `3W` Toffoli at the leaf. Compare with today: a `4x8` write costs 7 122
  gates; this costs ≈6 Toffoli + 24 Toffoli ≈ 30 gates pre-Bennett. That is the
  ~200× the current design is leaving on the table, and it collapses models 1,
  2 and 3 into one implementation with one cost model.
- **Const index is a compile-time specialisation of the same primitive**, not a
  separate strategy (`read`/`write` with a literal index folds the tree away and
  degenerates to today's shadow path automatically).
- **Guards are part of the IR, not a kwarg.** Every effectful op carries a
  `guard :: Predicate` field (defaulting to the entry-block `true`). The lowering
  of `write` consumes it as one extra control on the leaf action. This deletes
  the `block_label=Symbol("")` sentinel convention, the `extern_pred_wire`
  kwarg, the guarded/unguarded callee split, and the 1→64 predicate promotion —
  four separate mechanisms replaced by one field. It also makes the `when(q) do
  ... end` quantum-control case free (§5d).
- **Read-only tables are the same type with a `const` flag**, lowering to
  today's `emit_qrom!` with the data baked into the CNOT pattern. No separate
  `globals` dispatch in `lower_var_gep!`.
- **Capacity is checked at the type level.** `RegFile{N,W}` with `N` static means
  the A10 silent-truncation class cannot exist.
- **Front end: an explicit API is the contract.** `Bennett.RegFile(N, T)` with
  `getindex`/`setindex!` defined to lower to the two primitives, so user code
  still *reads* like Julia. Recognition of raw `Vector`/`Dict` becomes an
  optional, clearly-labelled "best effort" plugin that either succeeds or tells
  you to use the explicit type — never a supported compile mode with a version
  pin.
- **Dynamic N**: one honest answer only. Either (a) require a static upper bound
  (`RegFile{N}` with runtime length ≤ N, length carried as a value), or (b)
  refuse. Do not ship a third thing that silently means something else.

Under this design the memory area is roughly: one `regfile.jl` (~250 LOC,
`read`/`write`/`select_swap` on top of the existing unary-iteration tree), the
kept `qrom.jl`, the kept `shadow_memory.jl` primitives as the leaf action, and a
~150-LOC lowering that maps `alloca`/`load`/`store`/`gep` onto it. Call it 600
LOC replacing ~5 000, with a 10–200× gate-count improvement on the writable path.

**One more thing worth designing in from the start:** a SELECT-SWAP / QROAM
variant (Low–Kliuchnikov–Schaeffer, dirty-ancilla) as a second `read`
implementation trading ancillae for T-count. That is the real Pareto knob for the
quantum target, and it slots into the same interface. Today there is no such knob
because the interface doesn't exist.

---

## 5. Specific questions

### (a) Is it one coherent model or five accreted ones?

**Six accreted ones, plus two extraction-phase rewriters and one orphan.** See
§1.2. The evidence that this is accretion rather than design:

- The dispatch decision is spread across three unrelated layers: an extraction
  kwarg (`mem=:heap/:vm`), a shape table (`_pick_alloca_strategy`), and two
  symbol→function dicts (`_MUX_EXCH_*_DISPATCH`) — with a fourth decision hidden
  in `lower_var_gep!`'s `globals` check.
- Each arm has its own **cost model, own error vocabulary, own guard mechanism,
  and own notion of what an index means** (slot offset in 1/2/3, table index in
  4, map key in 5, byte offset in the extraction-side `IRPtrOffset`).
- The arms disagree about what "unsupported" means: `_pick_alloca_strategy`
  returns `:unsupported` for shapes it doesn't cover, and that symbol is still
  reachable (e.g. `(elem_width=64, n=1)` → 64 bits, not in `_MUX_SHAPES_NW`, not
  >64 → `:unsupported`), producing an error from `memory.jl:683` that names the
  shape but not the fix.
- The persistent arm and the alloca arm use **different context dictionaries**
  (`persistent_info` vs `alloca_info`) with early-out checks scattered at five
  call sites (`memory.jl:666`, `aggregate.jl:203, 314, 483`, `memory.jl:78`),
  each with a comment explaining that the other path would KeyError.

There is exactly one unifying idea in the tree — "memory is an SSA value you
rebind" — and it is implemented three times independently (wire-vector rebinding,
UInt64 packing, NTuple slab threading).

### (b) Is recognising Julia Dict/Vector idioms in LLVM IR viable long-term?

**No, not as a supported compile path. Yes, as an opt-in best-effort plugin.**

The case against, from the code itself:

1. **Cost**: 4 353 LOC across `heap.jl` + `dict_vm.jl` + `vector_vm*.jl` — larger
   than the entire lowering directory — to support a *tiny* program class.
2. **The accepted class is minuscule.** M1: heap collection provably dead (i.e.
   the allocation didn't matter). M2: `Array{T}(undef,N)` with constant N, no
   back-edge (`heap.jl:510-532`), surviving slice straight-line. M3: `push!` with
   statically-inferable count. Case B (Dict): only if `getindex` survives as a
   callee — and `dict_vm.jl:36-58` documents at length that on Julia 1.12.5 it
   **never does** for the canonical `d[k]=v; d[k]` program. So the flagship Dict
   case rejects the flagship Dict example.
3. **The version pin is total** (§3): one minor Julia bump zeroes the feature.
4. **The failure mode is the project's stated catastrophe.** Everything here is a
   heuristic proof that instructions are dead. `heap.jl:14-19` says it out loud:
   a wrong suppression yields a wrong circuit whose ancillae still return to zero,
   so `verify_reversibility` passes. The mitigation (reject on any doubt) is
   correct but means the recogniser's *value* is bounded by how much doubt you
   can eliminate — and doubt grows with every Julia release.
5. **It fights the optimiser both ways**: Case A needs `optimize=false`, heap M1/M2
   need `optimize=true`.

**Expressiveness lost by requiring an explicit API:** very little that works
today. A user writing `v = Vector{Int8}(undef, 16); v[i] = x; v[j]` gets a reject
today under `mem=:auto` and `mem=:heap` (dynamic index into a heap array with a
runtime count is out of scope), and under `mem=:vm` gets IR that Bennett cannot
lower. The same user writing `v = RegFile(16, Int8); v[i] = x; v[j]` would get a
correct, cheap circuit. The genuine loss is **third-party / unmodifiable source**
— you cannot annotate someone else's library — and **non-Julia front ends** (the
C/Rust corpus), where you have no API to offer. For those, keep the recogniser as
a plugin with a loud "unsupported, may break on any toolchain update" banner, and
never let it be the thing a headline feature depends on.

A pragmatic middle: recognise only what LLVM *itself* canonicalises. Run
`sroa`+`mem2reg` (already available at `entry.jl:23`, currently off) and accept
what survives as plain `alloca`/`load`/`store`. That is version-stable, is 0 LOC
of recogniser, and covers the same "small fixed-size local array" class M2 covers.

### (c) What does linear_scan winning at all scales imply for v2 scope?

Three implications, in increasing order of importance.

**First — the headline result is probably an artefact and should not be trusted
as stated.** `worklog/026` reports linear_scan's per-`set` cost is *constant in
max_n* (~1 385 gates at max_n=1000) and attributes it to Bennett.jl "recognising
the no-op slots". Look at the benchmark generator
(`benchmark/codegen_sweep_impls.jl:221-249`): the demo does
`s = pmap_new(); s = set(s, seed+k₀, seed+v₀); s = set(s, seed+k₁, ...)` — the
*keys* are runtime-dependent, but the **write index is not**. `pmap_set` writes at
slot `count` (`linear_scan.jl:50`), `pmap_new` returns all zeros, and `count`
increments deterministically, so at every call site `target` is a **compile-time
constant** and `ifelse(target == i, …)` folds to a static select for all N slots.
The measured "constant per-set cost" is the cost of writing *one statically-known
slot*, i.e. constant folding, not reversible-circuit magic. A workload with a
data-dependent write index would be Θ(max_n) per set. This should be re-measured
before any v2 decision cites it.

**Second — the part of the finding that is real and important** is the cost-model
inversion: popcount is ~2 782 gates, a tree rebalance is thousands, pointer
chasing is meaningless, and *every* classical DS technique that trades work for
indirection loses. `worklog/026:105-113` states it well. Generalised: in
reversible compilation the only cheap operations are those with *uniform,
data-independent structure*. That is the same reason unary iteration beats MUX
trees, and it is a design law for v2, not a data-structure result.

**Third — the scope implication.** The persistent-map workstream produced: an
interface, a harness, four implementations (three of them "research" but loaded),
a dispatcher arm, a `mem=:persistent` kwarg with two dead sub-kwargs, and the
conclusion *"the trivial one wins."* That is a research negative result, correctly
obtained, and it should be **written down in a doc and deleted from the
compiler**. Concretely for v2:

- No persistent data structures in the compiler. `RegFile{N,W}` with value
  semantics *is* a persistent array, at 2(N-1) Toffoli per op, and its old
  snapshot survives for free because Bennett's tape keeps it.
- If a user wants a map, they write one against `RegFile` in user code and pay
  for it. The compiler should not have opinions about hash tables.
- Keep `verify_pmap_persistence_invariant`'s test *shape* for `RegFile`.
- The 1.38M-gate / 3.4 GB / N=1000 data point is the useful artefact: it is the
  measured ceiling of what the current architecture can compile, and any v2
  should beat it by ≥50× on the same workload as an acceptance criterion.

### (d) What memory abstraction would you design today for the Sturm.jl goal?

The target is `when(qubit) do f(x) end` — i.e. every compiled circuit must be
liftable to a **controlled unitary**, and `f` may touch memory. That constrains
the memory design far more than the classical case does. My design:

1. **`RegFile{N,W}` as an SSA-threaded value** (§4.3). Value semantics is
   non-negotiable for quantum control: a controlled write must be a no-op on the
   `|0⟩` branch *and* leave no residue, which is only expressible if "the state
   after the write" is a distinct value from "the state before".

2. **Every effectful op carries an explicit guard operand.** `ControlledCircuit`
   (`src/controlled.jl`) already lifts a whole circuit by adding a control to
   each gate — that is the sledgehammer. With a guard field, lifting a memory op
   costs *one extra control on the leaf action of the unary tree*, not a control
   on all 2(N-1) tree Toffolis. Guards must compose (`guard ∧ qubit`) so nested
   `when` blocks don't multiply cost. This is the single most important design
   decision for the Sturm goal, and today it is a kwarg with a sentinel default.

3. **Ancilla accounting as a first-class output.** `peak_live_wires` exists in
   `diagnostics.jl`; it must become a *contract*, with `free!` actually used and
   a per-op ancilla bound in the type (`read` costs `⌈log₂N⌉` borrowed ancillae
   and returns them). On real hardware, peak qubits dominates gate count. Today
   the memory paths leak by construction (A7).

4. **Explicit uncompute policy per region.** Bennett's global forward/copy/reverse
   is the wrong granularity for memory-heavy code: a `RegFile` that is written
   once and read many times wants a checkpoint, not a full replay. The
   `BennettStrategy` machinery already exists; memory ops should expose their
   uncompute cost so a strategy can choose. This is the "pebbling with real cost
   data" story the pebble/ directory was aiming at.

5. **A `Measured`/`Classical` distinction at the type level** — for Sturm, some
   indices will be classically known at circuit-construction time and some will
   be in superposition. `RegFile.read` with a classical index is free
   (compile-time slice); with a quantum index it is the full unary tree. That
   distinction should be in the type, not discovered by
   `idx_op isa ConstOperand` at `memory.jl:149`.

6. **Refuse dynamic allocation, loudly and permanently.** A quantum register file
   whose size depends on a superposed value is not a thing. Static `N` (with
   runtime *length* ≤ N as a carried value) is not a limitation to apologise for;
   it is the honest model. Delete `mem=:persistent`, `mem=:heap`, `mem=:vm` and
   the four documents that promise otherwise.

The one-sentence version: **today memory is six strategies behind a pointer
side-table; it should be one type behind two unary-iteration primitives, with the
control predicate in the IR.**

---

## Appendix — highest-value concrete citations

| Finding | Location |
|---|---|
| MUX-EXCH ~50–100× more expensive than the "fallback" it preempts | `BENCHMARKS.md:106-117` vs `worklog/024:91`; rule at `src/lowering/memory.jl:143-157` |
| 4 uncoordinated shape lists claiming one SoT | `softmem.jl:285`, `softmem.jl:323`, `lowering/memory.jl:967`, `callees.jl:85` |
| `mem` kwarg means two different things; fudged at the seam | `Bennett.jl:232, 367`; `lowering/driver.jl:127` |
| Array→4-entry map with silent write loss under `mem=:persistent` | `lowering/memory.jl:420-423`; `persistent/linear_scan.jl:47-51` |
| Silent skip in load lowering (violates §1) | `lowering/aggregate.jl:533-536` |
| Julia 1.12 hard pin gating all heap/vm modes | `extract/heap.jl:139-144` (called from `dict_vm.jl:157`, `heap.jl:415`) |
| x86-64-only inline-asm allowlist | `extract/heap.jl:40-42` |
| Unused, regex-parsed MemorySSA (violates §5) | `memssa.jl:23-26, 123-143` |
| `research/` claimed unloaded, actually on the load path | `CLAUDE.md:202-207` vs `persistent/persistent.jl:37-57` |
| 4× byte-template duplication + dead `hashcons` surface | `lowering/memory.jl:209-267` |
| `free!` used nowhere in the memory paths | `wire_allocator.jl:39`; only callers `qrom.jl:129`, `feistel.jl:123` |
| Strategy table keyed `(W,N)` while all names are `NxW` | `lowering/memory.jl:1085-1087` |
| Persistent-DS "constant per-set" likely a constant-folding artefact | `benchmark/codegen_sweep_impls.jl:221-249` + `persistent/linear_scan.jl:50` vs `worklog/026:42-64` |
