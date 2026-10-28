# Council — isa-2026-10-28 round 7

Document snapshot sha256 b0e348a493a9; rubric docs/council/rubric-isa.md. Members: codex, muse, opus. Scores are advisory.

| | codex | muse | opus | mean | spread ≥ 2 |
|---|---|---|---|---|---|
| C1 | 4 | 4 | 4 | 4.0 |  |
| C2 | 4 | 4 | 4 | 4.0 |  |
| C3 | 5 | 4 | 4 | 4.33 |  |
| C4 | 4 | 4 | 4 | 4.0 |  |
| C5 | 4 | 4 | 4 | 4.0 |  |
| C6 | 4 | 4 | 4 | 4.0 |  |
| C7 | 5 | 5 | 4 | 4.67 |  |
| C8 | 4 | 4 | 4 | 4.0 |  |

Overall mean: 4.12

Verdicts: **codex: accept**, **muse: accept**, **opus: revise**

Core verdicts: **codex: accept**, **muse: accept**, **opus: accept**

**Consensus: no**   **Core consensus: YES**

Blocking by scope/severity: codex: core 0 / contract 0 (S0 0), muse: core 0 / contract 0 (S0 0), opus: core 0 / contract 1 (S0 1)

## Regressions reported

- **[codex]** New nonblocking defect in §12.1: the stated strict-feasibility construction does not make the third inequality strict. It leaves mu·I − Tr_out(Y) unchanged. This can cause rejection of a valid bound, but cannot make the revised checker accept an invalid bound.

## Previous-round blockers, status

- [codex] B1: **resolved** — §3.6 requires reverse-order assignment exchanges, and lift.alloc explicitly restores atop before addressing its allocation-table entry.
- [codex] B3: **resolved** — §7.4 applies the same cancellation-aware traversal to segment and whole-run reversal, skipping already-reversed frames and nested uncall markers.
- [codex] B10: **resolved** — Claims and error entries now cover every resolved invocation context in the bound root schedule; channel claims require a witness for each context.
- [codex] B11: **resolved** — The unsound leading-principal-minor fallback is removed; rigorous strictly positive pivots are required for all three matrices.
- [codex] B1_UNCALL_OVER_MEASURE: **resolved** — Segment uncall explicitly excludes measurement and unverified hardware release at every nesting depth; measure frames are never reversed.
- [codex] B2_PSD_ACCEPTANCE_UNSOUND: **resolved** — The acceptance procedure is now conservative and sound. The new witness-inflation recipe has a separate nonblocking defect.
- [muse] codex B1: **resolved** — §3.6 requires A-row inverse exchanges in reverse forward order with current-state addressing, and §4.2 prints lift.alloc's inverse order atop, heap_used, alloctab[restored atop], w.
- [muse] codex B3: **resolved** — §7.4 defines one history traversal for segment and whole-run reversal: LIFO, skipping already-reversed frames and uncall frames; the nested clock example is in suite A.
- [muse] codex B10: **resolved** — §12.1 defines subjects over every invocation context, including path-resolved arguments, budgets, shares and cleanup choices; bounds are common upper bounds and channel claims carry one witness per context.
- [muse] codex B11: **resolved** — The unsound leading-principal-minor acceptance rule is removed; §12.1 requires strict positive definiteness proved by interval Cholesky/LDL† with every pivot lower bound >0.
- [muse] opus B1_UNCALL_OVER_MEASURE: **resolved** — §7.4 traps segment uncall when the segment contains a measure frame at any depth or an unverified hardware qreg.free, and §3.3 states that a measure frame is never reversed.
- [muse] opus B2_PSD_ACCEPTANCE_UNSOUND: **resolved** — The checker may now accept only by proving positive definiteness with strictly positive interval pivots and must reject otherwise; sound conservative rejection replaces the false minor criterion.
- [opus] codex B1: **resolved** — §3.6 step 4 runs A-row inverse exchanges in reverse forward order with addresses evaluated in the current state; lift.alloc prints atop, heap_used, alloctab[restored atop], w. Traced: correct, and in range at capacity.
- [opus] codex B3: **resolved** — §7.4 history traversal (LIFO; skip reversed and uncall frames; undo and mark) is shared by segment uncall and whole-run reversal; the clock counterexample nets to zero and is a suite-A case. The §4.1 summary row is stale (suggestion).
- [opus] codex B10: **resolved** — Subjects denote all invocation contexts; claims and error entries are common upper bounds over them, so multiplicity composition is sound; one channel witness per context. The enumeration key wording could be tightened (suggestion).
- [opus] codex B11: **resolved** — The leading-minor rule is removed; strict PD by interval Cholesky/LDL† with positive pivot lower bounds is sound. The new producer shift recipe has a defect, raised as B1.
- [opus] opus B1_UNCALL_OVER_MEASURE: **resolved** — Uncall of a segment containing a measure frame, or an unverified hardware qreg.free, at any depth is a trap with no state change; the handle table says measure frames are never reversed; suite A case added.
- [opus] opus B2_PSD_ACCEPTANCE_UNSOUND: **resolved** — Same as codex B11: the acceptance rule is now sound. The producer δ-shift leaves mu·I−Tr_out(Y) non-strict (B1).

