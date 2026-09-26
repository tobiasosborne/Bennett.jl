# Astra review — B-extract-core — 2026-09-26
Status: COMPLETE
Scope: src/ir_extract.jl; src/extract/{entry,callees,callgraph,julia_set,errors,sret,module_walk,instructions,heap,constexpr,vectors,helpers,target_pin}.jl; src/{ir_types,callees,memssa,ir_parser}.jl.
Method: Read-only source audit, inherited-finding re-verification, targeted Julia 1.12.3 / LLVM 18 probes with --compiled-modules=existing --check-bounds=yes, one standalone poison-lane test file, and pinned-target subprocess comparisons. Read the supplied open-bead snapshot and relevant .beads/issues.jsonl records. No full suite, issue-tracker commands, or source changes. This report is the only file intentionally written.

## Executive summary

26 findings: **15 S0, 7 S1, 4 S2**. All 17 inherited findings reproduced; this continuation added nine findings.

The highest risks are erased memory effects, incorrect sret/callee substitution, conflated LLVM identities, wrong numeric/address conversions, and stale circuits after method redefinition. A valid nested constant array crashes Julia.

Every S0 has an executed counterexample. Overall, 25 findings are execution-verified; the weak-symbol folding finding is REASONED-ONLY with executed extractor evidence.

Pinned-target comparisons, poison-lane tests and live literal certification passed their targeted checks. Those successes do not cover the separate type-tag interner or the failing memory conversions.

## Findings

Ranked by severity; original finding IDs are retained for cross-references.

### F1 — [S0] Bare-name callee registration substitutes a different module's function
- Where: `src/extract/callees.jl:14–19,75–89`; `src/extract/instructions.jl:6849–6871`.
- Evidence: VERIFIED-BY-EXECUTION (Julia 1.12.3, `--check-bounds=yes`). Define `module ReviewA; Base.@noinline same(x::Int8)=x+Int8(1); end`, `module ReviewB; Base.@noinline same(x::Int8)=x+Int8(2); end`, and `f(x::Int8)=ReviewA.same(x)`. After `Bennett.register_callee!(ReviewB.same)`, `Bennett.extract_parsed_ir(f,Tuple{Int8})` prints `IRCall(:__v1, Main.ReviewB.same, …, [8], 8)` although the source calls ReviewA. `c=Bennett.reversible_compile(f,Int8)` gives `(native = 8, circuit = 9, reversible = true)` for input `Int8(7)` (`verify_reversibility(c;n_tests=16)`).
- Failure scenario: registering a function with the same bare name as an unrelated function changes what that unrelated caller computes. Module identity and the requested MethodInstance are absent from the lookup; registration silently overwrites an existing name.
- Fix: resolve LLVM call symbols to the exact method/specialization emitted for this extraction; pass that mapping in an extraction context. Until then reject ambiguous registrations and calls rather than silently selecting the last registered function. Include module identity and full signature in linkage, not just a bare name.
- Test: two modules with same-named `@noinline` functions; compile a caller of each in both registration orders and exhaust all 256 Int8 inputs, checking both oracle output and ancilla restoration.
- Already tracked? No matching open bead. `docs/design/rearch-2026-08/c1-extraction.md` §5c correctly identifies the collision risk, but incorrectly describes current lookup as substring matching: it is an exact lookup after demangling, still keyed only by bare name. Bennett-wh1p tracks the distinct case-folding bug.

### F2 — [S0] Zero-fill memset is deleted even when it overwrites live data
- Where: `src/extract/instructions.jl:4693–4715` (`c_int == 0 && return IRInst[]`).
- Evidence: VERIFIED-BY-EXECUTION. The following in-memory module extracts to alloca/store/load with **no memset or replacement stores**. `p=Bennett._parsed_ir_from_ir_string(ir); c=Bennett.reversible_compile(p); simulate(c,UInt8(42))` returns `0x2a`, expected `0`; `verify_reversibility(c;n_tests=16)` is `true`.
  ```llvm
  declare void @llvm.memset.p0.i64(ptr,i8,i64,i1)
  define i8 @julia_zero(i8 %x) {
  entry:
    %p = alloca i8
    store i8 %x, ptr %p
    call void @llvm.memset.p0.i64(ptr %p,i8 0,i64 1,i1 false)
    %r = load i8, ptr %p
    ret i8 %r
  }
  ```
- Failure scenario: any zeroing after a write, including clearing a reused buffer, keeps the previous contents. The bypass also precedes volatility and destination/provenance checks; zero fills receive weaker checks than nonzero fills.
- Fix: permit a no-op only after proving the exact written region is already zero and the operation has no volatile effect. Otherwise emit real stores through the memory model or reject unsupported overwrites. Put volatile validation before the zero-fill branch.
- Test: initialize an alloca from each Int8 input, zero all/part of it, then read; also cover non-fresh destinations and volatile zero fills. Compare outputs and ancilla restoration.
- Already tracked? Bennett-zmry (open; the real ID behind the notional `Bennett-8bys-uncompute`) explicitly includes the same `store; memset(0); load→0` acceptance test and correctly identifies the missing destructive-zeroing behavior. Its deferred-feature framing understates the actively accepted miscompile. Bennett-9nwt and Bennett-8su4 (closed) deliberately retained the zero/volatile bypass for GC frames; extending that rationale to arbitrary destinations is unsound.

### F12 — [S0] Heap classification drops writes to live element data as “GC machinery”
- Where: `src/extract/heap.jl:590–594,1521–1536,1795–1799,1834–1841,1873–1895,2061–2062`.
- Evidence: VERIFIED-BY-EXECUTION. A one-element recognized Memory skeleton containing `store i8 %x,ptr %data; call void @llvm.memset.p0.i64(ptr %data,i8 7,i64 1,i1 false); %r=load i8,ptr %data` compiles under `mem=:heap` to just the original store/load. Input 42 prints `(got = 0x2a, want = 7, reversible = true)`. This is a **nonzero** fill, so it is separate from F2's zero-fill fast path. An additional mutation of the checked-in heap fixture is recorded below.
- Continuation verification: read `test/fixtures/heap_m2_cond_pair.ll` into a String, replace `  %3 = load i8` with `  call void @llvm.memset.p0.i64(ptr %memory_data,i8 7,i64 1,i1 false)\n  %3 = load i8`, and compile with `_parsed_ir_from_ir_string(modified;mem=:heap)`. Input `Int8(42)` returns 42, expected 7, reversibility true. Repeating with `%old=atomicrmw xchg ptr %memory_data,i8 7 monotonic` yields the same wrong 42. Both distinct effect families are executed, not merely suspected.
- Failure scenario: every memset is seeded as skeleton and every skeleton call is classed as machinery; the allowlist accepts memset without checking whether its destination is GC storage or the live element region. O1/O2 inspect only LLVMStore/LLVMLoad, leaving bulk writes outside the proof. The M2 forbidden-opcode list also excludes AtomicRMW wholesale on the assumption that it is GC bookkeeping.
- Fix: classify all memory-writing instructions by destination provenance and effect. Only suppress certified GC-frame/tag operations. Lower or reject memset/atomicrmw on element data, and include call memory effects in the partition obligations.
- Test: insert nonzero memset and atomicrmw into `test/fixtures/heap_m2_cond_pair.ll` immediately before `%3 = load i8`, with `%memory_data` as destination. Verify data effects survive or extraction rejects; check oracle output and ancillae for accepted forms.
- Already tracked? No matching open issue. This refutes c1-extraction's blanket description of heap recognizers as safely subtractive fail-loud partitions.

