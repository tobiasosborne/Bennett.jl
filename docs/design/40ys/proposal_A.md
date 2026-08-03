# Bennett-40ys — Design Proposal A

**Closed-world walker: non-singleton (instance-less) callee keys**

Proposer A (independent). Julia 1.12.3, Bennett.jl @ `2d2a81e` (main).
All claims below are backed by probes run in this session; transcripts are in
§9 and the scratch files `propA_probe{1..9}.jl`.

---

## 0. TL;DR

* **Mechanism (the crux):** stop treating `(callable, argtypes)` as the unit of
  extraction currency. Use the **full specTypes signature** `Tuple{K, A...}` and
  emit LLVM IR from it directly via the *same* code path `InteractiveUtils.code_llvm`
  uses internally — `Base._which` → `Base.specialize_method` → `Base.Compiler.typeinf_code`
  → `InteractiveUtils._dump_function_llvm`. `code_llvm` derives **nothing** from the
  callable except `Base.signature_type(f, t)` (verified by reading
  `stdlib/v1.12/InteractiveUtils/src/codeview.jl:193-253`), so an instance is
  structurally unnecessary. **Probe-proven** on the real `_growend!` closure key and
  proven byte-identical (modulo per-emission `_NNN` / `jl_global#N` counters) to
  `code_llvm` on ordinary functions.
* **Scope:** option (b′) — *one* new arm keyed on the general property
  "**callable type with no `.instance`**", which covers closures **and** callable
  structs (probe 8: `Adder` behaves identically), with a **total** classifier that
  fails loud on anything outside the three recognised kinds. Not a general
  "any callee whatsoever" rewrite; not diagnostic-only.
* **Naming:** the barename is *the name Julia's codegen mangles into the LLVM
  symbol*. For all three kinds that name is available: constructor →
  `nameof(k.parameters[1])`, singleton → `nameof(k.instance)` (both unchanged),
  instance-less → `Base._which(st).method.name`. Probe: `method.name` is
  `Symbol("#_growend!##0")`, exactly what `j_#_growend!##0_98` demangles to, and
  exactly what BVM's `_vm_funcname` / `_vm_dispatch_name` both sanitise to
  `._growend!..0`. **Zero BVM changes needed for name binding.**
* **Registry:** a *name-only* callee registry (`register_callee_name!`) plus one
  hoisted-helper hook in `instructions.jl`, because `register_callee!` requires a
  `Function` **value** we do not have and the un-registered path emits a *mangled*
  Symbol that BVM cannot link.
* **BVM impact:** none for this bead. The follow-on wall (aggregate-by-pointer
  argument ABI at `CallEnter`) is real, is **not closure-specific** (it already
  applies to any Julia function taking a struct arg), and belongs to its own bead.
* **Biggest risk:** we depend on three Julia *internals* (`Base._which`,
  `Base.specialize_method`, `InteractiveUtils._dump_function_llvm`). Mitigated by
  a load-time capability assertion that fails loud with `VERSION` (Rule 5/9).

---

## 1. Ground truth — verified independently (Rule 10)

### 1.1 The crash reproduces exactly as reported

Probe 1 (`propA_probe1.jl`), fixture `f(n::Int64) = (v = Int64[]; push!(v, n); @inbounds v[1])`:

```
=== transitive_callees(f, Tuple{Int64}) ===
SINGLETON    | key=typeof(Base.throw_boundserror) | argtypes=Tuple{Vector{Int64}, Tuple{Int64}}
NO-INSTANCE  | key=Type{BoundsError}              | argtypes=Tuple{Any, Tuple{Int64}}
NO-INSTANCE  | key=Base.var"#_growend!##0#_growend!##1"{Vector{Int64}, Int64, Int64,
                     Int64, Int64, Int64, Memory{Int64}, MemoryRef{Int64}} | argtypes=Tuple{}
NO-INSTANCE  | key=Type{ConcurrencyViolationError} | argtypes=Tuple{String}
SINGLETON    | key=typeof(Core.throw_inexacterror) | argtypes=Tuple{Symbol, Type, Int64}
NO-INSTANCE  | key=Type{InexactError}             | argtypes=Tuple{Symbol, Any, Vararg{Any}}

=== _callable_of_key crash reproduction ===
CRASH on key=Base.var"#_growend!##0#_growend!##1"{...} -> UndefRefError: access to undefined reference
```

Confirms: `src/extract/julia_set.jl:100` (`_callable_of_key(k::Type) = k.instance`).
`_nameof_of(k::Type) = nameof(k.instance)` (line 105) has the **same** latent crash and
is reached from `_canonical_callee_key` (line 120-121) — so a fix that only patches
`_callable_of_key` moves the crash three lines down. The classifier must cover both.

The closure struct is 72 bytes, 8 fields:
```
fieldnames(CT) = (:a, :newmemlen, :offset, :newlen, :len, :memlen, :mem, :ref)
fieldtypes(CT) = (Vector{Int64}, Int64, Int64, Int64, Int64, Int64, Memory{Int64}, MemoryRef{Int64})
```

### 1.2 Two corrections / additions to the scout report

