# Astra review — B-arith — 2026-09-26
Status: IN PROGRESS
Scope: Arithmetic and memory primitives in src/adder.jl, qcla.jl, multiplier.jl, mul_qcla_tree.jl, partial_products.jl, parallel_adder_tree.jl, divider.jl, qrom.jl, tabulate.jl, softmem.jl, shadow_memory.jl, fast_copy.jl, feistel.jl; strategy dispatch and in-place operand selection.
Method: Read CLAUDE.md in full. Read-only source/test/issue review and targeted Julia probes with bounds checking; no full suite. Only this report is written, per explicit review instructions (overriding routine worklog/beads/session-close mutations).

## Executive summary
Pending completion.

## Findings

### F1 — [S1] QCLA accepts aliased operands and emits irreversible self-CNOTs for ordinary `x + x`
- Where: `src/qcla.jl:44-50,85-86,134-135`; `src/lowering/arith.jl:270-271`.
- Evidence: `julia --project --startup-file=no --compiled-modules=existing --check-bounds=yes -e 'using Bennett; f(x::Int8)=x+x; c=reversible_compile(f,Int8;add=:qcla,optimize=false); println(simulate(c,Int8(2)))'` compiles successfully, then throws `Ancilla wire 12 not zero post-circuit — uncomputation invariant violated`. Inputs 3 and -1 also fail; 0 and 1 happen to pass. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: both SSA operands resolve to the same register. QCLA's propagate initialization emits `CNOT(a[k], b[k])` with identical control and target, erasing input bits. Its later restoration and Bennett reversal cannot undo erasure. The function is valid Julia, and an explicit supported adder must handle it.
- Fix: enforce unique, disjoint operand registers in the QCLA primitive before allocation/emission, and copy one operand in the dispatcher when registers overlap (including partial overlap through aliases), as the Cuccaro path already does.
- Test: exhaust all Int8 inputs of `x+x` under `add=:qcla, optimize=false`, checking output and reversibility; add direct full/partial-overlap and duplicate-wire rejection tests with no partial emission.
- Already tracked? No matching QCLA-alias bead found. `Bennett-stwr` fixed the analogous Cuccaro defect, but its protection is not applied here.

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

### F4 — [S2] Reported multiplier Toffoli-depth ignores CNOT dependencies, invalidating the claimed paper advantage
- Where: `src/diagnostics.jl:131-142`; duplicated metric in `test/test_mul_qcla_tree_paper_match.jl:44-53,89-97` and `test/test_qcla.jl:20-30`.
- Evidence: independent weighted dependency walk updates every touched wire for every gate, adding 1 only for Toffoli. For forward `lower_mul_qcla_tree!`, `(W, reported, dependency-respecting)` is `(4,16,30), (8,20,56), (16,24,88), (32,28,128), (64,32,176), (128,36,232)`. The paper-match test asserts a <0.5 ratio using the same flawed skip-CNOT calculation: at W=32 its own reference formula is 124, so true dependency depth 128 exceeds it, rather than beating it by >2×. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: a Toffoli produces a value that CNOT transfers to a new wire, then another Toffoli consumes it. Skipping CNOT entirely loses the causal edge. A minimal chain is `Toffoli(1,2,3); CNOT(3,4); Toffoli(4,5,6)`: those Toffolis cannot be in the same layer of the emitted circuit.
- Fix: propagate the maximum accumulated Toffoli depth through zero-cost Clifford gates; increment only on Toffoli. Use one production implementation plus an independent explicit-layer oracle in tests. Recompute paper comparisons and T-depth estimates. Keep full gate depth separately.
- Test: pin the three-gate chain at depth 2; pin QCLA-tree weighted depth at W=8/16/32 to 56/88/128 before any scheduling optimization; ensure the paper comparison uses the same dependency definition.
- Already tracked? `Bennett-q22p` tracks a missing Schedule B implementation, but its claim that the measured depth already beats the paper because of wire-granular scheduling is **incorrect**: this metric discards dependencies. No bead found for that root cause. Coordinate with the circuit-metrics reviewer; this cross-scope trace is necessary to assess arithmetic resource claims.

