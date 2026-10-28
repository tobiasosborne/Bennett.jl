# Editor's response to ISA round 1

Verdicts: codex, muse, opus all **revise**. Mean 2.12; C3 (coherent
semantics) 1.33. Seventeen + sixteen + nine blocking issues, strongly
overlapping. The diagnosis is accepted in full: draft 0.1 described the
step machine over linear SSA, which cannot hold lifted values; its fault
register design was not injective; oracle bodies were not restricted to
permutation gates; gates had no matrices; superposed quantities were put
in classical counters; adjoint and control of actions were asserted, not
defined; and the cross-repository contracts were sketches. Draft 0.2 is
a rewrite. Status reported to the maintainer: **no-go**.

## What draft 0.2 does, by theme

1. **Register-file sublanguage** (muse B1, opus B1, codex B4). Oracle
   bodies are programs over a declared register file of named `reg[N]`
   locations plus quantum memory, not SSA. New `lift.*` instructions
   (const, binop, div, icmp, select, cast, mov, load, store, alloc, free,
   faultif, call, ret, retval, oracle_call, perm_call) each write exactly
   one location by out-of-place compute then `qexch`, with the displaced
   value retained in the step's history frame. Block parameters lower to
   `lift.mov` on split edges. Linearity applies to structured code and
   interfaces only. Each lifted instruction is one budget step and the
   dialect mapping is one-to-one and versioned, so the fault set never
   depends on executor lowering (§4.2 "reference binding").
2. **Step machine** (codex B2, muse B2, opus B1). One transition from an
   immutable snapshot: dispatch, execute exactly the selected instruction,
   next-pc including **HALT self-loop**, commit pc by two exchanges, clean
   dispatch from the frame's old pc. One frame per step with a fixed
   layout `(old_pc, displaced, flag)`. Exit recomputes `at_HALT` from the
   final pc. B = 0 defined.
3. **Fault construction** (codex B1, muse B3, opus B3). Internal clean
   `faulted` and `code`; `fault c` XORs c into `code`, flips `faulted`,
   jumps to HALT (the self-loop makes first-fault-wins automatic and the
   operation injective); commit XORs into the caller's `tgt`/`fr` once,
   outside the reversed prefix. Numeric fault codes are now normative,
   with `FAULT_UB_SDIV_OVERFLOW` added.
4. **Budgets** (codex B3, muse B4, opus B2). Steps classical (every branch
   runs exactly B); `heap_used` and `depth` are wire counters updated by
   `lift.alloc`/`lift.call`/`lift.ret`; fault precedence stated; nested
   `lift.oracle_call` is one outer step under its own token.
5. **Permutation-only oracles** (muse B5, opus B4, codex B5). Well-
   formedness rule; oracles may call only *permutation actions*; action
   call graphs acyclic; recursion only via `lift.call` under the depth
   budget.
6. **`qinplace`** (codex B6, muse B7, opus B4). `@g`, `@ginv` are total
   permutation oracles (XOR evaluators) with certificates that the fault
   code is `FAULT_NONE` on the encoding and `g∘ginv = id`; the construction
   is spelled out with a clean fault bundle; the `n ≤ 16` constant is gone.
7. **Gate matrices and decomposition legality** (muse B6, codex B10).
   Every matrix printed; `rα(θ) = exp(−iθσ_α/2)`; decompositions must be
   exact including global phase, or within ε in operator norm; relative-
   phase Toffolis excluded unless a certificate proves cancellation.
8. **Action semantics, adjoint, control** (muse B8, codex B7/B8, opus B5).
   U block-diagonal in the `ins` basis, identity on borrowed systems,
   workspace clean; a full per-instruction **adjoint table** (qalloc↔qfree,
   qcopy↔quncopy, qload↔qunload, qinplace g↔ginv, loops); `ctl` at region
   level with unconditional allocation; `qloop … while` via a chain of
   fresh out-of-place flags over permutation-provenance conditions.