1. **The root ALSO walls today**, independently of the closure key. With the
   registration crash hypothetically removed,
   `extract_parsed_ir(f, Tuple{Int64}; optimize=false, ptr_cells=true)` fails at the
   `bennettvm-416r.16` consumed-sret reconciler → `_sret_struct_fields`
   (`src/extract/sret.jl:1224` → `:151`):
   ```
   ir_extract.jl: sret struct field 0 has type LLVM.PointerType(ptr) in @julia_f_2637;
   only fixed-width integer bits-struct fields are supported (... — Bennett-dv1z)
   ```
   because the closure call returns `sret({ ptr, ptr })`. So *both* the root and the
   closure body sit behind the same dv1z wall. **Bennett-40ys cannot end with "push!
   extracts"** — see §7 exit criteria.
2. **The silent-empty hazard.** Probe 9: with a wrong-but-plausible kwarg combo
   (`mem=:vm, ptr_cells=true, on_extract_error=:skip`) the *working* Dict corpus
   returns `n=0` — an empty `Vector{Pair{Symbol,ParsedIR}}`, no error. A closed-world
   set that lost its entry routine is not a closed world. Rule-1 gap; see D5.

---

## 2. Research step (explicit) — how to get IR from a signature alone

**Question:** obtain `code_llvm`-equivalent LLVM IR text for `Tuple{ClosureType}` given
only the TYPE.

### 2.1 What `code_llvm` actually does (read, not guessed)

`stdlib/v1.12/InteractiveUtils/src/codeview.jl`:

```julia
function _dump_function(@nospecialize(f), @nospecialize(t), native, wrapper, raw,
                        dump_module, syntax, optimize, debuginfo, binary,
                        params::CodegenParams=...)
    ...
    if !isa(f, Core.OpaqueClosure)
        world = Base.get_world_counter()
        match = Base._which(signature_type(f, t); world)     # ← f used ONLY here
        mi = Base.specialize_method(match)
        ...
    end
    src = Base.Compiler.typeinf_code(Base.Compiler.NativeInterpreter(world), mi, true)
    str = _dump_function_llvm(mi, src, wrapper, !raw, dump_module, optimize, debuginfo, params)
```

`f` reaches codegen **only** through `signature_type(f, t) == Tuple{typeof(f), t...}`.
That is precisely the `specTypes` the call-graph walker already holds
(`callgraph.jl:73-74`, `mi.specTypes`). Therefore the instance is structurally
unnecessary, not merely avoidable.

### 2.2 Chosen mechanism

```julia
world = Base.get_world_counter()                                   # per call, NEVER cached
match = Base._which(sig; world)                                    # sig::Type{<:Tuple}
mi    = Base.specialize_method(match)
src   = Base.Compiler.typeinf_code(Base.Compiler.NativeInterpreter(world), mi, true)
params = Base.CodegenParams(debug_info_kind=Cint(0), debug_info_level=Cint(2),
                            safepoint_on_entry=false, gcstack_arg=false)  # == code_llvm's raw=false
ir = InteractiveUtils._dump_function_llvm(mi, src, false, true, dump_module, optimize, :none, params)
```

Argument mapping to `code_llvm(...; debuginfo=:none, optimize, dump_module=true)`:
`wrapper=false`, `strip_ir_metadata = !raw = true`, `debuginfo=:none`
(`_dump_function` maps `:default → :source`; we pass `:none` directly, matching the
existing `extract_parsed_ir` call at `entry.jl:60`).

### 2.3 PROOF — real `_growend!` closure key, no instance anywhere

Probe 2 (`propA_probe2.jl`), key harvested via `Bennett._transitive_callee_specTypes`:

```
closure specTypes = Tuple{Base.var"#_growend!##0#_growend!##1"{Vector{Int64}, Int64,
                          Int64, Int64, Int64, Int64, Memory{Int64}, MemoryRef{Int64}}}
=== IR for the closure body (optimize=false, dump_module=true) ===
length(ir) = 28074
; Function Signature: (::Base.var"#_growend!##0#_growend!##1"{Array{Int64,1}, ...})()
define void @"julia_#_growend!##0_1531"(
    ptr noalias ... sret({ ptr, ptr }) align 8 dereferenceable(16) %sret_return,
    ptr noalias ... align 8 dereferenceable(8)  %return_roots,
    ptr nocapture ... readonly align 8 dereferenceable(72) %"#self#::#_growend!##0#_growend!##1",
    ptr nocapture readonly %".roots.#self#") #0 {
```

28 kB of real IR for the exact key that crashes today. No instance was constructed.

### 2.4 Equivalence to today's path

Probe 7: for `f` (the push! fixture) the signature path and
`code_llvm(...; optimize=false, dump_module=true)` produce **238 lines vs 238 lines,
9 differing lines**, and every difference is a per-emission counter:

```
L6 A: @"jl_global#121" = private unnamed_addr constant ptr @"jl_global#121.jit"
L6 B: @"jl_global#154" = private unnamed_addr constant ptr @"jl_global#154.jit"
L30 A:   %"jl_global#121" = load ptr, ptr @"jl_global#121", align 8
L30 B:   %"jl_global#154" = load ptr, ptr @"jl_global#154", align 8
```
(the embedded JIT addresses `inttoptr (i64 124270274319472 …)` are **identical**).
On a counter-normalised comparison the mechanism is exactly equal (`[g] … true`).
This is the same drift `julia_set.jl:12-19` and `_lookup_callee` already document —
nothing consumes the counter value.

