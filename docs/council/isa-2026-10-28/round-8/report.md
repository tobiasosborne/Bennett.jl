# Council — isa-2026-10-28 round 8

Document snapshot sha256 30e6e33077c7; rubric docs/council/rubric-isa.md. Members: codex, muse, opus. Scores are advisory.

| | codex | muse | opus | mean | spread ≥ 2 |
|---|---|---|---|---|---|
| C1 | 4 | 4 | 4 | 4.0 |  |
| C2 | 4 | 4 | 4 | 4.0 |  |
| C3 | 5 | 4 | 4 | 4.33 |  |
| C4 | 4 | 4 | 4 | 4.0 |  |
| C5 | 4 | 4 | 4 | 4.0 |  |
| C6 | 4 | 4 | 4 | 4.0 |  |
| C7 | 5 | 5 | 5 | 5.0 |  |
| C8 | 4 | 4 | 4 | 4.0 |  |

Overall mean: 4.17

Verdicts: **codex: accept**, **muse: accept**, **opus: accept**

Core verdicts: **codex: accept**, **muse: accept**, **opus: accept**

**Consensus: YES**   **Core consensus: YES**

Blocking by scope/severity: codex: core 0 / contract 0 (S0 0), muse: core 0 / contract 0 (S0 0), opus: core 0 / contract 0 (S0 0)

## Previous-round blockers, status

- [codex] B1_SDP_PRODUCER_SHIFT_NOT_STRICT: **resolved** — For Y′ = Y + δI and mu′ = mu + δ(d+1), the third slack becomes (mu I − Tr_out(Y)) + δI; the other two slacks also gain δI. Starting from a feasible witness, all three are strictly positive definite.
- [muse] B1_SDP_PRODUCER_SHIFT_NOT_STRICT: **resolved** — §12.1 now sets mu' = mu + δ·(d+1) (any mu' > mu + δ·d), so mu'·I − Tr_out(Y+δI) = (mu·I − Tr_out Y) + δI ⪰ δI ≻ 0 and Y±J ⪰ δI; producer recipe and strict-PD checker obligation no longer contradict.
- [opus] B1_SDP_PRODUCER_SHIFT_NOT_STRICT: **resolved** — With Y′ = Y + δI and mu′ = mu + δ(d+1): Y′ ± J ⪰ δI, and mu′I − Tr_out(Y′) = (mu+δ)I − Tr_out(Y) ⪰ δI. All three matrices are strictly positive definite, the bound ‖Φ‖◇ ≤ mu′ holds, and the producer recipe and checker obligation now agree.

## Blocking issues

- none

## codex

B1_SDP_PRODUCER_SHIFT_NOT_STRICT is resolved: the revised mu shift makes every required slack matrix strictly positive definite. The example checker passes against the round-8 snapshot. Re-reading the complete specification revealed no additional S0 issue or regression; remaining points concern clarification and conformance examples.

**Path to accept:** No mandatory changes remain. To raise C8 from 4 to 5, add a byte-exact worked action object with a target, schedule and certificate demonstrating controlled execution, default schedule resolution and repeated invocation contexts.

