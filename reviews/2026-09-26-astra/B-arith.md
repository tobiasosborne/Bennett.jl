# Astra review — B-arith — 2026-09-26

Status: COMPLETE
Scope: Arithmetic and memory primitives in src/adder.jl, qcla.jl, multiplier.jl, mul_qcla_tree.jl, partial_products.jl, parallel_adder_tree.jl, divider.jl, qrom.jl, tabulate.jl, softmem.jl, shadow_memory.jl, fast_copy.jl, feistel.jl; strategy dispatch and in-place operand selection.
Method: Read CLAUDE.md in full; source/test/issue review, primary-paper checks, exhaustive packed-lane arithmetic probes, scalar forward-state memory probes, and three individual regression files under Julia bounds checking; no full suite. Only this report is written, per explicit review instructions (overriding routine worklog/beads/session-close mutations).

## Executive summary

Complete: 15 findings — 4 S0, 1 S1, 9 S2, 1 S3.
QROM→compact-callee composition, two tabulation errors, and aliased shadow stores produce wrong results while reversibility verification passes.
QCLA still fails on ordinary `x+x`; the recent Cuccaro repair passed all 872 regression assertions.
Arithmetic passed 611,660 direct-generator and 655,360 public-compilation cases, including odd widths, forward cleanup, and signed widening.
Depth/resource claims need correction: CNOT dependencies are dropped, y broadcast is linear-depth, and QROM costs and benchmark tables are misleading.
The report contains executed evidence, concrete fixes, regression suggestions, tracked-issue reconciliation, and coverage limits; no full suite or source edits.

## Findings

### F1 — [S0] QROM scratch recycling corrupts a following compact callee; verification still passes

- Where: `src/qrom.jl:126-129`; `src/lowering/call.jl:103-104,138-139` and offset remapping sites; `src/wire_allocator.jl:18-25`.
- Evidence: executed the following with bounds checks; no manual allocator corruption is involved:
  ```julia
  using Bennett
  using Bennett: WireAllocator, allocate!, wire_count, ReversibleGate,
                 IRCall, ssa, LoweringResult
  callee(x::UInt8) = x + UInt8(1)
  wa = WireAllocator(); idx = allocate!(wa,2); g = ReversibleGate[]
  v = Bennett.emit_qrom!(g,wa,UInt64[5,7,11,13],idx,8)
  vw = Dict(:v => v)
  Bennett.lower_call!(g,wa,vw,IRCall(:r,callee,[ssa(:v)],[8],8); compact=true)
  c = Bennett.bennett(LoweringResult(g,wire_count(wa),idx,vw[:r],[2],[8]))
  println([simulate(c,i) for i in 0:3]); println(verify_reversibility(c))
  # Int8[102, -120, -52, -18]
  # true
  ```
  Expected `[6,8,12,14]`. After QROM: 15 wires, free list `[15,14,13,12]`. After compact inlining: allocator says 52 wires but gates reference wire 56. Noncompact mode has allocator count 44 versus maximum gate wire 48 and raises an ancilla error during simulation. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: `lower_call!` discards the vector returned by `allocate!` and assumes all requested wires were appended after `wire_count(wa)`. QROM legitimately returns clean scratch to the free list, so allocation extends the high-water mark by four fewer wires. Later output-copy allocation overlaps those phantom callee wires; compact mode computes wrong outputs with clean ancillae.
- Fix: remap every callee input/output/gate/loop-guard wire through the actual allocation vector; alternatively provide an explicit contiguous fresh-block allocator and use it here. Add gate wire-range validation as defense in depth; it does not replace correct remapping.
- Test: the exact QROM→callee composition in both compact modes, all indices; then QROM→callee→another allocation and Feistel→callee (the other in-scope freeing primitive). Check numerical outputs as well as reversibility.
- Already tracked? **Bennett-9k7n**, open. The suspected allocation-contiguity root cause is right. This review upgrades its unconfirmed description to an executed silent wrong-result witness, including compact mode; the immediate issue is referencing unallocated future wires, which subsequent allocations turn into live aliases.

### F2 — [S0] Tabulation silently truncates the return value to the first argument's width

