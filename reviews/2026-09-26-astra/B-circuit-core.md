# Astra review — B-circuit-core — 2026-09-26
Status: COMPLETE
Scope: `src/gates.jl`, `src/bennett_transform.jl`, `src/bennett_strategies.jl`, `src/pebble/`, `src/dep_dag.jl`, `src/compose.jl`, `src/controlled.jl`, `src/simulator.jl`, `src/diagnostics.jl`, `src/Bennett.jl`; supporting read of `src/lowering/types.jl`.
Method: Source inspection and focused Julia probes with bounds checks; no full suite. Only this report is modified, per the explicit review instructions (overriding repository worklog and issue-tracker mutation requirements).

## Executive summary

23 verified findings: 8 S0, 7 S1, and 8 S2.
The public API can return stale circuits, change narrowed arithmetic under automatic tabulation, truncate wider returns, and misdecode controlled unsigned outputs.
Checkpoint replay can permute results; Eager fails on real QCLA lowering; ValueEager can leave dead ancestors dirty.
The positive-budget verifier is no longer tautological and detects missing uncompute gates, but vacuous budgets and malformed metadata/primitives remain holes.
Bennett-q9pi's ordinary compose/control loop-guard repairs pass all 6,669 regression assertions.
Toffoli depth and peak-live metrics are misleading; gate-level pebbling emits Default unchanged, and folding disables group strategies.
All 14,931 existing assertions across 14 focused test files passed; the report's additional counterexamples were executed separately. No full suite was run.

## Findings

### F1 — [S0] Recompiling a redefined Julia function returns the old circuit

- Where: `src/Bennett.jl:371-376,399-402,508-518`; supporting `src/extract/callees.jl:37-60`.
- Evidence (Verified: VERIFIED-BY-EXECUTION): `g(x::Int8)=x+Int8(1); c1=reversible_compile(g,Int8); @eval g(x::Int8)=x+Int8(2); c2=reversible_compile(g,Int8); (c1===c2,simulate(c2,Int8(0)),g(Int8(0)))` prints `(true,1,2)`.
- Failure scenario: The public compiler now uses the extraction cache, whose key contains the function object but no Julia method/world version. Redefining a method preserves that function object, so extraction and compilation both hit stale entries. The internal cache's original assumption of stable package callees no longer holds for arbitrary user functions.
- Fix: Key/invalidate extraction and compilation against method/world changes (including transitive callees), or remove automatic top-level caching until invalidation is sound. An internal manual cache-clear escape hatch is insufficient for the ordinary `reversible_compile` contract.
- Test: Redefine the compiled method and a callee between compilations in the same process; the next result must match the new Julia oracle while preserving inputs/ancillae. Keep a same-world cache-hit test.
- Already tracked? **Bennett-uiaq** and **Bennett-sr8v** are closed cache-introduction work; neither open list entry tracks this bug. The extraction helper documents manual invalidation for package callees, but the public entry point does not state that repeated compilation can ignore method redefinition.

### F2 — [S0] Automatic tabulation changes narrowed comparisons and intermediate overflow

- Where: `src/Bennett.jl:381-390`; supporting `src/tabulate.jl:86-103,140-152,166-177`; `src/narrow.jl:3-11`.
- Evidence (Verified: VERIFIED-BY-EXECUTION): `fn(x::Int8)=ifelse(x<Int8(0),x*x,Int8(1))`. With `bit_width=4,optimize=false`, `simulate(reversible_compile(fn,Int8;strategy=:expression,...),Int8(-2))` returns `4`; both `strategy=:auto` and `:tabulate` return `1`. Raw input `Int8(14)` gives the same strategy discrepancy, because it encodes the same four bits.
- Independent unsigned overflow witness: `f(x::UInt8)=(x*x)>>2`, `bit_width=4,optimize=false`, input `UInt8(7)`: expression returns `0x0`, auto/tabulate return `0xc`. All three circuits pass `verify_reversibility`. Correct four-bit arithmetic computes `(49 mod 16)>>2 == 0`; the table computes `(49>>2) mod 16 == 12`.
- Failure scenario: Narrowed expression lowering interprets the four-bit sign bit as negative. The tabulate path evaluates original Int8 values 0:15, never sign-extends from the narrowed width, then merely masks the final result. Consequently an automatic cost-model decision changes branch selection and the function. The problem also extends to intermediate modular overflow before comparisons/shifts, not just output decoding.
- Fix: Generate tables from the same narrowed semantics as expression lowering, or restrict auto/tabulate eligibility to cases where equivalence is established. Evaluating the original Julia function and masking only its return is not a general implementation of W-bit arithmetic.
- Test: Exhaust all bit patterns for W=2,3,4 on signed comparisons, shifts after overflowing arithmetic, and intermediate-overflow branches; require expression/auto/tabulate equality or an explicit unsupported-combination error.
- Already tracked? no matching open bead found; distinct from the return-width truncation finding and Bennett-g7d6.

### F3 — [S0] The public tabulate path truncates wider return values to the first argument's width

- Where: `src/Bennett.jl:353-360,383-386`; supporting `src/tabulate.jl:144-152`.
- Evidence (Verified: VERIFIED-BY-EXECUTION): For `f(x::Int8)=Int16(x)*Int16(x)`, `reversible_compile(f,Int8;strategy=:expression)` has output widths `[16]` and returns `400` at input `Int8(20)`. `strategy=:tabulate` has `[8]` and silently returns `-112` at the same input.
- Failure scenario: With no requested narrowing (`bit_width=0`), `out_width` is inferred from the first argument, not the return type; table construction masks the correct native result to this unrelated width. A user selecting an optimization changes the computed function.
- Fix: Infer/validate the actual scalar integer return width before choosing the tabulate output layout. With explicit `bit_width`, define and check narrowing semantics separately; reject unsupported return shapes rather than truncate implicitly.
- Test: Int8→Int16 widening, UInt8→UInt16, and small-input functions returning Bool or different-width tuples; tabulate and expression paths must agree wherever both claim applicability.
- Already tracked? no matching open bead found. This is separate from Bennett-g7d6's dropped globals during `_narrow_ir`.

