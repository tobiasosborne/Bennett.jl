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
# Module-scoped because registered callees are stable functions in this
# package — the cache is small (one entry per distinct (callee, arg_types)
# pair) and never grows after warm-up. Avoids worsening the LoweringCtx
# back-compat-constructor sprawl tracked in Bennett-ehoa / U43.
#
# Bennett-uiaq: cache key extended to include `optimize` and `mem` so the
# top-level `reversible_compile(f, arg_types)` overload can route its
# `extract_parsed_ir(f, arg_types; optimize, mem)` call through this
# helper and auto-hit the Bennett-sr8v compile cache on repeat calls,
# WITHOUT silently dropping non-default extraction kwargs. The old
# no-kwargs call shape (e.g. src/lowering/call.jl:82) is preserved via
# the kwarg defaults `optimize=true, mem=:auto` — matches the old
# `extract_parsed_ir(f, arg_types)` defaults exactly.
const _parsed_ir_cache = Dict{Tuple{Function, Type, Bool, Symbol}, ParsedIR}()
const _parsed_ir_cache_lock = ReentrantLock()

"""
    _extract_parsed_ir_cached(f, arg_types; optimize=true, mem=:auto) -> ParsedIR

Memoised wrapper over `extract_parsed_ir(f, arg_types; optimize, mem)`.
On a cache hit returns the previously-extracted `ParsedIR` by identity;
on a miss extracts, stores, and returns. `ParsedIR` is immutable and
the lowering pipeline only reads from it, so sharing across compiles
is safe.

The key is `(f, arg_types, optimize, mem)` so distinct extraction
kwargs do not collide on the same cache slot.
"""
function _extract_parsed_ir_cached(f::Function, arg_types::Type{<:Tuple};
                                    optimize::Bool=true,
                                    mem::Symbol=:auto)::ParsedIR
    key = (f, arg_types, optimize, mem)
    lock(_parsed_ir_cache_lock) do
        haskey(_parsed_ir_cache, key) && return _parsed_ir_cache[key]
        pir = extract_parsed_ir(f, arg_types; optimize, mem)
        _parsed_ir_cache[key] = pir
        return pir
    end
end

"""Empty the `_parsed_ir_cache`. For tests, and as a manual escape hatch
if a callee gets redefined (e.g. under Revise) — registered callees in
this package are otherwise stable across the process lifetime."""
function _clear_parsed_ir_cache!()
    lock(_parsed_ir_cache_lock) do
        empty!(_parsed_ir_cache)
    end
    return nothing
end

function _lookup_callee(llvm_name::String)
    lock(_known_callees_lock) do
        # First: try exact match (for hardcoded lookups like "soft_fcmp_ole")
        haskey(_known_callees, llvm_name) && return _known_callees[llvm_name]

        # Second: LLVM-mangled names follow julia_<funcname>_<NNN> or j_<funcname>_<NNN>.
        # Extract the function name and do exact dict lookup.
        lname = lowercase(llvm_name)
        m = match(r"^(?:julia_|j_)(.+)_(\d+)$", lname)
        if m !== nothing
            fname = m.captures[1]
            haskey(_known_callees, fname) && return _known_callees[fname]
        end
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