- Where: `src/Bennett.jl:357-359,383-385`; `src/tabulate.jl:140-151`.
- Evidence: `f(x::Int8)=Int16(x)*Int16(x); c=reversible_compile(f,Int8;strategy=:tabulate); println((c.output_elem_widths,simulate(c,Int8(20)),verify_reversibility(c)))` prints `([8], -112, true)` although `f(Int8(20)) == 400`. The expression strategy returns 400 with output width `[16]`. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: a small-domain function widens its return type (or has a different-width first argument). Both tabulation branches choose output width from the input type, then `_tabulate_build_table` masks away the actual high result bits. The circuit remains perfectly reversible, so its verifier accepts the wrong oracle.
- Fix: derive return width/type from the actual return contract (inferred return type or extracted IR), validate scalar integer returns consistently, and pass that width to `lower_tabulate`. Preserve the intentional `bit_width` contract separately; do not infer output width from the first argument.
- Test: exhaust Int8→Int16 square and UInt8→UInt16 widening functions under expression/tabulate; include narrower returns, Bool returns, and mixed-width argument tuples. Compare both output shape and bits, then reversibility.
- Already tracked? No matching tabulate return-width bead found; closed `Bennett-b2fs` concerns tuple unpacking/allocation, not this defect.

### F3 — [S0] `:auto` tabulation changes narrow-width arithmetic semantics

- Where: `src/tabulate.jl:88-107,142-151`; `src/Bennett.jl:379-390`; documented per-operation wrap contract in `src/narrow.jl:1-11`.
- Evidence: `f(x::UInt8)=(x*x)>>1;` compile with `bit_width=2` and each strategy. Outputs for inputs 0:3: expression `[0,0,0,0]`; tabulate `[0,0,2,0]`; auto `[0,0,2,0]`. Every circuit returns `true` from `verify_reversibility`. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: at input 2, two-bit multiplication must wrap `2*2` to zero before shifting. Tabulation evaluates the original UInt8 function (4 >> 1 = 2), masking only its final return. The auto heuristic selects that incompatible oracle merely because it sees a multiplication. Signed narrow inputs are also zero-extended to the original Julia type, so their sign interpretation is wrong for narrowed signed comparisons/division.
- Fix: generate the table by interpreting the narrowed IR with exact per-instruction width/sign semantics; alternatively restrict tabulation to full natural widths until such an interpreter exists. Sign-extending arguments alone does not fix overflow-before-shift/comparison.
- Test: differential exhaustive expression/tabulate/auto tests at W=2..7 for multiply-then-shift, overflow-then-compare, signed comparison and signed division. Include the specific UInt8 square/shift witness; require actual outputs and ancilla/input invariants.
- Already tracked? No matching open or closed tabulation-semantics bead found.

### F4 — [S0] Shadow store silently writes zero when its value aliases the primal register

- Where: `src/shadow_memory.jl:36-56,100-118`.
- Evidence: allocate one-bit `p` and zero `tape`; emit `emit_shadow_store!(g,wa,p,tape,p,1)`, then `emit_shadow_load!(g,wa,p,1)`; wrap with `Bennett.bennett(LoweringResult(g,wire_count(wa),p,out,[1],[1]))`. For input 1: `expected=1 got=0 verify=true`. The guarded variant with a separate constant-one predicate prints exactly the same result. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: storing a register back to itself should preserve its value. Phase 2 clears the primal before phase 3 reads `val`; since `val` is the same register, the old value is already gone. The tape lets the outer reverse restore inputs, so the wrong output survives while all verification invariants pass. Partial overlap/permuted aliases have the same snapshot problem. Neither API documents a disjointness precondition or enforces one.
- Fix: either snapshot any overlapping value bits before clearing primal, or reject overlapping/duplicate wire registers before emission and require caller copy-in. Tape must be disjoint from primal/value; guarded stores must also reject predicate overlap with mutated registers. Exact `val==primal` may be specialized, while respecting the advertised tape postcondition.
- Test: exhaustive one-/two-bit direct and Bennett-wrapped same-register and partial-overlap stores, both predicate values; assert primal, saved tape, value preservation, and final cleanup. Existing lowering resolves ordinary loaded values onto fresh wires, so this finding is established at the direct primitive API boundary, not claimed as a reproduced ordinary Julia memory miscompile.
- Already tracked? No matching shadow-alias bead found.

