# ---- known callee registry for gate-level inlining ----

const _known_callees = Dict{String, Function}()
# Bennett-7stg / U26: wrap mutations and lookups in a ReentrantLock.
# Multi-threaded compiles (e.g. parallel Pkg.test workers) could race on
# Dict mutation; the lock makes register_callee! / _lookup_callee safe.
# ReentrantLock allows recursive entry — matters for pathological cases
# where _lookup_callee somehow triggers a register during compilation.
const _known_callees_lock = ReentrantLock()

# Bennett-7q9z: registry generation, bumped AFTER every mutation of
# `_known_callees` / `_known_callee_names` that changes them. Both compile
# caches fold it into their stamp (`_cache_stamp`): a registration does not
# move Julia's world counter, so without it a ParsedIR or circuit built before
# `register_callee!` was served after it, with the callee lowered the old way.
# Bumping after the mutation (never before) means a compile that raced it
# either sees the old stamp at insert time — and skips the insert — or read
# the new stamp and the new registry together.
const _callee_registry_gen = Threads.Atomic{UInt}(0)
_callee_registry_changed!() = (Threads.atomic_add!(_callee_registry_gen, UInt(1)); nothing)

"""
    register_callee!(f::Function) -> Nothing

Register a Julia function for gate-level inlining when encountered as an LLVM
call. The registry is keyed by the BARE name `string(nameof(f))` — the only
part of the LLVM symbol `j_<name>_<NNN>` that names the function. Re-registering
the same function is a no-op; registering a DIFFERENT function under an
already-registered bare name (e.g. `A.same` after `B.same`) throws (Bennett-p9a0):
the old overwrite silently inlined the last-registered body for both.
"""
function register_callee!(f::Function)
    name = string(nameof(f))
    changed = lock(_known_callees_lock) do
        prev = get(_known_callees, name, nothing)
        prev === nothing || prev === f || throw(ArgumentError(
            "register_callee!: cannot register $(parentmodule(f)).$name — the bare " *
            "name `$name` is already registered to $(parentmodule(prev)).$(nameof(prev)). " *
            "LLVM call symbols (`j_$(name)_<NNN>`) carry no module, so two same-named " *
            "callees cannot share the registry (Bennett-p9a0); rename one of them."))
        prev === f && return false
        _known_callees[name] = f
        return true
    end
    changed && _callee_registry_changed!()   # Bennett-7q9z
    return nothing
end

# ---- Bennett-p9a0: module identity of a demangled callee ----
#
# The registry key is a bare name and the LLVM symbol carries no module, so a
# call `j_same_NNN` to the UNREGISTERED `A.same` used to resolve to a registered
# `B.same`, whose body was then inlined (wrong circuit, ancillae still clean).
# A Julia-function extraction knows its root signature, and Julia's codegen
# emits a `j_<name>_<NNN>` call for each `:invoke` left in the root's optimized
# typed code — so the root's `:invoke` edges say which function each name
# denotes. `extract_parsed_ir` / `extract_parsed_ir_by_sig` set `_CALLEE_ROOT`
# for the walk; `_lookup_callee` then accepts a demangled hit only when the
# edges hold exactly one function of that name and it IS the registered one,
# and fails loud otherwise. `.ll`/`.bc`/IR-string entries have no Julia root
# (the scope is unset): they keep name-only resolution, which is unambiguous
# within the registry because `register_callee!` rejects same-named functions.
mutable struct _CalleeRoot
    sig::Type
    direct::Union{Nothing, Vector{DataType}}    # root's own `:invoke` specTypes (lazy)
    closure::Union{Nothing, Set{DataType}}      # transitive `:invoke` specTypes (lazy)
end
_CalleeRoot(sig::Type) = _CalleeRoot(sig, nothing, nothing)

const _CALLEE_ROOT = Base.ScopedValues.ScopedValue{Union{Nothing, _CalleeRoot}}(nothing)

"""Run `body()` with `sig` as the Julia root whose `:invoke` edges vouch for
demangled callee hits (Bennett-p9a0)."""
_with_callee_root(body, sig::Type) =
    Base.ScopedValues.with(body, _CALLEE_ROOT => _CalleeRoot(sig))