## Blocking issues

- **[opus] B1_SDP_PRODUCER_SHIFT_NOT_STRICT** (§12.1 Diamond-norm SDP, positivity test; contract/S0): The checker must prove all three matrices strictly positive definite: Y−J, Y+J and mu·I−Tr_out(Y). The normative producer recipe says to replace Y with Y+δI and mu with mu+δ·d. Since Tr_out(I_{d²}) = d·I_d, this gives (mu+δd)·I − Tr_out(Y+δI) = mu·I − Tr_out(Y) exactly, so the third matrix is unchanged. At a dual optimum mu = λmax(Tr_out Y), so that matrix is singular and the checker must reject. The claim that the recipe 'makes witnesses strictly feasible' is false: producer and checker obligations contradict each other. Every producer that follows the recipe from a tight witness gets its channel claim rejected by every conformant checker. *Fix:* State: 'Producers replace Y with Y+δI and mu with mu+δ·(d+1) (any mu′ > mu+δ·d suffices) for a small rational δ>0. Then Y±J(Φ) ⪰ δI ≻ 0 and mu′·I − Tr_out(Y+δI) ⪰ δI ≻ 0, and ‖Φ‖◇ ≤ mu′ ≤ bound.' I would take this. The alternative is to require strict PD only for Y±J and accept the third constraint as soon as the interval upper bound of λmax(Tr_out Y), by Cholesky of (mu−η)I−Tr_out(Y) for a stated η>0, is below mu. That is more machinery, so I prefer the one-line shift.

## codex

All six previous blockers are resolved: B1, B3, B10, B11, B1_UNCALL_OVER_MEASURE and B2_PSD_ACCEPTANCE_UNSOUND. The core repairs are sound, and the example checker passes. No new S0 issue found. The new strict-feasibility recipe contains a false mathematical claim, but the checker still rejects inconclusive or non-positive witnesses, so this is a producer-side S1 correction rather than an unsound acceptance path.

**Path to accept:** Already accept: no S0 blocker remains. The most direct improvement to a lowest-scoring criterion is correcting §12.1's strict-feasibility construction and distinguishing feasible witnesses from witnesses accepted by the conservative procedure; this would raise C6.

- **C1 4**: §§3.2–3.7 specify the state, ownership, register files and activation records concretely. §7.4 now supplies one cancellation-aware traversal. The distinction between retained audit frames and logically restored history remains implicit. *Change:* Define the active history separately from retained reversed records, making T4's restoration of history precise.
- **C2 4**: §4 provides a closed instruction set with width rules, fault behavior and expansion-based cost hooks. The corrected A-row exchange order handles lift.alloc's indexed destination; the printed call/return inverses restore their addressing counters before accessing records. *Change:* Add a compact normative table of permitted destination/source aliasing for lifted rows, including self-updates and parallel assignments.
- **C3 5**: The repaired inverse ordering, shared history traversal and irreversible-segment exclusion resolve the previous core counterexamples. Oracle XOR semantics, prefix reversal, phase-sensitive control, cleanup windows and the restricted borrow-frame lemma are sound within their stated obligations. *Change:* No semantic change required; concrete allocation-inverse and nested-cancellation vectors would improve auditability.
- **C4 4**: §8 distinguishes requested and achieved accuracy, counts expanded leaf events once, defines capacity and provides resource defaults. Applying the equal-share default during scheme expansion could be stated more directly. *Change:* Specify how the existing epsilon-share default applies to a scheme's expanded leaves, including its relationship to the parent's share.
- **C5 4**: Objects, linking, launch, scheduling and certificates are decided at the required level. §12.1 now requires bounds over every resolved invocation context, closing B10. Context enumeration refers to sparse schedule-entry paths even though invocations also exist under defaults. *Change:* Enumerate contexts from the complete expanded invocation tree, then resolve schedule overrides for each context; do not derive the context set from the entries array.
- **C6 4**: The strict positive-definiteness acceptance test is sound and rejects the previous counterexamples. However, the new claim that shifting Y by δI and mu by δd makes the entire witness strictly feasible is false: the third slack matrix is unchanged. *Change:* Starting from a feasible witness, use Y' = Y + δI and mu' = mu + δd + η for rational δ,η > 0, requiring mu' ≤ bound.
- **C7 5**: The specification preserves the north star's tier separation, total oracle interface, phase-sensitive correctness, public contracts and target-driven scheduling. Deferring measurement-based cleanup with an explicit unitary default is consistent with that vision. *Change:* No substantive change required.
- **C8 4**: The document is implementable as a first normative specification. Defaults cover the principal deferred choices. The supplied mechanical checker passes both example objects, their hashes, both printed envelopes and their stated execution cases. *Change:* Add one small action example with a schedule and certificate covering repeated callee invocations with different classical arguments.

