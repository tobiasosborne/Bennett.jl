23 verified findings: **8 S0, 7 S1, 8 S2**. Silent failures affect caching, tabulation, unsigned decoding, and checkpoint replay. Eager fails on real QCLA lowering; ValueEager can leave ancillae dirty.

The positive-budget verifier catches missing uncompute gates. Bennett-q9pi’s compose/control guard fixes passed all 6,669 regression assertions. Verification still has vacuous-success and malformed-input gaps.

All **14,931 assertions across 14 focused test files passed**; additional probes reproduced the findings below. No full suite was run.

- F1 — **S0:** Recompiling a redefined function returns its old circuit.
- F2 — **S0:** Automatic tabulation changes narrowed arithmetic semantics.
- F3 — **S0:** Tabulation truncates wider return values.
- F4 — **S0:** Controlled simulation misdecodes unsigned outputs.
- F5 — **S0:** Checkpoint replay permutes result bits.
- F6 — **S0:** Simulator silently truncates wide values.
- F7 — **S0:** Duplicate input wires bypass preservation checks.
- F8 — **S0:** Five self-reversing strategy paths discard failing loop guards.
- F9 — **S1:** Eager cleanup replays writes using incorrect historical controls.
- F10 — **S1:** ValueEager leaves dead ancestors unclean.
- F11 — **S1:** Fixed self-reversing probes accept false cleanup claims.
- F12 — **S1:** Nonpositive verification budgets certify dirty circuits.
- F13 — **S1:** Irreversible self-controlled gates can pass verification.
- F14 — **S1:** Dependency extraction omits read-before-write hazards.
- F15 — **S1:** Cached compilation rejects supported callable objects.
- F16 — **S2:** Toffoli depth loses dependencies through CNOTs.
- F17 — **S2:** Peak-live measurement reports only all-zero-input Hamming weight.
- F18 — **S2:** Forward-half guessing misanalyzes valid circuits.
- F19 — **S2:** Gate-level pebbling expensively reproduces Default unchanged.
- F20 — **S2:** Folding disables group strategies; PebbledGroup ignores budgets.
- F21 — **S2:** Identical narrowed compilations retain duplicate circuits indefinitely.
- F22 — **S2:** Left-associated composition grows exponentially.
- F23 — **S2:** Tabulation bypasses keyword-value validation.