# The distinct callee identities whose LLVM bare name is `fname` among the
# callee specTypes `sts`. A singleton `Function` is identified by its type and
# named by `nameof`; an INSTANCE-LESS callable (closure / functor, Bennett-40ys
# / Bennett-m5q9) by its `TypeName` — every specialisation and call method of
# one callable type mangles to the same bare name — and named by the method
# name codegen mangles (`mi.def.name`, see `_callee_barename`).
function _callee_types_named(sts, fname::AbstractString)
    out = Any[]
    for st in sts
        fT = st.parameters[1]
        fT isa DataType || continue
        id = if isdefined(fT, :instance)
            (fT.instance isa Function && string(nameof(fT.instance)) == fname) || continue
            fT
        else
            (isstructtype(fT) && !(fT <: Core.OpaqueClosure)) || continue
            string(_method_instance_of_sig(st).def.name) == fname || continue
            fT.name
        end
        id in out || push!(out, id)
    end
    return out
end

_callee_identity_qual(fT::DataType) = "$(parentmodule(fT.instance)).$(nameof(fT.instance))"
_callee_identity_qual(tn::Core.TypeName) = "$(tn.module).$(tn.name)"

# `id` is the registered identity: `typeof(f)` for `register_callee!`, the
# `TypeName` for `register_callee_name!`; `bead` names the registry's guard.
function _check_callee_identity(root::_CalleeRoot, llvm_name::String,
                                fname::String, id, bead::String)
    # Direct edges first (the case for every call in the root's own body); the
    # transitive closure covers a call that reached the root's LLVM body from a
    # co-emitted callee. Both are computed at most once per extraction.
    root.direct === nothing && (root.direct = _invoke_callees(root.sig))
    cands = _callee_types_named(root.direct, fname)
    if isempty(cands)
        root.closure === nothing && (root.closure = _transitive_callee_specTypes(root.sig))
        cands = _callee_types_named(root.closure, fname)
    end
    length(cands) == 1 && only(cands) === id && return nothing
    why = isempty(cands) ?
        "no function named `$fname` is invoked beneath $(root.sig), so the call's target is unknown" :
        length(cands) > 1 ?
        "several functions named `$fname` are invoked beneath $(root.sig) " *
        "($(join(_callee_identity_qual.(cands), ", "))) and the symbol does not say which" :
        "it targets $(_callee_identity_qual(only(cands))), not the registered " *
        "$(_callee_identity_qual(id))"
    error("$bead: LLVM call `$llvm_name` demangles to the registered callee " *
          "name `$fname`, but $why. Refusing to inline a body that may be the wrong " *
          "function; give the callees distinct names.")
end

# Bennett-ej4n / U48: cache extracted ParsedIR keyed on (callee, arg_types).
# `extract_parsed_ir` does a ~21ms LLVM C-API walk per invocation; a circuit
# with N references to the same callee paid that N times via `lower_call!`.
# Avoids worsening the LoweringCtx back-compat-constructor sprawl tracked in
# Bennett-ehoa / U43.
#
# Bennett-uiaq: cache key extended to include `optimize` and `mem` so the
# top-level `reversible_compile(f, arg_types)` overload can route its
# extraction through this helper and auto-hit the Bennett-sr8v compile cache
# on repeat calls, WITHOUT silently dropping non-default extraction kwargs.
# The no-kwargs call shape (src/lowering/call.jl) keeps the defaults
# `optimize=true, mem=:auto` — matches `extract_parsed_ir(f, arg_types)`.
#
# Bennett-4ddk: the key `(f, arg_types, ...)` does NOT change when a method is
# redefined (the function object survives `@eval g(x) = ...`), nor when a
# callee that `f` inlines is. Both this cache and `_compile_cache` are
# therefore WORLD-GATED: an access in a different world (`Base.get_world_counter`)
# than the cache was filled in empties it first. That is conservative — any
# method definition, and in Julia 1.12 any new global binding, bumps the world
# — but sound for transitive redefinition, where a per-method check is not.
# Same-world repeats (the intra-compile `lower_call!` reuse, back-to-back
# compiles) still hit. Each cache is also size-bounded, and `f` is untyped so
# callable structs / `Type` constructors are accepted like `extract_parsed_ir`.
# Bennett-sfq8: an `IdDict` — keys compare by `===`. A `Dict` compares `f` by
# `isequal`, which equates callables of different types (`Int8(0)`,
# `UInt64(0)`, `0.0`, `false`), so a callable `false` was handed the IR of a
# callable `Int8(0)`. Egality also separates distinct `Type` callables.
const _parsed_ir_cache = IdDict{Tuple{Any, Type, Bool, Symbol, Int}, ParsedIR}()
const _parsed_ir_cache_lock = ReentrantLock()
const _parsed_ir_cache_world = Ref{Tuple{UInt, UInt}}((0, 0))   # `_cache_stamp()` it was filled at
const _PARSED_IR_CACHE_MAX = 256