### F3 — [S0] Sret return-funnel deletion removes live instructions and changes the returned aggregate
- Where: `src/extract/sret.jl:953–959`; `src/extract/module_walk.jl:522–525,578–597,680–695`.
- Evidence: VERIFIED-BY-EXECUTION. Extracting and compiling this module with the same in-memory helper as F2 gives `(got = 0x03, want = 99, reversible = true)` for `UInt8(3)`. ParsedIR contains only an insertvalue of `%x` and a return; the modifying call disappears.
  ```llvm
  define void @mutate(ptr %p) {
  entry:
    store i8 99, ptr %p
    ret void
  }
  define void @julia_sret(ptr sret([1 x i8]) %out, i8 %x) {
  entry:
    store i8 %x, ptr %out
    br label %common
  common:
    call void @mutate(ptr %out)
    ret void
  }
  ```
- Failure scenario: any `ret void` block without a directly recognized sret store is classified as a disposable funnel. Such a block may still modify the return through a call, write other memory, trap, or perform another observable operation. Checking only its terminator and absence from the direct-store map proves none of these operations dead.
- Fix: eliminate only a certified empty funnel (or explicitly proven inert instructions). Preserve the funnel and carry aggregate values through it when it has effects; reject unsupported sret-pointer escape to a call. Check every sret pointer use, not just stores/GEPs.
- Test: the module above, plus a funnel with an unrelated memory store or trapping call, should execute faithfully or fail during extraction. Retain the existing truly empty shared-return-funnel tests.
- Already tracked? No. Bennett-jghk (closed) introduced the per-block/funnel scheme; this contradicts its claim that only store-free return plumbing is dropped.

### F8 — [S0] ParsedIR naming conflates distinct LLVM values
- Where: `src/extract/callees.jl:164–168`; `src/extract/module_walk.jl:277–280,344–348,1061`; `src/extract/instructions.jl:7163–7173`; intrinsic/scalarization users of `_auto_name`.
- Evidence: VERIFIED-BY-EXECUTION. `define i8 @julia_names(i8 %__v1) { entry: %0=add i8 %__v1,1 %r=add i8 %0,%__v1 ret i8 %r }` extracts the unnamed `%0` as **the same** `:__v1` symbol as the input. The second add then uses the first add's result twice. Input `UInt8(3)` prints `(got = 0x08, want = 7, reversible = true)`.
- Failure scenario: `%__vN` is a legal LLVM source name. The counter never reserves existing names; first-pass unnamed instructions and synthetic expansion temporaries can overwrite parameters or named results in ParsedIR. This is a concrete valid-IR SSA corruption, independent of any malformed input.
- Additional VERIFIED-BY-EXECUTION namespace collision: `@p=constant [1 x i8] [i8 99]` plus `define i8 @julia_ns(ptr dereferenceable(1) %p,i8 %idx){entry: %q=getelementptr i8,ptr %p,i8 %idx %r=load i8,ptr %q ret i8 %r}`. `@p` and `%p` are distinct LLVM namespaces but both become `:p`. The QROM lookup selects the unused global instead of the pointer input: `simulate(c,(UInt8(42),UInt8(0))) == 99`, expected 42, reversibility true.
- Fix: allocate every ParsedIR identity through a collision-free namespace that distinguishes global values, local values, basic blocks and generated temporaries. Reserving only source local names fixes the auto-name witness but not the global/local collision. Prefer opaque internal identities with source names retained for diagnostics. Apply the same policy to synthetic switch labels/compare names.
- Test: named `%__v1` parameters/results combined with unnamed LLVM values and intrinsic-created temporaries; exhaust Int8 inputs and verify output plus ancilla restoration.
- Already tracked? No matching issue found.

### F11 — [S0] Recompilation after a Julia method redefinition returns the old circuit
- Where: `src/extract/callees.jl:37–61`; public compilation routes through `_extract_parsed_ir_cached`.
- Evidence: VERIFIED-BY-EXECUTION. Define `cache_review(x::Int8)=x+Int8(1)`, compile it and simulate input 3 (output 4). Redefine the same method as `x+Int8(2)` and call `reversible_compile(cache_review,Int8)` again. Printed result: `(native = 5, compiled = 4, reversible = true)`.
- Failure scenario: the cache key contains the Function object/type/options, which do not change when the method body changes. The cache now serves public user functions, not just stable package primitives. A fresh compile request silently uses stale source semantics.
- Fix: include method/world validity in the cache key and invalidate downstream circuit caches when relevant methods or dependencies change; alternatively limit caching to explicitly immutable primitives or provide an explicit opt-in cache with documented invalidation. Method identity alone is insufficient if an inlined dependency is redefined.
- Test: redefine a root method and a noinline/inlined dependency between compiles; both fresh circuits must match current Julia execution and restore ancillae.
- Already tracked? Bennett-ej4n/Bennett-uiaq (closed) introduced and extended caching. The source documents a manual internal clear helper, but no matching open correctness issue covers stale public recompilation.