### F4 — [S0] Controlled simulation changes unsigned results into negative signed integers

- Where: `src/controlled.jl:218-229`; `src/simulator.jl:253-257`.
- Evidence (Verified: VERIFIED-BY-EXECUTION): `c = reversible_compile(identity, UInt8; strategy=:expression); (simulate(c, 0xff), simulate(controlled(c), true, 0xff))` prints `(0xff, -1)`.
- Broader signedness limitation: `f8(x::UInt16)=x%UInt8; c8=reversible_compile(f8,UInt16;strategy=:expression)` gives `(simulate(c8,0xffff),simulate(c8,UInt16,0xffff),f8(0xffff)) == (-1,0xffff,0xff)`. The untyped width-mismatch fallback is documented, but it also causes the typed wider-output overload to sign-extend an actually unsigned source. The circuit has no return-type metadata with which to repair this automatically.
- Failure scenario: `_simulate_ctrl` prepends the signed `Int(ctrl)` and a one-bit input width. Both changes defeat the unsigned-output heuristic even for an otherwise width-aligned unsigned circuit. The promised `ctrl ? f(x) : 0` semantics fail for every unsigned result with the sign bit set. Gates remain clean; the verifier cannot detect wrong decoding.
- Fix: Carry output type/signedness metadata independently of control inputs, or explicitly decode using the original payload-input layout in the controlled wrapper. Merely changing the control to unsigned does not repair the width-alignment condition.
- Test: Exhaust all UInt8 inputs under both controls, including tuple outputs; compare the value and type with the uncontrolled result. Cover UInt64 sign-bit values too.
- Already tracked? no matching open bead found; Bennett-zc50 fixed the uncontrolled heuristic only.

### F5 — [S0] Checkpoint replay permutes a group's result bits

- Where: `src/pebble/pebbled_groups.jl:75-96,449-455,467-477`.
- Evidence (Verified: VERIFIED-BY-EXECUTION): `lr = LoweringResult(ReversibleGate[CNOTGate(1,2)], 3, [1], [3,2], [1], [2], [Bennett.GateGroup(:a,1,1,[3,2],Symbol[],2,3)], false)`. At input 1, Default returns `2`, Checkpoint returns `1`, and `PebbledGroupStrategy(1)` returns `1`. All simulations finish without invariant errors.
- The incorrectly permuted Checkpoint circuit also returns `true` from `verify_reversibility`; this is a functional error with clean ancillary state.
- Failure scenario: `result_wires` is an ordered vector describing logical bit order. `_replay_forward!` converts it to a set and appends owned results in increasing allocation order; later code zips those wires with the original ordered vector. A valid group with result `[3,2]` silently becomes `[2,3]`. Duplicated result positions also lose multiplicity. No GateGroup contract requires ascending unique results.
- Fix: Construct `new_result` by mapping each entry of `group.result_wires` in its existing order. Classify/free owned wires separately, once each, to avoid double-freeing aliases. Do not use a set to reconstruct ordered output metadata.
- Test: Permuted, duplicated, and non-contiguous result vectors; compare every strategy with Default and verify every output bit plus ancilla cleanup.
- Already tracked? no matching open bead found.

### F6 — [S0] Simulator silently truncates wide values and accepts unsupported output widths

- Where: `src/simulator.jl:13-25,424-441`; `src/gates.jl:107-162`.
- Evidence (Verified: VERIFIED-BY-EXECUTION): (Julia 1.12.3, `--check-bounds=yes`). `c = reversible_compile(identity, UInt64; strategy=:expression); simulate(c, UInt128(1)<<64)` prints `0`. `c = ReversibleCircuit(128, ReversibleGate[], collect(1:128), collect(1:128), Int[], [128], [128]); simulate(c, UInt128(1)<<100)` also prints `0`.
- Failure scenario: `_assert_input_fits` skips **all** range checks for widths ≥64 even though its argument accepts every `Integer`; decoding always accumulates into `UInt64`. Over-wide inputs to an ordinary 64-bit circuit wrap silently, and a 128-bit identity loses its high bits while the input-preservation assertion still passes. This is an element-width limit, not a total-wire-count limit.
- Fix: Validate arbitrary `Integer` values against the declared signed/unsigned interval even at width 64. Either reject element widths >64 in the constructor or implement wider decoding using UInt128/BigInt; validate positive widths consistently.
- Test: Boundary probes at 63, 64, 65, 128 bits, including `UInt128(1)<<64`, `typemin(Int128)`, and BigInt values; supported widths must round-trip or reject before gates execute.
- Already tracked? no matching open bead found.

### F7 — [S0] Duplicate logical input wires bypass input-preservation verification

