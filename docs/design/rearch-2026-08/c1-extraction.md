# C1 — IR Extraction Layer: Adversarial Architecture Review

**Scope:** `src/ir_types.jl`, `src/ir_extract.jl`, all of `src/extract/` (21 files, not 18 — the file map in `CLAUDE.md` is stale), `src/callees.jl`, `src/narrow.jl`. `src/ir_parser.jl` **does not exist** — it was deleted 2026-04-25 (Bennett-cs2f / U42); `CLAUDE.md` still lists it, and also omits `src/extract/sig_llvm.jl` (181 LOC, Bennett-40ys).

**Measured size:** 19,020 lines across the assigned files. 6,817 of those are comment lines (36%), 1,030 blank, ~11,173 lines of actual code. The whole `src/` tree is 39,098 lines, so **the IR extraction front-end is ~49% of the entire compiler by line count.** `src/extract/instructions.jl` alone is 8,143 lines — larger than the entire lowering directory.

---

## 1. What this area actually does

The aspirational description ("walks LLVM IR as typed objects via LLVM.jl's C API and lowers each instruction to a small typed IR") is accurate for maybe 2,000 of the 19,000 lines. What the layer *actually* is, is four superimposed products sharing one file tree:

**(a) A genuine, small, clean LLVM→ParsedIR walker.** `_convert_instruction`'s core arms — binop, icmp, select, phi, cast, br, ret, switch, extract/insertvalue, freeze, bitcast, fneg (`instructions.jl:6196–6295`, `6582–6718`, `7607–7762`) — are about 250 lines and are exactly what you'd write today. `ir_types.jl` is a reasonable typed IR: 20 `IRInst` subtypes with validating inner constructors (Bennett-k7al) and an `IROperand` abstract hierarchy (Bennett-v958) that replaced a `kind::Symbol` tagged union. `helpers.jl`, `errors.jl` are clean.

**(b) A soft-float / intrinsic desugaring layer.** `_handle_intrinsic` (`instructions.jl:4768–5834`, ~1,070 lines) expands `llvm.ctpop/ctlz/cttz/bitreverse/bswap/fshl/fshr/abs/umax/…` into loops of `IRBinOp`/`IRSelect` emitted at extraction time, and routes every `fcmp`/`fptosi`/`sitofp`/transcendental to a registered `soft_*` callee. Note the altitude violation: `llvm.ctpop.i64` becomes **~257 IRInsts emitted in the extractor** (`instructions.jl:4828–4848`) — an optimisation/lowering decision made in the parser, invisible to `lower.jl`, and untunable by strategy.

**(c) A "reverse-engineer the Julia runtime out of LLVM IR" subsystem.** `heap.jl` (2,863), `dict_vm.jl` (490), the five `vector_vm*.jl` files (1,001), plus the GC-preamble/type-tag/singleton-global/write-barrier/gc_preserve arms inside `instructions.jl`. These exist purely to recognise and delete Julia's GC frame, `Memory{T}` header layout, `julia.gc_loaded` launder, type-tag globals, and throw diamonds.