"""
    _cache_stamp() -> Tuple{UInt, UInt}

`(world counter, callee-registry generation)`: what a cached ParsedIR or
circuit depends on beyond its key (Bennett-4ddk world, Bennett-7q9z registry).
"""
_cache_stamp() = (Base.get_world_counter(), _callee_registry_gen[])

"""
    _cache_world_gate!(cache, stamp_ref) -> Tuple{UInt, UInt}

Bennett-4ddk / Bennett-7q9z: empty `cache` when the world counter or the
callee-registry generation has moved since `stamp_ref` was recorded, then
return the current `_cache_stamp()`. Call with the cache's lock held.
"""
function _cache_world_gate!(cache::AbstractDict, stamp_ref::Base.RefValue{Tuple{UInt, UInt}})
    st = _cache_stamp()
    if st != stamp_ref[]
        empty!(cache)
        stamp_ref[] = st
    end
    return st
end

"""
    _cache_insert_bounded!(cache, key, val, maxlen, stamp)

Bennett-4ddk: store `key => val` unless the world (or, Bennett-7q9z, the
callee registry) moved during the computation of `val` (then the entry's
stamp is ambiguous — skip it), evicting arbitrary entries first so
`length(cache) <= maxlen`. Call with the lock held.
"""
function _cache_insert_bounded!(cache::AbstractDict, key, val, maxlen::Int,
                                stamp::Tuple{UInt, UInt})
    _cache_stamp() == stamp || return val
    while length(cache) >= maxlen
        delete!(cache, first(keys(cache)))
    end
    cache[key] = val
    return val
end

"""
    _extract_parsed_ir_cached(f, arg_types; optimize=true, mem=:auto, bit_width=0) -> ParsedIR

Memoised wrapper over `extract_parsed_ir(f, arg_types; optimize, mem)`,
followed by `_narrow_ir(_, bit_width)` when `bit_width > 0` (Bennett-4ddk: so
identical narrowed compiles share one `ParsedIR`, hence one compile-cache
entry). On a hit returns the previously-built `ParsedIR` by identity.
`ParsedIR` is immutable and the lowering pipeline only reads from it, so
sharing across compiles is safe.

Bennett-sl4h: a narrowed `optimize=true` entry is built by `_narrow_hybrid`
(unoptimised IR first, the optimised IR as the fallback), so the two
`optimize` values are separate keys that may hold different IR.

The key is `(f, arg_types, optimize, mem, bit_width)`; the cache is emptied
whenever the world counter moves (Bennett-4ddk) or the callee registry changes
(Bennett-7q9z), and holds at most
`_PARSED_IR_CACHE_MAX` entries.
"""
function _extract_parsed_ir_cached(f, arg_types::Type{<:Tuple};
                                    optimize::Bool=true,
                                    mem::Symbol=:auto,
                                    bit_width::Int=0)::ParsedIR
    key = (f, arg_types, optimize, mem, bit_width)
    lock(_parsed_ir_cache_lock) do
        w = _cache_world_gate!(_parsed_ir_cache, _parsed_ir_cache_world)
        haskey(_parsed_ir_cache, key) && return _parsed_ir_cache[key]
        pir = bit_width == 0 ? extract_parsed_ir(f, arg_types; optimize, mem) :
              optimize       ? _narrow_hybrid(f, arg_types, mem, bit_width) :
            _narrow_unoptimised(f, arg_types, mem, bit_width)
        return _cache_insert_bounded!(_parsed_ir_cache, key, pir,
                                      _PARSED_IR_CACHE_MAX, w)
    end
end

