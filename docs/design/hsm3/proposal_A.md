# Bennett-hsm3 — PROPOSER A (verbatim hand-back, 2026-09-24)

# Proposer A design: semantic certification of `jl_global#N` heap literals (Bennett-hsm3 and gcf7 D1, D2, D3)

**Summary.** Seed and alias a `jl_global#N` global only when the live producing session has shown that its address is an empty GenericMemory singleton. The check is a lookup of the address in the set of live singletons; the address is never dereferenced. It runs inside a short window with GC disabled and no yield points, opened right after IR emission. Every other literal fails loud at its live load site. Text and bitcode ingest has no live session, so it certifies nothing. On D3 I recommend replacing the blob's null data pointer with a non-null trapping sentinel, with a named fallback if that re-walls the corpus. Beyond amending ADR 0021, BennettVM needs no src changes.

I modified no files in either repo. All probes ran as inline `julia --project -e` in this session; their outputs are quoted below.

---

## 1. Root cause, with evidence

**1a. What the IR looks like (measured, Julia 1.12, `optimize=false`, `dump_module=true`).** For `const RI = Ref(42); h3(x::Int) = RI[] + x`:
```
@"jl_global#146" = private unnamed_addr constant ptr @"jl_global#146.jit"
@"jl_global#146.jit" = private alias ptr, inttoptr (i64 140014760661792 to ptr)
  %"jl_global#146" = load ptr, ptr @"jl_global#146", align 8
  %.x = load i64, ptr %"jl_global#146", align 8
```
- The literal's address K is the `ConstantInt` operand of an `inttoptr` ConstantExpr. That ConstantExpr is the aliasee of the `.jit` GlobalAlias, and the alias is the initializer of the `jl_global#N` GlobalVariable.
- In the same process, `0x7f57ba129320 == K == pointer_from_objref(RI)`, and `unsafe_pointer_to_objref(K) === RI`. So K is the object's live address.
- The existing `_ptr_identity(LLVM.API.LLVMGetInitializer(g.ref))` (constexpr.jl:228) already walks GlobalVariable → alias → `inttoptr` and returns `(:addr, K)`. I used exactly that call successfully in the probes. No regex and no new C-API code are needed.
- In the hand-written fixture form (`constant ptr inttoptr (i64 K to ptr)`, no alias) the same call also returns `(:addr, K)`.
- For `external constant ptr`, `LLVMGetInitializer` is `C_NULL` and the call returns `nothing`.

**1b. Why it miscompiles.**
- `_extract_const_globals` (module_walk.jl:1018 and 1109) seeds `(zeros(UInt64,16), 8)` for any name matching `^jl_global#\d+$` (constexpr.jl:158).
- The `_handle_load` alias arm (instructions.jl:7420) and `_5viz_singleton_load` (instructions.jl:2915) trust the same regex.
- Julia uses the `jl_global#` prefix for every interned heap literal. From `src` literal types in a probe:

| function | global | object it actually is |
|---|---|---|
| h1 | `jl_global#75` | `Base.RefValue{S2}` |
| h3 | `jl_global#195` | `Base.RefValue{Int64}` |
| h4 | `jl_global#275` | `Base.RefValue{Tuple{Int64}}` |
| he (`const EM = Memory{Int}()`) | `jl_global#235` | `Memory{Int64}` (the real singleton) |

  So `RI[]` reads cell 0 of a zero blob and returns 0 instead of 42.
- The comment at module_walk.jl:1000-1004 says the guard is "structural". That is false: the opaque-alias shape is common to all literals.

**1c. Liveness facts that shape the mechanism** (from the Julia 1.12 `codegen.cpp` a previous agent left in the t9rh_A scratchpad).
- `jl_temporary_root` (codegen.cpp:3179) roots codegen literals only while emission runs.
- `code_llvm`'s `CodeInfo` is a fresh `typeinf_code` result that is dropped after printing.
- For `memorynew` with constant length 0, codegen emits `typ->instance` directly as a literal (codegen.cpp:4155). That singleton appears in no `src` statement.
- Conclusion: "rooted by the method's code" does not hold on the reflection path. A K printed by `code_llvm` may point at an object that is no longer alive once the call returns. Dereferencing K (`unsafe_pointer_to_objref`) is therefore unsound in general. The design never dereferences K.