- Where: `src/gates.jl:114-159`; `src/simulator.jl:186-202`; `src/diagnostics.jl:243-250`.
- Evidence (Verified: VERIFIED-BY-EXECUTION): `c = ReversibleCircuit(2, ReversibleGate[CNOTGate(1,2)], [1,1], [2], Int[], [1,1], [1]); simulate(c,(1,0))` returns `0`, and `verify_reversibility(c)` returns `true`.
- Additional metadata bypasses: a declared input with `input_widths=[0]` is never randomized and `verify_reversibility` returns true although `simulate` rejects it. `ReversibleCircuit(3,ReversibleGate[NOTGate(3)],[1],[2,3],Int[],[1],[1])` returns `(simulate(c,0),verify_reversibility(c)) == (0,true)`: wire 3 is permanently dirty but classified as an output position that decoding never reads.
- Failure scenario: Set-based partition checks erase duplicate positions. The second logical input overwrites the first during ingestion, and the “original inputs” snapshot is taken only afterward. The checker therefore certifies preservation of the overwritten physical state, not the caller's two independent inputs.
- Fix: Reject duplicate input wire positions, and validate `sum(input_widths)==length(input_wires)` and `sum(output_elem_widths)==length(output_wires)` at construction. Preserve explicitly supported output aliases, but distinguish them from illegal independent-input aliasing. Also reject duplicate ancilla/guard metadata or define its semantics explicitly.
- Test: `(1,0)` and `(0,1)` on the aliased fixture must fail at construction; malformed width totals must fail before simulation. Retain the legitimate input/output pass-through tests.
- Already tracked? no matching open bead found; Bennett-6azb's cross-class checks do not cover within-input duplication.

### F8 — [S0] Five self-reversing strategy paths silently discard failing loop guards

- Where: `src/pebble/eager.jl:64-75`; `src/pebble/value_eager.jl:47-54`; `src/pebble/pebbling.jl:144-151`; `src/pebble/pebbled_groups.jl:288-295,393-400`; contrast `src/bennett_transform.jl:307-317`.
- Evidence (Verified: VERIFIED-BY-EXECUTION): `lr = LoweringResult(ReversibleGate[CNOTGate(1,2)], 3, [1], [2], [1], [1], Bennett.GateGroup[], true, [Bennett.LoopGuard(3,:L,1)])`. Default rejects the contradictory metadata. Eager, ValueEager, Checkpoint, Pebbled(2), and PebbledGroup(2) each produce `(length(c.loop_check_wires), simulate(c,1)) == (0,1)`.
- Failure scenario: These fast paths run before the loop-guard fallback and omit Default's `isempty(lr.loop_guards)` assertion. The guard is zero (failure), so `_validate_self_reversing!` accepts it as a clean ancilla, and `_build_circuit` silently removes its guard role. A purported universal rejection depends on strategy choice.
- Fix: Route every self-reversing fast path through `_bennett_default(lr)` or a single shared validator/builder which rejects contradictory loop metadata before classification.
- Test: The fixture must fail identically for all strategies; verify valid self-reversing fixtures still use the same gate stream and loop-bearing non-self-reversing fixtures preserve guards.
- Already tracked? no matching open bead found; Bennett-rjk7's uniform-fast-path guarantee is incomplete.

### F9 — [S1] Gate-level Eager reverses dead-end writes using the wrong historical controls

- Where: `src/pebble/eager.jl:96-105,114-120`.
- Evidence (Verified: VERIFIED-BY-EXECUTION): `lr = LoweringResult(ReversibleGate[CNOTGate(1,3), NOTGate(1), CNOTGate(1,3)], 3, [1], [2], [1], [1]); simulate(Bennett.bennett(lr), 0)` returns `0`; replacing the strategy with `EagerStrategy()` throws `Ancilla wire 3 not zero post-circuit`.
- Production-lowering witness: `f(x::Int8)=(x+Int8(3))*(x+Int8(1)); lr=Bennett.lower(extract_parsed_ir(f,Tuple{Int8};optimize=false);add=:qcla,fold_constants=false)`. At `Int8(-128)`, Julia and Default both return `3`; Eager throws `Ancilla wire 26 not zero post-circuit`. Its forward writes are gates 11/26/28/29, respectively `Toffoli(8,17,26)`, `Toffoli(25,17,26)`, `Toffoli(24,29,26)`, `Toffoli(22,30,26)`. This is not limited to hand-built lowering results.
- Failure scenario: Wire 3 is never a control, but its two writes read wire 1 on opposite sides of a NOT. Eager replays both writes against the final control value, so their XOR is zero and the old accumulated 1 remains dirty. Reversing only a target's modification path is not an inverse when its controls changed between those modifications. The comment claiming dead-end cleanup is always correct is false.
- Fix: Permit early cleanup only when every replayed gate's control values are provably unchanged across the moved interval (wire-version dependencies), or conservatively retain canonical reverse order. Do not assume an exclusive consumer of the target proves control stability.
- Test: This three-gate fixture for both input values, plus generated sequences with interleaved control writes; compare outputs with Default and explicitly assert ancilla/input invariants.
- Already tracked? no matching open bead found.

### F10 — [S1] ValueEager strands a dead value's ancestors and returns an unclean circuit

- Where: `src/pebble/value_eager.jl:113-120,135-165`.
- Evidence (Verified: VERIFIED-BY-EXECUTION): Construct `gates = ReversibleGate[CNOTGate(1,2), CNOTGate(2,3)]`, groups `GateGroup(:a,1,1,[2],Symbol[],2,2)` and `GateGroup(:b,2,2,[3],[:a],3,3)`, and `lr = LoweringResult(gates,3,[1],[1],[1],[1],groups,false)`. Default returns `1` for input 1; ValueEager throws `Ancilla wire 2 not zero post-circuit`.
- Failure scenario: `b` is dead and cleaned in phase 1, but `a` keeps its consumer count of 1. Phase 3 neither enqueues `a` nor visits already-cleaned `b` to release that count. No completion assertion catches the missing cleanup before a circuit is returned.
- Fix: Release dependencies of phase-1-cleaned groups before building the phase-3 queue; ensure each edge is released exactly once and assert every group was cleaned before returning. Do not clean ancestors prematurely during the forward scan.
- Test: A two-node dead chain, a dead branch sharing an ancestor with a live result, and longer chains; exhaustive input simulation and `verify_reversibility` must pass.
- Already tracked? **Bennett-htu2**. Its consumer-count hypothesis is correct, now concretely confirmed. Its tentative suggestion that ancestors “would still be cleaned by the final pass” is wrong: the final pass never schedules them, so this is a correctness failure, not merely missed optimization.

