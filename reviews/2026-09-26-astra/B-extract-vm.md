# Astra review — B-extract-vm — 2026-09-26
Status: COMPLETE
Scope: src/extract/{dict_vm,vector_vm,vector_vm_walk,vector_vm_emit,vector_vm_cfg,vector_vm_term,heap,callgraph,julia_set}.jl; src/memssa.jl. Cross-scope reads limited to the certification, memcpy, dispatch and VM paths needed to check these findings.
Method: Read CLAUDE.md in full; targeted source/ADR/test review, real Julia extraction, in-memory LLVM near-miss fixtures, BennettVM execution/reversal, and an exhaustive Int8 circuit probe. Julia 1.12.3; substantive probes and individual tests used --check-bounds=yes. No full test suite, bd, commits or worklog changes. Only this report is edited, per the review-specific override.

## Executive summary
**FAIL: 13 confirmed findings — 8 S0, 2 S1, 3 S2.**
Six real-Julia VM counterexamples produce wrong behaviour and still reverse cleanly; a synthetic heap atomic-update case is wrong for all 256 Int8 inputs while reversibility passes.
The main failures are destructive skeleton suppression, lost Dict identity/control/effects, and collapsed reachable throws.
Closed-world recursion/name handling and MemorySSA capture/parsing also fail concrete probes.
All **260 existing targeted test assertions pass**. hsm3's tested non-singleton rejects pass, but the tracked singleton-identity bug remains an executed S0; Bennett-23ml's real-Julia 5viz end-to-end gate remains outstanding.

## Findings

### F1 — [S0] Vector prelude collapse deletes user returns and needed SSA definitions

- Where: src/extract/vector_vm_cfg.jl:112–156; src/extract/vector_vm_emit.jl:70–88.
- Evidence: Verified: VERIFIED-BY-EXECUTION, Julia 1.12.3, `julia --project --check-bounds=yes -e 'using Bennett; function probe(n::Int64); n == 2 && return Int8(99); v=Vector{Int8}(undef,n); s=Int8(0); for i in 1:n; v[i]=Int8(i%100); s+=v[i]; end; s; end; p=Bennett.extract_parsed_ir(probe,Tuple{Int64};optimize=false,mem=:vm); println(probe(2)); for b in p.blocks; println(b); end'`. Native output is `99`. Extraction succeeds; the synthetic entry contains only `IRAlloca(n)`, `icmp sle 1,n`, and its xor. The `n == 2` test and `ret 99` are absent. The only emitted return is the loop sum (1+2 = 3).
- Failure scenario: a valid Vector routine with a guard return before allocation loses that guard and executes the allocation/loop instead. `_vec_vm_prelude_blocks` marks **all** entry-reachable blocks before the chosen loop-bound block as prelude, including user return blocks. No check certifies those blocks as disposable machinery.
- Fix: preserve user CFG and move only positively certified allocation instructions; as an immediate safe fix reject any prelude with a user return, user branch, side effect, or surviving value definition outside the chosen exit block. Prove the chosen exit dominates the surviving body and validate SSA dominance after rewriting.
- Test: native-versus-VM execution and reversal for this function at n=0,1,2,3; also a scalar computation and a user side effect before allocation.
- Already tracked? no matching open bead.

  End-to-end confirmation: loaded the sibling BennettVM via `push!(LOAD_PATH,"../BennettVM.jl"); using BennettVM`, ran `vm=lower_vm(p); rs=initial_state(vm,Dict(p.args[1][1]=>Int64(2))); run!(rs,vm)`. The return register `:value_phi51` is **3**, native is **99**. `unrun!(rs,vm)` restores `rs.current == rs.initial` and empties history: **clean reversal does not catch this miscompile**.

- Additional execution (same root cause, S1 manifestation): `function predcalc(n::Int64); x=n+10; v=Vector{Int64}(undef,n); s=Int64(0); for i in 1:n; v[i]=x; s+=v[i]; end; s; end`. Native `predcalc(2)` is 24. Extraction and `lower_vm` succeed, but `run!` reports `unbound SSA name :__v1 ... pc: 92`. The emitted entry has no definition of `n+10`, though the store still uses it. Preserve the dependency-closed user prelude and validate dominance. Include this case and a computed allocation count in the regression tests. Verified: VERIFIED-BY-EXECUTION.

