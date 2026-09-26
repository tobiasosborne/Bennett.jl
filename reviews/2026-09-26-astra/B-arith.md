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

## Unconfirmed suspicions

## What is sound (brief)
- Independent exhaustive direct-generator sweep passed all 87,380 input pairs per generator across W=1..8 (611,660 generator/input cases total): ripple addition, subtraction, Cuccaro, QCLA, truncating shift-add multiplication, full-width shift-add multiplication, and full-width QCLA-tree multiplication. Checked exact output, preserved inputs (Cuccaro's second operand intentionally overwritten), and reverse recovery. Also checked every non-output ancilla immediately after FORWARD for Cuccaro/QCLA/tree. Odd widths 3,5,7 and degenerate widths 1,2 passed. Ordinary ripple/sub/shift-add deliberately retain intermediates for outer Bennett cleanup and were not falsely required to self-clean.

## Nits (S4)

## Coverage log
- Repository instructions read in full; review beginning.
- Read all arithmetic primitive implementations, QROM, fast copy, shadow memory, Feistel, soft-memory shapes and tabulation; read strategy dispatch and exclusive-reader helpers. Read corresponding small-width test helpers, QCLA/tree resource tests, division exception tests, and BENCHMARKS arithmetic/memory tables.
- Exhaustive probe used 64 independent basis-state lanes packed into UInt64 words; NOT/CNOT/Toffoli were evaluated as bitwise NOT/XOR/AND. Per-lane expected arithmetic was independently assembled from integer inputs; unused lanes masked. No files created by the probe. Julia commands use `--startup-file=no --compiled-modules=existing --check-bounds=yes` to avoid source/cache edits and force bounds checking.
