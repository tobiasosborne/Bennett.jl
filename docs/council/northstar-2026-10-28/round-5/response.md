# Editor's response to round 5

Verdicts: muse **accept**, codex revise, opus revise. Mean 4.42 (4.33 →
4.42). All three round-4 blocking issues confirmed resolved by all three
members. One new blocking issue, raised independently by codex and opus
and accepted; it is the third instance of the same class (round 4:
`freeze`; round 5: what `freeze` removal still leaves open), so the fix
this time closes the class rather than one instance.

## Accepted and changed

**Residual LLVM nondeterminism** (codex B_DEFINED_NONDETERMINISM, opus
B_RESIDUAL_NONDETERMINISM). After poison and undef are removed, LLVM
still leaves NaN sign and payload, `llvm.fmuladd` fusion, fast-math
permissions, and allocation addresses (observable through `ptrtoint`,
cross-allocation comparison, hashing, `%p`) unspecified; codex showed
clang 18 emitting opposite SSE operand orders at -O0 and -O3 for one
`fadd`/`bitcast`/`xor` function. §3.2 now states that the reference
semantics **fixes every remaining choice**:

- Floating point is **deterministic soft-float in both builds** (codex's
  preferred option, and the project's existing bit-exact asset): every
  FP operation of lifted code is rewritten to `bennett-arith` soft-float
  calls with a single canonical NaN, round-to-nearest-even, `fmuladd`
  rewritten to `fmul`+`fadd`, fast-math stripped; hardware FP never runs
  in either build.
- **Deterministic layout model**: globals and heap through the shared
  `bennett-runtimes` allocator shim in both builds, fixed base, no ASLR;
  stack-address-dependent executions classified *layout-dependent* via
  provenance tracking in the reference interpreter, excluded from native
  comparison and validated against the interpreter (opus's option A,
  since a no-fork design cannot control native frame layout).
- **Faulting memory access defined** by an object-bounds model;
  **atomics/volatile** sequentialised in program order under a recorded
  single-thread assumption.
- Fault *causes* come from the reference interpreter (a native trap
  cannot distinguish them); the normaliser version is recorded in the
  certificate; the normalisation rules are normative text in the dialect
  spec with an enumerated source list and an independently implemented
  residual-poison validator. Floating point is removed from the deferred
  list (§9.11).

Also from suggestions: region inputs are not zero-initialised (only
memory first touched inside the region); the permutation theorem is
generalised to a declared expected permutation P, with the oracle tuple
and the in-place bijection |x⟩↦|g(x)⟩ as instances, so g∘ginv = id is
checked by the same mechanism; the step machine's per-step predecessor
record is named as the QCM injectivity condition; "need not be an
involution"; quantum actions with coherent internal control are their
bounded padded unitary by definition; the handle-table idiom for
classically indexed collections of handles; rung 4's oracle shape (query
parameterised by a `rowid` bound from the superposed register); the
dialect spec's dependency on the ISA formal model recorded in §6.1.

## Declined

Nothing. Codex's suggestion to tighten the landscape's negative
comparisons is taken as wording to revisit in the landscape table during
the ISA-spec workstream rather than now; it is not a blocker.

## Routing note

From this round on, blockers of the "what exactly does the machine
compute" kind are resolved in `Bennett-ISA-Spec.md` (council run
`isa-2026-10-28`) and the north star points at the spec. This round's
blocker was still a north-star-level contract (what "equals native"
means), so it was fixed here; the spec will mirror it in its next
iteration.