**1d. Empty singleton layout (measured).**
- Every concrete GenericMemory type `T` has `T(undef, 0) === T.instance`, `length == 0` and `sizeof == 0`. The header is `{length@0, ptr@8}`.
- The data pointer is never null:
  - For sysimage-baked singletons it points outside the object. `Memory{Int8}` has `ptr - obj = 84 MB`; `Memory{Int64}` has 77 MB.
  - For freshly created types (Union, Any, String, AtomicMemory) `ptr == obj + 16`.
- So the blob is faithful for `length` but not for the data pointer (D3).

**1e. Corpus facts (measured).** I emitted every callee's IR via `transitive_callees` and `_code_llvm_by_sig` and classified each `jl_global#N` by the membership test in §2. Results:
- **push! Int64** (`v = Int64[]; push!(v, n); @inbounds v[1]`):
  - The root's `#447` is `Memory{Int64}` (block `top`).
  - `_growend!##0`'s `#1034` is `Memory{Int64}` (block `emptymem`).
  - `#1029` and `#1031` are not singletons. Their only uses are in `L96` and `L90`: throw blocks ending in `unreachable`, which utzc prunes.
- **push! Int8**: same pattern, with `Memory{Int8}`.
- **fdict**:
  - Root: `#1126` is `Memory{UInt8}` and `#1127` is `Memory{Int8}`, both in `top`. `#1132` is not a singleton and is used only in `L84` (throw, unreachable).
  - `rehash!`: `#1201` and `#1203` are singletons (the `emptymem*` blocks). `#1206` is used only in `L189` (throw, unreachable).
- Every jl_global that is live in the corpus is an empty singleton. The non-singletons, such as ConcurrencyViolationError and AssertionError message literals, live only in dead-pruned blocks, or are hoisted loads covered by the name-agnostic 3vf2 drop. The fix therefore does not re-wall the corpus.
- In the corpus, the data pointer is used only for `memoryref` construction, `memoffset` subtraction (`ref.ptr - mem.ptr`), and a length-0 `memset` (see `fdict_O0.ll:16-20` in the BVM repo). Length 0 makes element accesses dead.

---

## 2. Classification mechanism

**Rule: the address is used only as a lookup key into a set of known-live objects, never dereferenced.**

New file `src/extract/jl_literals.jl`, included by `ir_extract.jl` after `constexpr.jl`:

```julia
struct _EmptyMemoryFact; type::String; data_nonnull::Bool; end
struct _JlLiteralCert                       # produced ONLY in the live producing session
    empty_memory::Dict{UInt64,_EmptyMemoryFact}   # K => fact, K ∈ live empty-GenericMemory singletons
    literal_types::Dict{UInt64,String}            # best-effort diagnostics: K => typeof string of a src literal
end
mutable struct _JlLiteralSeeds                # per-module output of _extract_const_globals
    certified::Set{Symbol}                    # globals seeded as empty-singleton headers
    rejected::Dict{Symbol,String}             # (:addr,…)-initialised globals NOT certified => reason
end
const _EMPTY_MEMORY_DATA_SENTINEL = (UInt64(1) << 48) + (UInt64(1) << 47)  # §5 (D3)

# Deref-free enumeration of every live empty GenericMemory singleton. All of them
# are permanent: each is rooted by its DataType, allocated once, never freed.
function _live_empty_memory_singletons()::Dict{UInt64,_EmptyMemoryFact}
    _assert_jl_literal_cert_supported()   # hasfield(Core.TypeName, :cache/:linearcache) etc.; fail loud otherwise (Rule 5/9)
    tn = Base.unwrap_unionall(Core.GenericMemory).name
    out = Dict{UInt64,_EmptyMemoryFact}()
    for c in (tn.cache, tn.linearcache), i in 1:length(c)
        isassigned(c, i) || continue
        T = c[i]
        (T isa DataType && isconcretetype(T) && isdefined(T, :instance)) || continue
        x = T.instance
        (x isa Core.GenericMemory && length(x) == 0) || error("…invariant: $(T).instance is not an empty GenericMemory (Bennett-hsm3)")
        out[UInt64(UInt(pointer_from_objref(x)))] = _EmptyMemoryFact(string(T), getfield(x, :ptr) != C_NULL)
    end
    haskey(out, UInt64(UInt(pointer_from_objref(Memory{UInt8}())))) ||
        error("…singleton enumeration is broken on Julia $(VERSION) (Bennett-hsm3)")  # self-test
    return out
end

function _certify_jl_literals(ir::AbstractString, src::Union{Nothing,Core.CodeInfo})::_JlLiteralCert
    addrs = Set{UInt64}()
    LLVM.Context() do _
        mod = parse(LLVM.Module, ir)
        try
            for g in LLVM.globals(mod)
                LLVM.isconstant(g) || continue
                id = _ptr_identity(LLVM.API.LLVMGetInitializer(g.ref))   # alias -> inttoptr -> (:addr,K)
                (id !== nothing && id[1] === :addr) && push!(addrs, id[2])
            end
        finally
            dispose(mod)
        end
    end
    S = _live_empty_memory_singletons()
    return _JlLiteralCert(Dict(K => S[K] for K in addrs if haskey(S, K)),
                          src === nothing ? Dict{UInt64,String}() : _src_literal_types(src))
end
```

**`_src_literal_types(src)`** is diagnostics only. It walks `src.code` through `Expr`, `QuoteNode`, `ReturnNode.val`, `PiNode.val`, and const `GlobalRef` resolved via `getglobal`. For every non-isbits value it records `ccall(:jl_value_ptr, Ptr{Cvoid}, (Any,), v)` → `string(typeof(v))`.
- Use `jl_value_ptr` here, not `pointer_from_objref`: my first probe crashed because `pointer_from_objref` rejects immutables.
- Verified output: h1 → `Base.RefValue{S2}`, h3 → `RefValue{Int64}`, h4 → `RefValue{Tuple{Int64}}`, he → `Memory{Int64}`.

**GC-pinned window (belt and braces for "provably").**

```julia
function _gc_pinned(thunk)
    tid = Threads.threadid(); prev = GC.enable(false)
    try
        return thunk()
    finally
        migrated = Threads.threadid() != tid
        GC.enable(prev)
        migrated && error("Bennett-hsm3: GC-pinned certification window yielded and migrated threads — invariant broken (Rule 1)")
    end
end
```
- The window must be free of yield points. It contains exactly:
  - the two C calls inside `InteractiveUtils._dump_function_llvm` (`jl_get_llvmf_defn` and `jl_dump_function_ir`);
  - `parse(LLVM.Module, …)`;
  - the alias harvest;
  - the singleton enumeration.
- Inference (`typeinf_code`) runs before the window.
- With GC off, nothing is freed between codegen holding object O at address K and the lookup. O is still at K, and two live objects cannot share an address. Hence **K ∈ S ⇔ O is that empty singleton**.
- Without the window there is a residual (and very unlikely) case: a temp-rooted object is freed, and a newly created singleton lands on its address.
- `GC.enable` is per-thread state plus a global counter, hence the thread-id assertion.