### F2 — [S0] Two different Dict objects are silently merged into one map

- Where: src/extract/dict_vm.jl:155–180, 305–345, 448–485.
- Evidence: Verified: VERIFIED-BY-EXECUTION. Define `function twodict(x::Int64,y::Int64); a=Dict{Int64,Int64}(); b=Dict{Int64,Int64}(); a[1]=x; b[1]=y; Base.@noinline getindex(a,1); end`. `Bennett.extract_parsed_ir(twodict,Tuple{Int64,Int64};optimize=true,mem=:vm)` succeeds and emits exactly `IRMapInsert(1,x); IRMapInsert(1,y); IRMapGet(result,1); ret result`. Native `twodict(11,22)` is 11; the emitted single-map program returns 22. Probed with `--check-bounds=yes` on Julia 1.12.3. The equivalent one-Dict function succeeds too; optimize=false correctly rejects the allocator shape on this Julia.
- Failure scenario: ordinary independent dictionaries with a shared key alias in ParsedIR. All dictionary identity operands are discarded. The comment at lines 168–171 promises a multi-dictionary guard in `_dict_vm_collect_ops`; **that guard does not exist**.
- Fix: prove every rewritten get/set/delete receiver is the same positively identified Dict allocation (including any identity-preserving aliases), and reject multiple receivers before discarding their operands. Alternatively add explicit map identity to the IR/backend.
- Test: two Dicts with equal keys and distinct values, querying each and deleting from only one; compare native output and verify reversal. Also reject a call whose receiver is not the recognised allocation.
- Already tracked? no matching open bead.

End-to-end confirmation: native `twodict(11,22)` returned **11**, BennettVM returned **22**, and reverse restored the initial state with empty history.

### F3 — [S0] Dict skeleton taint silently deletes arbitrary mutating helper calls

- Where: src/extract/dict_vm.jl:250–286, 316–317; compare Vector's missing-in-Dict post-taint callee check at src/extract/vector_vm_walk.jl:198–217.
- Evidence: Verified: VERIFIED-BY-EXECUTION. `@noinline function mutate!(d); d[1]=Int64(99); nothing; end; function helperdict(x::Int64); d=Dict{Int64,Int64}(); d[1]=x; mutate!(d); Base.@noinline getindex(d,1); end`. Native `helperdict(11)` returns **99**. With `optimize=true,mem=:vm`, extracted operations are insert(1,x), get(1), return; BennettVM returns **11**, and reverse restores the initial state with empty history.
- Failure scenario: `_dict_vm_skeleton` taints any instruction consuming the allocated Dict, including an unknown call. `_dict_vm_collect_ops` skips skeleton instructions before its supposedly fail-loud unknown-callee branch. The public comments at lines 69–72 explicitly promise rejection of this exact escape, but the check is unreachable for it.
- Fix: run a post-taint effect/escape audit before suppressing skeleton instructions. Reuse or generalise the Vector/heap callee allowlist checks; an unknown tainted call must reject, regardless of whether its returned SSA value is used.
- Test: a helper that changes the map and returns nothing, one that mutates a second object, and a non-mutating helper whose result is used; every unsupported case must fail at extraction, not disappear.
- Already tracked? no matching open bead.

### F4 — [S0] A user branch on Dict state is flattened and its untaken mutations execute

- Where: src/extract/dict_vm.jl:250–286, 382–403.
- Evidence: Verified: VERIFIED-BY-EXECUTION. `function condict(x::Int64); d=Dict{Int64,Int64}(); d[1]=x; if isempty(d); d[1]=99; end; Base.@noinline getindex(d,1); end`. Native `condict(11)` returns **11**. Extract at `optimize=true,mem=:vm`, lower/run on BennettVM: return **99**, clean reverse `true`.
- Failure scenario: the load of Dict count and the `isempty` comparison are skeleton-tainted, so the recogniser treats a real user conditional as a disposable allocation diamond. It emits both surviving map operations unconditionally in block-list order. Unlike F3, no unknown helper is needed: every call is an allowed map operation.
- Fix: prove that each suppressed branch controls only discarded machinery. If either arm contains a surviving map operation, preserve the branch/CFG or reject. Taint of the condition is not proof that the controlled operations are dead.
- Test: conditionals on isempty/length/haskey with set/get/delete in only one arm, including both reachable outcomes; compare map contents, returned values and reversal.
- Already tracked? no matching open bead.

