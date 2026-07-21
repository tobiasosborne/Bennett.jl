# worklog chunk 095 — 2026-07-12 — Bennett-klgz determinism guard

## Session log — 2026-07-21 — tracker truth-up + Bennett-a70z (bsng) 3+1 design phase; impl parked as WIP

**Orchestrated session (Fable orchestrator, serial subagents: auditor → scout →
2 blind proposers → implementer). Stopped gracefully mid-implementation at user
request; nothing lost.**

### Tracker truth-up (the beads DB was ~5 weeks behind git)

A read-only audit subagent reconciled beads vs git/worklogs in BOTH repos.
Result: **17 closes** with evidence-cited reasons. Bennett.jl: `44dg`
(superseded by utzc route-a), `eln6` (dissolved by the 9n3y byte-granular
convention), `800b` (superseded by Option C; residual → `25dm`). BennettVM:
`7xa` (SC9 Case B — re-verified live: `test_dict_roundtrip.jl` 34/34), `90l`,
`416r.11/.12/.13/.4` (epic `416r` auto-closed 13/13), `6db`/`ehp`/`nm0`
(superseded by ADR 0017 architecture), M13 chain `zg5/fu5/kl3/vw8`
(FORCE-closed past stale planned-ordering dep edges — 7zl Lean gate + xkl were
never real prerequisites; the dispatch shipped, `test_e2e_collatz.jl` proves it).
`xkl` re-scoped to the closed-world route. **The three successors named in the
BVM WORKLOG milestone block were never filed** (dolt gap) — now filed:
`Bennett-a70z` (bsng: elsize>1 overflow prover), `Bennett-zdd6` (jb6w:
SysV register-coercion-spill mis-stamp landmine), `bennettvm-rnhv` (san3:
Dict growth `:__v96` undefined-SSA run wall).

### Bennett-a70z — scout + 2 blind proposals (CONVERGED); designs archived

Full artifacts: `docs/design/a70z/` (scout_report.md, proposal_A.md,
proposal_B.md, ir_excerpts.txt; full .ll dumps regenerable via `code_llvm`).

- **Scout ground truth:** the wall is `_fuse_overflow_extractvalue`
  (`src/extract/instructions.jl:2509-2534`) — provably-zero only for mul
  c∈{0,1} / add c=0. i64 rehash! has 6 `smul(%value_phi, c)` sites (c=1 slots,
  c=8 keys/vals); the memorynew guard shape routes bit=1 → `jl_argument_error`
  → utzc-pruned `:__unreachable__` halt sink, but the pruner is keep-branch so
  the bit stays live as a VALUE. `%value_phi` is statically unbounded ⇒ no
  range proof exists; the bit must be COMPUTED.
- **Both blind proposers converged** (strong signal): emit the EXACT bit for
  one-ConstantInt-operand `{s,u}{mul,add}.with.overflow` as constant-folded
  interval tests — ≤2 `IRICmp` + width-1 `IRBinOp(:or)`; bounds in Int128
  (smul c≥2: `[cld(typemin,c), fld(typemax,c)]`, c≤-2 flipped, c=-1 ⟺
  `x==typemin`; sadd one-sided; unsigned arms need MASKED decode — LLVM.jl
  constant decode is sign-extending). Always-0 fast path stays byte-identical
  (protects lbot GATE (a) pins, zero counter drift). Two-dynamic-operand,
  ssub/usub, ptr_cells=false: stay fail-loud. BVM side needs NOTHING (emitted
  opcodes all already ingestable; byte-granular VM ready for elsize>1).
- **Implementation is PARKED UNVERIFIED on branch `wip/a70z-overflow-bit`**
  (commit 1f521d3d: instructions.jl +133/−27 + test_a70z_overflow_const_bit.jl,
  583 insertions). The implementer was killed mid-first-test-run — NO green has
  been observed. Next session: re-verify RED/GREEN from scratch (do NOT trust
  the WIP; CLAUDE.md rule 10), then the non-regression battery
  (test_lbot_overflow_intrinsic, test_d1b_julia_set, test_utzc_dead_block_pruner,
  test_klgz_determinism_guard, test_416r13_jlglobal_singleton, all
  `--check-bounds=yes`), honest lbot GATE (b) pin updates, worklog, close.

### Gotchas / blockers for the next agent

