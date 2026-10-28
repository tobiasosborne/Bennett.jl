# Editor's response to round 4

Verdicts: muse **accept**, codex revise, opus revise. Mean 4.33 (4.04 →
4.33). All five round-3 blocking issues confirmed resolved by all three
members. Three new blocking issues, all genuine and all accepted; by the
maintainer's rule (a further round only when new blockers emerge) a round
5 follows.

## Accepted and changed

1. **`freeze` is not a deterministic refinement** (codex B_FREEZE,
   opus B1). The editor's round-3 fix was wrong on this premise: `freeze`
   stabilises an arbitrary value, and codegen lowers it to whatever the
   register holds (opus: `shl` by ≥ width is masked on x86; padding holds
   stale memory; codex: clang 18 gives an undefined register at -O0 and
   zero at -O3 for the same frozen poison). Both members' preferred option
   A is taken: §3.2 now specifies **materialised normalisation**: strip
   poison-generating flags, totalise partial operations with stated
   results via `select`, zero-initialise allocas/heap/padding/region
   inputs, replace remaining `undef` by stated constants; both the
   reference interpreter and the native comparison binary are built from
   the materialised bitcode, so it has one defined meaning; only immediate
   UB remains, as a fault code. The §4.2 tier table says "refined by the
   materialised normalisation" instead of "by `freeze`". The certificate
   records the LLVM version and pipeline, and "never of the compiler" is
   corrected to "never of Bennett's own lowering".
2. **Oracle vs quantum-action interface** (codex B1_QUANTUM_STATE_WRITE).
   The universal "XOR involution with inputs preserved" formula cannot
   describe a region containing RZ(θ) or an in-place increment. §4.2 now
   names **two region interfaces**: the *lifted classical oracle* (F_B,
   XOR accumulation, input preserved, self-adjoint, fault register) and
   the *quantum action* (a unitary U on declared mutable wires, borrowed
   inputs preserved, workspace restored; ctrl = controlled-U, adj = U†;
   no fault outcome of its own, fallible work delegated to lifted oracles
   whose fault registers it declares). They nest; the plugin classifies
   each region by contents and the verifier checks the declared
   interface. Exit synchronisation to a common halt counter is stated
   (muse's suggestion, the QCM condition).
3. **In-place updates need bounded inverses** (codex B_INPLACE). Codex's
   minimal design is taken: `__bennett_inplace` is admitted only for
   mutually inverse **total bijections on a declared finite encoding**
   with budgets sufficient for forward and inverse evaluation; fallible or
   budget-limited computations are never in-place and use the oracle
   interface; library modular multiplication states its coprimality
   condition and the treatment of unused encodings; g∘ginv = id is a
   checked obligation (part 1 at small widths or a library certificate),
   and a wrong inverse is caught because swap-then-uncompute leaves the
   scratch non-clean (opus's suggestion).

Also taken from suggestions: both halves of the Silq discipline (`qfree`
computation as well as preserved dependencies); MBU fixup computed for
the actual schedule (D becomes U D U† after an intervening U); the
`qstore` source-level clean-target restriction distinguished from the
oracle ABI; "unmodified" defined as no source edits with build flags and
shims allowed and recorded; the Grover fault-entanglement reason for a
zero fault rate; dirty-pool tractability lemma or evidence label;
"UBSan-instrumented" shorthand replaced by the §3.2 wording everywhere;
host-effect/handle interleaving split assigned to the launch ABI; ISA
sub-artefacts versioned independently; "only LLVM-linked component"
qualified to the compiler core; HUGR/Guppy/tket2 added to §7.

## Declined

- Codex's "add small normative examples" (a faulting oracle, a non-self-
  inverse action, a controlled in-place bijection): agreed in spirit but
  deferred to the dialect spec, where worked examples belong; the vision
  document already carries a non-normative ISA sketch and the council has
  not treated the absence of examples as blocking.
