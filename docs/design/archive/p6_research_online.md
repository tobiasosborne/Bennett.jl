# p6 Research (Online) — Julia NTuple ABI Lowering to LLVM IR

**Author:** research subagent
**Date:** 2026-04-21
**Purpose:** Ground-truth research for Bennett.jl's `NTuple{9,UInt64}` sret-vectorisation blocker. This document is descriptive (external sources only); synthesis and design proposal are out of scope.
**Scope:** Everything public I could verify about Julia's LLVM calling convention for NTuples, LLVM's sret/aggregate machinery, LLVM passes that rewrite aggregate/vector stores, and what Enzyme.jl / GPUCompiler.jl already do for this exact problem.

All file:line citations come from either (a) locally cloned canonical repos (`JuliaLang/julia`, `EnzymeAD/Enzyme.jl`, `JuliaGPU/GPUCompiler.jl`, `llvm/llvm-project`) against their respective `master`/`main` branches as of this session, or (b) permalinks fetched via WebFetch. Where I couldn't verify a claim, I say so explicitly.

---

## Executive Summary (read this first)

1. **NTuple is NOT a struct to Julia's backend.** For a homogeneous tuple `NTuple{N,T}` where `T` is a primitive, Julia's `_julia_struct_to_llvm` in `src/cgutils.cpp` lowers the tuple to either an LLVM `ArrayType` (`[N x T]`) or, if `T` is a `VecElement`, an LLVM `FixedVectorType` (`<N x T>`). Non-homogeneous tuples become `StructType`. This is the *source-language-level* lowering, before ABI concerns.

