# Astra review — B-extract-vm — 2026-09-26
Status: IN PROGRESS
Scope: src/extract/{dict_vm,vector_vm,vector_vm_walk,vector_vm_emit,vector_vm_cfg,vector_vm_term,heap,callgraph,julia_set}.jl; src/memssa.jl
Method: Read CLAUDE.md in full. Targeted source/ADR/test inspection and bounded Julia probes; no full suite. Only this report is written, per the review-specific instructions (which supersede worklog/beads/commit requirements).

## Executive summary
Pending completion.

## Findings

### F1 — [S0] Vector prelude collapse deletes an ordinary early return
- Where: src/extract/vector_vm_cfg.jl:112–156; src/extract/vector_vm_emit.jl:70–88.
- Evidence: VERIFIED-BY-EXECUTION, Julia 1.12.3, `julia --project --check-bounds=yes -e 'using Bennett; function probe(n::Int64); n == 2 && return Int8(99); v=Vector{Int8}(undef,n); s=Int8(0); for i in 1:n; v[i]=Int8(i%100); s+=v[i]; end; s; end; p=Bennett.extract_parsed_ir(probe,Tuple{Int64};optimize=false,mem=:vm); println(probe(2)); for b in p.blocks; println(b); end'`. Native output is `99`. Extraction succeeds; the synthetic entry contains only `IRAlloca(n)`, `icmp sle 1,n`, and its xor. The `n == 2` test and `ret 99` are absent. The only emitted return is the loop sum (1+2 = 3).
- Failure scenario: a valid Vector routine with a guard return before allocation loses that guard and executes the allocation/loop instead. `_vec_vm_prelude_blocks` marks **all** entry-reachable blocks before the chosen loop-bound block as prelude, including user return blocks. No check certifies those blocks as disposable machinery.
- Fix: preserve user CFG and move only positively certified allocation instructions; as an immediate safe fix reject any prelude with a user return, user branch, side effect, or surviving value definition outside the chosen exit block. Prove the chosen exit dominates the surviving body and validate SSA dominance after rewriting.
- Test: native-versus-VM execution and reversal for this function at n=0,1,2,3; also a scalar computation and a user side effect before allocation.
- Already tracked? no matching open bead.

  End-to-end confirmation: loaded the sibling BennettVM via `push!(LOAD_PATH,"../BennettVM.jl"); using BennettVM`, ran `vm=lower_vm(p); rs=initial_state(vm,Dict(p.args[1][1]=>Int64(2))); run!(rs,vm)`. The return register `:value_phi51` is **3**, native is **99**. `unrun!(rs,vm)` restores `rs.current == rs.initial` and empties history: **clean reversal does not catch this miscompile**.

## Unconfirmed suspicions

## Findings continued (to be consolidated on completion)

### F2 — [S0] Two different Dict objects are silently merged into one map
- Where: src/extract/dict_vm.jl:155–180, 305–345, 448–485.
- Evidence: VERIFIED-BY-EXECUTION. Define `function twodict(x::Int64,y::Int64); a=Dict{Int64,Int64}(); b=Dict{Int64,Int64}(); a[1]=x; b[1]=y; Base.@noinline getindex(a,1); end`. `Bennett.extract_parsed_ir(twodict,Tuple{Int64,Int64};optimize=true,mem=:vm)` succeeds and emits exactly `IRMapInsert(1,x); IRMapInsert(1,y); IRMapGet(result,1); ret result`. Native `twodict(11,22)` is 11; the emitted single-map program returns 22. Probed with `--check-bounds=yes` on Julia 1.12.3. The equivalent one-Dict function succeeds too; optimize=false correctly rejects the allocator shape on this Julia.
- Failure scenario: ordinary independent dictionaries with a shared key alias in ParsedIR. All dictionary identity operands are discarded. The comment at lines 168–171 promises a multi-dictionary guard in `_dict_vm_collect_ops`; **that guard does not exist**.
- Fix: prove every rewritten get/set/delete receiver is the same positively identified Dict allocation (including any identity-preserving aliases), and reject multiple receivers before discarding their operands. Alternatively add explicit map identity to the IR/backend.
- Test: two Dicts with equal keys and distinct values, querying each and deleting from only one; compare native output and verify reversal. Also reject a call whose receiver is not the recognised allocation.
- Already tracked? no matching open bead.

