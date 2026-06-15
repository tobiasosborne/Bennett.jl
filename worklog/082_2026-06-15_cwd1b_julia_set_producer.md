# 082 — 2026-06-15 — CW-D1b — extract_parsed_ir_set_from_julia (closed-world producer)

**Bead:** `bennettvm-416r.11` (CW-D1, BVM) — chunk **b** of three (D1a walker ✓ /
**D1b set producer** / D1c BVM linkage). The closed-world path to **SC9 Case B**
(`fdict`, `bennettvm-7xa`). Case B = closed-world execution is **SETTLED** (ADR-0017,
lead, 2026-06-10) — RevMap is demoted (`o1y`); see bd memory `case-b-closed-world-settled`.
**Code home:** Bennett.jl front-end. Additive (1 new file + 1 include + 1 export),
Rule-14 crossing under standing approval.

## What landed
- **NEW `src/extract/julia_set.jl`** (~340 LOC): `extract_parsed_ir_set_from_julia(f,
  argtypes; optimize=false, include_root=true, drop_throw_leaves=true,
  on_extract_error=:fail_loud, mem=:auto) -> Vector{Pair{Symbol,ParsedIR}}` — drives
  D1a's `transitive_callees`, extracts root + each helper body, keys them by drift-free
  canonical `Symbol("<barename>#<argtype-digest>")`, and runs `_closed_world_check!`.
- `src/ir_extract.jl` include after `callgraph.jl`; export in `Bennett.jl`.
- **NEW `test/test_d1b_julia_set.jl`** Gates A–G (30 Pass / 1 Broken).

## The D1b ground truth — a BLOCKER surfaced (and why D1b still shipped)
The design pass found that **0/4 fdict callee bodies extract today**: `setindex!`/`rehash!`
hit the **U81** ptr-width wall (`unsupported LLVM type for width query: PointerType`),
`ht_keyindex2_shorthash!` hits the **Bennett-dv1z** heterogeneous-sret wall
(`Tuple{Int64,Int8}`), `AssertionError` is a throw-leaf. ADR-0021 confirmed the IR is
*recoverable* via `code_llvm`; this probe found *lowering it through `extract_parsed_ir`*
walls. **This is the accepted closed-world runway the lead chose over RevMap (the longer
runway), NOT a pivot trigger.** So D1b ships the producer + linkage + closed-world
machinery, proven on a synthetic extractable root (`root_d1b(x)=h_d1b(x)+g_d1b(x)`,
`@noinline` helpers), with `fdict` as an HONEST tripwire: `:fail_loud` `@test_throws` a
real wall; `:skip` `length>=4` is `@test_broken` — auto-flips when the walls clear
(CW-D2). The "≥4 ParsedIRs for fdict" gate text is BLOCKED on CW-D2, not on D1b.

## Design crux — inter-callee linkage (Rule-5-safe)
Set keys are canonical (from the walker's `specTypes`, never mangled `j_*_NNN`). An
in-body IRCall resolves: `Function` callee → `nameof`; `Symbol` callee → demangle (reuse
`_lookup_callee`'s regex, drop `_NNN`) → bare-name lookup. Multi-candidate (same name,
diff specialization) → fail loud (arity-disambiguation deferred to CW-D2). `transitive_callees`
is `:invoke`-only by design; `_closed_world_check!` is the COMPLETENESS enforcer — every
IRCall must resolve in-set / throw-leaf / benign-intrinsic else fail loud (ADR-0021 Decision 2).

## Method (3+1) + hostile review fixes
Ground-truth → 2 blind proposers → synthesis → Opus implementer → +1 + hostile review.
Implementer adaptation: the producer `register_callee!`s live callees (else the body
walk hits the U15 unregistered-call guard). **Orchestrator hardening + hostile-review fixes
landed BEFORE commit:**
- **register-pollution (orchestrator):** the producer was permanently mutating the
  process-global `_known_callees` — a real interlock (`test_bd5f_heap_m4`, which pins
  Dict-rejection and runs *after* this in `runtests.jl`, depends on `setindex!` being
  UNregistered). Fixed: SNAPSHOT + SCOPED restore in a `finally` (touch only the keys this
  call added — race-tolerant, not a destructive `empty!`; **S2**). Gate G guards it
  permanently.
- **S1:** canonical-key barename parsed with `rsplit(…, "#"; limit=2)` (a closure barename
  `#9` contains `#`; `split[1]` gave "").
- **S3:** Gate E now captures & asserts a genuine extractor-wall signature, not the
  wrapper's hardcoded hint.
- **N2:** "stable across processes" → "within-process deterministic" (keys never serialized).
- No BLOCKER from hostile review; additivity + the bd5f interlock independently verified.

## Gates (orchestrator-run, fresh subprocess)
`test_d1b` 30 Pass / 1 Broken; `using Bennett` clean precompile; gate-count regression
39/39 (lowering untouched). Full `Pkg.test` deferred to the CW-D1 pre-push.

## Follow-ups filed
- `bennettvm-2k1k` (P3): unify `_D1B_BENIGN_INTRINSIC_PREFIXES` with `instructions.jl`'s
  `benign_prefixes` behind one shared const (deferred to keep D1b additive).

## Next (the closed-world runway)
The long pole to a REAL `fdict`: the extractor extensions that make Dict helper bodies
lower — **ptr_cells-for-Julia** (ADR-0021 Decision 2) + **U14 atomic-load collapse**
(Julia `GenericMemory` `load atomic … unordered` → plain load, single-thread VM) +
**dv1z heterogeneous-sret** (`Tuple{Int64,Int8}`). These are core extractor changes
(each a 3+1 + full-suite gate). Then D1c (BVM linkage; ADR-0021 allows a hand-stitched
set first) → CW-D2 whitelist → CW-D3 globals → `7xa` e2e.
