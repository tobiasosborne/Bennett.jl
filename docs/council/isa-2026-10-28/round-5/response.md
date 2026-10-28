# Editor's response to ISA round 5

Verdicts: all **revise**; no member returned `verdict_core` (the S0/S1
policy and the core/contract split were added to the rubric after the
round was launched, so the members graded under the old rubric). Mean
3.12 (2.12 → 2.83 → 3.04 → 2.83 → 3.12). Nineteen blockers (codex 10,
muse 6, opus 3), re-classified by the editor under the S0/S1 rule; every
one is addressed in draft 0.6. Status reported to the maintainer:
**no-go**, core blockers fixed, contracts closed by rule or by default.

## Re-classification

| Blocker | Scope | Class | Disposition |
|---|---|---|---|
| codex B1, muse B1 (A+D inverse order) | core | S0 | fixed: §3.6 step 4 inverts an A+D row as the exact reverse of its sub-operation list; §3.7 prints C1–C5 / R1–R5 and both inverse lists; slot kinds (assignment, capture, delivery) defined |
| codex B2, opus B2 (example 2 stack) | core | S0 | fixed: the result name is a location (§3.7), R_sum = 16, S_cells = 9, success domain n ≤ 16 holds; the stack-capacity boundary is a stated result the pre-flight executes; `@sum`'s envelope is printed and verified |
| codex B3, opus B1 (segment uncall) | core | S0 | fixed: `uncall` is legal only when every frame after the segment is pure (§7.4); whole-run reversal skips reversed segments and `uncall` frames; nothing is re-executed or redone |
| codex B4 (memory boundaries) | core | S0 | fixed: pre-entry count ≤ 2^A_tab at load; CC/R `alloc` fails before mutation on heap exhaustion or a full table; `inrange` at max(ptr_width, width(n)) + 1 |
| codex B5, muse B2 (closed schemas) | core | S0 | fixed: lifted width rules (§3.3); R in region-call tiers (§4.7, §4.8); label and `qjumpr` confined to the containing function; `parmov` destinations distinct; cell padding; `bounds` defined (§5.3); memoryless objects defined (§7.2) |
| codex B6, muse B6 (handles, launch) | contract | S0 for the `measure`/free contradiction, S1 otherwise | fixed: handle transition table (§3.3); `measure` consumes, no "measure then free"; result encodings, `bennett_wait` outcomes, `hostcall` request/reply, `qreg_free` clean rule, tape field layout (§10) |
| codex B7, muse B3 (targets) | contract | S0 for unbound variables, S1 otherwise | fixed: variable-binding table and requested-vs-achieved rule (§8.1); schemes carry no cost or epsilon; leaf-event aggregation; `t2`; control order; default rate 1; `mbu_schemes` removed |
| codex B8 (dependency closure) | contract | S0 | fixed: closure set per symbol kind; `qregion` images are symbol references; globals are data symbols of the same name (§9.2) |
| codex B9, muse B4 (realised schedule) | contract | S0 | fixed by binding a versioned **expansion library** in the schedule (§11), the alternative both members named; prefix path matching; iteration vectors; per-kind selector resolution; dependency-respecting timing; `any` default |
| codex B10, muse B5, opus B3(b) (certificate SDP) | contract | S1 by rubric (numerical/SDP witness schemas), stated anyway | the diamond-norm SDP is printed with its Choi convention, constraints, norm convention, encoding and PSD procedure (§12.1); claims carry a subject with `schedule_hash`; `error` keyed like `cleanup` |
| opus B3(a) (MBU fixup) | core | S0 | resolved by deferral with a default: measurement-based cleanup is not admitted in 0.6 (§6.4, §17 item 6) |

## Decisions

- **Measurement-based cleanup deferred.** Muse recommended removal for
  0.5, opus a normative fixup. The fixup is a function of g's computing
  sequence, so it belongs in the ISA, not the target; writing it well
  needs the controlled variant and a certificate kind the north star
  (§9 item 6) wants settled in Bennett.jl's language first. 0.6 admits
  unitary cleanup only and records the default in §17.
- **Segment uncall restricted, not checked.** Codex offered checked
  non-interference; opus offered the pure-suffix rule with redo-by-delta.
  0.6 takes the pure-suffix rule and drops redo: with a pure suffix the
  state at the `uncall` frame already equals the pre-segment state on
  every component but instances, so whole-run reversal skips the
  segment. The compute–copy–`uncall` idiom still works.
- **Expansion library, not a carried graph.** Carrying the realised
  operation graph in every schedule is the heavier design; binding a
  versioned library gives the same property (two consumers execute and
  charge the same set) with the reference library `ref` as the default.
  Revisit when a scheduler exists.
- **Result name is a location.** Both members who raised it preferred
  this; the example's stack grows to 2^9 cells rather than shrinking its
  domain.

## Not changed

- Codex's request for a per-opcode schema table for every CC/R
  instruction beyond §3.3/§4.8: the width rules now cover every lifted
  row; CC/R rows follow the same rules through §4.8. S1.
- Muse's typed accessors for `QREG`/`TOKEN` results: `bennett_result_get`
  returns the 8-byte id with the kind set instead (one accessor, no new
  entry points).

## Mechanical check

`python3 tools/isa_check.py` executes both examples (including the new
stack-capacity boundary and the R_sum = 16 claim), recomputes all four
hashes under `isa=0.6` and verifies both printed envelopes (`inc8`
directly; `sum` through the one-member SCC rule).
