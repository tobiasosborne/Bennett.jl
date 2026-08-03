# Bennett-40ys — Design Proposal B

**Proposer B (independent). Written blind to proposal A.**
Bead: `Bennett-40ys` (P1) — closed-world extraction crashes with `UndefRefError`
on any function containing `push!`.
Downstream goal: `bennettvm-xkl` (P0) — `push!`-built `Vector` through the
closed-world route → BennettVM → run → reverse.

Environment for every probe below: Julia **1.12.3**, `--project` at repo root,
`main` @ `2d2a81e`. All probe scripts are under
`/tmp/claude-1000/-home-tobiasosborne-Projects-Bennett-jl/…/scratchpad/propB_*.jl`.

---

## 0. Ground truth — verified independently (CLAUDE.md Rule 10)

I did not take the scout's diagnosis on trust. Probe `propB_probe1.jl`:

```
=== transitive_callees(pushw, Tuple{Int64}) ===   # pushw(n) = (v=Int64[]; push!(v,n); v[1])
  1  key = typeof(Base.throw_boundserror)   at=Tuple{Vector{Int64}, Tuple{Int64}}  singleton=true  hasinstance=true
  2  key = Type{BoundsError}                at=Tuple{Any, Tuple{Int64}}
  3  key = Base.var"#_growend!##0#_growend!##1"{Vector{Int64},Int64,Int64,Int64,Int64,Int64,Memory{Int64},MemoryRef{Int64}}
         at = Tuple{}      isType=false  nfields=8  singleton=false  hasinstance=FALSE
         field 1: a::Vector{Int64}      field 2: newmemlen::Int64   field 3: offset::Int64
         field 4: newlen::Int64         field 5: len::Int64         field 6: memlen::Int64
         field 7: mem::Memory{Int64}    field 8: ref::MemoryRef{Int64}
  4  key = Type{ConcurrencyViolationError} …
  5  key = typeof(Core.throw_inexacterror) …
  6  key = Type{InexactError} …

=== _callable_of_key behaviour ===
  OK   typeof(Base.throw_boundserror) -> throw_boundserror
  OK   Type{BoundsError}              -> BoundsError
  FAIL UndefRefError  on key=Base.var"#_growend!##0#_growend!##1"{…}
  …
=== full pipeline attempt (on_extract_error=:skip) ===
  UndefRefError: access to undefined reference
```

Confirmed exactly as diagnosed:

* `src/extract/julia_set.jl:100` — `_callable_of_key(k::Type) = k.instance` — the
  key is a **non-singleton** `DataType` with 8 fields, so `.instance` is undefined.
* The crash is in the **registration loop** (`julia_set.jl:316-322`), *outside*
  `_extract_one`'s `try/catch` (`julia_set.jl:280-296`), so
  `on_extract_error=:skip` cannot rescue it. Verified: `:skip` still `UndefRefError`s.
* `src/extract/callgraph.jl:66-78` `_invoke_callees` harvests `:invoke` edges at
  `optimize=true`; the Dict corpus never hit this because its helpers allocate
  inline via `:foreigncall` (`jl_alloc_genericmemory_unchecked`), which the
  `:invoke`-only walker deliberately drops (`callgraph.jl:56-65`).

**One correction to the framing.** `_growend!` itself is *not* in the callee set —
it is fully inlined into the root. Only the **outlined slow-path closure** appears
as an `:invoke`. So the caller of the closure is the **root body itself**, not a
separate `_growend!` body. This matters for §4.

---

## 1. Design overview

Three layers, in dependency order. Layers 1+2+3 together are this bead; layer 0
is the pre-existing surface that must not change.

| Layer | What | Where | Rule |
|---|---|---|---|
| **L1** | Callee-key **classifier** + fail-loud diagnostic | `julia_set.jl` | Rule 1 |
| **L2** | **By-signature LLVM IR extraction** (no instance) | new `src/extract/sig_llvm.jl` + `entry.jl` | Rule 9 (research) |
| **L3** | **Naming** from `MethodInstance`, not from the type | `julia_set.jl` | Rule 5 |

The organising idea: **a callee key's only job is to produce codegen input.**
Today `julia_set.jl` does that by recovering a *callable value* (`.instance`) and
handing it to `extract_parsed_ir(f, T)`. That is a *value*-shaped interface, and
it is exactly the wrong dimension — Julia's own codegen works from a
**signature**, and `transitive_callees` already hands us one. The general fix is
to move `julia_set.jl` from the value interface to the signature interface. That
generalises over *every* non-singleton callable (closures **and** functors, §5),
not just closures, and it needs no new special case per callable kind.

---

## 2. L1 — Diagnostic floor (Rule 1)

Never let a bare `UndefRefError` escape. Replace the two-arm helpers at
`julia_set.jl:99-105` with one **classifier** that all downstream helpers share,
so naming / extraction / diagnostics can never disagree:

```julia
# src/extract/julia_set.jl
"""
    _classify_callee_key(k) -> Symbol

Classify a `transitive_callees` key into the shape that determines how its LLVM
IR is obtained. Exactly one of:
  * `:constructor` — `Type{T}` (e.g. `Type{BoundsError}`); callable is `T`.
  * `:singleton`   — `typeof(g)` for a plain function `g`; callable is `g`.
  * `:noninstance` — a callable DataType with FIELDS (closure / functor). There
                     is NO instance; codegen must be driven by signature.
Fails loud on anything else (Rule 1).
"""
function _classify_callee_key(@nospecialize k)
    k isa Type || _callee_key_error(k, "not a Type")
    k <: Type && return :constructor
    isdefined(k, :instance) && return :singleton
    isconcretetype(k) || _callee_key_error(k, "abstract / non-concrete callee key")
    return :noninstance
end

_callee_key_error(@nospecialize(k), why) = error(
    "julia_set.jl: unsupported transitive_callees callee key `$(k)` " *
    "(typeof = $(typeof(k)), $(why)). Registration loop " *
    "(extract_parsed_ir_set_from_julia); the typed call graph produced a key " *
    "this producer cannot turn into codegen input. Rule 1: no silent skip.")
```

