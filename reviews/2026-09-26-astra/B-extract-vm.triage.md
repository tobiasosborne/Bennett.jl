# Triage — B-extract-vm — 2026-09-26

Orchestrator triage of `B-extract-vm.md` after independent re-execution of all 13 findings
(`B-extract-vm.verification.md`: 13/13 CONFIRMED; F10 upgraded S1→S0 with a new silent witness).
Note: `B-extract-core.verification-B.md` cites extract-vm F3/F5/F8 under an older numbering — read F9/F12/F13.

| Finding | Sev | Disposition |
|---|---|---|
| F1 mem=:vm Vector prelude collapse deletes user returns / SSA defs (real Julia) | S0 | Bennett-q5hc (P1) |
| F2 two Dict objects merged into one map (real Julia) | S0 | Bennett-po36 (P1) |
| F3+F4 Dict skeleton taint deletes mutating helper calls; user branch on Dict state flattened (real Julia) | S0 | Bennett-bc2m (P1) |
| F5 Vector re-root turns reachable conversion failures into truncated results (real Julia) | S0 | Bennett-o6ge (P1) |
| F7 heap escape check accepts caller-owned pointer args, drops writes (from_ll) | S0 latent | Bennett-f4z4 (P2) |
| F9 recursive root re-added as callee → duplicate canonical key (= extract-core F16) | S1 | Bennett-okcg (P2) |
| F12 MemorySSA stderr pipe deadlock >64 KiB (= extract-core F15) | S2 | Bennett-rh62 (P3) |
| F6 heap recognition drops atomicrmw (from_ll) | S0 latent | DUPLICATE → Bennett-7v22 (note) |
| F8 certified empty-Memory pointers compare incorrectly (real Julia, ptr_cells) | S0 | DUPLICATE → Bennett-eqjl (note; P3→P1; caused by hsm3 data-pointer sentinel) |
| F10 mixed-case callee names: Foo/foo both bind to foo — silent (real Julia) | S0 | DUPLICATE → Bennett-wh1p (note; S1→S0, P2→P1) |
| F11 skip mode returns empty set, skipped list never surfaced | S2 | DUPLICATE → Bennett-9tg3 (note) |
| F13 MemoryPhi annotation overwrites store def location | S2 | OVERLAPS Bennett-7nez (note) |

All new beads carry label `astra-2026-09-26` and `discovered-from:Bennett-yjd5`.