**IR source, keeping one code path (Rule 12).**
- Refactor `_code_llvm_by_sig` and `_pinned_optimized_ir` (sig_llvm.jl, target_pin.jl) so the raw `_dump_function_llvm` call can optionally run inside `_gc_pinned`, together with `_certify_jl_literals(raw, src)`. The functions then return `(ir, cert)`. For `optimize=true`, certify the RAW module and run `_optimize_pinned` afterwards, outside the window: passes do not change `inttoptr` constants, and lookup is by address.
- Under `ptr_cells=true` only, `extract_parsed_ir(f, T; …)` switches its IR source from `code_llvm(io, f, T)` to the by-sig split. In 1.12, `InteractiveUtils._dump_function` (codeview.jl:193-258) is literally `_which(signature_type(f,t))` → `specialize_method` → `typeinf_code(…, mi, true)` → `_dump_function_llvm(mi, src, false, !raw, dump_module, optimize, debuginfo, params)`, so the switch is equivalent. Keep the `Core.Builtin` and `OpaqueClosure` front-door checks from `_julia_ir_string`.
- At `ptr_cells=false` nothing changes: no certification and no window. The circuit path stays byte-identical, and gate counts are untouched.

**Seeding, in `_extract_const_globals(mod, ptr_cells, jl_literal_cert=nothing)`.**
- It now returns `(out, synth_ptr_provenance, seeds::_JlLiteralSeeds)`; its only caller is module_walk.jl:150.
- Leave the 8kno-fingerprinted catch block byte-identical.
- Under `ptr_cells`, the `init === nothing` arm and the pointer-typed `else` arm both call `_classify_jl_literal_global!(out, seeds, g, jl_literal_cert)`:
  1. Skip `_is_type_tag_global_name` globals (identity-only arm).
  2. Compute `id = _ptr_identity(LLVMGetInitializer(g.ref))`. If it is not `(:addr, K)`, record a reason and do not seed. The reason is "no readable `inttoptr` address (external/opaque)" or "initializer is null / a named global".
  3. If `cert === nothing`, record the reason "no live producing Julia session (text/bitcode ingest); the address is meaningless in this process and is never dereferenced".
  4. If `K ∉ cert.empty_memory`, record the reason "in the producing session this address is a live heap object that is NOT an empty GenericMemory singleton", plus `" — it is a \`$T\` literal"` when `literal_types` knows the type.
  5. Otherwise, seed `blob = zeros(UInt64,16)` with `blob[9] = fact.data_nonnull ? _EMPTY_MEMORY_DATA_SENTINEL : 0`, then `out[gname] = (blob, 8)` and `push!(seeds.certified, gname)`.
- Admission is now purely semantic; names no longer affect soundness. `_is_singleton_data_global_name` should be renamed `_is_jl_global_literal_name` and used only to route diagnostics.

**Threading to every consumer.** Add a kwarg `jl_seeds::_JlLiteralSeeds = _JlLiteralSeeds(Set{Symbol}(), Dict{Symbol,String}())`. The empty default fails closed.

| consumer | change |
|---|---|
| `_module_to_parsed_ir_on_func` → `_convert_instruction` (module_walk.jl:589) | pass `jl_seeds` |
| Load alias arm (instructions.jl ~7420) | alias only if `Symbol(pname) in jl_seeds.certified` |
| Generic reject block (~7442-7605) | after the klgz GOT classifier and after the 3vf2 dead-use drop (keep both unchanged, so uncertified literals hoisted into live blocks with only dead uses still drop), check `haskey(jl_seeds.rejected, Symbol(gname))`. If so, raise the new message (below). Also update the generic message's clause (2) to "`jl_global#N` literals **certified in the producing session** to be the empty GenericMemory singleton" |
| `_handle_intrinsic` (instructions.jl:6762) → `_handle_memcpy_arm` (5439) → `_5viz_global_src_root` (3419) → `_5viz_singleton_load` | replace clause 1 (the name regex) with `gname in jl_seeds.certified`; keep `haskey(globals)` and the `names` clause |
| Other callers (vectors.jl:746, vector_vm_cfg.jl:217, heap.jl:2066) | keep the empty default |

Why 5viz needs the set, and not just the alias:
- The docstring says `names[v] === G` proves the alias landed. It does not, for the first load: Julia gives that load the same SSA spelling as the global (`%"jl_global#146" = load … @"jl_global#146"`).
- If a memcpy is converted before its load (block layout order is not dominance order), clause 3 passes without the alias ever having been installed.
- Recommend fixing the docstring.

**New reject message** (stable test phrases: `Bennett-hsm3` and `NOT certified as the empty GenericMemory singleton`):

