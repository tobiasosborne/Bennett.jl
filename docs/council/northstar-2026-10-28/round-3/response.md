# Editor's response to round 3 (final round of three)

Verdicts: muse **accept**, codex revise, opus revise. Mean 4.04 (from
3.75, from 2.62). Every criterion at 4 or above; codex C4 and muse C6 at
5. All seven round-2 blocking issues were confirmed resolved by every
member. The residue is five semantic points, each with an explicit
path-to-accept, and the editor agrees with all five. They are folded into
iteration 4 of the document without a fourth council round, per the
maintainer's three-round rule.

## Residue, and what iteration 4 does with it

1. **Definedness consistency** (codex B1). §0 promised named faults for
   executions outside the domain while §3.2 admitted the optimiser erases
   source UB. Fixed by one authoritative contract in §3.2, referenced from
   §0, §4.2, §5.1 and rung 7: the reference semantics is the ISA formal-
   model interpreter on the freeze-normalised optimised bitcode; faults
   cover what that machine encounters; erased source UB is a recorded
   definedness assumption, not a fault guarantee; UBSan/ASan/MSan or a
   checked interpreter are supplementary classifiers in a separate build.
   Codex's `10/x` example is quoted.
2. **Faulted output state** (codex B3; muse and opus suggestions). §4.2
   now defines F_B(x) deterministically: success XORs f(x) into the output
   target with the fault register unchanged; failure XORs the canonical
   zero payload (target unchanged) and XORs a reference-chosen code into
   the fault register. Both halves are XORs, so the region is an
   involution and composes under repeated, controlled and adjoint
   invocation. The prefix-reversal invariant is stated: a faulted branch
   reverses its history exactly as a clean one. The budget unit is steps
   of the reference interpreter on the outlined region, so the fault set
   is a property of program plus budget, not of the compiler.
3. **Input preservation** (codex B4). §5.1 part 1 now requires equality of
   the entire final register tuple, with x preserved, t ⊕ payload, e ⊕
   code, dirty registers unchanged and clean workspace restored, and says
   explicitly that input preservation is a hypothesis and an acceptance
   check, with codex's "flip an input bit" counterexample as the reason.
   The fault register's value is part of domain D.
4. **Coherent memory and in-place update** (opus B1). New §3.1 row and
   §4.2 paragraph: read is a CNOT copy, write XORs (store into a not-known-
   clean register is a compile-time error), region inputs preserved and
   outputs XORed into caller targets, in-place update needs an inverse via
   `__bennett_inplace(@g, @ginv)` or a library bijection and is lowered
   compute/swap/uncompute, else fails loud. Opus's option (a) is taken,
   (b) remains legal. This is what makes `when(q) do x += a end` work.
5. **Uncomputation validity** (opus B2). New §4.2 paragraph adopting the
   Silq `qfree`/`const` and Unqomp condition as an ISA invariant: garbage
   records its dependency set, is uncomputed only while that set is
   unmodified, must be cleaned before any non-permutation operation or in-
   place update on a dependency and before region exit; MBU with phase
   fixup is the alternative; all schedulers are confined to valid
   schedules; the verifier rejects violations; conformance uses
   interference tests. Credited in §7.

Also taken from the suggestions: diamond-norm / operator-norm metrics and
the numerical-bound rule for channel comparison; marker-only rule
clarified to explicit quantum registers (SQLite's ordinary loads and
stores are lifted per the incoming memory model); handles through memory
or `inttoptr` round trips rejected fail-loud; code touching handles or
measurement results runs in the device's classical-control tier; MBU
under control falls back to unitary uncomputation until agreed; exceptions
and unwinding named; Rust std's embedded bitcode (rebuild only when
missing); tested compatibility envelope instead of "run on the newest";
dialect-spec reference semantics; binary-edge versioning rule; Quantum
Control Machine, QCOR/XACC, tweedledum/RevKit, ProjectQ, REVS added to §7;
Qualtran/Azure unit-reconciliation rule; LLVM.jl orchestration in-process
with tools out of process.

## Declined

Nothing. Muse's accept stands; codex's and opus's paths to accept are
implemented verbatim in substance. Whether to spend a confirmation round
is the maintainer's call; the three-round budget is spent.