### F5 — [S0] Shadow store silently writes zero when its value aliases the primal register
- Where: `src/shadow_memory.jl:36-56,100-118`.
- Evidence: allocate one-bit `p` and zero `tape`; emit `emit_shadow_store!(g,wa,p,tape,p,1)`, then `emit_shadow_load!(g,wa,p,1)`; wrap with `Bennett.bennett(LoweringResult(g,wire_count(wa),p,out,[1],[1]))`. For input 1: `expected=1 got=0 verify=true`. The guarded variant with a separate constant-one predicate prints exactly the same result. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: storing a register back to itself should preserve its value. Phase 2 clears the primal before phase 3 reads `val`; since `val` is the same register, the old value is already gone. The tape lets the outer reverse restore inputs, so the wrong output survives while all verification invariants pass. Partial overlap/permuted aliases have the same snapshot problem. Neither API documents a disjointness precondition or enforces one.
- Fix: either snapshot any overlapping value bits before clearing primal, or reject overlapping/duplicate wire registers before emission and require caller copy-in. Tape must be disjoint from primal/value; guarded stores must also reject predicate overlap with mutated registers. Exact `val==primal` may be specialized, while respecting the advertised tape postcondition.
- Test: exhaustive one-/two-bit direct and Bennett-wrapped same-register and partial-overlap stores, both predicate values; assert primal, saved tape, value preservation, and final cleanup. Existing lowering resolves ordinary loaded values onto fresh wires, so this finding is established at the direct primitive API boundary, not claimed as a reproduced ordinary Julia memory miscompile.
- Already tracked? No matching shadow-alias bead found.

### F6 — [S0] QROM scratch recycling corrupts a following compact callee; verification still passes
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

### F7 — [S2] The polylogarithmic-depth multiplier serializes the entire y broadcast
- Where: `src/mul_qcla_tree.jl:39-48,66-68`; `test/test_mul_qcla_tree_paper_match.jl:79-86`.
- Evidence: step 2 emits W CNOTs with the same `b[i]` control, giving W sequential gate layers per bit; reversing that step repeats the linear-depth fanout. Full forward primitive depths measured at W=8/16/32/64/128 are 92/146/224/342/532. At W=64, 342 already exceeds the test's claimed 30%-above-paper tolerance: `1.3*(3*6^2+17*6+20) = 299`. Tests stop at W=32. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: selecting this implementation for its advertised polylogarithmic overall circuit depth encounters an Ω(W) fanout bottleneck, independently of the Toffoli-depth metric defect in F4. `emit_fast_copy!` is used for x, but not y. The source paper explicitly broadcasts both inputs in logarithmic depth ([Sun–Borissov, §II.B/III](https://arxiv.org/html/2604.09847v1)); the local TeX source confirms it.
- Fix: use a balanced `emit_fast_copy!` broadcast for each y bit (or broadcast the whole y register then transpose the wire-vector view); reverse exactly that balanced network. Preserve proper disjoint controls for parallel partial products. Decide whether the original bit is included in the copies and adjust counts consistently.
- Test: isolate broadcast depth and require `ceil(log2(W))` (or `ceil(log2(W+1))` if every copy must be fresh); extend full-depth resource probes to W=64/128. Re-run forward ancilla-zero and exhaustive small-width multiplication tests.
- Already tracked? No matching y-broadcast bead found. `Bennett-9wmk` concerns ancilla recycling; `Bennett-q22p` concerns adder scheduling. Neither describes this independent linear-depth bottleneck.