- **C1 4**: §§3.2–3.7 specify the state, ownership, predicated execution and activation records concretely. §7.4 supplies a single cancellation-aware reversal procedure. *Change:* Distinguish active history from retained, reversed audit records so restoration of history has one explicit meaning.
- **C2 4**: §4 supplies a closed instruction set with width rules, fault behavior and expansion-based cost hooks. The assignment exchange order and call/return inverse lists handle their state-dependent addresses correctly. *Change:* Add a compact operand-aliasing table for lifted rows, making permitted self-updates and parallel assignments immediately apparent.
- **C3 5**: The oracle XOR interface, commit followed by prefix reversal, phase-sensitive gates, bounded action semantics, cleanup windows and restricted borrow-frame lemma are sound under their stated obligations. *Change:* No semantic change required; add concrete inverse-step and interference vectors to make these obligations easier to audit.
- **C4 4**: §8 defines capability matching, requested versus achieved accuracy, expanded-leaf accounting, timing and capacity. §17 supplies defaults for deferred resource choices. *Change:* Show one worked scheme expansion tracing the parent's accuracy allocation through its leaves and into the reported resource vector.
- **C5 4**: Objects, linking, launch, scheduling and certificates are decided at the required level. Bounds over every invocation context make multiplicity composition sound. The description of context ordering still refers to sparse schedule-entry paths. *Change:* Clarify that context ordering covers the complete concrete invocation tree, including invocations whose operations use schedule defaults.
- **C6 4**: The corrected SDP shift supplies strict slack in all three constraints. The symmetric dual bound agrees with [Watrous's 2013 formulation, §3.2](https://cs.uwaterloo.ca/~watrous/Papers/SimplerSDPforCBnorm.pdf). Frobenius upper bounds and the operator-to-diamond factor of two are sound. T4's history wording remains less precise than its referenced operational rules. *Change:* State T4 explicitly over reversal-eligible traces and the active-history projection, distinguishing retained audit records from restored machine state.
- **C7 5**: The specification preserves the north star's tier separation, total oracle interface, reversible ABI, phase-sensitive correctness and independently replaceable components. Deferred measurement-based cleanup has an explicit unitary default. *Change:* No substantive change required.
- **C8 4**: A VM author and specialiser author can start from the operational rules and declared defaults. The supplied checker passes both example objects, all four hashes, both printed envelopes and the tested execution and budget-boundary cases. *Change:* Add one complete action example with its target, schedule and certificate, exercising inherited control and repeated callee invocations with different classical arguments.

Suggestions:
1. Align the abbreviated §4.1 uncall entry explicitly with all legality conditions and the cancellation-aware traversal in §7.4.
2. Clarify invocation-context ordering using concrete invocation chains, including default-scheduled invocations; the existing requirement to check every context should remain unchanged.
3. Separate active history from retained audit records and use that distinction in T4.
4. Add a small strictly feasible channel-witness test vector and a worked controlled-action target/schedule/certificate example.
5. Cite Watrous's 2013 §3.2 alongside the 2009 reference for the particular symmetric dual formulation used.

## muse

Previous blocker B1_SDP_PRODUCER_SHIFT_NOT_STRICT is resolved exactly as proposed: mu' = mu + δ·(d+1) makes all three SDP matrices ⪰ δI, since Tr_out(δI_{d²}) = δ·d·I_d. The 0.8 diff otherwise touches only version strings and example hashes; all four recomputed hashes (inc8, zero, sum, sum_db) were independently recomputed from the §9.2 envelopes and match, and no stale 0.7 string remains. Core (§3-§7, §14, §16) was accepted by every member in round 7 and is unchanged in substance. No new S0 issue was found in core or contract scope; remaining items are S1 wording and enumeration clarifications with sound defaults.

**Path to accept:** Already accept. To raise a lowest-scoring criterion (C5) by one point: rewrite §12.1's invocation-context enumeration as the sorted set of all paths in the root schedule's static region tree, explicitly including invocations covered only by schedule defaults, and use that same enumeration for numerical claims, channel witnesses and §12.3 multiplicities.

- **C1 4**: §3.2-3.7 define state, frames, forward and inverse steps, register files and counters unambiguously; unchanged in 0.8 except version strings, and core was accepted by all members in round 7. *Change:* Synchronise the abbreviated §4.1 uncall row fully with §7.4 so the state model needs no cross-referencing to assemble.
- **C2 4**: §4 gives every form, operand schema (§3.3, §4.8), row classes, flags and successors (§4.2); gate realisation (§4.4) requires exact unitaries including global phase for oracles, so two implementers emit the same permutations. *Change:* Make §4.1 repeat §7.4's no-measure and history-traversal conditions for segment uncall.
- **C3 4**: §3.5-3.6 predication and prefix reversal, §5.2 F_B commit procedure, §5.6 borrow-frame translation lemma with negative tests, §6 provenance windows and §7.4 LIFO history traversal are checkable and phase-safe; nothing inspects superposed data. *Change:* Add the no-measure / reverse-eligibility hypotheses explicitly to T4 in §14.3.
- **C4 4**: §8 fixes target JCS form, closed cost-expression AST, variable binding per context, matching order, scheme expansion, aggregation from the scheduled event list and capacity, with §17 defaults for deferred items. *Change:* No semantic change needed; a worked target example would help first implementers.
- **C5 4**: §9-13 decide objects, byte-exact semantic envelopes and SCC hashing, linking, launch states, schedule specificity and coverage. §12.1 as revised now states a producer shift that is actually strictly feasible, removing the last producer/checker contradiction. *Change:* Enumerate §12.1 invocation contexts directly from all region-tree paths (including default-covered invocations) rather than from schedule-entry paths.
- **C6 4**: §14.1 reference interpreter defines F_B; T1-T6 are stated with usable hypotheses; §15 suites A-H are derivable; §16.3 hashes independently recompute to the printed 0.8 values (inc8, zero, sum via its SCC envelope, sum_db). The corrected SDP statement is true: Tr_out(δI)=δ·d·I, so mu'=mu+δ(d+1) leaves mu'·I-Tr_out(Y+δI)=(mu·I-Tr_out Y)+δI ⪰ δI. *Change:* State in §12.1 that δ must also exceed the interval-enclosure width so the interval Cholesky pivots clear zero at the chosen precision_bits.
- **C7 5**: Tier separation, lifted-oracle vs quantum-action interfaces, fault registers, target descriptions, certificates separating proof from evidence, and the exclusion of measurement-based cleanup in this version all match Bennett-NorthStar.md §4-5 without contradiction. *Change:* No change needed.
- **C8 4**: A VM author and a specialiser author can each start from the reference bodies, step machine, row table, schedule matching, conformance suites and §17 defaults; every deferred item carries a default and none is semantic. *Change:* Synchronise summary tables (§4.1) and theorem statements (T4) with their controlling sections so no implementer must guess precedence.

Suggestions:
1. §12.1: note that δ must be chosen large enough (relative to interval width at precision_bits) for the interval Cholesky pivot lower bounds to be strictly positive; exact strict feasibility alone does not make the interval test conclusive.
2. §12.1 invocation contexts: enumerate paths from the region tree itself, not from schedule entries, since §11 permits invocations covered only by defaults.
3. §14.3 T4: add the explicit hypotheses that the trace contains no measure frame and reversal is invoked only under §10 reverse eligibility.
4. §4.1 uncall summary: repeat §7.4's measure-frame and unverified-qreg.free traps and the shared history traversal.
5. §7.4: define 'retired' for an uncall marker, or state that uncall frames remain in history and are always skipped.

## opus

I accept draft 0.8; the blocking list is empty. Round 7's blocker B1_SDP_PRODUCER_SHIFT_NOT_STRICT is resolved: replacing Y with Y + δI and mu with mu + δ(d+1) makes Y ± J(Φ) ⪰ δI and mu′I − Tr_out(Y + δI) = (mu+δ)I − Tr_out(Y) ⪰ δI. All three matrices the checker tests are therefore strictly positive definite, and the bound ‖Φ‖◇ ≤ mu′ still holds. I also re-checked the soundness of the Hermiticity-preserving dual: −Y ⪯ J ⪯ Y gives ‖(√ρ⊗I)J(√ρ⊗I)‖₁ ≤ tr(ρ·Tr_out Y) ≤ mu. It bounds the diamond norm itself, as the text states. Apart from that one change, the diff only bumps version strings and recomputes the example hashes. I did not recompute those hashes this round: my attempt to run the check was blocked in this environment. On re-reading the whole document I found no new S0 issue and no regression. Core (§3–§7, §14, §16) remains accepted. The remaining items are S1 suggestions: state that trivial SCCs are hashed as one-member SCCs, require δ to exceed a solver's residual, and publish the 'ref' expansion library.

**Path to accept:** I already accept. To raise C5 (and C8) by one point: state in §9.2 that every symbol is hashed as a possibly trivial SCC, and publish the default 'ref' expansion library with its hash. That would leave identity and schedule-charging with no implementer choice.

- **C1 4**: §3.1–§3.7 give the tiers, the state table, the types and ownership rules, the qreg handle state machine, and the forward and inverse machine steps sub-operation by sub-operation. Nothing changed since round 7, where core consensus was reached. *Change:* Add one figure or table showing the complete per-step wire inventory (dispatch scratch, frame fields, counters) in allocation order. Basis order matters for §12.1 (allocation order), and implementers should not have to reconstruct it.
- **C2 4**: §4.1–§4.8 give every opcode with tier, arity, width rules, result suffixes and semantics. §4.2 gives each lifted row its class, slots, flag/fault and successor, including the explicit inverse exchange order for lift.alloc. *Change:* Turn the row table's slot widths (W_j, k_max) into an explicit per-row column, so frame sizing (§3.6) can be read off the table rather than derived.
- **C3 4**: The predicated step machine (§3.6) covers injectivity through old_pc and synchronisation at HALT. Prefix reversal, the XOR/involution oracle contract (§5.2), the borrow-frame translation lemma with negative tests (§5.6), the §6 provenance and window discipline, and segment uncall with purity conditions (§7.4) are all stated as checkable rules. I found nothing phase-unsafe or dependent on inspecting superposed data. *Change:* In §6.2, say explicitly whether a diagonal gate on a wire of S keeps g's window open even when g is later used as a control under a different predicate context. A short worked example would settle what 'permutation change not undone' means.
- **C4 4**: §8 gives a closed expression AST, a variable-binding table per context, requested-versus-achieved epsilon matching, aggregation by resource kind from leaf events, scheme templates, and defaults (§17 items 9–12). *Change:* Specify how topology and routing costs enter when a target declares them; currently only 'all-to-all over logical wires' is the default.
- **C5 4**: The object sections, the identity envelope with SCC handling, linking, the launch C ABI with its state machine, schedule matching by specificity with an expansion-library binding, the certificate claims including the corrected SDP witness recipe (§12.1), and composition by multiplicities are all decided. The remaining gaps are S1 with stated defaults. *Change:* State explicitly that every symbol, including one with no self-reference (inc8, zero), is hashed as a trivial one-member SCC (member hash = SHA-256 of '<scc_hash>:0'). Example 2 currently justifies the SCC treatment of @sum by its self-reference, which invites the reading that acyclic symbols hash their envelope directly.
- **C6 4**: §14.1 makes the reference interpreter normative. T1–T6 are stated with hypotheses. The §12.1 diamond-norm dual is sound: −Y ⪯ J ⪯ Y implies ‖(√ρ⊗I)J(√ρ⊗I)‖₁ ≤ tr(ρ·Tr_out Y) ≤ λmax(Tr_out Y) ≤ mu. The δ-shift with mu′ = mu + δ(d+1) now gives all three matrices ⪰ δI. The §15 suites derive from the text. *Change:* In the producer recipe, require δ to exceed the certified magnitude of any negative residual eigenvalue of a solver-produced witness, not only that the exact witness is feasible. The checker is unchanged.
- **C7 5**: Consistent with north star §3.2, §4.2, §4.4, §5.1 and §6.1: F_B success-or-fault with XOR targets, prefix reversal, the Silq/Unqomp validity window, QCM injectivity and synchronisation, unitary cleanup as the fallback under control. Established forms are used (Watrous SDP, RFC 8785, xoshiro256**). *Change:* None required. Optionally cite Watrous 2012 ('Simpler semidefinite programs for completely bounded norms') next to the 2009 reference, since the Hermiticity-preserving single-Y dual is stated there most directly.
- **C8 4**: §17 lists 14 deferred items, each with a default. Items 1–5 are non-semantic; items 6–14 fix behaviour until revised. Two executable example objects with envelopes serve as test vectors. A VM author and a specialiser author could start from §3–§7 and §16. *Change:* Publish the 'ref' expansion library (§17 item 7) as an appendix or companion document with its hash. It is the one default an executor author cannot write from this text alone.

Suggestions:
1. §9.2: say explicitly that acyclic symbols are trivial one-member SCCs (member hash = SHA-256('<scc_hash>:0')). Otherwise an implementer may hash inc8/zero envelopes directly; the test vectors pin the intended reading, but the prose should too.
2. §12.1: in the strict-feasibility recipe, require δ larger than any certified negative residual of a numerically obtained witness (solvers return Y ± J ⪰ −η·I), e.g. δ > η + 2^−precision_bits.
3. §12.1: name the basis convention for Tr_out relative to ρ (ρ vs ρᵀ) in the non-normative soundness note. It does not affect the bound, but it helps checker authors cross-check.
4. §11/§17 item 7: ship the reference expansion library 'ref' with its hash alongside the spec. Schedules default to it, so executor charging depends on it.
5. §16.3: add a third example covering an action with qloop bounds and a borrow frame satisfying the translation lemma, so suite C/F has a positive vector for §5.3/§5.6.
6. §8.3: give a default for how target topology, when declared, constrains overlap and adds routing cost.
