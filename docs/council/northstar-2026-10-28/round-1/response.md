# Editor's response to round 1

All three members returned `revise` (mean 2.62). Their blocking issues
cluster into eight themes; every theme was accepted and the document was
rewritten (iteration 2). Where a point was accepted with a correction, the
correction is stated.

## Accepted and changed

1. **§3 extension-point table overclaimed** (codex B2, muse B1, opus B1).
   Rewritten as §3.1 around mechanisms an out-of-tree plugin has: declared
   marker functions (no plugin-registered intrinsics), opaque handle
   pointers in an address space (front ends can emit these; target
   extension types cannot be emitted and are unsized out of tree), taint
   by analysis not types, bounds as real operands of marker calls (no
   metadata), garbage from liveness (no lifetime intrinsics), legality as
   the ordinary property of non-speculatable side-effecting calls (no
   invented attributes; `convergent` dropped). The legality spike is now a
   gate on freezing the dialect spec (§3.2, §9.1). Upstream patch, not
   fork, wherever LLVM-side support is genuinely needed.
2. **Compilation model missing** (muse B2, opus B3, codex C5). New §3.3:
   link time over whole-program bitcode, fat objects, our own driver with
   clang offload as the model not the mechanism, host-triple IR accepted
   by the lowering, per-front-end integration named (clang `-flto`; rustc
   via bitcode emission because in-process plugins are nightly-only; Julia
   via LLVM.jl). "Loaded by clang, rustc and Julia without modification"
   is withdrawn and replaced by "any front end that emits bitcode".
3. **Effects under superposition undefined** (codex B1, muse B4, opus B4).
   New §4.2 effect table per tier: coherent regions are closed and
   effect-free, devices virtualised as reversible state inside the device,
   classical inputs fixed before entry, outputs through measurement after
   exit, unvirtualisable effects refused at compile time by name. §0
   restated as "every defined, effect-bounded execution". Rungs 4, 7, 8
   rewritten with fixed classical state, virtualised devices, and
   acceptance tests.
4. **Two control classes conflated** (codex B3, muse B3, opus C3). §4.2
   now separates classical control (dynamic) from coherent control
   (predicated, padded to a classical bound fixed before entry). Run-time
   policy may inspect only classical data, stated as an architectural
   invariant. The implication that run-time bounds unlock superposed trip
   counts is withdrawn explicitly. Honest costs of superposition added
   (§4.3): both arms paid, O(N) quantum-addressed memory, padded
   allocation. Clean release and dirty borrowing are semantic obligations.
5. **Correctness blind to phase** (codex B4, muse B5, opus C6). Accepted
   with a correction: for the permutation tier (X/CX/CCX/MCX only) basis-
   state agreement plus clean ancillae on every basis input determines the
   unitary exactly, so no relative phase and no garbage entanglement is
   possible; differential testing is complete there, by theorem. Phase-
   sensitive verification (unitary equivalence at small widths, controlled-
   interference tests, stated ε) is required for measurement-based
   uncomputation, rotations, and synthesised non-permutation gates, and
   algorithms are verified compositionally by simulation with branch
   enumeration. "Proof-carrying" now says what the certificate asserts and
   who checks it (§5.1).
6. **Qubit value vs reference semantics undecided** (opus B2). Decided:
   reference semantics (handles) at the dialect level, where LLVM cannot
   enforce linearity and a fail-loud verifier does; linear wire semantics
   in the ISA. Both forms at named stages, as Quake keeps ref and wire.
7. **Repo split contradictions and missing contracts** (muse B6, opus B5,
   codex C4). "One codebase holds both executors" withdrawn; one semantics
   comes from the ISA spec's formal model and conformance suite. The
   scheduler and cost model move into `bennett-sched` (Rust, C ABI),
   linked by both the plugin and the VM, which makes decision 6 literally
   true. The ISA spec now explicitly owns the object and link format, the
   reversible ABI, the host–device launch ABI, and the cost-certificate
   schema (§4.4, §6.1). The build dependency of runtimes and arith on the
   driver is declared.
8. **Prior art absent; QIR critique partly wrong** (all three, C7). New §7
   landscape table (Enzyme, PTX/offload, QIR, OpenQASM 3, CUDA-Q/Quake,
   Catalyst/MLIR, Q#, Quipper, Silq/Unqomp/Reqomp/SQUARE, Tower,
   Qualtran/Azure RE, QSSA/QIRO, ReVerC, pebbling literature) with a
   narrow novelty claim. QIR critique corrected: opaque pointers do
   participate in SSA dataflow; adaptive profile and memory-management
   spec acknowledged; the defensible criticism restated.

Also from suggestions: optimality qualified (pebbling is PSPACE-complete;
optimal within a declared search space with gap certificates); resource-
vector decision rule (scalarisation or lexicographic order supplied by the
target); governance paragraph; Rust is affine not linear; C++ rationale
corrected (`llvmGetPassPluginInfo` has C linkage, registration and analyses
are C++); pipeline placement and "correctness invariant, cost not" stated;
non-normative ISA sketch and example target description added (§4.5);
each ladder rung has an acceptance test with instance sizes and oracles;
xkcd aside removed; the "leading figures" sentence moved out of the
argument into the provenance note.

## Declined or kept, with reasons

- **Drop the appeal to the maintainer's year of discussion entirely**
  (opus C8). Kept as provenance, not as argument, at the maintainer's
  explicit instruction that this context matters; it is no longer inside
  §4.
- **"A classical runtime cannot inspect a superposed value"** (codex B3)
  is accepted as the invariant; the stronger reading that the VM is
  therefore "a reversible classical debugger" is answered in §4.2's last
  paragraph: the VM is a classical runtime that schedules quantum
  operations, and that is the claim, not a retreat from it.
- **The branch-enumeration simulation** is new in this iteration, added
  because it is what makes rungs 4, 7, 8 testable at small instance size
  without a state vector the size of SQLite's memory. Members are asked to
  check the claim: a permutation oracle applied to a state vector is a
  permutation of amplitudes, so running the reversible program once per
  basis state of the superposed inputs is an exact simulation of the
  oracle.
