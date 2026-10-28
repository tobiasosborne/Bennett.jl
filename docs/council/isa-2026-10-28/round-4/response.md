# Editor's response to ISA round 4

Verdicts: all **revise**. Mean 2.83 (2.12 → 2.83 → 3.04 → 2.83). The
drop is deserved: draft 0.4 contained mechanical errors the members
broke with two-line counterexamples. Twenty-six blockers (12 + 9 + 5),
all accepted; draft 0.5 corrects them. Status reported to the
maintainer: **no-go**.

## Errors of draft 0.4, acknowledged

- `lift.retval r` with `result r` computed `r ^= r = 0` (codex B2, muse
  B1): both examples returned zero. Fixed with a dedicated internal
  `result_val` register; `result` is no longer a location.
- The stated inverse step never undid the successor XOR into `pc'` nor
  uncomputed the displaced values left in the slots (codex B1). The
  inverse is now written out in exact reverse dependency order (§3.6).
- The toggling lemma was unsound (codex B4, muse B4, opus B2): three
  counterexamples. Replaced by the **translation lemma** with explicit
  side conditions (V's targets in B, controls in X, X ∩ B = ∅; W's
  targets outside X, B and all of W's controls; ≤ 1 borrowed control per
  W gate; no swaps), and the four counterexamples are negative tests.
- Example 2 relied on name-resolution rules that existed nowhere (muse
  B2, opus B1), its heap overlapped the mapped region, its depth-fault
  statement was off by one, and the hash table printed each hash equal
  to itself (opus B5). Rewritten with explicit parameters, `lift.addr`,
  disjoint ranges, correct statements, and hashes computed from the
  envelope bytes, which are printed for example 1.

## Accepted and changed

1. **Return protocol and procedures** (codex B2, muse B1/B2, opus B1).
   `result_val`; `lift.ret` delivers by exchange through a frame slot
   compared against the stored destination id; argument capture into
   frame slots before the locations are pushed; record layout and
   location numbering stated; lprocs resolve only their own params and
   locations; `w = lift.addr @g` for globals and mapped regions; label
   values canonical under re-indexing.
2. **Predicate disjointness** (codex B3). Control-context wires disjoint
   from targets and consumed/produced operands; selectors unmodified
   until their pop; duplicates count once; MBU legality uses the
   effective control count at the cleanup site.
3. **Memory** (codex B5, muse B3). Initial allocator state stated; `heap_
   limit_max` validated at load against disjointness and 2^H; `lift.
   load`/`lift.store` carry the `inrange` check **inherently** so the
   reference is total (T1 holds for hand-written bodies); prospective
   sums at widened width.
4. **Operand schema, CC quantum registers** (codex B6, opus B3). Result-
   type suffixes; width rules; the opcode table §4.8 with tiers; `qreg[n]`
   with `qreg.new/free/slice/concat`, the binding rule to `wire[n]` and
   `region[A,W]` slots, `measure` consuming the handle; kind-dependent
   signature schemas; examples conform.
5. **R history and effects** (codex B7, muse B5/B9). Effect frames record
   overwritten destination bytes; `clock.read` writes through memory;
   block presence bit; alloc frames record the bump pointer and zero-
   filled range; effects atomic; **segment `uncall`** with explicit
   operands and a matching rule; `hostcall` as a CC instruction;
   `FAULT_ENTROPY_EXHAUSTED` as a code.
6. **Launch** (codex B10, muse B6/B8). Positional typed binding; copying
   and lifetime rules; tokens; unload with live runs; clean-only
   `qreg_prepare`; run record as a tree reversed post-order with Q calls
   inside R calls reversed once; preparing a touched register invalidates
   reversal; scheduler opaque types declared.
7. **Targets** (codex B8, muse B5, opus B4). `log2inv_eps` as an exact
   integer; arities; eps = 0 rule; `i` and `theta` variables; ordered
   `schemes` with `realises`, indexed template wires `c[e] t a[e]`,
   declared ancillae, exclusive-end repeats; `mbu_schemes`; aggregation
   from the scheduled event list including concurrent peaks.
8. **Envelope** (codex B9, muse B6, opus B5). One byte-exact format with
   tagged lines (`data`, `layout`, `device`); the closure set defined
   conservatively (an oracle's envelope includes every layout leaf);
   full version string hashed; intra-SCC references replaced in parts
   (4)–(5) and omitted from part (6); `object_hash`, `params_hash`,
   `schedule_hash` byte-exact; closure hash required for executable
   certificates.
9. **Schedule** (codex B11, muse B8). Generated-operation ordinals made
   normative; per-level `iteration`; `step` and `phase` for oracle
   operations; `generated` ordinal; a total specificity order with
   incomparable maximal matches invalid; kind-specific required fields;
   `mbu_scheme` binding; no `any` class in a schedule.
10. **Certificate** (codex B12, muse B7). Checker-computed `numerical`
    claims (interval enclosures of V†U − I, Frobenius bound); `channel`
    claims with an SDP dual witness; sampler assembling enough words with
    rejection and a non-zero seed; structural witnesses per rule with
    sub-claim indices; per-metric local and inclusive errors; minimality
    claims prohibited in this version.

## Declined

- Muse's alternative for `uncall` (static pairing): segment `uncall` with
  operands is taken, as muse also recommended.
- Codex's alternative of displacing the free'd index into the frame:
  base-only matching retained (sound, slot-free).