> "Bennett-hsm3: load of the interned Julia heap-object literal `@\"$gname\"` under ptr_cells, which is NOT certified as the empty GenericMemory singleton: $reason. Julia names EVERY interned heap literal `jl_global#N` (a `const Ref(…)`, a struct/tuple box, an `Array`, a non-empty `Memory`, …); the closed world models only the empty-GenericMemory singleton (a length-0 header), so reading any other literal would read a phantom blob — a silent miscompile. Refusing at the load site (CLAUDE.md §1; BVM ADR 0021 D3 Amendment B)." $(_3vf2_why)

**Behaviour per producer.**

| producer | live session | cert | jl_global behaviour |
|---|---|---|---|
| `extract_parsed_ir(f,T; ptr_cells=true)` | yes | computed in window | certified → seeded and aliased (unchanged shape); other literals → fail loud at the live load |
| `extract_parsed_ir_by_sig(sig; ptr_cells=true)` | yes | same | same |
| `extract_parsed_ir_set_from_julia` | yes (via the two above, per root and callee) | per module | same; julia_set.jl itself is unchanged |
| any of the above with `ptr_cells=false` | n/a | none | byte-identical to today |
| `extract_parsed_ir_from_ll` / `_from_bc` / `_set_from_ll`, `_parsed_ir_from_ir_string`, `_module_to_parsed_ir` | no | `nothing` | never seeded; a live load fails loud with the "no live producing session" reason |

- Test-only escape hatch: an internal kwarg `_jl_literal_cert` on the .ll/.bc/IR-string entries (forwarded through `_extract_from_module`).
- Tests obtain a real certificate with `Bennett._certify_jl_literals_in_session(ir)`, which runs `_certify_jl_literals(ir, nothing)` inside `_gc_pinned`. The fixture must interpolate a live singleton's address, e.g. `$(UInt(pointer_from_objref(Memory{Int64}())))`.
- This is a genuine classification, not a name trust. Document it as "the caller asserts the addresses were produced in THIS process".
- No BennettVM test ingests `.ll` containing `jl_global` (all 12 of its `.ll`-ingest tests have zero `jl_global` references), so the BVM repo sees no fallout.

---

## 3. ADR 0021 Decision 3 amendment text (BennettVM `docs/adr/0021-julia-callgraph-extraction.md`)

> ## Amendment B — semantic certification of interned heap literals (2026-09-xx, Bennett-hsm3 / gcf7 D1–D3)
>
> **Status: ACCEPTED.** Probe-grounded (Julia 1.12.7). Refines Decision 3.
>
> Decision 3's rule "the floor must never read the `inttoptr` address as data" is **amended as follows**: the JIT address of an interned literal (`@"jl_global#N" = constant ptr @"jl_global#N.jit"`, the `.jit` alias being `inttoptr (i64 K to ptr)`) **may be used at extraction time, by the closed-world Julia producer running in the live producing session, solely to CLASSIFY the object it denotes. It is never dereferenced, never emitted into `ParsedIR`, and never read by the floor at run time.** The emitted program is address-free, so determinism (ADR 0015 D3) is unaffected: the classification outcome is a property of object identity, not of the address.
>
> Classification is a membership test: K is admitted iff it equals `pointer_from_objref(T.instance)` for some concrete `T <: Core.GenericMemory` enumerated from the live type cache, i.e. the literal IS an empty-GenericMemory singleton (`length == 0`, permanent). The test runs inside a GC-disabled window with no yield points, opened immediately after codegen printed K, so the object codegen named at K cannot have been freed and its address reused. Every other literal (`Ref`, struct/tuple box, `Array`, non-empty `Memory`, …) is NOT seeded and fails loud at its first live load.
>
> `jl_global#N` naming is NOT evidence of anything (Julia names every heap literal this way). Producers without a live session (`.ll`/`.bc`/IR-text ingest) certify nothing: an address from another process is meaningless and is never classified.
>
> The certified singleton's header is shipped as a 16-cell ew-8 blob: `length@0 = 0`; `data-ptr@8 = EMPTY_MEMORY_DATA_SENTINEL = GLOBAL_BASE + 2^47` when the real pointer is non-null (always, as measured). The sentinel is non-null like the real pointer, identical in every function's copy so pointer arithmetic stays consistent across the closed-world set, never allocatable, and inside the globals-tier read-window trap band `[GLOBAL_BASE, TLS_BASE − _TLS_TIER_GUARD)`, so any (UB) dereference traps loud. Residual: two DISTINCT empty singletons share the sentinel data pointer (real Julia: distinct). Only aliasing heuristics (`mightalias` → conservative copy) can observe this; results are unchanged.
>
> Consequence for the rest of Decision 3: the "structural" empty-vs-non-empty argument recorded under 416r.13 is withdrawn.