### F5 — [S1] QCLA accepts aliased operands and emits irreversible self-CNOTs for ordinary `x + x`

- Where: `src/qcla.jl:44-50,85-86,134-135`; `src/lowering/arith.jl:270-271`.
- Evidence: `julia --project --startup-file=no --compiled-modules=existing --check-bounds=yes -e 'using Bennett; f(x::Int8)=x+x; c=reversible_compile(f,Int8;add=:qcla,optimize=false); println(simulate(c,Int8(2)))'` compiles successfully, then throws `Ancilla wire 12 not zero post-circuit — uncomputation invariant violated`. Inputs 3 and -1 also fail; 0 and 1 happen to pass. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: both SSA operands resolve to the same register. QCLA's propagate initialization emits `CNOT(a[k], b[k])` with identical control and target, erasing input bits. Its later restoration and Bennett reversal cannot undo erasure. The function is valid Julia, and an explicit supported adder must handle it.
- Fix: enforce unique, disjoint operand registers in the QCLA primitive before allocation/emission, and copy one operand in the dispatcher when registers overlap (including partial overlap through aliases), as the Cuccaro path already does.
- Test: exhaust all Int8 inputs of `x+x` under `add=:qcla, optimize=false`, checking output and reversibility; add direct full/partial-overlap and duplicate-wire rejection tests with no partial emission.
- Already tracked? No matching QCLA-alias bead found. `Bennett-stwr` fixed the analogous Cuccaro defect, but its protection is not applied here.

### F6 — [S2] Reported multiplier Toffoli-depth ignores CNOT dependencies, invalidating the claimed paper advantage

- Where: `src/diagnostics.jl:131-142`; duplicated metric in `test/test_mul_qcla_tree_paper_match.jl:44-53,89-97` and `test/test_qcla.jl:20-30`.
- Evidence: independent weighted dependency walk updates every touched wire for every gate, adding 1 only for Toffoli. For forward `lower_mul_qcla_tree!`, `(W, reported, dependency-respecting)` is `(4,16,30), (8,20,56), (16,24,88), (32,28,128), (64,32,176), (128,36,232)`. The paper-match test asserts a <0.5 ratio using the same flawed skip-CNOT calculation: at W=32 its own reference formula is 124, so true dependency depth 128 exceeds it, rather than beating it by >2×. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: a Toffoli produces a value that CNOT transfers to a new wire, then another Toffoli consumes it. Skipping CNOT entirely loses the causal edge. A minimal chain is `Toffoli(1,2,3); CNOT(3,4); Toffoli(4,5,6)`: those Toffolis cannot be in the same layer of the emitted circuit.
- Fix: propagate the maximum accumulated Toffoli depth through zero-cost Clifford gates; increment only on Toffoli. Use one production implementation plus an independent explicit-layer oracle in tests. Recompute paper comparisons and T-depth estimates. Keep full gate depth separately.
- Test: pin the three-gate chain at depth 2; pin QCLA-tree weighted depth at W=8/16/32 to 56/88/128 before any scheduling optimization; ensure the paper comparison uses the same dependency definition.
- Already tracked? `Bennett-q22p` tracks a missing Schedule B implementation, but its claim that the measured depth already beats the paper because of wire-granular scheduling is **incorrect**: this metric discards dependencies. No bead found for that root cause. Coordinate with the circuit-metrics reviewer; this cross-scope trace is necessary to assess arithmetic resource claims.

### F7 — [S2] The polylogarithmic-depth multiplier serializes the entire y broadcast