### F5 — [S0] Reachable conversion failures are rewritten into successful truncated results

- Where: src/extract/vector_vm_cfg.jl:9–20; src/extract/vector_vm_term.jl:50–86; src/extract/vector_vm_walk.jl:258–289.
- Evidence: Verified: VERIFIED-BY-EXECUTION, including BennettVM and reversal. `function narrowvec(n::Int64,x::Int64); v=Vector{Int8}(undef,n); s=Int8(0); for i in 1:n; v[i]=Int8(x); s+=v[i]; end; s; end`. Native `narrowvec(1,128)` throws `InexactError`. `extract_parsed_ir(...;optimize=false,mem=:vm)` → `lower_vm` → `run!` returns **128** (the Int8 bit pattern 0x80) without any error. `unrun!` restores the initial state and empties history.
- Failure scenario: an LLVM `unreachable` terminator means that control cannot continue after a throwing/noreturn call; it does **not** prove the block cannot be entered. The recogniser marks every such block dead and unconditionally takes its sibling, even when the surviving condition is user arithmetic. The comments' claim that the guard “proved in-range / exact” is unsupported. Bounds, size, explicit-error and overflow paths share the same rewrite risk.
- Fix: preserve the guard and emit a fail-loud trap edge, or prove the throwing arm unreachable for all admitted inputs before eliminating it. Do not collapse solely on successor terminator kind. Use the closed-world generic path's trapping-unreachable representation as the baseline.
- Test: exhaustive x∈[-256,255] for this conversion, an explicit conditional throw inside the loop, n<0 allocation, and checked out-of-bounds access; both successful values and expected failures must match native Julia. Test default and --check-bounds=yes modes.
- Already tracked? no matching open bead; Bennett-i30x describes an over-rejection under bounds checking, not this silent acceptance.

### F6 — [S0] The heap M2/M3 proof explicitly permits dropping atomic read-modify-write effects

- Where: src/extract/heap.jl:1524–1536, 1875–1895; src/extract/heap.jl:2064–2065.
- Evidence: Verified: VERIFIED-BY-EXECUTION (in-memory LLVM fixture → ParsedIR). Run `Bennett._parsed_ir_from_ir_string(ir;mem=:heap,ptr_cells=true)` on the following accepted fixture:
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

Circuit confirmation: `simulate(c,Int8(5))` returned **5**; `verify_reversibility(c;n_tests=256)` returned **true**. An exhaustive sweep of all 256 Int8 values found **256 wrong results** against x+1.

### F7 — [S0] The heap escape check accepts caller-owned pointer arguments and drops writes through them

- Where: src/extract/heap.jl:701–726, 1854–1867; src/extract/heap.jl:608–621.
- Evidence: Verified: VERIFIED-BY-EXECUTION (in-memory LLVM fixture). Replace the body of the F6 fixture by the allocation/length/data-GEP setup, then `%v = load i8, ptr @G; store i8 %v, ptr %out; ret i8 %x`; add `@G = global i8 9` and a second argument `ptr %out`, rename entry `julia_escape`. `_parsed_ir_from_ir_string(...;mem=:heap,ptr_cells=true)` accepts it and prints `IRBasicBlock(:top, IRInst[], IRRet(SSAOperand(:x),8))`: the externally visible store of 9 is entirely deleted.
  The exact accepted F7 body and signature were:
  ```llvm
  @G = global i8 9
  declare ptr @ijl_gc_small_alloc(ptr, i32, i32, i64)
  define i8 @julia_escape(i8 %x, ptr %out) {
  entry:
    %m = call ptr @ijl_gc_small_alloc(ptr null, i32 0, i32 24, i64 0)
    store i64 1, ptr %m
    %d = getelementptr i8, ptr %m, i64 16
    %v = load i8, ptr @G
    store i8 %v, ptr %out
    ret i8 %x
  }
  ```