**(d) A closed-world program-analysis engine for a *different repo* (BennettVM).** Everything under the `ptr_cells` flag: `_p06b_*` (aggregate-store certification, ~440 lines), `_57hd_*` (a hand-rolled straight-line value-numbering + alias analysis reading LLVM's `memory`/`noalias`/`nocapture` attribute bits, ~570 lines), `_foz5_*` (confined-value contract, ~300), `_jbko_*`, `_583s_*`, `_bvmd_*`/`_root_scale` (~420), plus `callgraph.jl` + `julia_set.jl` + `sig_llvm.jl` (849 lines of Julia-inference introspection).

**The decisive structural fact:** products (c) and (d) are **not reachable from `reversible_compile` at all.** `validate_persistent_config` (`Bennett.jl:232`) accepts only `mem ∈ (:auto, :persistent, :heap)` — `mem=:vm` is rejected. No call site in `src/` outside `extract/` ever passes `ptr_cells=true` (verified by grep). They are reachable only by an external consumer calling `extract_parsed_ir(f, T; mem=:vm, ptr_cells=true)` directly. Conservatively 8,000–9,000 of the 19,000 lines — **45–50% of the extraction layer, ~22% of the whole compiler — is a front-end for BennettVM, not for the reversible-circuit compiler this repo claims to be.** That is the single most important architectural finding, and it is invisible in the file map.

---

## 2. Antipatterns, tech debt, accidental complexity

### 2.1 Genuine antipatterns

**A1. Exception-message string sniffing as control flow.**
`module_walk.jl:588–623`. Every instruction conversion is wrapped in a `try/catch` that decides whether to swallow the error by *substring-matching the formatted message*:
```julia
bennett_authored = startswith(msg, "ErrorException(") ? false :
                   occursin("ir_extract.jl:", msg) || occursin("Bennett-", msg)
benign = !bennett_authored && (
    (e isa ErrorException && (occursin("Unknown value kind", msg) ||
                              occursin("LLVMGlobalAlias", msg))) ||
    (e isa MethodError && occursin("PointerType", msg)))
```
This is load-bearing for the T5 corpus. It is also a time bomb: any LLVM.jl message reword silently flips behaviour between "skip instruction, leave dest unbound" and "crash". The same pattern recurs at `module_walk.jl:980–991` and `helpers.jl:49–52`. Note the self-referential fragility — the guard distinguishes Bennett's own errors from LLVM.jl's by looking for the literal string `"Bennett-"` in the message, which means **bead IDs in error strings are now part of the control flow**.

**A2. Regex/IR-text parsing, despite Rule 5 forbidding it.**
- `helpers.jl:56–111`: `_get_deref_bytes` falls back to hand-splitting the textual `define` line with paren-depth tracking and `%"quoted name"` needle matching, when `LLVM.parameter_attributes` MethodErrors.
- `heap.jl:205`: inline-asm asm/constraint strings recovered by regex over `string(LLVM.Value(callee))`.
- `heap.jl:53`, `dict_vm.jl:89–91`, `vector_vm.jl:82`: recognisers keyed on **mangled Julia symbol names** — `r"^j_setindex!_\d+$"`, `r"^j_#_growend!##\d+_\d+$"`, `r"^j_throw_inexacterror_\d+$"`.
- `callees.jl:82` and `:151`: two *different* demangling regexes for `julia_<name>_<NNN>`, one case-lowering and one case-preserving.

**A3. A known, documented, unfixed correctness bug shipped deliberately.**
`callees.jl:74–89`: `_lookup_callee` lowercases the *captured* function name, so `julia_Adder_770` resolves to `:adder` and any capitalised callee silently fails to resolve. This is acknowledged in the file (`callees.jl:113–120`, "that is a real latent bug, tracked separately as Bennett-wh1p, and is NOT touched here") and left in place **because fixing it might change gate-count regression baselines**. Rule 6 has here inverted from a safety net into a correctness ratchet.

**A4. Silent data loss in `narrow.jl`.**
`narrow.jl:24`:
```julia
return ParsedIR(W, new_args, new_blocks, [W for _ in parsed.ret_elem_widths])
```
This uses the 4-arg back-compat constructor (`ir_types.jl:594`), which **defaults `globals` to an empty `Dict`, `memssa` to `nothing`, and `synth_ptr_provenance` to an empty `Set`.** So `reversible_compile(f, Int8; bit_width=W)` on any function with a compile-time constant table silently discards the table — the exact class of silent failure Rule 1 exists to prevent, in a file whose *own* fallback method (`narrow.jl:83–88`) fails loud for exactly this reason. The file is 88 lines and has a beautifully-argued fail-loud fallback while the entry point drops three fields on the floor.

**A5. Copy-paste of the entry-point pipeline, four times.**
`entry.jl` has four near-identical implementations of "build `effective_passes`, run MemorySSA if asked, `LLVM.Context() do … parse … _run_passes! … dispose`, re-stamp memssa": lines 79–120, 236–265, 301–325, 350–370. Three separate copies of the sret auto-SROA prepend (`:104`, `:178`, `:313`). The docstrings for `ptr_cells` are also copy-pasted at ~30 lines each into `:41`, `:204`, `:288`.

**A6. Self-admitted duplicated tables.**
`julia_set.jl:45` defines `_D1B_BENIGN_INTRINSIC_PREFIXES`, a "DELIBERATELY a small LOCAL copy" of the `benign_prefixes` tuple at `instructions.jl:6969`, with a comment saying "keep them in sync by hand". They have already diverged (`julia.get_pgcstack` is in one, not the other).

**A7. Kwarg-threading as a substitute for a context object.**
`_convert_instruction` (`instructions.jl:6131–6177`) takes 3 positional and **10 keyword arguments**, seven of which are mutable side tables threaded from `module_walk.jl` (`synth_ptr_allocas`, `suppressed_refs`, `tag_ids`, `tag_ssa`, `dead_blocks`, `lanes`, `counter`). `_handle_intrinsic` re-threads a subset, `_handle_memcpy_arm` re-threads a sub-subset with a 12-line comment (`instructions.jl:3126–3137`) explaining why one of them must not default to empty. There is an extraction context object here that was never written.

**A8. Boolean-flag bimodality instead of separate pipelines.**
`ptr_cells` appears 225 times in `instructions.jl`, 39 in `sret.jl`, 27 in `module_walk.jl`. Its meaning is "we are compiling for BennettVM's cell-addressed VM, not for a reversible circuit" — i.e. a *different target with a different value model*. It is implemented as a boolean threaded through every function and gating ~20 top-level conditionals plus dozens of nested ones. The comment idiom "the gate defaults false, so the circuit path is byte-identical" appears **35 times in `instructions.jl` alone** — an admission that the whole design rests on one flag's default value.

**A9. `ParsedIR` constructor archaeology.**
`ir_types.jl:566–616`: one 7-field struct with three back-compat constructors, each layering defaults. `IRInsertValue`/`IRExtractValue` each have a "convenience ctor reproducing the EXACT pre-6bu3 signature" (`:167`, `:387`). `IRRet` has a void form reachable only via a zero-arg constructor because the value-bearing one asserts `width >= 1` and a test pins that assertion's message (`ir_types.jl:105–131`). `IRCall` has two nearly-identical inner constructors differing only in callee type (`:416`, `:442`). Every one of these exists to avoid touching a pinned test string.

**A10. Semantic overloading of a single struct field.**
`IRPtrOffset.offset_bytes` (`ir_types.jl:221–238`) means **three different things** depending on producer: (i) a byte offset (the contract), (ii) a raw GEP index when the source element type is non-integer (`instructions.jl:7080`), (iii) a raw element *index* in the `mem=:heap` re-rooter. The comment says "a follow-up bead tracks reconciling the heap sites to true bytes". A field with three meanings and a note saying so is not documentation, it is a deferred miscompile.

**A11. Non-fail-loud escape hatches inside a fail-loud codebase.**
`module_walk.jl:1251–1257`: in `_expand_switches` phi patching, a phi citing a switch block that doesn't branch to it "leave[s] the incoming alone rather than silently dropping it; a downstream phi resolver will raise if this is malformed" — i.e. deliberately defers a detected inconsistency to a hoped-for downstream check. `instructions.jl:7604` (`return nothing  # non-integer load — skip`) leaves the load's dest unbound; the code path that consumes it errors later at `_operand` with "the producing instruction was skipped".

**A12. Comment mass as an antipattern in its own right.** 36% of the layer is comments, and many are essays: the `_57hd` header (`instructions.jl:1844–2008`) is **165 lines of prose** containing a theorem, a proof, a 4-row comparison table of invariance requirements, a 2×2 failure matrix, five numbered "declared premises", and a "NON-GOAL, MEASURED AND REJECTED — READ BEFORE 'IMPROVING' THIS" section. The `ptrtoint` arm in `_convert_instruction` (`instructions.jl:6297–6580`) is ~280 lines of which ~200 are comment and ~60 are error-message string literals. Individual `_ir_error` messages run 15–25 lines (e.g. `instructions.jl:6410–6438`, a single error string spanning 29 lines). This is not over-documentation; it is design-by-comment substituting for design-by-structure. When the invariants are too subtle to express in code, they get expressed in prose next to the code and drift.

### 2.2 Complexity that is *justified* by the domain

To be fair, a substantial fraction of the apparent mess is real:

- **The fail-loud discipline is correct and should be kept.** 182 `_ir_error` sites in `instructions.jl`, each naming opcode/function/block/instruction (`errors.jl:80–112`), is exactly right for a compiler whose failure mode is a silent miscompile that still passes `verify_reversibility`. The messages are too long, but their *existence at every unhandled shape* is the layer's best property.
- **Constructor validation** (`ir_types.jl`, Bennett-k7al) genuinely catches `:zxt` vs `:zext` typos at construction rather than 500 lines later. Keep verbatim.
- **`_const_int_as_int`** (`helpers.jl:123–132`) refusing >64-bit constants rather than silently truncating via `LLVMConstIntGetSExtValue` is a real LLVM.jl footgun correctly handled.
- **Poison/undef/ConstantFP/ConstantPointerNull rejection** (`helpers.jl:134–210`) is right, and the position-dependent `undef → 0` relaxation *only* in phi-incoming (`instructions.jl:6254–6272`) is a genuinely careful piece of reasoning.
- **sret handling** is intrinsically ugly because the ABI is ugly. Julia routes >16-byte tuple returns through a caller-allocated buffer; recovering the by-value aggregate shape requires a pre-walk, store classification, and synthesis. `sret.jl`'s decomposition into per-pattern handlers (Bennett-s92x) is the right shape. 1,518 lines is maybe 2× what it should be, not 10×.
- **`_expand_switches`** (`module_walk.jl:1144–1280`) — the two-phase design (expand all, then global phi patch) with the `pred_map` keyed on `(switch, target)` is correct and non-obvious; the U11 bug it fixes is real.
- **Vector scalarisation** (`vectors.jl`) is a legitimate response to SLP-vectorised IR when the backend has no vector primitive.
- **`sig_llvm.jl`** is, in isolation, excellent work: it identifies that `InteractiveUtils._dump_function` consumes the callable in exactly one place and reproduces the sequence minus that step, with a capability gate (`_assert_sig_llvm_supported`) that fails loud per-call. If you must extract IR for an instance-less closure, this is how.

---

## 3. Version coupling: what breaks or simplifies on Julia 1.13

The layer is coupled to Julia/LLVM at five distinct altitudes, with very different risk profiles.

**Tier 0 — hard pins that will refuse to run.**
`heap.jl:139–144`: `_assert_memory_layout()` errors if `(VERSION.major, VERSION.minor) != (1, 12)`. It is called unconditionally by `_dict_vm_extract` (`dict_vm.jl:157`) and by the Case-A Vector recogniser. **On Julia 1.13, `mem=:heap` and `mem=:vm` stop working on day one, by design.** That is ~4,350 lines that go dark immediately. (Credit where due: this is the *correct* failure mode.)

**Tier 1 — Julia object-layout constants.** `_GC_LAYOUT_TLS_PGCSTACK_OFF = -8`, `_GC_LAYOUT_PTLS_FIELD_OFF = 16`, `_GC_LAYOUT_TAG_OFF = -1` (`heap.jl:60–62`), plus the "Memory header is `{i64, ptr}` and the data pointer is at byte 8" assumption baked into `_is_genericmemory_header_struct` / CW-D4 byte-granular stamping (`instructions.jl:1477`, `:7222–7262`). Any GC or `GenericMemory` layout change in 1.13 invalidates these.

**Tier 2 — Julia inference/codegen internals.**
- `callgraph.jl:34–39`: `mi_of` handles `Core.CodeInstance` (≥1.11) vs `Core.MethodInstance` (≤1.10) and fails loud otherwise; `Base.code_typed_by_type`, the `:invoke` Expr shape, `mi.specTypes`.
- `sig_llvm.jl:70–103`: `Base._which`, `Base.specialize_method`, `Base.CodegenParams`, `Base.Compiler.typeinf_code`, `Base.Compiler.NativeInterpreter` (explicitly noted as having moved from `Core.Compiler` in 1.12), `InteractiveUtils._dump_function_llvm`.
- `julia_set.jl:197`: `_method_instance_of_sig(...).def.name` and the closure-type naming rules.
These have capability gates and will fail loud, but each is a re-derivation task on 1.13.

**Tier 3 — Julia symbol-mangling and emission conventions.** `_find_entry_function`'s "first function whose name starts with `julia_`" heuristic (`module_walk.jl:11`); the `julia_<n>_<NNN>` / `j_<n>_<NNN>` demangling regexes (`callees.jl:82`, `:151`, `julia_set.jl:236`); `@"+Main.Base.Dict#148"` type-tag global naming (`instructions.jl:7393`); `@"jl_global#N"` singleton naming (`:7418`); `@"jlplt_<callee>_<N>_got"` GOT-stub demangling (`:7463`); `swiftself` detected by `occursin("swiftself", string(p))` (`module_walk.jl:295`) — a *substring search on the stringified parameter*.

**Tier 4 — LLVM internals.** `_57HD_ME_KNOWN_MASK = 0b111111` decodes the **raw packed integer of LLVM's `memory` attribute** (`instructions.jl:2013–2017`), explicitly acknowledged as "LLVM-internal and NOT a stable API". `_57hd_attr_kind` deliberately avoids `const`-ing attribute-kind ids so precompile doesn't bake one LLVM build's numbering into the `.ji` (`:2019–2023`) — a real and subtle correctness note. LLVM.jl is pinned to `9, 10`; `LLVM.jl 9 has no ConstantPointerNull wrapper` forces raw value-kind enum dispatch (`module_walk.jl:884`).

**What 1.13 would *simplify*:** essentially nothing in the current design — the coupling is all in the "delete the Julia runtime skeleton" direction, and 1.13's changes will make that work harder, not easier. The one thing that could genuinely simplify is if the reimplementation stops walking post-codegen LLVM IR (see §5a).

---

## 4. From-scratch verdict

Assuming code generation is free, the reimplementation should be organised around a single question the current design never asked: **what is the narrowest input language that suffices?**

### KEEP (port near-verbatim)

1. **`ir_types.jl`'s core, with the constructor validation.** The 15 circuit-relevant `IRInst` subtypes, the `IROperand` abstract hierarchy with interned sentinels, and every validating inner constructor. Drop the back-compat convenience constructors, `IRMap*`, the `width==0` pointer sentinels, and the three-meaning `offset_bytes`.
2. **The fail-loud contract and `_ir_error`'s message *format*** (`errors.jl:80–112`): `opcode in @fn:%block: <instruction> — reason`. Keep the format; cut message bodies to ≤3 lines with a doc link.
3. **`_const_int_as_int`, poison/undef/ConstantFP rejection, `_type_width`'s precise per-type errors.** These are hard-won and pinned by `test_qmk6_dq8l_type_width_errors.jl`, `test_k7al_ir_constructor_asserts.jl`, `test_bjdg_*` — port those tests verbatim.
4. **`_expand_switches` (both phases) and its U11 regression test.**
5. **The intrinsic *semantics* table** (ctpop/ctlz/cttz/bswap/bitreverse/fshl/fshr/abs/minmax/copysign/fabs/roundeven-vs-round) — but as declarative data, not as emit-code (see REDESIGN).
6. **The soft-float callee registry's *content*** (`src/callees.jl`) — the domain grouping (Bennett-kmuj) is good; the whole file is 147 lines of declaration and should be kept as-is.
7. **The Bennett-mq6f `llvm.round` vs `llvm.roundeven` distinction** and every other "these two intrinsics are not the same function" note. Those are real bugs found by real testing.
8. **`sig_llvm.jl`'s capability-gate pattern** — probe for the internals you need, fail loud naming `VERSION`, at every call not at load.

### DISCARD

1. **The entire `ptr_cells` subsystem** (`_p06b_*`, `_57hd_*`, `_foz5_*`, `_jbko_*`, `_583s_*`, `_bvmd_*`, cell-model store/load/GEP/call arms, type-tag interning, singleton globals, GOT-stub classification). ~4,000+ lines serving an external VM through a boolean flag on a shared walker. If BennettVM needs a front-end, it needs its **own** front-end — the "byte-identical when the gate is off" argument repeated 35 times is proof the two products don't belong in one function.
2. **`heap.jl`, `dict_vm.jl`, all five `vector_vm*.jl`.** ~4,350 lines of Julia-1.12-pinned skeleton archaeology, already scheduled to die on 1.13 by their own version assert. Nothing in them is a reusable algorithm; they are a snapshot of one compiler's codegen.
3. **The exception-message-sniffing benign-skip** (`module_walk.jl:588–623`). Replace with explicit pre-classification of value kinds via the raw C API before any `LLVM.Value()` identification.
4. **`_get_deref_bytes`'s IR-text fallback** (`helpers.jl:56–111`). If the typed attribute API doesn't work, fix or vendor the accessor; do not parse the `define` line.
5. **`narrow.jl` in its current form** — see §5d.
6. **Every "back-compat constructor" and "byte-identical" preservation shim.** With free code generation, there is no reason to carry API archaeology; regenerate the call sites.
7. **The 165-line theorem comments.** Move to `docs/adr/`, leave a one-line pointer.

### REDESIGN

**R1. Split the front-end by target, not by flag.** Two separate walkers over a shared *typed-IR definition* and a shared *instruction-classification table*. The circuit walker never sees `ptr_cells`; the VM walker (if it survives) lives in BennettVM's repo and depends on `Bennett.IRTypes` as a package.

**R2. Make instruction handling table-driven.** Today `_convert_instruction` is a 2,000-line `if opc == …` chain and `_handle_intrinsic` a 1,070-line `if startswith(cname, …)` chain. Both should be dispatch tables keyed on `LLVM.API.LLVM*` opcode / intrinsic-name-prefix, with each handler a small function taking one `ExtractionCtx`. Intrinsic *expansions* (ctpop etc.) should be declared as small builder functions in a registry, and — importantly — should **not run in the extractor**: emit `IRIntrinsic(:ctpop, op, width)` and let `lower.jl` choose the expansion. That moves ~800 lines out of extraction and makes intrinsic lowering strategy-tunable (a QROM-based popcount is a legitimate alternative to 257 IRInsts).

**R3. One `ExtractionCtx` struct** replacing the 13-argument threading. Fields: `names`, `counter`, `lanes`, `globals`, `func`, `mod`, `datalayout`, plus a per-target policy object. Handlers take `(ctx, inst)`.

**R4. One entry point.** `extract(source; passes, memssa) -> ParsedIR`, where `source` is a small sum type (`JuliaFn(f, argtypes)`, `JuliaSig(spectypes)`, `LLFile(path, entry)`, `BCFile(path, entry)`, `IRText(str)`). The four copy-pasted pipelines in `entry.jl` collapse to one.

**R5. Explicit `Width` typing in the IR.** The single most common bug class visible in the git history (`Bennett-vz5n`/U12 byte-vs-index, `Bennett-plb7`/U13 elem_width default, `Bennett-xv0u` element-index recovery, `bvmd` byte-vs-word tier, CW-D4 split) is **unit confusion between bits, bytes, elements, and cells**. Introduce `Bits`, `Bytes`, `ElemIndex` newtypes and let the type system enforce it. This alone would have prevented four of the beads cited in the current code.

**R6. Make the "recogniser" question explicit and small.** If you must recognise runtime idioms at all, the recogniser should be (a) a separate pass over `ParsedIR`, not interleaved into the walker, (b) expressed as declarative pattern rules with a version stamp, and (c) able to say "I recognise nothing" without the walker being any different.

**R7. Property-test the extractor.** There is currently one 67-line `test_ir_extract.jl` and 324 test files mostly pinning *error message substrings*. Replace with: for a generated corpus of small integer/float Julia functions, assert `simulate(compile(f)) == f(x)` for all inputs. Error-string pinning has become a change-suppression mechanism (see A3).

---

## 5. Answers to the specific questions

### (a) Is `optimize=false` LLVM IR the right substrate, or the wrong altitude?

**It is the wrong altitude for the Julia front-end, and the right altitude for the C/Rust front-end.** That mismatch is the layer's original sin.

Quantitatively: of the ~19,000 lines, I estimate **8,000–9,000 exist solely to reverse-engineer Julia runtime idioms back out of LLVM IR** — the GC frame, `pgcstack`/TLS reads, `julia.gc_alloc_obj`, `julia.gc_loaded`, `GenericMemory` headers, MemoryRef pairs, type-tag globals, JIT-global aliases, `swiftself` synthetic parameters, boxed-throw skeletons, `sret` ABI recovery, mangled-name demangling, and inline-asm allowlisting. All of that information *existed* one layer up and was destroyed by codegen. `callgraph.jl:14–17` says this out loud about the call graph — "Walking it at the LLVM layer would mean re-deriving information inference already has" — and then the rest of the directory does exactly that for everything else.

There is a further, subtler cost. Extracting from `code_llvm` output means the *entire Julia ABI* is in scope: every function you compile drags in whatever codegen decided to emit, including code paths (throw diamonds, bounds checks, GC bookkeeping) that are semantically irrelevant to the pure integer function you actually wanted. The layer then spends thousands of lines *proving those irrelevant paths dead* — `_assert_dead_block_is_throw_skeleton`, `_all_uses_in_dead_blocks`, the five-part liveness proof in `heap.jl`. On typed Julia IR (post-inference, pre-codegen), that work mostly evaporates.

**Recommendation for a 2026 rebuild:** make the *primary* Julia substrate `Base.code_typed`/`CodeInfo` after inference and optimisation — SSA `IRCode` with `PhiNode`, `GotoIfNot`, typed `Expr(:call, Base.add_int, …)` on concrete `Int8..Int64`/`Float64`. You get: concrete types (no width guessing), a real CFG, no GC skeleton, no mangling, no sret, no ABI, no `dereferenceable` parsing, no `swiftself`. Julia's own `Compiler` API is *more* stable across versions than the IR-text-shaped assumptions currently in use, and 1.13's `Base.Compiler` is now a first-class stdlib. Keep the LLVM path as a **secondary** front-end for `.ll`/`.bc` (C/Rust corpus) targeting the *same* `ParsedIR` — there, LLVM genuinely is the right altitude, and the C surface has none of the Julia-runtime noise. Cost: reimplementing the Enzyme-style typed-IR walk (real work, but ~1,500 lines, not 9,000) and losing the "one walker for all languages" story — which the code doesn't actually deliver anyway, given `ptr_cells` and `mem` fork the walker three ways.

### (b) The recogniser zoo: fragile pattern-matching or defensible?

**Fragile, and honest about it.** They are defensible *as engineering under the constraint of (a)* — they are partition recognisers that fail loud rather than miscompile, they refuse to guess (`dict_vm.jl:36–58` explicitly refuses to model an inlined `getindex` because proving it sound is undecidable), and `heap.jl`'s "purely subtractive and monotone: it only ever rejects" framing is the right safety posture. Given the substrate they were handed, this is close to the best you can do.

But look at what they key on: exact mangled callee names (`"jl_alloc_genericmemory_unchecked"`, `"julia.gc_loaded"`, `r"^j_setindex!_\d+$"`), literal byte offsets in the GC frame (`-8`, `16`, `-1`), the assumption that the Memory length field is a two-zero-index struct GEP (`vector_vm.jl:222–238`), the assumption that the size is `extractvalue(llvm.smul.with.overflow(n, STRIDE), 0)` (`vector_vm.jl:143–167`), and — for `mem=:heap`/`:vm` — an unconditional `VERSION == 1.12` assert.

**Fraction surviving an LLVM version bump:** distinguish two axes.
- *LLVM-only bump* (LLVM 18→19/20, same Julia): I'd expect **70–85%** to survive, because most of the pattern surface is Julia-codegen-shaped, not LLVM-shaped. The exposed parts are `_57hd`'s raw `memory`-attribute bit decode (fails closed — good), `nocapture`→`captures(none)` respelling (anticipated at `instructions.jl:2001`), `LLVMGetElementAsConstant`/`ConstantDataArray` vs `ConstantAggregateZero` classification (`module_walk.jl:1060–1063` already notes an LLVM-18 behaviour), and the constant-expression folding in `constexpr.jl`.
- *Julia bump* (1.12→1.13): **near 0% for `heap.jl`/`dict_vm.jl`/`vector_vm*.jl`** — they self-disable. Maybe 60% of the `ptr_cells` recognisers survive since the C track dominates them.

Net: the zoo is not defensible as a *long-term* artefact. It is 4,350 lines with a scheduled expiry date already written into it. In a rebuild, if the Julia front-end moves to typed IR, **the zoo has no reason to exist** — `Vector{T}(undef,n)`, `Dict`, and `push!` are visible as themselves at that altitude, and the recognition problem becomes "match a call to `Base.setindex!`", not "match a mangled symbol and prove twenty instructions dead".

### (c) The known-callee registry: sound design or hand-maintained shadow?

**Both, and the split is instructive.**

`src/callees.jl` (147 lines, declarative, grouped by domain) is *sound and should be kept verbatim*. It is a deliberate, curated list of soft-float and reversible-memory primitives that the compiler knows how to gate-inline. It is exactly the right thing.

`src/extract/callees.jl` (169 lines) is where it goes wrong:
- **Resolution is by name-substring, not identity.** `_lookup_callee` demangles `julia_<n>_<NNN>` and looks up a `Dict{String,Function}` keyed on `string(nameof(f))`. Two different `soft_foo` methods, or a user function colliding with a registered name, resolve to whatever is in the dict. There is no arity or signature check.
- **It carries a known bug it refuses to fix** (A3 above).
- **It has a second, divergent registry** — `_known_callee_names::Dict{String,Symbol}` (`:121`) — added because closures/functors have no `Function` value, with a *deliberately different* case-sensitivity rule from its sibling. Two lookup functions, two regexes, one lock.
- **It is process-global mutable state**, which `julia_set.jl:427–530` then has to snapshot and scope-restore in a `finally` block with per-key restore semantics, because a leaked registration changes how *later, unrelated* compiles behave (`julia_set.jl:414–420` names the exact test-ordering hazard).

So: the *registry concept* is sound; the *implementation* is a hand-maintained shadow of the call graph, keyed on unstable strings, with global mutable state that requires a save/restore dance. **Redesign:** key on `MethodInstance`/`(Function, Tuple)` identity, resolve callees by walking the module's `LLVM.Function` → Julia `MethodInstance` mapping that codegen already knows (or, on the typed-IR path, read the `:invoke` target directly — no registry at all for in-module calls). Keep an explicit *primitive* registry only for the soft-float intercepts, and make it immutable and pass it in the context object rather than holding it in a module-global under a `ReentrantLock`.

### (d) `narrow.jl` width-narrowing: what does native Int2/Int4 obsolete?

`narrow.jl` is 88 lines implementing "compile a function written for `Int8` as if it operated on W-bit integers, all arithmetic wrapping mod 2^W". It is a *hack around the absence of narrow integer types in Julia's surface language*, and it is a bad one:

- It rewrites widths **after** extraction, so LLVM has already constant-folded, range-analysed, and emitted code under the *wrong* modulus. `f(x::Int8) = x + Int8(200)` narrowed to W=4 is not the same program as a genuine 4-bit `x + 4`; the IR was produced by an optimiser that believed the operands were 8 bits.
- `_narrow_inst(IRCast)` (`narrow.jl:34`) narrows `from_width` and `to_width` *both* to W, turning every genuine widening/narrowing cast into an identity. For an `Int8` source that's coherent-by-luck; for anything with mixed widths it is a silent semantic change.
- It uses `width > 1 ? W : 1` as the i1 discriminator — a heuristic, not a type. A genuine `Int1` value and a boolean are indistinguishable.
- It silently drops `globals`/`memssa`/`synth_ptr_provenance` (A4).
- It has no method for `IRVarGEP`, `IRLoad`, `IRSwitch` and fails loud for them (`narrow.jl:83–88`) — i.e. `bit_width` is incompatible with memory and switches.

**What native `Int2`/`Int4` (or, more precisely, arbitrary-width integer types) would obsolete:** essentially all of it. If Julia 1.13 shipped `Core.IntN{W}` / native `Int4` such that `f(x::Int4) = x + Int4(1)` type-infers and codegens to `i4` arithmetic, then narrowing becomes *just extraction* — `_iwidth` reads 4 from the LLVM type, `IRBinOp.width == 4`, and the whole file deletes. LLVM has supported arbitrary integer widths (`i2`, `i4`, `i37`) since forever; the gap is purely on Julia's surface-language side.

Caveats worth stating plainly, because they determine how much you can bank on this:
1. I am not aware of `Int4`/`Int2` being a *committed* Julia 1.13 feature — treat it as speculative. The maintainer should verify before designing around it.
2. Even with native narrow ints, LLVM will legalise `i4` operations into `i8` with masking on most backends. That is irrelevant *here* — we extract IR before target legalisation, and `optimize=false`/`preprocess` control which passes run — but it means the IR you read must be pre-legalisation, which reinforces the argument for extracting at a higher altitude still (§5a).
3. Bennett already has a second, better answer for narrow widths: `tabulate.jl` (classical evaluation of `f` over all 2^W inputs → QROM). For W ≤ 8 that is exact, strategy-tunable, and needs no IR narrowing at all. `Bennett.jl:344–374` already auto-picks it in some cases. In a rebuild, `bit_width` should either (a) become a real type-level width fed to inference, or (b) be restricted to the tabulation path and removed from the IR pipeline entirely. Keeping a post-hoc IR rewrite that mutates widths under an optimiser that assumed different ones is the one option that should not survive.

---

## 6. Summary judgement

The extraction layer is not badly *written* — the fail-loud discipline, the constructor validation, the error-message format, and several individual analyses (`sig_llvm.jl`, `_expand_switches`, the poison/undef handling) are better than average. What has gone wrong is **scope**: a component whose job is "LLVM IR → 15 typed instruction nodes" has absorbed a Julia-runtime archaeology suite, a straight-line alias analysis, a closed-world call-graph producer, an intrinsic expander, and a second compiler's front-end — all fused into one walker by boolean flags, and all held together by 6,800 lines of comments and a test suite that pins error strings.

A from-scratch 2026 version, extracting the Julia front-end from typed `IRCode` and keeping an LLVM `.ll`/`.bc` front-end for the C/Rust corpus, sharing one `ir_types.jl` and one table-driven handler registry, should land at **2,500–4,000 lines** for the same circuit-path capability — and would not carry a Julia-version assert that turns 4,350 lines off on the next minor release.
