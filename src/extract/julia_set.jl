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

"""
    _callee_key_kind(k) -> Symbol

Classify a `transitive_callees` callee key by the shape that determines how its
LLVM IR is obtained. TOTAL over the shapes the walker can produce; every other
input fails loud (Rule 1) naming the key, its `typeof`, why it is unsupported,
and the bead.

  * `:constructor`  — `Type{T}` (e.g. `Type{BoundsError}`); the callable is `T`.
  * `:singleton`    — `typeof(g)` for a plain function `g`; the callable is
                      `g = k.instance`.
  * `:instanceless` — a concrete callable struct type with NO `.instance`:
                      a CLOSURE (`Base.var"#_growend!##0#_growend!##1"{…}`) or a
                      FUNCTOR. It has no value, only a signature; its IR comes
                      from `extract_parsed_ir_by_sig` (Bennett-40ys).

This exists because `.instance` used to be read unconditionally, both here
(`_callable_of_key`) and in the naming helper — so a closure key produced a bare
`UndefRefError: access to undefined reference` with no file, no key and no
context, from a registration loop OUTSIDE any try/catch. Asking "which kind of
key is this?" exactly ONCE makes `.instance` structurally unreachable for
anything but `:singleton`, so that crash cannot recur for ANY key shape.
"""
function _callee_key_kind(@nospecialize k)
    k isa Type || error(
        "julia_set.jl: unsupported transitive_callees callee key `$(k)` " *
        "(typeof = $(typeof(k))): not a Type. Callee keys are `typeof(g)` or " *
        "`Type{T}` (callgraph.jl `_split_spectypes`). Reached from the " *
        "closed-world registration/extraction loop " *
        "(extract_parsed_ir_set_from_julia). Julia $(VERSION). Rule 1: no " *
        "silent skip — extend _callee_key_kind (Bennett-40ys).")
    k <: Type && return :constructor
    isdefined(k, :instance) && return :singleton
    # `Core.OpaqueClosure` is instance-less too, but needs a DIFFERENT codegen
    # entry (`get_oc_code_rt` / the closure's own `.world`, per codeview.jl's
    # OpaqueClosure branch), so the by-signature path would silently emit the
    # wrong thing. Reject BEFORE the generic :instanceless arm — we have no
    # evidence of one in this corpus, and building support speculatively would
    # be guessing (Rule 9).
    k <: Core.OpaqueClosure && error(
        "julia_set.jl: unsupported transitive_callees callee key `$(k)`: " *
        "a Core.OpaqueClosure. OpaqueClosures are instance-less but require a " *
        "different codegen entry point than closures/functors do (the " *
        "by-signature path in sig_llvm.jl reproduces the ORDINARY " *
        "_dump_function branch, not the OpaqueClosure branch), so admitting " *
        "one here would emit the wrong IR. Julia $(VERSION). Rule 1/9: fail " *
        "loud rather than guess (Bennett-40ys).")
    (isconcretetype(k) && isstructtype(k)) && return :instanceless
    error(
        "julia_set.jl: unsupported transitive_callees callee key `$(k)` " *
        "(typeof = $(typeof(k))): not a constructor `Type{T}`, not a singleton " *
        "(`.instance` is undefined), and not a concrete callable struct type " *
        "(isconcretetype=$(isconcretetype(k)), isstructtype=$(isstructtype(k))). " *
        "Reached from the closed-world registration/extraction loop " *
        "(extract_parsed_ir_set_from_julia); the typed call graph produced a key " *
        "this producer cannot turn into codegen input. Julia $(VERSION). Rule 1: " *
        "no silent skip — extend _callee_key_kind (Bennett-40ys).")
end

# Recover the callable VALUE from a transitive_callees key. `Type{T}` (a
# constructor callee) → the type `T` itself; a singleton `typeof(g)` → the
# function instance `g`.
#
# Bennett-40ys: this is now used ONLY for REGISTRATION (`register_callee!` needs
# a `Function` value), never on the extraction path — extraction goes through
# `_callee_key_kind` + `extract_parsed_ir_by_sig`. The `:instanceless` arm fails
# loud rather than reading `.instance`, which is what used to `UndefRefError`.
function _callable_of_key(@nospecialize(k))
    kind = _callee_key_kind(k)
    kind === :constructor && return k.parameters[1]
    kind === :singleton   && return k.instance
    error("julia_set.jl: _callable_of_key: callee key `$(k)` is :$(kind) — it " *
          "has no callable VALUE (a closure / functor is a callable TYPE with " *
          "fields; `.instance` is undefined). Use `_callee_key_kind` and the " *
          "by-signature extraction path instead (Bennett-40ys).")