`_classify_callee_key` returning `:noninstance` is what today crashes. After L2/L3
it is a supported arm; if a *fourth* shape ever appears (a future Julia
introspection change), `_callee_key_error` names the key, its `typeof`, and the
registration context — never `UndefRefError`.

**RED today**: `_callable_of_key(K)` throws `UndefRefError`. **GREEN**: the
classifier returns `:noninstance`, and a synthetic bad key (`_classify_callee_key(3)`)
throws an `ErrorException` whose message contains the key and `"julia_set.jl"`.

---

## 3. L2 — By-signature IR extraction *(the crux — RESEARCH STEP, probe-proven)*

### 3.1 What `extract_parsed_ir` actually needs

`src/extract/entry.jl:60`:

```julia
ir_string = sprint(io -> code_llvm(io, f, arg_types; debuginfo=:none, optimize, dump_module=true))
```

Everything after line 60 (lines 62-102) operates on the **IR string** — pass
pipeline, `parse(LLVM.Module, ir_string)`, `_module_to_parsed_ir`. So the *only*
thing that needs a callable value is line 60. Replace that one line's source and
the entire rest of the pipeline is untouched. No LLVM-C-API change; no regex;
Rule 5 respected (we still hand LLVM.jl a module to walk).

### 3.2 The mechanism

I read `InteractiveUtils/src/codeview.jl` (Julia 1.12.3) rather than guessing.
`_dump_function` (codeview.jl:193-259) is:

```julia
world = Base.get_world_counter()
match = Base._which(signature_type(f, t); world)      # ← the ONLY use of `f`
mi    = Base.specialize_method(match)
isdispatchtuple(mi.specTypes) || (warning = GENERIC_SIG_WARNING)   # codeview.jl:208
src   = Base.Compiler.typeinf_code(Base.Compiler.NativeInterpreter(world), mi, true)
src isa Core.CodeInfo || error("failed to infer source for $mi")
str   = _dump_function_llvm(mi, src, wrapper, !raw, dump_module, optimize, debuginfo, params)
return warning * str
```

`f` is consumed **only** by `signature_type(f, t)` = `Tuple{Core.Typeof(f), t...}`.
`transitive_callees` already gives us that tuple, split in two by
`callgraph.jl:45` `_split_spectypes`. The split is exactly invertible:
`Tuple{k, at.parameters...}` (probe-verified on all six keys, including the
`Vararg` one, `Type{InexactError}` / `Tuple{Symbol,Any,Vararg{Any}}`).

So: **reassemble the signature and skip `signature_type` entirely.** No instance
required. Proposed new file, `src/extract/sig_llvm.jl` (~90 LOC, purely additive):

```julia
# src/extract/sig_llvm.jl
#
# CLAUDE.md Rule 9/10: `Base._which`, `Base.specialize_method`,
# `Base.Compiler.typeinf_code` and `InteractiveUtils._dump_function_llvm` are
# Julia INTROSPECTION INTERNALS, not a stable API. They are the exact call
# sequence `InteractiveUtils._dump_function` (codeview.jl:193-259, Julia 1.12.3)
# uses; this file reproduces it MINUS the `signature_type(f, t)` step, which is
# the only place a callable VALUE is needed. Probe-proven byte-identical output
# (modulo Julia's per-emission `_NNN` / `#NNN` counters) — see
# docs/design/40ys/proposal_B.md §3.3. Same precedent as callgraph.jl, which
# already depends on `Core.CodeInstance` / `:invoke` internals.

const _SIG_LLVM_CAPABILITIES = (
    (Base, :_which), (Base, :specialize_method), (Base, :CodegenParams),
    (Base, :Compiler), (InteractiveUtils, :_dump_function_llvm),
)

function _assert_sig_llvm_supported()
    for (m, s) in _SIG_LLVM_CAPABILITIES
        isdefined(m, s) || error(
            "sig_llvm.jl: Julia $(VERSION) does not define `$(m).$(s)` — the " *
            "by-signature LLVM IR path reproduces InteractiveUtils._dump_function " *
            "(codeview.jl) and must be re-derived for this Julia. Rule 5/9: Julia " *
            "introspection internals are not a stable API (Bennett-40ys).")
    end
    (isdefined(Base.Compiler, :typeinf_code) &&
     isdefined(Base.Compiler, :NativeInterpreter)) || error(
        "sig_llvm.jl: Base.Compiler.{typeinf_code,NativeInterpreter} missing on " *
        "Julia $(VERSION) (Bennett-40ys; Rule 5/9).")
    return nothing
end

"""
    _code_llvm_by_sig(sig::Type{<:Tuple}; optimize=false, raw=false,
                      dump_module=true, debuginfo=:none) -> String

The LLVM IR text for the method matching the FULL signature tuple `sig`
(`Tuple{callee_key, argtypes...}`) — the `code_llvm(io, f, t; …)` output for a
callee whose instance cannot be constructed (a closure or a functor).

Mirrors `InteractiveUtils._dump_function(f, t, false, false, raw, dump_module,
:intel, optimize, debuginfo, false, params)` EXCEPT that the MethodInstance is
resolved from `sig` directly rather than from `signature_type(f, t)`.
The `GENERIC_SIG_WARNING` comment line is reproduced verbatim (NOT upgraded to a
fail-loud — see proposal_B.md §3.4: `Core.throw_inexacterror` is a real,
currently-working, non-dispatch-tuple callee).
"""
function _code_llvm_by_sig(sig::Type{<:Tuple}; optimize::Bool=false, raw::Bool=false,
                           dump_module::Bool=true, debuginfo::Symbol=:none)::String
    _assert_sig_llvm_supported()
    world = Base.get_world_counter()
    mm = try
        Base._which(sig; world)
    catch e
        e isa InterruptException && rethrow()
        error("sig_llvm.jl: _code_llvm_by_sig: no unique matching method for " *
              "signature `$(sig)` in world $(world) — $(sprint(showerror, e)). " *
              "The typed call graph produced a signature inference cannot " *
              "re-resolve (Rule 1; Bennett-40ys).")
    end
    mi = Base.specialize_method(mm)
    warning = Base.isdispatchtuple(mi.specTypes) ? "" :
              "; WARNING: This code may not match what actually runs.\n"
    src = Base.Compiler.typeinf_code(Base.Compiler.NativeInterpreter(world), mi, true)
    src isa Core.CodeInfo || error(
        "sig_llvm.jl: _code_llvm_by_sig: inference returned $(typeof(src)) (not a " *
        "Core.CodeInfo) for $(mi) — cannot emit LLVM IR (Rule 1; Bennett-40ys).")
    params = Base.CodegenParams(debug_info_kind=Cint(0), debug_info_level=Cint(2),
                                safepoint_on_entry=raw, gcstack_arg=raw)
    return warning * InteractiveUtils._dump_function_llvm(
        mi, src, false, !raw, dump_module, optimize, debuginfo, params)
