# Astra review — B-lowering — 2026-09-26
Status: IN PROGRESS
Scope: `src/lower.jl`, `src/lowering/*.jl`, `src/narrow.jl`, `src/wire_allocator.jl`; contextual IR, gates, simulation and diagnostics code.
Method: Read-only source audit and focused Julia probes with bounds checking. Only this report is intentionally written; no issue-tracker operations, full test suite, or repository mutations.

Continuation audit: the previous report is preserved below while its S0/S1 claims are independently re-executed. Any refuted claim will be explicitly superseded; continuation measurements and coverage will be recorded here before completion.

## Executive summary

Pending completion.

## Findings

### F1 — [S0] Stores through a selected pointer ignore the store block's predicate
- Where: `src/lowering/memory.jl:615–648`, especially 624–625, 632–633 and 647–648; guard override at 878–884 and 1051–1064.
- Evidence: VERIFIED-BY-EXECUTION. A one-input ParsedIR initializes two i8 allocas to 11 and 22, selects pointer `p = (x & 1) != 0 ? a : b` in the entry block, conditionally executes `store 9, p` only when `(x & 2) != 0`, then returns `load a`. Exhaustive Int8 simulation gives **64/256 wrong**, e.g. `x=-127 → 9`, expected 11; `verify_reversibility(c) == true`. Executed with `--check-bounds=yes`, default folding. The multi-origin loop passes only `o.predicate_wire`, completely discarding `block_label`. This affects static shadow, dynamic shadow-checkpoint, and generated MUX-EXCH branches by the same code path.
- Failure scenario: pointer selection is true while the later store's branch is false; a store that source execution skips still changes memory. This is the named false-path-sensitization failure, now in memory predication rather than scalar PHIs.
- Frontend confirmation: independently expressed the fixture in LLVM text, parsed it in memory, ran `LLVM.verify(module)` successfully, and passed it through `_module_to_parsed_ir` and `reversible_compile`. The same **64/256** mismatches and passing reversibility check result. No temporary source file was written.
- Fix: combine the origin predicate with the current store block predicate before every multi-origin dispatch. Pass that conjunction as the external predicate; keep entry-block fast paths only when the block predicate is provably true.
- Test: the fixture below over all 256 Int8 inputs, with folding on/off; repeat with dynamic indices for both MUX-EXCH and shadow-checkpoint shapes, and pointer PHIs as well as selects. Assert output and ancilla/input invariants.
- Already tracked? no matching open bead found.

```julia
using Bennett
using Bennett: IRInst, IRBasicBlock, IRBinOp, IRICmp, IRSelect, IRBranch,
    IRRet, IRAlloca, IRStore, IRLoad, ParsedIR, ssa, iconst
entry = IRInst[
    IRAlloca(:a,8,iconst(1)), IRAlloca(:b,8,iconst(1)),
    IRStore(ssa(:a),iconst(11),8), IRStore(ssa(:b),iconst(22),8),
    IRBinOp(:m1,:and,ssa(:x),iconst(1),8),
    IRICmp(:c,:ne,ssa(:m1),iconst(0),8),
    IRBinOp(:m2,:and,ssa(:x),iconst(2),8),
    IRICmp(:d,:ne,ssa(:m2),iconst(0),8),
    IRSelect(:p,ssa(:c),ssa(:a),ssa(:b),0)]
p = ParsedIR(8,[(:x,8)],[
    IRBasicBlock(:entry,entry,IRBranch(ssa(:d),:write,:exit)),
    IRBasicBlock(:write,IRInst[IRStore(ssa(:p),iconst(9),8)],
        IRBranch(nothing,:exit,nothing)),
    IRBasicBlock(:exit,IRInst[IRLoad(:r,ssa(:a),8)],IRRet(ssa(:r),8))],[8])
c = reversible_compile(p)
println(count(x -> simulate(c,x) != ((x & 3)==3 ? 9 : 11),
              typemin(Int8):typemax(Int8))) # 64
println(verify_reversibility(c))           # true
```

### F2 — [S0] A zero-offset GEP after a dynamic GEP silently loads stale memory
- Where: `src/lowering/aggregate.jl:235`, `260`, `275–277`, `340–354`, `398–410`.
- Evidence: VERIFIED-BY-EXECUTION. The following valid pointer sequence returns **0 instead of 42 for all 256 Int8 inputs**, with both `fold_constants=false` and `true`; `verify_reversibility == true` in both configurations. `IRVarGEP` creates a value snapshot and provenance. `IRPtrOffset` aliases the snapshot, then silently skips the dynamic origin (`o.idx_op isa ConstOperand || continue`). The load falls back to `_lower_load_legacy!` and copies the pre-store snapshot.
- Failure scenario: `p = &a[x & 3]; q = p + 0; *p = 42; return *q` on a four-byte local array. Every address is in bounds. A zero offset must preserve pointer identity and must not freeze the pointee value.
- Frontend confirmation: LLVM-verified `alloca i8,i32 4; gep i8 a,(x&3); gep i8 p,0; store 42,p; load q` also extracts and compiles, with **256/256** mismatches and passing reversibility. This is valid LLVM pointer arithmetic, not only a hand-built ParsedIR edge case.
- A second VERIFIED-BY-EXECUTION form exists in the persistent path: `IRVarGEP(:p1,ssa(:a),iconst(1),8)` followed by `IRPtrOffset(:q,ssa(:p1),0,8)` resets the origin index to zero at `aggregate.jl:219`. With initialized slots 11 and 22, `load q` returns **11 instead of 22**, and reversibility passes. This uses only two stores and is independent of F15's capacity failure.
- Fix: represent every GEP as provenance plus composed index/offset, resolving memory at load time. At minimum propagate a dynamic origin unchanged for offset zero, add constant offsets to dynamic indices, and reject unsupported compositions instead of dropping provenance. The dynamic-GEP-on-GEP path also needs provenance propagation, not just `haskey(alloca_info, base)`.
- Test: sweep all 256 inputs on zero/nonzero constant GEP after variable GEP, chained variable GEPs, and stores before/after pointer construction; compare with direct pointer use and verify ancilla/input restoration.
- Already tracked? no matching open bead found (the existing GEP extraction/scale issues concern different code).

