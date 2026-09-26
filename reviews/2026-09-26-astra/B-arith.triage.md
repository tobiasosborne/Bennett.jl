# Triage — B-arith — 2026-09-26

Orchestrator triage of `B-arith.md` after independent re-execution of F1–F5 and dedup of
F1–F15 (`B-arith.verification.md`: F1–F5 CONFIRMED; F4 S0→S2 latent, F14 S2→S3).

| Finding | Sev (final) | Disposition |
|---|---|---|
| F1 QROM free-list reuse corrupts compact inlined callees | S0 | DUPLICATE → Bennett-9k7n (note added with both witnesses, P→1); = lowering F7 |
| F2 tabulate truncates return to first-arg width | S0 | DUPLICATE → Bennett-iwj6 (circuit-core F3) |
| F3 tabulate ≠ narrowed semantics (W=2 witness) | S0 | DUPLICATE → Bennett-iwj6 (circuit-core F2) |
| F4 shadow store writes zero on val==primal alias (primitive API only) | S2 | Bennett-owsk (P3); overlaps Bennett-lcye |
| F5 add=:qcla self-CNOTs on x+x; stwr covered :cuccaro only | S1 | Bennett-retr (P2) |
| F6 toffoli_depth drops CNOT-carried deps (multiplier depth tables, paper-match tests, q22p claim) | S2 | OVERLAP → notes on Bennett-u3b2 and Bennett-q22p |
| F7 mul_qcla_tree serialises y broadcast (Ω(W) depth) | S2 | Bennett-1f92 (P2) |
| F8 callees/loops discard explicit arithmetic strategies | S2 | DUPLICATE → Bennett-0a6f + Bennett-vpgj (= lowering F9) |
| F9 Feistel permutation/odd-width contract vs code; vacuous avalanche test | S2 | Bennett-z3j3 (P2) |
| F10 guarded softmem store clears unused high bits on pred=0 | S2 | Bennett-brsg (P2) |
| F11 QROM literature T/ancilla claims vs emitted costs | S2 | Bennett-kj78 (P2) |
| F12 BENCHMARKS x+1 rows stale (100/204/412/828) | S2 | OVERLAP → note on Bennett-t3ou |
| F13 tabulate skips option validation (+ retired mul=:karatsuba accepted) | S2 | DUPLICATE → Bennett-iwj6 (circuit-core F23) |
| F14 emit_qrom! non-pow2 L → InexactError before ArgumentError | S3 | Bennett-uzi5 (P3) |
| F15 adder-tree docstring schedule ≠ code; reuse_pool inert | S3 | Bennett-3mfb (P3) |
