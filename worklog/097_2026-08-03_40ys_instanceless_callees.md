# Worklog chunk 097 — 2026-08-03 — 40ys instance-less callees (xkl frontier)

## Session log — 2026-08-04 — Bennett-3vf2: dead-use global-load drop; xkl wall 3 cleared; frontier is now memmove (8bys)

Third bead of the 40ys/7wsz session. 3+1 where the proposers genuinely
DIVERGED — the adjudication and its verification are the story.

### The wall and the design fork

`_growend!` has 4 identical div-guard diamonds (`sdiv` by literal 4/8) whose
guard is literally `and i1 true, (or i1 true, X)` — structurally dead — but
Julia HOISTS the `load ptr, ptr @jl_diverror_exception` into the LIVE
predecessor block; its only use is `ijl_throw` inside the unreachable-
terminated fail block. The global matches neither recognized global-name kind,
so the generic UNRECOGNIZED-JIT-global reject fired. Proposer A: census
whitelist of Julia's 6 `jl_*_exception` singletons + use-shape assertion.
Proposer B: name-agnostic "dead-use drop" — drop any otherwise-rejected
GlobalVariable ptr load iff EVERY use's parent block is in the utzc
`dead_blocks` set (sound because the pruner empties those blocks: nothing
emitted can reference the def). B also showed `@jl_sym#convert` is one codegen
hoist away from re-walling any whitelist. ADJUDICATION: B's mechanism + A's
near-miss diagnostics (live-use exception-singleton rejects name the live
block).

### The correction chain (Rule 10 vindicated twice)

B "falsified" the scout with an `addrspacecast ptr→addrspace(12)` direct-use
sighting — which the implementer then showed was a DUMP ARTIFACT: on the real
extraction path (`_code_llvm_by_sig(optimize=false, dump_module=true)` + the
`sroa,mem2reg` prepend) there are ZERO addrspacecasts in the function; the
load's direct use IS the throw. Every layer's claim got re-verified by the
next layer, and each round found something. Wall forecasts and IR claims are
only valid for the EXACT pipeline configuration that produced them.

### What landed

- The arm sits AFTER the klgz GOT-stub classifier (determinism diagnostics
  keep priority) and carves out only the generic reject. Pure drop: no IRInst,
  no alias, `delete!(names,…)` so survivors fail loud in `_operand`. Helpers
  (`_all_uses_in_dead_blocks`/`_first_live_use_block` + soundness theorem + φ
  corollary) live in vector_vm_cfg.jl NEXT TO `_vec_vm_dead_blocks` so the
  coupling is pinned at the oracle. Atomic loads DECLINED explicitly (fence
  semantics ≠ value semantics; acquire loads DO reach the arm since ares).
  Zero-use loads still reject — that conservatism is what keeps 416r13's
  `weird_global#5` fixture green (verified principled, not incidental).
- Hostile review found a STRONGER soundness argument than the design docs: SSA
  domination alone makes dead-block-def → live-block-use structurally
  impossible in verifier-valid IR (a block with no successors dominates only
  itself).
- push! corpus now lands on `llvm.memmove.p0.p0.i64` (Bennett-8bys/37mt — the
  next xkl wall, already tracked). ptr_cells=false byte-identical
  (fingerprint-compared, not "extracts ok"); gate-count 39/39.
- BVM: zero src changes; E2E fixture — the benign diamond runs to `:halted`
  (never the `:__unreachable__` error sink), `div(n,4)` for 7 values incl.
  negatives, exact unrun! under L2+L3 (104 asserts).

### Gotchas

1. `return` inside `@testset begin…end` silently aborts the enclosing testset
   — a RED run can under-report to 2 assertions. Use `if`, never early return.
2. `LLVM.isvolatile` isn't exported by this LLVM.jl; use
   `LLVM.API.LLVMGetVolatile`/`LLVMGetOrdering`.
3. Volatile loads never reach the arm (4mmt/U14 guard unconditional) but
   ATOMIC loads do (ares relaxed that half) — the arm's atomic decline is
   live code, its volatile check is documented belt-and-braces.
4. test_7wsz gate (J) is a SECOND wall-marker that flips on frontier advance,
   not just test_40ys (I). Both now carry negative pins
   (!occursin("jl_diverror_exception")) — the disjunctions alone would not
   guard a re-open (hostile review R6 of 7wsz; Bennett-0ncn).