end

"""
    _callee_barename(k, at::Type{<:Tuple}) -> Symbol

Bare (unmangled, un-digested) name of a callee key — the canonical-key prefix
and the `bare_to_key` linkage name.

The RULE, one line: **the barename is the name Julia's codegen mangles into the
LLVM symbol.** For the two pre-existing arms that is `nameof` of the callable,
unchanged. For an instance-less key it is `mi.def.name` — the METHOD name.

`nameof(k)` is WRONG here and the mistake is easy to make: for a closure it
returns the closure's TYPE name (`#_mk40ys##0#_mk40ys##1`), which matches NO
LLVM symbol, whereas the emitted define is `@"julia_#_mk40ys##0_1531"` — i.e.
`mi.def.name == Symbol("#_mk40ys##0")`. A barename that matches no symbol makes
`_closed_world_check!` report a spurious closed-world violation. (This is the
same reason the singleton arm reads `nameof(k.instance)` and not `nameof(k)`:
`nameof(typeof(g)) == Symbol("#g")`.)

`k.name.singletonname` agrees on 1.12, but `mi.def.name` is what codegen itself
reads, so it is the defensible source and the one fewer version-gated field
(Rule 5). The test cross-checks them.
"""
function _callee_barename(@nospecialize(k), at::Type{<:Tuple})::Symbol
    kind = _callee_key_kind(k)
    kind === :constructor && return nameof(k.parameters[1])
    kind === :singleton   && return nameof(k.instance)
    return _method_instance_of_sig(_spectypes_of(k, at)).def.name
end

# Content-addressed digest of a signature Tuple, deterministic WITHIN a process
# (Rule 5): `hash(::DataType)` is content-based — same signature → same digest in
# this process; `objectid` would drift even within a process. Keys are never
# serialized cross-process, so `hash`'s build-seed variation across processes is
# irrelevant (N2). 8 hex chars is collision-safe at the handful of callees a
# single closed-world set contains (a collision trips the dup-key assert — loud).
#
# `lpad` before slicing: `string(hash(x); base=16)` drops leading zero nibbles,
# so a hash with a high-order zero would `BoundsError` on `[1:8]` (p ≈ 2^-28 per
# call — rare enough to never have been seen, common enough to eventually bite).
_argtype_digest(at) = lpad(string(hash(at); base=16), 16, '0')[1:8]