"""
    _narrow_hybrid(f, arg_types, mem, W) -> ParsedIR

The `bit_width=W, optimize=true` narrowing (Bennett-sl4h).  LLVM's folds are
only valid at the source width S (`x * 16 == 0` becomes `(x & 15) == 0`,
wrong at 6 bits, and no local rule tells it from a plain mask), so at `W != S`
the UNOPTIMISED IR is narrowed first: it holds the source's own operations,
so an accepted narrowing is sound by construction, and the result is the very
`ParsedIR` the `optimize=false` compile uses (same cache entry).  If that
attempt is refused, the result is exactly the pre-sl4h path — the optimised IR
through `_narrow_ir(...; optimized=true)` and its folded-comparison checks —
whatever that path does (accept or throw).  At `W == S` nothing is re-typed
and the folds are valid, so the optimised path is used directly (no gate-count
cost for an identity narrowing).

Which failures of the unoptimised attempt fall back (`_narrow_attempt_refused`):
`ArgumentError` (every narrowing refusal: `_narrow_reject` and the g7d6
metadata check) and `ErrorException` (extraction refusals: `_ir_error` and the
extractor's raw `error(...)` calls — memory, calls, the gq1z global-alias
refusal, ... — which only the unoptimised IR may contain).  `_ir_error` raises
a plain `ErrorException`, and the extractor raises deliberate refusals through
raw `error(...)` too, so a refusal cannot be told from an accidental
`error(...)` without matching message text; we chose to let EVERY
`ErrorException` fall back.  The optimised path then re-checks the program
from scratch, so nothing is accepted that the pre-sl4h path did not accept.
Everything else — `InterruptException`, `MethodError`, `BoundsError`,
`KeyError`, `AssertionError`, ... — is a bug, not a refusal, and propagates.
A refused attempt caches nothing for this key (the exception skips the
insertion); only the returned result is cached, under the `optimize=true` key.

Bennett-5y48: the unoptimised attempt is `_narrow_unoptimised`, which refuses
width-dependent intrinsics and the Julia idioms LLVM recognises as them; the
optimised path refuses the intrinsics too (`_narrow_ir`).

LIMITATION (Bennett-5y48 stays open): a Julia-level width-dependent idiom that
LLVM folds away is narrowed literally from the unoptimised IR —
`ifelse(bitreverse(x) == 0, 1, 0)` re-types Julia's S-bit masks.

LIMITATION (Bennett-sl4h stays open): on the fallback a fold that relies on an
S-bit arithmetic fact can still be narrowed into a wrong circuit — a program
whose unoptimised IR is refused AND whose optimised IR holds such a fold.
"""
function _narrow_hybrid(f, arg_types::Type{<:Tuple}, mem::Symbol, W::Int)::ParsedIR
    unopt = try
        S = _narrow_source_width(_extract_parsed_ir_cached(f, arg_types;
                                                           optimize=false, mem))
        S == W ? nothing :
            _extract_parsed_ir_cached(f, arg_types; optimize=false, mem, bit_width=W)
    catch e
        e isa InterruptException && rethrow()
        _narrow_attempt_refused(e) || rethrow()
        nothing
    end
    unopt === nothing || return unopt
    return _narrow_ir(_extract_parsed_ir_cached(f, arg_types; optimize=true, mem),
                      W; optimized=true)
end

"""
    _narrow_unoptimised(f, arg_types, mem, W) -> ParsedIR

The `bit_width=W, optimize=false` narrowing — and `_narrow_hybrid`'s first
attempt, which goes through the same cache entry.  `_narrow_ir` refuses an
intrinsic the extractor expanded for the source width S
(`ParsedIR.width_dependent_ops`).  Bennett-5y48: Julia's own `bitreverse` and
`bitrotate` are Julia code whose masks and shift amounts were folded for S
(`typemax(T) ÷ 3`, `8sizeof(T)`) before LLVM sees them, so the UNOPTIMISED IR
holds no intrinsic to refuse; LLVM's optimiser re-recognises those idioms as
`llvm.bitreverse` / `llvm.fshl`.  So at `W != S` an accepted narrowing is
refused when the OPTIMISED IR records a width-dependent intrinsic.  If the
optimised IR cannot be extracted (an extraction refusal) there is nothing to
read and the narrowing stands (the pre-5y48 result).  LIMITATION: an idiom
LLVM folds away or does not recognise (`bitreverse(x) == 0` folds to
`x == 0`) is not seen — see the LIMITATION in `_narrow_hybrid`.
"""
function _narrow_unoptimised(f, arg_types::Type{<:Tuple}, mem::Symbol, W::Int)::ParsedIR
    raw = _extract_parsed_ir_cached(f, arg_types; optimize=false, mem)
    pir = _narrow_ir(raw, W; optimized=false)
    _narrow_source_width(raw) == W && return pir
    opt = try
        _extract_parsed_ir_cached(f, arg_types; optimize=true, mem)
    catch e
        e isa InterruptException && rethrow()
        _narrow_attempt_refused(e) || rethrow()
        return pir
    end
    isempty(opt.width_dependent_ops) || _narrow_reject(
        "the optimised IR of the function holds the width-dependent intrinsic(s) " *
        "$(join(sort!(collect(opt.width_dependent_ops)), ", ")): LLVM recognised a " *
        "bit-reverse / rotate / byte-swap / count-zeros idiom whose masks and " *
        "shift amounts Julia computed for the source width, so the unoptimised " *
        "IR re-typed to $W bits does not compute the $W-bit operation (Bennett-5y48)")
    return pir
