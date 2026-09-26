# Triage — B-circuit-core — 2026-09-26

Orchestrator triage of `B-circuit-core.md` after independent re-execution of F1–F15
(`B-circuit-core.verification.md`: all 15 CONFIRMED; severity adjusted F7→S1, F8→S1, F14→S2).

| Finding | Sev (final) | Bead |
|---|---|---|
| F1 stale circuit after method redefinition, F15 callable objects rejected, F21 duplicate narrowed circuits retained | S0/S1/S2 | Bennett-4ddk (P1) |
| F2 tabulate ≠ narrowed expression semantics, F3 return width truncated, F23 kwarg values unvalidated on tabulate path | S0/S0/S2 | Bennett-iwj6 (P1) |
| F4 controlled() misdecodes unsigned outputs | S0 | Bennett-u91f (P1) |
| F5 Checkpoint/PebbledGroup replay permutes result bits | S0 | Bennett-uhk3 (P1) |
| F6 simulate truncates wide values, no range check at width ≥ 64 | S0 | Bennett-qa2g (P1) |
| F7 duplicate input wires / width totals accepted; verifier certifies | S1 | Bennett-q7yd (P2) |
| F8 five self-reversing fast paths drop failing loop guards | S1 | Bennett-ui55 (P2) |
| F9 Eager replays writes against wrong historical controls (real qcla witness) | S1 | Bennett-3vji (P2) |
| F10 ValueEager strands dead ancestors | S1 | Bennett-htu2 (note added, P3→P2) |
| F11 fixed self-reversing probes accept a false claim | S1 | Bennett-lxk7 (note added) |
| F12 verify_reversibility(n_tests≤0) returns true | S1 | Bennett-ukup (P2) |
| F13 self-controlled gates accepted, pass verifier | S1 | Bennett-lcye (note added) |
| F14 dep_dag omits WAR hazards (latent: unexported, unused) | S2 | Bennett-n4ws (P3) |
| F16 toffoli_depth drops dependencies through CNOTs | S2 | Bennett-u3b2 (P2) |
| F17 peak_live_wires is an all-zero Hamming-weight trace | S2 | Bennett-kk3y (P2) |
| F18 forward-half guessing in dep_dag / constant_wire_count | S2 | Bennett-zcve (P3) |
| F19 PebbledStrategy is identity + O(n²s) DP | S2 | Bennett-mjtl (note added) |
| F20 folding disables group strategies; PebbledGroup ignores budget | S2 | Bennett-exb3 (note added) |
| F22 left-folded compose grows exponentially | S2 | Bennett-7c5u (P2) |
| Nits (compose wording, 7-arg ctor docs, cache comment) | S4 | Bennett-82jc (note added) |

All new beads carry label `astra-2026-09-26` and `discovered-from:Bennett-yjd5`.