### Beads

3vf2 closed. Filed: GOT-stub/dead-use interaction fixture (P3, hostile-review
R3 — unclassified jlplt stub with all-dead uses falls through klgz into the
drop, sound but unpinned). Frontier for xkl: Bennett-8bys/37mt (memmove
lowering), then iwo9 ptrtoint (kvdv); root separately at pgcstack (5oyt).

### Gates (orchestrator-run, fresh subprocesses)

- BennettVM full `Pkg.test`: **9895/9895**, 4m00.9s.
- Bennett.jl full `Pkg.test`: **690811 Pass / 3 Broken (pre-existing)**, 28m56.6s (implementer run 690810/3 — benign +1 run-to-run pass-count delta, Broken identical).
- Implementer runs: Bennett 690810/3B 26m02s; BVM 9895/9895 3m51s.


## Session log — 2026-08-04 — Bennett-7wsz: ptr-typed sret fields under ptr_cells; xkl closure frontier advances to the 416r.13 JIT-global wall

Same orchestrated session as 40ys (below), second bead. 3+1: two blind Opus
proposers CONVERGED again; Opus implementer; Sonnet hostile review
ACCEPT-WITH-CONDITIONS (zero claims falsified across 9 attack vectors).

### What landed

- `_sret_struct_fields(st, func; ptr_cells=false)` admits `LLVM.PointerType`
  sret fields at width 64 under the gate ONLY (addrspace-0 only; pointersize==8
  asserted; both rejects loud). `_detect_sret` gains a threaded `ptr_cells`
  kwarg (was called unconditionally from module_walk — the exact leak channel).
- `_try_handle_sret_scalar_store!` accepts `store ptr` with WIDTH-based (not
  type-equality) field matching — REQUIRED because Julia's split-roots ABI
  stores literal `i64 -1` into ptr-TYPED sret slots. Slot selection stays
  exact-byte-offset (`findfirst` on offset), so width relaxation cannot land a
  store in the wrong field (hostile-review-verified, adversarial i32 probe).
- **`return_roots` is modeled VERBATIM as an ordinary 64-bit out-pointer param
  — NO fusion.** Both proposers proved independently: callee stores the
  GC-tracked field into `return_roots` and writes `i64 -1` into the matching
  sret slot; the jfptr wrapper reassembles `{sret[0], return_roots[0]}`. A
  future agent "fixing" the -1 sentinel by splicing return_roots into the
  aggregate would be a SILENT POINTER MISCOMPILE — anti-fusion pinning tests
  (ConstOperand(-1) shape + a dat+mem-1 arithmetic witness) + a 45-line
  SEMANTICS block in sret.jl record the evidence.
- BVM: **zero src changes** (guard-5 `ret_width==sum` 128==128 takes the
  value-ABI branch — read, not trusted). New `test_7wsz_ptr_sret_vm.jl` (160):
  sret({ptr,i64}) fixture family E2E (extract → lower_vm → run == native
  oracle → unrun! exact, L2+L3, per-step inverse) + a hand-built split-roots
  `.ll` pair proving the return_roots store crosses frames on the VM and
  IRInsertBits+ConstOperand(-1) lowers.

### Gotchas (hard-won)

1. **"Advances to the next wall" is NOT monotone in program order.** Clearing
   the 416r.16 PRE-WALK wall exposed the body walk's FIRST instruction: the
   push! ROOT lands on the pgcstack inline-asm wall (Bennett-5oyt/U15), NOT the
   forecast U114 store-{ptr,ptr}. Both proposals' root forecast was measured
   with an UNGATED monkey-patch — wall forecasts must state the gate value.
   The SET/closure frontier DID advance as forecast: unrecognized JIT global
   `@jl_diverror_exception` (bennettvm-416r.13 family).
2. **A const-field Julia fixture cannot pin IRInsertBits+ConstOperand** —
   `S(p,-1)` constant-folds to `IRRet(ConstOperand(...))`. Hand-built `.ll` is
   the only honest route to that path.
3. **The auto-SROA dependency is now tripwired**: `_mk7wsz`'s O0 form is a
   16-byte whole-aggregate memcpy; it reaches the scalar-store arm only because
   `_module_has_sret` prepends `sroa,mem2reg`. Testset (A) pins it.
