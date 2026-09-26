Complete: **15 findings — 4 S0, 1 S1, 9 S2, 1 S3.** Four defects produce wrong results while reversibility verification passes. QCLA fails on ordinary `x+x`; the Cuccaro repair passed all 872 regression assertions. Arithmetic passed 611,660 direct-generator and 655,360 public-compilation cases. Resource claims require correction. No source edits or full-suite execution.

- **F1 [S0]** QROM scratch recycling corrupts subsequent compact callees.
- **F2 [S0]** Tabulation truncates returns to the first argument’s width.
- **F3 [S0]** Auto-tabulation changes narrow-width arithmetic semantics.
- **F4 [S0]** Shadow stores write zero when value and primal registers alias.
- **F5 [S1]** QCLA accepts aliased operands and emits irreversible self-CNOTs.
- **F6 [S2]** Toffoli-depth ignores dependencies carried through CNOTs.
- **F7 [S2]** Multiplier y broadcast introduces linear circuit depth.
- **F8 [S2]** Callees and loops silently discard explicit arithmetic strategies.
- **F9 [S2]** Feistel permutation and odd-width mixing contradict documentation.
- **F10 [S2]** False guarded stores clear unused high bits.
- **F11 [S2]** QROM literature resource claims mismatch emitted costs.
- **F12 [S2]** Arithmetic benchmark tables retain obsolete baselines.
- **F13 [S2]** Tabulation bypasses strategy and target validation.
- **F14 [S2]** Non-power-of-two QROM tables trigger misleading conversion errors.
- **F15 [S3]** Adder-tree replay documentation is stale; reuse-pool option is unused.