end

"""A refusal of `_narrow_hybrid`'s unoptimised attempt, which falls back to
the optimised path; any other exception is a bug and propagates."""
_narrow_attempt_refused(e) = e isa ArgumentError || e isa ErrorException

"""Empty the `_parsed_ir_cache`. For tests; registry changes invalidate the
cache on their own (Bennett-7q9z), except direct edits of the registry Dicts."""
function _clear_parsed_ir_cache!()
    lock(_parsed_ir_cache_lock) do
        empty!(_parsed_ir_cache)
    end
    return nothing
end

"""
    _demangle_llvm_callee(llvm_name::AbstractString) -> Union{String, Nothing}

THE one demangler for Julia-emitted LLVM callee symbols, shared by
[`_lookup_callee`](@ref), [`_lookup_callee_name`](@ref) and the closed-world
check's `_demangle_callee_symbol`: `julia_<name>_<NNN>` / `j_<name>_<NNN>` →
`<name>` (the drift-prone `_<NNN>` dropped), `nothing` if not in that form.

Bennett-wh1p: CASE-PRESERVING. Only the `julia_`/`j_` prefix matches case-
insensitively; the captured name keeps its original casing. The registries are
keyed by `string(nameof(f))`, which is case-sensitive, so folding the capture
both made a capitalised callee unresolvable (`j_Upper_1050` → `upper`, a miss)
and SILENTLY bound it to a lowercase namesake (`j_Foo_101` → `foo`, whose body
was then inlined for `Foo`: wrong circuit, ancillae still clean).
"""
function _demangle_llvm_callee(llvm_name::AbstractString)
    m = match(r"^(?:julia_|j_)(.+)_(\d+)$"i, llvm_name)
    return m === nothing ? nothing : String(m.captures[1])
end

function _lookup_callee(llvm_name::String)
    hit, fname = lock(_known_callees_lock) do
        # First: try exact match (for hardcoded lookups like "soft_fcmp_ole")
        haskey(_known_callees, llvm_name) && return (_known_callees[llvm_name], nothing)

        # Second: LLVM-mangled names follow julia_<funcname>_<NNN> or j_<funcname>_<NNN>.
        # Extract the function name (case-preserved, Bennett-wh1p) and do an
        # exact dict lookup.
        fname = _demangle_llvm_callee(llvm_name)
        fname !== nothing && haskey(_known_callees, fname) &&
            return (_known_callees[fname], fname)
        return (nothing, nothing)
    end
    # Bennett-p9a0: a demangled hit is only a NAME match — confirm it is the
    # function the call targets (outside the registry lock: this may infer).
    root = _CALLEE_ROOT[]
    fname === nothing || root === nothing ||
        _check_callee_identity(root, llvm_name, fname, typeof(hit), "Bennett-p9a0")
    return hit
end

# ---- Bennett-40ys: callees known by NAME but not by VALUE ----
#
# `_known_callees` is `Dict{String, Function}` and `register_callee!` takes an
# `f::Function`. An INSTANCE-LESS callable — a closure or a functor, i.e. a
# callable type with fields and therefore no `.instance` — has no `Function`
# value to register, so it cannot live there.
#
# It still needs to be registered SOMEWHERE, because of what happens at the
# CALLER's extraction. Without an entry, `_lookup_callee` misses; under
# `ptr_cells=true` the miss falls into the ADR-0020-D5 arm and emits
# `IRCall(dest, Symbol("j_Adder40ys_2978"), …)` — the MANGLED LLVM name. That
# name is unusable downstream: BennettVM's `_vm_dispatch_name` does no
# demangling, so `j_Adder40ys_2978` sanitises to `j_Adder40ys_2978` while the
# closed-world set's table key `Adder40ys#<digest>` sanitises (via
# `_vm_funcname`) to `Adder40ys` — the call would never bind, and the `_<NNN>`
# suffix drifts between extractions anyway (Rule 5).
#
# So this registry maps an LLVM-visible BARE name to the BARE canonical Symbol
# the emitted `IRCall` should carry. Bare, NOT the digested set key: BVM strips
# the digest from TABLE keys but call sites carry bare names, and the closed-
# world check's `bare_to_key` map is keyed the same way.
#
# CASE PRESERVATION: the lookup below matches the `julia_`/`j_` PREFIX case-
# insensitively and keeps the capture's original casing — a functor is named
# after its TYPE, so capitalisation is the common case, not the exception.
# (Bennett-wh1p later moved `_lookup_callee` onto the same shared demangler,
# `_demangle_llvm_callee`; it used to lowercase the capture.)
#
# Bennett-m5q9: each entry also carries the callable's IDENTITY — its
# `TypeName` — so a demangled hit gets the same root-edge module check as
# `_lookup_callee` (Bennett-p9a0): the bare name alone let a call to an
# unrelated same-named functor in another module emit the registered callee's
# canonical name.
const _known_callee_names = Dict{String, Tuple{Symbol, Core.TypeName}}()   # guarded by _known_callees_lock