### F11 — [S1] Four fixed self-reversing probes accept a false cleanup claim

- Where: `src/bennett_transform.jl:80-92,122-151,307-324`.
- Evidence (Verified: VERIFIED-BY-EXECUTION): `lr = LoweringResult(ReversibleGate[CNOTGate(1,5), CNOTGate(2,6), CNOTGate(3,6)], 6, [1,2,3,4], [5], [4], [1], Bennett.GateGroup[], true); c = Bennett.bennett(lr)` succeeds and emits only three gates. `simulate(c,2)` throws `Ancilla wire 6 not zero post-circuit`.
- Failure scenario: Garbage `input_bit_2 XOR input_bit_3` is zero on all-zero, all-one, first-lane, and last-lane probes, but nonzero for ordinary interior-lane inputs. The fast path trusts an invalid claim and returns a broken circuit. Normal simulation still catches it; this is a compile-time contract-check gap, not a demonstrated bypass of the positive-budget verifier.
- Fix: Exhaustively check small input spaces, and treat larger producer claims as explicitly trusted unless backed by a structural proof/validated primitive contract. Extra random probes improve detection but cannot justify the existing universal “forged tag fails” guarantee.
- Test: This four-input-bit adversary and interior-lane leakage under all six strategies. Keep the current unconditional-dirty/input-flip rejection tests.
- Already tracked? **Bennett-lxk7** discusses increasing probe coverage; **Bennett-egu6** is closed with a stronger guarantee than the implementation provides. The open description correctly identifies limited coverage but understates it as a future-producer possibility; a concrete false positive exists now at the public LoweringResult boundary.

### F12 — [S1] A zero or negative verification budget certifies a dirty circuit without executing it

- Where: `src/diagnostics.jl:239-278`; `src/controlled.jl:247-253`.
- Evidence (Verified: VERIFIED-BY-EXECUTION): `c = ReversibleCircuit(3, ReversibleGate[NOTGate(3)], [1], [2], [3], [1], [1]); verify_reversibility(c; n_tests=1)` throws `ancilla wire 3 not zero after forward pass`; both `n_tests=0` and `n_tests=-1` return `true`.
- Failure scenario: An empty computed test budget takes the empty loop and returns the same success certificate as a checked circuit. The controlled overload delegates to this behavior.
- Fix: Require `n_tests > 0` at entry with `ArgumentError`; if an explicit skip feature is wanted, expose a distinguishable skipped result rather than `true`.
- Test: Dirty-ancilla and input-mutation fixtures with budgets 0 and -1 must reject; budget 1 must execute and detect their unconditional violation.
- Already tracked? no. Bennett-asw2's original tautology is fixed for positive budgets; this is a remaining vacuous-success path.

### F13 — [S1] Irreversible self-controlled gates are accepted and can pass the verifier

- Where: `src/gates.jl:7-22,107-162`; `src/simulator.jl:1-3`; `src/diagnostics.jl:239-276`.
- Evidence (Verified: VERIFIED-BY-EXECUTION): `c = ReversibleCircuit(1, ReversibleGate[CNOTGate(1,1)], Int[], [1], Int[], Int[], [1]); verify_reversibility(c)` returns `true`. Applying this gate twice to `Bool[true]` produces `Bool[false]`, disproving the documented self-inverse gate contract.
- Failure scenario: `CNOT(c,c)` implements `b[c] XOR= b[c]`, irreversibly zeroing the bit; a Toffoli whose target is a control has the same defect on some inputs. The verifier initializes outputs/ancillae at zero, so some invalid gates are invisible even to the forward/reverse check. The constructor also never validates gate wire bounds; compose/controlled add only an upper-bound check.
- Fix: Validate positive distinct target/control indices in gate constructors (two equal Toffoli controls may be normalized to CNOT or explicitly rejected). Validate every referenced wire is within the circuit at construction. Do not rely on sampling initialized-zero states to establish gate invertibility.
- Test: Reject self-controlled CNOT/Toffoli and zero/negative/out-of-range indices at their boundary. Exhaustively establish that accepted primitive gates are permutations/self-inverse on all their local bits.
- Already tracked? **Bennett-lcye** accurately describes the acceptance bug. This probe additionally shows why the existing verifier is not a substitute for primitive validation.

### F14 — [S1] The dependency DAG omits read-before-write hazards

- Where: `src/dep_dag.jl:37-60`; `test/test_dep_dag.jl`.
- Evidence (Verified: VERIFIED-BY-EXECUTION): Extract the DAG from `Bennett.bennett(LoweringResult(ReversibleGate[CNOTGate(1,2), NOTGate(1)],2,[1],[2],[1],[1]))`: both nodes have `preds == Int[]`. Forward execution of these gates on `Bool[1,0]` yields `[0,1]`; the reversed order, allowed by this DAG, yields `[0,0]`.
- Failure scenario: The graph tracks the last writer, but not earlier readers of a wire subsequently overwritten. It certifies a noncommuting control read / target write as independent. A scheduler using the advertised dependency graph can reorder the computation incorrectly. Current strategy bodies do not consume this graph, so this is not a demonstrated default-pipeline miscompile.
- Fix: Track outstanding readers per wire; writes depend on those readers as well as the previous writer. Reads sharing only controls can remain independent; disjoint gates must remain independent. Define output nodes from final producers, not every historical writer.
- Test: Read→write, write→read, multiple readers→write, shared-control, and disjoint fixtures; enumerate permitted topological orders on tiny circuits and compare their truth tables. Existing tests mainly check edge reciprocity, which cannot expose missing edges.
- Already tracked? no matching open bead found.