- Failure scenario: a load from any non-instruction address is seeded as skeleton. Its value taints an external store. P-escape checks an address only if it is an **instruction**; an LLVM argument is not an instruction, so caller-owned `%out` falls into the purported “global/constant object-init” exception. Writes to globals are also admitted without proving ownership.
- Fix: classify arguments, globals, constants and instructions separately; require proven private allocation provenance for every dropped write. Reject a pointer argument or mutable global target. Extend the ownership proof to memcpy/memset and aliases instead of testing raw SSA membership.
- Test: the fixture above, a GEP/bitcast of `%out`, mutable globals, and a live load through an alias; extraction must reject or retain the store and preserve native effects.
- Already tracked? no matching open bead.

### F8 — [S0] Certified empty Memory objects still give wrong observable pointer equality

- Where: src/extract/jlglobal_cert.jl:76, 367–380 (cross-scope dependency of the reviewed closed-world path); src/extract/julia_set.jl:462–482.
- Evidence: Verified: VERIFIED-BY-EXECUTION. `const EM1=Memory{Int64}(); const EM2=Memory{UInt8}(); eqmem(x::Int64)=Int64(pointer(EM1)==pointer(EM2))+x`. `extract_parsed_ir(eqmem,Tuple{Int64};optimize=false,ptr_cells=true)` → `lower_vm` → `run!` returns **6** for x=5; native returns **5**. Reverse restores the initial state and empties history. Both literals genuinely pass hsm3 certification; this is not a non-singleton falsely passing the membership test.
- Failure scenario: every distinct empty Memory data pointer is represented by the same `_EMPTY_MEMORY_DATA_SENTINEL`. Comparing two genuinely different native data pointers therefore yields equality on the VM.
- Fix: assign stable distinct synthetic identities to each certified singleton data pointer, consistent across functions, or reject any observation requiring identity beyond the supported null/non-null distinction. Keep the non-null/trapping property.
- Test: equal and unequal singleton types in one function and across a call boundary, pointer equality/inequality, returned Boolean and reversal.
- Already tracked? **Bennett-eqjl**. Its description is correct. This executes its first half as a current S0 wrong result; its P3/corpus-only framing understates demonstrated impact. The separate per-function object-window half was not executed here.

### F9 — [S1] Recursive roots are re-added as callees and rejected as duplicate canonical keys

- Where: src/extract/callgraph.jl:100–113, 124–136; src/extract/julia_set.jl:475–493.
- Evidence: Verified: VERIFIED-BY-EXECUTION. `@noinline rec(n::Int64)=n==0 ? 0 : rec(n-1)+1`. `any(x->x[1]===typeof(rec),Bennett.transitive_callees(rec,Tuple{Int64}))` prints `true`, contradicting the API's “ROOT ... EXCLUDED” contract. `extract_parsed_ir_set_from_julia(rec,Tuple{Int64})` fails with `duplicate canonical key rec#dcc408c3 — a hash collision or a re-extracted callee leaked through`.
- Failure scenario: a finite self-recursive or mutually recursive typed callgraph contains the root. `visited` starts empty, so the root is extracted as a callee and again as the root. This blocks a valid closed-world graph before the VM can handle the call.
- Fix: initialise the traversal's visited set with the root, excluding it from the returned order (and similarly from the helper's output). Preserve root registration for recursive calls separately; ensure include_root=false has an explicit contract for recursive roots.
- Test: self and mutual recursion, exact one-root set membership, native-versus-VM results and clean reversal for bounded input values.
- Already tracked? Bennett-t7zu mentions recursive sret/circuit lowering, but does not describe this graph-enumeration/duplicate-key defect; no matching open bead.

### F10 — [S1] Mixed-case callee names fail during otherwise valid closed-world extraction