- Where: `src/mul_qcla_tree.jl:39-48,66-68`; `test/test_mul_qcla_tree_paper_match.jl:79-86`.
- Evidence: step 2 emits W CNOTs with the same `b[i]` control, giving W sequential gate layers per bit; reversing that step repeats the linear-depth fanout. Full forward primitive depths measured at W=8/16/32/64/128 are 92/146/224/342/532. At W=64, 342 already exceeds the test's claimed 30%-above-paper tolerance: `1.3*(3*6^2+17*6+20) = 299`. Tests stop at W=32. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: selecting this implementation for its advertised polylogarithmic overall circuit depth encounters an Ω(W) fanout bottleneck, independently of the Toffoli-depth metric defect in F6. `emit_fast_copy!` is used for x, but not y. The source paper explicitly broadcasts both inputs in logarithmic depth ([Sun–Borissov, §II.B/III](https://arxiv.org/html/2604.09847v1)); the local TeX source confirms it.
- Fix: use a balanced `emit_fast_copy!` broadcast for each y bit (or broadcast the whole y register then transpose the wire-vector view); reverse exactly that balanced network. Preserve proper disjoint controls for parallel partial products. Decide whether the original bit is included in the copies and adjust counts consistently.
- Test: isolate broadcast depth and require `ceil(log2(W))` (or `ceil(log2(W+1))` if every copy must be fresh); extend full-depth resource probes to W=64/128. Re-run forward ancilla-zero and exhaustive small-width multiplication tests.
- Already tracked? No matching y-broadcast bead found. `Bennett-9wmk` concerns ancilla recycling; `Bennett-q22p` concerns adder scheduling. Neither describes this independent linear-depth bottleneck.

### F8 — [S2] Explicit arithmetic strategies are silently discarded at callee and loop boundaries

- Where: `src/lowering/call.jl:98`; `src/lowering/cfg.jl:429,557`; `src/lowering/types.jl` call dispatch.
- Evidence: a one-block ParsedIR containing `IRCall(:r,cf,[ssa(:x),ssa(:y)],[8,8],8)`, `cf(x::UInt8,y::UInt8)=x+y`, compiles to exactly `(total=116, NOT=4, CNOT=86, Toffoli=26)` for each `add=:ripple/:cuccaro/:qcla` with outer `fold_constants=false`. A raw LLVM i8 loop with `acc=phi(0,s); s=acc+x; i=phi(0,next); next=i+1; repeat while next<3`, lowered with `max_loop_iterations=4,fold_constants=false`, produces byte-identical gate streams under all three add strategies: total=1845, Toffoli=568, input 7→21, verification true. Callee `lower(callee_parsed;max_loop_iterations=64)` receives none of the caller's options, and loop contexts explicitly pass `:ripple`. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: a caller requests QCLA or Cuccaro, but expensive division/soft-float/memory kernels use default add/mul lowering, and explicit loop additions use ripple. This defeats strategy selection and resource planning, without an error or diagnostic. Callee defaults also ignore the caller's constant-folding request.
- Fix: thread a validated options object through callee and loop lowering; keep in-place eligibility empty inside repeated loop bodies while honoring the adder family via Cuccaro copy-in. If any combination is deliberately unsupported, reject it explicitly. Investigate and document changed explicit-strategy counts for affected compositions.
- Test: registered-call and loop witnesses with demonstrably different primitive gate counts for each explicit family, plus numerical output and cleanup tests; include nested callees and target=:depth multiplication.
- Already tracked? **Bennett-0a6f** (callees) and **Bennett-vpgj** (loops), both open. Their descriptions are correct. `Bennett-4iuj` separately tracks the documented target=:depth omission for auto-add selection; that is a design limitation, not needed to prove this explicit-strategy bug.

### F9 — [S2] Feistel's documented permutation and odd-width mixing are not the implemented algorithm

