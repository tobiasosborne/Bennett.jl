# ---- closed-world Julia multi-IR producer (CW-D1b / bennettvm-416r.11 chunk b) ----
#
# `extract_parsed_ir_set_from_julia(f, argtypes)` is the *closed-world* path to
# SC9 Case B (ADR-0017, SETTLED — do NOT reopen the RevMap alternative): given a
# plain Julia entry `(f, argtypes)`, produce the FULL set of `ParsedIR` bodies
# that BennettVM's multi-function lowering consumes — the root plus every
# transitively-reached helper method — as a `Vector{Pair{Symbol,ParsedIR}}`, the
# exact shape `extract_parsed_ir_set_from_ll` already returns for the C track.
#
# Why this lives apart from `_module_to_parsed_ir_set` (module_walk.jl):
# that walker keys each function by `Symbol(LLVM.name(f))`. On a single LLVM
# module (the C `.ll` track) that name is stable. On the Julia track each callee
# body is extracted from its OWN `code_llvm` module, where Julia mangles the
# entry as `julia_<name>_<NNN>` / `j_<name>_<NNN>` with a per-extraction `_NNN`
# suffix that DRIFTS between processes and even between calls — keying on it
# would violate CLAUDE.md Rule 5 (LLVM IR / mangled names are not a stable API).
# So this producer keys on the *typed call graph's* `specTypes` instead — a
# content-addressed `nameof#<argtype-digest>` canonical Symbol that is
# deterministic across processes (hash of the argtype DataType, NOT objectid).
#
# Closed-world COMPLETENESS (the thing `transitive_callees` deliberately defers,
# per its `_invoke_callees` docstring: it harvests ONLY `:invoke` edges) is
# ENFORCED here at set-assembly: `_closed_world_check!` walks every IRCall in
# every block of every emitted ParsedIR and fails loud (Rule 1) on any callee
# that resolves to neither an in-set body, a throw-leaf, nor a benign intrinsic.
# A real heap/runtime intrinsic surfacing here is CW-D2's domain
# (bennettvm-416r.12) — the message says so, rather than silently dropping it.
#
# CLAUDE.md Rule 9/10 caveat: the producer REGISTERS each discovered Function
# callee via `register_callee!` before extracting any body. Without that, the
# root/body walk hits the Bennett-5oyt / U15 fail-loud guard the instant it sees
# an unregistered in-module call (probe-verified: `root_probe`'s body emits
# `call @j_h_probe_NNN` which U15 rejects pre-registration). Registration makes
# those IRCalls come back as `Function`-callees, which the linkage resolves by
# `nameof`. This mutates the process-global `_known_callees`; that is acceptable
# (registered callees in this package are stable functions) and idempotent.

# Benign LLVM/Julia intrinsic prefixes the closed-world check tolerates on an
# unresolved Symbol callee (memory-range annotations, GC meta-ops, throw
# helpers). DELIBERATELY a small LOCAL copy, NOT the canonical
# `instructions.jl` `benign_prefixes` tuple: CW-D1b is scoped purely additive
# (no edit to instructions.jl). These two lists SHOULD be unified behind one
# shared const in a follow-up (a `_BENIGN_INTRINSIC_PREFIXES` refactor) — until
# then, keep them in sync by hand.
const _D1B_BENIGN_INTRINSIC_PREFIXES = (
    "llvm.lifetime.",
    "llvm.assume",
    "llvm.dbg.",
    "llvm.experimental.noalias.scope.decl",
    "llvm.invariant.start",
    "llvm.invariant.end",
    "llvm.sideeffect",
    "llvm.trap",
    "llvm.debugtrap",
    "j_throw_",
    "ijl_throw",
    "jl_throw",
    "ijl_bounds_error",
    "jl_bounds_error",
    "julia.safepoint",
    "julia.gc_",
    "julia.pointer_from_objref",
    "julia.push_gc_frame",
    "julia.pop_gc_frame",
    "julia.get_gc_frame_slot",
    # Bennett-zf5v / CW-D2: at optimize=false get_pgcstack is the named
    # intrinsic `@julia.get_pgcstack()`, which lowers cleanly to a 64-bit cell
    # IRCall under ptr_cells (it feeds the `gep -152` current_task chain). The
    # cell is MODELED, not dropped — so the surviving IRCall must be tolerated
    # by the closed-world completeness check (it is not an in-set body / throw
    # leaf). Distinct from `julia.gc_` above: that prefix does NOT match
    # `julia.get_pgcstack` (`gc_` vs `get_pg`).
    "julia.get_pgcstack",
)

