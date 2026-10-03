# ---- known callee registry for gate-level inlining ----

const _known_callees = Dict{String, Function}()
# Bennett-7stg / U26: wrap mutations and lookups in a ReentrantLock.
# Multi-threaded compiles (e.g. parallel Pkg.test workers) could race on
# Dict mutation; the lock makes register_callee! / _lookup_callee safe.
# ReentrantLock allows recursive entry — matters for pathological cases
# where _lookup_callee somehow triggers a register during compilation.
const _known_callees_lock = ReentrantLock()

"""Register a Julia function for gate-level inlining when encountered as an LLVM call."""
function register_callee!(f::Function)
    # Get the LLVM name Julia would give this function (j_name_NNN pattern)
    # We match by substring, so just store the Julia function name
    lock(_known_callees_lock) do
        _known_callees[string(nameof(f))] = f
    end
    return nothing
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
const _parsed_ir_cache = Dict{Tuple{Any, Type, Bool, Symbol, Int}, ParsedIR}()
const _parsed_ir_cache_lock = ReentrantLock()
const _parsed_ir_cache_world = Ref{UInt}(0)
const _PARSED_IR_CACHE_MAX = 256

"""
    _cache_world_gate!(cache, world_ref) -> UInt

Bennett-4ddk: empty `cache` when the global world counter has moved since
`world_ref` was recorded, then return the current world. Call with the
cache's lock held.
"""
function _cache_world_gate!(cache::AbstractDict, world_ref::Base.RefValue{UInt})
    w = Base.get_world_counter()
    if w != world_ref[]
        empty!(cache)
        world_ref[] = w
    end
    return w
end

"""
    _cache_insert_bounded!(cache, key, val, maxlen, world)

Bennett-4ddk: store `key => val` unless the world moved during the
computation of `val` (then the entry's world is ambiguous — skip it), evicting
arbitrary entries first so `length(cache) <= maxlen`. Call with the lock held.
"""
function _cache_insert_bounded!(cache::AbstractDict, key, val, maxlen::Int, world::UInt)
    Base.get_world_counter() == world || return val
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

The key is `(f, arg_types, optimize, mem, bit_width)`; the cache is emptied
whenever the world counter moves (Bennett-4ddk) and holds at most
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
        pir = bit_width > 0 ?
            _narrow_ir(_extract_parsed_ir_cached(f, arg_types; optimize, mem),
                       bit_width) :
            extract_parsed_ir(f, arg_types; optimize, mem)
        return _cache_insert_bounded!(_parsed_ir_cache, key, pir,
                                      _PARSED_IR_CACHE_MAX, w)
    end
end

"""Empty the `_parsed_ir_cache`. For tests, and as a manual escape hatch
after `register_callee!` (a registry change does not move the world, so the
Bennett-4ddk world gate does not see it)."""
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
    lock(_known_callees_lock) do
        # First: try exact match (for hardcoded lookups like "soft_fcmp_ole")
        haskey(_known_callees, llvm_name) && return _known_callees[llvm_name]

        # Second: LLVM-mangled names follow julia_<funcname>_<NNN> or j_<funcname>_<NNN>.
        # Extract the function name (case-preserved, Bennett-wh1p) and do an
        # exact dict lookup.
        fname = _demangle_llvm_callee(llvm_name)
        fname !== nothing && haskey(_known_callees, fname) && return _known_callees[fname]
        return nothing
    end
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
const _known_callee_names = Dict{String, Symbol}()   # guarded by _known_callees_lock

"""
    register_callee_name!(llvm_bare::AbstractString, canonical::Symbol) -> Nothing

Register an instance-less callable (closure / functor) by NAME. `llvm_bare` is
the bare name Julia's codegen mangles into the LLVM symbol (i.e. `mi.def.name`,
NOT `nameof(type)`); `canonical` is the bare Symbol the emitted `IRCall` should
carry. See this file's Bennett-40ys section for why a name-only registry is
needed and why it is separate from `_known_callees`.
"""
function register_callee_name!(llvm_bare::AbstractString, canonical::Symbol)
    lock(_known_callees_lock) do
        _known_callee_names[String(llvm_bare)] = canonical
    end
    return nothing
end

"""
    _lookup_callee_name(llvm_name::String) -> Union{Symbol, Nothing}

Name-registry counterpart of [`_lookup_callee`](@ref): exact match first, then
the `julia_<name>_<NNN>` / `j_<name>_<NNN>` demangle. CASE-PRESERVING (see the
section comment above). Returns the canonical bare callee Symbol, or `nothing`.
"""
function _lookup_callee_name(llvm_name::String)
    lock(_known_callees_lock) do
        haskey(_known_callee_names, llvm_name) && return _known_callee_names[llvm_name]
        # Case-INSENSITIVE on the `julia_`/`j_` prefix only; the capture keeps
        # the original casing (Bennett-40ys — a functor is named after its type).
        fname = _demangle_llvm_callee(llvm_name)
        fname !== nothing && haskey(_known_callee_names, fname) &&
            return _known_callee_names[fname]
        return nothing
    end
end

# ---- value identity via C pointer ----

const _LLVMRef = LLVM.API.LLVMValueRef

# Auto-name counter (passed as argument, not global state)
function _auto_name(counter::Ref{Int})
    counter[] += 1
    Symbol("__v$(counter[])")
end