---

## 4. Test plan (red–green)

**New file `test/test_hsm3_jl_literal_certification.jl`.** Register it in `runtests.jl` and run with `--check-bounds=yes`.
1. **RED: the four gcf7 programs fail loud.** Cases: h1 `Ref(S2(3,4))`, h2 `Ref(W1(42))`, h3 `Ref(42)`, h4 `Ref((77,))`, h5, k1-k3 (boxed variants), `const EA = Int[]; f(x) = length(EA) + x`, and `const M = Memory{Int}([7,8,9]); g(x) = length(M) + x`.
   - Run each through `extract_parsed_ir_set_from_julia(f, Tuple{Int}; ptr_cells=true)` and also single-function `extract_parsed_ir(f, Tuple{Int}; ptr_cells=true)`.
   - Assert: it throws; the message contains `Bennett-hsm3` and `NOT certified as the empty GenericMemory singleton`; for h3 it contains `RefValue`.
   - Pristine: these extract today, so the tests are RED.
2. **Positive semantic control.** `const EM = Memory{Int}(); he(x::Int) = length(EM) + x` extracts. The global is in `.globals` and in `certified`, with `blob[1] == 0` and `blob[9] == _EMPTY_MEMORY_DATA_SENTINEL`. This proves admission is semantic: it is a user constant, not a Dict internal.
3. **Classifier unit tests (never dereference).**
   - `_live_empty_memory_singletons()` contains `Memory{Int8}()`, `Memory{Int64}()`, a fresh `Memory{Foo}(undef, 0)` and `AtomicMemory{Int}(undef, 0)`.
   - It does not contain `pointer_from_objref(Ref(42))`.
   - `_certify_jl_literals(ir, nothing)` on a hand-built module with 6 `jl_global#i` globals whose addresses are: `0x10`; `typemax(UInt64)`; a `Libc.malloc(64)` pointer (free it afterwards); `pointer(Vector{UInt8}(undef, 64))` (an interior data buffer, not an object); a live `Ref(42)`; `Memory{Int64}()`. Assert only the last is certified and that nothing crashes. The non-Julia-object cases never touch memory.
4. **Text ingest.**
   - The 5viz DIRECT fixture with a live singleton address and no cert → fails loud with "no live producing Julia session".
   - With `_jl_literal_cert = _certify_jl_literals_in_session(ir)` → admitted.
   - With a live `Ref(42)` address plus a cert → rejected.
   - `external constant ptr` → rejected ("no readable `inttoptr` address").
5. **GC state restored.** After an extraction, `GC.enable(true) == true` (it was enabled). Also mutation-prove the migration guard by calling `_gc_pinned(() -> yield())` from a `Threads.@spawn` task where migration is possible. If that proves flaky, drop it and keep the assertion.
6. **Mutation proofs.**
   - M1: revert the alias-arm gate to the name regex → (1) goes RED.
   - M2: make the membership test always true → (3) goes RED.
   - M3: seed `blob[9] = 0` → the D3 assertion in (2) goes RED.