2. **sret is a separate decision made by `deserves_sret` + platform ABI.** On x86_64 SYSV (Bennett.jl's target), anything classified `Memory` by the System V classifier is returned sret. An `NTuple{9,UInt64}` is 72 bytes, way past the 16-byte threshold, so it always becomes sret on this target.

3. **The `<4 x i64>` you see at `-O2` is SROA+InstCombine+SLP mashing the sret store into a wide vector store.** SROA tries to map `alloca [9 x i64]` accesses onto insert/extract-element of a vector, then instcombine/SLP coalesce adjacent stores. This is the LLVM pass `SROAPass(SROAOptions::ModifyCFG)` followed by `SLPVectorizerPass()` in `src/pipeline.cpp`.

4. **The `llvm.memcpy.p0.p0.i64 ... i64 72` at `-O0` is Julia's native `emit_new_struct` / ccall aggregate spill.** At no optimisation, aggregate return copies are emitted as a bulk memcpy from the callee's stack alloca into the sret pointer.

5. **Enzyme.jl hit this exact problem and solved it.** They have (a) a `memcpy_sret_split!` pass in `src/llvm/transforms.jl` that splits the memcpy into individual loads/stores recursively following the Julia struct layout, and (b) a C++-side `FixupJuliaCallingConventionSRetPass` (registered as `enzyme-fixup-julia-sret`) that runs late in their pipeline. **This is the closest external precedent to what Bennett.jl needs.**

6. **Stock LLVM has a ready-made pass for unvectorising stores: `Scalarizer` with `ScalarizeLoadStore=true`.** It splits `store <N x iW>` into `N` individual `store iW` instructions. It is **not** included in Julia's default pipeline. Adding it to a custom Bennett-side pipeline should be low-friction.

7. **Nobody else in the reversible/quantum-compiler space has solved this at the Julia level.** ReVerC, Quipper, Silq all operate on their own surface languages or domain IRs; they don't ingest LLVM IR from a general-purpose compiler. Bennett.jl is the novel case here.

**Concrete recommendation anchor (detail in §11):** the tightest external precedent is Enzyme's two-prong approach — canonicalise memcpy-sret into per-field loads/stores at the IR level, plus optionally run `Scalarizer` with load-store scalarisation to neutralise any wide-vector stores that slip through.

---

## §1 — Julia's LLVM Calling Convention for NTuple{N, T}

### §1.1 The official documentation

From `doc/src/devdocs/callconv.md` on the master branch
(https://github.com/JuliaLang/julia/blob/master/doc/src/devdocs/callconv.md), the authoritative text on the "Native" calling convention is:

> "The native calling convention is designed for fast non-generic calls. It usually uses a specialized signature.
>
> - LLVM ghosts (zero-length types) are omitted.
> - LLVM scalars and vectors are passed by value.
> - LLVM aggregates (arrays and structs) are passed by reference.
>
> A small return value is returned as LLVM return values. A large return value is returned via the "structure return" (`sret`) convention, where the caller provides a pointer to a return slot.
>
> An argument or return value that is a homogeneous tuple is sometimes represented as an LLVM vector instead of an LLVM array."

Rendered page: https://docs.julialang.org/en/v1/devdocs/callconv/

The phrase "is sometimes represented as an LLVM vector" is exactly what bites Bennett.jl — the doc admits non-determinism but doesn't specify the rule. The rule is in `cgutils.cpp` (§1.3 below).

### §1.2 The `deserves_sret` decision (size threshold)

`src/codegen.cpp` line 1693 (master, verified locally):

```cpp
static bool deserves_sret(jl_value_t *dt, Type *T)
{
    assert(jl_is_datatype(dt));
    return (size_t)jl_datatype_size(dt) > sizeof(void*) && !T->isFloatingPointTy() && !T->isVectorTy();
}
```

Key observations:

- **The Julia-level threshold is `sizeof(void*)` (8 bytes on 64-bit platforms).** This is narrower than the SYSV ABI threshold of 16 bytes. Anything larger than a pointer that isn't float/vector gets sret-returned at the Julia specfunc level.
- **If the LLVM type is already a `VectorType`, it is NOT sret.** This is the path by which an `NTuple{4,Float64}` tagged as a VecElement bundle returns as `<4 x double>` in-register.
- This decides sret *before* ABI lowering — so on x86_64 SYSV, this shortcut keeps small aggregates out of sret, and then the platform ABI further decides (§1.4).

The companion helpers immediately above (lines 1674-1691):

```cpp
static bool deserves_stack(jl_value_t* t)
{
    if (!jl_is_concrete_immutable(t))
        return false;
    jl_datatype_t *dt = (jl_datatype_t*)t;
    return jl_is_datatype_singleton(dt) || jl_datatype_isinlinealloc(dt, /* (require) pointerfree */ 0);
}
static bool deserves_argbox(jl_value_t* t) { return !deserves_stack(t); }
static bool deserves_retbox(jl_value_t* t) { return deserves_argbox(t); }
```

So: concrete immutable + inline-alloc ⇒ on stack; otherwise argbox/retbox (heap-boxed).

### §1.3 Julia type → LLVM type mapping (tuples become arrays, not structs)

`src/cgutils.cpp` lines 1023-1048 (master, verified locally) — this is **the** function that decides the LLVM type of a tuple:

```cpp
if (allghost) {
    ...
    struct_decl = getVoidTy(ctxt);
}
else if (jl_is_vecelement_type(jt) && !jl_is_uniontype(jl_svecref(ftypes, 0))) {
    // VecElement type is unwrapped in LLVM (when possible)
    struct_decl = latypes[0];
}
else if (isarray && !type_is_ghost(lasttype)) {
    if (isTuple && isvector && jl_special_vector_alignment(ntypes, jlasttype) != 0)
        struct_decl = FixedVectorType::get(lasttype, ntypes);
    else if (isTuple || !llvmcall)
        struct_decl = ArrayType::get(lasttype, ntypes);
    else
        struct_decl = StructType::get(ctxt, latypes);
}
else {
    struct_decl = StructType::get(ctxt, latypes);
}
```

So the ranked decisions for a tuple `(T1, T2, …, Tn)`:

1. All fields ghost → `void`.
2. The outer Julia type is itself `VecElement{T}` → return just the single scalar LLVM type (unwrap).
3. All fields have the same LLVM type (`isarray && isvector`) **and** `jl_special_vector_alignment(n, T) != 0` → `<n x T>` **FixedVectorType**.
4. All fields have the same LLVM type but not special-vector-aligned → `[n x T]` **ArrayType**.
5. Heterogeneous fields → `StructType`.

The key gate is `jl_special_vector_alignment`, defined in `src/datatype.c` line 323 (master):

```c
unsigned jl_special_vector_alignment(size_t nfields, jl_value_t *t)
{
    if (!jl_is_vecelement_type(t))
        return 0;
    ...
}
```

**Punchline: `jl_special_vector_alignment` returns nonzero only for `VecElement{T}` element types.** A plain `NTuple{9,UInt64}` is NOT `VecElement`, so the front-end lowering gives an `ArrayType`, i.e. `[9 x i64]`, not `<9 x i64>`. That means Bennett's `NTuple{9,UInt64}` arrives at LLVM IR as `[9 x i64]`, not as a vector.

Therefore: **the `<4 x i64>` Bennett sees at `-O2` is introduced by LLVM optimisation passes, not by Julia's front-end.** (This is the critical framing — see §2, §7, §11.)

### §1.4 Platform ABI decision after specfunc lowering

For x86_64 SYSV, `src/abi_x86_64.cpp` line 176 (verified locally):

```cpp
bool use_sret(jl_datatype_t *dt, LLVMContext &ctx) override
{
    int sret = classify(dt).isMemory;
    if (sret) {
        assert(this->int_regs > 0 && "No int regs available when determining sret-ness?");
        this->int_regs--;
    }
    return sret;
}
```

`classifyType` (same file, lines 118-167) implements the SYSV AMD64 classifier. The cut-off for primitives is 16 bytes (line 137-144):

```cpp
else if (jl_is_primitivetype(dt)) {
    if (jl_datatype_size(dt) <= 8) {
        accum.addField(offset, Integer);
    }
    else if (jl_datatype_size(dt) <= 16) {
        // Int128 or other 128bit wide INTEGER types
        accum.addField(offset, Integer);
        accum.addField(offset+8, Integer);
    }
    else {
        accum.addField(offset, Memory);
    }
}
```

Structs ≤ 16 bytes are recursively classified (lines 151-162); **anything else is `Memory` ⇒ sret.**

An `NTuple{9,UInt64}` is 72 bytes. It is not itself a primitive, so it goes down the "else" path at line 164-166 and is classified as `Memory`. Confirmed sret on x86_64 SYSV.

Windows x86_64 is narrower still — `src/abi_win64.cpp` `use_sret`:

```cpp
bool use_sret(jl_datatype_t *dt, LLVMContext &ctx) override
{
  size_t size = jl_datatype_size(dt);
  if (win64_reg_size(size) || is_native_simd_type(dt))
    return false;
  nargs++;
  return true;
}
```

with `win64_reg_size` being "size in {1, 2, 4, 8}". So on Win64 only 1/2/4/8-byte aggregates (or SIMD) dodge sret.

On AArch64, `src/abi_aarch64.cpp`'s `use_sret` delegates to `classify_arg()` with the HFA (Homogeneous Floating-point Aggregate) rules — up to 4 members of a common floating-point/SIMD type can stay in SIMD registers. HFAs **don't** help a `NTuple{9,UInt64}` (neither floating-point nor ≤4 members).

### §1.5 The sret buffer is emitted at codegen.cpp:8262

`src/codegen.cpp` lines 8258-8287 (verified locally):

```cpp
else if (!deserves_retbox(jlrettype)) {
    bool retboxed;
    rt = _julia_type_to_llvm(&out, M->getContext(), jlrettype, &retboxed, /*noboxing*/false);
    assert(!retboxed);
    if (rt != getVoidTy(M->getContext()) && deserves_sret(jlrettype, rt)) {
        auto tracked = CountTrackedPointers(rt, true);
        ...
        props.cc = jl_returninfo_t::SRet;
        props.union_bytes = jl_datatype_size(jlrettype);
        props.union_align = props.union_minalign = julia_alignment(jlrettype);
        props.all_roots = tracked.all;
        // sret is always passed from alloca
        assert(M);
        fsig.push_back(PointerType::get(M->getContext(), M->getDataLayout().getAllocaAddrSpace()));
        argnames.push_back("sret_return");
        srt = rt;
        rt = getVoidTy(M->getContext());
    }
    else {
        props.cc = jl_returninfo_t::Register;
    }
}
```

Attributes added (lines 8289-8303):

```cpp
if (props.cc == jl_returninfo_t::SRet) {
    assert(srt);
    AttrBuilder param(M->getContext());
    param.addStructRetAttr(srt);
    ...
    param.addAttribute(Attribute::NoAlias);
    addNoCaptureAttr(param);
    param.addAttribute(Attribute::NoUndef);
    param.addAlignmentAttr(Align(props.union_align));
    attrs.push_back(AttributeSet::get(M->getContext(), param));
}
```

So the sret pointer gets the real LLVM `sret(<ty>)` attribute (with the typed-form where supported), plus `noalias`, `nocapture`, `noundef`, and alignment. This matches the LLVM LangRef spec (§10.1).

### §1.6 Takeaway for §1

- **Bennett.jl should design for `NTuple{N,T}` arriving as `[N x T]*`** passed as the first (sret) argument of a `void` function, with attrs `sret([N x T]) noalias nocapture noundef align <A>`.
- **Bennett.jl must NOT assume the front-end emits `<N x T>*` for sret on arbitrary `NTuple{N,T}`.** Vector typing is reserved for `VecElement` homogeneous tuples. The `<4 x i64>` seen at `-O2` is an optimisation artefact.
- The problem is **narrow in scope**: it's about normalising post-optimisation IR back to the pre-optimisation shape for the specific purpose of walking the IR instruction-by-instruction.

---

## §2 — LLVM sret Variants Seen in Julia-emitted IR

Two shapes are observable from `code_llvm(f, (NTuple{N,T},); optimize=true|false)`:

### §2.1 Form A (`-O0`, `optimize=false`): memcpy-based sret

At `optimize=false`, Julia's specfunc emits the tuple computation into a stack alloca (type `[N x T]`), then spills the whole alloca to the sret pointer via `llvm.memcpy.p0.p0.i64(dst, src, <N*sizeof(T)>, i1 false)`. For Bennett's `NTuple{9,UInt64}` this is a 72-byte memcpy as reported.

The pattern for aggregate returns from emit-new-struct / ccall-tuple is documented implicitly by Yorick Peterse's ABI write-up (https://yorickpeterse.com/articles/the-mess-that-is-handling-structure-arguments-and-returns-in-llvm/):

> "When processing a `return` in such a function, transform it into a pointer write to the `sret` pointer and return `void` instead."
> "Due to the above rules it's likely that the types of structure arguments don't match the types of their corresponding `alloca` slots. The solution involves copying via `memcpy` intrinsics between ABI-compliant and user-defined types, with optimization passes removing unnecessary copies afterward."

Julia's `MemCpyOptPass` is relied upon to simplify / eliminate these memcpys under optimisation (see §4). Without optimisation, the memcpy survives.

### §2.2 Form B (`-O2`, `optimize=true`): vector store

Under `-O2`, Julia's pipeline (`src/pipeline.cpp`, see §7.2) runs `SROAPass(SROAOptions::ModifyCFG)` multiple times plus `SLPVectorizerPass` and `VectorCombinePass` in the vector pipeline. SROA's LangRef-blessed job is:

> "The well-known scalar replacement of aggregates transformation. This transform breaks up `alloca` instructions of aggregate type (structure or array) into individual `alloca` instructions for each member if possible." (LLVM Passes docs: https://llvm.org/docs/Passes.html)

Critically, SROA also has a second behaviour — **it promotes aggregate allocas to vector operations when it detects insert/extract patterns.** From the Scalarizer/SROA search result (LLVM doxygen, https://llvm.org/doxygen/SROA_8cpp_source.html):

> "The pass will try to detect a pattern of accesses which map cleanly onto insert and extract operations on a vector value, and convert them to this form."

Consequently an `[9 x i64]` alloca with naturally-indexed stores can be promoted to a `<N x i64>` vector value, whose subsequent stores into the sret pointer then turn into `store <4 x i64>` / `store <1 x i64>` etc. after SLP and store-coalescing. This is exactly Bennett's observed `store <4 x i64>` at byte offset 8.

I did not find a single canonical doc page naming this chain end-to-end, but the ingredients are all on record:

- SROA's "vector-promotion" behaviour: LLVM doxygen `SROA_8cpp.html` and the quote above.
- SLPVectorizer: https://llvm.org/doxygen/SLPVectorizer_8cpp_source.html.
- Julia's `-O2` pipeline wiring: https://github.com/JuliaLang/julia/blob/master/src/pipeline.cpp lines 482-550 (verified, see §7).

### §2.3 Sret attribute vs "first arg pointer convention"

Julia emits the real LLVM `sret(<ty>)` parameter attribute (verified in codegen.cpp line 8293 `param.addStructRetAttr(srt);`, §1.5). It is **not** just a coincidental "first arg is a pointer"; it is a real attributed parameter. Tools can look it up reliably.

### §2.4 Takeaway for §2

- Bennett.jl can recognise sret unambiguously via LLVM.jl's attribute-query API (look for a typed `sret(<ty>)` attribute on param index 1).
- Both observed shapes (memcpy form at O0, vector-store form at O2) happen because SROA/InstCombine/SLP/VectorCombine are promoting `[N x T]` allocas to vectors as an optimisation.
- The underlying Julia-level type is always `[N x T]` (array), regardless of how it's stored into the sret pointer.

---

## §3 — Canonicalising LLVM IR for External Consumers

This is the question: given Form A (memcpy) or Form B (vector store), how do we get back to N individual scalar `store iW` instructions?

### §3.1 The Scalarizer pass (and the `scalarize-load-store` option)

LLVM has a **dedicated pass** for converting vector ops to scalar ops: `llvm/lib/Transforms/Scalar/Scalarizer.cpp`. Verified by direct fetch of `https://raw.githubusercontent.com/llvm/llvm-project/main/llvm/lib/Transforms/Scalar/Scalarizer.cpp`:

File header (lines 8-13):

```
// This pass converts vector operations into scalar operations (or, optionally,
// operations on smaller vector widths), in order to expose optimization
// opportunities on the individual scalar operations.
// It is mainly intended for targets that do not have vector units, but it
// may also be useful for revectorizing code to different vector widths.
```

The critical member variable (line 338 of main):

```cpp
const bool ScalarizeLoadStore;
```

`visitLoadInst` (lines 1217-1241) and `visitStoreInst` (lines 1242-1268) are the relevant entry points. The store-scalarisation core:

```cpp
bool ScalarizerVisitor::visitStoreInst(StoreInst &SI) {
  if (!ScalarizeLoadStore)
    return false;
  if (!SI.isSimple())
    return false;

  Value *FullValue = SI.getValueOperand();
  std::optional<VectorLayout> Layout = getVectorLayout(
      FullValue->getType(), SI.getAlign(), SI.getDataLayout());
  if (!Layout)
    return false;

  IRBuilder<> Builder(&SI);
  Scatterer VPtr = scatter(&SI, SI.getPointerOperand(), Layout->VS);
  Scatterer VVal = scatter(&SI, FullValue, Layout->VS);

  ValueVector Stores;
  Stores.resize(Layout->VS.NumFragments);
  for (unsigned I = 0; I < Layout->VS.NumFragments; ++I) {
    Value *Val = VVal[I];
    Value *Ptr = VPtr[I];
    Stores[I] =
        Builder.CreateAlignedStore(Val, Ptr, Layout->getFragmentAlign(I));
  }
  transferMetadataAndIRFlags(&SI, Stores);
  return true;
}
```

This is **literally** "take a `store <N x iW>` and emit N `store iW` instructions" behaviour. Exactly what Bennett.jl needs for Form B.

The option defaults to `false` (confirmed by LLVM PR #110645, https://github.com/llvm/llvm-project/pull/110645, which converted the legacy `cl::opt` into a pass parameter while preserving the default false value). To enable in the new pass manager, use `-passes="scalarizer<load-store>"`. WebSearch quote:

> "The `scalarize-load-store` option is a boolean option that allows the scalarizer pass to scalarize loads and stores. This option defaults to false."
> "It can be passed to the opt tool using syntax like `-passes=scalarizer<load-store>` to enable load/store scalarization when running the scalarizer pass."

### §3.2 SROA — does it help?

LLVM's Passes doc (https://llvm.org/docs/Passes.html) says:

> "sroa: The well-known scalar replacement of aggregates transformation. This transform breaks up `alloca` instructions of aggregate type (structure or array) into individual `alloca` instructions for each member if possible."

SROA **splits aggregate allocas into scalar allocas**. It does **not**, directly, split aggregate *stores into the sret pointer*. The sret pointer is a function argument, not an alloca, so SROA can't touch it the same way.

Worse, SROA has the "vector promotion" mode that *creates* the wide-vector stores we want to get rid of (quoted in §2.2). Running SROA is part of how we got into this state.

### §3.3 InstCombine — partial help

InstCombine folds `store <N x iW>` into a sequence of insertelement+store in some patterns but, as a rule, does **not** split a wide aligned vector store into N scalar stores (that would be pessimisation on targets with vector units). It isn't a canonicaliser for our goal.

Enzyme does use InstCombine after its own sret-splitting pass (`src/compiler/optimize.jl` line 406: `run!(InstCombinePass(), mod)` with comment "Instcombine breaks apart struct stores into individual components"), so it does have *some* useful struct-splitting effect on aggregate value stores, but it's not a vector-store splitter.

### §3.4 MemCpyOptimizer

From LLVM Passes docs:

> "memcpyopt: This pass performs various transformations related to eliminating `memcpy` calls, or transforming sets of stores into `memset`s."

MemCpyOpt's typical trick in the sret world is the opposite of what we want — it *collapses* a series of stores into a memcpy. The pass also does forward/backward memcpy elimination ("call-slot optimisation"). For Bennett.jl, MemCpyOpt is part of the Form A problem, not the solution.

### §3.5 No documented "de-aggregate sret" pipeline

I searched for a documented LLVM pipeline that canonicalises aggregate sret to scalar sret and found none. Every frontend (clang, rustc, Julia) handles this in its own frontend ABI code. The closest thing is Enzyme.jl's `memcpy_sret_split!` + `FixupJuliaCallingConventionSRetPass` (§5).

### §3.6 Takeaway for §3

- `Scalarizer` with load-store scalarisation is the only stock LLVM pass that mechanically rewrites `store <N x iW>` → N scalar `store iW`. Any Bennett solution that wants Form B → scalar should either use it or implement the same transform manually.
- SROA, InstCombine, MemCpyOpt do not canonicalise sret layouts for external consumers — SROA actively creates the vector-store form.
- There is no documented stock pipeline for "de-aggregate sret". Write it, borrow it from Enzyme, or walk IR that handles both forms.

---

## §4 — llvm.memcpy Canonicalisation

### §4.1 MemCpyOptimizer: what it does

Primary source: https://llvm.org/doxygen/MemCpyOptimizer_8cpp.html and the master source at https://github.com/llvm/llvm-project/blob/main/llvm/lib/Transforms/Scalar/MemCpyOptimizer.cpp.

From the pass description in LLVM's Passes docs:

> "This pass performs various transformations related to eliminating `memcpy` calls, or transforming sets of stores into `memset`s."

The main transforms:

1. **Call-slot optimisation.** If `alloca A` is filled and then `memcpy(dst, A, N)` copies it to `dst`, and `dst` is a suitable destination (e.g. sret or another alloca), the pass rewrites the original fill to write directly to `dst`, eliminating `A`.
2. **memcpy → memset.** If source bytes are known constant.
3. **Memcpy combining / chaining elimination.**

For our sret case, the common transform at -O2 is: alloca is filled, memcpy into sret, call-slot-opt rewrites to write directly into sret, then SROA + SLP promote the fill pattern into a vector store into sret. That's how Form A (memcpy) becomes Form B (vector store) under optimisation.

### §4.2 Can we force memcpy → individual loads/stores?

Not via a single stock LLVM pass applied to arbitrary memcpy. MemCpyOpt is focused on elimination, not expansion. However:

- The `LowerMemIntrinsics` utility (https://llvm.org/doxygen/LowerMemIntrinsics_8cpp.html, though I did not directly verify the exact URL) is used by several targets to expand `llvm.memcpy` into explicit load/store loops for backends that don't support the intrinsic. This is target-specific.
- **Enzyme's `memcpy_sret_split!` manually expands the memcpy following the Julia aggregate's nested structure.** See §5.3.
- **GPUCompiler's `lower_byval`** is the analogous approach for byval, not sret. See §6.

### §4.3 LLVM upstream issues

- https://github.com/llvm/llvm-project/issues/2590 ("[memcpyopt] fails to eliminate memcpy fed by sret") — documents the known LLVM weakness that MemCpyOpt can't always eliminate a memcpy whose destination is sret. This doesn't help us, but confirms the sret-memcpy space is a known sharp edge.
- https://github.com/llvm/llvm-project/issues/95152 ("[MemCpyOpt] Call slot optimization doesn't respect writeonly") — another sret/memcpy edge case.

### §4.4 Takeaway for §4

- There is no stock pass to explode `llvm.memcpy(dst, src, N)` into N individual typed loads/stores; it's always done by a frontend or a custom walker.
- Bennett.jl will either (a) walk memcpy intrinsics in `ir_extract.jl` with explicit handling for sret-destination memcpy, (b) port Enzyme's `memcpy_sret_split!` + `copy_struct_into!`, or (c) force the LLVM pipeline to canonicalise away the memcpy (MemCpyOpt does this in many but not all cases).

---

## §5 — Enzyme.jl's Approach to Aggregate Args/Returns

**Enzyme.jl is the single most valuable external reference for Bennett.jl.** It solves this exact problem in exactly this setting (Julia function → LLVM IR → IR analysis/transformation).

Repo: https://github.com/EnzymeAD/Enzyme.jl

### §5.1 Two-pronged approach

Enzyme registers two dedicated module passes specifically for Julia's sret calling convention (from `src/compiler/optimize.jl` lines 10-12, verified locally):

```julia
LLVM.@module_pass "enzyme-fixup-julia" FixupJuliaCallingConventionPass
LLVM.@module_pass "enzyme-fixup-julia-sret" FixupJuliaCallingConventionSRetPass
LLVM.@module_pass "enzyme-fixup-batched-julia" FixupBatchedJuliaCallingConventionPass
```

These are implemented in Enzyme's C++ side (`libEnzyme`) — the .cpp sources are not in the Enzyme.jl repo, they live in the EnzymeAD/Enzyme C++ repo (https://github.com/EnzymeAD/Enzyme). The Julia side is a thin pass-pipeline wrapper.

They are scheduled in `post_optimize!`, `src/compiler/optimize.jl` lines 395-427:

```julia
function post_optimize!(mod::LLVM.Module, tm::LLVM.TargetMachine, machine::Bool = true)
    addr13NoAlias(mod)
    
    removeDeadArgs!(mod, tm, #=post_gc_fixup=#false)
    
    memcpy_sret_split!(mod)
    # if we did the move_sret_tofrom_roots, we will have loaded out of the sret, then stored into the rooted.
    # we should forward the value we actually stored [fixing the sret to therefore be writeonly and also ensuring
    # we can find the root store from the jlvaluet]
    # Instcombine breaks apart struct stores into individual components
    run!(InstCombinePass(), mod)
    # GVN actually forwards
    @dispose pb = NewPMPassBuilder() begin
        registerEnzymeAndPassPipeline!(pb)
    	add!(pb, SimpleGVNPass())
        run!(pb, mod, tm)
    end
    ...
    @dispose pb = NewPMPassBuilder() begin
        registerEnzymeAndPassPipeline!(pb)
        add!(pb, "enzyme-fixup-batched-julia")
        if VERSION < v"1.12"
            add!(pb, "enzyme-fixup-julia-sret")
        else
            add!(pb, "enzyme-fixup-julia")
        end
        run!(pb, mod, tm)
    end
```

The ordering tells us:

1. Run `memcpy_sret_split!` first — Julia-side transform that splits memcpy-into-sret into per-field loads/stores.
2. Run `InstCombinePass` — breaks apart struct stores into individual components ("Instcombine breaks apart struct stores into individual components", their comment line 405).
3. Run `SimpleGVNPass` (Enzyme's own GVN) — forwards loads across the new split stores.
4. Run the C++-side `enzyme-fixup-julia-sret` pass (for Julia < 1.12) or `enzyme-fixup-julia` (for 1.12+) — the final "massage the sret ABI into something Enzyme's differentiation machinery can consume".

**Key observation:** Enzyme does not run the LLVM `Scalarizer` pass. They chose instead to walk the IR themselves via `memcpy_sret_split!`, then rely on `InstCombine` to break up aggregate stores into scalar stores.

### §5.2 `memcpy_sret_split!` — the crucial Julia-side pass

From `src/llvm/transforms.jl` lines 589-649 (verified locally):

```julia
# Split a memcpy into an sret with jlvaluet into individual load/stores
function memcpy_sret_split!(mod::LLVM.Module)
    dl = datalayout(mod)
    ctx = context(mod)
    sretkind = LLVM.kind(if LLVM.version().major >= 12
                LLVM.TypeAttribute("sret", LLVM.Int32Type())
            else
                LLVM.EnumAttribute("sret")
            end)
    for f in functions(mod)
        if length(blocks(f)) == 0
            continue
        end
        if length(parameters(f)) == 0
            continue
        end
        sty = nothing
        for attr in collect(LLVM.parameter_attributes(f, 1))
            if LLVM.kind(attr) == sretkind
                 sty = LLVM.value(attr)
                 break
            end
        end
        if sty === nothing
            continue
        end
        tracked = CountTrackedPointers(sty)
        if tracked.all || tracked.count == 0
            continue
        end
        todo = LLVM.CallInst[]
        for bb in blocks(f)
            for cur in instructions(bb)
                    if isa(cur, LLVM.CallInst) &&
                       isa(LLVM.called_operand(cur), LLVM.Function)
                        intr = LLVM.API.LLVMGetIntrinsicID(LLVM.called_operand(cur))
                        if intr == LLVM.Intrinsic("llvm.memcpy").id
                            dst, _ = get_base_and_offset(operands(cur)[1]; offsetAllowed = false)
                            if isa(dst, LLVM.Argument) && parameters(f)[1] == dst
                            if isa(operands(cur)[3], LLVM.ConstantInt) && LLVM.sizeof(dl, sty) == convert(Int, operands(cur)[3])
                                push!(todo, cur)
                            end
                            end
                        end
                    end
            end
        end
        for cur in todo
              B = IRBuilder()
              position!(B, cur)
              dst, _ = get_base_and_offset(operands(cur)[1]; offsetAllowed = false)
              src, _ = get_base_and_offset(operands(cur)[2]; offsetAllowed = false)
              if !LLVM.is_opaque(value_type(dst)) && eltype(value_type(dst)) != eltype(value_type(src))
                  src = pointercast!(B, src, LLVM.PointerType(eltype(value_type(dst)), addrspace(value_type(src))), "memcpy_sret_split_pointercast")
              end
              copy_struct_into!(B, sty, dst, src, VERSION < v"1.12")
              LLVM.API.LLVMInstructionEraseFromParent(cur)
        end
    end
end
```

**What it does, distilled:**
- Walk each function.
- Look at parameter 1, find the `sret(<ty>)` type attribute — pull out the Julia struct type.
- Find every `llvm.memcpy` call where the destination is the sret parameter and the size matches the sret type size.
- For each such memcpy, call `copy_struct_into!(builder, sretTy, dst, src, false)` which recursively walks the LLVM struct type and emits individual `load`+`store` pairs per leaf field.
- Erase the original memcpy.

This handles **Form A** entirely. It does nothing about Form B.

### §5.3 `copy_struct_into!` — recursive field-level loads/stores

From `src/compiler.jl` lines 4152-4219 (verified locally):

```julia
function copy_struct_into!(builder::LLVM.IRBuilder, jltype::LLVM.LLVMType, dst::LLVM.Value, src::LLVM.Value, copy_jlvalues::Bool)
    count = 0
    todo = Tuple{Vector{Cuint},LLVM.LLVMType}[(
        Cuint[],
        jltype,
    )]

    extracted = LLVM.Value[]
    ...

    while length(todo) != 0
            path, ty = popfirst!(todo)

            if isa(ty, LLVM.PointerType) && any_jltypes(ty) && !copy_jlvalues
                continue
            end

            if isa(ty, LLVM.ArrayType) && any_jltypes(ty)
                for i = 1:length(ty)
                    npath = copy(path)
                    push!(npath, i - 1)
                    push!(todo, (npath, eltype(ty)))
                end
                continue
            end

            if isa(ty, LLVM.VectorType) && any_jltypes(ty)
                for i = 1:size(ty)
                    npath = copy(path)
                    push!(npath, i - 1)
                    push!(todo, (npath, eltype(ty)))
                end
                continue
            end

            if isa(ty, LLVM.StructType) && any_jltypes(ty)
                for (i, t) in enumerate(LLVM.elements(ty))
                    npath = copy(path)
                    push!(npath, i - 1)
                    push!(todo, (npath, t))
                end
                continue
            end

        dstloc = inbounds_gep!(builder, jltype, dst, to_llvm(path), "dstloccs")
        srcloc = inbounds_gep!(builder, jltype, src, to_llvm(path), "srcloccs")
        val = load!(builder, ty, srcloc)
        st = store!(builder, val, dstloc)
        end
    return nothing
end
```

**Note the recursive structure-walking.** It handles `ArrayType`, `VectorType` (!), and `StructType` uniformly, descending until it finds a leaf scalar type, then emits a `load`/`store` for that leaf. For an `[9 x i64]` sret-typed slot, it emits 9 `load i64` + 9 `store i64` pairs.

**Caveat — the `any_jltypes(ty)` gate:** Enzyme only splits fields that contain boxed Julia values (tracked pointers in addrspace 10 — `prjlvalue`). For pure primitive `[9 x i64]`, `any_jltypes` returns false and **none** of the recursive cases fire. The scalar-leaf path at the bottom handles the whole type as a single load/store because the type doesn't contain `jlvaluet`.

Actually looking again — the `any_jltypes` gate short-circuits the recursion for fields that DON'T contain pointers. For a plain `[9 x i64]`, at the top level `any_jltypes(ArrayType [9 x i64])` is false, so the outer ArrayType case is skipped, and the entire `[9 x i64]` is loaded-and-stored as one value. This is a design choice specific to Enzyme's needs (they care about jlvaluet-tracking) — Bennett.jl would want to recurse unconditionally.

### §5.4 Before-differentiation pipeline

From `src/compiler/optimize.jl` — Enzyme's full optimiser (lines 32-211 from verified local copy):

- `optimize!` runs a big block of Julia-style passes (`PropagateJuliaAddrspacesPass`, `SROAPass`, `MemCpyOptPass`, `AllocOptPass`, …) — identical in spirit to stock Julia's optimiser, though hand-built.
- `middle_optimize!` inside `optimize!` runs the heavy scalar/loop/vector pipeline (InstCombine, JumpThreading, LICM, IndVarSimplify, LoopUnroll, SROA, GVN, MemCpyOpt, …). **No Scalarizer.**
- `addOptimizationPasses!` (lines 213-315) includes `LoopVectorizePass`, `SLPVectorizerPass` — similar to stock Julia.

Pre-Enzyme-diff, the IR is heavily optimised, including vectorisation. Enzyme's `post_optimize!` is where the sret-fixup happens AFTER the main optimiser. So the sequence is:
1. Julia frontend → LLVM IR (with Julia-specific addrspaces, boxes, etc.).
2. Enzyme's `optimize!` — a near-Julia-stock optimisation pipeline.
3. `post_optimize!` — the final clean-up including `memcpy_sret_split!` and the C++-side `enzyme-fixup-julia-sret`.
4. Enzyme's differentiator walks the clean IR.

### §5.5 Takeaway for §5

- **Enzyme.jl has solved Bennett's exact problem for Form A (memcpy).** Their approach: read the sret type attribute, find memcpys targeting the sret pointer, and replace them with recursive per-leaf load/store pairs via a helper (`copy_struct_into!`). Estimated effort to port: a few hundred LOC of Julia + LLVM.jl.
- They handle Form B (vector store) **implicitly via InstCombine + GVN** rather than via Scalarizer. After `memcpy_sret_split!` there are no aggregate stores to fight with — so they use InstCombine to crack any remaining struct-value stores into scalar stores.
- The C++-side `FixupJuliaCallingConventionSRetPass` is opaque from the Julia side but its name and scheduling make its role clear: "fix up Julia's sret calling convention to something clean". It may rewrite the function signature to put the returned struct back into a `ret` or normalise the sret further — we don't have the source. If Bennett.jl needs that level of ABI rewriting, the Enzyme C++ repo would be the next place to study.
- **Bennett.jl should seriously consider lifting Enzyme's `memcpy_sret_split!` pattern wholesale.** It's MIT-licensed, battle-tested, and matches Bennett's use case (walk clean scalar IR).

---

## §6 — GPUCompiler.jl / Generic Julia IR Tooling

Repo: https://github.com/JuliaGPU/GPUCompiler.jl

### §6.1 `deserves_sret` — same as Julia core

From `src/irgen.jl` line 378 (verified locally):

```julia
function deserves_sret(T, llvmT)
    @assert isa(T,DataType)
    sizeof(T) > sizeof(Ptr{Cvoid}) && !isa(llvmT, LLVM.FloatingPointType) && !isa(llvmT, LLVM.VectorType)
end
```

Byte-for-byte equivalent to Julia's own `deserves_sret` (§1.2). GPUCompiler doesn't try to change this.

### §6.2 `lower_byval` — not what we need, but analogous

`src/irgen.jl` lines 388-499 defines `lower_byval`, which unwraps byval aggregate arguments for backends that don't support byval well. The PR referenced is https://reviews.llvm.org/D79744 (a Clang PR about byval support). The comment (line 386):

```julia
# byval lowering
#
# some back-ends don't support byval, or support it badly, so lower it eagerly ourselves
# https://reviews.llvm.org/D79744
```

The pass:
1. Finds parameters with the `byval` attribute.
2. Generates a new function whose byval params are replaced by value-typed params.
3. For each byval param in the new function, alloca a slot, store the value into it, then pass the slot pointer to the body (which was cloned from the original).
4. Replaces the original function.

**This is an inverse/analogous transformation to what Bennett needs for sret.** GPUCompiler solves "backend doesn't like byval" by converting byval pointer args into value args. Bennett wants to solve "backend doesn't like vector-store-into-sret" by normalising the IR after the fact. The pattern is comparable: inspect parameter attributes, build a new function, migrate bodies.

Enzyme's `lower_convention` in `src/compiler.jl` line 4222 (`# Modified from GPUCompiler/src/irgen.jl:365 lower_byval`) literally starts from GPUCompiler's `lower_byval` and generalises it. So this is a known-good pattern in the Julia-compiler ecosystem.

### §6.3 GPUCompiler sret handling

`src/interface.jl` line 90 documents `entry_abi=:specfunc`:

> "`:specfunc` expects the arguments to be passed in registers, simple return values are returned in registers as well, and complex return values are returned on the stack using `sret`, the calling convention is `fastcc`."

GPUCompiler uses the same sret convention as Julia native — it doesn't invent its own. There is no GPUCompiler-specific "sret canonicalisation" pass (verified by grepping `/tmp/gpucompiler/src` for `sret|StructRet|aggregate|NTuple` — the matches are all in `interface.jl:90`, `irgen.jl:378`, `irgen.jl:388`).

GPUCompiler's pipeline is configurable — see https://github.com/JuliaGPU/GPUCompiler.jl/issues/23 ("Make Julia's optimization passes configurable") — but it doesn't ship with a dedicated sret-canonicalising pass. GPU backends that need scalarised memory ops bring their own (e.g., the PTX backend uses `lower_byval`).

### §6.4 Takeaway for §6

- GPUCompiler.jl doesn't solve the sret-vectorisation problem. It solves the related byval problem with `lower_byval`. The pattern (attribute-inspect, clone function, migrate) is reusable.
- GPUCompiler's `deserves_sret` is identical to Julia core's — no behavioural divergence there.

---

## §7 — Julia's `abi_*.cpp` and `pipeline.cpp` — Primary Source

Repo: https://github.com/JuliaLang/julia (master branch, verified locally).

### §7.1 ABI files and the sret decision tree

- `src/abi_x86_64.cpp` (SYSV AMD64): `use_sret` delegates to a SYSV classifier. 16-byte threshold for primitives. Anything structured >16 bytes or non-register-mappable → `Memory` → sret.
- `src/abi_win64.cpp`: `use_sret` returns true unless size ∈ {1,2,4,8} or `is_native_simd_type`.
- `src/abi_aarch64.cpp`: `use_sret` delegates to `classify_arg()`. HFA rules (up to 4 same-type floating-point/SIMD fields) can keep aggregates in SIMD regs.
- `src/abi_arm.cpp`, `src/abi_riscv.cpp`, `src/abi_ppc64le.cpp`, `src/abi_win32.cpp`, `src/abi_x86.cpp`: other targets. Each implements `AbiLayout::use_sret` / `needPassByRef` / `preferred_llvm_type`.
- `src/ccall.cpp` lines 385-402: `is_native_simd_type` checks for homogeneous VecElement-like tuples that can be represented as SIMD register types.

None of these platform-specific files affect the Bennett scenario qualitatively — all of them return "sret" for an `NTuple{9,UInt64}` (72 bytes, no HFA/SIMD qualification).

### §7.2 `pipeline.cpp` — the Julia pass pipeline

`src/pipeline.cpp` (verified, 1194 lines), pass insertion sites for SROA/SLP/MemCpyOpt:

```cpp
// line 362 (early simplification):
FPM.addPass(SROAPass(SROAOptions::ModifyCFG));

// line 407 (early optimiser):
FPM.addPass(SROAPass(SROAOptions::ModifyCFG));

// lines 482-494 (scalar optimiser, speedup >= 2):
if (O.getSpeedupLevel() >= 2) {
    JULIA_PASS(FPM.addPass(AllocOptPass()));
    FPM.addPass(SROAPass(SROAOptions::ModifyCFG));
    FPM.addPass(VectorCombinePass(/*TryEarlyFoldsOnly=*/true));
    FPM.addPass(MergedLoadStoreMotionPass());
    FPM.addPass(GVNPass());
    FPM.addPass(SCCPPass());
    FPM.addPass(BDCEPass());
    FPM.addPass(InstCombinePass());
    FPM.addPass(CorrelatedValuePropagationPass());
    FPM.addPass(ADCEPass());
    FPM.addPass(MemCpyOptPass());
    FPM.addPass(DSEPass());
    ...

// lines 498-506 (scalar optimiser, speedup >= 1):
else if (O.getSpeedupLevel() >= 1) {
    JULIA_PASS(FPM.addPass(AllocOptPass()));
    FPM.addPass(SROAPass(SROAOptions::ModifyCFG));
    FPM.addPass(MemCpyOptPass());
    ...

// lines 540-553 (vector pipeline, speedup >= 2):
FPM.addPass(LoopDistributePass());
FPM.addPass(InjectTLIMappings());
FPM.addPass(LoopVectorizePass());
FPM.addPass(LoopLoadEliminationPass());
FPM.addPass(SimplifyCFGPass(aggressiveSimplifyCFGOptions()));
FPM.addPass(createFunctionToLoopPassAdaptor(LICMPass(LICMOptions()), /*UseMemorySSA=*/true, /*UseBlockFrequencyInfo=*/false));
FPM.addPass(EarlyCSEPass());
FPM.addPass(CorrelatedValuePropagationPass());
FPM.addPass(InstCombinePass());
FPM.addPass(SLPVectorizerPass());
FPM.addPass(VectorCombinePass());
invokeVectorizerCallbacks(FPM, PB, O);
FPM.addPass(LoopUnrollPass(LoopUnrollOptions(O.getSpeedupLevel(), /*OnlyWhenForced = */ false, /*ForgetSCEV = */false)));
FPM.addPass(SROAPass(SROAOptions::PreserveCFG));
```

Critical confirmations:

- **SROA runs 4 times** in the pipeline. Each call is `SROAOptions::ModifyCFG` (aggressive vector-promotion permitted) except the post-vectorisation one (`PreserveCFG`).
- **SLPVectorizer runs only at `speedup ≥ 2`**. This is what Julia's `-O2` default invokes.
- **VectorCombine runs at `speedup ≥ 2`** — this is the pass that merges adjacent insertelement/extractelement ops.
- **MemCpyOpt runs at `speedup ≥ 1`** — even at `-O1`, memcpys get eliminated/shortened.
- **Scalarizer is NOT in the pipeline.** `grep -n "Scalarizer" pipeline.cpp` returns nothing (I verified with local grep: match count 0). Julia never runs Scalarizer.

At `optimize=false`, none of the above passes runs, so the raw codegen (memcpy-into-sret) survives — that's Bennett's Form A.
At `optimize=true`, the default is Julia's `-O2` setup which runs SROA+SLP+VectorCombine and thus Form B.

### §7.3 Interaction between SROA and Julia's sret

There's no magical special-case for sret in Julia's pipeline. SROA sees:
- An alloca whose stores feed a memcpy into the sret pointer (call-slot-opt'd from MemCpyOpt), OR
- An alloca whose stores feed multiple scalar stores into the sret pointer.

In either case, SROA with `ModifyCFG` tries to promote the alloca to a vector-of-scalars, which (combined with SLP or early VectorCombine) coalesces adjacent stores into `store <N x iW>`.

Julia is aware of memcpy/sret interaction (issue https://github.com/JuliaLang/julia/issues/38751 "LLVM not optimizing memcpy on Windows") but the thrust of these issues is about *performance* of the optimised code, not about the shape of the IR as seen by external walkers.

### §7.4 Takeaway for §7

- Julia's pipeline is stock-LLVM-plus-Julia-custom-passes; at `-O2` the sret-vectorisation is an inherent consequence of running stock SROA+SLP on aggregate alloca+sret code.
- **Bennett should either compile with `optimize=false` and handle Form A, or accept both forms and canonicalise post-hoc.**
- If Bennett wants a "mostly-optimised but sret-canonicalised" IR, inserting Scalarizer after the main pipeline or disabling `SLPVectorizerPass`/`VectorCombinePass` would be options — neither is typical.

---

## §8 — Reversible / Quantum Compiler Projects

I searched for relevant prior art in reversible-circuit compilation. Summary: **no existing reversible compiler ingests LLVM IR from a general-purpose compiler**, so the aggregate-return problem is essentially unique to Bennett.jl.

### §8.1 ReVerC (Amy, Parent, Roetteler, Svore; 2017)

- Paper: https://arxiv.org/abs/1603.01635
- Source: https://github.com/msr-quarc/ReVerC

From WebSearch results:

> "ReVerC (pronounced 'reverse') is a reversible circuit compiler which compiles a high-level, ml-like language to combinational reversible circuits. It is fully verified in the sense that the program and compiled circuit, when generated by ReVerC, will produce the same output for every input, and it is formally verified that any ancilla bits used by the compiler are correctly cleaned and returned to the pool of 0-initialized ancillas."

ReVerC's input is an "ml-like language" (surface syntax) not LLVM IR. Aggregate types in that language don't exist in the same LLVM-lowering sense. No relevance to Bennett's sret/NTuple problem.

### §8.2 Revs (Parent, Svore, 2015)

The predecessor of ReVerC. Targets the "Revs" ml-like surface language compiled via F#. No LLVM ingestion.

### §8.3 Quipper

WebSearch summary:

> "The more recent Quipper automatically generates reversible circuits from classical code by a process called lifting, and unlike languages such as Quipper, ReVerC's strictly combinational target architecture doesn't allow computations in the meta-language to depend on computations within Revs."

Quipper is Haskell-embedded. No LLVM ingestion. No aggregate-return problem at the IR level.

### §8.4 Silq (ETH Zürich)

Silq is its own surface-level quantum language with its own runtime. Not LLVM-based. No relevance.

### §8.5 Takeaway for §8

- **Bennett.jl appears to be unique in using LLVM IR (from a general-purpose compiler, via LLVM.jl) as the ingestion format for a reversible circuit compiler.** None of Revs/ReVerC/Quipper/Silq use LLVM IR as input.
- Therefore the NTuple-sret problem is not a reversible-computing problem per se; it's a "Julia → LLVM IR → IR analysis" problem. The relevant prior art is Enzyme.jl and GPUCompiler.jl (covered in §5, §6), not other reversible compilers.
- **This problem is narrow in scope.** It is Bennett-specific in that no prior reversible compiler has faced it, but it is also well-understood in the Julia/LLVM community (Enzyme faces it daily).

---

## §9 — Julia GitHub Issues / Discussions

I searched JuliaLang/julia for related issues. Findings:

### §9.1 Issue #8921 — "llvmcall translates pointer to NTuple in Julia to pointer to vector in LLVM"

https://github.com/JuliaLang/julia/issues/8921 — opened 2014-11-06 by @toivoh. WebFetch summary:

> "The issue reports that `llvmcall` incorrectly translates `Ptr{UInt64x2}` (where `UInt64x2 = NTuple{2,UInt64}`) to `<2 x i64>*` in LLVM IR, when the actual memory layout differs. This causes incorrect behavior when loading from pointers to tuple arrays."
> "The reporter demonstrates that while `UInt64x2` maps to `<2 x i64>` in LLVM, pointers don't align the same way: 'an array of tuples is currently not stored packed inline.'"

This is actually about an older version of Julia where homogeneous 2-element NTuples would spuriously be mapped to `<2 x i64>` by `llvmcall` specifically (not regular codegen). The reporter's diagnosis: tuple memory layout doesn't match the `<2 x i64>` layout. Relevant because it confirms "NTuple → vector" mapping has been a persistent source of confusion. **No maintainer responses were visible from the WebFetch — I note this limitation.**

### §9.2 Issue #11899 — "SLP vectorization not working for tuples"

https://github.com/JuliaLang/julia/issues/11899 — Julia 0.4 era.

> "The reporter attempted to reproduce tuple vectorization examples from PR #6271, where operations on `NTuple{4,Float32}` were expected to be vectorized by LLVM. Instead, the generated LLVM code shows: Individual scalar operations (separate `fmul`, `fadd` instructions for each tuple element); Element-by-element access via `getelementptr` and `load` operations; Results assembled using `insertvalue` instructions."
> "Rather than generating vectorized SIMD operations on the entire tuple as a vector, Julia was treating the four Float32 elements as separate scalar values, eliminating the performance benefits of SLP vectorization."

Note the **opposite** problem to Bennett's: here the user wanted vectorisation, didn't get it. In later Julia versions, SLP works well on homogeneous tuples — which is precisely why Bennett sees Form B at `-O2`.

### §9.3 Issue #52819 — "Assertion failure during SROA"

https://github.com/JuliaLang/julia/issues/52819

> "An assertion failure occurs in the SROA (Scalar Replacement of Aggregates) optimization pass during type inference... The issue was introduced in PR #52608 and represents a regression in Julia's compiler optimizer."
> "Resolution: The issue was closed via PR #52866"

This is about Julia's own internal SSAIR SROA pass (not LLVM SROA). Not directly relevant but a reminder that SROA-style passes are complex and bug-prone at both the Julia and LLVM levels.

### §9.4 Issue #38751 — "LLVM not optimizing memcpy on Windows"

https://github.com/JuliaLang/julia/issues/38751

WebFetch returned limited content but confirmed the topic: memcpy emitted for aggregate returns on Windows doesn't get optimised away at -O2 as aggressively as on Linux. The underlying cause is LLVM's memcpy-optimiser limitations around sret (LLVM issues #2590, #95152, #104794 referenced).

### §9.5 Issue #2496 — "more efficient tuple representation"

https://github.com/JuliaLang/julia/issues/2496 — historical issue about how to represent tuples efficiently. Context for why Julia's tuple-to-LLVM mapping is what it is. Not actionable for Bennett.

### §9.6 Takeaway for §9

- **Julia core tracks the NTuple-SLP-SROA interaction as a "feature that sometimes works, sometimes doesn't".** There is no issue I found where a maintainer said "we will guarantee this IR shape for external consumers".
- **Julia's position is implicitly: if you want to walk LLVM IR, you have to be ready for whatever the pipeline emits.** This matches Julia's own principle #5 in Bennett's CLAUDE.md: "LLVM IR IS NOT STABLE."
- Bennett.jl's strategy must assume the worst and canonicalise.

---

## §10 — LLVM Documentation on sret / Aggregate ABI

Primary: https://llvm.org/docs/LangRef.html (Parameter Attributes section). I downloaded the raw RST source (`llvm/docs/LangRef.rst` from master branch, 32702 lines, verified locally).

### §10.1 `sret` attribute — verbatim from LangRef

From `llvm/docs/LangRef.rst` lines 1435-1445 (master, verified):

```
``sret(<ty>)``
    This indicates that the pointer parameter specifies the address of a
    structure that is the return value of the function in the source
    program. This pointer must be guaranteed by the caller to be valid:
    loads and stores to the structure may be assumed by the callee not
    to trap and to be properly aligned.

    The sret type argument specifies the in-memory type.

    A function that accepts an ``sret`` argument must return ``void``.
    A return value may not be ``sret``.
```

### §10.2 `byval` attribute — verbatim

From lines 1336-1354:

```
``byval(<ty>)``
    This indicates that the pointer parameter should really be passed by
    value to the function. The attribute implies that a hidden copy of
    the pointee is made between the caller and the callee, so the callee
    is unable to modify the value in the caller. This attribute is only
    valid on LLVM pointer arguments. It is generally used to pass
    structs and arrays by value, but is also valid on pointers to
    scalars. The copy is considered to belong to the caller not the
    callee (for example, ``readonly`` functions should not write to
    ``byval`` parameters). This is not a valid attribute for return
    values.

    The byval type argument indicates the in-memory value type.

    The byval attribute also supports specifying an alignment with the
    ``align`` attribute. It indicates the alignment of the stack slot to
    form and the known alignment of the pointer specified to the call
    site. If the alignment is not specified, then the code generator
    makes a target-specific assumption.
```

### §10.3 `noalias` attribute — verbatim

From lines 1483-1488:

```
``noalias``
    This indicates that memory locations accessed via pointer values
    :ref:`based <pointeraliasing>` on the argument or return value are not also
```

(cut off in my grep with `-A 5`; the rest is standard "are not also accessed via other paths" language).

### §10.4 LLVM Passes — Scalarizer

LLVM `Scalarizer` pass (`llvm/lib/Transforms/Scalar/Scalarizer.cpp` on master):

File header (lines 8-13):

```
// This pass converts vector operations into scalar operations (or, optionally,
// operations on smaller vector widths), in order to expose optimization
// opportunities on the individual scalar operations.
// It is mainly intended for targets that do not have vector units, but it
// may also be useful for revectorizing code to different vector widths.
```

Options (from PR https://github.com/llvm/llvm-project/pull/110645 "Scalarizer: Replace cl::opts with pass parameters" and from member variable declarations in lines 338-339):

```cpp
const bool ScalarizeLoadStore;   // defaults to false
const unsigned ScalarizeMinBits;
```

Enabling via the new pass manager: `-passes="scalarizer<load-store>"`. Legacy: `-scalarizer -scalarize-load-store=true` (pre-PR-110645).

The store-scalarisation logic (lines 1242-1268, quoted in §3.1) does exactly what we want for Form B.

### §10.5 LLVM Passes — SROA (from docs)

LLVM Passes docs (https://llvm.org/docs/Passes.html):

> "sroa: The well-known scalar replacement of aggregates transformation. This transform breaks up `alloca` instructions of aggregate type (structure or array) into individual `alloca` instructions for each member if possible."

From the SROA.cpp doxygen (https://llvm.org/doxygen/SROA_8cpp.html), confirming the vector-promotion behaviour:

> "The pass will try to detect a pattern of accesses which map cleanly onto insert and extract operations on a vector value, and convert them to this form."

### §10.6 LLVM Passes — MemCpyOpt

LLVM Passes docs:

> "memcpyopt: This pass performs various transformations related to eliminating `memcpy` calls, or transforming sets of stores into `memset`s."

### §10.7 LLVM docs — "de-aggregate sret" explicitly

**I could not find any LLVM documentation describing a canonical "de-aggregate sret" transformation.** Every sret-aware frontend (clang, rustc, Julia) implements its own ABI machinery, and post-optimisation IR canonicalisation is not a common LLVM use-case.

### §10.8 Takeaway for §10

- LLVM's `sret(<ty>)` attribute is well-specified: the pointer is the address of the return structure, the function returns void, the callee assumes valid alignment/access. Bennett.jl can rely on these semantics.
- The `Scalarizer<load-store>` pass is the ONLY documented stock LLVM pass that mechanically splits `store <N x iW>` into N scalar `store iW`.
- No documented LLVM-side "fix up sret layout" pipeline exists; anyone walking IR has to handle it themselves.

---

## §11 — Practical Tool Recommendations (External Precedent)

**Reminder:** this section summarises what external actors (Enzyme, GPUCompiler, stock LLVM) provide as building blocks. Bennett.jl's specific choice is synthesis, out of this doc's scope. I enumerate options with ground-truth citations.

### §11.1 Option A — extract with `optimize=false`, handle Form A explicitly

Cite: Julia's default behaviour, `src/pipeline.cpp`. At `optimize=false`, no LLVM passes run; Julia emits memcpy-based sret.

Handling Form A requires:
- Recognising `llvm.memcpy.p0.p0.i64(sret_ptr, src, N, false)` intrinsic calls where the destination is the sret parameter.
- Replacing the memcpy with N individual typed loads from `src` and stores to `sret_ptr`, based on the sret parameter's typed attribute (or the known Julia type).

Precedent: Enzyme's `memcpy_sret_split!` + `copy_struct_into!` (§5.2, §5.3).

Trade-off: losing optimisation means 1.1x-7.1x slower input code (WebSearch cited Julia LLVM docs for this). For a compiler like Bennett that walks IR rather than executing it, this is largely irrelevant — the generated reversible circuit is independent of whether the source LLVM IR was optimised, provided semantics are preserved.

### §11.2 Option B — extract with `optimize=true`, handle both Forms

Requires handling Form B (vector stores into sret):
- Either run `Scalarizer<load-store>` after the main pipeline to split `store <N x iW>` into N scalar stores (§3.1).
- Or walk the IR's vector stores manually, splitting them by element index.

Precedent for Scalarizer: the pass itself (§3.1, §10.4). LLVM ships it, it's stable, it's designed for targets without vector hardware — Bennett's target (reversible circuits) literally doesn't have vector hardware.

Precedent for manual splitting: Enzyme's reliance on InstCombine after `memcpy_sret_split!` (§5.1).

### §11.3 Option C — port Enzyme's full two-prong approach

Lift Enzyme's `memcpy_sret_split!` verbatim (MIT licensed) + run InstCombine after it + possibly add Scalarizer for the vector-store path. This is the most robust option given it's battle-tested on real Julia-derived IR.

Precedent: entire Enzyme pipeline, §5.

Costs: takes on ~50 LOC of Julia for `memcpy_sret_split!` and ~70 LOC for `copy_struct_into!`, plus a dependency on InstCombine from LLVM.jl.

### §11.4 Option D — custom optimisation pipeline that avoids vector promotion

From `src/pipeline.cpp`: SROA (with `ModifyCFG`), SLPVectorizer, VectorCombine are the passes that introduce Form B. In principle Bennett could build a custom optimisation pipeline that runs everything **except** those three.

Problems:
- SROA-without-vector-promotion is not directly available; SROA has `ModifyCFG` vs `PreserveCFG` flags but both permit vector promotion when the alloca's accesses fit.
- Disabling SLP alone leaves InstCombine+VectorCombine able to produce vector stores.
- Disabling vectorisation gives up the cleanup that MemCpyOpt relies on.

This option is the most brittle and not well-supported by external precedent. No one in the Julia ecosystem ships a "SROA-without-vectorisation" pipeline.

### §11.5 Option E — force `llvm_returns_first` / change calling convention

I checked whether Julia exposes a way to force aggregate-return-in-registers. Searched `src/codegen.cpp` and `src/abi_*.cpp` for "returns_first", "force_scalar_return", etc. No such option exists in the Julia code.

Julia's `entry_abi=:specfunc` vs `:func` (from GPUCompiler, §6.3) chooses between the native specfunc convention (with sret) and the boxed generic convention. Neither eliminates sret for an `NTuple{9,UInt64}` — both would spill through boxing or sret.

The ccall ABI (where the user chooses return representation) is separate from the specfunc ABI and is NOT what Bennett is using.

**Conclusion: there is no external "force scalar return" option.** This option is not available.

### §11.6 Precedent summary table

| Approach | External precedent | Ships with? | Robust? |
|---|---|---|---|
| `optimize=false` + handle memcpy | Enzyme.jl `memcpy_sret_split!` (MIT) | Enzyme | Yes (for Form A only) |
| Run `Scalarizer<load-store>` post-pipeline | LLVM stock pass | LLVM | Yes (for Form B only) |
| Port Enzyme's two-prong pipeline | Enzyme.jl `post_optimize!` (MIT) | Enzyme | Yes (most battle-tested) |
| Custom no-vectorisation pipeline | None | — | No |
| Force scalar return | Doesn't exist | — | — |

### §11.7 Takeaway for §11

- External precedent strongly favours **extracting Form A (memcpy) and splitting it** (Enzyme.jl approach) over fighting Form B (vector stores).
- If Bennett can compile with `optimize=false` (which it currently uses per CLAUDE.md principle #5 — "Always use `optimize=false` for predictable IR when testing"), the Form A path is sufficient, and Enzyme's `memcpy_sret_split!` is the blueprint.
- If Bennett wants to allow `optimize=true`, adding `Scalarizer<load-store>` to the pipeline (or a custom splitter) covers Form B.

---

## §12 — Open Questions / Limitations of This Research

I could not verify the following things and note them explicitly:

1. **No maintainer comments visible for issue #8921.** WebFetch returned only the issue body. If there are substantive comments (likely, given the issue age), I don't have them.
2. **Enzyme's C++-side `FixupJuliaCallingConventionSRetPass` source was not inspected.** It lives in EnzymeAD/Enzyme (C++), not Enzyme.jl. I know what the pass is called and when it's scheduled, not its exact implementation.
3. **LLVM-version-specific differences in SROA/SLP behaviour.** Bennett's observed `store <4 x i64>` at byte offset 8 suggests LLVM split the 9-element tuple into a `<4 x i64>` vector plus smaller stores. The exact grouping depends on target alignment heuristics in SLPVectorizer and the target's preferred vector width. I didn't trace which LLVM version is in use in Julia master or identify the exact SLP-cost-model decision.
4. **I did not test the `Scalarizer<load-store>` pass on a Julia-emitted IR example.** The claim that it correctly handles Julia-style `store <4 x i64> %val, ptr %sret_arg` is based on reading `visitStoreInst` source; empirical verification is out of scope for a research doc but trivial for the synthesis step.
5. **LLVM LangRef's sret "writeonly" constraint.** The current `sret` attribute spec (§10.1) does NOT require the pointer be writeonly — the callee "may assume valid" but can also read. Some older LLVM versions tightened this. I didn't chase the historical timeline.
6. **Enzyme's `any_jltypes` gate in `copy_struct_into!`.** The pass only splits if the struct contains boxed Julia values. For a pure-primitive `[9 x i64]`, the recursion short-circuits and a single load/store pair is emitted. Bennett would need to remove this gate (or replicate only the recursive core) for its use case.

---

## Consolidated Findings

**What Julia emits for `NTuple{9,UInt64}`:**
- Front-end LLVM type: `[9 x i64]` (an `ArrayType`, NOT a `VectorType` — §1.3).
- sret calling convention: yes, on x86_64 SYSV (72 bytes > 16-byte threshold — §1.4, §7.1).
- `sret([9 x i64])` attribute with `noalias nocapture noundef align 8` on param 1 (§1.5).
- Return type: `void` (§1.5, §10.1).

**What shape the sret store takes:**
- `optimize=false` → `llvm.memcpy.p0.p0.i64(sret, src, i64 72, i1 false)` — Form A (§2.1).
- `optimize=true` → one or more `store <N x i64>, ptr <offset-gep>, align <A>` at various byte offsets — Form B (§2.2), introduced by SROA (vector-promotion) + SLPVectorizer + VectorCombine.

**External precedents for canonicalising this:**
- **Enzyme.jl's `memcpy_sret_split!`** (§5.2) handles Form A: find memcpy-into-sret, replace with per-leaf loads/stores.
- **LLVM's `Scalarizer` pass with `ScalarizeLoadStore=true`** (§3.1, §10.4) handles Form B: split `store <N x iW>` into N individual scalar stores.
- **No comparable transform exists in stock Julia, GPUCompiler.jl, or the reversible-computing literature** (§6, §8).

**This problem is narrow:** it's specific to walking post-Julia-frontend LLVM IR for aggregate-returning functions. It's well-understood in the Julia compiler ecosystem (Enzyme solves it daily). It's unique to Bennett among reversible compilers only because no one else tried ingesting LLVM IR.

**External precedent recommends:** walk both forms, with `memcpy_sret_split!` handling Form A and either `Scalarizer<load-store>` or a hand-written vector-store splitter handling Form B. The Enzyme.jl pipeline is the closest comparable implementation.

---

## Citations Index (verified URLs)

Verified-by-WebFetch/WebSearch:

- https://docs.julialang.org/en/v1/devdocs/callconv/ (Julia calling conventions)
- https://github.com/JuliaLang/julia/blob/master/doc/src/devdocs/callconv.md (mirror; same content)
- https://github.com/JuliaLang/julia/issues/8921 (NTuple/llvmcall issue — body only, no maintainer comments visible)
- https://github.com/JuliaLang/julia/issues/11899 (SLP vectorization for tuples)
- https://github.com/JuliaLang/julia/issues/52819 (SROA assertion)
- https://github.com/JuliaLang/julia/issues/38751 (memcpy on Windows — partial WebFetch)
- https://github.com/JuliaLang/julia/issues/2496 (tuple representation — historical)
- https://yorickpeterse.com/articles/the-mess-that-is-handling-structure-arguments-and-returns-in-llvm/ (ABI handling survey)
- https://llvm.org/docs/LangRef.html (LangRef — sections accessed via raw .rst download)
- https://llvm.org/docs/Passes.html (Passes overview)
- https://llvm.org/doxygen/Scalarizer_8cpp_source.html (Scalarizer source doxygen)
- https://llvm.org/doxygen/SROA_8cpp_source.html (SROA source doxygen)
- https://llvm.org/doxygen/MemCpyOptimizer_8cpp.html (MemCpyOpt doxygen)
- https://github.com/llvm/llvm-project/issues/2590 (sret+memcpy elimination)
- https://github.com/llvm/llvm-project/issues/95152 (memcpyopt+writeonly)
- https://github.com/llvm/llvm-project/pull/110645 (Scalarizer cl::opt → pass param)
- https://reviews.llvm.org/D79744 (referenced by GPUCompiler for byval lowering)
- https://enzyme.mit.edu/julia/ (Enzyme.jl home)
- https://github.com/EnzymeAD/Enzyme.jl (Enzyme.jl repo)
- https://github.com/EnzymeAD/Enzyme (Enzyme C++ repo; not inspected for this doc)
- https://github.com/JuliaGPU/GPUCompiler.jl (GPUCompiler.jl repo)
- https://github.com/JuliaGPU/GPUCompiler.jl/issues/23 (configurable passes)
- https://github.com/msr-quarc/ReVerC (ReVerC reversible compiler)
- https://arxiv.org/abs/1603.01635 (ReVerC paper)

Verified-by-local-clone (`master`/`main` as of 2026-04-21):

- /tmp/julia-src/src/codegen.cpp (lines 1674-1697 for deserves_*, 8258-8303 for sret emission)
- /tmp/julia-src/src/cgutils.cpp (lines 925-1070 for `_julia_struct_to_llvm`)
- /tmp/julia-src/src/abi_x86_64.cpp (lines 118-184 for SYSV classifier, `use_sret`)
- /tmp/julia-src/src/abi_aarch64.cpp (`use_sret`, `isHFAorHVA`, `classify_arg`)
- /tmp/julia-src/src/abi_win64.cpp (`use_sret`, `win64_reg_size`)
- /tmp/julia-src/src/ccall.cpp (lines 385-402 for `is_native_simd_type`)
- /tmp/julia-src/src/datatype.c (lines 316-345 for `jl_special_vector_alignment`)
- /tmp/julia-src/src/pipeline.cpp (lines 362-553 for pass insertion points)
- /tmp/enzymejl/src/compiler/optimize.jl (lines 1-430 for pipeline; `post_optimize!` at 395-463)
- /tmp/enzymejl/src/llvm/transforms.jl (lines 256-298 `fixup_1p12_sret!`, 589-649 `memcpy_sret_split!`)
- /tmp/enzymejl/src/compiler.jl (lines 4152-4219 `copy_struct_into!`, 4222+ `lower_convention`)
- /tmp/gpucompiler/src/interface.jl (lines 80-120 entry_abi docstring)
- /tmp/gpucompiler/src/irgen.jl (line 378 `deserves_sret`, lines 388-499 `lower_byval`)
- /tmp/llvm-main/.../Scalarizer.cpp (lines 1-100 header, 1217-1268 visitLoadInst/visitStoreInst) — via raw.githubusercontent.com fetch
- /tmp/langref.rst (lines 1298-1488 for parameter attributes) — via raw.githubusercontent.com fetch

**End of research document.**