- Where: src/extract/julia_set.jl:235–238, 440–456; src/extract/callees.jl:74–89 (cross-scope lookup).
- Evidence: Verified: VERIFIED-BY-EXECUTION. `@noinline Upper(x::Int64)=x+1; rootupper(x::Int64)=Upper(x); extract_parsed_ir_set_from_julia(rootupper,Tuple{Int64})` fails at the root with `call to j_Upper_1050 has no registered callee handler ... Bennett-5oyt / U15`, even though the producer just registered Upper. `_demangle_callee_symbol` separately lowercases its capture.
- Failure scenario: the registry preserves case while lookup folds the query; the typed callgraph itself contains the correct function. Valid functions with uppercase/mixed-case helper names are rejected with the misleading instruction to register a callee already registered by this API.
- Fix: preserve Julia symbol case during prefix/suffix demangling and use one shared routine throughout lookup and the closed-world check.
- Test: noinline uppercase helpers, mixed-case closure method names, and two case-distinct functions; all must bind to the intended body or explicitly reject genuine ambiguity.
- Already tracked? **Bennett-wh1p**; both parts of its description are correct. Executed symptom here is loud failure, not a silent wrong binding.

### F11 — [S2] Skip mode can return an empty “closed-world” program without disclosing the skipped root

- Where: src/extract/julia_set.jl:388–407, 478–485, 504–506.
- Evidence: Verified: VERIFIED-BY-EXECUTION. `plain(x::Int64)=x; ss=Bennett.extract_parsed_ir_set_from_julia(plain,Tuple{Int64};mem=:vm,on_extract_error=:skip); println(isempty(ss))` prints `true`. The root fails the mem=:vm recogniser, is appended only to a local `skipped` list, and that list is neither returned nor logged; the closure check over the empty vector passes vacuously.
- Failure scenario: a caller explicitly tolerating unsupported *callees* cannot distinguish a usable set from loss of the requested entry. A nonempty returned subset can similarly start with an unrelated helper when the root was skipped.
- Fix: require successful root extraction when include_root=true, reject an empty set, and return structured diagnostics for intentionally skipped non-root bodies. Do not describe a partial result as complete.
- Test: the one-line reproducer, root-fails/helper-succeeds, include_root=false, and ordinary successful sets.
- Already tracked? **Bennett-9tg3**; description and root-absent scenario are correct.

### F12 — [S2] MemorySSA printing deadlocks when its undrained stderr pipe fills

- Where: src/memssa.jl:123–142.
- Evidence: Verified: VERIFIED-BY-EXECUTION. With `timeout -k 2 75 julia --project --check-bounds=yes -e ...`, `_run_memssa_on_ir("define i64 @small(ptr %p) {\nentry:\n store i64 1, ptr %p\n %a = load i64, ptr %p\n ret i64 %a\n}\n";preprocess=false)` prints `small_bytes=188`. Then construct `big="define i64 @big(ptr %p) {\nentry:\n" * join([" store i64 $i, ptr %p\n %x$i = load i64, ptr %p\n" for i in 1:2000]) * " ret i64 %x2000\n}\n"`. It prints `big_input_bytes=99837`; the subsequent `_run_memssa_on_ir(big;preprocess=false)` never returns before timeout (exit 124). No sandbox execution block occurred. An earlier timeout during default-mode precompilation was discarded as evidence; this rerun reached both explicit progress prints.
- Failure scenario: `use_memory_ssa=true` on a moderately large function/module hangs inside LLVM's printer. Reading starts only after `LLVM.run!` returns; LLVM blocks when the finite pipe buffer fills.
- Fix: drain the pipe concurrently with a mechanism that continues running while the LLVM call blocks, or capture into a seekable temporary stream; guarantee pipe and module disposal on errors. Serialise process-wide stderr redirection if concurrent calls are allowed.
- Test: a bounded local test with annotation output larger than pipe capacity, asserting completion and all expected definitions/uses, plus exception cleanup.
- Already tracked? no matching open bead.

### F13 — [S2] MemorySSA annotations overwrite a real store definition with the preceding MemoryPhi

