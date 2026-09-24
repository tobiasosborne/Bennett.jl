# Bennett-hsm3 — PROPOSER B (verbatim hand-back, 2026-09-24)

# Bennett-hsm3: design proposal (Proposer B). Certify `jl_global` literals by what they are, not by their name

## TL;DR
- **Root cause, confirmed.** Julia's codegen names every heap literal `@"jl_global#N"`. Under `ptr_cells=true`, three places decide "this is data" from the name alone:
  - the seeding in `_extract_const_globals`;
  - the load alias arm in `_handle_load`;
  - 5viz's `_5viz_singleton_load`.
- **Why the name proves nothing.** I classified every `jl_global` against the live session. Each const `Ref` literal (h1–h4, k1) resolves to a `Base.RefValue{…}`. The throw-path message literals resolve to `String`s. A new executed counterexample: `const M3 = Memory{Int}([7,8,9]); m3(x)=length(M3)+x` gives BVM = 10 against oracle 13, and still reverses. I reproduced p4_vm on HEAD: h1–h4 all mismatch and reverse cleanly.
- **The fix, in one sentence.** At extraction, in the same process whose codegen produced the IR, resolve each `jl_global#N` alias address to its object and certify it only if it is the canonical empty GenericMemory singleton (`typeof(x).instance === x`). Seed only certified objects, under a renamed key `jl_global#N.obj`. After the walk, fail loud on any surviving use of anything uncertified, or of the raw slot name.
- **Corpus still green.** I ran an in-session emulation (via `@eval Bennett` plus `invoke_in_world`, no repo edits):
  - h1, h2, h3, h4, k1 and m3 are all rejected;
  - u1 (a const empty Memory) extracts;
  - `thr` (a String used only in a throw path), fdict and Dict64 extract;
  - the push! wall-12 marker message is unchanged: p06b positive, `_p06b_cell_ptr_target_kind`, "SILENTLY SKIPS", `!37mt`, `!.mem`, `!5viz`, `!hsm3`.

## 1. Verified root cause, and what each corpus program binds

The probe is in scratchpad `hsm3_B/instr.jl` + `corpus.jl` / `scan.jl`. It hooks `_extract_const_globals` and resolves each `@"jl_global#N.jit" = private alias ptr, inttoptr (i64 A)` with `unsafe_pointer_to_objref`. The resolved addresses matched `pointer_from_objref` of the const-bound objects exactly (for example 140474815009424 = 0x7fc2d772d290 = `RI`).

| program | `jl_global`s bound: object, and where it is loaded | used in surviving IR? |
|---|---|---|
| push! root (`v=Int64[]; push!(v,n); v[1]`, every marker file and 5viz (k)) | empty **Memory{Int64}** singleton (`%top`, the 5viz site) | yes, certified |
| `_growend!##0` (reached only with `:skip`) | Memory{Int64} singleton (`emptymem`); String "Vector has invalid state…" (L96); String "Vector can not be resized concurrently…" (L90) | singleton yes; Strings **no** (throw blocks) |
| fdict_d1b root | Memory{UInt8} and Memory{Int8} singletons (`top`); String "" (L84) | singletons yes; String no |
| `rehash!` (Dict) | Memory{UInt8} and Memory{Int8} singletons (`emptymem*`); String "Multiple concurrent writes to Dict detected!" (L189) | singletons yes; String no |
| `setindex!`, `ht_keyindex2_shorthash!` | none | – |
| Dict{Int64,Int64}: fd64 (a70z) and the 14-insert fd14 (rnhv/0fw7) | same pattern with Memory{Int64} | same |
| `_root40ys`, `_use7wsz` | none | – |
| h1 / h2 / h3 / h4 / k1 | RefValue{S2} / RefValue{W1} / RefValue{Int64} / RefValue{Tuple{Int64}} / RefValue{W1} | yes → silent miscompile today |
| m3 (new) | Memory{Int64} of **length 3** | yes → silent miscompile (BVM 10 vs 13) |
| u2 = `unsafe_wrap(Memory{Int}, p, 0)` | a length-0 Memory that is **not** the singleton | yes (correct today by accident) |