**Existing tests.**
- **Must stay green unchanged:** the 8 markers (sy29, 57hd, 40ys, 7wsz, bvmd, foz5, p06b, vau9), the test_5viz corpus gate (k), 416r.13 (2) and (3), test_8kno, and test_gate_count_regression. The markers extract from live Julia, and certified singletons produce the same IR shape as today; only blob cell 9 changes, which extraction never reads.
- **Must be updated, with justification in the commit:**
  - `test_416r13_jlglobal_singleton.jl:75`: `all(==(0), data)` becomes: length cell 0, `data[9] == sentinel`, all other cells zero.
  - `test_5viz_loaded_ptr_src_memcpy.jl`: fixtures use the fake `inttoptr (i64 140234000 …)`. Interpolate a live `Memory{Int64}()` address and pass `_jl_literal_cert`. Line 307's pinned blob follows the D3 layout. Add a fixture with a live Ref address that must be rejected. Also fold in gcf7 D4 (a distinct 5viz reject message) and D5 (repoint the comment to case (c) and pin `[8, 24)`).
  - `test_bvmd_root_scale.jl` (C): uses `external global ptr` (no address), so it now fails loud. Convert it to a defined `constant ptr inttoptr(live singleton)` plus a cert.
  - `test_foz5_confined_bounds.jl` HR1/HR2: still `:err`. Check that `_foz5_predicate_probe(...)[:b] === false` still evaluates now that the load throws first. If the probe calls the extractor, adapt it to expect the hsm3 error.

**BennettVM tests (test files only).**
- Add `test/test_hsm3_literal_certification_vm.jl` using the p4_vm.jl harness:
  - h1 and h3 must throw at extraction with the hsm3 message. This is the "non-empty const Ref must fail loud" e2e gate.
  - The `he` positive control must `run!` to `length(EM) + x` for `x ∈ {0, 10, -5}` and `unrun!` exactly.
  - Pin that `Bennett._EMPTY_MEMORY_DATA_SENTINEL` lies in `(GLOBAL_BASE, TLS_BASE - _TLS_TIER_GUARD)`, and that a `MemoryLoad` at the sentinel traps.
- Re-run the existing Dict/push! e2e files one at a time (BVM Rule 7): jlglobal_singleton (e), a70z, 5m1t, 416r12, cwd4, p81t, 416r14, rnhv, 0fw7, tl1l, 40ys, 416r15, x3t0, 7wsz.
- After this lands, the gcf7 5viz BVM end-to-end gate is no longer vacuous and can be written (separate bead).

**Suggested order.**
1. RED file.
2. `jl_literals.jl`.
3. By-sig split and window.
4. `_extract_const_globals` and threading.
5. Load arm, reject, 5viz.
6. Fixture updates.
7. Targeted Bennett files.
8. BVM ADR and test.
9. Worklog.

---

## 5. D3 resolution

**Primary:** seed the data-pointer cell (byte-cell 8, `blob[9]`) with `_EMPTY_MEMORY_DATA_SENTINEL = 2^48 + 2^47` whenever the certified object's real pointer is non-null (always, as measured; the flag is kept for honesty). Why this is faithful for every corpus use:
- Non-null, like the real pointer.
- The same constant in every function's copy, so `ref.ptr - mem.ptr` (memoffset) and `memoryref` stay consistent across the set, exactly as zero did.
- Length-0 `memset`/`memmove` are no-ops whatever the pointer. `IntrinsicMemset`/`IntrinsicMemmove` with `nbytes = 0` touch no cells (intrinsics_bulk.jl:56-135).
- It sits in the globals trap band, so an erroneous dereference traps (memory_floor.jl:273-285). A null dereference, by contrast, silently reads `memory[0]`.
- 5viz copies of [8,16) now propagate a faithful non-null value, so the 5viz window does not need narrowing.

Documented residuals:
- Distinct empty singletons share one sentinel.
- Sub-word reads of bytes 9-15 read 0.

**Fallback, if the BVM e2e re-run shows any divergence:** keep 0 and restrict `_5viz_global_src_root` admission to src ranges inside [0,8), as the reviewer suggested. Record the null data pointer as a bead with that exact trigger.

---