- Where: src/memssa.jl:80–99; src/ir_types.jl:542–553 (representation).
- Evidence: Verified: VERIFIED-BY-EXECUTION using LLVM's actual printer, not guessed formatting. `_run_memssa_on_ir` on a diamond whose `yes` arm stores 1 and whose `join` immediately stores 2 prints adjacent `; 3 = MemoryPhi({entry,liveOnEntry},{yes,1})` and `; 2 = MemoryDef(3)` before the join store (line 14). `parse_memssa_annotations` returns `def_at_line=Dict(8=>1,14=>3)`, `def_clobber=Dict(2=>3,1=>:live_on_entry)`: definition **2** exists in the graph but has no instruction location. The pending phi overwrites the pending def at the same line. Additionally, `parse_memssa_annotations("; 1 = MemoryDef(unknown)\nstore i8 1, ptr %p\n")` silently returns an empty graph.
  Exact LLVM input passed to `_run_memssa_on_ir(ir;preprocess=false)`:
  ```llvm
  define void @a(ptr %p, i1 %c) {
  entry:
    br i1 %c, label %yes, label %join
  yes:
    store i8 1, ptr %p
    br label %join
  join:
    store i8 2, ptr %p
    ret void
  }
  ```
- Failure scenario: the first instruction in a join block itself defines memory. The API cannot represent both the block's MemoryPhi and that instruction's MemoryDef in one dictionary slot; it silently loses information. Malformed/changed annotation syntax is treated as unannotated text rather than a loud format error. IDs are also function-local in LLVM's printer, while this parser has no function namespace.
- Fix: represent phis separately by function/block, defs/uses by function/instruction, and reject annotation-looking lines that do not parse. Preserve function boundaries and check graph completeness. The representation must support a phi followed immediately by a def/use.
- Test: feed the actual printed diamond, assert both IDs 2 and 3 retain their own locations; add two functions with repeated local IDs and malformed annotation cases.
- Already tracked? no matching open bead. Impact is metadata correctness today: repository search found the graph attached to ParsedIR but no lowering consumer using it for alias resolution, so this is **not** presently an executed circuit miscompile.

## Unconfirmed suspicions

- **Vector backing provenance / GEP geometry:** `_vec_vm_skeleton` matches any GEP immediately based on any `julia.gc_loaded`, checks the offset-multiply constant, but does not certify that the launder's arguments derive from the recognised allocation or that the GEP source element type is i8. It also does not assert the `extractvalue` index in `_vec_vm_size_chain`. A real mixed external-array/local-array probe was rejected first by the existing multi-index GEP wall. These are unconfirmed avenues, not additional S0 findings.
- **Phi rewriting beyond tested shapes:** `_vec_vm_phi` maps every prelude predecessor to entry without deriving the final predecessor graph. Exact incoming-set checks passed for tested early-return, break and nested-diamond routines; no distinct wrong-phi example was confirmed. F1 does confirm the related dominance failure from deleted definitions.
- **M3 data roots:** `_m3_element_accesses` seeds every integer load/store narrower than 64 bits, and phi closure treats every connected incoming as the same data-root family. I did not obtain an accepted real-Julia counterexample merging unrelated roots. The clear atomic/escape failures are reported separately in F6/F7.
- **Symbol-path ambiguity:** `_closed_world_check!` accepts a bare Symbol with multiple canonical candidates, unlike its Function path. Bennett-zuk5's description is correct by inspection; this review did not bypass the documented upstream/downstream rejection walls to demonstrate a wrong binding.
- No non-singleton was found that passed hsm3's live-address membership test. F8 concerns the representation of *correctly certified* singletons, not a classifier false positive.

## What is sound (brief)

- The hsm3 repair replaces name-based trust with membership in the live empty-GenericMemory singleton set, checks constant pointer slots, defaults to refusal for non-live ingest, uses distinct slot/object keys, and places the use-directed backstop around every producer. Preserve these checks. The Ref/nonempty-Memory/tuple/alias near-miss tests passed (119/119).
- The 5viz source path checks semantic certification, that the source load has already been retired onto its object key, const offset/alignment/capacity, and canonicalises in the stripped value's defining block. All 103 existing tests passed. An additional K=2 in-memory LLVM → ParsedIR → BennettVM probe copied the length/data fields from a certified singleton, returned 6 for `x=5 + is_nonnull(data)`, and reversed cleanly. This is a useful positive check but does not fulfil the real-Julia closure-environment gate in Bennett-23ml.
- A single Dict with keys 1 and 23 (same low four native hash bits: bucket 14), values 11/22, and a query of key 1 returned 11 on native and VM and reversed cleanly. This positive collision case does not excuse the identity/control/effect defects above.
- Single-backing integer Vector probes retained 8/32/64-bit traffic for UInt8/Int8/Int32/Int64. Struct elements rejected loudly. A Bool wrapper probe rejected before recognition; this review makes no claim of working Bool support.
- A loop with `break` returned the native result 3 at n=4 and reversed cleanly. For separate early-return, break and nested-diamond Vector routines, every phi's incoming predecessor set exactly matched the emitted CFG. A literal early return *inside* the loop was retained by extraction but refused by BennettVM's existing literal-return limitation; it is not the deletion in F1.
- The typed-callgraph walk has a finite-node cap, explicit version-shape rejection for invoke targets, and an explicit incomplete-graph boundary backed by the set check. The local registry restore uses finally. These are useful safeguards despite the root and name bugs.