- **Strings are already being seeded.** Today every non-singleton String gets a zeroed 16-byte blob in `.globals` (1–2 dead entries per Dict or `_growend!` body, plus `thr`). That shows directly that the name gate admits non-singletons.
- **Only singletons are live.** No non-singleton `jl_global` reaches surviving IR anywhere in the corpus (checked with `compute_ssa_use_counts`).

**Every consumer of the name-based assumption:**
- `constexpr.jl:158` `_is_singleton_data_global_name`, the name regex;
- `module_walk.jl:1018`, the seeding when `LLVM.initializer` throws;
- `module_walk.jl:1109`, the "belt-and-suspenders" seeding for any pointer-typed initializer (this is the arm the 5viz `.ll` fixtures hit);
- `instructions.jl:7420`, the load alias arm. It checks the name only, not `.globals` membership, so it also aliases `external` and imaging-mode globals and leaves dangling SSA;
- `instructions.jl:2915` `_5viz_singleton_load`, used by both the DIRECT shape (:3040) and the store-forward shape (:3061);
- `instructions.jl:7105`, GEP Case B. `getelementptr i8, ptr @"jl_global#N", K` emits `IRVarGEP(ssa(:jl_global#N))` with **no `.globals` check**, so it indexes the object blob through the slot (slot/object confusion);
- `_handle_memcpy_global_src` G5 (:4276). A memcpy from the slot `@jl_global#N` would read the object blob as if it were the slot's content;
- the scalar load `load iN, ptr @jl_global#N` (silently skipped, leaving a dangling dest);
- the `.jit` alias used directly at optimize=true. This is the review's O1: h2 and u1 at `optimize=true` extract with an undefined operand;
- `synth_ptr_provenance`, which is not involved at all: it is alloca-keyed and consulted only by the memcpy global-src arm.