### F15 — [S1] The new cached entry path rejects callable objects that extraction supports

- Where: `src/Bennett.jl:281,326,376`; supporting `src/extract/callees.jl:37,52` and `src/extract/entry.jl:67`.
- Evidence (Verified: VERIFIED-BY-EXECUTION): Define `struct Fun end; (::Fun)(x::Int8)=x+Int8(1)`. `extract_parsed_ir(Fun(),Tuple{Int8}).ret_width` returns `8`; `reversible_compile(Fun(),Int8)` throws `MethodError: no method matching _extract_parsed_ir_cached(::Fun, ::Type{Tuple{Int8}}; optimize::Bool, mem::Symbol)`.
- Failure scenario: The generic public compiler and extractor accept callable values, but the inserted cache helper and Dict key restrict `f` to `Function`. A valid Julia callable gets past signature validation and crashes only at the cache boundary.
- Fix: Preserve the generic callable contract in the helper/key, with a sound cache policy for callable state, or bypass caching for callable objects. If some stateful shapes cannot be supported, reject those explicitly and consistently before extraction.
- Test: Stateless callable structs, captured closures, and ordinary generic functions through both extraction and public compilation, with exhaustive Int8 output/invariant checks.
- Already tracked? no matching open bead found; introduced by the public reuse of the Bennett-uiaq extraction-cache helper.

### F16 — [S2] Toffoli depth drops dependencies carried through CNOT gates

- Where: `src/diagnostics.jl:125-159`; `BENCHMARKS.md:185-198` (Toffoli-depth comparison table).
- Evidence (Verified: VERIFIED-BY-EXECUTION): For gates `[ToffoliGate(1,2,3), CNOTGate(3,4), ToffoliGate(4,5,6)]` on seven classified wires, `(depth(c), toffoli_depth(c), t_depth(c), t_count(c))` prints `(3, 1, 1, 14)`. The second Toffoli consumes the first Toffoli's result through wire 4, so the documented weighted dependency depth is 2.
- Failure scenario: `gate isa ToffoliGate || continue` skips dependency propagation, not just the Clifford gate's zero cost. Chains separated by CNOT copies appear parallel, understating Toffoli depth and both T-depth estimates. Published depth comparisons derived from this function need recomputation.
- Fix: Visit every gate, propagate the maximum incoming depth to all touched wires, and increment only for Toffoli. Keep the physical wire-exclusivity convention of `depth` consistent; document T-depth as an estimate under the chosen decomposition.
- Test: The three-gate bridge must have Toffoli depth 2 and `t_depth(...; decomp=:nc_7t)==6`; add multi-bridge chains and disjoint-Toffoli controls.
- Already tracked? no matching open bead found.

### F17 — [S2] “Peak live wires” is only the all-zero input's Hamming-weight trace

- Where: `src/diagnostics.jl:98-100,199-219`; `BENCHMARKS.md:37-43`; `test/test_eager_bennett.jl` and `test/test_value_eager.jl` peak-liveness comparisons.
- Evidence (Verified: VERIFIED-BY-EXECUTION): `c = ReversibleCircuit(8,ReversibleGate[],collect(1:8),collect(1:8),Int[],[8],[8]); peak_live_wires(c)` prints `0`, though simulating input `0xff` starts and ends with eight nonzero wires. Source initializes all wires to false and never ingests inputs.
- Failure scenario: A function preserving eight live input bits is advertised as having zero peak live wires. Data-dependent scratch that is zero only for the chosen input is counted as free, and comparisons in BENCHMARKS/test output are presented as space/qubit savings without measuring lifetime or allocated width.
- Fix: Rename the current helper to describe its actual all-zero Hamming-weight statistic, or add explicit input parameters for that statistic. Use allocation/lifetime analysis for a static live-wire resource metric; report `n_wires` until that exists. Remove the claim that this count is the quantum statevector width.
- Test: Identity, fanout, and a Toffoli network whose all-zero execution is idle but other inputs activate every scratch wire; any input-dependent statistic must identify its chosen inputs.
- Already tracked? no matching open bead found. C3 and C8 already note the discrepancy; it is still real.

### F18 — [S2] Forward-half guessing misanalyzes valid circuits and can index before the gate array

- Where: `src/dep_dag.jl:25-34,78-85`; `src/diagnostics.jl:163-197`.
- Evidence (Verified: VERIFIED-BY-EXECUTION): A self-reversing one-CNOT copy circuit has zero extracted DAG nodes. A valid eight-bit identity with no gates and input/output wires `1:8` makes `extract_dep_dag` throw `BoundsError ... index [-3]`. A one-wire constant-output `NOTGate(1)` circuit reports `constant_wire_count(c)==0`.
- Failure scenario: Both helpers infer the forward length from `(n_gates-n_outputs)÷2`. That layout does not exist for self-reversing, controlled, composed, or rescheduled circuits. Even Default's loop guard copy gates change the formula; two guards move the inferred midpoint by one gate. The generic circuit API has no provenance establishing the assumption.
- Fix: Analyze the supplied gate stream as such, or take a LoweringResult/explicit forward range and reject incompatible layouts. For constants, define whether the metric concerns final outputs or transient forward wires and implement that definition without guessing provenance.
- Test: Zero-gate identity, one-CNOT self-reversing copy, constant-output circuit, two-loop Default, controlled, compose, and non-default strategy results. Assert actual expected nodes/constants, not just nonempty output.
- Already tracked? no matching open bead found; the earlier C3 report identified the heuristic but it remains present.