### F3 — [S1] Recursive roots are re-added as callees and rejected as duplicate canonical keys
- Where: src/extract/callgraph.jl:100–113, 124–136; src/extract/julia_set.jl:475–493.
- Evidence: VERIFIED-BY-EXECUTION. `@noinline rec(n::Int64)=n==0 ? 0 : rec(n-1)+1`. `any(x->x[1]===typeof(rec),Bennett.transitive_callees(rec,Tuple{Int64}))` prints `true`, contradicting the API's “ROOT ... EXCLUDED” contract. `extract_parsed_ir_set_from_julia(rec,Tuple{Int64})` fails with `duplicate canonical key rec#dcc408c3 — a hash collision or a re-extracted callee leaked through`.
- Failure scenario: a finite self-recursive or mutually recursive typed callgraph contains the root. `visited` starts empty, so the root is extracted as a callee and again as the root. This blocks a valid closed-world graph before the VM can handle the call.
- Fix: initialise the traversal's visited set with the root, excluding it from the returned order (and similarly from the helper's output). Preserve root registration for recursive calls separately; ensure include_root=false has an explicit contract for recursive roots.
- Test: self and mutual recursion, exact one-root set membership, native-versus-VM results and clean reversal for bounded input values.
- Already tracked? Bennett-t7zu mentions recursive sret/circuit lowering, but does not describe this graph-enumeration/duplicate-key defect; no matching open bead.

### F4 — [S1] Vector extraction accepts dangling SSA after deleting pre-allocation arithmetic
- Where: src/extract/vector_vm_emit.jl:73–88; src/extract/vector_vm_cfg.jl:140–156.
- Evidence: VERIFIED-BY-EXECUTION. `function predcalc(n::Int64); x=n+10; v=Vector{Int64}(undef,n); s=Int64(0); for i in 1:n; v[i]=x; s+=v[i]; end; s; end`. Extract with `optimize=false,mem=:vm`. Native `predcalc(2)` is 24. Extraction and `lower_vm` succeed, but `run!` reports `unbound SSA name :__v1 ... pc: 92`. The emitted entry has the alloca and loop-bound test, but not the `n+10` definition used by the store.
- Failure scenario: valid computation before allocation, including a computed allocation size, is discarded when the prelude collapses. Names remain registered, so `_operand` accepts references to definitions that were never emitted. This is the value-flow counterpart to F1, not an unsupported-operation rejection.
- Fix: retain the dependency-closed surviving prelude slice in CFG order; validate that every emitted SSA use has a dominating emitted definition or argument. Reject at extraction if that cannot be proved.
- Test: the function above for n=0,1,2, plus `m=n+1; Vector{Int8}(undef,m); for i in 1:m ...`; check native values and reversal.
- Already tracked? no matching open bead.

### F5 — [S2] MemorySSA printing deadlocks when its undrained stderr pipe fills
- Where: src/memssa.jl:123–142.
- Evidence: VERIFIED-BY-EXECUTION. With `timeout -k 2 75 julia --project --check-bounds=yes -e ...`, `_run_memssa_on_ir("define i64 @small(ptr %p) {\nentry:\n store i64 1, ptr %p\n %a = load i64, ptr %p\n ret i64 %a\n}\n";preprocess=false)` prints `small_bytes=188`. Then construct `big="define i64 @big(ptr %p) {\nentry:\n" * join([" store i64 $i, ptr %p\n %x$i = load i64, ptr %p\n" for i in 1:2000]) * " ret i64 %x2000\n}\n"`. It prints `big_input_bytes=99837`; the subsequent `_run_memssa_on_ir(big;preprocess=false)` never returns before timeout (exit 124). No sandbox execution block occurred. An earlier timeout during default-mode precompilation was discarded as evidence; this rerun reached both explicit progress prints.
- Failure scenario: `use_memory_ssa=true` on a moderately large function/module hangs inside LLVM's printer. Reading starts only after `LLVM.run!` returns; LLVM blocks when the finite pipe buffer fills.
- Fix: drain the pipe concurrently with a mechanism that continues running while the LLVM call blocks, or capture into a seekable temporary stream; guarantee pipe and module disposal on errors. Serialise process-wide stderr redirection if concurrent calls are allowed.
- Test: a bounded local test with annotation output larger than pipe capacity, asserting completion and all expected definitions/uses, plus exception cleanup.
- Already tracked? no matching open bead.

## What is sound (brief)

### F6 — [S0] The heap M2/M3 proof explicitly permits dropping atomic read-modify-write effects
- Where: src/extract/heap.jl:1524–1536, 1875–1895; src/extract/heap.jl:2064–2065.
- Evidence: VERIFIED-BY-EXECUTION (in-memory LLVM fixture → ParsedIR). Run `Bennett._parsed_ir_from_ir_string(ir;mem=:heap,ptr_cells=true)` on the following accepted fixture:
  ```llvm
  declare ptr @ijl_gc_small_alloc(ptr, i32, i32, i64)
  define i8 @julia_atomic(i8 %x) {
  entry:
    %m = call ptr @ijl_gc_small_alloc(ptr null, i32 0, i32 24, i64 0)
    store i64 1, ptr %m
    %d = getelementptr i8, ptr %m, i64 16
    store i8 %x, ptr %d
    %old = atomicrmw add ptr %d, i8 1 monotonic
    %r = load i8, ptr %d
    ret i8 %r
  }
  ```
  Output contains only a one-cell alloca, store x, load r and ret r; the atomic increment is gone. `reversible_compile(p)` succeeds. Thus x=5 produces 5 instead of 6. The comment at lines 1890–1895 explicitly omits AtomicRMW because it supposedly never appears; no admission check establishes that assumption.