## 6. Impact on BennettVM

- **src:** zero changes. `_global_segment` already copies `reinterpret(Int64, data[k+1])` verbatim, and the trap band already exists.
- **Docs and tests:**
  - ADR 0021 Amendment B (above).
  - The new test file (§4).
  - A one-line note in `test_jlglobal_singleton.jl`'s header: the hand-built zero blobs stay valid VM inputs.

---

## 7. Risks

1. **GC window.**
   - The window must contain no yield points; the thread-id assertion catches a violation loudly.
   - Memory grows for the length of one codegen of a single function (milliseconds), even with 32 threads.
   - Inference stays outside the window.
   - Rejected alternative: dereferencing K (`unsafe_pointer_to_objref`). It is use-after-free-prone on the reflection path (temp roots are dropped after `jl_get_llvmf_defn`) and cannot handle foreign or garbage addresses.
2. **Julia internals** (`Core.TypeName.cache` / `.linearcache`, `_dump_function_llvm`, `typeinf_code`).
   - Version-guard them like `_assert_sig_llvm_supported`. The enumeration's self-test fails loud.
   - A missed singleton only fails closed: it re-walls, it never miscompiles.
   - The enumeration takes 0.1 ms warm (≈230 singletons).
3. **Precompile and caching.**
   - ParsedIR carries no address or certificate, so any cache of it stays valid.
   - `_parsed_ir_cache` and `_compile_cache` are `ptr_cells=false` only.
   - `precompile.jl` does not exercise `ptr_cells`.
4. **Determinism.** The outcome depends only on object identity, and the sentinel is a constant. The `#N` names drift as before.
5. **Cost.** The IR is parsed twice under `ptr_cells` (certification plus the walk): milliseconds.
6. **Behaviour change for text/bitcode ingest.** `jl_global` loads in hand-written `.ll` now fail loud by default. This affects only the Bennett fixtures listed in §4.
7. **Out of scope, but please file beads.**
   - (a) O1: at `optimize=true`, loads through `@"jl_global#N.jit"` (a GlobalAlias operand) are still silently skipped. Recommend a `ptr_cells` guard that fails loud on any load or GEP whose pointer resolves to `(:addr, K)`. The certificate is keyed by address, so a future admission can reuse it.
   - (b) Pre-existing: BVM gives each ParsedIR its own globals window, so one singleton referenced from two functions gets two VM addresses. `===` between them would diverge from Julia. The corpus has no such compare; the `emptymem` block just yields the literal. This needs its own probe.

---

## Critical files for implementation
- `/home/user/Bennett.jl/src/extract/module_walk.jl` (`_extract_const_globals` 958-1117; threading at 150 and 589)
- `/home/user/Bennett.jl/src/extract/instructions.jl` (load alias arm ~7403-7424; reject block ~7442-7605; 5viz 2906-2921 and 3005-3061, 3419; `_handle_intrinsic` → memcpy 5439/6762)
- `/home/user/Bennett.jl/src/extract/sig_llvm.jl` and `/home/user/Bennett.jl/src/extract/target_pin.jl` (`_code_llvm_by_sig`, `_pinned_optimized_ir`, `_julia_ir_string`: window and certificate split)
- `/home/user/Bennett.jl/src/extract/entry.jl` (`extract_parsed_ir`, `_parsed_ir_from_ir_string`, `.ll`/`.bc` entries: certificate kwarg)
- `/home/user/Bennett.jl/src/extract/constexpr.jl` (`_ptr_identity` reused; retire `_is_singleton_data_global_name`)
- `/home/user/bennettvm.jl/docs/adr/0021-julia-callgraph-extraction.md` (Amendment B)
- Tests to update: `/home/user/Bennett.jl/test/test_416r13_jlglobal_singleton.jl`, `/home/user/Bennett.jl/test/test_5viz_loaded_ptr_src_memcpy.jl`, `/home/user/Bennett.jl/test/test_bvmd_root_scale.jl`, `/home/user/Bennett.jl/test/test_foz5_confined_bounds.jl`