### F19 — [S2] Gate-level pebbling spends quadratic work per recursion to emit the unchanged Bennett stream

- Where: `src/pebble/pebbling.jl:88-121,158-178,199-238`.
- Evidence (Verified: VERIFIED-BY-EXECUTION): plus induction over the exact emission code. For `n=2:8` independent NOT forward gates, every successful `PebbledStrategy(k)` produced a gate vector exactly equal to Default. With the unfolded Int8 polynomial `x*x+3x+1` (760 gates under `optimize=false`), `PebbledStrategy(8)` throws `insufficient pebbles ... need at least 11 for 753 gates, have 1`. The folded version (344 gates) similarly throws on 337 remaining gates. An initial larger phi probe was stopped when it reached the excessive DP path; no timing claim is based on that interrupted run.
- Failure scenario: Each recursion emits a forward prefix, recursively emits the suffix/copy/reversed suffix, then reverses the prefix. Inductively this is exactly `forward ++ copy ++ reverse`, with identical wire allocation and peak trace. There is no checkpoint or wire reuse, yet the split computation rebuilds an O(n²s) DP table at each level and may reject a useful-looking budget.
- Fix: Remove/rename the advertised optimization until a real bounded-storage schedule exists, or implement checkpoint/recompute plus allocation under an actual budget. Validate feasibility before expensive work. Do not “fix” this solely by clamping k while retaining the identical stream.
- Test: Require a demonstrated resource reduction on a nontrivial chain and check a real bound, alongside exhaustive functional/invariant tests. An equality-only test certifies the no-op.
- Already tracked? **Bennett-mjtl** is substantively correct. Its description cites `pebbled_groups.jl` for the throwing gate-level path, but the relevant throw is `pebbling.jl:221`. “Almost every k” is not a universal theorem; the unchanged-stream proof is.

### F20 — [S2] Default constant folding disables the group strategies, and PebbledGroup ignores its budget on populated metadata

- Where: `src/lowering/driver.jl:529-535`; `src/pebble/value_eager.jl:56-59`; `src/pebble/pebbled_groups.jl:297-330,402-413`; `src/Bennett.jl:360,386,516`.
- Evidence (Verified: VERIFIED-BY-EXECUTION): For Int8 `x+3` and `x*x+3x+1`, `lower(...;fold_constants=true)` yields zero groups; ValueEager, Checkpoint, and PebbledGroup(3) are byte-for-byte Default gate streams. With folding off, the polynomial has five groups and Checkpoint/PebbledGroup(3) both produce 3,114 gates/241 wires versus Default's 1,528 gates/465 wires. `all(g.wire_start>0)` dispatches directly to Checkpoint before any `max_pebbles` check.
- Budget probe: unfolded `x+3` gives exactly `(gates=190,wires=49)` for `PebbledGroupStrategy(k)` at every `k ∈ (0,1,2,3,100)`, including budgets above its two groups and below them.
- Failure scenario: The default lowering destroys exactly the metadata required by three advertised construction strategies. With metadata restored, a positive PebbledGroup budget is still ignored on the preferred path. `reversible_compile` always invokes bare `bennett(lr)`, so selecting these strategies requires manual lower→bennett calls; they are not wholly dead code, but the earlier C3 claim about the normal entry point is correct.
- Fix: Preserve/remap group ranges through folding or explicitly reject unsupported strategy/metadata combinations. Make `max_pebbles` constrain a real scheduler or reject it when checkpoint delegation cannot honor it. Expose a separate construction-strategy option only if intended; do not conflate it with expression/tabulate selection.
- Test: Default-lowering strategy tests must assert which implementation actually ran and a meaningful resource difference; budget tests must vary k and assert its stated bound or an explicit rejection.
- Already tracked? **Bennett-exb3** accurately tracks metadata loss. The populated-metadata budget bypass is an additional issue; Bennett-mjtl concerns the other, gate-level strategy.

### F21 — [S2] Repeated identical narrowed compilation permanently retains duplicate circuits

- Where: `src/Bennett.jl:389-390,420-421,508-518`; `src/narrow.jl:13-24`.
- Evidence (Verified: VERIFIED-BY-EXECUTION): After `Bennett._clear_compile_cache!()`, run `[reversible_compile(f,Int8;bit_width=4,strategy=:expression) for _ in 1:10]` for `f(x::Int8)=x+Int8(1)`: `(length(Bennett._compile_cache), length(unique(objectid.(cs)))) == (10,10)`.
- Failure scenario: Each call creates a fresh narrowed ParsedIR, so the objectid-based cache never hits even for identical source/options. The global unbounded Dict then strongly retains every duplicate circuit for the rest of the process, after the caller releases it. Large repeated compiles can consume unbounded memory.
- Fix: Cache narrowing by source identity/version and width, or key final compilation by the original source plus all transformation options. Bound the cache or make retention explicitly managed; avoid caching transient identities that cannot be reused.
- Test: Repeated identical narrowed compiles keep cache size stable and reuse the result; changing width/source/options produces distinct entries. Exercise eviction or explicit lifecycle behavior for many unique compiles.
- Already tracked? no matching open bead found.

### F22 — [S2] Left-associated composition grows the gate tape exponentially