- Where: `src/feistel.jl:30-31,61-66,76-96,99-108`; `test/test_feistel.jl:14-18,83-105`.
- Evidence: exhaustive forward runs at W=8/9 and rounds=1/4 are bijective and ancilla-clean, but W=8, rounds=1, input `0x12` returns `0x12`. Using the implementation's low-first split L=2,R=1 and AND round function F(1)=0, the documented `(L,R)←(R,L⊻F(R))` requires the returned logical wire order to encode `0x21`. Pointer swaps are performed, but `return out` returns the original order. At W=9, every one of 512 inputs preserves bit 4 (zero-based), for both one and four rounds; that bit is excluded from every round. Separately, the docstring/test commentary says ADD+rotate while the code emits AND+rotate. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: callers trying to reproduce or invert the advertised permutation get a different result, especially at odd round counts. Odd widths permanently isolate the extra bit even though the comment says it mixes in later rounds. The existing “avalanche” test only checks distinct outputs, which every bijection satisfies.
- Fix: define one precise bit-order/round-function contract, return the final logical register order if the Feistel swap is part of it, and either implement an unbalanced Feistel that mixes the extra bit or document/reject odd widths. Remove unsupported PRF/security claims at lines 19-20 and 100; bijectivity alone does not establish them.
- Test: compare every output to an independent classical round oracle for W=2..9, rounds=1..8 and rotations including zero/multiples of half-width; check forward ancilla-zero. Pin the odd-width isolated-bit case if intentionally retained, or require its removal if diffusion is promised.
- Already tracked? No matching circuit-Feistel contract bead found. Closed `Bennett-sqtd` concerns the separate persistent-map `soft_feistel_int8`, not this emitter; the emitter's bijectivity itself is sound.

### F10 — [S2] A false guarded packed-memory store clears high bits despite promising identity

- Where: `src/softmem.jl:219-228,234-248,325-352`.
- Evidence: calling guarded stores with `arr=typemax(UInt64), idx=0, val=9, pred=0` gives `0xffff` for 2×8, `0xffffffff` for 4×8, and `0xffffffffffff` for 3×16. The input is `0xffffffffffffffff`. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: for every partially filled UInt64 shape, the implementation extracts/reassembles only N·W bits, so a false predicate still changes the word. The docstrings explicitly promise to return `arr` unchanged and the explanatory comment claims bit-for-bit equivalence to an outer conditional; neither states a zero-high-bits requirement. Full-width shapes and normalized packed inputs are sound.
- Fix: implement false-predicate identity exactly, preserving unused high bits when pred=0; or explicitly narrow the API contract and reject noncanonical high-bit inputs at its checked boundary. If the intended store always preserves the entire containing word, preserve high bits for pred=1 as well.
- Test: for every N·W<64 shape, test pred=0 and pred=2 on inputs with nonzero unused bits, plus predicate high-bit masking. Keep normalized-input tests for all shapes.
- Already tracked? No matching bead found.

### F11 — [S2] QROM advertises literature T/ancilla costs that its emitted circuit does not have