4. `_emit_cell_call` hardcodes ptr_cells=true — correct today (both call sites
   inside `if ptr_cells`, verified), named in a comment; a future refactor
   calling it from a non-gated path would silently admit ptr sret fields onto
   the circuit path.

### Beads

7wsz closed. Filed: Bennett-0ncn (P3, tighten bare-numeral wall-marker
disjunctions — hostile review R4). Homogeneous `[N x ptr]` stays rejected
(deliberate asymmetry, rationale-tested). Next frontier for xkl: the
`jl_diverror_exception` JIT-global materialization (416r.13 family), then
`jl_genericmemory_copy_slice`/alloc inside the closure body, then iwo9
ptrtoint (Bennett-kvdv).

### Gates (orchestrator-run, fresh subprocesses)

- BennettVM full `Pkg.test`: **9791/9791** (= 9631 + 160 new).
- Bennett.jl full `Pkg.test`: **690748 Pass / 3 Broken (pre-existing), 29m49.5s** (implementer run: 690747/3 — a benign +1 pass-count run-to-run delta, Broken identical).
- gate-count regression 39/39 byte-identical; legacy dv1z/sret rejects
  unchanged (ptr_cells=false byte-identical).


## Session log — 2026-08-03 — Bennett-40ys: instance-less (closure/functor) closed-world callees; xkl diagnosis; push! now fails loud at dv1z

Orchestrated session (Fable orchestrator; Sonnet scout + hostile reviewer, 2 blind
Opus proposers + Opus implementer, strictly serial Julia). Target chosen off the
frontier: `bennettvm-xkl` (P0, push!-built Vector on the VM) — its 2026-07-21
re-scope points at closed-world extraction of the real `push!`/`_growend!` IR,
and the Dict-growth machinery it depends on landed in rnhv/0fw7.

### The wall (Bennett-40ys, filed + closed this session)

Scout probe: EVERY push!-shape (straight-line ×3, loop ×20, Int8/Int64, all three
constructor syntaxes) died identically at tier-1 extraction, <1s, before any body
walk. Julia 1.12.3 codegen OUTLINES `_growend!`'s slow path into a closure
`Base.var"#_growend!##0#_growend!##1"{Vector{Int64},…,Memory{Int64},MemoryRef{Int64}}`
reached via a real `:invoke` edge (present whether or not growth is exercised —
`argtypes=Tuple{}`, everything rides in the captured-state struct).
`_callable_of_key` (julia_set.jl:100, `k.instance`) only handled `Type{<:Type}`
and assumed-singleton `Type` → bare `UndefRefError` in the registration loop,
OUTSIDE `_extract_one`'s try/catch, so `on_extract_error=:skip` could not rescue
it. NEW capability class — the Dict corpus never hit it because rehash!/setindex!
alloc/copy INLINE via foreigncalls + LLVM intrinsics, invisible to the
`:invoke`-only walker.

### Design (3+1; docs/design/40ys/proposal_{A,B}.md) — proposers CONVERGED

Both independently found the same mechanism: emit IR from the SIGNATURE alone via
the exact internal path `code_llvm` uses — `Base._which(sig)` →
`Base.specialize_method` → `Base.Compiler.typeinf_code` →
`InteractiveUtils._dump_function_llvm` — since `f` is consumed only by
`signature_type(f, t)` (codeview.jl). Generalized to "callable type with no
`.instance`" (closures AND functors). Adjudication merged A's name-only callee
registry + call-site hook with B's full-specTypes digest + `mi.def.name` naming.

### What landed (uncommitted at review time; commit hash in git log)

- `src/extract/sig_llvm.jl` (NEW, 181 LOC): `_assert_sig_llvm_supported` (Rule-5
  capability gate naming VERSION) / `_spectypes_of` / `_method_instance_of_sig` /
  `_code_llvm_by_sig`.
- `entry.jl`: tail factored to `_parsed_ir_from_ir_string`; `extract_parsed_ir_by_sig`.
- `julia_set.jl`: total `_callee_key_kind` classifier (constructor / singleton /
  instanceless / LOUD error incl. explicit `OpaqueClosure` rejection arm),
  `_callee_barename`, specTypes digest, kind-dispatched registration; `_nameof_of`
  removed (a back-compat alias that dropped argtypes was itself a footgun).