- Where: `src/compose.jl:212-224`.
- Evidence (Verified: VERIFIED-BY-EXECUTION): Let `a=reversible_compile(x->x+Int8(1),Int8)` (58 gates) and repeatedly assign `l=compose(l,a)` starting at `l=a`. For 2 through 9 stages, gate counts are `174,406,870,1798,3654,7366,14790,29638`, while wire counts are only `74,107,140,173,206,239,272,305`. Simulation at zero returns the correct stage count.
- Failure scenario: Each append copies the already-composed left circuit twice: `G(n)=2G(n-1)+58`, hence `G(n)=58*(2^n-1)`. A natural fold over a pipeline exhausts time/memory exponentially even though an equivalent composition can use each component a constant number of times. No semantic failure is claimed for the completed small cases.
- Fix: Preserve the sequence of original components and uncompute intermediates in reverse order once, or expose an n-ary composition builder that emits `c1…cn reverse(c[n-1])…reverse(c1)` with suitable guard copies. Document current binary association costs until this is fixed.
- Test: Build equal pipelines by left/right folds and a direct sequence builder; require identical truth tables/guards and linear gate growth for the supported pipeline API.
- Already tracked? no matching open bead found. The earlier C3 report correctly identified the recurrence; it persists.

### F23 — [S2] Tabulation bypasses validation of known keyword values

- Where: `src/Bennett.jl:296-301,353-360,381-386`; domain validators in `src/lowering/driver.jl:117-138`.
- Evidence (Verified: VERIFIED-BY-EXECUTION): `reversible_compile(identity,Int8;strategy=:tabulate,add=:bogus)`, `mul=:bogus`, `target=:bogus`, and `hashcons=:bogus` all return a 2,556-gate circuit. `bogus=1` correctly throws an unknown-kwarg ArgumentError.
- Other executed validation asymmetries: `reversible_compile(extract_parsed_ir(identity,Tuple{Int8});max_loop_iterations=-1)` returns a circuit although the Julia-function overload rejects that value; `reversible_compile(identity,Tuple{Float64};bit_width=4,strategy=:expression)` accepts four-bit Float64 input/output widths although the specialized Float64 overload forbids narrowing. These paths need the same central validation policy.
- Failure scenario: Unknown keyword names are rejected, but recognized keywords with invalid values are checked only by `lower()`. The tabulate early return skips it. The same typo is accepted or rejected depending on optimization selection, including `:auto` selection.
- Fix: Put shared option-domain validation before both tabulate exits, and distinguish explicitly irrelevant options from invalid values consistently across overloads.
- Test: A matrix of malformed values across `:expression`, `:tabulate`, and an auto-tabulated narrow function; all must fail with scoped ArgumentErrors.
- Already tracked? no matching open bead found; this is residual to Bennett-xlsz/Bennett-k0bg.

## Unconfirmed suspicions

- `_infer_self_reversing` exempts the entry predicate from cleanup, whereas `_bennett_default` immediately revalidates without that exemption. A future tagged ordinary lowering could therefore be promoted and then rejected. No currently reachable Julia arithmetic producer was found: `src/lowering/arith.jl:280-310` explicitly retains an unreachable `length(full)==W` tag for its 2W multiplier. This is a latent coupling concern, not a confirmed current compile failure.
- The final compile cache uses a numeric `objectid(parsed)` without retaining/comparing the ParsedIR itself. Identity reuse/hash collision could produce an unrelated cache hit; no collision reproducer was established, so no additional miscompile is claimed beyond the executed stale-method case.
- No currently compiler-produced GateGroup with permuted result wires was identified. The checkpoint permutation failure is confirmed at the supported LoweringResult/GateGroup boundary; its frequency in normal lowering remains unestablished.

## What is sound (brief)

- The positive-budget verifier detects a deliberately dirty ancilla and a deliberately flipped input before the reverse pass. `simulate` independently rejects the dirty fixture. Bennett-asw2 is not still tautological in normal use.
- Removing the final gate from a **copy** of a compiled Int8 increment circuit makes `verify_reversibility(...;n_tests=1)` fail with `ancilla wire 18 not zero after forward pass`. The checker detects a missing real uncompute gate, not just synthetic unconditional fixtures.
- Bennett-q9pi is fixed for valid circuits: all 6,669 guard/composition/control tests pass, including first-/second-stage failures, both guards, nested composition, disabled controls, self-reversing tabulation, and input/output pass-through aliases. The contradictory fast-path metadata finding is separate from those repaired ordinary paths.
- The five actual cross-class disjointness checks and union/range coverage checks in `ReversibleCircuit` are sound for the vectors supplied at construction. Intentional input/output overlap is handled by `controlled` using fresh outputs. The holes are input duplication, shape validation, gate validation, and reliance on mutable public vectors remaining unchanged.
- Default's forward/copy/reverse construction preserves the computed output while returning ancillary state and inputs to their initial values for valid primitives. Exhaustive 256-input sweeps pass for increment, polynomial, nested diamonds, and a bounded popcount loop; loop-guard fallback is correct under every strategy tested.
- Checkpoint is a real optimization when metadata is retained: the unfolded polynomial drops from 465 to 241 wires, and the existing SHA test drops from 2,017 to 1,761 wires. The blanket claim that all strategies are dead is too broad; normal `reversible_compile` selects Default, while manually selected Checkpoint is exercised and useful.
- `depth` correctly computes unit-gate depth for the declared convention that every touched wire participates in a layer. Shared-control gates commute logically but cannot simply occupy the same physical-wire layer; C3's suggestion to treat those as automatically parallel would change the metric, not repair this implementation. `gate_count` and `t_count=7*Toffoli` agree with their stated three-primitive/decomposition convention.
- Simulator storage is an ordinary `Vector{Bool}` sized by `n_wires`, with no 64-wire total limit: a 321-wire two-UInt64 adder returns zero for `(typemax(UInt64),1)` and passes verification. The 64-bit problem is numeric ingestion/decoding. `simulate!` resets its buffer and checks exact buffer length before reuse.
- Unknown keyword **names** and direct/Tuple Float32 arguments reject as intended. Precompile workload loading completed successfully on Julia 1.12.3; no swallowed precompile error was observed. It precompiles four representative functions but is not an output/invariant test, so it should not be counted as one.