```julia
using Bennett: IRVarGEP, IRPtrOffset
insts = IRInst[IRAlloca(:a,8,iconst(4)),
    IRBinOp(:i,:and,ssa(:x),iconst(3),8),
    IRVarGEP(:p,ssa(:a),ssa(:i),8), IRPtrOffset(:q,ssa(:p),0,8),
    IRStore(ssa(:p),iconst(42),8), IRLoad(:r,ssa(:q),8)]
p = ParsedIR(8,[(:x,8)],
    [IRBasicBlock(:entry,insts,IRRet(ssa(:r),8))],[8])
for fold in (false,true)
    c = reversible_compile(p;fold_constants=fold)
    println((fold, count(x->simulate(c,x)!=42, typemin(Int8):typemax(Int8)),
             simulate(c,Int8(0)), verify_reversibility(c)))
end
# (false, 256, 0, true)
# (true, 256, 0, true)
```

### F3 — [S0] Width narrowing preserves old-width shift guards and silently changes results
- Where: `src/narrow.jl:28–36`; `src/lowering/arith.jl:249–261`, `362–364`, `409–460`.
- Evidence: VERIFIED-BY-EXECUTION. Compile `f(x::Int8)=Int8(1)<<x` with `bit_width=4, strategy=:expression`. At `optimize=false`, inputs `0,1,2,3` all produce **0**, expected `1,2,4,8`. At `optimize=true`, input `4` produces **1**, expected **0** in four-bit arithmetic. Both circuits pass `verify_reversibility`. Full domains `0:7` (W=3) and `0:15` (W=4) were checked. Also, `g(x::Int8)=x>>1` with W=3 or 4 and `optimize=false` fails compilation: `constant shift k=7 out of [0, W]`. The narrowing pass rewrites operand widths but leaves old-width constants, comparison guards, and sign-bit shift positions unchanged; the barrel shifter then ignores high shift bits.
- Failure scenario: a documented narrow-width compile of a basic shift depends on extraction optimization and may be wrong even at shift amount zero. This is not LLVM poison: the original Julia function and its guarded shifts are defined.
- Stronger check: even `bit_width=8` on this **Int8** function changes `f(Int8(1))` from **2 to 0** at `optimize=false`. Inspection of the extracted IR shows the Int64 conversion checks against `typemin(Int64)`/`typemax(Int64)` are also narrowed; those constants become 0/−1, making a valid conversion fail its synthesized guard. `bit_width=8,optimize=true` returns 2. Width-dependent guards and promoted conversion checks both require attention.
- Fix: perform narrowing with width-aware semantics before source-width guards are baked in, or explicitly recognize/rewrite the complete shift idiom (bounds, negative amounts, sign extraction, and saturation). Until supported, reject these patterns rather than claim arbitrary W-bit semantics. Preserve i1 controls separately.
- Test: exhaustive narrow input × shift-amount domains for W=1,2,3,4,6,8, both optimization modes, all three shifts, negative amounts, amounts W−1/W/W+1 and source-width limits. Include `1 << 0`, whose expected result is unambiguous.
- Already tracked? no matching open bead found; `Bennett-g7d6` tracks discarded metadata, not these arithmetic miscompiles.

```julia
f(x::Int8) = Int8(1) << x
for opt in (false,true)
    c = reversible_compile(f,Int8;bit_width=4,optimize=opt,strategy=:expression)
    println((opt,[simulate(c,Int8(x)) for x in 0:4],verify_reversibility(c)))
end
# (false, [0, 0, 0, 0, 0], true)
# (true,  [1, 2, 4, 8, 1], true)
```