end

"""
    _method_instance_of_sig(sig::Type{<:Tuple}) -> Core.MethodInstance
"""
function _method_instance_of_sig(sig::Type{<:Tuple})::Core.MethodInstance
    _assert_sig_llvm_supported()
    return Base.specialize_method(Base._which(sig; world=Base.get_world_counter()))
end

# Invert callgraph.jl:45 `_split_spectypes`.
_spectypes_of(@nospecialize(k), at::Type{<:Tuple}) = Tuple{k, at.parameters...}
```

### 3.3 PROOF that the mechanism is the same codegen path

The strongest available evidence: take a case where an instance **does** exist,
and compare the two routes. Probe `propB_probe6.jl` §(A), on a **user closure**
`mkcl(v,n) = () -> v[1]+n`:

```
typeof(cl)              = var"#mkcl##0#mkcl##1"{Vector{Int64}, Int64}
isdefined(K1,:instance) = false                     ← a real non-singleton
code_llvm len=6034   by_sig len=6034
EXACT equal            : false
equal after _NNN norm  : TRUE                       ← identical modulo mangling drift
```

The only textual differences are Julia's per-emission `_NNN` / `#NNN` counters —
i.e. exactly the drift `julia_set.jl:12-19` and `callees.jl:79-88` already model as
non-stable (Rule 5). Repeated for the **non-dispatch-tuple** signature
`Tuple{typeof(Core.throw_inexacterror), Symbol, Type, Int64}`
(probe `propB_probe9.jl`): 78 lines each, 4 differing lines, **all four** of the
form `@"+Core.InexactError#115"` vs `@"+Core.InexactError#88"` — the same counter
class. Structurally identical.

And on the real target (probe `propB_probe3.jl`), by-sig on
`Tuple{Base.var"#_growend!##0#_growend!##1"{…}}` yields a complete module:

```
define void @"julia_#_growend!##0_322"(
    ptr noalias nocapture noundef nonnull sret({ ptr, ptr }) align 8 dereferenceable(16) %sret_return,
    ptr noalias nocapture noundef nonnull align 8 dereferenceable(8) %return_roots,
    ptr nocapture noundef nonnull readonly align 8 dereferenceable(72) %"#self#::#_growend!##0#_growend!##1",
    ptr nocapture readonly %".roots.#self#") #0 {
```

…plus the full `declare` set (`jl_alloc_genericmemory_unchecked`,
`llvm.julia.gc_preserve_begin`, `llvm.memmove`, …) that `dump_module=true`
requires. **The capability is proven.**

### 3.4 Mechanisms considered and REJECTED

| Candidate | Verdict |
|---|---|
| `InteractiveUtils.code_llvm(io, f, t)` with a fabricated instance (`jl_new_struct_uninit`) | **Reject.** Requires an instance (fails the requirement) and the closure holds live `Vector`/`Memory`/`MemoryRef` refs — an uninitialised struct is a GC crash waiting to happen. |
| `Base.code_ircode_by_type` / `Base.code_typed_by_type` | **Reject.** Typed IR, not LLVM IR. `ir_extract.jl` walks an `LLVM.Module`. |
| A generic trampoline `_call_it(c) = c(); code_llvm(_call_it, Tuple{K})` | **Reject.** At `optimize=false` (mandated by Rule 5 for predictable IR) the callee is *not* inlined — you get the trampoline's `invoke`, not the body. |
| Direct `@ccall jl_get_llvmf_defn(...)` | **Reject as primary.** Bypasses one Julia-side wrapper but adds a dependency on the `LLVMFDump` struct layout + C ABI. Strictly more fragile. Keep as a documented emergency fallback only. |
| Upgrading the non-dispatch-tuple case to a fail-loud | **Reject — probe-disproven.** `propB_probe7.jl`: `Core.throw_inexacterror` with `Tuple{Symbol, Type, Int64}` is **not** a dispatch tuple (`Type` is abstract) yet extracts fine today (`nargs=3 nblk=3`). A fail-loud there would regress a working callee. Reproduce `GENERIC_SIG_WARNING` verbatim; `;` is an LLVM comment so `parse(LLVM.Module, …)` accepts it (probe-verified: `from_ll` OK). |

### 3.5 `entry.jl` surface

