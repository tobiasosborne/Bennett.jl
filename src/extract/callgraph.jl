# ---- typed call-graph walker (CW-D1a / bennettvm-416r.11 chunk a) ----
#
# The path to SC9 Case B (reversible Dict). To compile a plain Julia function
# that touches a `Dict` into a reversible circuit we first need to know the FULL
# set of helper methods Julia's compiler inlines beneath it at the `:invoke`
# level — `setindex!` → `ht_keyindex2_shorthash!` → `rehash!` → `AssertionError`
# and so on. This file walks the *typed* call graph: it starts from a root
# `(f, argtypes)`, asks Julia's inference for the optimized typed code of every
# reached method, harvests the `:invoke` targets, and transitively closes the
# set. The output (a list of `(callee, argtypes)` pairs) feeds D1b, which
# extracts each callee's *body* for gate-level lowering.
#
# Why introspection and not LLVM here? The call graph is a *typing/inference*
# fact, not an LLVM fact — `Base.code_typed_by_type` already resolved every
# dynamic dispatch into a concrete `:invoke` with a `MethodInstance`. Walking it
# at the LLVM layer would mean re-deriving information inference already has.
# D1b is where LLVM re-enters (per-body extraction). No LLVM.jl usage here.
#
# CLAUDE.md Rule 5/9/10 caveat: `Core.CodeInstance` / `Core.MethodInstance` and
# the `:invoke` Expr shape are Julia *introspection internals*, not a stable
# public API. They are probed-and-verified against live IR (see the CW-D1a REPL
# probe) on Julia 1.12.x; `mi_of` fails LOUD (Rule 1) if a future Julia hands a
# shape it does not recognise, rather than silently mis-walking the graph.

# Rule-1 defensive backstop. The primary terminator is the `visited` fixpoint
# (a finite typed call graph closes); this cap only fires if a Julia-internals
# change makes the walk diverge, so we crash with context instead of hanging.
const _CALLGRAPH_MAX_NODES = 10_000

# `:invoke`'s first arg is the inlining target. Julia >=1.11 hands a
# `Core.CodeInstance` (whose `.def` is the `MethodInstance`); <=1.10 handed the
# `MethodInstance` directly. Normalise both to a `MethodInstance`; anything else
# is an unrecognised Julia-internals shape → fail loud (Rule 1).
mi_of(x::Core.CodeInstance)   = x.def
mi_of(x::Core.MethodInstance) = x
mi_of(@nospecialize x) = error(
    "callgraph.jl: transitive_callees: unexpected :invoke arg-1 type $(typeof(x)) " *
    "(expected Core.CodeInstance on Julia >=1.11 or Core.MethodInstance on <=1.10); " *
    "Julia $(VERSION). Julia introspection internals are not a stable API (CLAUDE.md Rule 5/9) — update mi_of.")

# A specTypes DataType is `Tuple{F, A1, A2, ...}` where `F` is the callee key
# (`typeof(f)` for a plain function, or `Type{T}` for a constructor like
# `AssertionError`) and `A1..` are the argument types. Split it back into the
# `(callee_key, Tuple{argtypes...})` shape callers expect.
_split_spectypes(st::DataType) = (st.parameters[1], Tuple{st.parameters[2:end]...})