### F4 — [S0] Funnel-shift expansion returns a OR b at zero dynamic shift
- Where: `src/extract/instructions.jl:4987–5033`; interacts with the barrel-shift count masking in `src/lowering/arith.jl`.
- Evidence: VERIFIED-BY-EXECUTION. Extract `declare i8 @llvm.fshl.i8(i8,i8,i8)` plus `define i8 @julia_f(i8 %x,i8 %y,i8 %s) { entry: %r=call i8 @llvm.fshl.i8(i8 %x,i8 %y,i8 %s) ret i8 %r }`. After compilation, `simulate(c,(UInt8(0x12),UInt8(0x34),UInt8(s)))` prints `0x36` for `s=0,8,16`, expected `0x12`; `s=1,9` gives the correct `0x24`. `verify_reversibility(c;n_tests=16)` returns `true`. A first probe with equal operands (rotate) passed, illustrating the coverage trap.
- Failure scenario: `fshl(a,b,s)` must use `s mod W` and return `a` when that is zero (`fshr` must return `b`). The expansion emits both shifts, including a shift by W. Dynamic gate shifts mask that count to zero, so both original operands are ORed. The constant-count branch also omits explicit modulo normalization.
- Fix: reduce the unsigned shift amount modulo W and explicitly select `a`/`b` for the zero case; expand only nonzero shifts into the pair of shifts. Do not depend on backend behavior for shifts by W. Support non-power-of-two widths with remainder or reject them explicitly.
- Test: distinct operands, both fshl/fshr, every i8 shift count including 0/W/2W/255, and constant versus dynamic count parity; check output and ancilla restoration. Include a supported non-power-of-two scalar width if that remains accepted.
- Already tracked? No matching issue in the supplied issue JSONL/open list.

### F5 — [S0] Packed i1 vector loads read bit zero for every lane
- Where: `src/extract/vectors.jl:825–846` (`eb = w ÷ 8` and `(i-1)*eb`).
- Evidence: VERIFIED-BY-EXECUTION. Extract and compile `define i1 @julia_vload(ptr dereferenceable(1) %p) { entry: %v=load <8 x i1>,ptr %p,align 1 %r=extractelement <8 x i1> %v,i32 1 ret i1 %r }` using the in-memory helper from F2. ParsedIR emits eight `IRPtrOffset(_,ssa(:p),0,1)` nodes, all at offset zero. Input `UInt8(2)` yields `(got = 0, want = 1, reversible = true)`.
- Failure scenario: `<8 x i1>` is a packed byte; lane 1 reads bit 1. Since the lane stride truncates to zero, every lane aliases bit 0. This reaches a complete circuit and silently computes the wrong boolean.
- Fix: reject sub-byte vector memory operations until the extractor can load the packed storage and extract bit ranges with correct target endianness. For supported byte-sized lanes, derive offsets from the datalayout rather than assuming every vector lane has a whole-byte stride.
- Test: all 256 byte patterns, all eight lane selections, and packed-vector bitcasts, checking native LLVM results and ancilla restoration.
- Already tracked? No matching issue. Bennett-0c8o is the closed vector-load/sret support bead.

### F6 — [S0] Float-to-integer conversion of f32 is accepted as a bit-preserving integer cast
- Where: `src/extract/instructions.jl:7751–7796`, especially the fallback at 7773 and sibling integer-to-float fallback at 7796.
- Evidence: VERIFIED-BY-EXECUTION. `define i32 @julia_f32(i32 %bits) { entry: %f=bitcast i32 %bits to float %r=fptosi float %f to i32 ret i32 %r }` extracts to two `IRCast(:trunc,32,32)` operations. Compiling and simulating on `UInt32(0x3fc00000)` (1.5f0) prints `(got = 0x3fc00000, want = 1, reversible = true)`.
- Failure scenario: a defined, in-range numeric conversion returns the raw IEEE encoding, not the integer 1. The same fallback pattern affects fptoui and unsupported sitofp/uitofp destination widths; rejecting top-level `reversible_compile(f,Float32)` does not protect raw-IR inputs or f32 intermediates in integer-signature functions.
- Fix: replace unsupported numeric-conversion fallbacks with contextual errors. Implement genuine conversion semantics before admitting these widths; a trunc/zext bitcast is never a substitute for FP conversion.
- Test: f32 1.5/−1.5/0 and representable limits through bit-pattern input/output wrappers; unsupported widths must reject at extraction, not silently become IRCast.
- Already tracked? Bennett-3wk7 (open) describes this accurately, but P3 understates an executed S0 miscompile.

### F7 — [S0] uitofp i64 dispatches to signed conversion for values above 2^63−1
- Where: `src/extract/instructions.jl:7777–7792`; `src/callees.jl:69–71`.
- Evidence: VERIFIED-BY-EXECUTION. `define i64 @julia_ui(i64 %x) { entry: %f=uitofp i64 %x to double %r=bitcast double %f to i64 ret i64 %r }` emits `IRCall(soft_sitofp, …, [64],64)`. Circuit input `typemax(UInt64)` returns bits `bff0000000000000` (−1.0), expected `43f0000000000000` (rounded 2^64); `verify_reversibility(c;n_tests=4)` returns `true`.
- Failure scenario: all high-bit-set unsigned 64-bit operands are interpreted as negative signed integers. Narrower unsigned values happen to work after zero extension; the full-width branch loses signedness entirely.
- Fix: add a real unsigned conversion primitive/expansion and distinguish LLVMUIToFP from LLVMSIToFP in dispatch; reject full-width unsigned conversion until implemented.
- Test: 0, 2^53±1, 2^63−1, 2^63, 2^64−1, comparing result bits to `Float64(::UInt64)` and checking reversibility.
- Already tracked? Bennett-tfx mentions “uitofp-edge” as deferred; this is an actively accepted wrong result, not merely a missing operation. Bennett-1la (closed) claims actual sitofp/uitofp conversion, but full-width unsigned conversion remains incorrect.

### F13 — [S0] Integer GEP scaling uses bit width instead of LLVM allocation size
- Where: `src/extract/instructions.jl:7143–7149,7165–7173` (also width-derived offsets in `_global_root_and_offset`).
- Evidence: VERIFIED-BY-EXECUTION. Extract `target datalayout="e-i24:32"` plus `define i8 @julia_gep(ptr dereferenceable(8) %p){ entry: %q=getelementptr i24,ptr %p,i64 1 %r=load i8,ptr %q ret i8 %r }`. ParsedIR reports `IRPtrOffset(:q,ssa(:p),3,24)`, but the target's i24 allocation stride is 4 bytes. Input `UInt64(0x0000009907000000)` prints `(got = 7, want = 0x99, reversible = true)`.
- Failure scenario: non-power-of-two integer widths or custom datalayout alignment introduce padding between elements. `width ÷ 8` truncates storage width and ignores ABI allocation alignment. Pointer arithmetic then reads another byte while all circuit invariants pass.
- Fix: derive GEP strides from LLVM's allocation-size/datalayout API, and preserve that stride separately from value bit width. Reject layouts the current IRVarGEP representation cannot express instead of assuming packed storage.
- Test: i9/i24 arrays and scalars, constant/runtime indices, custom integer alignment and normal i8/i16/i32/i64 controls; compare byte-addressed native LLVM results.
- Already tracked? Bennett-0ucg covers the analogous **non-integer** raw-index branch, not this integer-type ABI-stride error.
- The adjacent tracked non-integer bug also reproduces: `getelementptr float,ptr %p,i64 1` from `ptr dereferenceable(8) %p` emits byte offset 1 instead of 4; load i8 on input `UInt64(0x0000009900000700)` returns 7 rather than 153, reversibility true. Bennett-0ucg's description is correct and applies to the circuit path as well as cell-scale checking.

