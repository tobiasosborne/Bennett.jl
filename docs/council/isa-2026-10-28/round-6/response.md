# Editor's response to ISA round 6

Verdicts: **muse accept** (core and overall), codex revise, opus revise.
Mean 3.92 (2.12 → 2.83 → 3.04 → 2.83 → 3.12 → 3.92). Six blockers
(codex 4, opus 2), all S0, all accepted; three are core. Draft 0.7
corrects them by surgical edits. Status reported to the maintainer:
**no-go**, one member accepting, no criterion below 3.

## Regression acknowledged

Draft 0.6's positivity rule for the SDP witness ("every leading
principal minor nonnegative") was **false** (codex B11, opus B2;
counterexamples Z·Z − id and diag(0, −1)). Introduced by the editor in
0.6 while printing the SDP. Removed.

## Accepted and changed

| Blocker | Scope | Change in 0.7 |
|---|---|---|
| codex B1 (A-row indexed destinations) | core | §3.6 step 4: an A row's inverse exchanges run in the reverse of the forward exchange order, every address evaluated from the state current at that exchange; `lift.alloc`'s row prints its forward slot order and inverse exchange order (atop, heap_used, alloctab[atop] at the restored atop, w) |
| codex B3 (nested cancellation) | core | §7.4: one **history traversal** (LIFO; skip reversed frames and `uncall` frames; undo and mark the rest) shared by segment `uncall` and whole-run reversal, applied recursively; the clock counterexample is a suite-A case |
| opus B1 (`uncall` over `measure`) | core | §7.4: a segment containing a `measure` frame at any depth (or an unverified hardware `qreg.free`) cannot be uncalled: CC trap, no state change; §3.3 handle table: a `measure` frame is never reversed; suite A case |
| codex B10 (realisation context) | contract | §12.1: a subject denotes every invocation context of the region in the root schedule (path, resolved arguments, budget, shares, cleanup choices); claims are checked in every context; `error` entries are verified common upper bounds over all contexts of their key, which is what makes the multiplicity composition of §12.3 sound; `channel` carries one witness per context |
| codex B11, opus B2 (PSD acceptance) | contract | §12.1: the checker proves strict positive definiteness by interval Cholesky / LDL† with every pivot's interval lower bound > 0 and rejects otherwise; producers shift witnesses by δ (Y + δI, mu + δ·d) to make them strictly feasible |

## Declined

- Codex's alternative for B10 (per-invocation subjects composed
  separately): the conservative common bound is taken for 0.7, as codex
  also recommended. Per-invocation keys can be added when a scheduler
  produces them.
- Opus's alternative for B1 (static suite-F prohibition of `measure`
  under any uncalled callee): the dynamic trap is taken, as opus also
  recommended.

## Mechanical check

`python3 tools/isa_check.py` passes on 0.7: both examples execute as
stated (including the example-2 stack boundary), all four hashes are
recomputed under `isa=0.7`, both printed envelopes verify.