- **Concurrent Julia = precompile-cache corruption.** Another agent's full
  suite run had to be killed before this session could test. ALWAYS
  `pgrep -af julia` before any julia invocation. Laptop: single test files
  only.
- **`bd` dolt auto-push is BROKEN in both repos**: `git-remote-cache/.../repo.git`
  is "not a git repository" → every close prints a push warning. Local dolt
  store is fine (closes stick). Needs a repair (`bd dolt push` by hand /
  re-clone the remote cache) — not attempted this session.
- Known next walls after a70z: `Dict{Int64,Int64}` may hit a further wall
  inside rehash! (unknown — testset (e) of the WIP test file pins it), and the
  separate VM run-tier Dict-growth wall is `bennettvm-rnhv`.

## Session log — 2026-07-12 — Bennett-klgz: determinism CLASSIFIER at the 416r.13 GOT-stub reject site

**Bead pair:** `Bennett-klgz` (front-end, this repo) + `bennettvm-90l` (BennettVM
denylist mirror). Last open dependency of P0 `bennettvm-7xa` (e2e `fdict`).

**Protocol note (orchestrator decision).** This guard *refinement* was scoped as
**implementer + hostile-reviewer on a scout-RATIFIED design**, NOT the full
2-proposer core-change pass. Justification: the change ADMITS NO NEW CONSTRUCT
and adds NO lowering — it only refines a fail-loud message. Design basis:
`BennettVM.jl/scratchpad/scout-90l-determinism.md` (its Q5 recommendation was
ratified). Recorded here so a future agent does not read this as a rule-2 bypass.

### What landed (front-end, Bennett-klgz)

At the 416r.13 "unrecognized Julia JIT global" reject
(`src/extract/instructions.jl`, the `ptr_cells && GlobalVariable && result
PointerType` load arm), a determinism CLASSIFIER now runs BEFORE the generic
reject. Julia calls an unbound runtime C entry point via a PLT/GOT lazy-binding
stub: a global `@"jlplt_<callee>_<N>_got"` (`constant ptr`), an atomic
`load ptr` of it, then an INDIRECT call through the loaded SSA value. The callee
name survives ONLY as the GOT global's symbol (never as an `IRCall` `nameof`).
The classifier demangles `<callee>` (`_demangle_got_callee` in
`src/extract/constexpr.jl`, regex `^jlplt_(.+)_\d+_got$`) and:

- **IDENTITY hashers** (`_IDENTITY_HASH_GOT_CALLEES`: `ijl_object_id`,
  `jl_object_id`, `object_id`, `objectid`, `pointer_from_objref` + variants) →
  `_ir_error` with a DETERMINISM-FLOOR message: names the construct ("hashed by
  OBJECT IDENTITY / allocation address"), says WHY (address is non-deterministic
  across replays ⇒ unreplayable ⇒ the ADR 0015 D3 in-principle blocker),
  advises (use isbits or content-hashed String keys), cites ADR 0015 D3 + the
  bead pair.
- **CONTENT hashers** (`_CONTENT_HASH_GOT_CALLEES`: `memhash_seed` + variants) →
  a DISTINCT `_ir_error`: deterministic content hash, IN SCOPE for the floor,
  "MODELING GAP" (runtime-callee GOT-stub modeling is future work), NOT a
  correctness floor — so a future agent knows String-key Dicts reject here only
  for want of modeling, not for a determinism reason.
- **Anything else** → the existing generic 416r.13 message, unchanged.

**CRITICAL SCOPE INVARIANT held:** every path still rejects — nothing new is
admitted. Zero behavior change for programs that extract today: the isbits
`fdict` set extracts bit-identically (its 3 `ptrtoint` are `+Type#N` type tags
handled by the type-tag arm far above this site; verified `length(set)==4`).

### Ground-truth PLT-stub names (verified live 2026-07-12, Julia 1.12.5)

The names do NOT appear in the top-level `fmk`/`fstr` IR at `optimize=false` —
they live inside the transitive callees. Probed `code_llvm` of the callees:

| callee IR | GOT stub found | demangles to | family |
|---|---|---|---|
| `Base.ht_keyindex(Dict{MK,Int8}, MK)` | `@jlplt_ijl_object_id_161_got` | `ijl_object_id` | IDENTITY |
| `Base.ht_keyindex2_shorthash!(Dict{MK,Int8}, MK)` | `@jlplt_ijl_object_id_327_got` | `ijl_object_id` | IDENTITY |
| `Base.ht_keyindex(Dict{String,Int8}, String)` | `@jlplt_memhash_seed_333_got` | `memhash_seed` | CONTENT |
| `objectid(::MK)` | `@jlplt_ijl_object_id_281_got` | `ijl_object_id` | IDENTITY |

**Surprise:** `pointer_from_objref(::MK)` emits NO `jlplt_*_got` stub — it
inlines straight to a `ptrtoint`. So the only IDENTITY stub name observable in
real IR today is `ijl_object_id`. The `jl_`/bare variants are included in the
set *defensively* (a future JIT that emits them as stubs is still walled by
name) — membership on a `Set{String}` costs nothing.

### VM mirror (bennettvm-90l)

Extended `_NONDETERMINISTIC_CALLEES` (`BennettVM.jl/src/ir/ingest_call.jl`) with
the resolved identity-hash Symbols (`:ijl_object_id`, `:jl_object_id`,
`:object_id`, `:jl_pointer_from_objref`, `:ijl_pointer_from_objref`) alongside
the existing `:objectid`/`:pointer_from_objref`. `memhash_seed` is deliberately
NOT added (deterministic content hash). This is defense-in-depth: an
identity-hasher arriving as a raw `IRCall(Symbol)` hits the same specific
"nondeterministic" reject as `:objectid`.

**OUT OF SCOPE (documented, per the bead):** the bead's "inlined no-callee"
extension — the `load ptr @jlplt_*_got` + indirect-call-through-SSA-pointer
shape — CANNOT reach VM ingest today: the front-end 416r.13 classifier walls the
load before any `ParsedIR` exists (scout Q4). The mirror covers only the
named-`IRCall` surface; the indirect shape is blocked-by front-end
runtime-callee GOT-stub modeling (depends-on, not do-now).

### RED/GREEN evidence

- **RED** (classifier stashed out, hand-built GOT-stub IR through `from_ll`):
  both `jlplt_ijl_object_id_5_got` and `jlplt_memhash_seed_7_got` throw the
  GENERIC "UNRECOGNIZED" message — `OBJECT IDENTITY`/`MODELING GAP` absent. So
  the new assertions fail → RED.
- **GREEN** (after): `test/test_klgz_determinism_guard.jl` 29/29 pass. The SET
  path confirms end-to-end: `fmk` (Dict{MK,Int8}) → determinism-floor message
  naming `ijl_object_id`; `fstr` (Dict{String,Int8}) → MODELING-GAP message
  naming `memhash_seed` and NOT the determinism message; `fdict`
  (Dict{Int8,Int8}) → extracts OK, 4 bodies.

### Test wiring

- New `test/test_klgz_determinism_guard.jl` (SET-path (a)/(b)/(c) + a fast
  drift-immune hand-built-IR unit testset exercising all three arms), registered
  in `test/runtests.jl` after `test_416r13_jlglobal_singleton.jl`.
- BVM: extended the existing `test_fail_loud_completeness.jl` F1 section with a
  `bennettvm-90l mirror` testset iterating the new Symbols; already registered.

### Regression pins run green (`--check-bounds=yes`)

`test_416r13_jlglobal_singleton.jl`, `test_9n3y_memheader_gep.jl`,
`test_d1b_julia_set.jl`, `test_klgz_determinism_guard.jl` (one process). BVM:
`test_fail_loud_completeness.jl`, `test_cwd4_genericmemory.jl`,
`test_jlglobal_singleton.jl` — the fdict e2e stays green + bit-identical.

### Gotcha for the next agent

The `jlplt_*_got` names are per-compilation (`_<N>_` discriminator drifts every
build — CLAUDE.md Rule 5). NEVER pin the `_N_`; the classifier strips it and the
tests assert only the guard's OWN diagnostic prose + the drift-invariant callee
stem. If you later teach the extractor to MODEL these stubs (needed to make
String-key Dicts extract), the CONTENT arm is where `memhash_seed` should start
routing to a named runtime call — and at that moment this determinism guard
becomes LOAD-BEARING correctness (today it is defense-in-depth: the adversary is
already loud via the generic wall — the guard only refines WHY).