### 2.5 Alternatives considered and REJECTED

| Alternative | Verdict |
|---|---|
| Forge an instance: `ccall(:jl_new_struct_uninit, Any, (Any,), CT)` then call `code_llvm` | Works in principle (only `typeof` is read) but *fabricates a GC-visible object with null `Vector`/`Memory` fields*. Any incidental `show`/`repr` on an error path touches undefined references. Rejected: forging a value to satisfy an API that never needed it. |
| `Base.code_typed_by_type` / `Base.code_ircode_by_type` | Produce typed **Julia** IR, not LLVM IR. The extractor's input is LLVM IR text parsed by the LLVM.jl C API (`entry.jl:79-95`). Rejected. |
| LLVM.jl-native method→IR entry | Does not exist: LLVM.jl wraps the LLVM C API; `entry.jl:1` imports `InteractiveUtils.code_llvm` precisely because there is no such entry. |
| `GPUCompiler.jl` | New heavy dependency, different `CodegenParams`; would change IR shape and hence gate-count baselines (Rule 6). Rejected. |
| Bind call sites via the `"julia.fsig"` LLVM function attribute (probe 3 shows it carries the full closure signature) | Requires *string-parsing a Julia-rendered type* out of an LLVM attribute. Direct Rule 5 violation. Rejected. |

---

## 3. Design

Five changes. Only D4 touches a core file (`instructions.jl`) — the bead already
mandates 3+1 for that.

### D1 — Diagnostic floor: a TOTAL callee-key classifier (`julia_set.jl`)

Replace the two-arm `_callable_of_key` / `_nameof_of` pair with one classifier over
the **specTypes**, so the "which kind of key is this?" question is asked once:

```julia
"""
    _callee_key_kind(k::Type) -> Symbol

Classify a `transitive_callees` callee key. Total over `Type`; every other
input fails loud (Rule 1).

  :constructor  — `Type{T}` (e.g. `Type{BoundsError}`); callable is `T`.
  :singleton    — a `typeof(g)` with a `.instance` (the plain-function case).
  :instanceless — a concrete callable struct type with NO `.instance`:
                  a CLOSURE (`Base.var"#_growend!##0#_growend!##1"{…}`) or a
                  user callable struct. Has no value; only a signature.
"""
function _callee_key_kind(k)
    k isa Type || error("julia_set.jl: callee key $(k) (::$(typeof(k))) is not a Type — \
        transitive_callees keys are `typeof(g)` / `Type{T}` (callgraph.jl:41-45). Rule 1.")
    k <: Type              && return :constructor
    isdefined(k, :instance) && return :singleton
    (isconcretetype(k) && isstructtype(k)) && return :instanceless
    error("julia_set.jl: UNSUPPORTED callee key `$(k)` (::$(typeof(k))): not a \
        constructor `Type{T}`, not a singleton (`.instance` undefined), and not a \
        concrete callable struct. Reached from the closed-world registration/extraction \
        loop for the current root. Julia $(VERSION). Extend _callee_key_kind (Bennett-40ys).")
```

This is the Rule-1 requirement of the bead: the failing key's **type** and the
**registration context** are named; `UndefRefError` is structurally unreachable
because `.instance` is only read on the `:singleton` arm.

`_callable_of_key` survives **only** for the registration path (§D4) and gains an
explicit fail-loud third arm — it is no longer on the extraction path at all.

### D2 — The capability: signature-driven extraction (`entry.jl`)

Refactor `extract_parsed_ir` (`entry.jl:53-103`) by **factoring its tail** (lines
62-102 — passes, memssa, LLVM context, `_module_to_parsed_ir`, memssa stamp) into

```julia
_parsed_ir_from_ir_string(ir_string::AbstractString; preprocess, passes,
                          use_memory_ssa, mem, ptr_cells) -> ParsedIR
```

and adding, alongside the existing entry (which keeps its `code_llvm` call **verbatim**
— zero blast radius on the gate-count baselines, Rule 6):

```julia
"""
    _llvm_ir_string_by_signature(sig::Type{<:Tuple}; optimize=true, dump_module=true) -> String

Emit LLVM IR text for a FULL specTypes signature `Tuple{K, A...}` — the same code
path `InteractiveUtils.code_llvm` takes internally, minus the callable. Needed
because a closure / callable-struct callee key discovered by `transitive_callees`
has NO instance to hand `code_llvm` (Bennett-40ys).
"""
function _llvm_ir_string_by_signature(@nospecialize(sig::Type); optimize::Bool=true,
                                      dump_module::Bool=true)::String

"""
    extract_parsed_ir_by_signature(sig::Type{<:Tuple}; optimize=true, preprocess=false,
        passes=String[], use_memory_ssa=false, mem=:auto, ptr_cells=false) -> ParsedIR
"""
function extract_parsed_ir_by_signature(@nospecialize(sig::Type); kw...)::ParsedIR
```

