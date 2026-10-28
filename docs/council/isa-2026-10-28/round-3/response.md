# Editor's response to ISA round 3

Verdicts: all **revise**. Mean 3.04 (2.12 → 2.83 → 3.04). Twenty-nine
blockers (14 + 10 + 5). All accepted; draft 0.4 is a full pass. Status
reported to the maintainer: **no-go**.

## Accepted and changed

1. **Step table semantics** (codex B1, muse B1, opus B5). Rows are
   classified **assignment** (compute into `disp_j`, then exchange) or
   **direct** (in-place permutation); conditional-fault rows list
   `faulted ^= flag`, `code ^= flag·C` in their effects and inverse; the
   inverse of a step is spelled out (undo fault writes and direct
   permutations under the retained flag, exchange back, uncompute flag
   and succ, clean dispatch); `lift.parmov` computes all destinations
   before any exchange; a `succ` frame field holds data-dependent
   successors; **only `lift.retval` reaches HALT with success**, labels
   cannot name HALT, `qbranch` is a terminator, fallthrough is ill-formed.
2. **Index space and procedures** (opus B5, muse B2, codex B2). The
   flattening rule: oracle blocks in text order, then the lproc closure
   ordered by closure hash with SCC index, each block contiguous;
   `w = lift.label ^b` is the only source of index values; activation
   record layout field by field (`ret_index`, `prev_fp`, `dest`, all
   locations padded to one cell); `lift.ret` computes `succ` from the
   record before mutating `fp` and delivers the result by comparing the
   stored destination id; interface inputs are read-only pseudo-locations
   (the "copied at entry" duplication is gone); `lift.ret` at depth 0
   faults, `lift.retval` inside an lproc is ill-formed.
3. **Counters** (codex B2, opus B1). Size exponents (H, A_tab, S_cells)
   are separated from counter widths (Hc ≥ H+1, Ac ≥ A_tab+1, Sc ≥
   S_cells+1, Dc); `bennett_budget` validates limits against capacities.
4. **`lift.free` and allocation** (opus B1, codex B3). Match on base only,
   flag from `match ∧ live ∧ ¬pinned`, controlled flips on the live bits,
   match uncomputed; bases pairwise distinct via `max(n, 1)`; zero-size
   allocations inaccessible; `heap_base + heap_limit ≤ 2^H`.
5. **Address layout** (opus B2, muse B3, codex B3). A null region, globals
   at fixed bases with images, the heap above them with `heap_base` equal
   to the comparison link's shim base, interface regions (W = 8) mapped
   at base addresses, `alloctab` pre-entered with **pinned live** entries
   for globals and mapped regions, dispatch of lifted loads/stores by
   address range, `in` regions preserved, the same partition for CC/R.
   Lifted call forms carry the full callee interface (`mem`, `args`).
6. **Ownership and operand schema** (codex B4, muse B4). Regions threaded
   consume-and-reproduce like bundles; per-opcode operand schema with
   results on the lhs (`w = op a b` everywhere, §4 rewritten); width
   rules (N multiple of 8, measurement chunking, cast strictness);
   `in`-wire positional use rule in actions.
7. **Borrow frames** (opus B3). The `V; W; V⁻¹` rule is withdrawn with
   opus's counterexample; the **toggling lemma** `V; W; V⁻¹; W` with its
   four side conditions is the structural rule; "touches" includes
   targets; other shapes need a T3 claim.
8. **Validity** (codex B5, muse B4). Transfer rules now include predicate
   and inherited context in every set, both operands of predicated
   `qexch`, interface-region cells for calls, `qalloc`, `qstore`/`qexchm`
   cell provenance and version advance, lifted rows; cleanups are bound
   to their exact computing sequence and its versions; control context
   defined as a multiset with an inherited control count that keys
   schedules and cleanup entries.
9. **Matched cleanup** (codex B6). `lift.oracle_uncall` consumes the
   successor versions of `tgt`/`fr'` with unchanged `ins`/`mem`, sharing
   the call's dynamic invocation identity.
10. **R tier** (codex B7, muse B5/B6, opus B5). Retained **dynamic SSA
    instances** as the reference model; frames per instruction incl.
    `hostcall`; Q calls reversed exactly once by their R frame; device
    operations over `(ptr, len)`; initial device state; the entropy tape
    as a run input; `FAULT_ENTROPY_EXHAUSTED`; the **run record as a
    tree** with post-order reversal; preparing a touched register
    invalidates reversal; measurement invalidates its register id.
11. **Targets** (codex B8, muse B7). A closed **JSON expression AST**
    evaluated in exact rationals, variables `k eps a w c`, tables, eps = 0
    and division rules; gate entries as an ordered array with class
    patterns and inclusive control ranges and first-match semantics;
    parametric **scheme templates** declared in the target; QRAM cost
    schema; aggregation per kind including classical step time.
12. **Grammar, schemas, identity** (codex B9/B10, muse B8/B9, opus B4).
    Section order and uniqueness; JSON field schemas for every metadata
    section (coverage as an object); large integers as decimal strings;
    canonical function bytes without trailing LF; the **semantic
    envelope** (ISA major, `ptr_width`, JCS signature, function bytes,
    reached data and layout entries, referenced hashes) for both interface
    and closure hashes; byte-exact reference replacement, SCC encoding,
    `object_hash`, `params_hash`, `schedule_hash`; program-point ids with
    nested ordinals.
13. **Launch and scheduler** (codex B11/B12, muse B5/B8). A `hostcall` CC
    instruction with service ids; a complete C header with opaque types,
    builders, accessors, destructors, status enum and ownership; the
    `bennett_estimate`/`bennett_coverage` name collisions fixed; scheduler
    request builders and response accessors; a **hierarchical schedule
    document** with invocation path, iteration, phase and generated-op
    selectors, kind-specific required fields, defaults, and bindings
    including inherited control count.
14. **Certificate** (codex B14, muse B10). Domains over every component of
    D with inclusive bounds and enumeration order; expectations as a
    table or a program; exact sampler replay (xoshiro256**, consumption
    order, rejection sampling); structural witnesses with sub-claim
    indices; numerical interval witnesses; typed local/inclusive errors
    with a single ×2 conversion point; multiplicities from the realised
    schedule; channel claims required for measurement-assisted
    realisations.
15. **Second worked example** (muse's path to accept): `sum_db`, an oracle
    reading an interface region through lifted memory with a recursive
    lproc and a global, plus the hash computation of both examples by the
    envelope rule (executed by a script, which is the first evidence the
    rule is implementable).

## Declined

- Codex's alternative of displacing the allocation index into the frame
  for `lift.free`: the base-only match (opus) is taken; both are sound,
  the chosen one needs no frame slot.
- Muse's "name the region in lifted loads" (`lift.load @db a`): address-
  range dispatch is taken instead, because unmodified C addresses memory
  by pointer value, not by region name.