- Where: `src/qrom.jl:8,26-28,78-80,109-115`; `BENCHMARKS.md:56-69`; `src/diagnostics.jl:115-122`.
- Evidence: direct raw QROM at `(L,W)=(16,8)` emits 30 Toffolis, reports `t_count=210`, and allocates 9 scratch wires; its header promises `4(L-1)=60` T gates and `log2(L)=4` scratch wires. Outer Bennett produces 60 Toffolis / 420 T gates. At L=2 and 4, raw `(T-count,scratch)` is `(14,3)` and `(42,5)`. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: the benchmark calls its post-Bennett `4(L-1)` **Toffoli** count a match to a paper bound that is a **T-gate** count. The implementation emits ordinary Toffoli compute/uncompute pairs, and its T metric charges 7 per gate; it has no measurement-based AND-uncompute representation. Scratch is `2*log2(L)+1` for L>1 because both child flags stay live at every depth plus a root. [Babbush–Gidney et al., §III.A/III.C](https://arxiv.org/html/1805.03662v2#S3.SS3) use a different fault-tolerant cost model/construction to obtain 4L−4 T gates and logarithmic scratch.
- Fix: document actual emitted Toffoli/CNOT/wire counts separately from the hypothetical specialized Clifford+T implementation. Remove “matches paper bound” until the lowering/decomposition actually supports that resource model; correct the exact scratch formula. If specialized AND uncompute is implemented later, model its phase/measurement requirements explicitly.
- Test: pin raw and wrapped counts independently for L=1/2/4/16, varying W to retain the valid W-independence claim; assert `t_count` agrees with the stated decomposition, and compute scratch from the input/output partition.
- Already tracked? `Bennett-p4ch` discusses future QROAM and knows the current `2(L-1)` Toffoli construction, but does not fix the existing false T-count/ancilla comparison. No dedicated matching bead found.

### F12 — [S2] BENCHMARKS arithmetic baselines are stale and mix old defaults with current strategy claims

- Where: `BENCHMARKS.md:9-18,248`; `test/test_gate_count_regression.jl:18-66`.
- Evidence: current explicit ripple `x+1` at Int8/16/32/64 yields total 58/114/226/450 and Toffoli 12/28/60/124, with successful verification. BENCHMARKS lists 100/204/412/828 and 28/60/124/252 in the unqualified rows. Explicit Cuccaro now yields totals 98/202/410/826 and Toffoli 26/58/122/250, while the document still lists pre-optimization Cuccaro totals/counts. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: readers use the claimed canonical benchmark table to compare strategies/papers and get the wrong current defaults and outdated explicit-strategy costs. The local regression test is correct; the document is not.
- Fix: regenerate these rows with explicit `add`, `mul`, `fold_constants`, and extraction options recorded; distinguish default selection from primitive forward and post-Bennett comparisons. Refresh the summary comparison at line 248 as well.
- Test: locally validate generated table entries against the existing explicit-strategy regression baselines; retain total doubling `2*prev-2` and Toffoli doubling `2*prev+4` (both reproduced).
- Already tracked? **Bennett-t3ou**, open, correctly flags stale Cuccaro rows. Its description is too narrow: the unqualified addition rows also describe the retired default. No source/test baseline should be changed merely to match this stale document.

### F13 — [S2] The tabulate shortcut bypasses validation of arithmetic strategies and target

- Where: `src/Bennett.jl:343-361,381-386`; validation deferred to `src/lowering/driver.jl:115-142`.
- Evidence: `reversible_compile(x->x+Int8(1),Int8;strategy=:tabulate,add=:nonsense)` succeeds and simulates 3→4. So do `mul=:karatsuba` and `target=:nonsense`. The same three calls under `strategy=:expression` throw the proper `ArgumentError`, including the Karatsuba-removal message. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: API validity depends on which implementation/cost-model branch wins, so misspelled/retired options are silently accepted. Auto-tabulation has the same return-before-validation structure.
- Fix: validate the shared option set before either tabulate short circuit, even when some supported options have no effect on table generation. Centralize validation rather than copying the lowerer's enum lists.
- Test: invalid add/mul/target values under expression, explicit tabulate, and auto-at-small-width; require consistent failures. Pin retired Karatsuba rejection across all paths.
- Already tracked? No matching tabulate-validation bead found; the Karatsuba-removal decision is recorded in closed `Bennett-tbm6`.

### F14 — [S2] QROM's non-power-of-two validation throws an unrelated floating-conversion error

- Where: `src/qrom.jl:47-48`.
- Evidence: with an ordinary allocator, `emit_qrom!(g,wa,UInt64[1,2,3],idx,8)` prints `InexactError: Int64(1.584962500721156)` and emits zero gates. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: the code converts log2(L) to an exact integer before checking whether L is a power of two, so the intended descriptive `ArgumentError` is unreachable for L=3/5/6/etc. This is an invalid-input diagnostic defect, not data corruption.
- Fix: check `ispow2(L)` first, then use integer `trailing_zeros(L)` or `ilog2` to derive n; keep L≥1 validation before it.
- Test: L=0/3/5/6 must fail with the descriptive ArgumentError before any gates or wires are allocated; L=1/2/4 and normal dispatch padding must continue working.
- Already tracked? No matching bead found.

### F15 — [S3] Adder-tree replay documentation proves a different schedule and exposes an unused reuse-pool option

- Where: `src/parallel_adder_tree.jl:21-47,60-62,138-157`.
- Evidence: the docstring says non-root levels D−1…1 are reversed and the root contributes forward gates only; the code copies the root then replays **every** level D…1. `reuse_pool` is accepted but never read after the signature. Executed W=2 and W=4 with 50 preallocated zero pool wires: `used_pool=false` in both emitted streams. Independent tree forward-clean checks pass, including every arbitrary row assignment through W=4; this is not a cleanup defect. Verified: VERIFIED-BY-EXECUTION for pool nonuse; the schedule discrepancy is an exact source trace.
- Failure scenario: a maintainer following the purported proof/cost formula would remove required root-pad cleanup or underestimate gates. A caller supplying a recycling pool gets no wire-budget benefit and no indication that the option is inert.
- Fix: rewrite the proof and cost statement around copy-root + reverse-all (including pad cleanup), and either remove the unused keyword or implement its ownership/lifetime contract before advertising it. Do not change the working replay order merely to match stale prose.
- Test: a one-level W=2 tree must clean its root pads after forward execution; if pooling is implemented, assert supplied pool wires are actually used and remain zero outside their lifetimes, with output/source wire exclusion.
- Already tracked? `Bennett-q22p` correctly calls the implementation copy-root + uncompute-all, unlike this docstring; `Bennett-9wmk` tracks future recycling. Closed `Bennett-d1ee` claimed to document the invariant, but the current proof/cost text is stale.

## Unconfirmed suspicions

- No additional suspected numerical bug is promoted to a finding. An exploratory narrow tuple-return probe failed in both expression and table paths (different errors), so it does not establish that the auto-table choice alone rejects an otherwise supported narrow tuple program. Broad tuple/narrowing support is outside this scope; the confirmed scalar table errors are F2/F3.
- No end-to-end Julia shadow-store alias miscompile was reproduced: ordinary loads copy into fresh registers. F4 is deliberately scoped to the direct generator API. Likewise, F1 uses legitimate primitive composition and `lower_call!`; it does not depend on an unverified assumption that a particular Julia optimizer preserves a QROM followed by a call.

## What is sound (brief)

- Independent exhaustive direct-generator sweep with separate operand registers passed all 87,380 input pairs per generator across W=1..8 (611,660 generator/input cases total): ripple addition, subtraction, Cuccaro, QCLA, truncating shift-add multiplication, full-width shift-add multiplication, and full-width QCLA-tree multiplication. Checked exact output, preserved inputs (Cuccaro's second operand intentionally overwritten), and reverse recovery. Also checked every non-output ancilla immediately after FORWARD for Cuccaro/QCLA/tree. Odd widths 3,5,7 and degenerate widths 1,2 passed. Ordinary ripple/sub/shift-add deliberately retain intermediates for outer Bennett cleanup and were not falsely required to self-clean.
- Public compilation passed all 65,536 Int8 input pairs for `x*y+x+y` under every 3×2 add/mul strategy combination (`optimize=false`), checking result, input preservation and all ancillae. Both multiplication families also passed every Int8→Int16 and UInt8→UInt16 widening-product pair, including signed high bits (655,360 public-pipeline cases total).
- `test/test_stwr_cuccaro_soundness.jl`: 872/872 assertions passed in 76.4 s, including exclusive op2 overwrite, op1 swap, copy-in, repeated operands, sibling branches, phi aliases, loops, six Bennett strategies, and soft-float witnesses. The inspected stwr analysis counts operand occurrences (including terminators), excludes phi definitions, suppresses in-place targets inside loops, and checks live wire aliases. The old c2 A1/A2 findings are fixed; do not revert to last-use analysis.
- QROM passed every address at L=1,2,4,…,256 for W=1,7,8,33,64 (seeded random tables): exact data, input preservation, and all scratch zero after forward execution. Freeing its child flags is locally correct; F1 is in the consumer's allocation assumption. Fast-copy passed every input at W=1..8, n_copies=1..10, including inverse cleanup. Broadcast copies are outputs, so they should not be zero after forward execution.
- All eleven soft-memory shapes passed every valid index on 1,000 seeded normalized packed words each, with full-width values and predicates 0/1/2/typemax. Both unsigned division kernels passed all 65,280 UInt8 pairs with nonzero divisor and 200,000 seeded UInt64 pairs. `test/test_division.jl` passed 4,819 assertions; `test/test_salb_div_by_zero.jl` passed 146 assertions. No nonzero-divisor arithmetic defect was found.
- Feistel forward bijectivity, input preservation and scratch cleanup passed every input at W=2..10, rounds=1..5. This confirms bijectivity, not the documented permutation/diffusion/security claims (F9).
- Standalone adder-tree verification also passed arbitrary independently varying partial-product rows (not merely the correlated rows of a multiplication): every bit assignment at W=1..4, plus 1,000 seeded arbitrary row sets per W=5..8. Results matched `sum(pp[i] << (i-1))`; every source register survived and every scratch wire was zero after forward execution.

## Nits (S4)

- `test/test_qcla.jl`'s “ancillae zero after forward pass” testset actually tests forward followed by inverse. Other testsets do check forward cleanup correctly, so this is a misleading local test name, not a missing overall proof. Rename it or inspect forward scratch before reversal.
- Multiplier resource helpers subtract `3W` from the total wire count even though there are `2W` input and `2W` output wires. Standardize whether “ancilla” means scratch excluding outputs (`n_wires-4W`) or all non-input wires (`n_wires-2W`, as some papers count them); `n_wires-3W` fits neither. E.g. at W=8, physical scratch is 463 while the test labels 471 as ancilla.
- Minor stale references: `mul_qcla_tree.jl:7` calls self-cleanup CLAUDE principle 13 (it is principle 4); `lowering/arith.jl:41` dates Sun–Borissov to 2023 instead of 2026; tabulate unpacking comments discuss 24-bit/16-million tables despite the current 16-bit cap.

## Coverage log

- Repository instructions read in full. Review completed without source modifications.
- Read all arithmetic primitive implementations, QROM, fast copy, shadow memory, Feistel, soft-memory shapes and tabulation; read strategy dispatch and exclusive-reader helpers. Read corresponding small-width test helpers, QCLA/tree resource tests, division exception tests, and BENCHMARKS arithmetic/memory tables.
- Exhaustive probe used 64 independent basis-state lanes packed into UInt64 words; NOT/CNOT/Toffoli were evaluated as bitwise NOT/XOR/AND. Per-lane expected arithmetic was independently assembled from integer inputs; unused lanes masked. No files created by the probe. Julia commands use `--startup-file=no --compiled-modules=existing --check-bounds=yes` to avoid source/cache edits and force bounds checking.
- Read `docs/design/rearch-2026-08/c2-lowering.md` arithmetic/dispatch findings, the relevant worklog/108 session notes, BENCHMARKS arithmetic/memory and comparison rows, and relevant entries in the read-only issue export/open-beads snapshot. Looked up primary Sun–Borissov and Babbush–Gidney papers; read Sun–Borissov's local TeX through `tar -xOf` without extracting/writing files.
- Division exceptional inputs: public `soft_udiv`/`soft_urem` throw; compiled UInt8 `7÷0` returns 255 and verifies, compiled remainder by zero returns the dividend, and signed `typemin(Int8)÷-1` wraps. This is the explicitly documented **Bennett-salb** totalization, not a newly discovered kernel defect. It does not preserve Julia exception semantics, and successful reversibility verification says nothing about that semantic gap. The tests intentionally pin the deviation. No new issue claimed for a behavior the existing contract explicitly excludes.
- Out-of-range soft-memory indices remain unchecked preconditions: e.g. 4×8 packed `0x44332211`, idx=99 loads 0x44 and a store is a no-op on normalized data. These APIs document valid indices only; no claim of valid-index corruption. Shapes exceeding 64 packed bits are not generated; the separate lowering uses other memory strategies. Full >64-bit memory lowering is outside this primitive review.
- Karatsuba is absent by explicit design (closed Bennett-tbm6); there is no odd-split implementation to audit. Expression-path rejection is correct; F13 covers the shortcut inconsistency. No independent divergent implementation of signed/unsigned multiplication was found: public widening uses extension followed by modular multiplication, which passed the exhaustive high-bit checks.
- The remaining arithmetic-lowering carry patterns (`lower_sub!`, unsigned comparison carry-out, conditional negation) were traced: their different output/carry contracts are intentional, not evidence by themselves of divergent duplicate lowering. The real dispatch duplication defects are F8. Read driver strategy validation/selection, operand targeting, and gate folding; the general CFG/phi, full memory dispatcher, simulator/verifier, and Bennett scheduling algorithms remain primarily other reviewers' scope.
- Cross-scope overlap: `B-circuit-core.md` F16 independently reports the metric defect; this report adds the arithmetic/paper-match consequences and measured multiplier depths in F6. Source files were not edited. No `bd`, git mutation, full suite, or remote automation was run.