# Canonical set key: `Symbol("<barename>#<digest>")`. The digest is 8 hex chars
# (no `#`), so the LAST `#` always separates barename from digest — recover the
# barename with `rsplit(key, "#"; limit=2)[1]`, NOT `split(...)[1]`, since a
# closure/gensym barename (e.g. `#9`) itself contains `#` (S1). The key never
# matches the mangled `_<NNN>` LLVM suffix, so it stays distinct from LLVM names.
#
# Bennett-40ys: the digest is taken over the FULL specTypes, not over `argtypes`
# alone. A closure carries all of its state in the callee KEY and has
# `argtypes == Tuple{}`, so an argtypes-only digest is a CONSTANT for every
# closure in the process: `push!(::Vector{Int64})` and `push!(::Vector{Int8})`
# outline to genuinely different `#_growend!##0` bodies that collided onto one
# canonical key and tripped the duplicate-key assert. Digesting the specTypes is
# strictly more correct for EVERY key (the callee key was previously absent from
# the content address entirely), and BennettVM only requires the SHAPE
# `#<8hex>`, never a particular value.
_canonical_callee_key(callee_key, argtypes)::Symbol =
    Symbol(_callee_barename(callee_key, argtypes), "#",
           _argtype_digest(_spectypes_of(callee_key, argtypes)))

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
            push!(throw_leaf_names, _callee_barename(k, at))
        else
            push!(live_callees, (k, at))
        end
    end

    out = Pair{Symbol,ParsedIR}[]
    skipped = Tuple{Symbol,Any}[]   # (canonical_key, exception) — for :skip diagnostics.

    # Local extraction helper honouring on_extract_error. `what` is a short
    # description of the extraction subject for the fail-loud message; `thunk`
    # produces the ParsedIR (by VALUE via `extract_parsed_ir` for a singleton /
    # constructor key, by SIGNATURE via `extract_parsed_ir_by_sig` for an
    # instance-less one — Bennett-40ys).
    function _extract_one(canonical_key::Symbol, what, at, thunk)
        try
            return thunk()
        catch e
            e isa InterruptException && rethrow()
            if on_extract_error === :fail_loud
                error("julia_set.jl: extract_parsed_ir_set_from_julia: extraction FAILED for " *
                      "callee `$(canonical_key)` (callable=$(what), argtypes=$(at)) — " *
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
    #
    # Bennett-40ys: an INSTANCE-LESS callee (closure / functor) has no `Function`
    # value, so it cannot go into `_known_callees` at all. It is registered by
    # NAME instead (`_known_callee_names`), which is what makes the caller's
    # IRCall carry the bare canonical name rather than the mangled, drift-prone
    # `j_<name>_<NNN>` that BennettVM cannot bind. That registry gets the SAME
    # snapshot/scoped-restore discipline (S2), including on the throwing path.
    local _registry_snapshot, _name_registry_snapshot
    lock(_known_callees_lock) do
        _registry_snapshot = copy(_known_callees)
        _name_registry_snapshot = copy(_known_callee_names)
    end
    _my_registered_keys = String[]        # `_known_callees` keys THIS call adds
    _my_registered_names = String[]       # `_known_callee_names` keys THIS call adds
    try
        # Register every live callee, by VALUE where one exists and by NAME
        # otherwise (idempotent; `Type{T}` constructor callees are not
        # registerable and don't appear as in-module calls).
        for (k, at) in live_callees
            if _callee_key_kind(k) === :instanceless
                bare = _callee_barename(k, at)
                register_callee_name!(string(bare), bare)
                push!(_my_registered_names, string(bare))
            else
                callable = _callable_of_key(k)
                if callable isa Function
                    register_callee!(callable)
                    push!(_my_registered_keys, string(nameof(callable)))
                end
            end
        end

        # (3) per-callee extraction. An instance-less key is extracted from its
        # SIGNATURE (there is no value to hand `code_llvm`); every other key
        # keeps the by-value path byte-identically.
        for (k, at) in live_callees
            canonical_key = _canonical_callee_key(k, at)
            pir = if _callee_key_kind(k) === :instanceless
                sig = _spectypes_of(k, at)
                _extract_one(canonical_key, sig, at,
                             () -> extract_parsed_ir_by_sig(sig; optimize=optimize,
                                                            mem=mem, ptr_cells=ptr_cells))
            else
                callable = _callable_of_key(k)
                _extract_one(canonical_key, callable, at,
                             () -> extract_parsed_ir(callable, at; optimize=optimize,
                                                     mem=mem, ptr_cells=ptr_cells))
            end
            pir === nothing && continue
            push!(out, canonical_key => pir)
        end

        # (4) root extraction, PREPEND (entry-first). `f` may be a Function or a
        # Type constructor; `nameof(f)` keys both, so build the canonical key
        # directly (the callee-key helpers expect a `typeof`/`Type{T}` *key*, not
        # the callable itself).
        if include_root
            root_key = Symbol(nameof(f), "#",
                              _argtype_digest(Base.signature_type(f, argtypes)))
            root_pir = _extract_one(root_key, f, argtypes,
                                    () -> extract_parsed_ir(f, argtypes; optimize=optimize,
                                                            mem=mem, ptr_cells=ptr_cells))
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
            # Bennett-40ys: same discipline for the name-only registry.
            for key in _my_registered_names
                if haskey(_name_registry_snapshot, key)
                    _known_callee_names[key] = _name_registry_snapshot[key]
                else
                    delete!(_known_callee_names, key)
                end
            end
        end
    end
end