### F4 — [S1] MUX-EXCH rejects a valid negative integer constant store
- Where: `src/lowering/memory.jl:1049`, `1151–1155`.
- Evidence: VERIFIED-BY-EXECUTION. In the F2 fixture replace the store value by `iconst(-1)` and load directly from `p` (omit `q`). `reversible_compile` throws `InexactError: convert(UInt64, -1)`. The static-index shadow path uses `resolve!` and handles the same bit pattern. `_operand_to_u64!` uses checked `UInt64(op.value)` rather than bit reinterpretation/modular conversion.
- Failure scenario: storing an ordinary signed i8 constant such as −1 through an in-bounds dynamic pointer fails compilation for an otherwise supported alloca shape.
- Fix: use a bit-pattern-preserving conversion, consistent with `resolve!(::ConstOperand)` (`unsigned(op.value)` / `reinterpret(UInt64, Int64(op.value))`); mask to the store width where required by the callee contract.
- Test: dynamic-index stores of −1, typemin(Int8), −2 and positive edge values across every packed shape; verify all selected slots and all ancillae. Compare equivalent constant versus SSA values and static versus dynamic indices.
- Already tracked? no matching open bead found.

### F5 — [S0] Loop-header side effects keep executing after exit, including the “check-only” pass
- Where: `src/lowering/cfg.jl:419–420`, `444–450`, `523–527`, `549–562`.
- Evidence: VERIFIED-BY-EXECUTION. The fixture below counts actual visits to a loop header in memory. Its correct result is `(x & 3) + 1`, and every input terminates within three back edges. For K=3 the circuit always returns **4**, wrong on **192/256** inputs; for K=5 it always returns **6**, wrong on **256/256** inputs. Both folding settings reproduce; all four circuits pass `verify_reversibility`. Header execution is guarded by the function-level header predicate, which stays true for every unrolled iteration. Only PHI registers freeze. The post-K “check-only” evaluation dispatches `IRStore` again, so it is observably not check-only.
- Failure scenario: a valid loop loads/increments/stores memory in its header before testing for exit. After source execution exits, the unroller continues changing that memory; increasing the supposedly safe bound changes the answer.
- Frontend confirmation: the corresponding self-loop LLVM function passes `LLVM.verify` and, after actual extraction, reproduces **192/256** wrong outputs at K=3 with `verify_reversibility == true`.
- Fix: track an iteration-active/done predicate and freeze all observable state after the first exit, including header stores and inlined effects. Treat the final header evaluation as the actual next header visit only if active; compute convergence without replaying effects on already-exited paths. An immediate safe refusal is to reject side-effecting loop headers until this is implemented.
- Test: below fixture exhaustively for K=3,4,5, with both fold settings; source oracle and all ancillae must agree and results must be invariant under increasing a sufficient K. Add cases where the header writes memory used in its exit condition.
- Already tracked? `Bennett-8nfb` mentions needing a done flag for loop extensions, but its description says current problematic shapes all fail loud; this accepted **silent** memory miscompile is not described there. `Bennett-n9o8` concerns a separate false convergence failure.

```julia
using Bennett: IRPhi
p = ParsedIR(8,[(:x,8)],[
    IRBasicBlock(:entry,IRInst[IRAlloca(:a,8,iconst(1)),
        IRStore(ssa(:a),iconst(0),8),IRBinOp(:n,:and,ssa(:x),iconst(3),8)],
        IRBranch(nothing,:h,nothing)),
    IRBasicBlock(:h,IRInst[
        IRPhi(:i,8,[(iconst(0),:entry),(ssa(:i2),:h)]),
        IRLoad(:v,ssa(:a),8),IRBinOp(:v2,:add,ssa(:v),iconst(1),8),
        IRStore(ssa(:a),ssa(:v2),8),
        IRBinOp(:i2,:add,ssa(:i),iconst(1),8),
        IRICmp(:done,:uge,ssa(:i),ssa(:n),8)],IRBranch(ssa(:done),:exit,:h)),
    IRBasicBlock(:exit,IRInst[IRLoad(:r,ssa(:a),8)],IRRet(ssa(:r),8))],[8])
for K in (3,5), fold in (false,true)
    c = reversible_compile(p;max_loop_iterations=K,fold_constants=fold)
    println((K,fold,count(x->simulate(c,x)!=Int(x&3)+1,
        typemin(Int8):typemax(Int8)),simulate(c,Int8(0)),verify_reversibility(c)))
end
# (3, false, 192, 4, true), (3, true, 192, 4, true)
# (5, false, 256, 6, true), (5, true, 256, 6, true)
```

### F6 — [S0] Missing store/allocation gate groups let ValueEager silently erase memory writes
- Where: `src/lowering/driver.jl:556–568`; consumer `src/pebble/value_eager.jl:56` onward. `IRStore` has no `dest`, and a zero-gate `IRAlloca` creates no group.
- Evidence: VERIFIED-BY-EXECUTION. Lower `alloca a; store x,a; r=load a; ret r` with `fold_constants=false`. Emitted groups are exactly `[(:__pred_entry,1,1), (:r,26,33)]`; store gates 2–25 and allocation ownership are absent. Default Bennett returns **42** for x=42, but `ValueEagerStrategy()` returns **0** and **passes `verify_reversibility`**. `CheckpointStrategy()` and `PebbledGroupStrategy(4)` fail with `_remap_wire: unmapped wire 10 … not in wmap and not a function input` on the same LR.
- Failure scenario: the lowering result advertises a group decomposition that does not cover its gate stream or mutable dependencies. Strategies replaying the advertised groups silently omit stores or cannot map their primal registers.
- Fix: make group metadata cover every emitted gate and every allocated live register, including side-effecting instructions and zero-gate allocations; represent memory state dependencies explicitly. Until then mark memory-bearing LRs unsupported for these strategies and fall back explicitly to full Bennett. Merely assigning a synthetic name to a store is insufficient without dependencies on prior memory versions.
- Test: the fixture below under each strategy and folding configuration; require `simulate(c,x)==x` for all 256 Int8 inputs, and verify clean ancillae. Add a structural assertion that group ranges partition all forward gates whenever a group-based strategy is allowed.
- Already tracked? no exact open bead. Architecture review c2 §2.B1 notices missing store groups but does not execute this silent miscompile. `Bennett-exb3` is different: folding empties all groups and triggers a safe fallback; this defect occurs with populated but incomplete groups.