### F19 — [S0] Type-tag interning turns a non-null type pointer into null
- Where: `src/extract/module_walk.jl:185–197`; `src/extract/instructions.jl:7480–7487,6296–6304`.
- Evidence: VERIFIED-BY-EXECUTION. Under `ptr_cells=true`, extract `@"+Main.Core.Int8#1" = constant ptr inttoptr (i64 1234 to ptr)` followed by `define i1 @julia_tag(i8 %x){ entry: %tag=load ptr,ptr @"+Main.Core.Int8#1" %r=icmp eq ptr %tag,null ret i1 %r }`. ParsedIR contains `IRBinOp(:tag,:or,iconst(0),iconst(0),64)` and compares it to null's `iconst(0)`. Compilation returns 1 for input `UInt8(1)`, expected 0, with reversibility true. No dereference of address 1234 occurs or is needed: equality with null is fully defined.
- Failure scenario: the first type in a function is assigned `length(tag_ids)==0`, colliding with the null-cell encoding. Moreover `tag_ids` is recreated for each function, so distinct first-seen types in separately extracted callees share identity while the same type can receive different IDs in different bodies. The null collision is already sufficient for a complete miscompile.
- Fix: reserve null and other pointer namespaces, allocate nonzero type identities consistently for the entire closed-world set, and preserve type provenance or a semantic type-ID operand through linkage. Reject arithmetic/escaping type IDs if those operations are not part of the supported abstraction. Validate the type-tag global's shape before replacing its load.
- Test: non-null type tag compared to null; two different types compared within/across functions; same type encountered in different orders across functions. Check extracted IDs and actual equality results, with ancilla checks on circuit-compatible cases.
- Already tracked? No matching open bead. Bennett-iwo9 introduced the interner; Bennett-eqjl concerns empty-Memory singleton identities, a different identity namespace.

### F24 — [S0] ConstantExpr inttoptr folding sign-extends narrow unsigned addresses
- Where: `src/extract/constexpr.jl:242–253`; `src/extract/helpers.jl:124–132`.
- Evidence: VERIFIED-BY-EXECUTION. With `target datalayout="e-p:64:64"`, extract `define i1 @julia_cast(i8 %x){entry: ret i1 icmp eq (ptr inttoptr (i32 -1 to ptr),ptr inttoptr (i64 4294967295 to ptr))}`. ParsedIR returns constant 0; circuit input `UInt8(0)` returns 0 with reversibility true. Both LLVM pointer values are 0x00000000ffffffff, so the correct answer is 1. `_const_int_as_int(i32 -1)` produces signed Int64 −1 and `_ptr_identity` reinterprets that as UInt64 0xffffffffffffffff.
- Failure scenario: ConstantExpr address equality depends on the spelling/width of an integer even though both inttoptr expressions denote the same pointer. The implementation also has no datalayout/address-space parameter with which to truncate over-wide integers for narrower pointers.
- Native oracle recheck: change the return to `%r=zext i1 icmp eq (...) to i8; ret i8 %r`, then execute `Base.llvmcall((ir,"julia_cast"),UInt8,Tuple{UInt8},x)`. Printed `CONSTPTR_NATIVE 1 CIRCUIT 0` for x=0. Unlike F21's unresolved weak-symbol attempt, this complete native-vs-circuit counterexample executes successfully.
- Fix: normalize the integer using its original unsigned bit width, then apply the destination pointer width from the module datalayout (zero extension or truncation). If layout or address-space semantics are unavailable, decline folding. Do not reuse the signed arithmetic-constant helper for address normalization.
- Test: equivalent inttoptr expressions from i8/i16/i32/i64, including each width's high bit, plus truncation on a 32-bit layout; compare eq/ne outcomes and reversibility.
- Already tracked? No matching issue found.

