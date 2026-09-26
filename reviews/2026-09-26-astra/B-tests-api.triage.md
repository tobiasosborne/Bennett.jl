# Triage — B-tests-api — 2026-09-26

Orchestrator triage of `B-tests-api.md` after independent re-execution of the ten S1 findings
(`B-tests-api.verification.md`: 10/10 CONFIRMED; F8/F20 downgraded to S2 suite-wide; S2 claims spot-checked, 6/7 by execution).

| Finding | Sev | Disposition |
|---|---|---|
| F4 captured closure variables become extra circuit inputs (x->x-k → widths [8,8], wrong result) | S1 | Bennett-o9sv (P1) |
| F9 mixed-width tests convert compiler exceptions into @test_broken | S1 | Bennett-8gkj (P2) |
| F15 ABI regression pins pass via @test true when callees disappear | S1 | Bennett-z1o8 (P2) |
| F19 loop-corruption fixture has no loop under optimize=true | S1 | Bennett-s99j (P2) |
| F20 registry concurrency tests pass with lookup broken | S1→S2 | Bennett-bn0p (P3) |
| F8 constant-folding equivalence tests compare folded vs folded | S1→S2 | Bennett-oac7 (P3) |
| F2 test_args typo passes when another pattern matches | S2 | Bennett-xlpl (P3) |
| F3 standalone test file command fails (69 files lack using Test) | S2 | Bennett-0f6j (P3) |
| F11 README/tutorial snippets fail as written | S2 | Bennett-b4wh (P2) |
| F13 BENNETT_CI=1 breaks its own guard test | S2 | Bennett-n7ur (P3) |
| F16 research maps always loaded, tests gated off | S2 | Bennett-v1nq (P3) |
| F17 sampled Int8 tests violate the exhaustive rule | S2 | Bennett-cr5l (P3) |
| F21 Tuple{Float64} vs Float64 signature asymmetry (fmul unsupported) | S2 | Bennett-19jw (P2) |
| F1 doctest guard passes while doctests disabled | S1 | DUPLICATE → Bennett-gygy (note) |
| F5 n_tests ≤ 0 certifies dirty circuits | S1 | DUPLICATE → Bennett-ukup (fixed this session) |
| F6 tabulate truncates wider returns | S0 | DUPLICATE → Bennett-iwj6 |
| F7 stale compile after redefinition | S0 | DUPLICATE → Bennett-4ddk |
| F10 tabulate skips option validation | S2 | DUPLICATE → Bennett-iwj6 |
| F12 simulate accepts over-wide integers | S1 | DUPLICATE → Bennett-qa2g (fixed this session) |
| F14 Feistel tests accept an identity primitive | S1/S2 | DUPLICATE → Bennett-z3j3 (note: whole file vacuous) |
| F18 Float64 target-propagation test passes while target ignored | S1 | OVERLAPS Bennett-0a6f (note) |
| F22 documented Float64 fma fails | S1 | DUPLICATE → Bennett-8aes (note; docs advertise fma) |

All new beads carry label `astra-2026-09-26` and `discovered-from:Bennett-yjd5`.