```julia
p = ParsedIR(8,[(:x,8)],[IRBasicBlock(:entry,IRInst[
    IRAlloca(:a,8,iconst(1)),IRStore(ssa(:a),ssa(:x),8),
    IRLoad(:r,ssa(:a),8)],IRRet(ssa(:r),8))],[8])
lr = Bennett.lower(p;fold_constants=false)
c = Bennett.bennett(lr;strategy=ValueEagerStrategy())
println((simulate(c,Int8(42)),verify_reversibility(c))) # (0, true)
```

### F7 — [S0] QROM free-list reuse corrupts compact inlined callees while reversibility still passes
- Where: `src/lowering/call.jl:104–105`, `113`, `120`, `124`, and noncompact twin at `138–158`; `src/wire_allocator.jl:18–25`; `src/qrom.jl:129`.
- Evidence: VERIFIED-BY-EXECUTION. A 32-entry i8 QROM lookup followed by `inc8(x::UInt8)=x+UInt8(1)` reproduces the previously unconfirmed allocator bug. With `compact_calls=true`, **192/256** inputs are wrong, e.g. x=−128 → **65**, expected 1; x=−127 → **−126**, expected 2. Appending `+3` makes **256/256** wrong, e.g. x=−128 → **−60**, expected 4. Both compact variants **pass `verify_reversibility`**. Without compact calls and without the final add, simulation instead detects `Ancilla wire 68 not zero post-circuit`. Noncompact with the final add happened to give correct results, demonstrating sensitivity to later allocations rather than a universal failure.
- Failure scenario: QROM returns scratch wires to the allocator. The subsequent call discards the vector returned by `allocate!` and uses a bump-pointer offset as if every allocation were contiguous. Reused holes mean the remapped callee reaches registers it did not reserve; copy-out/subsequent allocations overlap those registers.
- Fix: map every callee wire through the actual vector returned by `allocate!`, including inputs, outputs, gates, and loop guards, or add an explicit contiguous-allocation primitive that reserves exactly the assumed interval. Audit every other use of `wa.next_wire` as an allocation-range description.
- Test: below across compact on/off, folding on/off, table sizes 16/32/64, calls with constant and SSA arguments, and allocations after calls. Assert output against the table oracle exhaustively and all wire invariants.
- Already tracked? **Bennett-9k7n**. Its root-cause description is correct; this review supplies the missing reproducer and establishes S0 severity, beyond its current P2/unconfirmed description. The older `aggregate.jl:159–166` comment blaming free-list reuse on Bennett's reverse scheduling should be re-evaluated: correctly cleaned scratch reuse is reversible; this offset remapping violates allocation ownership independently of reverse scheduling.

```julia
using Bennett: IRCall
inc8(x::UInt8) = x + UInt8(1)
insts = IRInst[IRBinOp(:i,:and,ssa(:x),iconst(31),8),
    IRVarGEP(:p,ssa(:table),ssa(:i),8),IRLoad(:v,ssa(:p),8),
    IRCall(:c,inc8,[ssa(:v)],[8],8)]
p = ParsedIR(8,[(:x,8)],[IRBasicBlock(:entry,insts,IRRet(ssa(:c),8))],
    [8],Dict(:table=>(UInt64.(0:31),8)))
c = reversible_compile(p;compact_calls=true)
println((simulate(c,Int8(-128)),verify_reversibility(c))) # (65, true)
println(count(x->simulate(c,x)!=Int(x&31)+1,typemin(Int8):typemax(Int8))) # 192
```

### F8 — [S1] An untaken loop can fail its unconditional convergence guard
- Where: `src/lowering/cfg.jl:567–575`; loop-header reachability is available at 419–420 and 550 but omitted from the guard.
- Evidence: VERIFIED-BY-EXECUTION. `skiploop` below is defined and terminates for all Int8 inputs with at most three iterations. At `optimize=false, max_loop_iterations=3, strategy=:expression`, **128/256 inputs throw** a false convergence error. First failure: x=−124 (n=4), where the source skips the loop and returns 4. `optimize=true` happened to avoid the failure in this fixture. Two other conditional-loop fixtures passed all 256 inputs in both modes; the issue requires an inactive seed whose hypothetical loop exceeds K.
- Failure scenario: the loop is not entered, but its speculatively evaluated seed would require more iterations than the bound. Simulation demands convergence even on that inactive path.
- Fix: emit `!block_pred[header] || converged`, rather than the raw convergence condition. Apply the same condition to guards imported from calls, including calls in inactive loop iterations and branches.
- Test: exhaustive `skiploop` with K=3, plus taken overflow (must still throw), untaken nonterminating seeds, multi-preheader inactive loops and calls with loops in inactive branches.
- Already tracked? **Bennett-n9o8**; its description is correct. Its current P2 understates the S1 valid-input rejection under this review's scale.

