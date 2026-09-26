**18 confirmed findings: 8 S0, 5 S1, 3 S2, and 2 S3.** All inherited findings were independently reproduced; two new failures were added.

Serious defects silently corrupt results while reversibility passes. Ordinary Julia reproducers confirm the QROM/call miscompile and lost tuple bounds errors; LLVM-verified fixtures confirm memory and irreducible-CFG failures. Cuccaro ownership and isolated memory primitives retain substantial passing coverage. MUX-EXCH costs 6–14× the existing shadow alternative.

- **F7 [S0]** QROM free-list reuse corrupts compact inlined callees.
- **F1 [S0]** Selected-pointer stores ignore the store block’s predicate.
- **F2 [S0]** GEP composition silently loads stale or incorrect memory.
- **F3 [S0]** Width narrowing preserves incompatible shift guards.
- **F5 [S0]** Loop-header side effects continue after exit.
- **F18 [S0]** Irreducible regions lose effects from edges entering their bodies.
- **F6 [S0]** Missing gate groups let ValueEager erase memory writes.
- **F15 [S0]** Dynamic allocations silently inherit a four-write history limit.
- **F17 [S1]** Tuple bounds violations return values instead of errors.
- **F8 [S1]** Untaken loops can fail convergence checks.
- **F4 [S1]** MUX-EXCH rejects negative constant stores.
- **F16 [S1]** Exit heuristics reject ordinary natural loops.
- **F13 [S1]** Narrowing breaks tuple layouts and return widths.
- **F9 [S2]** Inlined callees discard compilation options.
- **F10 [S2]** Constant folding disables group-based cleanup strategies.
- **F11 [S2]** Unused unknown-pointer loads disappear silently.
- **F14 [S3]** MUX-EXCH dispatch selects a substantially more expensive implementation.
- **F12 [S3]** The allocator accepts invalid and never-allocated wire IDs.