9. **Predication and allocation** (muse B9, codex B7). Allocation and
   release are unconditional resource operations; cleanup is explicit
   program text (`quncopy`, `qunload`, adjoints); the schedule chooses
   only realisations.
10. **Borrowed systems** (codex B8). Identity ⊗ on borrowed and external
    reference systems required; discipline: permutation gates only, basis
    restoration over the extended domain, no non-permutation controls.
11. **Uncomputation validity** (opus B6, codex B9, muse B9). Rewritten
    with basis-diagonal criteria, per-instruction provenance transfer
    rules, a window definition, obligations, MBU only with empty
    predicate stack and `mbu: true`, unitary cleanup mandatory under
    control. The "non-diagonal rz" error is gone.
12. **Memory** (muse B11, codex B4). `load`/`store` forms with width and
    sign; little-endian; regions of exactly 2^A cells with data images;
    producer-emitted range checks raising `FAULT_UB_MEMFAULT`; lifted
    alloc as a per-branch bump over a `heap` region; `ptr_width` in the
    target description.
13. **R tier** (muse B12, codex B11). History rule table per instruction;
    device models with state, operations and inverse deltas; clock as a
    tape-advanced counter; entropy as an input tape; R fault records as
    terminal states; T4 over finite traces.
14. **Resources** (muse B13, codex B12, opus B9). Resource kinds (count,
    time, occupancy, peak) with aggregation rules; a timing model; all-to-
    all logical connectivity; borrowed occupancy replaces the owner's
    charge; class capacity and cross-class costs; `mcx`/rotation costs as
    functions; space budget as peak capacity.
15. **Objects and linking** (muse B14, codex B13, opus B8). SHA-256 content
    hash over canonical bytes as sole identity, SCCs hashed as units,
    local indices as aliases; imports by name + signature with optional
    pin; link rules for duplicates, mismatches and section conflicts; an
    **EBNF** for the canonical text with byte-level normalisation rules.
16. **Reversible ABI** (codex B14, opus B8). Frame descriptors; shared
    frames only with disjoint live ranges; call/uncall history-stack
    correspondence; borrowed-from-idle-set rule.
17. **Launch ABI** (opus B7, codex B15, muse B15). Device CC entry point;
    host holds opaque register ids; C declarations with `run_id`, `wait`,
    `prepare`, `free`, `suspend`/`resume` at CC boundaries, `reverse` per
    tier (oracle re-apply, action adjoint, R uncall), enumerated errors.
18. **Scheduling interface** (codex B16, muse B15). One C ABI with a full
    request; serialised schedule as an object section; INFEASIBLE and
    UNSUPPORTED results; verbatim execution of validated stored schedules.
19. **Certificate and coverage** (codex B17). Machine-readable schema
    bound to hashes; finite-domain encodings; sampler algorithm/version/
    seed/count; proof kinds and checker obligations; numerical bound
    method; ε composed over invocation multiplicities; coverage entries
    with stable locations and shim identity.
20. **Formal model** (muse B16, codex B8). Quantum state semantics (tensor
    order, matrices, Born measurement); T2 with a proof sketch and non-
    circular hypotheses; T3 over "realised unitary is a permutation
    matrix"; T5 under static validity; T6 with fixed hypotheses and ε₁+ε₂.
21. **Nested faults** (muse B10, opus B3). No automatic propagation; a
    caller-allocated clean nested register and explicit `lift.faultif
    FAULT_CALLEE` lifted code.

## Declined

- Muse's alternative of keeping pure SSA and restricting oracles to
  structured bodies: declined in favour of the register file, because the
  north star requires arbitrary post-O3 CFGs.
- Muse B4's option (b) (redefine the budget over ISA steps and amend the
  north star): declined; option (a)'s intent is achieved by the one-to-one
  reference binding of §4.2 rather than per-instruction weights.
- Codex's alternative for `qinplace` (direct in-place permutation action
  with certified adjoint): kept legal as a plain `action_call`, but
  `qinplace` itself is the XOR-evaluator form the north star needs.