```julia
function skiploop(x::Int8)
    n = x & Int8(7)
    if n <= Int8(3)
        while n > 0; n -= Int8(1); end
    end
    n
end
c = reversible_compile(skiploop,Int8;optimize=false,
    max_loop_iterations=3,strategy=:expression)
skiploop(Int8(-124))         # 4
simulate(c,Int8(-124))       # ERROR: ... header block :L4 did not converge ...
```

### F9 — [S2] Inlined callees discard the caller's arithmetic and compilation options
- Where: `src/lowering/types.jl:292–294`; `src/lowering/call.jl:91–97`; loop override `src/lowering/cfg.jl:429`, `557`.
- Evidence: VERIFIED-BY-EXECUTION. A ParsedIR containing only `IRCall(:r,mul8,[x,y],[8,8],8)`, with `mul8(x::UInt8,y::UInt8)=x*y`, produces **414 gates / 242 wires** identically for default, `target=:depth`, and explicit `mul=:qcla_tree`. Directly compiling the same multiplication with `strategy=:expression` gives **380 gates / 225 wires** for `:shift_add` versus **3024 gates / 504 wires** for `:qcla_tree`. All call variants returned 42 for (6,7) and passed reversibility. Source confirms the call lowers with defaults and hard-coded K=64, and loop contexts similarly hard-code `add=:ripple`.
- Failure scenario: an explicit strategy affects only the caller; software arithmetic and other registered callees silently run a different strategy. A requested loop bound also does not reach callees.
- Fix: carry an immutable compile-options bundle through contexts and recursive lowering, with recursion/bound policy explicit. Disable in-place eligibility inside loops without replacing the selected adder family. Any intentionally unsupported combination should fail at entry.
- Test: compare direct and one-call wrappers for explicit add/mul/target/folding/memory options, checking emitted primitive fingerprints as well as results and ancillae. Test callee convergence at K−1/K/K+1 rather than relying on 64.
- Already tracked? **Bennett-0a6f**, **Bennett-jgyx**, **Bennett-vpgj**; descriptions are correct. Only arithmetic option loss was independently executed here; the fixed bound and loop adder override are directly visible in the cited paths.

### F10 — [S2] Default constant folding silently disables all group-based cleanup strategies
- Where: `src/lowering/driver.jl:529–535`; empty-group fallbacks in `src/pebble/value_eager.jl:56–60`, `src/pebble/pebbled_groups.jl:297–301`, `402–403`.
- Evidence: VERIFIED-BY-EXECUTION. For `f(x::Int8) = (x*x + Int8(3))*x` extracted at `optimize=false`, `fold_constants=false` produces four groups; checkpoint and pebbled-group use **241 wires**. Default folding produces **zero groups**; ValueEager, Checkpoint and PebbledGroup(4) all emit gate streams exactly equal to DefaultStrategy, at **441 wires**. All six cases passed an exhaustive 256-input result sweep and `verify_reversibility`.
- Failure scenario: the documented cleanup strategy can be selected successfully yet has no effect under the default lowerer options, increasing resource use and defeating the strategy contract.
- Fix: preserve/remap group ranges and dependencies while folding, or explicitly reject/warn about incompatible strategy/options. Do not silently present fallback as the requested strategy.
- Test: exercise non-default cleanup strategies using default lowerer options and assert the strategy's observable scheduling/resource behavior, with correctness and ancilla checks.
- Already tracked? **Bennett-exb3**; description verified as written.

### F11 — [S2] Unknown-pointer loads are silently discarded if their result is unused
- Where: `src/lowering/aggregate.jl:531–536`.
- Evidence: VERIFIED-BY-EXECUTION. `ParsedIR(8,[(:x,8)],[IRBasicBlock(:entry,IRInst[IRLoad(:dead,ssa(:missing),8)],IRRet(ssa(:x),8))],[8])` compiles, returns 42 for x=42, and passes reversibility. The pointer does not exist and the instruction never binds its destination. A live use instead fails later in `resolve!`, hiding the original load site.
- Failure scenario: unsupported/malformed memory access is accepted according to downstream usage instead of being diagnosed at the offending instruction, violating the explicit fail-fast contract. No valid-program wrong result is claimed for this fixture.
- Fix: reject unknown pointers at the load with pointer/destination context. Recognize provably irrelevant safepoint operations in extraction, not a catch-all silent lowerer fallback.
- Test: unknown-pointer loads with dead and live destinations must both fail immediately at the load; legitimate pointer parameters and NTuple loads must still pass.
- Already tracked? **Bennett-sy9t**; description is correct.