# CW-D2 / bennettvm-416r.12: modeled heap/runtime intrinsics the closed-world
# check tolerates because BennettVM ingest lowers each to an Intrinsic*. MUST
# mirror BennettVM._HEAP_DISPATCH (src/ir/ingest_call.jl) — tolerate-here ⟺
# ingest-there; machine-checked by the BVM-side equality test. EXACT-name match
# (not prefix): an unknown runtime callee still fails loud.
const _D1B_MODELED_HEAP_INTRINSICS = Set{Symbol}((
    :malloc, :calloc, :realloc, :free, :memset, :memcpy, :memmove,
    :gc_alloc_obj, :jl_alloc_genericmemory_unchecked,
))

# A throw-leaf is a constructor-callee `Type{E}` for some `E <: Exception`
# (e.g. `Type{AssertionError}`, `Type{BoundsError}`). The typed call graph
# bottoms out at these (CW-D1a GATE 4); their *bodies* hit the ptr-width wall in
# extract_parsed_ir (probe-verified: `unsupported LLVM type ... PointerType`), so
# we filter them BEFORE extraction and accept surviving IRCalls to them in the
# closed-world check. `k.parameters[1]` is the `E` inside `Type{E}`.
_is_throw_leaf(k) = k isa Type && k <: Type && (k.parameters[1] <: Exception)

# Recover the callable from a transitive_callees key. `Type{T}` (a constructor
# callee) → the type `T` itself; a singleton `typeof(g)` → the function instance
# `g`. (A `typeof(g)` key has an EMPTY `parameters` SimpleVector, so the naive
# `k.parameters[1]` would BoundsError — dispatch on `Type{<:Type}` vs `Type`
# disambiguates.)
_callable_of_key(k::Type{<:Type}) = k.parameters[1]
_callable_of_key(k::Type)         = k.instance

# Bare (unmangled, un-digested) name of a callee key. Used both for the
# canonical key prefix and for the linkage `bare_to_key` map.
_nameof_of(k::Type{<:Type}) = nameof(k.parameters[1])
_nameof_of(k::Type)         = nameof(k.instance)

# Content-addressed digest of an argtype Tuple, deterministic WITHIN a process
# (Rule 5): `hash(::DataType)` is content-based — same argtypes → same digest in
# this process; `objectid` would drift even within a process. Keys are never
# serialized cross-process, so `hash`'s build-seed variation across processes is
# irrelevant (N2). 8 hex chars is collision-safe at the handful of callees a
# single closed-world set contains (a collision trips the dup-key assert — loud).
_argtype_digest(at) = string(hash(at); base=16)[1:8]

# Canonical set key: `Symbol("<barename>#<digest>")`. The digest is 8 hex chars
# (no `#`), so the LAST `#` always separates barename from digest — recover the
# barename with `rsplit(key, "#"; limit=2)[1]`, NOT `split(...)[1]`, since a
# closure/gensym barename (e.g. `#9`) itself contains `#` (S1). The key never
# matches the mangled `_<NNN>` LLVM suffix, so it stays distinct from LLVM names.
_canonical_callee_key(callee_key, argtypes)::Symbol =
    Symbol(_nameof_of(callee_key), "#", _argtype_digest(argtypes))

# Demangle an LLVM-mangled callee Symbol to its bare name. Reuses the EXACT
# regex from `_lookup_callee` (callees.jl): `julia_<name>_<NNN>` / `j_<name>_<NNN>`
# → `<name>`, dropping the drift-prone `_NNN`. Returns the bare name as a Symbol,
# or `nothing` if the symbol is not in mangled form (e.g. a raw intrinsic name).
function _demangle_callee_symbol(sym::Symbol)
    m = match(r"^(?:julia_|j_)(.+)_(\d+)$", lowercase(String(sym)))
    return m === nothing ? nothing : Symbol(m.captures[1])
end

