# Triage — B-lowering — 2026-09-26

Orchestrator triage of `B-lowering.md` after independent re-execution of all 13 S0/S1 findings
(`B-lowering.verification.md`: 13/13 CONFIRMED, no severity changes; F7 needs `compact_calls=true`,
F15 needs `mem=:persistent`, F6 needs `fold_constants=false`). c6ex relation: F5/F18/F16/F8 are holes
c6ex left (not regressions); F1 is unrelated (memory.jl); F17's sentinel edge is explicitly admitted by
c6ex's CFG validator.

| Finding | Sev | Disposition |
|---|---|---|
| F7 QROM free-list reuse corrupts compact callees (compact_calls=true) | S0 | DUPLICATE → Bennett-9k7n (P1); = arith F1 |
| F1 select-ed pointer store ignores block predicate | S0 | Bennett-37w3 (P1, CORE → 3+1) |
| F2 zero-offset GEP after dynamic GEP loads stale memory | S0 | Bennett-jkf0 (P1) |
| F3 narrowing keeps source-width shift guards + F13 narrowing breaks tuple layout | S0/S1 | Bennett-mrhg (P1) |
| F5 loop-header side effects continue after exit (silent) | S0 | Bennett-i5zn (P1, CORE → 3+1); note on Bennett-8nfb |
| F18 irreducible region treated as natural loop | S0 | Bennett-73gr (P1, CORE → 3+1) |
| F6 gate groups miss stores/zero-gate allocas → ValueEager drops writes (fold_constants=false) | S0 | Bennett-o23d (P2) |
| F15 mem=:persistent dynamic alloca loses the 5th write | S0 | Bennett-9378 (P1) |
| F17 reachable error branches erased (tuple bounds) | S1 | Bennett-jzhh (P1) |
| F8 untaken loop fails convergence guard | S1 | DUPLICATE → Bennett-n9o8 (note added) |
| F4 MUX-EXCH rejects negative constant store | S1 | Bennett-ovzp (P2) |
| F16 loop-exit heuristic rejects a valid 5-block loop | S1 | DUPLICATE → Bennett-8nfb (note added) |
| F9 callees drop caller options | S2 | DUPLICATE → Bennett-0a6f/vpgj/jgyx (note added) |
| F10 folding disables group strategies | S2 | DUPLICATE → Bennett-exb3 |
| F11 unused unknown-pointer load silently dropped | S2 | DUPLICATE → Bennett-sy9t (note added) |
| F14 MUX-EXCH 6–14× shadow arm | S3 | DUPLICATE → Bennett-vscb (note added) |
| F12 allocator frees invalid wire ids | S3 | Bennett-89m1 (P3) |

All new beads carry label `astra-2026-09-26` and `discovered-from:Bennett-yjd5`.