Suggestions:
1. S1 — §12.1: Correct the witness-inflation recipe. With Φ = 0, Y = 0 and mu = 0, the printed shift gives Y' = δI and mu' = δd, leaving the third slack exactly zero. Add an independent positive margin η to mu', or require the starting third slack to be strictly positive. I recommend the independent margin.
2. S1 — §12.1: Distinguish mathematical dual feasibility from acceptance by the conservative strict-positivity procedure. A feasible boundary witness may legitimately be rejected; the preceding 'accepts iff' sentence should say so.
3. S1 — §12.1: Enumerate all expanded invocation contexts, including the root, default-covered calls and loop repetitions. The universal verification obligation already closes B10; sorting sparse override entries is merely an unsuitable description of the enumeration.
4. S1 — §§7.4, 14.3: Distinguish active history from retained audit records, and explicitly restrict T4 to reversal-eligible traces. This would reconcile retained reversed frames with restoration of history without changing the cancellation semantics.
5. S1 — §§8.1, 8.3, 17.9: State explicitly how equal epsilon shares are assigned after scheme expansion and how the resulting sum is checked against the requested region accuracy.
6. Citation correction — §12.1: The Y0/Y1 Choi-form dual is presented directly in [Watrous, Simpler semidefinite programs for completely bounded norms (2013), §3](https://cs.uwaterloo.ca/~watrous/Papers/SimplerSDPforCBnorm.pdf). Cite that formulation, or explain the transformation from the 2009 channel-distance formulation. The printed full-diamond-norm bound is sound.

## muse

All six round-6 blockers are resolved: B1 by reverse-order A-row exchanges and the printed lift.alloc inverse order; B3 by the shared cancellation-aware history traversal; codex B10 by common upper bounds checked over every invocation context; codex B11 and opus B2 by removing the false principal-minor PSD test and requiring strict positive-definiteness; and opus B1 by trapping segment uncall over measure. I found no remaining S0 divergence or unsoundness in core or contract scope. The remaining items are S1 wording, enumeration and witness-production details with sound conservative defaults.

**Path to accept:** Already accept. To raise a lowest-scoring criterion, C5, by one point: rewrite §12.1's context enumeration as the sorted set of all paths in the root schedule's static region tree, explicitly including invocations covered only by schedule defaults, and use that same enumeration for numerical claims, channel witnesses and §12.3 multiplicities.

- **C1 4**: §3.6 now defines reverse-order A-row exchanges with addresses evaluated from the current inverse state; §4.2 prints lift.alloc's exact forward and inverse orders; §§3.7, 5.2, 7.4 give a coherent state and step model. *Change:* Synchronise the abbreviated §4.1 uncall row with the complete §7.4 rule.
- **C2 4**: §4 gives forms, operand schemas, row classes, flags, successors and tier restrictions; the lift.alloc ordering ambiguity is removed. *Change:* Make §4.1 state explicitly that segment uncall uses §7.4's cancellation-aware traversal and traps over measure.
- **C3 4**: §3.6 defines forward and inverse steps, §7.4 defines one LIFO history traversal that skips reversed frames and uncall frames, and §7.4 makes uncall over measure or unverified qreg.free a no-state-change trap. *Change:* Add the no-measure and reverse-eligibility hypotheses explicitly to T4.
- **C4 4**: §8 defines target expressions, variable binding, matching, schemes, aggregation, timing, capacities and defaults sufficiently for independent implementation. *Change:* No semantic change needed; further worked target examples would help implementers.
- **C5 4**: §§9-13 decide objects, identity, linking, launch, scheduling, coverage and certificates. §12.1 now makes subject bounds common upper bounds over every invocation context and §12.3 states why multiplicity composition is sound. *Change:* Define invocation-context enumeration directly from all region-tree paths, including default-covered invocations, rather than referring to schedule-entry paths.
- **C6 4**: §14 states the reference interpreter and theorems with usable hypotheses; §15 derives suites from the text, including nested uncall, uncall over measure and the clock counterexample. §12.1 replaces the false principal-minor test with a sound strict-positive-definiteness test. *Change:* State in T4 that the trace contains no measure frame, matching §§3.3, 7.4 and 10, and add the third-matrix strictness slack to the SDP producer recipe.
- **C7 5**: The draft implements the north star's tier separation, oracle/action distinction, fault outcomes, target descriptions, certificates and staged ISA contracts without an identified contradiction. *Change:* No change needed.
- **C8 4**: A VM or specialiser author can start from the reference bodies, step machine, row table, schedule matching and §17 defaults; remaining items are non-semantic or conservatively defaulted. *Change:* Synchronise summary tables with §§7.4 and 12.1 so an implementer need not infer which text controls.

Suggestions:
1. §4.1 uncall summary: repeat §7.4's history-traversal, measure-frame and unverified-qreg.free conditions so the instruction table cannot be read as allowing the old reversal.
2. §14.3 T4: add the explicit hypotheses that reversal is invoked only under §10 reverse eligibility and that the trace contains no measure frame.
3. §12.1 producer shift: replace mu -> mu + δ·d with mu -> mu + δ·d + η for η > 0. The δ·d part alone leaves mu·I - Tr_out(Y) unchanged, so an optimal singular third constraint is still not strictly positive definite; the checker's acceptance rule itself is sound.
4. §12.1 invocation contexts: enumerate paths from the region tree itself, not from schedule entries, because §11 permits invocations covered only by defaults and entries need not enumerate them.
5. §7.4 history traversal: define 'retired' for an uncall marker, or simply say uncall frames remain but are always skipped.

## opus

All six round-6 blockers are resolved. The A-row inverse exchange order is fixed, and I traced it for lift.alloc: correct, including at table capacity. The single history traversal handles nested compute–copy–uncall: the clock counterexample nets to zero. Uncall over measure traps. Certificate subjects range over all invocation contexts with common upper bounds, so multiplicity composition is sound. The PSD acceptance rule is now strict positive definiteness by interval Cholesky, which is sound. I re-checked the core (forward and inverse step, C1–C5/R1–R5 inverses, commit and prefix reversal, qinplace, translation lemma, both examples' stated results) and found no new core S0, so verdict_core is accept. One new contract-level S0: the producer δ-shift (Y+δI, mu+δ·d) leaves mu·I−Tr_out(Y) unchanged, hence singular at a tight witness. The checker must then reject every witness produced by the normative recipe; the fix is one sentence (shift mu by more than δ·d). Suggestions: the stale §4.1 uncall summary row, a precise context enumeration key, and the workspace restriction of U in numerical claims.

**Path to accept:** One sentence changes my verdict to accept: correct the §12.1 producer recipe so the mu shift exceeds δ·d (e.g. mu′ = mu + δ·(d+1)), making mu′·I − Tr_out(Y+δI) ⪰ δI ≻ 0, and drop the false claim that the current shift yields strict feasibility. Optionally, in the same pass, align the stale §4.1 uncall row with §7.4 and pin the context enumeration key. After that, the lowest criterion (all at 4) rises with a suite-D channel-claim test vector and a worked target-description example.

- **C1 4**: §3.2 state table, §3.3 handle transitions (the measure frame is now never reversed), §3.6 forward and inverse steps with the A-row exchange order now fixed, §7.4 one history traversal. Two implementers would draw the same state diagram for CC/R/Q. *Change:* Bring the §4.1 `uncall` row into line with §7.4. It still describes the old reversal ('frames reversed in LIFO order (nested segments included) and marked reversed') and omits the measure/qreg.free legality condition.
- **C2 4**: Every §4.2 row has its class, reads, slots, flag and successor. lift.alloc now prints its forward slot order and inverse exchange order (atop, heap_used, alloctab[atop] at the restored atop, w), which is the exact reverse. §4.8 opcode table and the width rules are closed. *Change:* Replace the summary semantics in the §4.1 `uncall` row with a pointer to §7.4's legality conditions and history traversal, so §4.1 cannot be read as a second, divergent rule.
- **C3 4**: I traced the A-row inverse for lift.alloc, the C1–C5 and R1–R5 inverses, the commit and prefix reversal, the qinplace expansion and the translation lemma: all invert correctly. The history traversal skips reversed frames and uncall markers. In the nested clock counterexample the clock goes +1, −1 once, and the outer uncall then skips the cancelled frames. Uncall over measure now traps. *Change:* State whether the call segment cancelled by an `uncall` can still be 'the most recent completed call segment' for a later uncall. Today a second uncall is blocked only because the uncall frame is impure; say so explicitly.
- **C4 4**: §8 has a closed expression AST, variable binding per context, requested vs achieved ε, aggregation from leaf events, matching order and scheme templates. §17 gives defaults for any-class, rates and timing. *Change:* Give one worked target-description example: the gates and schemes entries for mcx(k) under c inherited controls, with its evaluated cost, as a suite-E vector.
- **C5 4**: §12.1 invocation contexts with common upper bounds make the §12.3 multiplicity composition sound. The positivity test is now strict PD by interval Cholesky with positive pivot lower bounds, which is sound. But the producer δ-shift recipe does not make the third SDP constraint strict (see B1). *Change:* Fix the mu shift so that all three matrices are strictly positive definite, and define the context enumeration key as the JCS bytes of each context's concrete invocation chain.
- **C6 4**: T1–T6 are stated with hypotheses. §14.1 reference interpreter defines F_B. The suites now include the nested-uncall and uncall-over-measure cases and the lift.call/lift.ret one-step inverse checks. The Watrous dual (Y0=Y1=Y with Y±J ⪰ 0 and mu ≥ λmax(Tr_out Y)) is a valid upper bound on ‖Φ‖◇. The Frobenius bound on ‖V†U−I‖ and the ×2 conversion from operator norm to diamond norm are correct. *Change:* State T4 explicitly over the history traversal: reversed and retired frames contribute nothing, and an uncall restores every component except retained instances.
- **C7 4**: Consistent with north star §4.2 (F_B, prefix reversal, the validity invariant) and §5.1 (permutation theorem; proof vs evidence). The mbu capability is reserved, consistent with the north star's unitary fallback under control. The Watrous SDP is attributed and used correctly. *Change:* Cite the Watrous 2012/2013 'Simpler SDPs for completely bounded norms' Hermiticity-preserving form specifically, alongside the ToC 2009 citation.
- **C8 4**: A VM author can start from §3.6/§3.7/§4.2 and the two executed examples, whose hashes are recomputed. A specialiser author has the §11 expansion library binding with default `ref`. Every §17 item has a default. *Change:* Add a suite-D test vector: one tiny channel claim (e.g. id vs Z·Z on one qubit) with a strictly feasible witness that the checker accepts, so producers and checkers calibrate on the same bytes.

Suggestions:
1. §4.1 `uncall` row: it still says the segment's frames are 'reversed in LIFO order (nested segments included) and marked reversed' and lists only three legality conditions. Replace it with 'legal and executed per §7.4 (including the measure/qreg.free exclusion and the history traversal)' so it cannot be read as a second, divergent rule.
2. §12.1 context enumeration: contexts are invocation chains, not necessarily schedule `entries` (uncovered operations take defaults). Define the order as the bytewise order of the JCS serialisation of each context's concrete invocation chain, using the §11 path-element schema with concrete iteration vectors. Then two checkers assign channel witnesses to the same contexts.
3. §12.1 numerical: say explicitly that U is the realised map restricted to clean workspace input with workspace verified returned to |0⟩ (an isometry on the interface), or that the workspace-clean check is a separate obligation. Otherwise 'realised unitary at signature widths' is slightly underdefined.
4. §7.4: state that a call segment already cancelled by an `uncall` is not eligible as 'the most recent completed call segment'. Today a repeat uncall is excluded only because the uncall frame is impure.
5. §10: say whether a FAILED R run (fault record terminal) is reversible. §7.4 says fault records are 'reversed like any prefix', but the state machine allows REVERSED only from COMPLETED.
6. Allow channel claims to supply one witness per distinct realised channel instead of per context, via an index map, to avoid repeating identical witnesses across loop iterations.
