# Bennett-c6ex — orchestrator review of proposals A and B

2026-09-24. Both proposals archived verbatim alongside.

## Headline (both proposers, independently, with measurements)
The v2 review's two phi.jl sites are silent only on MALFORMED IR (phi citing a non-predecessor,
unexpanded IRSwitch) — valid LLVM does not reach them. But both proposers found **real silent
miscompiles from plain Julia at optimize=false in `lower_loop!`**: a loop header with >1
pre-header incoming keeps only the LAST pre-header value (A: `pre2` 1143/2304 wrong, `pre4`
2268/2304; B: g1 40/256, g2/g4 128/256). Only the last latch incoming is kept too (hand .ll:
A 48/119, B 160/256). B additionally: a second loop exit (`break`) at optimize=false is never
modelled — iterations continue past the break (l5: 96/256 wrong) — and the exit block need not
have a phi, so a phi-membership check alone does NOT catch it.

## Decisions (synthesis)
1. **Multi-preheader header phis — merge by edge predicate** (both agree): single-preheader path
   byte-identical (`resolve!`), else `resolve_phi_predicated!` over FUNCTION-LEVEL block_pred /
   branch_info with phi_block = header. Pointer-typed (width 0) multi-preheader phi → loud error (A).
2. **Multi-latch → loud error (A)**, not B's latch merge. Rationale: optimize=true (default)
   loop-simplify guarantees one latch, Julia `continue` lowers through a merge block (A), so
   multi-latch arises only from hand .ll; adding merge logic to the highest-risk code for a
   path no Julia program reaches is not worth it. Fix the `_collect_loop_body_blocks` docstring
   that falsely claims it fails loud.
3. **Second loop exit → loud error in `_collect_loop_body_blocks` (B)** — required: A's
   membership check misses exits without phis (B's l5). Tests that newly fail on it are latent
   miscompiles: mark `@test_broken` + file a bead (real multi-exit support), never weaken.
4. **Up-front CFG validator at `lower()` entry (B's `_check_predication_cfg`)**: V1 only
   IRBranch/IRRet terminators (IRSwitch must be expanded), V2 targets exist, V3 entry has no preds,
   V4 phi incomings ⊆ preds, every pred has an incoming (coverage), duplicate incomings agree.
   Plus A's membership assert in `lower_phi!` (covers in-loop `iter_preds` too) — cheap defence in depth.
5. **Same-target conditional branches → canonicalise to unconditional (B)** before lowering
   (identity when absent ⇒ byte-identical otherwise); fixes valid-IR false rejections (switch whose
   last case targets the default). Both phi.jl functions additionally assert tl ≠ fl.
6. **Site 1 / dead blocks**: unreachable-from-entry blocks get no predicate and record no edges
   (either A's `unreachable` kwarg or B's driver change — implementer's choice); the `continue`
   becomes an assert; the third silent arm (branch_info with neither target = label) → assert.
7. **Site 2**: neither-target arm → assert (both); the no-branch_info fallthrough is protected by
   the membership invariant (A's CE3u shows it is otherwise silent).
8. Optional debug-mode mutual-exclusion auditor (B §4.5): include if cheap (zero gates when off);
   useful as a test oracle for P4.
9. fq8n T1–T3 fixture: pass a consistent `preds` (A §5f).

## Gate counts
Must be identical for every currently-correct program (both measured: A 14 fns, B 29 programs +
12 loop programs). Changes only for previously-wrong or previously-rejected programs.

## Tests
Union of A §7 and B §6: pre2/pre4/g1/g2/g4 exhaustive (red today), H5/H6′/two-latch .ll,
l5 second-exit throws, CE3/CE3c/CE3u/H9 non-predecessor throws, unexpanded-IRSwitch ParsedIR throws,
H1/H1b/H2 same-target now compile (0 wrong), CE1/H4c dead block benign, CE1c dead chain compiles,
unit tests for each assert, gate-count pins for the green guards, auditor 0 violations.
**The FULL suite must run after this lands** (validator false positives from extraction
rewrites — sret, ptr_cells pruner, `_expand_switches` A11 — are the main risk; any hit is a latent
extraction bug to file, not a reason to weaken the validator).

## Follow-ups to file
`_expand_switches`: emit unconditional br for same-target cmp blocks + dedupe (val,pred)
incomings (412→392 gates; baseline change); A11 fail-loud at source; `LLVM.verify` on .ll ingest;
natural-loop exit identification (`br c, body, exit` headers, latch exits); `:__unreachable__`
KeyError in `_collect_loop_body_blocks`; real multi-exit loop support; loop convergence guard not
gated by the header predicate (B); unused last-incoming edge predicate in resolve_phi_predicated!.