# Harvest the direct `:invoke` edges out of one reached specTypes key, as a
# vector of callee specTypes DataTypes. Edges are taken at `optimize=true`:
# inference has by then lowered dynamic dispatch into concrete `:invoke`s, so
# the typed call graph is fully resolved. (At `optimize=false` the body still
# contains generic `:call`s and emits ZERO `:invoke`s — the CW-D1a probe
# confirmed O0 fdict has 0 invokes vs O2's 2; ADR-0021 Decision-1's original
# "O0" claim was materially wrong and is corrected here. Bodies are extracted
# at `optimize=false` — but that is D1b's concern, not this edge walk.)
#
# CLOSED-WORLD BOUNDARY (CW-D1a contract — read before reusing this in D1b/D2):
# this harvests ONLY `:invoke` edges. Non-`:invoke` statements — `:foreigncall` /
# ccall (e.g. `jl_alloc_genericmemory_unchecked`, `_growat!`), dynamic `:call`,
# and `invoke`-of-Builtin — are INTENTIONALLY dropped. `transitive_callees` is a
# typed-callgraph closure, NOT a complete leaf inventory. Runtime intrinsics &
# foreign calls are CW-D2's domain (the intrinsic whitelist), and closed-world
# COMPLETENESS is enforced downstream at D1b/D2 set-assembly: every emitted call
# symbol must resolve in-set or in the CW-D2 whitelist, else fail loud (ADR-0021
# Decision 2). A consumer that treats this set as the complete set of bodies to
# lower would SILENTLY MISS those helpers — so it must not.
function _invoke_callees(st::DataType)
    cinfos = Base.code_typed_by_type(st; optimize=true)
    isempty(cinfos) && error("callgraph.jl: code_typed_by_type returned 0 methods for reached key $st (Rule 1)")
    edges = DataType[]
    for (ci, _rt) in cinfos
        for stmt in ci.code
            stmt isa Expr && stmt.head === :invoke || continue
            mi = mi_of(stmt.args[1])
            push!(edges, mi.specTypes)
        end
    end
    return edges
end

"""
    transitive_callees(f, argtypes::Type{<:Tuple}) -> Vector{Tuple{Any,DataType}}

Walk the typed call graph beneath `(f, argtypes)` and return every
transitively-reached callee as a `(callee_key, Tuple{argtypes...})` pair, in
discovery order, deduplicated, with the ROOT `(f, argtypes)` itself EXCLUDED.

`callee_key` is `typeof(g)` for a plain function `g`, or `Type{T}` for a
type/constructor callee (e.g. `Type{AssertionError}`).

Edges are harvested at `optimize=true` (ADR-0021 Decision-1, *as corrected* —
see this file's `_invoke_callees` docstring: only the optimized typed code
contains the resolved `:invoke`s; the unoptimized body has none). Callee BODY
extraction at `optimize=false` is D1b's job, not this walker's.

The walk terminates on the `visited` fixpoint; a `$(_CALLGRAPH_MAX_NODES)`-node
cap is a Rule-1 backstop against a divergence introduced by future Julia
internals changes. All state is call-local (no module-level caches), so repeated
calls and nested sub-walks never pollute each other.
"""
function transitive_callees(f, argtypes::Type{<:Tuple})
    root = Base.signature_type(f, argtypes)
    visited = Set{DataType}()
    order   = DataType[]
    work    = copy(_invoke_callees(root))
    while !isempty(work)
        st = pop!(work)
        st in visited && continue
        push!(visited, st); push!(order, st)
        length(visited) > _CALLGRAPH_MAX_NODES && error(
            "callgraph.jl: transitive_callees exceeded $_CALLGRAPH_MAX_NODES nodes from root $root (Rule 1)")
        append!(work, _invoke_callees(st))
    end
    return [_split_spectypes(st) for st in order]
end

"""
    _transitive_callee_specTypes(f, argtypes) -> Set{DataType}

Internal helper: the raw transitively-reached callee *specTypes* (the `order`
vector of [`transitive_callees`](@ref) BEFORE `_split_spectypes`), as a Set.
Lets tests compare specTypes directly without round-tripping through the
`(callee, argtypes)` split. Not exported.
"""
function _transitive_callee_specTypes(f, argtypes::Type{<:Tuple})
    root = Base.signature_type(f, argtypes)
    visited = Set{DataType}()
    work    = copy(_invoke_callees(root))
    while !isempty(work)
        st = pop!(work)
        st in visited && continue
        push!(visited, st)
        length(visited) > _CALLGRAPH_MAX_NODES && error(
            "callgraph.jl: _transitive_callee_specTypes exceeded $_CALLGRAPH_MAX_NODES nodes from root $root (Rule 1)")
        append!(work, _invoke_callees(st))
    end
    return visited
end