`entry.jl` is core pipeline → **CLAUDE.md Rule 2 (3+1) applies** (this document
is proposer B's half). The change is a pure extract-method refactor plus one new
entry point:

```julia
# src/extract/entry.jl  — split the existing body at line 60/62
function extract_parsed_ir(f, arg_types::Type{<:Tuple}; optimize=true, kwargs...)
    ir_string = sprint(io -> code_llvm(io, f, arg_types; debuginfo=:none, optimize, dump_module=true))
    return _parsed_ir_from_ir_string(ir_string; optimize=optimize, kwargs...)
end

"""
    extract_parsed_ir_by_sig(sig::Type{<:Tuple}; optimize=false, …) -> ParsedIR

`extract_parsed_ir` for a callee that cannot be named by a VALUE — a closure or
a functor whose type has fields, so `sig.parameters[1].instance` is undefined
(Bennett-40ys). `sig` is the FULL signature `Tuple{callee_key, argtypes...}`,
the un-split form of a `transitive_callees` pair. Every kwarg, pass-pipeline
step, and fail-loud is shared with `extract_parsed_ir` — only the IR SOURCE
differs (`_code_llvm_by_sig` instead of `code_llvm`).
"""
function extract_parsed_ir_by_sig(sig::Type{<:Tuple}; optimize::Bool=false, kwargs...)
    ir_string = _code_llvm_by_sig(sig; optimize=optimize, dump_module=true, debuginfo=:none)
    return _parsed_ir_from_ir_string(ir_string; optimize=optimize, kwargs...)
end
```

`_parsed_ir_from_ir_string` is `entry.jl:62-102` verbatim (memssa, sret
auto-SROA, `_run_passes!`, `_module_to_parsed_ir`, memssa stamp). Because the
tail is *shared*, the two entries cannot drift — the byte-identity in §3.3 then
carries all the way to `ParsedIR`.

`_find_entry_function(mod, nothing)` (`module_walk.jl:9-17`) picks the first
`julia_*` with a body. In the closure's own module the defines are exactly
`["julia_#_growend!##0_322", "jfptr_#_growend!##0_323"]` (probe `propB_probe4.jl`)
— the `jfptr_` wrapper does not start with `julia_`, so the existing heuristic
selects correctly. **No change needed.**

---

## 4. L3 — Naming, registry, and the call-site binding

### 4.1 `nameof(K)` is the WRONG name — use `mi.def.name`

This is the subtlest finding and the one most likely to be got wrong. Probe
`propB_probe4.jl`:

```
nameof(K)             = Symbol("#_growend!##0#_growend!##1")   ← the TYPE name
K.name.singletonname  = Symbol("#_growend!##0")
mi.def.name           = Symbol("#_growend!##0")                ← the METHOD name
LLVM define           = @"julia_#_growend!##0_322"             ← matches mi.def.name
```

Julia's codegen mangles from the **method** name, not the type name. A design
that reaches for `nameof(K)` produces `#_growend!##0#_growend!##1`, which matches
**nothing** in the LLVM module, and `_closed_world_check!` (`julia_set.jl:150-202`)
would then report a spurious closed-world violation. Use `mi.def.name`.

Cross-check on the three key shapes (probe `propB_probe7.jl`) — `mi.def.name`
**agrees with the existing `_nameof_of`** everywhere it works today:

```
throw_boundserror         | throw_boundserror           SAME
BoundsError               | BoundsError                 SAME
<UndefRefError>           | #_growend!##0               ***the fix***
ConcurrencyViolationError | ConcurrencyViolationError    SAME
throw_inexacterror        | throw_inexacterror           SAME
InexactError              | InexactError                 SAME
```

So `mi.def.name` is a **strict generalisation**, not a behaviour change. Proposed:

```julia
# src/extract/julia_set.jl — replaces _callable_of_key / _nameof_of (lines 99-105)
function _callee_bare_name(@nospecialize(k), at::Type{<:Tuple})::Symbol
    cls = _classify_callee_key(k)
    cls === :constructor && return nameof(k.parameters[1])
    cls === :singleton   && return nameof(k.instance)
    # :noninstance — the METHOD name (what codegen mangles), NOT nameof(k)
    # (`nameof` gives the closure's TYPE name `#f##0#f##1`, which matches no
    # LLVM symbol — Bennett-40ys, proposal_B §4.1).
    return _method_instance_of_sig(_spectypes_of(k, at)).def.name
end
```

`K.name.singletonname` gives the same answer on 1.12 but is a newer `TypeName`
field; `mi.def.name` is what codegen itself reads, so it is the more defensible
source. Prefer it.

### 4.2 Registration is **not required** under `ptr_cells=true`

`julia_set.jl:298-322` registers every `Function` callee so the body walk does not
hit the Bennett-5oyt / U15 guard. We **cannot** register the closure: `register_callee!`
is `f::Function`-typed (`callees.jl:12`) and keys on `string(nameof(f))` — no
instance, no registration.

That turns out to be fine. `instructions.jl:3189-3311` (BVM ADR 0020 D5): under
`ptr_cells=true`, a `_lookup_callee` **miss** on an `LLVM.Function` callee emits a
`Symbol`-callee `IRCall` with cell-width args — it never reaches the U15 fail-loud
at `instructions.jl:3369`. The gate the closed-world producer already passes
(`ptr_cells=true`) is exactly the gate that makes registration optional.

**Design consequence:** the registration loop stays as-is, guarded by the
classifier — register only `:singleton` / `:constructor`-derived `Function`s, skip
`:noninstance`. No change to `callees.jl`, no `Union{Function,Symbol}` widening of
`_known_callees` (which would ripple into `lowering/call.jl`'s inliner).

### 4.3 Canonical key: `#` is safe, but the DIGEST is not

`_canonical_callee_key` (`julia_set.jl:120-121`) builds `Symbol(bare, "#", digest)`.
For the closure: `#_growend!##0#a7027856`. The `rsplit(…, "#"; limit=2)[1]`
recovery at `julia_set.jl:359` handles the embedded `#` correctly — the S1 comment
already anticipated closure barenames. Probe-verified:

```
canonical key = Symbol("#_growend!##0#a1b2c3d4")  ->  bare = Symbol("#_growend!##0")
```

**But the digest is broken for this key class.** `_argtype_digest(at)`
(`julia_set.jl:113`) hashes only the *argtypes*, and a closure's argtypes are
`Tuple{}` — **constant**. Probe `propB_probe11.jl`, on
`push2(n) = (a=Int64[]; b=Int32[]; push!(a,n); push!(b,Int32(n)); …)`:

```
Base.var"#_growend!##0#…"{Vector{Int32},…}  at=Tuple{}  key(argtype-digest)=#_growend!##0#9fcdd36a
Base.var"#_growend!##0#…"{Vector{Int64},…}  at=Tuple{}  key(argtype-digest)=#_growend!##0#9fcdd36a   ← COLLISION
                                                        key(specTypes-digest)=#_growend!##0#9d90b8fb / #a7027856  ← distinct
hash(Tuple{}) digest = 9fcdd36a
```

Two genuinely different closure bodies collide on one canonical key and trip the
duplicate-key assert at `julia_set.jl:348`. **Required fix, one line:** digest the
**full specTypes**, not the argtypes —

```julia
_canonical_callee_key(k, at)::Symbol =
    Symbol(_callee_bare_name(k, at), "#", _argtype_digest(_spectypes_of(k, at)))
```

This is *more* correct for every key (the callee key was previously absent from
the content address entirely), and BVM only requires the shape `#<8hex>`
(`BennettVM.jl/src/ir/ingest_multi.jl:55` `_CONTENT_DIGEST_RE`), not a specific
value. **Nit while there:** `string(hash(at); base=16)[1:8]` `BoundsError`s when
the hash has ≥1 leading zero nibble (p ≈ 2⁻²⁸ per call) — use `lpad(…, 16, '0')[1:8]`.

### 4.4 BennettVM `#`-label interop — already handled, with ONE gap

`BennettVM.jl/docs/adr/0019-reversible-calls.md:129-136` reserves `#` for label
qualification and says ingest fails loud on a `#`-bearing function name. That
would be fatal — except the guard has already been generalised for exactly this
case. `BennettVM.jl/src/ir/ingest_multi.jl:55-70`:

```julia
const _CONTENT_DIGEST_RE = r"#[0-9a-fA-F]{8}$"
function _vm_funcname(key::Symbol)::Symbol
    s = String(key)
    if occursin(_CONTENT_DIGEST_RE, s)
        return Symbol(replace(s[1:end-9], '#' => '.'))   # `#9#<digest>` → `.9`
    elseif occursin('#', s) …
```

So `#_growend!##0#a7027856` → strip digest → `#_growend!##0` → sanitise → `._growend!..0`.
Block labels are checked separately (`ingest_multi.jl:147-152`) and LLVM block
labels never contain `#`. **No BVM change needed for the table key.**

**The gap is the call site.** `BennettVM.jl/src/ir/ingest_body.jl:77-89`:

```julia
_callee_sym(callee::Function) = nameof(callee)
_callee_sym(callee::Symbol)   = callee            # ← no demangling
_vm_dispatch_name(callee) = Symbol(replace(String(_callee_sym(callee)), '#' => '.'))
```

The comment at `ingest_body.jl:82-83` states the assumption explicitly: *"Call
sites carry BARE names … a Julia set's in-set call site is a bare `nameof`
`Function`"*. That assumption holds **only because** `julia_set.jl` registers
every callee. For the closure — which cannot be registered (§4.2) — the call site
carries the **mangled** `Symbol("j_#_growend!##0_464")`, so
`_vm_dispatch_name` yields `j_._growend!..0_464` ≠ the table key `._growend!..0`,
and BVM guard-5 fails loud with an unresolved-callee error.

Recommended fix, **Bennett-side**, minimal and in the right place: in the closed-world
producer, post-process each emitted `ParsedIR`'s `Symbol` callees through the
**existing** `_demangle_callee_symbol` (`julia_set.jl:127-130`) when the demangled
bare name is in-set — i.e. rewrite `j_#_growend!##0_464` → `#_growend!##0` at set
assembly, right where `_closed_world_check!` already computes exactly that
demangling (`julia_set.jl:178-181`). This removes the drift-prone `_NNN` from the
IR the way Rule 5 wants, is a no-op for the C track (no `julia_`/`j_` prefix) and
a no-op for registered `Function` callees. **I scope this OUT of Bennett-40ys**
(§5) because it cannot be exercised end-to-end until the sret wall clears; file it
as a follow-on with this evidence attached.

### 4.5 Case-folding hazard in the demangler — a real latent bug closures make live

`_demangle_callee_symbol` (`julia_set.jl:128`) and `_lookup_callee`
(`callees.jl:81-82`) both match against `lowercase(String(sym))` and return the
**lowercased** capture. Probe `propB_probe10.jl`:

```
j_#_growend!##0_464  -> Symbol("#_growend!##0")     ok (already lowercase)
j_#Foo##0_12         -> Symbol("#foo##0")           ← WRONG
julia_Adder_770      -> :adder                      ← WRONG
```

and an uppercase-parented closure is entirely ordinary:

```
function MakeIt(v, n) = () -> v[1]+n
  mi.def.name = Symbol("#MakeIt##0")
  define i64 @"julia_#MakeIt##0_136"(…)
```

The Dict corpus survives only by luck — `setindex!`, `rehash!`,
`ht_keyindex2_shorthash!` are all lowercase. A closure inside any capitalised
function (or any functor, per §5) breaks `bare_to_key` resolution and produces a
**spurious** closed-world violation. The `lowercase` is only needed to
case-normalise the `julia_`/`j_` *prefix*; the capture must be taken from the
**original** string. Cheap fix (`i` flag on the prefix, capture unlowered), and it
belongs in this bead because the closure work is what makes it reachable.

---

## 5. Calling convention through the pipeline — probed, not guessed (Rule 9)

### 5.1 Caller side (root `pushw`, `optimize=false`)

From `propB_probe3.jl` / `propB_root_O0.ll`:

```llvm
%"new::#_growend!##0#_growend!##1" = alloca [9 x i64], align 8   ; captured state, BY POINTER
%sret_box = alloca [2 x i64], align 8                            ; sret buffer
%1 = alloca ptr, align 8                                         ; return_roots (1 slot)
%2 = alloca ptr, i32 3, align 8                                  ; GC roots for the 3 ptr fields
...
%19 = getelementptr inbounds i8, ptr %"new::#_growend!##0#…", i32 8 ; store i64 %16   (newmemlen)
%20 = …i32 16   ; store i64 %14   (offset)     %21 = …i32 24  ; store i64 %11  (newlen)
%22 = …i32 32   ; memcpy len      %23 = …i32 40 ; memcpy memlen  %24 = …i32 56 ; memcpy ref
store ptr %"new::Array",         ptr %30   ; roots[0] = a
store ptr %"new::Array.ref.mem", ptr %31   ; roots[1] = mem
store ptr %28,                   ptr %32   ; roots[2] = ref.mem

call void @"j_#_growend!##0_464"(
    ptr noalias nocapture noundef sret({ ptr, ptr }) %sret_box,
    ptr noalias nocapture noundef %1,                       ; return_roots
    ptr nocapture readonly %"new::#_growend!##0#…",          ; captured state
    ptr nocapture readonly %2)                               ; .roots.#self#
```

### 5.2 Callee side — matches exactly

```llvm
define void @"julia_#_growend!##0_322"(ptr … sret({ptr,ptr}) %sret_return,
                                       ptr … %return_roots,
                                       ptr … dereferenceable(72) %"#self#::#_growend!##0#…",
                                       ptr … %".roots.#self#")
  %1 = getelementptr inbounds i8, ptr %".roots.#self#", i32 0   ; a
  %5 = getelementptr inbounds i8, ptr %".roots.#self#", i32 16  ; ref
  %6 = getelementptr inbounds i8, ptr %"#self#::…", i32 16      ; .unbox i64
```

**Answers to the calling-convention questions:**

1. **By-pointer, not byval, not decomposed.** The captured struct is a caller
   `alloca [9 x i64]` passed as a plain `ptr` (`nocapture readonly`).
2. **The struct is SPLIT.** Julia's rooting ABI puts the *unboxed* `i64` fields in
   the `#self#` buffer (offsets 16/24/32/40) and the three *pointer* fields in a
   **separate** `.roots.#self#` buffer. The callee reads each from its own buffer.
   A design that assumed one contiguous struct would be wrong.
3. **Arity mismatch is structural.** `argtypes = Tuple{}` at the Julia level
   becomes **4 LLVM parameters**. `ParsedIR.args` derives from the LLVM signature,
   so `length(pir.args) == 4` while `length(at.parameters) == 0`. Nothing in
   `julia_set.jl` currently compares them — but no new code may assume they match,
   and the canonical-key digest must not be derived from `at` alone (§4.3).
4. **Under `ptr_cells=true`** all four are `ptr` ⇒ four 64-bit VM cells, and BVM's
   `CallEnter` COPY-read semantics (ADR 0019 Amendment A.1 / ADR 0023) carry them
   unchanged — they are ordinary SSA cells; ADR 0023 already removed the
   `allunique(args)` guard. **No BVM arg-passing change needed.** The BVM-side work
   is (a) the callee-name binding of §4.4 and (b) the sret-box ABI below.

### 3+1 note on the return: **`sret({ptr, ptr})` is the next wall, and it is loud**

Probe `propB_probe4.jl` / `propB_probe7.jl`, on the by-sig-extracted closure body:

```
from_ll ptr_cells=true  : WALL: ir_extract.jl: sret struct field 0 has type
  LLVM.PointerType(ptr) in @julia_#_growend!##0_1428; only fixed-width integer
  bits-struct fields are supported (… — Bennett-dv1z)
```

and the **root** `pushw` walls identically —

```
extract_parsed_ir(pushw, Tuple{Int64}; ptr_cells=true) :
  WALL: … sret struct field 0 has type LLVM.PointerType(ptr) in @julia_pushw_1573 …
```

— because `_collect_consumed_sret` (`src/extract/sret.jl:1219-1224`, bead
`bennettvm-416r.16`) inspects the *call site's* sret pointee and routes it through
`_sret_struct_fields` (`sret.jl:137-165`), which rejects any non-`IntegerType`
field. Both walls are the **same root cause**: `_sret_struct_fields` has no
`ptr_cells` awareness, so a `ptr` field is rejected even in the mode where a
pointer is defined to be a 64-bit cell. That is a clean, well-scoped follow-on
(one predicate, both call sites), and — importantly — it is a **named fail-loud
with a bead reference**, not a crash. Exactly the behaviour §6 asks for.

---

## 6. Scope decision

**Chosen: (b′) — a general "non-instance callable" arm, not a closure-specific one.**

Rejecting the three offered options as stated:

* **(a) fully general non-singleton-callable support** — as a *goal* this is right,
  but "general" must not mean "speculative". I implement the general *mechanism*
  (signature-driven codegen) and let it cover whatever callable shapes Julia
  actually hands us, with a fail-loud for anything else.
* **(b) closure-specific arm** — wrong dimension. Probe `propB_probe6.jl` §(B): a
  plain **functor** `struct Adder; n::Int64; end; (a::Adder)(x)=x+a.n` is *also*
  `isdefined(K,:instance) == false`, and by-sig handles it with zero extra code
  (`define i64 @julia_Adder_770(ptr … %"a::Adder", i64 %"x::Int64")`,
  `mi.def.name == :Adder`). Special-casing "closure" would need a second arm the
  day a functor appears, and closures/functors are the *same* Julia concept
  (a callable type with fields).
* **(c) diagnostic-only now** — fails the bead. The bead exists to unblock
  `bennettvm-xkl`; stopping at the diagnostic leaves `push!` no further along and
  the next agent re-derives all of §3.

The "general in the right dimension, fail loud outside it" line:

* **General in**: *how a callee key becomes codegen input* → by **signature**.
  Covers closures, functors, and (unchanged) plain functions and constructors.
* **Loud outside**: `_classify_callee_key` fails loud on any key that is not a
  concrete `Type`; `_assert_sig_llvm_supported` fails loud on any Julia that
  moved the internals; `_code_llvm_by_sig` fails loud on no-unique-method and on
  non-`CodeInfo` inference. The body walk's existing walls (sret, U15, ptr-width)
  are untouched and keep firing.

**Explicitly OUT of scope for Bennett-40ys** (each to be filed as a bead with the
evidence from this document attached):

| # | Follow-on | Evidence |
|---|---|---|
| F1 | `_sret_struct_fields` must accept `ptr` fields as 64-bit cells under `ptr_cells` (blocks BOTH the closure body and the root `pushw`) | §5, `sret.jl:137-165`, `sret.jl:1219-1224` |
| F2 | BVM call-site binding for unregisterable callees: demangle `Symbol` callees at set assembly | §4.4, `ingest_body.jl:77-89` |
| F3 | Whatever lies beyond the sret wall inside the closure body (`jl_genericmemory_copy_slice`, `llvm.memmove`, the `.roots` buffer model) | §5.2 declares |

**In scope, and non-negotiable, is the property that F1/F2/F3 surface as named
fail-louds.** Probe-verified today (§5): they already do.

---

## 7. Test plan (RED-GREEN, CLAUDE.md Rule 3)

New file **`test/test_40ys_noninstance_callee.jl`**, registered in
`test/runtests.jl`. All fixtures are **local to the test file** — none depends on
`Base.var"#_growend!##..."` naming (§8 R1) except the two explicitly-marked
integration testsets, which assert only *shape*, never a Base-internal name.

**T1 — diagnostic floor (RED today = `UndefRefError`).**
```julia
@testset "non-instance callee key classifies, does not UndefRefError" begin
    mk(v::Vector{Int64}, n::Int64) = () -> v[1] + n
    K = typeof(mk(Int64[7], 3))
    @test !isdefined(K, :instance)                       # the precondition
    @test Bennett._classify_callee_key(K)     == :noninstance
    @test Bennett._classify_callee_key(typeof(sin))      == :singleton
    @test Bennett._classify_callee_key(Type{BoundsError}) == :constructor
    e = try Bennett._classify_callee_key(3); nothing catch e; e end   # not a Type
    @test e isa ErrorException && occursin("julia_set.jl", e.msg)
    @test !(e isa UndefRefError)
end
```

**T2 — by-sig ≡ code_llvm (the mechanism proof, §3.3).** The load-bearing test:
```julia
@testset "_code_llvm_by_sig matches code_llvm modulo mangling drift" begin
    norm(s) = replace(s, r"_\d+\b" => "_N", r"#\d+" => "#N")
    for (f, T) in ((x -> x + 1, Tuple{Int64}),
                   (Core.throw_inexacterror, Tuple{Symbol, Type, Int64}))  # non-dispatchtuple
        sig = Base.signature_type(f, T)
        a = sprint(io -> code_llvm(io, f, T; debuginfo=:none, optimize=false, dump_module=true))
        b = Bennett._code_llvm_by_sig(sig; optimize=false)
        @test norm(a) == norm(b)
    end
    # the case with an instance but NO .instance — closures
    cl = (v = Int64[7]; n = 3; () -> v[1] + n)
    a = sprint(io -> code_llvm(io, cl, Tuple{}; debuginfo=:none, optimize=false, dump_module=true))
    b = Bennett._code_llvm_by_sig(Tuple{typeof(cl)}; optimize=false)
    @test norm(a) == norm(b)
end
```

**T3 — naming.** `_callee_bare_name(K, Tuple{})` equals the bare name embedded in
the emitted `define` (extracted from the IR text *for the assertion only*, which
is legitimate: the test asserts a naming *contract*, it does not build the
compiler on regex). Also `@test _callee_bare_name(K, Tuple{}) != nameof(K)` — the
trap of §4.1, pinned so nobody "simplifies" it back.

**T4 — end-to-end body extraction of a user closure.**
`extract_parsed_ir_by_sig(Tuple{typeof(cl)}; ptr_cells=true)` returns a `ParsedIR`;
assert `length(pir.args) >= 1` and `length(pir.blocks) >= 1`. Uses a *local*
closure, so it is Julia-version-robust.

**T5 — functor generality (§5/§6).** `struct Adder40ys; n::Int64; end;
(a::Adder40ys)(x::Int64) = x + a.n` → `_classify_callee_key(Adder40ys) == :noninstance`,
`_callee_bare_name(Adder40ys, Tuple{Int64}) == :Adder40ys`, and
`extract_parsed_ir_by_sig(Tuple{Adder40ys, Int64})` succeeds.

**T6 — canonical-key collision (§4.3).** Two distinct closure types with
`argtypes == Tuple{}` and the same method name must produce **distinct** canonical
keys. RED today (both `#…#9fcdd36a`).

**T7 — case folding (§4.5).** `_demangle_callee_symbol(Symbol("j_#MakeIt##0_12")) ==
Symbol("#MakeIt##0")` and `Symbol("julia_Adder_770") → :Adder`. RED today
(`#makeit##0`, `:adder`).

**T8 — integration, the bead's exit criterion.**
```julia
@testset "push! closed-world set: no UndefRefError; loud at the NEXT wall" begin
    pushw(n::Int64) = (v = Int64[]; push!(v, n); v[1])
    e = try Bennett.extract_parsed_ir_set_from_julia(pushw, Tuple{Int64};
              ptr_cells=true, on_extract_error=:fail_loud); nothing catch e; e end
    @test !(e isa UndefRefError)                     # ← THE bead
    @test e isa ErrorException
    @test occursin("extraction FAILED for callee", e.msg)   # named, contextual
    @test occursin("sret", e.msg)                    # the next wall, named (F1)
    # and :skip must now be able to do its job
    out = Bennett.extract_parsed_ir_set_from_julia(pushw, Tuple{Int64};
              ptr_cells=true, on_extract_error=:skip)
    @test out isa Vector{Pair{Symbol, Bennett.ParsedIR}}
end
```
The `occursin("sret", …)` assertion is deliberately a **wall marker**: when F1
lands it goes RED, which is the signal to advance the assertion to the *next*
wall. Comment it as such so the next agent does not simply delete it.

**T9 — no registry pollution.** `julia_set.jl:365-379` restores `_known_callees`
in a `finally`. Assert the registry is byte-identical before/after a `pushw` call
that now takes the `:noninstance` path (which registers nothing).

### Exit criterion — this bead vs. `bennettvm-xkl`

| | |
|---|---|
| **Bennett-40ys DONE when** | T1–T9 green; `extract_parsed_ir_set_from_julia` on any `push!` function raises no `UndefRefError` and either returns a set or fails loud with a message naming the canonical key and the wall; the closure body's `ParsedIR` is obtainable in isolation via `extract_parsed_ir_by_sig`. |
| **Still owed to `xkl`** | F1 (ptr-field sret under `ptr_cells`) → F3 (whatever is inside the closure body) → F2 (BVM callee binding) → BVM run + reverse. |

`bennettvm-xkl` remains P0 and blocked; 40ys converts an opaque crash into a
mapped, one-at-a-time wall sequence and delivers the reusable capability.

---

## 8. Risk register

| # | Risk | Assessment / mitigation |
|---|---|---|
| **R1** | **`Base.var"#_growend!##0#_growend!##1"` naming is a Julia-version artefact.** The outlining of `_growend!`'s slow path is a 1.12 codegen decision; 1.11 inlined it, 1.13 may re-inline it. | Do **not** pin any Base-internal closure name. All unit fixtures (T1–T7) use *local* closures/functors. T8 asserts *shape* only ("no `UndefRefError`", "message mentions sret"). If a future Julia stops outlining, T8 changes from "walls at sret" to "extracts" — a green-to-different-green transition, and T1–T7 still prove the capability. |
| **R2** | **Julia introspection internals move** (`Base.Compiler` was `Core.Compiler` before 1.12; `_dump_function_llvm` is a private stdlib function). | `_assert_sig_llvm_supported()` checks all five symbols and errors with the Julia version + the codeview.jl reference. Precedent: `callgraph.jl:19-23/34-39` already depends on `Core.CodeInstance` and fails loud via `mi_of`. This is the project's established pattern, not a new class of debt. |
| **R3** | **optimize skew.** `transitive_callees` harvests at `optimize=true` (`callgraph.jl:52-54`, and its docstring documents that O0 emits **zero** `:invoke`s); bodies are extracted at `optimize=false` (Rule 5). | Unchanged by this proposal — `_code_llvm_by_sig` takes `optimize` as a parameter and `julia_set.jl` keeps passing `optimize=false`. But note the *specific* consequence for closures: the closure exists **only because** O2 outlined it, so the edge is an O2 fact while the body is an O0 emission. That is sound (the MethodInstance is the same object; only codegen differs) and is exactly what `code_llvm(cl, Tuple{}; optimize=false)` does today — probe T2 pins the equivalence. Document it in the file header. |
| **R4** | **`argtypes == Tuple{}` oddity.** The closure carries everything in its type; the argtypes carry nothing. | Two concrete consequences, both handled: (i) canonical-key collision — §4.3, **fixed** by digesting specTypes, test T6; (ii) Julia arity (0) ≠ LLVM arity (4) — §5.1(3); no code may equate them. |
| **R5** | **Precompile / cache interactions.** `_parsed_ir_cache` (`callees.jl:37`) is keyed `(f::Function, …)` and cannot hold a by-sig entry. | By design: `extract_parsed_ir_by_sig` does **not** route through `_extract_parsed_ir_cached`, matching `extract_parsed_ir_set_from_julia`'s existing choice (`julia_set.jl:217-219`). A separate `Type`-keyed cache is a later optimisation, not correctness. Separately: `Base.get_world_counter()` is read *per call*; a `@eval` between the callgraph walk and the body extraction could skew worlds. Both `transitive_callees` and this path already re-read the counter, so the exposure is unchanged — but it should be noted in the worklog. |
| **R6** | **`_dump_function_llvm` JIT-compiles the method** (`jl_get_llvmf_defn`), which for a closure with `Vector`/`Memory` captures pulls a chunk of Base codegen into the process. | Observed cost is comparable to the existing `code_llvm` path (probe runs complete in normal test time). It is the *same* ccall `code_llvm` makes. No new risk. |
| **R7** | **Case folding** (§4.5) silently corrupts bare-name resolution for any capitalised parent. | Pinned by T7; fix is in scope. Currently masked only because the Dict corpus is all-lowercase — a genuine latent bug that this bead's work makes reachable. |
| **R8** | **`entry.jl` is core pipeline** — CLAUDE.md Rule 2 (3+1). | This document is proposer B. The refactor is extract-method only (the tail of `extract_parsed_ir` moves verbatim into `_parsed_ir_from_ir_string`); the reviewer should confirm byte-identical behaviour for every existing caller and that the Dict corpus + T5 multi-language tests stay green. |
| **R9** | **`_vm_funcname` sanitisation is lossy**: `#f##0` and `.f..0` map to the same VM name if a user ever defines a function literally named `.f..0`. | Structurally impossible per `ingest_multi.jl:45-48` (`nameof` can never produce `.`). No action. |

---

## 9. Files touched (summary)

| File | Change | Core? |
|---|---|---|
| `src/extract/sig_llvm.jl` | **NEW** (~90 LOC): `_assert_sig_llvm_supported`, `_code_llvm_by_sig`, `_method_instance_of_sig`, `_spectypes_of` | no (additive) |
| `src/ir_extract.jl` | add `include("extract/sig_llvm.jl")` to the manifest | trivial |
| `src/extract/entry.jl` | extract-method `_parsed_ir_from_ir_string`; add `extract_parsed_ir_by_sig` | **YES — 3+1** |
| `src/extract/julia_set.jl` | `_classify_callee_key`, `_callee_bare_name`, `_callee_key_error`; drop `_callable_of_key`/`_nameof_of`; specTypes digest; classifier-guarded registration; `:noninstance` extraction arm; demangler case fix | **YES — 3+1** |
| `test/test_40ys_noninstance_callee.jl` | **NEW**: T1–T9 | — |
| `test/runtests.jl` | register the new file | — |
| `worklog/<highest NNN>_*.md` | session entry: the four non-obvious findings (§4.1 `nameof` trap, §4.3 digest collision, §4.5 case folding, §5.2 split `.roots` ABI) | — |

No change to `callees.jl`, `callgraph.jl`, `instructions.jl`, `sret.jl`, or any
BennettVM file in this bead.
