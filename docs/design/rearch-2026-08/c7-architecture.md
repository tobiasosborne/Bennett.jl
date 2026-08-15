# C7 — Whole-system architecture: altitude, staging, and the substrate question

**Reviewer:** agent c7 (architecture)
**Scope:** `src/Bennett.jl` in full; headers of all 31 top-level `src/*.jl`; `CLAUDE.md`;
`Bennett-VISION-PRD.md`; `Bennett-ReversibleVM-PRD.md`; the sibling `BennettVM.jl`
(README, `BENNETT_JL_PIN.md`) and `/home/tobias/Projects/bennett` (TS/Wasm PRD).
Read-only pass over the repo at `980805d`; 39,098 LOC `src/`, 49,878 LOC `test/`,
635 commits, 2026-04-11 → 2026-08-14.

---

## 1. What this area actually does — the real design

### 1.1 The declared pipeline vs. the built one

`CLAUDE.md:61-77` declares four stages: extract → lower → bennett → simulate. That is
true of the *data flow* and false of the *architecture*. What is actually built is:

```
f, Tuple{Int8}
  │  reversible_compile (7 overloads; 13 kwargs)                       Bennett.jl:104-575
  ├─ strategy=:tabulate short-circuit ──► classical eval → QROM ──► bennett   (×2 sites)
  │  InteractiveUtils.code_llvm → **String**                          entry.jl:59
  │  parse(LLVM.Module, ::String)                                     entry.jl:96
  │  conditional pass-pipeline mutation (sroa/mem2reg if sret present) entry.jl:98-105
  │  _module_to_parsed_ir  ── mem=:auto|:heap|:vm|:persistent, ptr_cells=Bool
  │     ├─ _detect_gc_preamble! / _recognise_skeleton  (2,863 LOC)     heap.jl
  │     ├─ dict_vm / vector_vm recognisers (5 files, 1,201 LOC)
  │     ├─ sret detect+synthesise (1,518 LOC)                          sret.jl
  │     └─ _convert_instruction (8,143 LOC, 65 fns, 581 bead refs)     instructions.jl
  ▼  ParsedIR  (21 IRInst node types)                                  ir_types.jl
  │  _narrow_ir (optional width rewrite)                               narrow.jl
  │  reversible_compile(::ParsedIR) → global memoised cache            Bennett.jl:410
  │  target=:reversible_vm ──► Ref{Any} hook ──► BennettVM.lower_vm     Bennett.jl:419,490
  │  lower(parsed; 10 kwargs)                                          driver.jl:104
  ▼  LoweringResult (gates + GateGroups + wire partition + loop guards)
  │  bennett(lr; strategy=DefaultStrategy|Eager|ValueEager|Checkpoint|Pebbled|PebbledGroup)
  ▼  ReversibleCircuit  ── validated wire partition (in/out/ancilla/loop-check)
     simulate / verify_reversibility / gate_count / toffoli_depth
```

So the real architecture is a **five-stage pipeline with two escape hatches
(`:tabulate`, `:reversible_vm`), two caches, and a front-end that is not an LLVM IR
reader but a Julia-codegen-shape recogniser.**

### 1.2 Altitude: this package holds three unrelated altitudes in one flat namespace

`src/Bennett.jl` is 583 lines and `include`s 40 files into one namespace. Three distinct
things live there:

1. **A compiler** (extract → ParsedIR → lower → bennett). ~22k LOC.
2. **A reversible-circuit combinator library** (`gates.jl`, `adder.jl`, `qcla.jl`,
   `multiplier.jl`, `mul_qcla_tree.jl`, `qrom.jl`, `feistel.jl`, `fast_copy.jl`,
   `compose.jl`, `controlled.jl`, `dep_dag.jl`, pebbling strategies). ~3k LOC. This has
   *no dependency on LLVM at all* and would be a perfectly good standalone package.
3. **Two Julia-source libraries that exist to be compiled, not called**
   (`src/softfloat/` 35 files ~7k LOC, `src/persistent/` 10 files, `softmem.jl`,
   `divider.jl`). These are *input programs* to the compiler that happen to ship inside
   it, registered as callees at load time (`callees.jl`).

Category 3 is the most interesting altitude confusion. `soft_fadd` is not compiler code
— it is a *Julia program* that the compiler compiles. It lives in `src/` and is
`export`ed at `Bennett.jl:81` (35 names on one line). The soft-float library and the
compiler are coupled only by the callee registry (`extract/callees.jl:3`,
`_known_callees::Dict{String,Function}` guarded by a lock). Everything else about that
coupling is accidental.

Only 24 of 33 `src/` files touch `LLVM.` at all, and 19 of those are `src/extract/`. The
LLVM dependency is *already* well-confined — that is genuinely good and under-recognised
in the project's own self-description.

### 1.3 Staging: what is actually a "stage" and what is a smear

The stage boundaries are declared but not enforced. Three concrete smears:

- **`mem` is a four-valued symbol that means different things in different stages.**
  `:heap` is an *extraction* flag (turns on `heap.jl`'s recogniser); `:persistent` is a
  *lowering* flag (picks a data-structure impl); `:vm` is a *backend* flag; `:auto` is
  both. `Bennett.jl:366-367` literally normalises `mem === :heap ? :auto : mem` before
  forwarding to `lower()` because the same symbol cannot legally cross the boundary.
  That line is a stage boundary being hand-patched at the call site.

- **`ptr_cells` is documented as an extraction flag but is a backend selector.**
  327 references in `src/extract/`, 5 in `src/lowering/` + `Bennett.jl`. It is not even
  exposed on `reversible_compile` — the Julia path threads it through
  `_parsed_ir_from_ir_string`. `driver.jl:1-102` is a 100-line docstring plus predicate,
  `_bvmd_reject_normalised_alloca!`, whose *entire job* is to detect a ParsedIR shape that
  the extractor emits **only for BennettVM's cell map** and refuse to lower it to gates.
  This is the clearest layering failure in the codebase: the gate backend now contains a
  hand-written recogniser for an artefact of the other backend's addressing model.

- **`self_reversing` is inferred in `lower()` and consumed in `bennett()`.**
  `GateGroup.is_self_reversing` (`lowering/types.jl:29-38`) is a producer tag that
  propagates to `lr.self_reversing`, which halves gate counts. The correctness argument
  is partly structural, partly a *runtime probe* (`auto_self_reversing`, U03). That is a
  cross-stage optimisation with a dynamic soundness check, kill-switched by a kwarg
  (`Bennett.jl:148-153`). It works, but it means "is this circuit self-cleaning" is not a
  property of the IR or the circuit — it is a property of the pipeline's belief state.

### 1.4 The substrate, precisely stated

Bennett does **not** compile LLVM IR. It compiles *the textual LLVM IR that Julia's
`code_llvm` prints for one method instance*, re-parsed into a fresh `LLVM.Context`:

```julia
ir_string = sprint(io -> code_llvm(io, f, arg_types; debuginfo=:none, optimize, dump_module=true))
...
mod = parse(LLVM.Module, ir_string)                              # extract/entry.jl:59, 96
```

Three consequences the project's own documentation does not state plainly:

1. It round-trips through **text**, which `CLAUDE.md:25` explicitly warns is not a stable
   API — and then the C-API walker is called "the source of truth". The walker is honest;
   the *serialisation into it* is not.
2. The default is `optimize=true` on the public entry (`Bennett.jl:272`,
   `entry.jl:56`), while the entire closed-world/heap machinery is built for
   `optimize=false` (`sig_llvm.jl:61`, `julia_set.jl:360`, `callgraph.jl:48-54`). There
   are therefore **two substrates**, with an explicitly documented "optimize skew": call
   edges are harvested at O2 (at O0 there are zero `:invoke`s), bodies extracted at O0.
3. The thing being recognised is not LLVM but **Julia's runtime ABI**. Census of
   Julia-runtime symbol names hard-coded in `src/extract/`: `julia.gc_alloc_obj` (47
   sites), `jl_global` (37), `ijl_gc_small_alloc` (33), `julia.gc_loaded` (17),
   `jl_alloc_genericmemory_unchecked` (14), `julia.get_pgcstack` (9),
   `julia.write_barrier`, `julia.safepoint`, `julia.push_gc_frame`. Plus regexes over
   Julia's *name mangling*: `_GC_GROWEND_CALLEE_RE = r"^j_#_growend!##\d+_\d+$"`
   (`heap.jl:53`), `_M4_DICT_SETINDEX_RE = r"^j_setindex!_\d+$"` (`heap.jl:281`).

That last point is the architectural crux of this review. **The "LLVM IR level, therefore
language-neutral" claim in `Bennett-VISION-PRD.md` §1 is true of `src/lowering/` and false
of `src/extract/`.** The Enzyme analogy holds for the back half of the compiler and breaks
for the front half, because Enzyme differentiates *values* and Bennett must
*reverse memory*, and Julia's memory model reaches Bennett only as GC intrinsics and
mangled runtime calls.

### 1.5 The sibling: BennettVM.jl

BennettVM is a **second lowering target, not a fork** — semantically distinct (a reversible
interpreter with a three-layer history tape vs. a fixed permutation circuit). The coupling
is well designed at the *mechanism* level and badly at the *contract* level:

- Mechanism (good): BennettVM depends on Bennett; Bennett names BennettVM nowhere. A
  `Ref{Any}` write-once hook (`Bennett.jl:413-419`) registered from BennettVM's `__init__`.
  `target=:reversible_vm` without `using BennettVM` errors loudly (`Bennett.jl:490-495`).
  This is the right shape for a plugin backend.
- Contract (bad): `Manifest.toml` carries a **path dependency**, so BennettVM builds
  against whatever is checked out in `../Bennett.jl` — `BENNETT_JL_PIN.md:6-19` says so
  explicitly ("the pin is documentary… the Manifest imposes no revision constraint").
  ParsedIR is a shared, unversioned, structurally-typed interchange format between two
  repos with two bead trackers and two worklogs. Every `IRInst` field addition
  (`IRPtrOffset.elem_width`, `IRInsertValue.field_widths`, the void `IRRet`) is a
  cross-repo ABI change managed by prose in a markdown file.
- Direction of pull (important): reading worklogs 094-106, **BennettVM is now the main
  consumer driving Bennett's front-end work.** Ten consecutive beads with zero BennettVM
  source changes, all Bennett-side extraction work, all in service of getting a
  BennettVM corpus to extract. Bennett.jl's front-end roadmap is de facto owned by the VM.

A third sibling, `/home/tobias/Projects/bennett` (TypeScript/WebAssembly, PRD only, no
code) proposes the *same* pipeline with Wasm substituted for LLVM — "everything else…
is the same algorithm". That PRD is, unintentionally, the strongest available argument
that the substrate is replaceable and that the valuable core is `lowering/` + `bennett` +
the circuit library, not `extract/`.

---

## 2. Antipatterns, tech debt, accidental complexity

I separate these into **(A) genuine antipatterns**, **(B) justified domain complexity that
merely looks bad**, and **(C) the one structural problem that dominates everything else.**

### (C) The dominating problem: `src/extract/` is a per-bug recogniser accretion

`src/extract/instructions.jl` is **8,143 lines, 65 functions, 581 `Bennett-xxxx` bead
references in one file.** Its function names are bead IDs, not concepts:

```
_57hd_canon, _57hd_clobbered, _57hd_write_footprint, _57hd_roots_disjoint,   # instructions.jl:2010-2575
_foz5_cert_src_kind, _foz5_i1_confined, _foz5_confined_dead_bounds,          # :1546-1843
_p06b_alloca_cells, _p06b_alias_group, _p06b_granularity_violation,          # :853-1277
_jbko_identity_use_violation, _bvmd_root_ref, _5viz_singleton_load,          # :2576-3117
```

with per-bead magic constants: `_57HD_DEPTH = 8`, `_57HD_SCAN_CAP = 512`,
`_57HD_ESCAPE_DEPTH = 4`, `_57HD_ME_KNOWN_MASK = 0b111111`, `_FOZ5_DEPTH = 8`,
`_FOZ5_CLOSURE_CAP = 32`, `_BVMD_ROOT_DEPTH = 8` (`instructions.jl:218, 1657-1659,
2010-2027`). Seven independent bounded-depth pointer-provenance walkers, each with its own
depth cap, each written by a different agent-session for a different failing corpus program.

`heap.jl` (2,863 LOC) is the same pattern one level up: `_recognise_skeleton`,
`_prove_skeleton_dead`, `_partition_skeleton`, `_prove_partition_sound`,
`_recognise_growend_array`, `_collapse_growend_diamond`, `_infer_growend_capacity`,
`_m3_skeleton`, `_m3_value_phi_redirects`, `_prove_growend_partition_sound`. This is a
*hand-written alias analysis and dead-region prover* for one language's GC skeleton,
written against `optimize=false` output, with an inline-asm allowlist
(`_GC_TLS_ASM_ALLOWLIST`, `heap.jl:40`) and hard-coded frame offsets
(`_GC_LAYOUT_TLS_PGCSTACK_OFF = -8`, `_GC_LAYOUT_PTLS_FIELD_OFF = 16`,
`_GC_LAYOUT_TAG_OFF = -1`, `heap.jl:60-62`).

**This is not a code-quality complaint. It is an asymptotic complaint.** See §5(c).

### (A) Genuine antipatterns

**A1. Triplicated kwarg surface with hand-maintained validation.**
`reversible_compile` has 7 methods (`Bennett.jl:104, 271, 467, 541, 559`, plus the
Float64 pair in `softfloat_dispatch.jl`). The Tuple overload enumerates 13 kwargs
(`Bennett.jl:271-285`), each defaulting to a field of `_DEFAULT_COMPILE_OPTIONS`; the
ParsedIR overload enumerates 10 of them again (`:467-478`); the `CompileOptions` overloads
then unpack the *same* 13 fields by hand (`:541-575`). On top of that sits
`_reject_unknown_kwargs` (`:173-196`) — a hand-rolled reimplementation of kwarg
validation, driven by two hand-maintained const tuples `_TUPLE_OVERLOAD_KWARGS` and
`_PARSED_OVERLOAD_KWARGS` (`:265, 395`) that must be kept in sync with the signatures they
describe. Adding one option touches six places. `CompileOptions` was introduced (U161) to
be the "single source of truth for defaults" and became a *fourth* copy instead of
replacing the other three.

**A2. Duplicated dispatch logic with a copy-pasted carve-out.**
The tabulate short-circuit appears twice, `Bennett.jl:343-351` and `:371-377`, each with
its own copy of the `target !== :reversible_vm` guard, the width computation, and the
`lower_tabulate(...) |> bennett` call. The comment at `:340-342` explains the carve-out
once and the code implements it twice.

**A3. Module-level mutable global state, five instances, no session object.**
`_compile_cache` + lock (`Bennett.jl:410-411`), `_parsed_ir_cache` + lock
(`extract/callees.jl:37-38`), `_known_callees` + `_known_callee_names` + lock
(`callees.jl:3,121`), `_REVERSIBLE_VM_BACKEND` (`Bennett.jl:419`). The compile cache is
keyed on `objectid(parsed)` — identity, not content — and the docstring
(`Bennett.jl:443-465`) has to warn that `ReversibleCircuit` is "effectively immutable" and
that `register_callee!` can silently return a stale circuit unless you call the exported-
by-underscore `_clear_compile_cache!()`. A compiler should thread a `CompilationSession`,
not mutate module globals under locks.

**A4. Tagged unions faked with sentinel field values.**
`IRInsertValue` / `IRExtractValue` carry a documented discriminator convention: "empty
`field_widths` ⇒ homogeneous, `elem_width`/`n_elems` authoritative; non-empty ⇒ StructType,
`elem_width == 0` sentinel" (`ir_types.jl:133-169, 363-389`). `IRRet` has two shapes
distinguished by `op === nothing && width == 0`, with two constructors, one of which
*must* keep rejecting `width=0` (`ir_types.jl:105-131`). `IRPtrOffset.offset_bytes` means
bytes everywhere *except* the `mem=:heap` re-rooter where it holds an element index — and
this is documented in the struct's own comment as a known lie
(`ir_types.jl:221-226`). Three different node types where a sum type was needed. The
project already did the right thing once — `IROperand` was converted from a
`kind::Symbol` tagged union to an abstract type with concrete leaves (U68,
`ir_types.jl:572-600`) — and then did not apply the lesson to the instruction types.

**A5. Fail-fast doctrine with silent-skip exceptions in the most dangerous file.**
`CLAUDE.md:17` is absolute ("Assertions, not silent returns"). `lowering/phi.jl:56`:
`haskey(block_pred, p) || continue  # skip if predecessor has no predicate (loop)`. A
silently dropped predecessor contribution in the *path-predicate* computation is precisely
the false-path-sensitization failure mode that `CLAUDE.md:49-59` singles out as the
project's top correctness risk. Two lines below it, two `AssertionError`s guard *other*
properties of the same loop. The doctrine was applied where a bug was found and not where
one wasn't.

**A6. Load order as an undocumented dependency graph.**
`Bennett.jl:13-16, 39-54` encode the module DAG in `include` order with explanatory
comments ("deps that lower.jl forward-references load BEFORE lower.jl so the file is
standalone-loadable"). `ir_extract.jl` and `lower.jl` are pure include-manifests whose
comments say "Loading order matches the original textual order so that all parse-time
references resolve in the same order they did pre-split". The split into `extract/` and
`lowering/` was a *textual* split of two monoliths (2,946 and 3,172 LOC) that preserved
their order rather than their structure — so the files are directories now, but the
coupling graph is unchanged and is expressed only in comments.

**A7. Documentation drift in the file that claims to be non-negotiable.**
`CLAUDE.md:121` lists `src/ir_parser.jl # legacy regex parser (backward compat)` — the
file was deleted 2026-04-25 (`Bennett.jl:5-7`). `CLAUDE.md:95` says `extract/ (18)`;
actual is 19 (`sig_llvm.jl` added by Bennett-40ys, unlisted). `CLAUDE.md:19` mandates the
3+1 agent protocol for changes to "`ir_extract.jl`, `lower.jl`" — both of which are now
20-line manifests, so the rule's named referents no longer contain any logic while the
8,143-line file that does is not named. The governance rule and the code drifted apart.

**A8. A test suite whose shape encodes its bug history.**
191 of 324 test files are named `test_<beadid>_*.jl`. That is a 1:1 bug-to-file mapping,
not a specification. It is excellent regression insurance and near-useless as a
description of intended behaviour — which matters enormously for a rewrite (§4).

### (B) Complexity that is justified by the domain — do not "clean this up"

- **The wire-partition invariant on `ReversibleCircuit`** (in/out/ancilla/loop-check, every
  wire in `1:n_wires` classified, U58) and its enforcement at construction. This is the
  load-bearing safety property. Four classes (not three) because `LoopGuard` wires
  legitimately end at 1 (`gates.jl:516-533`, `bennett_transform.jl:125-155`). Correct.
- **`verify_reversibility`'s four separate checks** (`diagnostics.jl:239-279`): loop
  convergence, ancilla-zero, input preservation, forward+reverse self-consistency — with
  the convergence check ordered *first* so an undersized `K` reports the root cause rather
  than the ancilla symptom. This ordering is hard-won and should be copied verbatim.
- **Six Bennett strategies behind a `BennettStrategy` abstract type**
  (`bennett_strategies.jl`). Space/time tradeoff is the whole research content of the
  project; having Knill pebbling, PRS15 EAGER, value-level EAGER, and checkpointing behind
  one dispatch point is right. The five legacy `*_bennett` aliases as forwarders are cheap.
- **Gate-count regression baselines as tests** (`CLAUDE.md:27`), pinned to *explicit*
  strategy kwargs rather than `:auto` defaults (U150). This is exactly the right
  discipline for a compiler whose output quality is the product.
- **The soft-float library's size.** 35 files for bit-exact IEEE-754 binary64 including
  transcendentals is not bloat; that is what bit-exactness costs. The subnormal-output
  sweep convention (`CLAUDE.md:45`) is a genuinely good post-mortem-derived rule.
- **Branchless-by-construction soft primitives** (`divider.jl`, `softmem.jl`): "all slots
  are computed and MUX-selected so the compiled reversible circuit has no data-dependent
  control flow". This is the domain forcing the code shape, correctly.
- **`_soft_udiv_compile` being throw-free** because `throw` emits `@ijl_throw`, an
  external call with no body to inline (`divider.jl:378-391`). Ugly, unavoidable, well
  documented.

---

## 3. Version coupling: what breaks or simplifies on Julia 1.13

`Project.toml` claims `julia = "1.10"`, `LLVM = "9, 10"`. In practice the code is welded
to 1.12. Ranked by fragility:

**T1 — Julia compiler internals, reached directly.** `extract/sig_llvm.jl` reproduces
`InteractiveUtils._dump_function` by hand, calling `Base._which`,
`Base.specialize_method`, `Base.CodegenParams`, `Base.Compiler.typeinf_code`, and
`InteractiveUtils._dump_function_llvm` (`sig_llvm.jl:20-31, 71-78`). The file's own comment
records that these "moved from `Core.Compiler` in 1.12" (`sig_llvm.jl:99`). There *is* a
capability gate (`_assert_sig_llvm_supported`, `sig_llvm.jl:88+`) that fails loud naming
`VERSION`, which is the right mitigation — but a rename in 1.13 turns a working feature
into a hard error. **This file is the single highest 1.13 risk.**

**T2 — Julia runtime ABI names in the recognisers.** Every symbol in the §1.4 census is a
1.12 codegen detail. `jl_alloc_genericmemory_unchecked` and `julia.gc_loaded` are
*1.11+ only* (the GenericMemory rework); `julia.get_pgcstack` and the
`_GC_LAYOUT_*` byte offsets are ABI. `heap.jl`'s mangled-name regexes
(`r"^j_#_growend!##\d+_\d+$"`) depend on Julia's *closure outlining and name mangling*,
which is a codegen implementation detail with no stability promise at all. Any of these
can change silently in 1.13 and will present as a "wall" error, not a wrong answer — which
is at least the right failure mode.

**T3 — `Core.CodeInstance` vs `Core.MethodInstance` edge shape.** `callgraph.jl:31-38`
already carries a 1.10-vs-1.11 normalisation with a fail-loud `mi_of`. Fine as written;
another such shim is likely in 1.13.

**T4 — LLVM version, via Julia.** Bennett does not pin LLVM; it inherits Julia's. Opaque
pointers are already assumed throughout (`OpaquePtrSentinel`, `ptr_cells`). The
`memssa.jl` path parses the *textual* output of `print<memoryssa>` with four regexes
(`memssa.jl:642-645`) because "LLVM.jl 9.4.6 does not expose MemorySSA as a queryable
C-API object". Textual pass-output parsing is fragile across LLVM versions by
construction; the comment claims the format is "stable since LLVM 4", which is an
assumption, not a guarantee.

**T5 — Toolchain, not language.** JET had to be removed from the test target because its
precompile *hangs* under 1.12's test flags (`Project.toml:23-35`), costing the project its
static-analysis gate. Worth re-testing on 1.13 immediately — that is free signal currently
switched off.

**What 1.13 could simplify.** If `Base.Compiler` becomes a stable public stdlib surface
with a documented `typeinf_ircode`/`code_ircode` entry, T1 collapses from "reproduce
`_dump_function` by hand" to a supported call, and — more importantly — the *instance-less
callee* problem that `sig_llvm.jl` exists to solve disappears entirely, because IRCode is
addressed by `MethodInstance`, never by a callable value. That single change removes the
project's most fragile file.

---

## 4. From-scratch verdict

Assume code generation is free. The question is what is *worth having generated*.

### KEEP — port verbatim or near-verbatim

1. **`gates.jl` + the `ReversibleCircuit` wire-partition invariant.** ~190 LOC, the safety
   backbone. Port unchanged.
2. **`bennett_transform.jl` + `bennett_strategies.jl` + `pebble/`.** The Bennett
   construction and its five alternatives (Knill pebbling, PRS15 EAGER, value-level EAGER,
   checkpoint, group-pebbled) behind one dispatch. This is the project's research content.
3. **`simulator.jl` + `diagnostics.jl` + `verify_reversibility`.** Including the check
   *ordering*, the `_assert_input_fits` bounds check, and the signedness-inference
   heuristic. Port with the tests.
4. **The whole circuit-combinator library**: `adder.jl` (ripple + Cuccaro with the §3.5
   high-bit optimisation), `qcla.jl` (with the five regression-tested cost formulas),
   `multiplier.jl`, `mul_qcla_tree.jl` + `partial_products.jl` + `parallel_adder_tree.jl`
   (including the **reverse-level uncompute schedule** and its correctness proof at
   `parallel_adder_tree.jl:804-824` — the paper's schedule is wrong as stated, that note is
   institutional memory worth more than the code), `qrom.jl`, `fast_copy.jl`, `feistel.jl`,
   `shadow_memory.jl`, `wire_allocator.jl`, `compose.jl`, `controlled.jl`, `tabulate.jl`.
5. **`src/softfloat/` in full, unchanged**, plus its bit-exactness tests and the
   subnormal-output sweep convention. This is ~7k LOC of verified numerics; regenerating it
   would be free but re-*verifying* it would not.
6. **The path-predicate φ resolution algorithm** (`lowering/phi.jl`) — the *approach*
   (block predicates as AND/OR/NOT wire trees, guarded MUX) is the correct answer to
   false-path sensitization. Port the algorithm; fix `phi.jl:56`.
7. **Tests worth porting verbatim**: `test_gate_count_regression.jl`, `test_qcla.jl`'s cost
   table, the exhaustive-256-input Int8 suites, the soft-float bit-exactness and
   subnormal sweeps, `verify_reversibility` on every circuit. Roughly the ~130 non-bead-named
   test files. The 191 `test_<beadid>_*.jl` files should be **triaged, not ported**: each
   pins one extraction wall that may not exist in a new front-end.

### DISCARD

1. **`src/extract/instructions.jl`, `heap.jl`, `sret.jl`, `dict_vm.jl`, the five
   `vector_vm*.jl`** — ~14k LOC of Julia-codegen-shape recognisers. Not because they are
   bad; because they are *shape-matched to a substrate you are considering replacing*. If
   the substrate stays, they are ~40% of the codebase and the treadmill continues (§5c). If
   it changes, they are all dead.
2. **`memssa.jl`** — textual pass-output regex parsing; superseded by whatever alias info
   the new substrate exposes. 143 LOC.
3. **`_reject_unknown_kwargs` + the kwarg const tuples + the `CompileOptions` unpack
   overloads.** Replace with one options struct actually threaded through.
4. **Both caches** as module globals. Replace with a session object (or drop — the
   `objectid`-keyed cache buys little and has a documented staleness hazard).
5. **`_narrow_ir`.** Rewriting a whole IR to change widths is a hack for a testing
   convenience (`bit_width=` on `reversible_compile`); widths should be a parameter of
   lowering, not a rewrite pass.
6. **The 191 bead-named test files**, after triage.

### REDESIGN

1. **IR as a proper sum type with a versioned schema.** 21 `IRInst` structs with sentinel
   discriminators, cross-repo. Redesign: one closed algebraic node set, no sentinel
   conventions, an explicit `IR_VERSION`, and a validator that runs at the stage boundary.
   Because BennettVM consumes it, the IR is an *interface*, and interfaces need versions.
2. **Explicit stage boundaries with typed, non-overlapping configuration.** Three configs,
   not one 13-field bag: `ExtractOptions` (substrate, optimize level, memory model),
   `LowerOptions` (adder/multiplier strategy, width, memory strategy), `SynthOptions`
   (Bennett strategy, target metric). No symbol crosses a boundary it does not belong to;
   `mem=:heap → :auto` normalisation and `_bvmd_reject_normalised_alloca!` both become
   unrepresentable.
3. **Backend as a typed interface, not a `Ref{Any}` hook.** `abstract type Target end`,
   with `CircuitTarget` and `VMTarget`; BennettVM registers a method, not a function
   pointer in a box. Same zero-cycle property, type-checked.
4. **Memory model as one designed subsystem.** Today: `softmem.jl` (MUX-EXCH on packed
   words), `shadow_memory.jl` (universal CNOT tape), `qrom.jl` (constant tables),
   `persistent/` (persistent maps), `lowering/memory.jl` (1,165 LOC dispatcher), plus four
   extraction-side recognisers. Five strategies and a dispatcher that grew bottom-up. This
   deserves one design pass with an explicit cost model, not a sixth arm.
5. **The front-end.** See §5(a).

---

## 5. Specific questions

### (a) The substrate: LLVM IR vs. Julia typed SSA (`IRCode`) vs. GPUCompiler hooks

*(r3/r5 own the ecosystem side; this is the view from inside the codebase.)*

**What exists in Bennett *only because* the substrate is LLVM IR:**

| Machinery | LOC | Exists because |
|---|---:|---|
| `extract/heap.jl` GC-skeleton recogniser + prover | 2,863 | LLVM IR shows `julia.gc_alloc_obj`, pgcstack GEPs, write barriers, tag offsets — all of which are *invisible* in `IRCode`, where an allocation is `:new` / `Expr(:foreigncall)` on typed values |
| `extract/sret.jl` sret detect/collect/synthesise | 1,518 | LLVM's aggregate-return ABI. `IRCode` returns a typed Julia value; there is no sret |
| `extract/dict_vm.jl` + `vector_vm*.jl` recognisers | 1,691 | Recovering `Dict`/`Vector` semantics from post-codegen memory traffic. In `IRCode` these are `Expr(:call, setindex!, ...)` on a `Dict{K,V}`-typed SSA value — *no recognition needed at all* |
| `extract/sig_llvm.jl` by-signature emission | 181 | `code_llvm` needs a callable value; `IRCode` is addressed by `MethodInstance` |
| `extract/constexpr.jl` GlobalAlias/ConstantExpr folding | 331 | LLVM constant expressions |
| `extract/vectors.jl` vector-SSA scalarisation | 719 | LLVM vector types from SLP/codegen |
| `memssa.jl` | 143 | LLVM MemorySSA |
| Opaque-pointer sentinels, `ptr_cells`, byte-vs-cell addressing | scattered | Pointers exist in LLVM; `IRCode` has typed references |
| The `optimize=true`/`false` skew, textual round-trip, mangled-name regexes | scattered | `code_llvm` is a *printer*, not an API |

That table is roughly **7,400 LOC — a fifth of `src/` — that is substrate tax, not
reversible-computing content.** On `IRCode`, allocation, aggregates, dictionaries, vectors,
and callee identity are all *given to you typed*, and the entire recogniser tier collapses.
`Bennett-VISION-PRD.md` §1.1's scope boundary ("we own everything from the tainted LLVM
opcodes on down") is exactly what makes the tax mandatory today.

**What would newly become hard on `IRCode`:**

1. **Language neutrality — the founding claim — is lost.** `test/` currently ingests C via
   clang and Rust via rustc through `extract_parsed_ir_from_ll` / `_from_bc`, and
   `README.md:38-41` sells "the same IR a C or Rust frontend emits goes through the same
   pipeline". `IRCode` is Julia-only, permanently. **The VISION PRD's taint-driven toolchain
   (§1.1) receives *tainted LLVM opcodes* from a clang/LLVM front-end owned upstream; that
   input contract is unsatisfiable from `IRCode`.** This is not a technical inconvenience,
   it is a strategic contradiction, and it is the single strongest argument against the
   move.
2. **`IRCode` is not lowered enough.** LLVM IR hands you `add i8`, `icmp slt`, `shl`,
   `zext` — a bit-width-explicit instruction set that maps 1:1 onto the existing
   `IRBinOp`/`IRICmp`/`IRCast` lowering. `IRCode` hands you `Expr(:call, Base.add_int, …)`
   on Julia types plus *unlowered intrinsics, dynamic dispatch, un-inlined calls, and
   `PhiCNode`/`UpsilonNode` for exception handling*. You would build a Julia-intrinsic →
   bit-width lowering tier that LLVM currently does for free. Call it 1,500-2,500 LOC of
   new work — real, but ~a quarter of what it replaces.
3. **Optimisation quality regresses.** `optimize=false` LLVM IR is already the deliberate
   choice (Rule 5), but `sroa`/`mem2reg`/`instcombine` are run on demand
   (`entry.jl:24, 96-105`) and matter (the memcpy-form sret canonicalisation depends on
   SROA). Julia's own optimizer does inlining and SROA on `IRCode`, so this is largely
   recoverable, but the specific pass pipeline would need re-derivation.
4. **`.ll` / `.bc` ingest and the T5 multi-language corpus die.** ~46 test files use
   `optimize=false` extraction; 138 touch the extraction API. Significant test-suite loss.
5. **You lose LLVM's IR verifier**, which currently catches malformed input for free.
6. **`IRCode` is itself unstable across Julia versions** — arguably *more* so than LLVM IR.
   You trade one moving substrate for another; the difference is that `Base.Compiler` is
   now a stdlib with some intent to stabilise, whereas Julia's *codegen output shape* has
   never had any stability promise at all. On that axis IRCode is a clear win.

**GPUCompiler-hook architecture** is the interesting middle: you keep LLVM IR (so C/Rust
and the taint contract survive) but stop scraping `code_llvm`'s printer. You get a
`CompilerJob`, a proper `Module`, a controllable pipeline, and — decisively — you get to
run *your own passes before Julia's GC lowering*, which is where roughly half of
`heap.jl`'s pain comes from (it is reverse-engineering a skeleton that a pre-GC-lowering
hook would never have emitted). It also gives you the `MethodInstance`-addressed entry that
`sig_llvm.jl` reproduces by hand.

**My recommendation, stated as a bet rather than a certainty:**
**a GPUCompiler-style LLVM hook as the primary substrate, with `IRCode` used as a
*side-channel oracle*, not as the IR.** Concretely: keep lowering from LLVM IR (preserves
C/Rust, preserves the taint contract, preserves the existing `lowering/` tier almost
unchanged), but obtain the module through a compiler hook rather than a printed string, and
*consult* `IRCode`/inference for the things LLVM has thrown away — that a value is a
`Vector{Int64}`, that a call is `setindex!`, that an allocation is a `Dict`. Most of
`dict_vm.jl` and `vector_vm*.jl` exists to re-derive facts that inference already knows and
codegen discarded; asking inference directly is a ~10× code reduction for those recognisers
and is *not* mutually exclusive with an LLVM substrate. Reject the pure-`IRCode` design on
the strength of point (1) alone unless the maintainer is willing to abandon the
language-neutrality claim explicitly.

### (b) Module / package decomposition for v2

Five packages, in dependency order:

1. **`ReversibleCircuits.jl`** — gates, `ReversibleCircuit` + wire-partition invariant,
   `WireAllocator`, simulator, diagnostics, `verify_reversibility`, `compose`,
   `controlled`. Zero deps. *Independently useful and independently publishable* — this is
   the piece a reversible-computing researcher wants without a compiler.
2. **`ReversibleArithmetic.jl`** — adders, multipliers, QCLA, QROM, Feistel, fast-copy,
   partial products. Depends on (1). Pure circuit combinators with cost formulas and
   regression-pinned gate counts.
3. **`SoftFloat.jl`** — the IEEE-754 integer library. **Zero deps on anything above** — it
   is plain Julia. Ship it standalone; it has independent value and independent tests, and
   detaching it removes ~7k LOC and 35 files from the compiler's cognitive surface.
4. **`BennettIR.jl`** — the IR node set, validator, versioned schema, plus the
   `ParsedIR → LoweringResult` lowering tier and the Bennett construction/strategies.
   Depends on (1),(2), optionally (3) as a callee provider. **This is the package
   BennettVM should depend on** — today it depends on all of Bennett including LLVM.jl.
5. **`BennettFrontend.jl`** (or `BennettLLVM.jl`) — the only package with an LLVM.jl
   dependency: substrate acquisition, recognisers, `ParsedIR` production. Swappable:
   a `BennettWasm.jl` (the TS PRD's substrate) or `BennettIRCode.jl` becomes a sibling,
   not a fork.

`Bennett.jl` remains a thin meta-package re-exporting the user-facing surface.

The decisive win is (4)/(5): **BennettVM would depend on `BennettIR.jl` and inherit no
LLVM dependency**, and the cross-repo interface would be a versioned IR schema rather than
"whatever is checked out in `../Bennett.jl`". Memory strategies I would keep *inside* (4)
rather than splitting out — they are too entangled with lowering to have a clean seam yet.

### (c) The fail-fast error architecture and the wall/marker system: converging or diverging?

This is the most important finding in this review, and the evidence is unusually good
because the project logged it honestly.

**The mechanism.** Fail-fast (Rule 1) means an unrecognised IR shape raises a named error.
Running a corpus program (Julia `push!`, `Dict{Int64,Int64}`) through extraction therefore
produces a *deterministic sequence of walls*: the first unsupported shape errors, a bead
clears it, the next shape errors. "Markers" are regression tests that pin the exact error
*message text* of the current frontier wall, so they go red when the frontier advances —
an ingenious, and entirely emergent, progress instrument.

**The measurements, from the project's own worklogs:**

- `worklog/101:102-109` tabulates walls 9, 10, 11, and "12+ — the §7.1 alloca-reservation
  mismatch — **silent, no wall** — unfiled".
- `worklog/106:113-118`: five walls cleared in one session (p06b/6, foz5/7, bvmd/8,
  sy29/9, 57hd/10), each a named admission contract.
- `worklog/106:135-138`: after wall 11, "walls 12 (1zow silent-skip), 13 (second 8bys
  memcpy), 14 (env-alloca tier decision)… **Then bennettvm-rxgy for the full-corpus RUN.**"
- `worklog/103:255`: "**SIX markers, not four.** The bead undercounted." → by `worklog/106`
  it is **eight** marker sites.
- `worklog/098:124-128`: "A wall marker whose disjunction admits the SUCCESSOR wall stops
  being a marker the moment it lands" — markers now carry hand-tuned `!occursin(...)`
  negatives against *other beads' error strings*, and `worklog/099:172-186` records that a
  blanket negative became "UNEXPRESSIBLE and has been RETIRED in all three markers", with
  the new rule that each marker must enumerate every substring that is some other marker's
  load-bearing negative.

**Verdict: locally converging, globally diverging.**

*Converging*, in the strict sense that the wall sequence for **one fixed corpus program**
is finite and is being consumed: `_growend!` now extracts completely, ten consecutive beads
required zero BennettVM changes. Each wall is genuinely cleared, with executed witnesses
and hostile reviews that caught four real miscompiles pre-landing. This is not busywork.

*Diverging*, on three independent axes:

1. **Cost per wall is rising, not falling.** Walls 6-11 each produced a *named admission
   contract* (CONFINED-VALUE, VALUE-IDENTITY, root-scale coherence) with its own
   provenance walker, depth cap, and scan cap. `_57hd_*` alone is ~570 lines
   (`instructions.jl:1844-2575`). Nothing generalises: `worklog/101:111-113` records that
   wall 10 "needs a **third** admission contract" because foz5's clause (iii) required an
   `icmp` use and this one is a `udiv`. Each contract is one more case, not a stronger
   theory.
2. **The marker system's maintenance cost is superlinear.** Eight markers × pairwise
   `!occursin` negatives against each other's messages. `worklog/103:270`: "check that your
   suggested discriminator…". `worklog/104:121-126`: "the wall-11 marker trap… advanced
   markers cannot tell a wall-9 **regression** from wall-11". The instrument now needs its
   own correctness discipline, and the project has written process rules about it.
3. **The corpus is one program, and the failure mode is turning silent.**
   `worklog/101:107` — wall 12 is "**silent, no wall**"; `worklog/101:118-120` — "the bead's
   premise is FALSE… **No amount of bvmd work produces a runnable push! corpus.**" Eleven
   walls for `push!` on a `Vector{Int64}`. `Dict{Int64,Int64}` has its own chain. There are
   thousands of Julia library shapes and Julia is free to change all of them.

**What this reveals about the extraction approach's asymptotics.** Recognising a
high-level data structure from *post-codegen, GC-lowered, optimize=false LLVM IR* is
decompilation. Decompilation of a fixed corpus converges; decompilation of a *language*
does not — the recogniser must be at least as large as the set of codegen shapes, which is
unbounded and version-dependent. The walls are not bugs; they are the *interface* between
a finite recogniser and an infinite shape space, and fail-fast is what makes that interface
visible instead of a miscompile. **The doctrine is working exactly as designed and the
result it is reporting is that the substrate is wrong for this job.** The moment wall 12
is "silent, no wall", the doctrine's protection has been exceeded too.

The strategic reading: this treadmill is the empirical case for §5(a)'s recommendation.
Every fact these recognisers reconstruct — this alloca is a `Vector{Int64}`'s data
pointer, this call is `setindex!`, this GEP is element `i` — is a fact Julia's inference
*already had* and codegen discarded. A design that asks inference instead of
re-deriving it from bytes does not have walls 6-14 at all.

### (d) Three candidate v2 architectures, with staging

Common ground for all three: week 1 is the *back half*, because the back half is proven,
substrate-independent, and exhaustively tested. Front-end choice is deferred to week 2+
precisely because it is the contested decision.

---

**Candidate A — "Same substrate, right structure" (lowest risk, ~4-6 weeks)**

Keep LLVM IR. Fix everything else.

- **Week 1 (end-to-end):** packages 1-4 from §5(b). Port gates, circuit invariant,
  simulator, `verify_reversibility`, adders, Bennett + strategies, and a *hand-built*
  `ParsedIR` for `x + 1` at i8/i16/i32/i64. Green criterion: the pinned gate-count
  baselines (58/114/226/450, Toffoli 12/28/60/124) reproduce exactly, and
  `verify_reversibility` passes. No LLVM in the repo yet.
- **Week 2:** `BennettFrontend.jl` via a GPUCompiler-style hook (no `sprint`/`code_llvm`
  string round-trip). Scope: scalar integer functions, `phi`, `select`, `icmp`, casts,
  calls. Explicitly *no* GC/heap/Dict/Vector recognition. Green criterion: the ~130
  non-bead-named test files pass.
- **Week 3:** soft-float as a separate package + callee registry as a session-scoped
  provider. **Week 4:** memory model, redesigned once, with a cost model. **Deferred
  indefinitely:** `heap.jl`, `dict_vm.jl`, `vector_vm*.jl` — reintroduced only with
  inference-oracle assistance (below), never as byte-pattern recognisers.
- **Risk:** the treadmill returns the moment heap support is needed.

---

**Candidate B — "Hybrid: LLVM substrate + inference oracle" (my recommendation, ~6-9 weeks)**

Candidate A, plus a second input channel. The front-end takes *both* the LLVM module
*and* the typed `IRCode`/inference result for the same `MethodInstance`, and correlates
them. Where LLVM shows `call julia.gc_alloc_obj` + GEP traffic, inference says
`Vector{Int64}`; where LLVM shows an opaque `j_setindex!_1234`, inference says
`setindex!(::Dict{Int64,Int64}, ::Int64, ::Int64)`.

- Week 1-2: identical to A.
- **Week 3:** the oracle channel — a `TypeOracle` that answers "what Julia type/operation
  does this LLVM value/call correspond to". Correlation is by `MethodInstance` + call
  order, not by name mangling. Green criterion: `Dict` and `Vector` recognition with
  **zero** mangled-name regexes and zero GC-skeleton proving.
- **Week 4-6:** memory model; heap support built on the oracle rather than on
  decompilation. **Week 7+:** the `.ll`/`.bc` path (C/Rust) runs *without* the oracle —
  degraded but functional, exactly as today's non-Julia corpus does.
- **Why this is the bet:** it keeps the VISION PRD's taint contract and language neutrality
  (LLVM stays the substrate; the oracle is a Julia-only *enhancement*, not a requirement),
  while deleting the strategic reason walls 6-14 exist. It is also the only option that
  makes the Julia and C/Rust paths differ in *quality* rather than in *kind*.
- **Risk:** LLVM↔IRCode correlation is itself research. Prototype it in week 0 on one
  `push!` function before committing; if correlation is unreliable, fall back to A.

---

**Candidate C — "IRCode-native, Julia-only" (highest leverage, highest strategic cost, ~5-7 weeks)**

Abandon LLVM. Front-end is `Base.Compiler.typeinf_ircode`; lower Julia intrinsics
(`add_int`, `slt_int`, `zext_int`, …) directly to gates.

- Week 1-2: identical to A.
- **Week 3-4:** the `IRCode` → `BennettIR` tier, including a Julia-intrinsic → bit-width
  lowering table and `PhiCNode`/`UpsilonNode` handling.
- **Week 5+:** memory: `:new`, `Expr(:foreigncall)`, and typed array access — *no
  recognisers at all*, because the types are present.
- **What you give up, explicitly:** C and Rust ingest, the `.ll`/`.bc` path, the T5
  multi-language corpus, and the VISION PRD §1.1 taint contract as written. BennettVM's
  language-agnostic charter (`ir_types.jl:273-296`) would need restating.
- **What you gain:** the ~7.4k-LOC substrate tax disappears; the wall treadmill disappears;
  version coupling moves from "Julia's undocumented codegen output" to "`Base.Compiler`,
  a stdlib with stabilisation intent" — a strict improvement.
- **Take this only if** the maintainer is willing to say out loud that Bennett v2 is a
  Julia compiler, and to relocate the multi-language ambition to a separate LLVM front-end
  built later against the same `BennettIR.jl`. Note that this is *recoverable*: because
  `BennettIR.jl` is the interface, an LLVM front-end can be added in v2.1 without touching
  the back half. That optionality is the strongest argument for the package split in §5(b)
  regardless of which candidate wins.

---

**Staging rule common to all three, stated as a hard gate:** nothing enters the new
front-end until the back half reproduces every pinned gate count and every soft-float
bit-exactness test from a hand-built IR. The back half is the asset; the front-end is the
liability. Building in that order also means that if the substrate decision is wrong, you
lose weeks 3+ and keep weeks 1-2 — which is precisely the risk profile the current
codebase does *not* have, because its 39k LOC cannot be separated along that seam today.

---

## Appendix: quick reference to the citations used

| Claim | Location |
|---|---|
| 7 `reversible_compile` methods, 13 kwargs, triplicated defaults | `src/Bennett.jl:104, 271-285, 467-478, 541-575` |
| Hand-rolled kwarg validation + const tuples | `src/Bennett.jl:173-196, 265, 395` |
| Duplicated tabulate short-circuit | `src/Bennett.jl:343-351, 371-377` |
| `mem=:heap → :auto` stage-boundary patch | `src/Bennett.jl:366-367` |
| Global caches + `Ref{Any}` backend hook | `src/Bennett.jl:410-419`, `src/extract/callees.jl:3, 37-38, 121` |
| String round-trip substrate | `src/extract/entry.jl:59, 96` |
| Conditional pass-pipeline mutation | `src/extract/entry.jl:98-105` |
| Julia compiler internals reached directly | `src/extract/sig_llvm.jl:20-31, 71-78, 88-100` |
| 1.10/1.11 `CodeInstance` shim | `src/extract/callgraph.jl:31-38` |
| Mangled-name regexes / GC ABI offsets | `src/extract/heap.jl:40, 53, 60-62, 281-288` |
| Per-bead recognisers + magic depth caps | `src/extract/instructions.jl:218, 1546-1843, 1657-1659, 1844-2575, 2010-2027, 2576-3117` |
| Cross-backend leak into the gate lowerer | `src/lowering/driver.jl:1-102` |
| Silent-skip in φ predicates | `src/lowering/phi.jl:56` |
| Sentinel-discriminated IR nodes | `src/ir_types.jl:105-131, 133-169, 221-226, 363-389` |
| Wire-partition + loop-guard invariant (KEEP) | `src/gates.jl:516-533`, `src/bennett_transform.jl:125-155` |
| `verify_reversibility` check ordering (KEEP) | `src/diagnostics.jl:239-279` |
| Adder-tree reverse-level uncompute proof (KEEP) | `src/parallel_adder_tree.jl:804-824` |
| Wall/marker treadmill evidence | `worklog/098:124-128`, `099:172-186`, `101:102-120, 131-136`, `103:255-270`, `104:121-126`, `106:100-140` |
| BennettVM path-dep, documentary pin | `../BennettVM.jl/BENNETT_JL_PIN.md:6-19` |
| VISION taint contract / scope boundary | `Bennett-VISION-PRD.md:§1.1` |
| Stale file map / deleted `ir_parser.jl` | `CLAUDE.md:121` vs `src/Bennett.jl:5-7` |
| JET disabled by 1.12 precompile hang | `Project.toml:23-35` |