"""
    _closed_world_check!(out, bare_to_key, throw_leaf_names)

Enforce closed-world COMPLETENESS over the assembled set `out`
(`Vector{Pair{Symbol,ParsedIR}}`): every `IRCall` in every block of every
`ParsedIR` must resolve to one of —

  1. an in-set body (by `nameof`/bare-name via `bare_to_key`),
  2. a known throw-leaf (`throw_leaf_names`), or
  3. a benign intrinsic (`_D1B_BENIGN_INTRINSIC_PREFIXES`).

A `Function` callee resolves by `nameof`. A `Symbol` callee resolves by exact
bare-name, then by demangled bare-name, then throw-leaf, then benign. Anything
unresolved FAILS LOUD (Rule 1) — this is the completeness that
`transitive_callees` defers (`:invoke`-only). A `Function`-callee with a
multi-candidate bare name (same name, different specialisations) also fails loud
(arity-disambiguation is CW-D2's job; we never guess).
"""
function _closed_world_check!(out::Vector{Pair{Symbol,ParsedIR}},
                              bare_to_key::Dict{Symbol,Vector{Symbol}},
                              throw_leaf_names::Set{Symbol})
    in_set_keys = Set(first.(out))
    for (pkey, pir) in out
        for blk in pir.blocks
            for inst in blk.instructions
                inst isa IRCall || continue
                if inst.callee isa Function
                    bare = nameof(inst.callee)
                    cands = get(bare_to_key, bare, Symbol[])
                    if isempty(cands)
                        error("julia_set.jl: _closed_world_check!: closed-world violation in " *
                              "ParsedIR `$(pkey)` — Function callee `$(bare)` is NOT in the set " *
                              "(in-set keys: $(collect(in_set_keys))). transitive_callees harvests " *
                              ":invoke edges only; CW-D2 whitelist not yet built (bennettvm-416r.12).")
                    elseif length(cands) > 1
                        error("julia_set.jl: _closed_world_check!: ambiguous callee `$(bare)` in " *
                              "ParsedIR `$(pkey)` — multiple in-set specialisations $(cands). " *
                              "Arity-matching disambiguation is deferred to CW-D2 (do NOT guess).")
                    end
                    # single candidate → resolved.
                else  # inst.callee isa Symbol
                    sym = inst.callee
                    name = String(sym)
                    # 1. exact in-set key / bare-name hit.
                    (sym in in_set_keys || haskey(bare_to_key, sym)) && continue
                    # 2. demangle + retry.
                    bare = _demangle_callee_symbol(sym)
                    if bare !== nothing && haskey(bare_to_key, bare)
                        continue
                    end
                    # 3. throw-leaf (exact OR demangled).
                    (sym in throw_leaf_names || (bare !== nothing && bare in throw_leaf_names)) && continue
                    # 4. benign intrinsic.
                    any(p -> startswith(name, p), _D1B_BENIGN_INTRINSIC_PREFIXES) && continue
                    # 5. 416r.12: modeled heap/runtime intrinsic (mirrors BVM _HEAP_DISPATCH).
                    (sym in _D1B_MODELED_HEAP_INTRINSICS ||
                     (bare !== nothing && bare in _D1B_MODELED_HEAP_INTRINSICS)) && continue
                    # Unresolved in all paths → fail loud (Rule 1).
                    error("julia_set.jl: _closed_world_check!: closed-world violation in " *
                          "ParsedIR `$(pkey)` — Symbol callee `$(sym)` " *
                          "(demangled bare name: $(bare === nothing ? "<not mangled>" : bare)) " *
                          "resolves to neither an in-set body (keys: $(collect(in_set_keys))), " *
                          "a throw-leaf ($(collect(throw_leaf_names))), nor a benign intrinsic. " *
                          "CW-D2 whitelist not yet built (bennettvm-416r.12); a real heap/runtime " *
                          "intrinsic must be classified there.")
                end
            end
        end
    end
    return nothing
end

