# Bennett-zf5v — CW-D2: gc_preserve token drop + get_pgcstack allowlist (3+1 adjudication)

Orchestrator-reviewer decision after 2 proposers + a DEFINITIVE optimize-level probe. 2026-06-20.

## 3+1 adjudication
- **Proposer A** took the bead at face value (get_pgcstack inline-asm GC-frame recognizer, reuse heap.jl).
  A independently flagged an UNRESOLVED "asm-vs-intrinsic" divergence it couldn't reconcile — the tell.
- **Proposer B** re-probed at optimize=FALSE and OVERTURNED the premise: the closed-world producer
  (`extract_parsed_ir_set_from_julia`) extracts bodies at optimize=false (julia_set.jl:185/231/261),
  where get_pgcstack is the named intrinsic `@julia.get_pgcstack()` and ALREADY lowers cleanly under
  ptr_cells. The inline-asm `movq %fs:0` form is an optimize=TRUE artifact, NOT on the real path.
- **Orchestrator probe (DEFINITIVE):** at optimize=false, ptr_cells=true: ROOT fdict_d1b walls at
  `llvm.julia.gc_preserve_begin` TokenType (NOT get_pgcstack; `has movq %fs:0 asm: false`,
  `has @julia.get_pgcstack: true`). => ADOPT PROPOSER B. Discard A's GC-frame approach (wrong premise).
  Bennett-6x2w closed as superseded.

## Decision (Proposer B's design)
Two surgical, additive, ptr_cells-gated edits:
1. **instructions.jl** — in the ptr_cells C-call arm (~2135), at the TOP (BEFORE the variadic arg loop
   and BEFORE the return-type check at ~2161), special-case
   `cname == "llvm.julia.gc_preserve_begin"` (token return) and `"llvm.julia.gc_preserve_end"` (void,
   consumes only the token) -> `return nothing` (drop). Pure GC-rooting bookkeeping; no value semantics
   in the VM cell model. Placement at the top avoids B's risk #3 (variadic `call token (...)` arg-carry
   hitting the TokenType error first). Any OTHER token-returning call still walls (Rule 1).
2. **julia_set.jl** — add `"julia.get_pgcstack"` to `_D1B_BENIGN_INTRINSIC_PREFIXES` (line 45) so the
   emitted get_pgcstack cell IRCall survives `_closed_world_check!` (the cell is MODELED, not dropped —
   it feeds the `gep -152` current_task chain).

## Verified ground truth (optimize=false, ptr_cells=true, 2026-06-20)
- ROOT fdict_d1b -> gc_preserve_begin TokenType wall (THIS lever).
- get_pgcstack lowers fine (intrinsic form); the gep -152/+168/+16 chain lowers as IRPtrOffset/IRLoad cells.
- Next root wall after this lever: gc_alloc_obj / genericmemory live allocations (follow-up levers).

## Byte-identity / fail-fast
- Circuit (ptr_cells=false) + mem=:heap unchanged (ptr_cells-gated; julia_set is closed-world only).
  Baselines i8 x+1=58, gate_count 39/39 hold.
- Only exact `llvm.julia.gc_preserve_begin`/`_end` names dropped; other token returns still fail loud.

## Tests — test/test_zf5v_gc_preserve.jl (RED-GREEN)
- (a) hand-built .ll: gc_preserve_begin(token)+gc_preserve_end(void) DROPPED under ptr_cells=true; the
      surrounding chain (get_pgcstack -> gep -152 -> gep 168 -> load -> gep 16) lowers intact
      (IRCall cell + IRPtrOffset/IRLoad). RED today (TokenType wall).
- (b) ptr_cells=false: same fixture still walls (byte-identity).
- (c) fail-loud: a DIFFERENT token-returning callee still walls at the TokenType error (drop is
      exact-name-scoped); a non-allowlisted inline asm still walls at U15.
- (d) real fdict_d1b root wall-ADVANCE (optimize=false, ptr_cells=true): negative (no longer
      gc_preserve/TokenType), positive disjunction (gc_alloc_obj/genericmemory/memcpy/unregistered).
      Registry snapshot/restore (Rule 7).
- gate_count 39/39 + i8 x+1=58 regression inline.