### F12 — [S3] The allocator accepts freeing never-allocated and nonpositive wire IDs
- Where: `src/wire_allocator.jl:39–49`.
- Evidence: VERIFIED-BY-EXECUTION. After allocating wires `[1,2]`, each separate `free!(wa,[0])`, `free!(wa,[-1])`, and `free!(wa,[99])` succeeds. The next `allocate!(wa,1)` returns `[0]`, `[-1]`, or `[99]` respectively while `wire_count(wa)==2`. Double-free protection does not enforce ownership/range.
- Failure scenario: an internal lifetime bug is turned into a successfully allocated invalid gate index, corrupting allocator invariants and deferring failure far from its cause. No existing valid-program producer of such an invalid free was found.
- Fix: validate the entire batch is unique and each ID lies in `1:wire_count(wa)` and is currently allocated before mutating the free list; keep the zero-state obligation explicit.
- Test: invalid IDs, duplicate IDs within a batch and already-free IDs fail without changing allocator state; ordinary noncontiguous reuse remains correct.
- Already tracked? no exact open bead. `Bennett-swee` fixed negative allocations/double frees, but not invalid frees; `Bennett-vt0a` addresses broader lifetime design.

### F13 — [S2] Narrowing breaks tuple layout, return widths, and byte offsets
- Where: `src/narrow.jl:12–24`, `41`, `49–57`, `61–65`, `70–71`.
- Evidence: VERIFIED-BY-EXECUTION. `reversible_compile((x::Int8) -> (x,x+Int8(1)), Int8; bit_width=4,strategy=:expression)` fails in both modes. At `optimize=false`: `_lower_store_via_shadow!: idx=2 out of range [0, 2)`. At `optimize=true`: `resolve!: SSA operand %new::Tuple.unbox.fca.1.insert has length(wires)=8 but caller advertised width=4`. The pass sets total return width to W even when there are two W-bit return elements. Its memory path changes alloca element widths while leaving byte GEP offsets unchanged, doubling the interpreted element index for W=4.
- Failure scenario: an ordinary two-element tuple return, supported at the source width, cannot use the advertised narrowing option. The comment that aggregates are mutually exclusive with narrowing is false for this public invocation.
- Fix: distinguish scalar widths, packed aggregate total widths, logical fields, and address-layout units. Derive return width from the narrowed return shape; rewrite byte layouts consistently or reject aggregate/memory narrowing at the public boundary with an accurate capability error.
- Test: homogeneous and mixed Boolean/integer tuple returns and arguments at W=1,3,4,8, with both extraction modes; assert actual output tuples and ancilla invariants. Test constant GEPs after narrowed allocas independently.
- Already tracked? no exact open bead; **Bennett-g7d6** is about metadata loss, and closed **Bennett-6bu3** repaired constructors but did not establish this layout contract.

### F14 — [S3] MUX-EXCH priority costs roughly 9–14× more gates than the existing shadow arm
- Where: `src/lowering/memory.jl:144–157`; generated helpers `989–1068`.
- Evidence: VERIFIED-BY-EXECUTION. Constructed identical contexts with N i8 slots initialized to `17+k`, then a runtime-indexed store and an independently indexed load. Called each existing helper directly, applied the same `_fold_constants` and default Bennett wrapper, and checked every index pair with values 0,1,127,128,255 plus `verify_reversibility`. Both arms were correct. Measurements:

  | N | MUX gates | Shadow gates | MUX wires | Shadow wires |
  |---|----------:|-------------:|----------:|-------------:|
  | 2 | 1080 | 114 | 2451 | 107 |
  | 4 | 3600 | 258 | 5827 | 185 |
  | 8 | 5572 | 594 | 9379 | 353 |

- Failure scenario: every supported small dynamic array is forced into the more expensive arm; the fallback is selected only when `N*W>64`. The comment claiming a cheaper MUX per-op cost contradicts these same-shape measurements. The measured ratio differs from historical 15–40× figures because the fixture and constant folding differ, but the direction is unequivocal.
- Fix: benchmark the shape-generic shadow helpers across the supported lattice, use the cheaper verified strategy by default, and expose explicit strategy selection if preserving a research comparison is useful. Update the inaccurate priority rationale and record default-count deltas.
- Test: compare both arms on identical initialized memory with independent store/load indices, multiple writes, and guards; retain result/ancilla checks alongside local resource regression limits.
- Already tracked? **Bennett-vscb**; root cause and recommended comparison are correct. This review verifies the primitives on valid indices as well as their cost; F1/F2 concern surrounding dispatch/provenance, not a failure of the isolated MUX primitive.