**The imaging-mode finding.** Under `julia --image-codegen` (and so, per Julia's `imaging_default`, during pkgimage generation) the slot is `@"jl_global#N" = external global ptr`. It has no address. Today it is not seeded, but the alias arm still aliases it by name, leaving a dangling operand.

**Cache finding.** `_parsed_ir_cache` **is serialized into the pkgimage.** A fresh session shows 5 entries from the precompile workload, including `soft_fadd`. All of them are `ptr_cells=false`, because the cache key has no `ptr_cells` and `_extract_parsed_ir_cached` never passes it.

## 2. The certification predicate, and why it is enough

A `jl_global#N` global `g` is CERTIFIED only if every one of these holds. A–E are LLVM/provenance checks; F–I are Julia-semantics checks.

- **(A) Candidate selection only.** The name matches `^jl_global#\d+$`. The name never admits anything.
- **(B) Constant slot.** `LLVM.isconstant(g)` and the value type is `ptr` in addrspace 0. A non-constant slot could be overwritten by the program.
- **(C) Address present.** Following the raw C-API initializer through at most 16 `GlobalAlias` links reaches `inttoptr (i64 K)` with `K` a `ConstantInt`. That is, `LLVMGetInitializer` → `LLVMAliasGetAliasee` → `LLVMGetConstOpcode == LLVMIntToPtr` → operand 0 → `LLVMConstIntGetZExtValue`. External, null, ConstantStruct or any other initializer means REFUSED.
- **(D) Live provenance.** The IR text was emitted by this process's codegen, inside one GC-disabled window spanning emission → parse → classification. Otherwise REFUSED.
- **(E) Address sanity.** `K != 0` and `K % 8 == 0`. Then `x = unsafe_pointer_to_objref(Ptr{Cvoid}(K))`.
- **(F) Type.** `T = typeof(x)`, `T <: GenericMemory` and `isconcretetype(T)`.
- **(G) Address space.** `T.parameters[3] === Core.CPU`.
- **(H) Canonical singleton.** `isdefined(T, :instance) && T.instance === x`.
- **(I) Invariant assert.** `length(x) == 0`. If this fails it is `error("Julia invariant broken")`, not a refusal.

Why this is enough, all verified on 1.12.7:
- **Every length-0 allocation is this object.** `Memory{Int}() === Memory{Int}(undef,0) === Int64[].ref.mem === Memory{Int}.instance`, and the same holds for atomic and bits-union element types. So (H) names exactly the object Julia hands out for any empty allocation of `T`, and nothing else.
- **Emptiness is immutable.** `length` and `ptr` are `const` fields (`isconst(Memory{Int}, :length/ptr) == true`), so the modelled `length = 0` is true forever. With zero elements, nothing mutable can be observed, so there is no determinism trap.
- **One blob serves every element type.** The header is always `{length::Int, ptr}` (fieldnames `(:length, :ptr)`). Element type only affects bytes past the data pointer, and there are none. The singletons are distinct per element type (`Memory{Int}() !== Memory{UInt8}()`), so they get distinct keys (distinct globals and addresses). Two slots resolving to the same address share one key, preserving identity within a module.
- **Near-misses are refused.** `unsafe_wrap(Memory{Int}, p, 0)` (length 0, not the singleton), `Memory{Nothing}(undef,5)` (zero-size elements, length 5), `Memory{Int}([7,8,9])`, `Ref`s and Strings all fail (H) or (F). This is conservative, as the maintainer asked.
- **Resolution safety.** The address was a `jl_value_t*` that codegen embedded moments earlier. The GC-off window closes the gap after `_code_llvm_by_sig` drops its local `CodeInfo` `src`. I also re-resolved `@eval`-interpolated and const-folded String literals after three `GC.gc(true)` calls with no problem.
- **The identity test is the proof.** The final `T.instance === x` compares against a permanently rooted object, so a stale address cannot be certified unless it currently *is* the singleton.

## 3. Mechanism and threading

**NEW `src/extract/jlglobal_cert.jl`** (included from `ir_extract.jl` before `module_walk.jl`):

```julia
struct _JLGlobalCert; gv::String; objkey::Symbol; certified::Bool; desc::String; end
const _JLGlobalCerts = Dict{String,_JLGlobalCert}          # keyed by GV name, pure data (no addresses kept)
_is_jl_global_slot_name(s) = occursin(r"^jl_global#\d+$", s)  # CANDIDATE finder only; replaces _is_singleton_data_global_name
_jl_global_objkey(gv::AbstractString) = Symbol(gv, ".obj")  # the ONLY name IR may use for the object (keeps "jl_global" for BVM (e)/416r13 tests)
_jl_global_address(g)::Union{UInt64,String}                  # raw C API, (C); returns a reason String on failure
_is_empty_memory_singleton(x)::Bool                           # (F)-(H), + (I) assert
_describe_literal(x)::String  # "Base.RefValue{S2}", "Memory{Int64} of length 3", "Memory{Int64} of length 0 that is NOT the canonical Memory{Int64}.instance singleton", "String (ncodeunits 14)"

function _classify_jl_globals(mod; live::Bool, refuse_reason::String)::_JLGlobalCerts
    certs = _JLGlobalCerts(); by_addr = Dict{UInt64,Symbol}()
    for g in LLVM.globals(mod)
        nm = LLVM.name(g); _is_jl_global_slot_name(nm) || continue
        live || (certs[nm] = refused(nm, refuse_reason); continue)
        LLVM.isconstant(g) || (certs[nm] = refused(nm, "non-constant slot"); continue)
        a = _jl_global_address(g)
        a isa String && (certs[nm] = refused(nm, a); continue)   # e.g. "external global — imaging-mode IR (precompile / --image-codegen)"
        (a != 0 && a % 8 == 0) || (certs[nm] = refused(nm, "misaligned address"); continue)
        x = unsafe_pointer_to_objref(Ptr{Cvoid}(a))
        key = get!(by_addr, a, _jl_global_objkey(nm))            # dedup: same object ⇒ same key
        certs[nm] = _is_empty_memory_singleton(x) ?
            _JLGlobalCert(nm, key, true, "empty $(typeof(x)) singleton") :
            _JLGlobalCert(nm, key, false, _describe_literal(x))
    end
    certs
end

function _live_ir_and_certs(emit::Function, ptr_cells::Bool)
    ptr_cells || return (emit(), _JLGlobalCerts())
    prev = GC.enable(false)                                   # emission → parse → classify: no GC in between
    try
        s = emit()
        certs = LLVM.Context() do _
            m = parse(LLVM.Module, s); try _classify_jl_globals(m; live=true, refuse_reason="") finally dispose(m) end
        end
        return s, certs
    finally GC.enable(prev) end
end

function _assert_no_refused_jl_global_use(pir, certs, fname, sites)
    uses = compute_ssa_use_counts(pir)                        # total over every IRInst + terminators (lowering/operand.jl)
    for c in values(certs)
        haskey(uses, Symbol(c.gv)) && error(slot_msg(c, fname))          # raw SLOT name used as a value (Case-B GEP, stale alias order…)
        !c.certified && haskey(uses, c.objkey) && error(refusal_msg(c, fname, sites[c.objkey]))
        @assert c.certified || !haskey(pir.globals, c.objkey)
    end
end
```

**`src/extract/entry.jl`:**
- `extract_parsed_ir` and `extract_parsed_ir_by_sig`: call `(ir, certs) = _live_ir_and_certs(() -> _julia_ir_string(...) / _code_llvm_by_sig(...), ptr_cells)` and pass `jl_global_certs = certs`.
- `_parsed_ir_from_ir_string(ir; jl_global_certs, …)`: make the new kwarg **required**, and forward it into `_module_to_parsed_ir`.
- `extract_parsed_ir_from_ll`, `extract_parsed_ir_from_bc` and `extract_parsed_ir_set_from_ll`: add a new kwarg `jl_globals::Symbol = :refuse`, which must be one of `(:refuse, :live_session)` (else `ArgumentError`). Under `ptr_cells`, classify the parsed module **before `_run_passes!`**, with `live = (jl_globals === :live_session)` and `refuse_reason = ".ll/.bc input: a JIT address in a file is not interpretable in this session (ADR 0021 D3 Amendment B); pass jl_globals=:live_session only for IR that `code_llvm` produced in THIS process"`.
- `_extract_from_module` forwards the certs.

**`src/extract/module_walk.jl`:**
- `_module_to_parsed_ir`, `_module_to_parsed_ir_set` and `_module_to_parsed_ir_on_func` take `jl_global_certs::Union{Nothing,_JLGlobalCerts}=nothing`.
  - `nothing` with `ptr_cells` means classify with `live=false` ("no live-session provenance supplied"). This makes the default safe for every producer; only the two Julia entries can obtain certification.
  - Rename the current body to `_module_to_parsed_ir_on_func_walk`. The wrapper runs classify → walk → `_assert_no_refused_jl_global_use` on the returned ParsedIR. That covers every return point: dict_vm, vec_vm, heap_skel and normal.
  - In the walk, after `_extract_const_globals`: `for c in values(certs); c.certified && (globals[c.objkey] = (zeros(UInt64,16), 8)); end`. Thread `jlg = certs` into `_convert_instruction`.
- `_extract_const_globals`: **delete both name-based seedings** (:1018 and :1109). The `init === nothing` arm becomes a plain `continue`. Rewrite the docstring: the "structural" claim is false.

**`src/extract/instructions.jl`:**
- `_convert_instruction` gains `jlg`.
- **Load arm (:7403):**
  - Under `ptr_cells` and a GlobalVariable pointer operand whose name is a `jl_global` slot, look up `c = jlg[pname]`. If it is missing, raise an internal `_ir_error`.
  - If the result type is not a `PointerType`, `_ir_error("Bennett-hsm3: … scalar read of Julia's literal SLOT reads the JIT address itself")`.
  - Otherwise set `names[inst.ref] = c.objkey` (certified **or** refused), record `sites[c.objkey] = string(inst)` for the diagnostic, and `return nothing`.
  - **Before** that, add the O1 guard: if the raw operand-0 kind is `LLVMGlobalAliasValueKind` with a `jl_global…jit` name, `_ir_error("Bennett-hsm3/O1: load straight through the JIT alias (optimize=true folded the slot load); not modelled — extract at optimize=false")`.
  - This is a use-site check, so first-wall ordering is unchanged. test_7wsz (J2) still hits the inline-asm wall first.
- **`_5viz_singleton_load`:** return three states: `(:ok, objkey, gv_ref)`, `(:refused, cert)` or `nothing`. The checks are `jlg[gv]`, `names[v] === objkey`, and `haskey(globals, objkey)` for the certified case.
  - In the memcpy arm, `:refused` raises `_ir_error("Bennett-hsm3: memcpy src reads Julia literal `@jl_global#N`, which this session resolves to <desc> — not the empty GenericMemory singleton; reading it would silently return 0 (gcf7 D1)")`. This also fixes D4 for this class: no misleading 37mt text.
  - `global_src` becomes `objkey`, so `ssa(objkey)` and `globals[objkey]` are used.
- **D3 clamp** in 5viz 6d: add `(goff + N <= 8) || _ir_error("…only the LENGTH field [0,8) of the certified singleton is faithfully modelled; bytes [8,16) are the data pointer, modelled 0 but non-null in Julia (gcf7 D3) …")`. The corpus is `[0,8)`.
- **Slot guards** with clear messages (the scan is the backstop):
  - `_handle_memcpy_global_src` G5, when `_is_jl_global_slot_name(gname)`;
  - GEP Case B at :7105;
  - array Case C at :7156.
- **Comment sites** to reword to "certified": :316, :441, :801, :1706, :2444, :2677, :3366, :3779, plus `heap.jl` and `dict_vm.jl` (comments only; no calls there).

**`constexpr.jl`:** delete `_is_singleton_data_global_name`. A tripwire test asserts `!isdefined(Bennett, :_is_singleton_data_global_name)`.

### Why use-directed rather than failing at the load site
I emulated both policies. Both pass today's corpus, because the String literals sit in throw blocks that the `ptr_cells` dead-block pruner drops. The load-site policy would start spuriously rejecting Dict and push! the moment the pruner stops dropping a throw-path literal load. The use-directed scan rejects exactly when the object's value survives into IR. It is total over IR, because every memory access needs an SSA base or a `.globals` entry, and refused objects have neither. It also gives a precise message via the recorded load site.

## 4. Behaviour per producer

| producer | where the IR comes from | outcome |
|---|---|---|
| `extract_parsed_ir(f,T; ptr_cells=true)` at optimize=false | `code_llvm` in-process, GC-off window | singleton certified and seeded as `jl_global#N.obj`; anything else is refused and fails loud if used |
| same at optimize=true (pinned) | in-process; slots folded into `.jit` alias uses | O1 guard fails loud (was a dangling operand for h2 and u1) |
| `extract_parsed_ir_by_sig` and `…_set_from_julia` | same | same; certificates are per body (each body is its own module) |
| `.ll`, `.bc`, `set_from_ll` (default) | a file | every `jl_global` refused |
| same with `jl_globals=:live_session` | the caller asserts the IR came from this process | live oracle, with no GC window (the caller keeps objects alive) |
| imaging-mode IR (pkgimage generation, `--image-codegen`) | in-process, but slots are `external` | refused: "imaging-mode IR — literal relocated at load, cannot be resolved" |
| any producer with `ptr_cells=false` | – | classification never runs (no dereference); byte-identical, so circuit gate-count baselines are untouched |
| `_parsed_ir_cache` and the precompile workload | `ptr_cells=false` | never seeds a `jl_global` (pinned by a test) |

**Caching across sessions is sound.** A ParsedIR carries no address and no certificate, only the zeroed blob. "Is the empty singleton" is a property of the program's code, not of the session. Reuse is therefore sound as long as method definitions and const bindings are unchanged, which is the same staleness caveat every extraction cache already has. Any future modelling of non-empty literals **by value** would break this. It would be limited to deeply immutable objects: a const `Ref`'s contents are a mutable snapshot, which is the determinism trap.

## 5. ADR 0021 Decision 3: text for Amendment B (in the BennettVM repo)

> **Amendment B — classification-only use of JIT addresses (Bennett-hsm3, 2026-09).** Decision 3's rule stands: the floor never reads an `inttoptr` JIT address as data, and nothing derived from its numeric value (not the value, a hash, an ordering, or an offset) ever enters `ParsedIR` or influences emitted IR. One additional use is permitted. At **extraction time**, in the **same Julia process whose codegen emitted the IR** (the emission-to-classification window is GC-disabled), Bennett.jl may resolve a `jl_global#N` literal's address to the live object **solely to classify it**. The only admitted class is the canonical empty `GenericMemory` singleton (`typeof(x).instance === x`, addrspace `Core.CPU`). It is modelled session-invariantly as a zeroed 16-byte `{length, data}` header under an opaque `.globals` key. Every other object is refused and fails loud at its first surviving use. IR whose provenance is not this process's codegen (`.ll`/`.bc` files, imaging-mode IR with `external` slots) is never classified unless the caller explicitly asserts live-session provenance (`jl_globals = :live_session`). Because the classification is a property of the program, not of the session, a ParsedIR carrying it may be cached or reused across sessions without re-certification. Type-tag globals (Lever 1) are unchanged: still by name, never by address. The `ParsedIR` contract keeps its shape; `.globals` keys stay opaque Symbols.

## 6. D3 decision: the data-pointer blob
- **Now: restrict 5viz to the length field `[0,8)`.** The corpus is `0+8 ≤ 16`, which passes. Fixtures (b) and (c) (`[8,16)`) flip to negative gates.
- **Provenance registration: rejected.** `synth_ptr_provenance` is alloca-keyed and consulted only in the memcpy global-src arm (`instructions.jl:4353-4400`). It never sees the direct `IRPtrOffset(+8)+IRLoad` reads, so it would be inert.
- **The existing direct data-pointer reads stay modelled as 0.** Examples: push! `%memory_data_ptr`, which becomes `MemoryRef.ptr`; fdict `.ptr_ptr`, which feeds a length-0 memset. The corpus needs them, and their only uses are base-cancelling (`ref.ptr − mem.ptr`), length-0 memset/memmove operands, and memoryref fields. Null is observable only through a null-compare or a ptr→int escape. This is documented as a known gap.
- **Follow-up beads:**
  - (i) a faithful model: BVM mints a non-null, unique, never-dereferenceable data pointer per certified singleton (needs a ParsedIR marker, cross-repo);
  - (ii) a BVM null-page trap, `MemoryLoad` at an address in `[0, 4096)` fails loud. Today a read through the modelled null pointer silently returns 0 from `s.memory`.

## 7. Red-green test plan
**Bennett: new `test/test_hsm3_jlglobal_certification.jl`, registered in runtests; run with `--check-bounds=yes`.**
- **T1 classifier units.**
  - True for: `Memory{Int}()`, `Memory{UInt8}()`, `Memory{Int}(undef,0)`, `Memory{Union{Int,Nothing}}()`, `GenericMemory{:atomic,Int,Core.CPU}(undef,0)`.
  - False for: the `unsafe_wrap` length-0 memory, `Memory{Int}([7,8,9])`, `Memory{Nothing}(undef,5)`, `Ref(42)`, a String, `Int64[]`, the type `Memory`, `nothing`.
  - Canaries: `Memory{Int}() === Memory{Int}.instance` and `Memory{Int}() !== Memory{UInt8}()`.
  - Tripwire: the old name predicate is gone.
- **T2 address resolution (hand-built `.ll` with interpolated live addresses).**
  - Certified in both spellings: direct `inttoptr` initializer, and Julia's `constant ptr @X.jit` + `alias`.
  - Refused: the address of a const Ref; `external`, `null`, a non-constant slot; the default `:refuse` even for a live singleton address.
  - Two slots with the same address get one key.
- **T3 counterexamples via `extract_parsed_ir_set_from_julia(ptr_cells=true)`.** h1–h4, k1 and m3 throw.
  - Every message contains `Bennett-hsm3` and the resolved description (`Base.RefValue{S2}`; `Memory{Int64} of length 3`).
  - h1, h2, h4 and k1 get the 5viz-specific message, **not** the `Bennett-37mt` text.
- **T4 positives.**
  - u1 extracts, with exactly one `…jl_global#N.obj` key holding `(zeros(16),8)`.
  - `thr` extracts with **no** `jl_global` key in `.globals`.
  - fdict's root has exactly 2 certified keys and no refused use.
  - test_416r13 (1), (2) and (3) are unchanged.
- **T5 slot/object and O1.** A scalar `load i64` of the slot, a byte GEP on the slot, a memcpy from the slot, and a load through `jl_global#N.jit` each fail loud. h2 and u1 at `optimize=true` fail loud (O1) instead of producing a dangling operand.
- **T6 cross-session.**
  - A subprocess `julia --image-codegen` extraction of u1 fails loud with the imaging-mode reason. This is slow; the T2 `external` case covers the same shape cheaply.
  - A `.ll` written by a subprocess and ingested here with the default fails loud.
  - Every `_parsed_ir_cache` entry after `using Bennett` has no key containing "jl_global".
- **T7 5viz and D3.** The corpus `(k)` wall-12 gate and `(a)` `[0,8)` stay admitted. `(b)` and `(c)` reject with the "LENGTH field" message.
- **Migrations:**
  - 5viz: `_5VIZ_GLOB` uses the live `pointer_from_objref(Memory{Int64}())`, and the helpers pass `jl_globals=:live_session`. `_5VIZ_G` becomes `Symbol("jl_global#93.obj")`. Add negatives: the same fixture under `:refuse`, and the live address of a `const Ref(42)`.
  - bvmd `(C)`: switch the `external global` to a live-certified form.
  - foz5 HR1/HR2: they stay `:err` (the probe checks the predicate directly); confirm the message.
- **Green bar:** the 8 marker files (sy29, 57hd, 40ys, 7wsz, bvmd, foz5, p06b, vau9), plus 5viz, 416r13, 3vf2, 9n3y, klgz, t9rh and gate_count_regression.

**BennettVM: new `test/test_hsm3_const_literal_vm.jl`.**
- End-to-end: h1–h4 and m3 must throw `Bennett-hsm3` at extraction, so `lower_vm` never runs. This is the gate the review asked for, no longer vacuous.
- u1 runs `== x` and reverses.
- Existing Julia-extraction VM tests stay green: test_jlglobal_singleton (e) (keys still contain "jl_global"; the String is no longer seeded), cwd4, a70z, rnhv, 0fw7, 40ys, 7wsz, sy29, 57hd, p06b, bvmd, vau9.
- Optional: serialize a certified fdict set in a subprocess, then deserialize, lower and run it here (checks the fdict E2E result holds, fdict(3,7) == 7), showing cross-session reuse is sound.

## 8. Risks
1. **Dereference safety** rests on codegen only naming live `jl_value_t*` as `jl_global#`, plus the GC-off window. With `:live_session`, `.ll` callers must keep the objects alive themselves.
2. **`GC.enable(false)` is process-wide** for a window of milliseconds. It is counted and nestable.
3. **Julia drift.** If a future Julia stops using `T.instance` for empty memories, the corpus fails loud rather than silently; the canaries catch it.
4. **Over-refusal.** The `unsafe_wrap` empty memory is refused. `optimize=true` `ptr_cells` paths that "succeeded" with dangling operands now fail loud. Every hand-written `jl_global` `.ll` fixture needs migrating.
5. **D3 residual:** the direct data-pointer reads remain null (follow-up (i) and (ii) above).
6. **Pre-existing: a singleton's identity differs across functions**, because BVM gives each function its own ROM window, so `===` between two functions' singletons diverges. File a bead.
7. **Every new error must go through `_ir_error`** (Bennett-authored text), or the benign-error swallow at `module_walk.jl:~605` will eat it.
8. **Alias ordering.** A use seen before the aliasing load is caught by the slot-name scan, which is the loud direction.
9. **Circuit path** at `ptr_cells=false`: h3 and u1 already fail loud ("undefined SSA"); no change.
10. **This is a core `ir_extract` change,** so the 3+1 process applies. BennettVM Rule 14: the BVM-side work is only the ADR amendment and the test.

### Critical Files for Implementation
- /home/user/Bennett.jl/src/extract/module_walk.jl
- /home/user/Bennett.jl/src/extract/instructions.jl
- /home/user/Bennett.jl/src/extract/entry.jl
- /home/user/Bennett.jl/src/extract/constexpr.jl
- /home/user/BennettVM.jl/docs/adr/0021-julia-callgraph-extraction.md

Probes are in `/tmp/claude-0/-home-user-Bennett-jl/3321b1e1-b9ad-5f3e-aa45-12923102bdac/scratchpad/hsm3_B/`: `instr.jl`, `corpus.jl`, `scan.jl`, `emu.jl` (run with `use` or `strict`), `opt.jl`, `gc.jl`, `vm2.jl`, and `vmenv/`.