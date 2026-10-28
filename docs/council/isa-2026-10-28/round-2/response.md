# Editor's response to ISA round 2

Verdicts: codex, muse, opus all **revise**. Mean 2.83 (from 2.12).
Thirty-four blockers (17 + 9 + 8), converging on ten themes. All
accepted; draft 0.3 is a further rewrite. Status reported to the
maintainer: **no-go**.

## Accepted and changed

1. **Per-instruction step table** (codex B1, muse B1, opus B2). §4.2 is
   now a table: for every lifted and control row its reads, its write set
   (the displaced values in order), its flag and fault, its successor
   (including fault → HALT, call → entry index, ret → popped index,
   retval → HALT) and its inverse. The frame layout is derived from the
   widest write set (`k_max` slots of widths `W_j`). Falling off the end
   is ill-formed (terminator rule), empty bodies are ill-formed,
   out-of-range `qjumpr` faults `FAULT_UB_TRAP`.
2. **Procedure model** (codex B2, opus B2). `lproc` symbols with their own
   locations; `lift.call`/`lift.ret` push **activation records on a
   monotonic stack** (return index, caller `fp`, all of the callee's
   locations exchanged out so recursion starts clean); `sp`, `fp`,
   `depth` in the state; stack and depth limits with widened comparisons;
   callee instructions charged to the caller's budget; inlining at the
   executor's option. Mandatory inlining is gone.
3. **Reference body and binding** (codex B3, opus B1). Each oracle carries
   its reference body (the dialect's versioned *sequence* per source
   instruction, bounds checks and parallel moves included); F_B is
   defined solely by the reference interpreter on it; the object holds
   only the reference body; all executor optimisation is extensionally
   equal on D. "Exactly one" is dropped. `lift.parmov` is an atomic
   parallel move (the cycle problem).
4. **Memory model** (codex B4, muse B2, opus B6). Byte cells; `lift.load.
   iN`/`store.iN` over N/8 consecutive cells, little-endian; an
   allocation table in quantum memory with live bits; `lift.boundscheck`
   as the ISA instruction behind the object-bounds model; monotonic
   allocation with dead marking; zero-size allocation; `ptr_width` as an
   object-level constant that targets must support. Interface regions
   (`mem … in | mut`) for persistent quantum memory such as a database.
5. **Local regions** (muse B3). Function-local `qregion` with image gates
   at entry, restoration before exit, release to clean; interface regions
   as above.
6. **Borrowed systems** (codex B7, muse B4, opus B4). The old discipline is
   withdrawn with both counterexamples quoted. New rule: borrowed wires
   are touched only inside **borrow frames**, permutation-only
   subcircuits whose realised permutation must factor as P' ⊗ I_borrowed,
   verified by T3 over the frame's full domain or structurally for
   `V; W; V⁻¹` with W disjoint from V's reads and the borrowed wires;
   `qreturn` is the matched inverse of `qborrow`.
7. **Validity** (codex B8, muse B5, opus B3). Complete transfer table over
   versions, including predicate dependence, calls, `qinplace`, and cell
   versioning (a store to a cell closes windows that depend on an older
   version); the `qxor` rule rewritten; the **control context** inherited
   transitively, MBU legal only with an empty control context and `mbu:
   true`, schedules keyed by variant; **closed-window MBU prohibited** in
   this draft (codex's recommendation), removing the contradiction; T5
   restated.
8. **Nested faults** (codex B9). A clean `fr'` is required only for a
   fresh outcome; clearing is a matched second call with identical
   operand versions (checked by suite F) or retention until reversal.
9. **Exactness vs decomposition** (codex B10). Permutation status is a
   property of the realised unitary at the gate boundary (exact
   Clifford+T Toffoli allowed); oracles and permutation actions require
   ε = 0 realisations; finite angles required; operator-norm to diamond
   conversion (×2) and local vs inclusive ε in the certificate.
10. **Ownership in structured code** (codex B5, opus B7). Linear SSA with
    implicit versioning stated; indexed operands `w[i]`; pairwise
    disjointness of instruction operands and of interface bundles and
    regions; roles in signatures; signed division convention; measurement
    width.
11. **R tier** (codex B11, muse B6, opus B5). SSA immutable except block
    parameters; `br` records predecessor and prior parameter values;
    `ret` records the whole activation; the lossy-binop row deleted; Q
    calls from R recorded and reversed by re-application/adjoint; LIFO
    `uncall`; typed device operations with failure cases; clock read-then-
    increment; sector size and missing-sector rule; entropy exhaustion.
12. **Targets** (codex B12, muse B8, opus B9). JSON in RFC 8785 canonical
    form with `target_hash`; a closed cost-expression language; legality
    and cost as functions of total control count (predicate depth
    included), classes, arity, parameters and ε; parametric decomposition
    schemes; interface-wire occupancy charged to the caller; versioned
    import maps; `ptr_widths_supported`.
13. **Grammar and identity** (codex B13/B14, muse B7, opus B8). A complete
    grammar with lexical rules, metadata sections as JCS JSON lines,
    data as hex, an opcode rule; interface hash vs closure hash; SCC rule
    with `$index` references; `object_hash` excluding certificate,
    schedule and coverage; program-point ids; a **complete example
    object** with its hash computed from the stated rules.
14. **Launch and scheduler** (codex B15/B16, muse B9). An invocation state
    machine; normative fields for `bennett_arg`/`bennett_result`/
    `bennett_request` behind opaque types; `bennett_wait` returning
    HOST_REQUEST with `bennett_reply`; `bennett_run_close`; reverse
    eligibility (no measurement, registers untouched since) and reverse
    order over the run record; the scheduler request carries object and
    target bytes; the schedule is a JCS document of program-point
    entries with bindings; verbatim execution or rejection.
15. **Certificate and coverage** (codex B17). Claim kinds (`exhaustive`,
    `sampled`, `structural`, `numerical`) with normative payloads and
    checker obligations; domain range encodings; sampler algorithm/
    version/seed/count; local vs inclusive ε; composition over
    multiplicities; coverage bound to program-point ids.

## Declined

- Codex's suggestion to allow a separate approximate oracle contract:
  declined; oracles stay exact and approximation lives in actions.
- Opus's option (b) for reference binding (keeping an optimised body in
  the object alongside the reference body): declined for option (a),
  since (a) keeps one body and one F_B per object.