### F15 — [S0] Dynamic alloca lowering silently substitutes a four-write history buffer for memory
- Where: `src/lowering/memory.jl:75–96`, `399–432`; backing semantics `src/persistent/linear_scan.jl:23`, `44–51`.
- Evidence: VERIFIED-BY-EXECUTION. A dynamic allocation of **two or three i8 slots** (size `(x&1)+2`, always valid), with stores `a[0]=5; a[1]=7; a[0]=9; a[1]=11; a[0]=13`, followed by `load a[1]`, returns **7 instead of 11 for all 256 Int8 inputs** under `mem=:persistent`. `verify_reversibility == true`; circuit has 7298 gates. Only two distinct indices are used, both in bounds, so this is not an oversized source allocation. The dispatcher never checks the implementation's `max_n` or number of writes. `linear_scan_pmap_set` appends even updates and overwrites its final history slot after four calls, discarding the only record of `a[1]=11`.
- Failure scenario: opting into the recommended lowering for runtime-sized memory changes ordinary store/load semantics after five writes, even when the array size and number of distinct live keys fit below the map's nominal capacity.
- Fix: require the backing implementation to preserve latest values for repeated keys and enforce a sound capacity contract for all admitted executions. Either statically prove sufficient capacity, allocate a bounded model derived from program constraints, or emit a runtime overflow guard. Never import an implementation-defined map-overflow behavior as silent alloca semantics. Merely checking `n <= max_n` does not fix repeated-write history exhaustion.
- Test: the fixture below exhaustively, repeated updates longer than max_n, distinct-key overflow, conditional writes, and each offered persistent implementation. Compare against a normal array oracle and check ancilla/input restoration.
- Already tracked? no exact open bead found. `Bennett-z2dj` introduced this dispatcher; deferred `Bennett-uxn2` concerns CF overflow, not this linear-scan repeated-key witness. Persistent implementation limitations do not authorize silent miscompilation of valid memory operations. The protocol in `persistent/interface.jl:35` only permits implementation-defined behavior after `max_n` **distinct** keys, a threshold this witness never reaches.

```julia
insts = IRInst[
    IRBinOp(:n0,:and,ssa(:x),iconst(1),8),
    IRBinOp(:n,:add,ssa(:n0),iconst(2),8),IRAlloca(:a,8,ssa(:n)),
    IRVarGEP(:p0,ssa(:a),iconst(0),8),IRVarGEP(:p1,ssa(:a),iconst(1),8)]
for (ptr,v) in ((:p0,5),(:p1,7),(:p0,9),(:p1,11),(:p0,13))
    push!(insts,IRStore(ssa(ptr),iconst(v),8))
end
push!(insts,IRLoad(:r,ssa(:p1),8))
p = ParsedIR(8,[(:x,8)],[IRBasicBlock(:entry,insts,IRRet(ssa(:r),8))],[8])
c = reversible_compile(p;mem=:persistent)
println((simulate(c,Int8(2)),verify_reversibility(c))) # (7, true), expected 11
```

### F16 — [S1] The loop-exit heuristic rejects an ordinary single-exit natural loop
- Where: `src/lowering/driver.jl:214–217`; duplicate heuristic `src/lowering/cfg.jl:356–362`.
- Evidence: VERIFIED-BY-EXECUTION. A valid five-block CFG `entry→H; H: (i<n ? body : exit); body→latch; latch→H; exit: ret i`, with n=`x&3`, initial i=0 and latch i'=i+1, throws `lower_loop!: IRRet in loop body at exit — early return inside a loop not supported` for K=3. There is no early return: exit is outside the loop. The heuristic labels the true successor as the exit whenever it is neither the header itself nor an immediate back-edge source; here it is an ordinary body block before the latch.
- Failure scenario: splitting the true arm into a body and a latch changes a supported loop into a misleading refusal, despite a single header, latch and exit and an adequate bound.
- Fix: identify natural-loop membership from dominance/back edges (or an explicit supported-region analysis), then classify outgoing edges. Share that analysis between the driver and unroller. Reject genuinely irreducible/multi-exit CFGs with accurate diagnostics until supported.
- Test: both branch polarities, zero/one/several blocks before the latch, body diamonds, and block-order permutations, each exhaustively for n=`x&3`; all must give n and clean ancillae at K≥3.
- Already tracked? **Bennett-8nfb** explicitly describes this heuristic and misleading IRRet error; that part of the tracked description is correct. F5 is a separate accepted silent failure.

## Unconfirmed suspicions

## What is sound (brief)

- The c6ex multi-preheader seed merge and stricter PHI-edge checks survived their full focused regression file. The old silent `_compute_block_pred!` / `_edge_predicate!` fallback claims in c2 A3 describe pre-fix code; the current paths throw with useful context. Same-target branches are canonicalized before predicate construction.
- The stwr replacement for index-based liveness is materially sounder: occurrence counting includes terminators, PHIs, selects and deferred GEP reads; fresh-definition restrictions and the live-wire alias scan protect in-place consumption; loop contexts disable in-place reuse. Its full focused suite passed all six strategies.
- All ten icmp predicates matched their signed/unsigned oracle on **all 65,536 Int8 bit-pattern pairs each**. `shl`, `lshr`, `ashr` matched all 256 values × legal amounts 0:7, with folding on/off. Raw LLVM overshifts produce poison, so deterministic barrel behavior outside that domain is not independently labelled a miscompile; F3 instead uses fully defined Julia inputs.
- `sext` and `zext` i8→i16 passed all 256 inputs; `trunc` i16→i8 passed all 65,536 inputs. Signed/unsigned div/rem passed selected zero/nonzero, sign, typemin, typemax and boundary inputs on defined cases, plus reversibility. The emitted division circuits were large (637,458–1,595,800 gates), but no numerical failure was found.
- `_fold_constants` passed 539 focused assertions and comparisons against unfolded arithmetic/predication results. Its loss of group metadata is F10; no numerical constant-propagation defect was found in the three implemented gate arms.
- Fresh result copies in casts and `extractvalue` uphold the in-place ownership whitelist. High carry/product/division bits left dirty during lowering are correctly cleaned by the outer Bennett reverse pass; c2 A10's observation is not itself an ancilla invariant violation.
- Isolated MUX-EXCH and shadow store/load helpers agreed for all tested in-bounds independent index pairs. Their primitive correctness should be preserved while repairing surrounding predicates/provenance and strategy selection.