### F20 — [S0] Vector-to-integer bitcasts silently ignore big-endian datalayouts
- Where: `src/extract/vectors.jl:779–819`; `src/extract/entry.jl:122–138`.
- Evidence: VERIFIED-BY-EXECUTION. Extract `target datalayout="E"` and `define i8 @julia_endian(i8 %x){entry: %b=trunc i8 %x to i1 %v=insertelement <8 x i1> zeroinitializer,i1 %b,i32 0 %r=bitcast <8 x i1> %v to i8 ret i8 %r}`. Compiling and simulating input `UInt8(1)` returns 1, expected 128; reversibility is true. Repeating with layout `"e"` correctly returns 1. The expected big-endian result follows the explicit vector packing rule in [LLVM 18 LangRef](https://releases.llvm.org/18.1.8/docs/LangRef.html#bitcast-to-instruction): lane zero occupies the most significant bits.
- Failure scenario: `.ll`/`.bc` ingest admits a big-endian module, but scalarization always shifts lane k by k. The module layout is lost before lowering, so no later layer can repair it. This failure does not require executing machine code on a non-x86 host.
- Fix: read the module datalayout when packing lanes and reverse their bit positions for big endian, or reject big-endian extraction consistently before any conversion until memory/bitcast paths support it. Retain the struct flattener's existing endianness guard.
- Test: all 256 lane masks for both `e` and `E`, comparing against the layout-specific packing oracle and checking ancilla restoration.
- Already tracked? No matching issue found.

### F17 — [S0] Non-jl_global aliases still cause entire side-effecting instructions to disappear
- Where: `src/extract/module_walk.jl:648–662`; `src/extract/instructions.jl:7904`.
- Evidence: VERIFIED-BY-EXECUTION. `@g=global i8 0; @a=alias i8,ptr @g; define i8 @julia_alias(i8 %x){entry: store i8 42,ptr @a ret i8 %x}` (each global on its own line) extracts to a block with **zero instructions** and `IRRet(ssa(:x),8)`. The alias store's LLVM.jl wrapping error is swallowed as benign. The direct-global equivalent would reject an unsupported store destination.
- Failure scenario: a valid write through a global alias is erased, so state mutations vanish without any remaining SSA consumer to trigger a later error. The claim that skipped instructions are necessarily caught by unbound-result consumers does not apply to stores or unused calls.
- Fix: resolve aliases with the raw API before typed dispatch, or reject them at the original instruction; never use exception-message matching to classify an instruction as harmless. Apply the same rule to called-function aliases.
- Test: alias-backed store and side-effecting alias call, plus alias loads with live/dead uses; unsupported effects must fail at extraction, supported ones must match native state changes.
- Already tracked? Bennett-n4di (open) is accurate. This probe strengthens it from a possible dangling SSA failure to an actual silently dropped side effect. Bennett-fnxh/hsm3 only protect the specifically named jl_global JIT-alias family.

### F10 — [S1] A valid nested ConstantArray crashes Julia in the LLVM C API
- Where: `src/extract/module_walk.jl:877–884` (`_flatten_struct_to_bytes`).
- Evidence: VERIFIED-BY-EXECUTION in an isolated process with core dumps disabled. `Bennett._parsed_ir_from_ir_string("@g = constant { [2 x i8] } { [2 x i8] [i8 1,i8 undef] }\ndefine i8 @julia_const(i8 %x){ entry: ret i8 %x }")` exits **139 / SIGSEGV**. Stack: `llvm::ConstantDataSequential::getElementAsInteger` → `getElementAsConstant` → `LLVMGetElementAsConstant` → `_flatten_struct_to_bytes … module_walk.jl:880`.
- Failure scenario: `ConstantArray` and `ConstantDataArray` are admitted by the same branch, but `LLVMGetElementAsConstant` requires a ConstantDataSequential object. The non-data array is cast to the wrong C++ class. The global need not even be referenced by the entry function; scanning all globals makes an otherwise trivial identity function crash the process. `undef` is valid in this initializer and should be rejected or handled explicitly, never segfault.
- Fix: use the operand accessor for `ConstantArray`; reserve `LLVMGetElementAsConstant` for `ConstantDataArray`. Explicitly reject undef/poison/non-integer elements under the existing policy, rather than replacing arbitrary elements with zero. Audit every raw C API accessor against its required value kind.
- Test: subprocess extraction of nested integer arrays containing undef, poison, and constant expressions, plus ordinary dense integer arrays. Require a contextual Julia exception or correct data, never abnormal process exit.
- Already tracked? No matching issue found. This is a distinct C API type-confusion crash, not an LLVM-context lifetime suspicion.

### F23 — [S1] Closed-world validation accepts genuinely ambiguous specialization calls
- Where: `src/extract/julia_set.jl:249–284,434–449,503–509`; `src/extract/callees.jl:101–154`.
- Evidence: VERIFIED-BY-EXECUTION. Define `struct ReviewAdder{T}; offset::T; end`, `Base.@noinline (a::ReviewAdder)(x::Int8)=x+Int8(a.offset)`, and `root_adder(x::Int8)=ReviewAdder(x)(x)+ReviewAdder(Int16(x))(x)`. `extract_parsed_ir_set_from_julia(root_adder,Tuple{Int8};ptr_cells=true)` **returns successfully** with keys `root_adder#48af7fb4`, `ReviewAdder#20e9b5fb`, `throw_inexacterror#223736bc`, `ReviewAdder#7be14e9b` (digests session-dependent). The two root calls both carry `callee=:ReviewAdder`, `arg_widths=[64,8]`, `ret_width=8`, despite referring to distinct specializations. The checker accepts any `haskey(bare_to_key,sym)`, without requiring one candidate. No downstream VM execution is claimed.
- Failure scenario: the producer promises a closed, resolvable set, but has erased the information needed to bind these two calls. Arity/width matching cannot disambiguate the printed calls. The corresponding Function-callee path correctly rejects multiple candidates; the Symbol path does not.
- Fix: carry the canonical specialization key at every call site using the typed/LLVM method mapping. Until that exists, make exact-bare and demangled-bare Symbol lookups require exactly one candidate, with an ambiguity error naming both keys.
- Test: the real functor example above must either link each call to the proper body or reject at set construction. Also test same-width closures of different captured types and plain Function/Symbol parity.
- Already tracked? Bennett-zuk5 accurately identifies the missing guard, but its “defense-in-depth” framing understates an executed public-producer acceptance with two indistinguishable calls.

### F14 — [S1] Volatile memory guards are bypassed by vector and sret dispatch
- Where: `src/extract/instructions.jl:6265–6267,7392–7405,7889–7902`; `src/extract/vectors.jl:825–846`; `src/extract/sret.jl:898–925`.
- Evidence: VERIFIED-BY-EXECUTION. Both `define i8 @julia_vol(ptr dereferenceable(1) %p){ entry: %v=load volatile <1 x i8>,ptr %p,align 1 %r=extractelement <1 x i8> %v,i32 0 ret i8 %r }` and `define void @julia_vol(ptr sret([1 x i8]) %out,i8 %x){entry: store volatile i8 %x,ptr %out ret void}` extract successfully. The former becomes ordinary IRLoad; the latter becomes only IRInsertValue+IRRet. Scalar counterparts outside these paths reject volatile effects.
- Failure scenario: recognized shapes bypass the common dispatch guards, so memory operations whose observable access semantics are unsupported are nevertheless accepted with those semantics discarded. The sret pre-walk likewise never checks atomic ordering on its suppressed stores.
- Fix: apply volatile/atomic policy checks before vector/sret/heap recognition can suppress or replace any instruction. Reuse one validation helper across every producer.
- Test: scalar, vector, sret and heap load/store matrices with volatile and supported/unsupported atomic orderings; equivalent effects must receive equivalent rejection policy.
- Already tracked? Bennett-4mmt (closed) claims atomic/volatile load/store rejection; the bypasses remain. F2 covers the separate memset zero-fill bypass.

### F18 — [S1] Unnamed LLVM basic blocks all become the same empty label
- Where: `src/extract/module_walk.jl:477–478`; `src/extract/instructions.jl:6658–6667,6326–6353`.
- Evidence: VERIFIED-BY-EXECUTION. `_parsed_ir_from_ir_string` on `define i8 @julia_unnamed(i8 %x) { %1=icmp eq i8 %x,0 br i1 %1,label %2,label %3 2: ret i8 7 3: ret i8 9 }` produces three blocks all labelled `Symbol("")`; both branch targets are also `Symbol("")`. `reversible_compile(p)` rejects with `lower: duplicate basic-block labels in ParsedIR (Bennett-c6ex)`.
- Failure scenario: numeric block slots are valid LLVM IR and common in external compiler output. `LLVM.name` returns an empty string for an unnamed block, not its printed slot number. The value naming pass handles unnamed instructions but omits block identities entirely.
- Fix: build a collision-free `LLVMValueRef => Symbol` block table before conversion and consult it for block labels, branch/switch targets and phi predecessor labels. Never use an empty string as block identity.
- Test: unnamed entry/diamond/loop blocks with named and unnamed values; extraction must retain distinct CFG nodes, and the diamond must return 7 for zero and 9 otherwise over all 256 UInt8 inputs with ancilla checks.
- Already tracked? No matching open bead; Bennett-c6ex's downstream duplicate-label guard catches the extractor defect but does not fix it.

### F22 — [S1] Array allocas discard the outer allocation count
- Where: `src/extract/instructions.jl:118–128,8211–8225`.
- Evidence: VERIFIED-BY-EXECUTION. `define i8 @julia_count(i8 %x){entry: %p=alloca [1 x i8],i32 2 %q=getelementptr i8,ptr %p,i64 1 store i8 %x,ptr %q %r=load i8,ptr %q ret i8 %r}` produces `IRAlloca(:p,8,ConstOperand(1))`. Compilation rejects the valid second-byte store with `ArgumentError: _lower_store_via_shadow!: idx=1 out of range [0, 1)`.
- Failure scenario: `alloca [K x T],N` reserves K×N elements in LLVM; the extractor reserves K. Runtime counts are silently replaced by K too. The circuit's bound guard prevents this witness becoming a wrong result, but the ParsedIR handed to external consumers has the wrong reservation.
- Fix: multiply the array length by the outer count, checking overflow. Preserve dynamic counts via a supported multiplication or reject them at extraction. Make reservation and all capacity proofs consume this one correct definition.
- Test: outer counts 0/1/2 and runtime N, read/write the last valid element, reject the first invalid one; compare accepted circuit results and ancilla restoration.
- Already tracked? Bennett-uiqq accurately describes this defect; the executed valid-input failure confirms it is active.

### F9 — [S1] Pure vector plumbing leaves supported sret stores permanently pending
- Where: `src/extract/module_walk.jl:662–667`; `src/extract/sret.jl:1018–1046`; `src/extract/vectors.jl:482–499`.
- Evidence: VERIFIED-BY-EXECUTION. `define void @julia_vret(ptr sret([2 x i8]) %out,i8 %x) { entry: %v0=insertelement <2 x i8> poison,i8 %x,i32 0 %v=insertelement <2 x i8> %v0,i8 %x,i32 1 store <2 x i8> %v,ptr %out,align 1 ret void }` fails with `AssertionError: ir_extract.jl: 1 pending sret vector store(s) remain unresolved at ret void`. Both lanes are fully defined. `_convert_vector_instruction` has populated `lanes`, but returns `nothing`; the walker continues before calling the pending-store resolver.
- Failure scenario: a vector returned via sret is built by insertelement/shuffle/same-shape bitcast, which are intentionally zero-instruction aliases. The resolver is never notified. Related incompleteness: constant vector values have no producer visit, and the resolver resolves only one pending store per producer.
- Fix: resolve pending lane references after every successfully processed producer, including `nothing` results that update `lanes`; initialize constants directly and resolve all stores referring to the producer. Distinguish intentionally empty conversion from an unsupported skipped instruction.
- Test: the module above, a shuffle-only sret producer, constant-vector sret stores, and one vector stored into two disjoint sret regions; check tuple outputs and ancilla restoration.
- Already tracked? No matching open issue. Bennett-0c8o claims vector-lane sret support, but this basic accepted vector plumbing is omitted.

### F21 — [S1] ConstantExpr pointer comparison mistakes symbolic identity for known address inequality
- Where: `src/extract/constexpr.jl:215–265,273–322`.
- Evidence: REASONED-ONLY for the end-to-end linked-program counterexample; extractor behavior was executed. `@review_undefined_weak = extern_weak global i8` plus `define i1 @julia_weak(i8 %x){entry: ret i1 icmp eq (ptr @review_undefined_weak,ptr null)}` extracts to `IRRet(ConstOperand(0),1)`. `_ptr_addresses_equal` compares `(:named,ref)` with `(:null,0)` and returns false. An undefined ELF weak symbol resolves to null, so this program must return true when that symbol is not supplied. This is specified by [LLVM 18 linkage semantics](https://releases.llvm.org/18.1.8/docs/LangRef.html#linkage-types). A native `Base.llvmcall` attempt reported `JIT session error: Symbols not found: [ review_undefined_weak ]` and was interrupted; the Julia JIT did not provide an ELF-linker oracle.
- Failure scenario: a conventional optional weak-symbol availability check is constant-folded to the wrong branch. More generally, a named symbol and a numerical address are not proven unequal merely because their identity tags differ; IFunc results also require resolver semantics.
- Fix: make equality tri-valued. Same proven identity can return true; provably distinct non-interposable/non-null objects can return false; extern_weak, IFunc, symbolic-versus-absolute, and other unresolved relationships must return `nothing` and reject rather than guess.
- Test: undefined/resolved weak symbol null checks via a local native linker fixture, aliases of the same symbol, distinct fixed globals, and undecidable symbolic/absolute comparisons. Require correct folding or explicit rejection.
- Already tracked? No matching issue found.

### F15 — [S2] MemorySSA printing deadlocks once its undrained stderr pipe fills
- Where: `src/memssa.jl:123–142`.
- Evidence: VERIFIED-BY-EXECUTION. `timeout 35s julia --compiled-modules=existing --project --check-bounds=yes -e 'using Bennett; ir="define i8 @julia_mem(ptr %p,i8 %x) {\nentry:\n" * repeat("store i8 %x, ptr %p\n",2000) * "ret i8 %x\n}"; println("MEMSSA_START"); flush(stdout); s=Bennett._run_memssa_on_ir(ir;preprocess=false); println("MEMSSA_DONE ",sizeof(s))'` prints only `MEMSSA_START` and exits 124 (timeout). The producer runs synchronously inside `redirect_stderr`; no reader starts until after the pass returns and the write endpoint closes.
- Failure scenario: a moderately sized valid module fills the OS pipe buffer while the LLVM printer is still writing. The producer waits for a reader that is scheduled only after producer completion. The public `use_memory_ssa=true` route inherits this hang.
- Fix: drain the pipe concurrently with the pass and close both endpoints in finally blocks; serialize process-wide stderr capture. Avoid a shared stderr channel if LLVM can supply an owned output stream.
- Test: printer output substantially larger than the pipe capacity, with a bounded timeout, plus exception cleanup and concurrent callers.
- Already tracked? No matching open issue found; Bennett-law3/08wr are closed MemorySSA implementation/integration work.

### F26 — [S2] MemorySSA parsing merges different functions' local node IDs
- Where: `src/memssa.jl:36–100,133–136`; `src/ir_types.jl:559–566`.
- Evidence: VERIFIED-BY-EXECUTION. Print MemorySSA without preprocessing for a module containing (1) `f1(ptr %p,i8 %x)` with two stores and ret void, and (2) `julia_f2(ptr %p,i8 %x)` with entry→loop, a loop store, an integer counter/conditional backedge and an exit return. LLVM prints `f1: 1=MemoryDef(liveOnEntry), 2=MemoryDef(1)` and `julia_f2: 2=MemoryPhi({entry,liveOnEntry},{loop,1}), 1=MemoryDef(2)`. `parse_memssa_annotations` returns `def_clobber=Dict(2=>1,1=>2)` and `phis=Dict(2=>[(:entry,0),(:loop,1)])`: f1's node 1 was overwritten and node 2 now simultaneously denotes a store and a phi from different functions.
- Failure scenario: `print<memoryssa>` visits every defined function in a module and restarts its numbering in each one. The parser ignores the `MemorySSA for function:` headers. Multi-function modules therefore yield a silently corrupted diagnostic graph. No circuit miscompile is claimed: current lowering has no consumer of this bundle.
- Fix: namespace IDs and instruction locations by function, or select one function's printer output before parsing. Preserve the function identity in MemSSAInfo. Also ensure any future association with ParsedIR uses the same transformed module/pass list, rather than independently generated pre-pass line numbers.
- Test: two functions that deliberately reuse def/phi IDs in different roles; assert each graph independently, and retain a single-function control.
- Already tracked? No matching open issue found.

### F16 — [S2] Recursive callgraph walks include the root despite promising to exclude it
- Where: `src/extract/callgraph.jl:98–110,122–136`; `src/extract/julia_set.jl:488–509`.
- Evidence: VERIFIED-BY-EXECUTION. `Base.@noinline rec_review(x::Int8)=x<=0 ? Int8(0) : rec_review(x-Int8(1))`. `transitive_callees(rec_review,Tuple{Int8})` prints `[(typeof(rec_review),Tuple{Int8})]`. `extract_parsed_ir_set_from_julia(rec_review,Tuple{Int8})` then fails with `duplicate canonical key rec_review#6f2728c5` (digest is session-dependent).
- Failure scenario: visited starts empty. A recursive edge adds the root as a callee; set assembly extracts it once in the callee loop and again as the prepended root. This fails before any actual downstream recursion limitation can be diagnosed. Mutual recursion has the same root-reentry issue.
- Fix: seed visited with the root while keeping the discovered non-root output separate; do the same for the raw-specTypes helper. Register the root explicitly when recursive linkage needs it, without emitting its body twice.
- Test: direct and mutual recursion, both include_root values, exactly one root body when requested and none when excluded; check closed-world linkage separately from circuit recursion support.
- Already tracked? Bennett-t7zu concerns downstream recursive sret lowering, not this callgraph/set-construction bug.

### F25 — [S2] Four rounding intrinsics fall through despite claiming registered dispatch
- Where: `src/extract/instructions.jl:5093–5107,6847–6871`; `src/callees.jl:27–36`.
- Evidence: VERIFIED-BY-EXECUTION. For each `op ∈ (floor,ceil,trunc,rint)`, extract `declare double @llvm.op.f64(double)` and an integer-bit wrapper: `define i64 @julia_f(i64 %x){entry: %a=bitcast i64 %x to double %b=call double @llvm.op.f64(double %a) %r=bitcast double %b to i64 ret i64 %r}`. All four reject with `call to 'llvm.<op>.f64' has no registered callee handler or intrinsic pattern`.
- Failure scenario: the explicit branch's comment says the callee registry handles these names, but registration keys are `soft_floor`, `soft_ceil`, `soft_trunc`, `soft_round`. `_lookup_callee` has no LLVM-name-to-soft-name mapping. Available implementations therefore cannot be reached from the stated intrinsic surface.
- Fix: add explicit f64 dispatch to the matching soft primitive, with width checks like round/roundeven. State the assumed rounding environment for rint. Remove the empty conditional and stale explanation.
- Test: raw LLVM bit-pattern wrappers on positive/negative fractional values, ties, ±0, infinities and NaNs; compare supported semantics and ancilla restoration. Keep unsupported widths loud.
- Already tracked? Bennett-6pa (closed) claims the rounding-intrinsic work; its scope includes these four intrinsics, but their direct dispatch is absent. Bennett-0hu (closed) adds a SoftFloat ceil test, which does not establish raw LLVM intrinsic linkage. No open issue specifically repairs the missing dispatch.

## Unconfirmed suspicions

- No additional suspected defect is promoted without a concrete trace. Non-x86 execution, GC-window task migration, and concurrent same-key registry replacement were not exercised. The registry locks protect individual dictionary operations, not an entire extraction snapshot; a concurrency stress review remains useful, but no concurrency miscompile is claimed here.
- Refuted during continuation: treating the new `select ?, poison, X → X` lane refinement itself as a wrong-result bug. The [LLVM poison refinement rule](https://releases.llvm.org/18.1.8/docs/LangRef.html#poison-values) permits this; undef is kept separate and the checked test rejects an undef computation. Ignoring nsw/nuw/exact flags is likewise not by itself a defined-input counterexample: the flagged poison cases admit refinement. The report's arithmetic findings use defined inputs.
- Refuted during continuation: a proposed wider-element M2 miscompile based solely on the `offset_bytes` comment. An i16 version of the heap fixture with capacity 4, stores at bytes 16/18 and a runtime element index returned the correct 3 for input −3. Do not turn Bennett-xroi's representation concern into an asserted wrong-result case without a stronger witness.
- No inherited finding was superseded. F2's tracking attribution was corrected after reading Bennett-zmry, and F25 was connected to the closed Bennett-6pa work rather than labelled wholly untracked.

## What is sound (brief)

- **Pinned optimization works on the tested x86 cases.** Three subprocesses (`-C x86-64 -O1`, `-C znver3 -O3`, `-C x86-64-v3 -O2`) each produced 6,248 gates for soft_fcmp_olt, returned 1 for −1.0 < 1.0 and passed reversibility. Pinned soft_fmul matched native `code_llvm` in an `x86-64-v3 -O2` subprocess after the checked-in normalizer (274 normalized lines). The test functions carried no target-cpu/target-features attributes. The implementation retains the source triple/datalayout and explicitly promises neither cross-architecture equality nor removal of codegen-time feature decisions; Bennett-yn08 and Bennett-nyln correctly record residual concerns.
- **The new poison-lane work survived targeted review.** `test/test_t9rh_poison_lane_propagation.jl`: 378/378 assertions passed in 23.1 seconds, including its exhaustive UInt8² oracle loop, poisoned observation rejects and undef distinction. A separate exhaustive UInt8 probe of ctpop, ctlz(false), cttz(false), bitreverse and abs(false) passed 1,285 assertions. These working paths should not be rewritten merely because the adjacent funnel-shift and vector-memory paths are wrong.
- **Live jl_global certification is substantively stronger than name recognition.** The code enumerates live GenericMemory singleton objects and compares addresses; it does not dereference an address obtained from IR. Executed Ref(struct), Ref(tuple), nested Ref and non-empty Memory functions rejected at both optimization settings. Empty Memory was certified at optimize=false and conservatively rejected through its direct JIT alias at optimize=true. Hand-written null, address 1 and address −1 slots were classified without dereference or process failure. All tested live empty singleton types had non-null data pointers; the dormant nullable-data fact was not demonstrated to cause a current failure.
- **Useful fail-loud boundaries remain.** Bool call ABI widened an i1 comparison to the callee's i8 Bool parameter and returned the correct 7/9. Integer predicate mapping is direct and consistent. Unsupported ordinary opcodes, unresolved ordinary callees, scalar volatile/atomic memory operations, vector shape changes, heterogeneous sret layout mismatches, and consumed-sret pointer escapes generally reject with context. Returned ParsedIR data contains symbols/integers/Julia callees rather than live LLVM references; no successful-path LLVM-context lifetime escape was found. The crash in F10 is a specific wrong-kind C API call, not evidence of a generic use-after-dispose.

## Nits (S4)

- `CLAUDE.md` still lists `src/ir_parser.jl`, which is absent; the include manifest also includes jlglobal_cert.jl and sig_llvm.jl beyond the older file map. c1 correctly noticed the missing legacy parser.
- `vectors.jl:98–108` still says scalar float min/max handlers use integer comparisons; those handlers now dispatch soft-float primitives. The vector refusal is conservative, but its explanation is obsolete.
- Several comments confuse an LLVM block's printed order with dominance/execution order, describe registered callee matching as substring matching, or claim LLVM names cannot contain `#`. Do not use these statements as proof obligations; F8/F18 demonstrate why naming matters.

## Coverage log

- Continuation review started 2026-09-26: read CLAUDE.md and this inherited report in full. Inherited claims remain provisional until rechecked; the following continuation will record re-verification and additional coverage. All probes are passed on stdin/in command arguments; no probe files are written.
- Continuation re-executed F1–F14 (including F10 in an isolated core-disabled subprocess) and F17: every primary claim reproduced. F10 again exited 139 at `LLVMGetElementAsConstant`. F12 additionally reproduced the atomicrmw deletion on the checked-in heap fixture. Circuit counterexamples checked actual output and `verify_reversibility(...;n_tests=4)`.
- Read CLAUDE.md in full. The review-specific one-file constraint overrides worklog, beads, and commit/push procedures.
- Read include manifest, entry pipeline, helpers, constexpr, callee registry, callgraph, julia_set, target pinning, jlglobal certification, memssa and vector scalarization. `src/ir_parser.jl` does not exist in this checkout.
- Julia probes use `--compiled-modules=existing` to avoid creating compilation cache files; initial default invocation encountered another process's precompile lock and was interrupted.
- Continuation completed re-verification of F15 (40-second bounded deadlock probe) and F16 (root duplication) as well. A small multi-function MemorySSA print completed normally and exposed F26, separating the pipe-size failure from general Julia startup problems.
- Read the include manifest and entry/callee/helpers/errors/constexpr/target-pin code, all ir_types.jl and src/callees.jl, callgraph.jl, the registration/linkage/restore paths in julia_set.jl, and sig_llvm.jl's method/world/codegen entry. Read jlglobal_cert.jl's classifier, live singleton enumeration, GC window, seeding and post-walk use checks. This extends the explicit scope through the manifest for the hsm3/target-pin questions.
- Read module_walk's entry selection, naming, sret suppression, exception swallow, global materialization, switch expansion and final literal-use backstop. Read sret detection/layout, scalar/vector stores, forwarding/padding memcpy recognition, pending resolution and consumed-sret reconstruction. Read every scalar opcode arm and the full intrinsic dispatcher in instructions.jl, in short slices; audited the memcpy/memmove/memset admission/emission paths and relevant root-width/constant-offset helpers. Read all vector scalarization and reduction branches.
- Read heap M1/M2 dispatch, skeleton seeding/closure, partition, liveness/escape checks, backedge guard and rerooted emission, and executed mutations of the checked-in M2 fixture. M3 growend recognition and the long ptr_cells-only `_57hd`/`_foz5`/`_p06b` helper analyses received targeted cross-references, not a complete independent proof audit. The separate mem=:vm Dict/Vector recognizers were not reviewed beyond references needed to understand core dispatch. No external BennettVM runtime result is claimed.
- Cross-scope source reads were limited to lowering call ABI/cache use, pointer-load/GEP behavior and reversibility entry points needed to confirm extraction findings. The poisoned-vector standalone test and all custom probes were read-only/in-memory; tests that create temporary .ll files were not run.
- c1-extraction claims checked: its bare-name collision concern is confirmed, but “substring matching” is inaccurate; its blanket safe/subtractive heap characterization is refuted by F12; its statement that the runtime-recognition product is unreachable from reversible_compile is too broad because mem=:heap is reachable and was executed here. Its observation that extraction mixes circuit and VM models is descriptive, not a substitute for the concrete defects above. No attempt was made to validate its speculative future-version architecture recommendations.
- Validation limits: x86_64/Linux, Julia 1.12.3, LLVM 18. No full suite, no remote builds, no source fixes, no new issue records. The F21 native weak-symbol oracle did not link in Julia's JIT and was interrupted; its classification is explicitly REASONED-ONLY. The first target-fidelity probe used an unsupported extract_ir dump_module keyword; the corrected probe used _julia_ir_string and passed. These probe errors were not classified as repository bugs.