"""
    extract_parsed_ir_set_from_julia(f, argtypes::Type{<:Tuple};
            optimize=false, include_root=true, drop_throw_leaves=true,
            on_extract_error=:fail_loud, mem=:auto) -> Vector{Pair{Symbol,ParsedIR}}

Closed-world Julia multi-IR producer (CW-D1b). Walk the typed call graph beneath
`(f, argtypes)` with [`transitive_callees`](@ref), extract the `ParsedIR` body of
the root and every reached helper, and return them as a
`Vector{Pair{Symbol,ParsedIR}}` keyed by drift-free canonical Symbols
(`<barename>#<argtype-digest>`) — the input shape of BennettVM's multi-function
lowering, matching [`extract_parsed_ir_set_from_ll`](@ref).

`f` is left UNTYPED so this accepts the same callee kinds as `extract_parsed_ir`
(a plain `Function` *or* a `Type` constructor like `AssertionError`). It does NOT
route through `_extract_parsed_ir_cached` (which is `f::Function`-keyed and would
MethodError on a constructor key).

Keyword arguments:
- `optimize` (default `false`): body-extraction optimisation level. CW-D1a edges
  are harvested at `optimize=true` internally regardless; bodies are extracted at
  `optimize=false` for predictable IR (CLAUDE.md Rule 5).
- `include_root` (default `true`): PREPEND the root `(f, argtypes)` body
  (entry-first ordering).
- `drop_throw_leaves` (default `true`): drop `Type{<:Exception}` constructor
  callees BEFORE extraction (their bodies hit the ptr-width wall). Their bare
  names are recorded so the closed-world check accepts surviving IRCalls to them.
- `on_extract_error` (default `:fail_loud`): `:fail_loud` rethrows a per-callee
  extraction failure with context naming the canonical key (Rule 1); `:skip`
  records the failure and continues (the honest path for callees blocked on the
  U14 atomic-load / dv1z heterogeneous-sret walls — the accepted closed-world
  runway, cleared by later beads).
- `mem` (default `:auto`): forwarded to each `extract_parsed_ir`.
- `ptr_cells` (default `false`): forwarded to each per-callee/root
  `extract_parsed_ir`. The C-track/Julia-ptr cell model (BVM ADR 0020 D3/D4,
  generalized to Julia ptr args/returns per ADR 0021 Decision 2). When `true`,
  Dict/Memory pointer args and returns are opaque 64-bit VM cells, clearing the
  ptr-RETURN wall for `setindex!`/`rehash!` (Bennett-lf14). Defaults `false` for
  symmetry with `extract_parsed_ir_set_from_ll`; the BennettVM closed-world
  caller passes `ptr_cells=true` explicitly (a later mem=:vm convergence may set
  the default from `mem`). Pointers are NEVER dereferenced — all the cell-model
  fail-louds (first-index≠0, non-struct pointee, non-8-byte-aligned, >2 GEP
  indices) are kept.

Closed-world COMPLETENESS is enforced by `_closed_world_check!`: every emitted
IRCall must resolve in-set, to a throw-leaf, or to a benign intrinsic, else fail
loud (this is the completeness `transitive_callees` defers to D1b/D2).
"""
function extract_parsed_ir_set_from_julia(f, argtypes::Type{<:Tuple};
                                          optimize::Bool=false,
                                          include_root::Bool=true,
                                          drop_throw_leaves::Bool=true,
                                          on_extract_error::Symbol=:fail_loud,
                                          mem::Symbol=:auto,
                                          ptr_cells::Bool=false)
    on_extract_error in (:fail_loud, :skip) || throw(ArgumentError(
        "extract_parsed_ir_set_from_julia: on_extract_error=:$(on_extract_error) " *
        "not in (:fail_loud, :skip)"))

    # (1) single call-graph source — no re-walk.
    callees = transitive_callees(f, argtypes)

    # (2) throw-leaf partition BEFORE extraction.
    throw_leaf_names = Set{Symbol}()
    live_callees = Tuple{Any,DataType}[]
    for (k, at) in callees
        if drop_throw_leaves && _is_throw_leaf(k)
            push!(throw_leaf_names, _nameof_of(k))
        else
            push!(live_callees, (k, at))
        end
    end

    out = Pair{Symbol,ParsedIR}[]
    skipped = Tuple{Symbol,Any}[]   # (canonical_key, exception) — for :skip diagnostics.

    # Local extraction helper honouring on_extract_error.
    function _extract_one(canonical_key::Symbol, callable, at)
        try
            return extract_parsed_ir(callable, at; optimize=optimize, mem=mem, ptr_cells=ptr_cells)
        catch e
            e isa InterruptException && rethrow()
            if on_extract_error === :fail_loud
                error("julia_set.jl: extract_parsed_ir_set_from_julia: extraction FAILED for " *
                      "callee `$(canonical_key)` (callable=$(callable), argtypes=$(at)) — " *
                      "$(sprint(showerror, e)). This is an accepted closed-world wall " *
                      "(e.g. U14 atomic-load / dv1z heterogeneous-sret / U81 ptr-width); " *
                      "pass on_extract_error=:skip to tolerate it (CW-D2 runway).")
            else  # :skip
                push!(skipped, (canonical_key, e))
                return nothing
            end
        end
    end

    # Body extraction needs every live Function callee REGISTERED so the body
    # walk emits Function-callee IRCalls instead of fail-louding at the
    # Bennett-5oyt / U15 unregistered-call guard (probe-verified). But this
    # producer is query-like: registration is an extraction-time mechanism ONLY
    # (the emitted ParsedIRs already carry their IRCall nodes; nothing downstream
    # consults `_known_callees`). So we SNAPSHOT the registry and RESTORE it in a
    # `finally` — leaving NO process-global pollution. Otherwise a later compile
    # in the same process (e.g. the test_bd5f_heap_m4 Dict-rejection tests, which
    # run after this in runtests.jl) could see `setindex!`/`rehash!` spuriously
    # registered and take a different rejection path (Rule 7: interlocked state).
    local _registry_snapshot
    lock(_known_callees_lock) do
        _registry_snapshot = copy(_known_callees)
    end
    _my_registered_keys = String[]   # registry keys THIS call adds (for a scoped restore)
    try
        # Register every live Function callee (idempotent; `Type{T}` constructor
        # callees are not registerable and don't appear as in-module calls).
        for (k, _at) in live_callees
            callable = _callable_of_key(k)
            if callable isa Function
                register_callee!(callable)
                push!(_my_registered_keys, string(nameof(callable)))
            end
        end

        # (3) per-callee extraction.
        for (k, at) in live_callees
            canonical_key = _canonical_callee_key(k, at)
            callable = _callable_of_key(k)
            pir = _extract_one(canonical_key, callable, at)
            pir === nothing && continue
            push!(out, canonical_key => pir)
        end

        # (4) root extraction, PREPEND (entry-first). `f` may be a Function or a
        # Type constructor; `nameof(f)` keys both, so build the canonical key
        # directly (the callee-key helpers expect a `typeof`/`Type{T}` *key*, not
        # the callable itself).
        if include_root
            root_key = Symbol(nameof(f), "#", _argtype_digest(argtypes))
            root_pir = _extract_one(root_key, f, argtypes)
            if root_pir !== nothing
                pushfirst!(out, root_key => root_pir)
            end
        end

        # (5)/(6) canonical keys assigned above; assert NO duplicate keys (Rule 1).
        seen = Set{Symbol}()
        for (key, _pir) in out
            key in seen && error("julia_set.jl: extract_parsed_ir_set_from_julia: duplicate " *
                                 "canonical key `$(key)` — a hash collision or a re-extracted " *
                                 "callee leaked through (Rule 1).")
            push!(seen, key)
        end

        # (7) closed-world completeness check.
        bare_to_key = Dict{Symbol,Vector{Symbol}}()
        for (key, _pir) in out
            # rsplit on the LAST `#`: the 8-hex digest contains no `#`, but a
            # closure/gensym barename (e.g. `#9`) does — split(...)[1] gives "" (S1).
            bare = Symbol(rsplit(String(key), "#"; limit=2)[1])
            push!(get!(bare_to_key, bare, Symbol[]), key)
        end
        _closed_world_check!(out, bare_to_key, throw_leaf_names)

        return out
    finally
        # SCOPED restore: touch ONLY the keys this call registered — restore a
        # prior value if we overwrote one, else delete what we added. Leaves any
        # unrelated/concurrent registration intact, unlike a destructive
        # empty!+merge! (the registry is deliberately race-tolerant-additive —
        # Bennett-7stg / U26 exercises 8-thread register_callee!). (S2)
        lock(_known_callees_lock) do
            for key in _my_registered_keys
                if haskey(_registry_snapshot, key)
                    _known_callees[key] = _registry_snapshot[key]
                else
                    delete!(_known_callees, key)
                end
            end
        end
    end
end