"""
    register_callee_name!(llvm_bare::AbstractString, canonical::Symbol, callable_type::Type) -> Nothing

Register an instance-less callable (closure / functor) by NAME. `llvm_bare` is
the bare name Julia's codegen mangles into the LLVM symbol (i.e. `mi.def.name`,
NOT `nameof(type)`); `canonical` is the bare Symbol the emitted `IRCall` should
carry; `callable_type` is the callable's type (any specialisation, or the
`UnionAll`), whose `TypeName` is the identity checked against the root's
`:invoke` edges on lookup. Re-registering the same callable is a no-op; a
different callable or canonical under an already-registered name throws
(Bennett-m5q9). See this file's Bennett-40ys section for why a name-only
registry is needed and why it is separate from `_known_callees`.
"""
function register_callee_name!(llvm_bare::AbstractString, canonical::Symbol,
                               callable_type::Type)
    name = String(llvm_bare)
    callable_type isa DataType && isdefined(callable_type, :instance) && throw(ArgumentError(
        "register_callee_name!: $callable_type has an instance; register the callable " *
        "with `register_callee!` instead (Bennett-m5q9)."))
    entry = (canonical, Base.typename(callable_type))
    changed = lock(_known_callees_lock) do
        prev = get(_known_callee_names, name, nothing)
        prev === nothing || prev == entry || throw(ArgumentError(
            "register_callee_name!: cannot register $(_callee_identity_qual(entry[2])) as " *
            "`$name` => :$canonical — the name is already registered to " *
            "$(_callee_identity_qual(prev[2])) => :$(prev[1]). LLVM call symbols " *
            "(`j_$(name)_<NNN>`) carry no module, so two callables cannot share the " *
            "name (Bennett-m5q9); rename one of them."))
        prev == entry && return false
        _known_callee_names[name] = entry
        return true
    end
    changed && _callee_registry_changed!()   # Bennett-7q9z
    return nothing
end

"""
    _lookup_callee_name(llvm_name::String) -> Union{Symbol, Nothing}

Name-registry counterpart of [`_lookup_callee`](@ref): exact match first, then
the `julia_<name>_<NNN>` / `j_<name>_<NNN>` demangle. CASE-PRESERVING (see the
section comment above). Returns the canonical bare callee Symbol, or `nothing`.
Under a Julia root, a demangled hit must be the callable the root's `:invoke`
edges name (Bennett-m5q9, the same check as `_lookup_callee`'s Bennett-p9a0).
"""
function _lookup_callee_name(llvm_name::String)
    entry, fname = lock(_known_callees_lock) do
        haskey(_known_callee_names, llvm_name) &&
            return (_known_callee_names[llvm_name], nothing)
        # Case-INSENSITIVE on the `julia_`/`j_` prefix only; the capture keeps
        # the original casing (Bennett-40ys — a functor is named after its type).
        fname = _demangle_llvm_callee(llvm_name)
        fname !== nothing && haskey(_known_callee_names, fname) &&
            return (_known_callee_names[fname], fname)
        return (nothing, nothing)
    end
    entry === nothing && return nothing
    root = _CALLEE_ROOT[]
    fname === nothing || root === nothing ||
        _check_callee_identity(root, llvm_name, fname, entry[2], "Bennett-m5q9")
    return entry[1]
end

# ---- value identity via C pointer ----

const _LLVMRef = LLVM.API.LLVMValueRef

# Auto-name counter (passed as argument, not global state)
function _auto_name(counter::Ref{Int})
    counter[] += 1
    Symbol("__v$(counter[])")
end