## Nits (S4)

- `julia_set.jl:18–19` calls canonical keys deterministic across processes, whereas lines 198–207 correctly say the digest is only process-local. The registration header also predates scoped restoration.
- `heap.jl` still describes an exactly-one-allocator M1-only entry contract although the entry dispatches M1/M2/M3. `_GC_LAYOUT_*` comments claim layout constants are asserted, but `_assert_memory_layout` only checks pointer/word size and the Julia minor version.

## Coverage log

- **Read:** all named recogniser/CFG/callgraph/multi-IR/memssa functions; heap M1 seed/closure/proof, M2 allocation/capacity/bounds/partition/re-rooting, M3 data roots/growend diamonds/phi redirects/proof and M4 scope guards. The long historical prose was sampled, not treated as evidence.
- **Cross-scope:** jlglobal_cert membership, GC window, slot/object seeding and refusal backstop; `_5viz_singleton_load`, `_5viz_global_src_root` and loaded-source memcpy predicates/emission; module_walk routing/final checks; entry ingest and callee lookup; BennettVM round-trip API and selected ADRs 0008, 0016, 0017, 0021. No claim of a full review of instructions.jl or BennettVM.
- **Prior work checked:** open-beads.txt and relevant .beads/issues.jsonl entries; worklog 108 hsm3/gcf7 closeout and 103–106 wall history; c1 extraction review and c5 recogniser/MemorySSA discussion. Their warning about fragile recognisers is justified, but c1's assertion that these recognisers fail loud instead of miscompiling is refuted by the executed examples here.
- **Individual tests:** `test/test_jfw6_vec_vm_extract.jl` 23/23, `test/test_hsm3_jlglobal_certification.jl` 119/119, `test/test_5viz_loaded_ptr_src_memcpy.jl` 103/103, all with `julia --project --check-bounds=yes`. `test/test_memssa.jl` also passed 15/15: **260/260 existing assertions** across the four files.
- **Known tracker adjudication:** Bennett-eqjl, Bennett-wh1p and Bennett-9tg3 are confirmed above. Bennett-21rj remains accurate: recogniser returns bypass `_check_scale_coherence!` (module_walk:733), even though hsm3's refusal check now wraps them. Bennett-23ml remains outstanding: the real push! closed-world producer still stops at the uncertified aggregate-alloca store wall after the 5viz site; resize! stops at an unsupported loaded-source memcpy. This review did not complete or modify those features.
- **Scope limits:** no Julia 1.13/other-architecture execution; no full suite, statistical fuzzing or large-size Vector run; no exhaustive callgraph-world-age or concurrency campaign; no nonempty raw-heap-literal representation. Each S0–S2 entry is execution-backed, with synthetic-versus-real inputs identified explicitly.
- **Reproduction convention:** VM probes loaded `Bennett`, then `push!(LOAD_PATH,"../BennettVM.jl"); using BennettVM`. Given a ParsedIR p and scalar argument values xs: `vm=lower_vm(p); rs=initial_state(vm,Dict(p.args[i][1]=>xs[i] for i in eachindex(xs))); run!(rs,vm)`. Read `result(rs)` at the `IRRet.op.name` register. Then `unrun!(rs,vm)` and check `rs.current==rs.initial && isempty(rs.history)`. In-memory LLVM fixtures use `_parsed_ir_from_ir_string`; their function names begin `julia_` so the ordinary entry finder selects them. Test snippets are in this report rather than new files.