### F8 — [S2] A false guarded packed-memory store clears high bits despite promising identity
- Where: `src/softmem.jl:219-228,234-248,325-352`.
- Evidence: calling guarded stores with `arr=typemax(UInt64), idx=0, val=9, pred=0` gives `0xffff` for 2×8, `0xffffffff` for 4×8, and `0xffffffffffff` for 3×16. The input is `0xffffffffffffffff`. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: for every partially filled UInt64 shape, the implementation extracts/reassembles only N·W bits, so a false predicate still changes the word. The docstrings explicitly promise to return `arr` unchanged and the explanatory comment claims bit-for-bit equivalence to an outer conditional; neither states a zero-high-bits requirement. Full-width shapes and normalized packed inputs are sound.
- Fix: implement false-predicate identity exactly, preserving unused high bits when pred=0; or explicitly narrow the API contract and reject noncanonical high-bit inputs at its checked boundary. If the intended store always preserves the entire containing word, preserve high bits for pred=1 as well.
- Test: for every N·W<64 shape, test pred=0 and pred=2 on inputs with nonzero unused bits, plus predicate high-bit masking. Keep normalized-input tests for all shapes.
- Already tracked? No matching bead found.

### F9 — [S2] Feistel's documented permutation and odd-width mixing are not the implemented algorithm
- Where: `src/feistel.jl:30-31,61-66,76-96,99-108`; `test/test_feistel.jl:14-18,83-105`.
- Evidence: exhaustive forward runs at W=8/9 and rounds=1/4 are bijective and ancilla-clean, but W=8, rounds=1, input `0x12` returns `0x12`. Using the implementation's low-first split L=2,R=1 and AND round function F(1)=0, the documented `(L,R)←(R,L⊻F(R))` requires the returned logical wire order to encode `0x21`. Pointer swaps are performed, but `return out` returns the original order. At W=9, every one of 512 inputs preserves bit 4 (zero-based), for both one and four rounds; that bit is excluded from every round. Separately, the docstring/test commentary says ADD+rotate while the code emits AND+rotate. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: callers trying to reproduce or invert the advertised permutation get a different result, especially at odd round counts. Odd widths permanently isolate the extra bit even though the comment says it mixes in later rounds. The existing “avalanche” test only checks distinct outputs, which every bijection satisfies.
- Fix: define one precise bit-order/round-function contract, return the final logical register order if the Feistel swap is part of it, and either implement an unbalanced Feistel that mixes the extra bit or document/reject odd widths. Remove unsupported PRF/security claims at lines 19-20 and 100; bijectivity alone does not establish them.
- Test: compare every output to an independent classical round oracle for W=2..9, rounds=1..8 and rotations including zero/multiples of half-width; check forward ancilla-zero. Pin the odd-width isolated-bit case if intentionally retained, or require its removal if diffusion is promised.
- Already tracked? No matching circuit-Feistel contract bead found. Closed `Bennett-sqtd` concerns the separate persistent-map `soft_feistel_int8`, not this emitter; the emitter's bijectivity itself is sound.

## Unconfirmed suspicions

## What is sound (brief)
- Independent exhaustive direct-generator sweep passed all 87,380 input pairs per generator across W=1..8 (611,660 generator/input cases total): ripple addition, subtraction, Cuccaro, QCLA, truncating shift-add multiplication, full-width shift-add multiplication, and full-width QCLA-tree multiplication. Checked exact output, preserved inputs (Cuccaro's second operand intentionally overwritten), and reverse recovery. Also checked every non-output ancilla immediately after FORWARD for Cuccaro/QCLA/tree. Odd widths 3,5,7 and degenerate widths 1,2 passed. Ordinary ripple/sub/shift-add deliberately retain intermediates for outer Bennett cleanup and were not falsely required to self-clean.

## Nits (S4)

## Coverage log
- Repository instructions read in full; review beginning.
- Read all arithmetic primitive implementations, QROM, fast copy, shadow memory, Feistel, soft-memory shapes and tabulation; read strategy dispatch and exclusive-reader helpers. Read corresponding small-width test helpers, QCLA/tree resource tests, division exception tests, and BENCHMARKS arithmetic/memory tables.
- Exhaustive probe used 64 independent basis-state lanes packed into UInt64 words; NOT/CNOT/Toffoli were evaluated as bitwise NOT/XOR/AND. Per-lane expected arithmetic was independently assembled from integer inputs; unused lanes masked. No files created by the probe. Julia commands use `--startup-file=no --compiled-modules=existing --check-bounds=yes` to avoid source/cache edits and force bounds checking.
