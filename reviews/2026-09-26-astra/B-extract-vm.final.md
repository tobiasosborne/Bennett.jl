**FAIL: 13 confirmed findings — 8 S0, 2 S1, 3 S2.**

Six real-Julia VM counterexamples produce wrong behaviour yet reverse cleanly. A synthetic heap atomic-update case produces wrong results for all 256 Int8 inputs while reversibility passes. All **260 existing targeted test assertions pass**. The hsm3 certification repair passes its negative tests, but singleton identity remains incorrect; Bennett-23ml remains outstanding.

- **F1 [S0]** Vector prelude collapse deletes user returns and needed SSA definitions.
- **F2 [S0]** Independent Dict objects silently merge into one map.
- **F3 [S0]** Dict skeleton suppression deletes mutating helper calls.
- **F4 [S0]** Untaken Dict mutations execute after user branches are flattened.
- **F5 [S0]** Reachable conversion failures become successful truncated results.
- **F6 [S0]** Heap recognition silently drops atomic updates.
- **F7 [S0]** Heap escape checks permit deleting writes through caller-owned pointers.
- **F8 [S0]** Certified empty Memory pointers compare incorrectly.
- **F9 [S1]** Recursive roots are duplicated and rejected.
- **F10 [S1]** Mixed-case callees fail closed-world extraction.
- **F11 [S2]** Skip mode silently returns an empty program.
- **F12 [S2]** MemorySSA printing deadlocks when its pipe fills.
- **F13 [S2]** MemorySSA parsing overwrites store definitions with MemoryPhi annotations.