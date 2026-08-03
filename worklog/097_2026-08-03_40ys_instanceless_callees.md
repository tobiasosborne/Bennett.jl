# Worklog chunk 097 — 2026-08-03 — 40ys instance-less callees (xkl frontier)

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