- Failure scenario: a near-match to the recognised Memory allocation with an atomic update is accepted and silently loses the update. An unused old-value result does not make the memory effect dead.
- Fix: reject AtomicRMW before skeleton suppression, as M1 already does; do the same audit for Vector/Dict skeletons and volatile/atomic loads and stores. Model these operations explicitly only with a proof covering their effects.
- Test: this fixture must fail loud; variations with a used old value, an external target, and an atomic update in an otherwise real Julia-derived allocation skeleton.
- Already tracked? no matching open bead; Bennett-ares atomic VM relaxation concerns the normal walker, not this bypass.

### F7 — [S0] The heap escape check accepts caller-owned pointer arguments and drops writes through them
- Where: src/extract/heap.jl:701–726, 1854–1867; src/extract/heap.jl:608–621.
- Evidence: VERIFIED-BY-EXECUTION (in-memory LLVM fixture). Replace the body of the F6 fixture by the allocation/length/data-GEP setup, then `%v = load i8, ptr @G; store i8 %v, ptr %out; ret i8 %x`; add `@G = global i8 9` and a second argument `ptr %out`, rename entry `julia_escape`. `_parsed_ir_from_ir_string(...;mem=:heap,ptr_cells=true)` accepts it and prints `IRBasicBlock(:top, IRInst[], IRRet(SSAOperand(:x),8))`: the externally visible store of 9 is entirely deleted.
- Failure scenario: a load from any non-instruction address is seeded as skeleton. Its value taints an external store. P-escape checks an address only if it is an **instruction**; an LLVM argument is not an instruction, so caller-owned `%out` falls into the purported “global/constant object-init” exception. Writes to globals are also admitted without proving ownership.
- Fix: classify arguments, globals, constants and instructions separately; require proven private allocation provenance for every dropped write. Reject a pointer argument or mutable global target. Extend the ownership proof to memcpy/memset and aliases instead of testing raw SSA membership.
- Test: the fixture above, a GEP/bitcast of `%out`, mutable globals, and a live load through an alias; extraction must reject or retain the store and preserve native effects.
- Already tracked? no matching open bead.

### F8 — [S2] MemorySSA annotations overwrite a real store definition with the preceding MemoryPhi
- Where: src/memssa.jl:80–99; src/ir_types.jl:542–553 (representation).
- Evidence: VERIFIED-BY-EXECUTION using LLVM's actual printer, not guessed formatting. `_run_memssa_on_ir` on a diamond whose `yes` arm stores 1 and whose `join` immediately stores 2 prints adjacent `; 3 = MemoryPhi({entry,liveOnEntry},{yes,1})` and `; 2 = MemoryDef(3)` before the join store (line 14). `parse_memssa_annotations` returns `def_at_line=Dict(8=>1,14=>3)`, `def_clobber=Dict(2=>3,1=>:live_on_entry)`: definition **2** exists in the graph but has no instruction location. The pending phi overwrites the pending def at the same line. Additionally, `parse_memssa_annotations("; 1 = MemoryDef(unknown)\nstore i8 1, ptr %p\n")` silently returns an empty graph.
- Failure scenario: the first instruction in a join block itself defines memory. The API cannot represent both the block's MemoryPhi and that instruction's MemoryDef in one dictionary slot; it silently loses information. Malformed/changed annotation syntax is treated as unannotated text rather than a loud format error. IDs are also function-local in LLVM's printer, while this parser has no function namespace.
- Fix: represent phis separately by function/block, defs/uses by function/instruction, and reject annotation-looking lines that do not parse. Preserve function boundaries and check graph completeness. The representation must support a phi followed immediately by a def/use.
- Test: feed the actual printed diamond, assert both IDs 2 and 3 retain their own locations; add two functions with repeated local IDs and malformed annotation cases.
- Already tracked? no matching open bead. Impact is metadata correctness today: repository search found the graph attached to ParsedIR but no lowering consumer using it for alias resolution, so this is **not** presently an executed circuit miscompile.

## Nits (S4)

## Coverage log
- Repository instructions read in full; source review starting.