Fail-loud obligations inside `_llvm_ir_string_by_signature` (all Rule 1):

* `sig <: Tuple` and `sig isa DataType` — else `ArgumentError` naming `sig`.
* `Base._which` throws `"no unique matching method found"` on an abstract /
  ambiguous signature (probe 4, hit accidentally via a world-age slip) — catch and
  rethrow with the signature and `VERSION` in the message.
* `src isa Core.CodeInfo` — else `error("inference produced no CodeInfo for $mi")`
  (mirrors `codeview.jl`'s own check).
* **Reflection-ABI capability assertion** (Rule 5/9), evaluated at first use:
  ```julia
  isdefined(InteractiveUtils, :_dump_function_llvm) &&
  hasmethod(InteractiveUtils._dump_function_llvm,
            Tuple{Core.MethodInstance, Core.CodeInfo, Bool, Bool, Bool, Bool, Symbol, Base.CodegenParams}) &&
  isdefined(Base, :_which) && isdefined(Base, :specialize_method) || error(
      "entry.jl: this Julia ($(VERSION)) does not expose the reflection internals \
       signature-driven IR emission needs (…); Julia introspection internals are not a \
       stable API (Rule 5) — update _llvm_ir_string_by_signature.")
  ```
* **World age**: `Base.get_world_counter()` is read *inside* the function on every
  call. Caching it in a `const` silently mis-resolves anything defined later
  (probe 4 reproduced exactly this as a `"no unique matching method found"`).

`entry_function` selection is left at `nothing`, i.e. `_find_entry_function`'s
"first `julia_*` with a body" rule (`module_walk.jl:9-18`) — identical to
`extract_parsed_ir` today, and correct here: probe 2/5 show the requested method is
emitted first in its own module (`julia_#_growend!##0_1531` at line 26, before
`jfptr_*` and before any co-emitted callee).

### D3 — Naming: one rule, three arms (`julia_set.jl`)

**Rule: the set barename is the name Julia's codegen mangles into the LLVM symbol.**

```julia
_callee_barename(st::DataType) -> Symbol   # st is the FULL Tuple{K, A...}
  :constructor  → nameof(k.parameters[1])            # UNCHANGED (line 104)
  :singleton    → nameof(k.instance)                 # UNCHANGED (line 105)
  :instanceless → Base._which(st; world).method.name # NEW
```

Evidence that the third arm satisfies the rule (probes 4 and 8):

| key | `method.name` | LLVM define | caller's declare |
|---|---|---|---|
| `typeof(g)` (singleton) | `:g` | `julia_g_1590` | — |
| `_growend!` closure | `Symbol("#_growend!##0")` | `julia_#_growend!##0_1531` | `j_#_growend!##0_98` |
| `Adder` (callable struct) | `:Adder` | `julia_Adder_564` | — |
| `#mk3##0#mk3##1{…}` | `Symbol("#mk3##0")` | `julia_#mk3##0_2936` | — |

Note `nameof(CT)` is **wrong** here: it returns the *type* name
`Symbol("#_growend!##0#_growend!##1")`, which no LLVM symbol ever carries. (This is
the same reason line 105 uses `nameof(k.instance)` and not `nameof(k)` —
`nameof(typeof(g)) == Symbol("#g")`, probe 4.) `CT.name.singletonname` (new in 1.12)
happens to agree with `method.name` on all four rows; it is used as a **cross-check
in a test**, never as the primary source (Rule 5 — one fewer version-gated field).

**The canonical key is unchanged in shape**: `Symbol(barename, "#", digest)` →
`#_growend!##0#a1b2c3d4`. The existing `rsplit(…, "#"; limit=2)` recovery
(`julia_set.jl:359`, comment "S1") *already* anticipates `#`-bearing closure
barenames. No change needed there.

**BVM `#`-tolerance — checked, and it lines up exactly** (`BennettVM.jl/src/ir/ingest_multi.jl:55-70`,
`ingest_body.jl:89`):

```
set key   #_growend!##0#a1b2c3d4  --_vm_funcname-->  strip 9-char digest  -> #_growend!##0 --'#'→'.'--> ._growend!..0
call site #_growend!##0           --_vm_dispatch_name------------------------------------- '#'→'.'--> ._growend!..0   ✔
```

Collision risk (flagged, not fixed): the `'#'→'.'` sanitisation is many-to-one, so
two barenames differing only in `#` vs `.` positions would alias. BVM already fails
loud on that (`ingest_multi.jl:139-145`, the `seen` map), and `nameof` can never
produce `.` (documented at `ingest_multi.jl:45-49`), so the residual risk is
closure-vs-closure only and is *detected*, not silent.

### D4 — Registry integration: a NAME-only callee registry

**The problem, stated precisely.** `register_callee!(f::Function)`
(`callees.jl:12-19`) stores `string(nameof(f)) → f`. We have no `f`. Consequences at
the *caller's* extraction:

* `_lookup_callee("j_#_growend!##0_98")` misses (`callees.jl:74-89`).
* Under `ptr_cells=true` the miss falls into the ADR-0020-D5 arm
  (`instructions.jl:3189-3311`) and emits
  `IRCall(dest, Symbol("j_#_growend!##0_98"), cells…, 64)` — a **mangled** callee.
* BVM's `_vm_dispatch_name` does **no** demangling (`ingest_body.jl:89`), so
  `j_#_growend!##0_98 → j_._growend!..0_98` never matches the table's
  `._growend!..0`; the call degrades to `SoftCall` and dies at the allowlist.
* Under `ptr_cells=false` the miss reaches the Bennett-5oyt/U15 fail-loud — correct,
  because gate-level inlining genuinely needs a re-extractable callable.

**Fix (additive, one hook).** In `callees.jl`:

```julia
# Bennett-40ys: callees we know by NAME but not by VALUE (instance-less callables:
# closures, callable structs). `_known_callees` cannot hold them — it is
# Dict{String,Function} and there is no Function. Value is the CANONICAL callee
# Symbol the closed-world set is keyed by, so the emitted IRCall carries a bare,
# drift-free name instead of the mangled `j_<name>_<NNN>` (which BVM cannot link).
const _known_callee_names = Dict{String, Symbol}()          # guarded by _known_callees_lock
register_callee_name!(llvm_bare::AbstractString, canonical::Symbol) -> Nothing
_lookup_callee_name(llvm_name::String) -> Union{Symbol, Nothing}
```

`_lookup_callee_name` mirrors `_lookup_callee`'s exact-then-demangle shape but
**does not lowercase** (see R6: lowercasing is a live latent bug in `_lookup_callee`).

In `instructions.jl`, immediately after the `_lookup_callee` block ends (line 3169-3170),
one new block:

```julia
if ptr_cells && n_ops >= 1
    cn = _lookup_callee_name(cname)
    cn === nothing || return _emit_cell_call(inst, ops, n_ops, names, cn)   # Bennett-40ys
end
```

where `_emit_cell_call(inst, ops, n_ops, names, callee::Union{Function,Symbol})` is
the **hoisted** body of the existing xrd6 arm (`instructions.jl:3100-3149`: sret-pointee
validation via `_sret_struct_fields`, `_cell_call_args`, the void/ptr→64 ret-width
sentinel), now shared by all three call-emission arms (Rule 12 — no duplicated lowering).
Hoisting is behaviour-preserving and is itself covered by the existing xrd6 tests.

`ptr_cells=false` deliberately gets **no** hook: an instance-less callee cannot be
gate-inlined (`lower_call!` re-extracts the callee body from a `Function`,
`src/lowering/call.jl:82`). It falls through to U15 — but the U15 message gains one
clause when `_lookup_callee_name` *would* have hit:
`"… callee '<name>' is a registered INSTANCE-LESS callee (closure/callable struct);
these are modelled only under ptr_cells=true (the VM cell ABI), not on the
gate-inlining circuit path (Bennett-40ys)."`

In `julia_set.jl`, the registration loop (lines 316-322) becomes kind-dispatched, and
the `finally` restore (lines 371-379) is extended with a symmetric scoped restore of
`_known_callee_names` (same snapshot/scoped-delete discipline — comment S2).

### D5 — Close the silent-empty hole (Rule 1)

In `extract_parsed_ir_set_from_julia`, after root extraction (line 337-343):

```julia
if include_root && root_pir === nothing
    error("julia_set.jl: extract_parsed_ir_set_from_julia: the ROOT body `$(root_key)` \
        was SKIPPED (on_extract_error=:skip) — a closed-world set without its entry \
        routine is unusable. Underlying wall: $(sprint(showerror, <recorded root exception>)). \
        Re-run with on_extract_error=:fail_loud for the full context (Rule 1).")
end
```

Probe 9 shows the current behaviour is a silent `n=0`. Secondary blanket
`isempty(out)` guard: propose it, but the implementer **must** run the full suite
first — if any currently-green `:skip` call site returns empty, that is a discovered
latent hazard to be decided explicitly, not papered over (Rule 7).

---

## 4. Calling convention through the pipeline (probed, not guessed)

### 4.1 Caller side (probe 3, root `f` at `optimize=false`)

```
%"new::#_growend!##0#_growend!##1" = alloca [9 x i64], align 8       ; 72-byte captured state
%19 = getelementptr inbounds i8, ptr %"new::#_growend!##0#…", i32 8  ; …field stores/memcpys…
call void @"j_#_growend!##0_98"(ptr … sret({ ptr, ptr }) %sret_box,
                                ptr … %1,                            ; return_roots
                                ptr nocapture readonly %"new::#_growend!##0#…",   ; SELF, BY POINTER
                                ptr nocapture readonly %2)           ; .roots.#self#
declare void @"j_#_growend!##0_98"(ptr … sret({ ptr, ptr }), ptr …, ptr …, ptr …) #6
attributes #6 = { … "julia.fsig"="(::Base.var\"#_growend!##0#_growend!##1\"{…})()" … }
```

So: **the captured state is a caller-stack `alloca` passed BY POINTER** (not byval,
not decomposed into scalars), plus two GC-root pointers and an sret out-parameter.

### 4.2 Callee side — the existing walker already models a by-pointer struct arg

Probe 5, synthetic 3-field closure, full `ParsedIR` via the new mechanism, **no
instance handed to the extractor**:

```
define i64 @"julia_#mk3##0_2936"(ptr … dereferenceable(24) %"#self#::#mk3##0#mk3##1",
                                 i64 signext %"x::Int64")
ParsedIR OK: ret_width=64  args=[(#self#::#mk3##0#mk3##1, 192), (x::Int64, 64)]
  IRLoad(#self#….unbox,   SSAOperand(#self#…), 64)
  IRBinOp(__v1, :add, SSAOperand(x::Int64), SSAOperand(#self#….unbox), 64)
  IRPtrOffset(#self#….b_ptr, SSAOperand(#self#…), 8, 8)
  IRLoad(#self#….b_ptr.unbox, SSAOperand(#self#….b_ptr), 64)
  IRBinOp(__v2, :mul, …)
  IRPtrOffset(#self#….c_ptr, SSAOperand(#self#…), 16, 8)
  IRLoad(#self#….c_ptr.unbox, …)
  IRBinOp(__v3, :sub, …)
```

The captured state arrives as a **leading extra argument**, and the existing
`IRPtrOffset`/`IRLoad` machinery already decodes its fields. **Nothing new is needed
in `lower.jl` or the IR types for the closure calling convention per se.**

### 4.3 The real ABI gap — and why it is NOT this bead's

The callee declares arg 1 with width `8*sizeof(CT)` (192 above, 576 for `_growend!`),
derived from `dereferenceable(N)`; identical under `ptr_cells=false` and `true`
(probe 6). The caller under `ptr_cells=true` passes that same argument as **one
64-bit pointer cell** (`_cell_call_args`). BVM drops widths entirely
(`ingest_multi.jl:153`: `params = Symbol[n for (n,_w) in parsed.args]`) and binds
`CallEnter` args positionally by name, arity-checked (`call_frames.jl:174`).
So an aggregate-by-pointer argument is currently a **cell/arity mismatch at the call
boundary**.

Crucially, probe 6 shows this is **not closure-specific**: the exact same shape arises
for the ordinary singleton `@noinline apply_it(g::CT, x::Int64)`
(`call i64 @j_apply_it_3998(ptr … %"new::#mk3##0#mk3##1", i64 …)`). It is the
general "Julia function with a struct-typed argument" ABI. Fixing it inside
Bennett-40ys would (a) mix two independent capabilities in one bead and (b) require
a BVM-side ADR amendment. **Recommendation: file it as its own bead**
("closed-world cell ABI for by-pointer aggregate arguments — caller cell vs callee
aggregate width at `CallEnter`"), blocking `bennettvm-xkl` alongside the dv1z item.

**BVM impact of this proposal: none.** Name binding lines up exactly (§D3), and no
`IRCall`/`ParsedIR` shape changes.

---

## 5. Scope control — the minimal honest capability

Options weighed, per the bead's part-2 framing:

* **(a) General non-singleton-callable support.** Too broad if read as "any callee":
  `Core.OpaqueClosure` needs a *different* codegen path
  (`codeview.jl:214-223`: `get_oc_code_rt`, `f.world`, `typeof(f).parameters[1]`) and
  we have zero evidence it appears in this corpus. Building it would be speculative.
* **(c) Diagnostic-only now.** Rejected: it converts an opaque crash into a clear
  crash and leaves `bennettvm-xkl` (P0) exactly as blocked. The bead explicitly names
  the capability as part 2.
* **(b′) CHOSEN — one arm keyed on the general property "callable type with no
  `.instance`", plus a total classifier.** This is general in the *right* dimension:
  the mechanism (signature-driven emission) is indifferent to *why* there is no
  instance, and probe 8 confirms it already covers callable structs, not just
  closures. Everything outside the three recognised kinds — `OpaqueClosure`,
  non-concrete keys, non-`Type` keys — fails loud naming the kind and the bead.

The scope line is drawn where the *evidence* runs out, not where the code got hard:
we implement what a probe demonstrates on the real corpus, and fail loud elsewhere.

---

## 6. Test plan (RED-GREEN)

New file `test/test_40ys_instanceless_callees.jl`, registered in `test/runtests.jl`
next to the CW-D1b block (line ~415). Fixtures are locally named (`*_40ys`) per the
D1a generic-collision lesson (`test_d1b_julia_set.jl:31-34`).

| Gate | Assertion | RED today |
|---|---|---|
| **A** diagnostic floor | `_callee_key_kind` returns `:constructor` / `:singleton` / `:instanceless` on `Type{BoundsError}` / `typeof(g_40ys)` / the harvested `_growend!` closure type; `@test_throws` with a message naming the type on a non-`Type` input | `UndefRefError`, no classifier exists |
| **B** no opaque crash | `err = try extract_parsed_ir_set_from_julia(push_40ys, Tuple{Int64}; ptr_cells=true) catch e; sprint(showerror,e) end`; `@test !occursin("UndefRefError", err)`; `@test occursin("extraction FAILED", err)`; `@test occursin("#_growend!##0", err)`; `@test occursin("sret", err) \|\| occursin("dv1z", err)` | RED: message *is* `UndefRefError: access to undefined reference` |
| **C** IR emission from a signature | `ir = _llvm_ir_string_by_signature(ct_st)`; `@test occursin("julia_#_growend!##0", ir)`; `@test occursin("dereferenceable(72)", ir)` — the real `_growend!` key, **no instance** | RED: function does not exist |
| **D** end-to-end ParsedIR, instance-less | synthetic `mk3_40ys` closure: `CT = typeof(mk3_40ys(3,4,5))`; extract via `extract_parsed_ir_by_signature(Tuple{CT,Int64})` — passing **only the type**; assert `ret_width == 64`, `length(args) == 2`, first arg width `== 8*sizeof(CT)`, and that `IRPtrOffset`+`IRLoad` decode fields 2 and 3 | RED |
| **E** callable struct (generality) | same as D on `struct Adder_40ys` — proves the arm is not closure-special-cased | RED |
| **F** equivalence to `code_llvm` | for two ordinary singletons, `extract_parsed_ir_by_signature(Base.signature_type(f,tt))` and `extract_parsed_ir(f, tt)` agree on a structural fingerprint (`ret_width`, `args`, block labels, per-block instruction type vectors) | GREEN-by-construction guard against drift |
| **G** naming rule | `_callee_barename(ct_st) === Symbol("#_growend!##0")`; cross-check `== getfield(CT.name, :singletonname)` when that field exists; canonical key matches `r"#[0-9a-f]{8}$"`; `rsplit(key,"#";limit=2)[1] == "#_growend!##0"` | RED |
| **H** call-site binding | extract the *caller* whose closure call resolves, assert the emitted `IRCall.callee === Symbol("#_growend!##0")` (bare, not mangled) after `register_callee_name!` — exercised on the synthetic `Adder_40ys`/closure fixture that clears the dv1z wall, not on `push!` | RED |
| **I** registry hygiene | `_known_callee_names` is empty before and after a full `extract_parsed_ir_set_from_julia` call (scoped restore, mirroring S2), including on the throwing path | RED |
| **J** root-skip guard (D5) | `on_extract_error=:skip` on the push! root fails loud naming the root key instead of returning `Pair[]` | RED: returns `[]` (probe 9) |

BVM-side: **no new tests required**. Add one *cross-repo* assertion in the existing
BVM naming test that `_vm_funcname(Symbol("#_growend!##0#a1b2c3d4"))` and
`_vm_dispatch_name(Symbol("#_growend!##0"))` are equal — pinning the linkage that
§D3 relies on so a future sanitisation change breaks loudly on the BVM side.

Regression obligations: full `Pkg.test()` (Rule 8/6). The gate-count baselines must
be untouched — `extract_parsed_ir` keeps its `code_llvm` call verbatim; only its tail
is factored, and `_emit_cell_call` is a pure hoist.

### Exit criterion of THIS bead vs what remains for `bennettvm-xkl`

**Bennett-40ys is DONE when:** (1) no callee-key shape can produce an opaque
`UndefRefError` — every unsupported key names its type, its kind and the bead;
(2) an instance-less callee key's LLVM IR and `ParsedIR` are obtainable from the
signature alone, demonstrated end-to-end on synthetic closures *and* callable structs
and at the IR level on the real `_growend!` key; (3) the push! closed-world set
reaches the **next honest wall** (dv1z sret-of-pointer) with a message naming the
canonical key; (4) call-site → set-key name binding is bare and BVM-compatible.

**Remains for `xkl` (file as separate beads):**
1. dv1z: `sret({ptr,ptr})` — pointer fields as 64-bit cells under `ptr_cells`, at
   *both* `_detect_sret` (`sret.jl:107-111`) and the 416r.16 consumed-sret
   reconciler (`sret.jl:1224`). Blocks the root *and* the closure body.
2. By-pointer aggregate **argument** ABI at `CallEnter` (§4.3).
3. GC-root parameters (`return_roots`, `.roots.#self#`) — model or drop, decided
   with evidence.
4. Walls *inside* the closure body (`jl_genericmemory_copy_slice` &c., per the bead).

---

## 7. Risk register

| # | Risk | Assessment / mitigation |
|---|---|---|
| **R1** | `Base._which` / `Base.specialize_method` / `InteractiveUtils._dump_function_llvm` are internals (Rule 5) | They are the *same* internals `code_llvm` itself calls, so they cannot drift independently of `code_llvm`, which the project already depends on (`entry.jl:1`). Mitigated by the load-/first-use capability assertion naming `VERSION` (§D2). |
| **R2** | `Base.var"#_growend!##0#_growend!##1"` naming is Julia-version-specific | **We never match on it.** The design keys on `method.name`, derived at runtime from the harvested signature. A future Julia that renames or re-inlines the helper changes *which* keys appear, not whether the mechanism works. No test asserts the literal Base name except gate B/C, which are explicitly marked version-observational and assert `occursin("#_growend!##0", …)` only as evidence the *real* corpus is exercised. |
| **R3** | optimize=true (edges) vs optimize=false (bodies) skew | Unchanged from today's contract (`callgraph.jl:48-54`: edges must be harvested at O2 or there are *zero* `:invoke`s; bodies at O0 for predictable IR). The new path passes `optimize` through identically. One consequence to keep in view: an edge that exists only at O2 may correspond to a body whose O0 form differs — this is pre-existing and is what `_closed_world_check!` exists to catch. |
| **R4** | `argtypes = Tuple{}` (everything rides in the closure struct) | Harmless and in fact *simplifying*: `_argtype_digest(Tuple{})` is a normal 8-hex digest, and the specTypes carries the full closure type so distinct captures produce distinct keys. It does mean `argtypes` is no longer a useful discriminator — which is exactly why the design switches to specTypes as the unit of currency. |
| **R5** | Global registry pollution across compiles | `_known_callee_names` gets the *same* snapshot/scoped-restore discipline as `_known_callees` (S2, `julia_set.jl:308-312, 365-379`), asserted by gate I including on the throwing path. |
| **R6** | **Pre-existing latent bug** — `_lookup_callee` lowercases (`callees.jl:81-85`) while the registry key preserves case | Probe 8: `register_callee!(UPPER); _lookup_callee("julia_UPPER_12") → nothing`. Invisible today because every registered callee is lowercase; it *would* bite `Adder`-style callable structs. `_lookup_callee_name` (new) is case-preserving. **Do not** change `_lookup_callee` in this bead — file a separate bead; changing it could alter which callees resolve on the circuit path (gate counts, Rule 6). |
| **R7** | `_find_entry_function`'s "first `julia_*`" heuristic on a closure module | Probe 2/5: the requested method is emitted first (line 26 of 555; `jfptr_*` and co-emitted callees follow). Same rule the existing entry already relies on. If it ever fails it fails *loud* (`ArgumentError`), never silently on the wrong function. |
| **R8** | Precompile / codegen cache interaction | `_dump_function_llvm` re-runs codegen per call (probe 7: the two emissions differ only in fresh `jl_global#N` counters, identical JIT addresses) — no cache is consulted or poisoned. `_parsed_ir_cache` (`callees.jl:37`) is `Function`-keyed and is **not** reachable from the signature path; `julia_set.jl` already bypasses it (docstring, line 217-219). If a future bead wants caching here, key it on `specTypes`, not on a callable. |
| **R9** | World-age | `get_world_counter()` must be read per call, never cached (probe 4 reproduced the failure mode). Enforced by construction and worth a comment at the call site. |
| **R10** | D5's guard trips an existing green `:skip` test | Scoped narrowly to "root was skipped". Implementer must run the full suite before landing; a trip is a *discovered* latent hazard (Rule 7), to be decided explicitly. |

---

## 8. Files touched (implementer's map)

| File | Change | Core? |
|---|---|---|
| `src/extract/entry.jl` | factor `_parsed_ir_from_ir_string`; add `_llvm_ir_string_by_signature`, `extract_parsed_ir_by_signature`, capability assertion | yes (extraction entry) |
| `src/extract/julia_set.jl` | `_callee_key_kind`, `_callee_barename(st)`, specTypes-driven `_extract_one`, kind-dispatched registration + scoped restore, D5 root guard | yes |
| `src/extract/callees.jl` | `_known_callee_names`, `register_callee_name!`, `_lookup_callee_name` | yes |
| `src/extract/instructions.jl` | hoist `_emit_cell_call` out of the xrd6 arm; one `ptr_cells`-gated name-registry hook; one U15 message clause | **yes — 3+1 mandated** |
| `src/extract/callgraph.jl` | *optional*: expose the ordered specTypes (`transitive_callee_spectypes`) so `julia_set` need not re-assemble `Tuple{K, A...}`; `transitive_callees` stays for back-compat | yes |
| `src/Bennett.jl` | export/`using` the new entry if it is to be user-facing | no |
| `test/test_40ys_instanceless_callees.jl` (new), `test/runtests.jl` | gates A–J | — |
| BennettVM.jl | **no source change**; one cross-repo naming assertion in the existing test | — |

---

## 9. Probe index (scratchpad, `…/scratchpad/`)

| File | What it establishes |
|---|---|
| `propA_probe1.jl` | Crash reproduction; the six harvested keys; singleton vs no-instance classification |
| `propA_probe2.jl` | **The mechanism works on the real `_growend!` key** (28 kB IR, correct signature); singleton cross-check vs `code_llvm` |
| `propA_probe3.jl` | Caller-side calling convention (alloca + by-pointer self + sret + roots); closure body walls at dv1z under both `ptr_cells` settings |
| `propA_probe4.jl` | `method.name` vs `nameof(CT)` vs `singletonname`; root also walls at dv1z; world-age gotcha |
| `propA_probe5.jl` | **End-to-end `ParsedIR` from a type alone** (1-field and 3-field synthetic closures) |
| `propA_probe6.jl` | Callee arg width 192 under both gates; caller passes one pointer → the ABI gap; the gap is not closure-specific |
| `propA_probe7.jl` | Line-by-line diff: signature path ≡ `code_llvm` modulo per-emission counters |
| `propA_probe8.jl` | Callable structs behave identically (generality); `_lookup_callee` case-folding bug (R6) |
| `propA_probe9.jl` | Silent empty-set hazard (D5) |
| `propA_closure_body_O0.ll`, `propA_root_O0.ll` | Saved IR for the real `_growend!` closure body and the push! root |