- `callees.jl`: name-only registry `register_callee_name!`/`_lookup_callee_name`
  (case-PRESERVING — did not repeat the Bennett-wh1p bug).
- `instructions.jl`: `_emit_cell_call` hoisted verbatim out of the xrd6 arm +
  ptr_cells name-registry hook + U15 message clause.
- Tests: `test_40ys_instanceless_callees.jl` (Bennett.jl) +
  `test_40ys_closure_callee_vm.jl` (BennettVM, ZERO BVM src changes) — cross-repo
  E2E: a `@noinline` local functor callee extracted from its TYPE alone runs on
  the VM to the native-oracle value and `unrun!`s to exact initial state, empty
  history, L2 AND L3, per-step inverse.
- push! now fails LOUD at the named NEXT wall: `Bennett-dv1z` (sret struct field
  of PointerType under ptr_cells) — with the callee key named in the message.

### Gotchas for future agents (hard-won this session)

1. **`nameof(ClosureType)` is a trap**: gives `#f##0#f##1` (type name); LLVM
   symbols mangle `mi.def.name` = `#f##0`. Wrong choice ⇒ spurious closed-world
   violation, not a crash.
2. **Digest collision was real, not theoretical**: `argtypes=Tuple{}` for ALL
   such closures, so an argtypes-only digest gave `push!(Vector{Int32})` and
   `push!(Vector{Int64})` the IDENTICAL key. Full-specTypes digest fixes it
   (regression-tested Int8 vs Int64).
3. **`string(hash; base=16)` drops leading zero nibbles** — `[1:8]` on the result
   throws p≈2⁻²⁸; `lpad(…,16,'0')` fix changes digest values for ~1/16 of hashes
   (swept: no literal digests pinned anywhere in either repo).
4. **`@noinline` in body position is load-bearing** for closure fixtures —
   without it Julia inlines the closure and `transitive_callees` returns empty.
5. **1-field functors pass by coincidence**: 8-byte self makes caller cell width
   == callee width. Hostile review's 2-field probe exposed caller `[64,64]` vs
   callee `[128,64]` — inert TODAY (BVM ingest drops ParsedIR.args widths,
   decodes from byte offsets; proven green E2E) but a landmine for any future
   width consumer. Bead filed; 2-field fixture added at review time.
6. **Root-skip hazard confirmed live** (Bennett-9tg3): `:skip` + root wall ⇒
   set silently missing the root (2 unrelated throw_* bodies). Pinned as a
   known-gap testset, NOT fixed (blast radius).

### Hostile review: ACCEPT-WITH-CONDITIONS (all discharged)

Six construction attempts failed to reach the barename-collision gap today
(U114 / 416r.16 walls fire first; BVM `seen[vmname]` catches it downstream) —
defense-in-depth bead filed. `_emit_cell_call` hoist verified byte-identical.
Digest-consumer sweep clean. Beads filed this session: Bennett-40ys (closed),
Bennett-wh1p (case-folding, P2), Bennett-9tg3 (root-skip, P3, repro confirmed),
width-metadata P3, bare_to_key-guard P3. `bennettvm-m9i` annotated STALE
(pre-ADR-0017 framing); `bennettvm-xkl` annotated with the diagnosis + next wall.

### Gates (orchestrator-run, fresh subprocesses)

- Bennett.jl full `Pkg.test`: **690653 Pass / 3 Broken, 29m28.4s** (orchestrator
  re-gate after condition fixes; the 3 Broken are pre-existing, count
  byte-identical). Also discharges the 2026-07-30 cut-short-suite caveat —
  test_a70z_overflow_const_bit.jl ran green in a full suite.
- BennettVM full `Pkg.test`: **9631/9631**, 4m03.8s (was 9448 baseline; +183
  from the new file; clang absent so ~2000 asserts self-skip, bennettvm-5o86).
- Gate-count regression 39/39 (explicit-strategy baselines byte-identical).

### Next

`Bennett-dv1z` (sret ptr fields under ptr_cells) is now THE named wall for the
entire push! chain (root AND closure body wall there). After dv1z: walls inside
the closure body (`jl_genericmemory_copy_slice` etc.) per the scout's forecast.
