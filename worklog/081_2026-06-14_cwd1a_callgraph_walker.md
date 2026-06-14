# 081 — 2026-06-14 — CW-D1a — transitive_callees typed call-graph walker

**Bead:** `bennettvm-416r.11` (CW-D1, BVM beads) — chunk **a** of three (D1a walker
/ D1b per-callee extraction / D1c BVM linkage). The path to **SC9 Case B**
(reversible `Dict`, bead `bennettvm-7xa`) — the last open SC9 motivating case.
**Design:** BennettVM `docs/adr/0021-julia-callgraph-extraction.md` (ACCEPTED),
**Decision 1 amended this session — see below.**
**Code home:** Bennett.jl front-end (`src/extract/`). This is a Rule-14
cross-repo change made under the standing autonomous directive (2026-06-14);
**additive** (one new file + one `include` line), zero edits to existing
functions/structs/dispatch tables.

## What landed
- **NEW `src/extract/callgraph.jl`** (~140 LOC): `transitive_callees(f, argtypes)`
  returns the transitive `:invoke` callee closure (root EXCLUDED, discovery
  order, deduped) as `(callee_key, Tuple{argtypes...})` pairs; `mi_of` version
  shim; `_invoke_callees`; internal `_transitive_callee_specTypes` (Set, for
  tests). No `export`, no LLVM.jl — operates on `code_typed`/inference only.
- **`src/ir_extract.jl`**: one `include("extract/callgraph.jl")` after `callees.jl`.
- **NEW `test/test_d1a_transitive_callees.jl`** (Gates 1–6); registered in `runtests.jl`.

## MATERIAL ground-truth correction (Law 1 / Rule 5/9 — write this down)
ADR-0021 Decision 1 said callgraph edges come from *"the SAME O0 inference run
that produced the body."* **That is FALSE on Julia 1.12.5.** Freshly probed:
- `code_typed(fdict, Tuple{Int8,Int8}; optimize=false)` has **ZERO `:invoke`
  statements** — calls appear as dynamic `:call` Exprs with no CodeInstance.
- The `:invoke` edges (carrying a `Core.CodeInstance` arg-1) materialize **only
  at `optimize=true`**.
So the walker harvests **edges @ optimize=true**, while callee **bodies** are
still extracted **@ optimize=false** (that is D1b's job). A verbatim-ADR
implementation returns an empty closure. **Gate 5** is a permanent tripwire:
`!isempty(transitive_callees(fdict, …))` flips red if anyone "fixes" this back
to O0. ADR-0021 amended (Amendment A) in the BVM repo this session.

## Ground truth (fdict, Julia 1.12.5)
- Closure = exactly `{setindex!(Dict{Int8,Int8},Int8,Int8),
  ht_keyindex2_shorthash!(…,Int8) [self-recursive], rehash!(…,Int64),
  AssertionError(String)}` — 4 callees, 8 `:invoke` edges (a DAG, not a chain:
  setindex! calls BOTH ht_keyindex2_shorthash! AND rehash!).
- `mi_of`: on ≥1.11 `:invoke` arg-1 is `Core.CodeInstance`; `.def` → the
  `MethodInstance`; `.specTypes` is the recursion key. `mi_of(::CodeInstance)=.def`,
  `mi_of(::MethodInstance)=identity`, `@nospecialize` → fail loud (Rule 1).
- **Length witness CONFIRMED**: `rehash!`'s O0 body calls
  `jl_alloc_genericmemory_unchecked` with the backing length as an `i64` arg
  (6 sites). The "missing length witness" that blocked Case B on 2026-06-08
  exists one level down the callgraph — closed-world extraction reaches it.

## Method (3+1, CLAUDE.md §2)
Design pass (workflow): fresh ground-truth probe → 2 blind Opus proposers →
synthesis. Conflicts decided: (1) **exclude root** (match the name + the
4-element gate); (2) **uniform `Base.code_typed_by_type(specTypes; optimize=true)`**
(the `Type{AssertionError}` constructor key can't re-split into a callable for
the 2-arg `code_typed`). Opus implementer → orchestrator (+1) review + hostile
review. Hostile findings fixed before commit:
- **S1** — documented the **closed-world boundary as a contract** in
  `_invoke_callees`: `:invoke`-only; `:foreigncall`/dynamic-`:call`/Builtin are
  intentionally dropped; this is a typed-callgraph closure, NOT a complete leaf
  inventory; runtime-intrinsic COMPLETENESS is CW-D2's job, enforced fail-loud
  at D1b/D2 set-assembly (ADR-0021 Decision 2). A consumer treating this as the
  full body set would SILENTLY MISS alloc/`_growat!` helpers.
- **S2** — renamed the test fixture `fdict` → `fdict_d1a` (runtests includes all
  files into one module; a bare `fdict` couples dispatch with
  `test_bd5f_heap_m4.jl`'s `fdict`).
- **N1** — Gate-2 `count(==, Set)` was tautological (Set can't hold dups); the
  real dedup proof is the single appearance in the dup-capable *vector*.
- **N3** — `include` comment alignment.

## Gates (run by me, fresh subprocess — never a subagent's claim)
- `test/test_d1a_transitive_callees.jl`: **15/15**.
- `using Bennett`: clean precompile + load (70s).
- `test/test_gate_count_regression.jl`: **39/39** (lowering untouched — additive).
- Full `Pkg.test()` deferred to the pre-push gate: the change is additive +
  caller-less (nothing invokes `transitive_callees` yet — D1c wires it in), so
  the integration surface is precompile (verified) + the new test (green).

## Rule-14 / pin
Additive Bennett.jl front-end under standing approval. BVM (`../Bennett.jl` path
dep) does NOT consume the walker yet, so its suite is unaffected;
`BENNETT_JL_PIN.md` repin is **deferred to D1c** (when BVM ingests the set and I
validate BVM's full suite against the new Bennett.jl HEAD) — don't bump the
"tested-against" pin before actually testing against it.

## Next
**CW-D1b** (`bennettvm-416r.11` chunk b): per-callee O0 body extraction + set
assembly `extract_parsed_ir_set_from_julia(f, argtypes) -> Vector{Pair{Symbol,ParsedIR}}`
(mirror the ADR-0020 C-track `extract_parsed_ir_set_from_ll` producer). Known
D1b risk (flagged by D1a): `_extract_parsed_ir_cached`'s key is typed
`f::Function` — the `Type{AssertionError}` constructor callee is not a
`Function`; route it through the untyped `extract_parsed_ir` path or widen the
cache key.
