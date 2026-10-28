# Editor's response to round 2

All three members returned `revise` (mean 3.75, up from 2.62; C1, C3, C4,
C7, C8 unanimous 4). Seven blocking issues converging on three themes
plus one ABI point; all accepted. Iteration 3 is a targeted revision.

## Accepted and changed

1. **Bound exhaustion and totality of coherent regions** (codex B3, muse
   B2, opus B1). §3.1 bounds row rewritten: the primary bound is a
   **region-level classical budget** (steps, heap, recursion depth) passed
   as ordinary integer operands of the region-entry marker or supplied
   out of band by the host or driver, applied after outlining; per-loop
   bounds are refinements only; **no per-loop source annotation is ever
   required**, so "nobody rewrote SQLite" follows from the dialect. The
   `token` wording is gone. §4.2 now defines the general coherent
   construction as a **predicated step machine** over an arbitrary post-
   O3 CFG (structured pred/loop as optimisations), and **totality**: every
   coherent region returns declared outputs plus a **fault register**
   with distinct codes (budget, immediate UB, unmodelled effect); on a
   faulted basis input the outputs are not an oracle value and the
   workspace is still returned clean because predicated execution runs to
   the budget with the fault predicate off. Equivalence is restated as
   "equals native, or is flagged", the fault rate is reported per domain
   and must be zero on acceptance instances (§5.1, §8). The ISA sketch
   gained `region`, `step`, `fault`.
2. **Verification scope** (codex B4, muse B1). §5.1 rewritten: the
   permutation tier is defined *after decomposition into emitted gates*
   (relative-phase Toffoli decompositions and measurement fixups
   excluded); the theorem's domain D is stated exactly (every x, every
   target t, every value of borrowed dirty ancillae, clean ancillae in
   their declared state), with equality of result or of fault code;
   **exhaustive agreement on D is complete for D; sampling is evidence**;
   measurement-based uncomputation is verified as a channel (Choi-state
   comparison with a reference system, instrument where outcomes are
   exposed), unitaries by equivalence plus controlled-interference tests,
   with ε and its composition rule; certificates label every claim proof
   or evidence; replayable records are evidence; minimality needs a
   lower-bound or exhaustive-search certificate. Branch enumeration is
   scoped to permutation segments with the full branch configuration
   tracked (§4.2). Clean release is checked by simulation.
3. **Definedness** (codex B1, opus B1(iii)). §3.2 "Definedness" bullet and
   §0: the claim that UB is "concretised and recorded" is withdrawn. The
   reference semantics is the optimised bitcode; undef/poison are refined
   by `freeze` at region inputs and poison-producing operations;
   immediate UB is a fault code; correctness is under an explicit
   definedness assumption recorded in the certificate; the native oracle
   runs under UBSan and UB-triggering inputs are excluded and counted
   separately.
4. **Portable marker ABI** (codex B2, opus C2/C5 suggestions). Handles are
   ordinary `ptr` in address space 0 or integer handles, emittable from
   unmodified clang, rustc and Julia; normalised by the plugin at link
   time; quantum memory is accessed only through `__bennett_qload/qstore`
   markers, never LLVM `load`/`store` in a special address space, which
   also removes the GVN/forwarding hazard and the DataLayout concern. The
   dialect spec is gated on actual emission examples from all three front
   ends and on native codegen of fat objects.

Also from the suggestions: positive legality requirement on markers (no
`readnone`/`readonly`/`speculatable`/`willreturn` combinations; external
declarations are never inlined, containing functions may be); context-
sensitive interprocedural taint with polyvariant specialisation; region
well-formedness (unitary; user measurement refused or deferred by the
deferred-measurement principle; MBU the sole exception); `__bennett_
reversible` as the reversible-tier entry; stated coverage constraints for
Rust std (`-Zbuild-std`), the Julia runtime and native libraries; mixed-
LLVM-major link rule; `bennett-sched` interface, capability declarations,
coverage-report format and driver invocation assigned to the two specs;
launch-time lowering to the target alphabet assigned to the VM; classical
checkpoints never copy quantum state; Quil/QAM, eQASM, Knill's QRAM model,
Spire and Qrisp added to §7 and §4.1's "has not had its layer" qualified
to name what those machines lacked; rungs 2, 3, 6 gained independent
forward-result checks; rung 8's entropy wording fixed; driver stated as
Rust invoking LLVM tools externally so the "C++ only where LLVM is linked"
rule holds.

## Declined or kept, with reasons

- Nothing was declined. One point is kept with a clarification rather than
  a change: codex's note that branch enumeration "does not independently
  validate physical lowerings" is correct and is now stated in §4.2 and
  §5.1 (enumeration is exact for permutation segments; lowerings are
  verified by part 2).