## Nits (S4)

- `src/compose.jl:40-42,98-101` still equates self-reversing circuits with input/output overlap and says QROM overwrites inputs. The passing q9pi tests disprove that wording. **Bennett-82jc** correctly tracks the misleading terminology; rename it to an input/output-alias restriction.
- `src/bennett_transform.jl:286-288,400-402` still advertises a seven-argument LoweringResult convenience constructor removed under Bennett-8h41; only six/eight/nine argument forms remain.
- `src/Bennett.jl:462-466` claims ordinary function compilation does not use the extraction cache, contradicting lines 371-376 and actual identity hits.

## Coverage log

- Read `CLAUDE.md` in full before any repository investigation.
- Read all scoped source files: gates/LoopGuard/constructor/accessors; default transform, copy/ancilla helpers, self-reversing probes/inference; all six strategy bodies and Knill helpers; dependency graph construction; compose/control remapping and guard handling; every simulator overload, diagnostic replay and decoding; every diagnostic metric/verifier; all of `src/Bennett.jl`; GateGroup/LoweringResult and the rest of `lowering/types.jl`.
- Followed necessary cross-scope threads into `lowering/driver.jl` (group recording, option validation, constant folding), `lowering/arith.jl` (producer tag and QCLA path), `tabulate.jl` (width selection/table semantics), `narrow.jl`, `extract/callees.jl` (cache), `extract/entry.jl` (generic callable signatures), `softfloat_dispatch.jl` (overloads), and `precompile.jl`. No soft-float arithmetic or whole lowering/extraction audit is claimed.
- Read BENCHMARKS.md, the relevant worklog/108 entries, C3's architecture findings and C8's verifier/cleanup lessons. Consulted open-beads.txt and relevant JSONL issue descriptions; no `bd` invocation or issue mutation was performed.
- Executed focused probes with `julia --project --compiled-modules=existing --check-bounds=yes -e '…'` (first load used normal compiled modules). Julia 1.12.3. The report contains exact small reproducers/outputs for every finding; none is reasoning-only. No full `Pkg.test()` run.
- Ran 14 individual test files in two small Julia harnesses (`using Test,Bennett; include(...)`), all with bounds checking, **14,931 assertions passed**: `test_asw2_verify_reversibility` (8), `test_q9pi_compose_controlled_guards` (6,669), `test_eager_bennett` (978), `test_value_eager` (1,558), `test_toffoli_depth` (23), `test_bennett_strategy` (29), `test_pebbling` (310), `test_pebbled_space` (516), `test_pebbled_wire_reuse` (1,048), `test_6azb_input_preservation` (387), `test_egu6_self_reversing_check` (264), `test_rjk7_self_reversing_all_strategies` (3,098), `test_xlsz_kwargs_unified` (23), `test_k0bg_compile_validation` (20). Their green status does not negate the additional failing probes above.
- Verifier-test audit: the asw2/egu6/rjk7/q9pi tests contain actual `@test` / `@test_throws` assertions. The strategy-dispatch parity fixtures, however, fold away their groups despite claiming no fallback; several strategy parity cases only compare two aliases and never check an output. `test_dep_dag` checks RAW/WAW and reciprocal edges but not WAR. Its output-source test repeats the same forward-half arithmetic. `test_toffoli_depth`'s intercut-CNOT fixture specifically avoids transporting a dependency to the next Toffoli. These gaps explain why this review's counterexamples stay green in existing tests.
- Exhaustive independent sweeps: all 256 Int8 inputs for `x+3`, `x*x+3x+1`, a nested two-level diamond, and Kernighan popcount (K=8), with `optimize=false`, folding on/off, and all six strategies. Gate-level Pebbled(8) rejects the polynomial; the successful variants match Julia and their simulator asserts cleanup/preservation. For diamond/loop completion, Pebbled used an explicit sufficient gate budget, exercising its documented Default fallback. Popcount retains one guard across all strategies. The unfolded loop LR has only two recorded groups and `_has_branching==false`, so the explicit loop-guard fallback, not the branching heuristic, is load-bearing.
- Additional all-Int8 matrix for `(x+3)*(x+1)` over ripple/Cuccaro/QCLA and both folding settings under Default/Eager/ValueEager/Checkpoint/PebbledGroup: every completed cell passes output and invariant checks except unfolded QCLA Eager, which fails at the first input (-128). Also verified all-strategy fast-path guard loss and tiny gate-level pebbling identity cases.
- Resource control: the first diamond function used `isodd` under `optimize=false` and expanded to 679,781 forward gates. Its Default/Eager/ValueEager/Checkpoint exhaustive runs passed; the ensuing pebbling DP was stopped by terminating only this review's identified process. Replaced the predicate with an explicit Int8 bit test for the complete bounded matrix. No result is claimed for the interrupted strategy call. Two exploratory scripts had a top-level soft-scope/JSON record-shape harness error; affected probes were rerun successfully and only completed evidence is reported.
- Only this Markdown report was intentionally edited. Other campaign reports and bead-store changes visible in the shared worktree were left untouched. No commit/stash/checkout, full suite, issue-tracker command, or build automation was used.