## Nits (S4)

- `aggregate.jl:565` says “zero gates (wire aliasing)” immediately before allocating and CNOT-copying a fresh result; the latter is essential for stwr.
- `phi.jl:333–336` still claims `resolve!` does not check SSA widths; it does at `operand.jl:14–18`.
- `cfg.jl:379–387` promises deletion of iteration-local SSA entries and computes `phi_dests` / `vw_snapshot`, but no deletion follows. Fresh rebinding currently keeps the disabled-in-place loop path correct; remove the unused bookkeeping or implement and document the intended lifetime policy.

## Coverage log

- Read `CLAUDE.md` in full. The explicit review-only instructions override its worklog, issue-tracker, and commit/push workflow for this session.
- Read all lowering source files, narrow pass and allocator; contextual IR/simulator/diagnostics/QROM code. Read the c2 architecture review, relevant chunk 108 history and the open bead snapshot.
- Executed `test/test_c6ex_predication_soundness.jl` with `--compiled-modules=existing --project --check-bounds=yes --startup-file=no`: **115/115 passed (30.0s)**. Fresh focused probes above expose intersections absent from that regression battery.
- Executed `test/test_stwr_cuccaro_soundness.jl` under the same flags: **872/872 passed (65.4s)**, including all six Bennett strategies. The old c2 A1/A2 live-operand/liveness defects have been replaced by the exclusive-reader implementation; no new Cuccaro aliasing failure has yet been confirmed.
- Executed `test/test_heup_fold_constants_contract.jl`: **539/539 (7.7s)**, and `test/test_zmw3_shift_bounds.jl`: **705/705 (5.3s)**, via a short `using Test,Bennett; include(...)` probe with bounds checking.
- Independently swept nested branch diamonds and nested `ifelse` functions on all 256 Int8 inputs under optimize on/off × ripple/Cuccaro × fold on/off: **16 successful circuit configurations**, no output or reversibility failures. Conditional bounded-loop fixtures also passed both optimization modes when hypothetical inactive iterations fit K; F8 isolates the missing activation guard.
- A more complex four-preheader loop with an `iseven` body exposed the already-tracked `:__unreachable__` KeyError at `cfg.jl:228` under optimize=false (**Bennett-8nfb**), and mixed-poison ConstantVector extraction refusal under optimize=true (**Bennett-2o4r**). These were loud failures, not additional silent PHI miscompiles.
- Arithmetic probes: ten predicates × 65,536 pairs; three shifts × two folding modes × 2,048 pairs; 131 signed-division, 132 signed-remainder, and 110 cases each for unsigned division/remainder; 256/256/65,536 cast inputs. Every successful circuit also ran `verify_reversibility` (12 random probes for the large division circuits, default 100 elsewhere).
- Metadata audit: **Bennett-g7d6** is correct that `_narrow_ir` discards all three fields. A direct probe with one global, non-nothing MemSSAInfo and one provenance tuple produced `globals=0, memssa=nothing, provenance=empty`. The stronger claim of a currently reachable silent constant-table result is not established: the normal table nodes `IRVarGEP`/`IRLoad` hit missing narrowing handlers first. No S0 table claim is inferred from field loss alone.
- No full suite, `bd`, source changes, worklog edits, commits or remote automation were performed. Julia 1.12.5; subsequent probes used existing compiled modules to avoid repeated precompile work. Initial normal package load completed after a shared precompile-lock wait.

### Continuation checkpoint 1 — independently repeated serious reproducers

- Re-executed the saved Julia snippets under Julia with `--compiled-modules=existing --project --check-bounds=yes --startup-file=no`. F1: 64 mismatches and reversibility true. F2: 256 mismatches in both folding modes, output 0 and reversibility true. F3: exactly the recorded `[0,0,0,0,0]` / `[1,2,4,8,1]` outputs, both reversible. F5: all four recorded mismatch counts and outputs reproduced. F6: output 0 instead of 42, reversible. F7: output 65 for -128 and 192 mismatches, reversible. F8: the recorded false convergence exception reproduced. F15: output 7 instead of 11, reversible. These claims remain confirmed; real Julia extraction follow-ups and the two remaining S1 fixtures follow.
- Independently read the complete CFG/loop and PHI implementations, call lowering, allocator, and driver control-flow walk. No repository source files were changed.
