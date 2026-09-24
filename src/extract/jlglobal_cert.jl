using LLVM

# ---- Bennett-hsm3: SEMANTIC certification of `jl_global#N` heap literals ----
#
# (+ Bennett-gcf7 D1/D2/D3/D4, Bennett-fnxh / O1; BennettVM ADR 0021 Decision 3
# Amendment B; design: docs/design/hsm3/{proposal_A,proposal_B,
# orchestrator_review}.md.)
#
# WHY THIS FILE EXISTS
#
# Julia's codegen interns EVERY heap-object literal a method references as
#
#     @"jl_global#N"     = private unnamed_addr constant ptr @"jl_global#N.jit"
#     @"jl_global#N.jit" = private alias ptr, inttoptr (i64 K to ptr)
#
# where K is the object's LIVE address in the producing process. That covers a
# `const Ref(…)`, a struct / tuple box, a `String`, an `Array`, a non-empty
# `Memory`, … — and the EMPTY `GenericMemory` singleton (`Memory{T}.instance`,
# what `Int64[]` / `Dict{K,V}()` store), which is the ONLY one the closed-world
# `ptr_cells` model can represent (a length-0 header). Pre-hsm3 the extractor
# certified "is the empty singleton" from the NAME (a `^jl_global#\d+$` regex),
# so `const RI = Ref(42); h3(x) = RI[] + x` read a zero blob and BennettVM
# returned 0 against the oracle 42 — and reversed cleanly (gcf7 D1/D2, executed).
# The "empty-vs-non-empty guard is structural" claim (416r.13) was false: every
# literal has the same opaque alias shape.
#
# THE CLASSIFIER (orchestrator decision 1): a MEMBERSHIP test, NEVER a
# dereference. In the producing session, K is admitted iff K is the address of
# a live empty-GenericMemory singleton, enumerated from the GenericMemory
# TypeName caches (`T.instance`, permanent: rooted by its DataType). We never
# `unsafe_pointer_to_objref(K)`: on the reflection path codegen's temporary
# roots are dropped after emission, and a `.ll` from another process carries
# addresses that mean nothing here. Membership is exactly as precise inside a
# GC-disabled window (two live objects cannot share an address; nothing is
# freed, so no address is reused) and cannot crash on a garbage, foreign or
# freed address.
#
# WHERE IT FAILS (decision 2): certified objects are seeded under an OBJECT key
# `jl_global#N.obj` (never the slot name); every `jl_global` slot load aliases
# onto its object key, certified or not; after the per-function walk,
# `_assert_no_refused_jl_global_use` fails loud on ANY surviving use of a
# refused object, of a raw SLOT name, or of an un-aliased slot-load result. So a
# refused literal that only feeds a dead throw path (the corpus's String
# messages) never walls, and one whose value survives always does.
#
# NAMES ARE NOT EVIDENCE. `_is_jl_global_slot_name` only FINDS candidates; it
# never admits anything.

# The slot-name CANDIDATE finder. `^…$`-anchored: matches the bare module-global
# slot, NOT its `.jit` alias (`_is_jl_global_jit_alias_name`), NOT an object key
# (`.obj` suffix).
_is_jl_global_slot_name(s::AbstractString)::Bool = occursin(r"^jl_global#\d+$", s)
_is_jl_global_jit_alias_name(s::AbstractString)::Bool =
    occursin(r"^jl_global#\d+\.jit$", s)

# The ONLY name IR may use for a certified object (keeps the `jl_global` stem, so
# BennettVM's `test_jlglobal_singleton` key filter and 416r.13 (2) still see it).
_jl_global_objkey(gv::AbstractString)::Symbol = Symbol(gv, ".obj")

"""
    _EMPTY_MEMORY_DATA_SENTINEL

Bennett-hsm3 / gcf7 D3. The value seeded into the DATA-POINTER field (byte-cell
8) of a certified empty-singleton header. Julia's real data pointer is NEVER
null (measured: sysimage singletons point outside the object, fresh ones at
`obj + 16`), so the pre-hsm3 zero was unfaithful for any null compare and was
copied around by 5viz. The sentinel is `GLOBAL_BASE + 2^47` (BennettVM
`GLOBAL_BASE = 2^48`): non-null, identical in every function's copy (so
base-cancelling `ref.ptr - mem.ptr` arithmetic is unchanged), never
allocatable, and inside BennettVM's globals-tier read-window trap band
`[GLOBAL_BASE, TLS_BASE - _TLS_TIER_GUARD)` — an (always-UB) dereference of a
length-0 Memory's data pointer traps loud instead of silently reading
`memory[0]`. Residual (documented, ADR 0021 Amendment B): two DISTINCT empty
singletons share one sentinel data pointer.
"""
const _EMPTY_MEMORY_DATA_SENTINEL = (UInt64(1) << 48) + (UInt64(1) << 47)

# One live empty singleton: its type (diagnostics) and whether its data pointer
# is non-null (always, as measured; kept so the sentinel is not asserted blindly).
struct _EmptyMemoryFact
    type::String
    data_nonnull::Bool
end

# Per-slot certificate. `desc` is the positive description when certified, the
# REFUSAL REASON otherwise. Pure data: no address is kept.
struct _JLGlobalCert
    gv::String
    objkey::Symbol
    certified::Bool
    desc::String
end
const _JLGlobalCerts = Dict{String, _JLGlobalCert}

# Julia internals this file reaches for (Rule 5/9): fail loud, naming VERSION.
function _assert_jl_literal_cert_supported()
    (hasfield(Core.TypeName, :cache) && hasfield(Core.TypeName, :linearcache)) ||
        error("jlglobal_cert.jl: Julia $(VERSION) has no `Core.TypeName.cache` / " *
              "`.linearcache` — the Bennett-hsm3 empty-GenericMemory singleton " *
              "enumeration must be re-derived for this Julia (CLAUDE.md Rule 5/9).")
    return nothing
end

"""
    _live_empty_memory_singletons() -> Dict{UInt64, _EmptyMemoryFact}

Every live empty `GenericMemory` singleton (`T.instance` for each concrete
`T <: GenericMemory` in the GenericMemory TypeName caches), keyed by address.
DEREFERENCE-FREE with respect to any extracted address: it only reads objects
reachable from the type cache. Each singleton is permanent (rooted by its
DataType, allocated once). A missed singleton only fails CLOSED (re-walls);
the self-test guards against a silently empty enumeration.
"""
function _live_empty_memory_singletons()::Dict{UInt64, _EmptyMemoryFact}
    _assert_jl_literal_cert_supported()
    tn = Base.unwrap_unionall(Core.GenericMemory).name
    out = Dict{UInt64, _EmptyMemoryFact}()
    # GOTCHA (measured, Julia 1.12.7): `TypeName.cache` / `.linearcache` are
    # `@atomic` fields, and a precompiled `for c in (tn.cache, tn.linearcache)`
    # threw "TypeError: in new, expected Core.SimpleVector, got a value of type
    # Core.SimpleVector" (a typeassert on an explicit acquire load failed the
    # same way). Reading them with an explicit ordering into an untyped
    # container sidesteps it. The caches also GROW (256 → 2048 slots after
    # `using Bennett`) — never cache their length.
    caches = Any[getfield(tn, :cache, :acquire), getfield(tn, :linearcache, :acquire)]
    for c in caches, i in 1:length(c)
        isassigned(c, i) || continue
        T = c[i]
        (T isa DataType && isconcretetype(T) && isdefined(T, :instance)) || continue
        x = T.instance
        (x isa Core.GenericMemory && length(x) == 0) || error(
            "jlglobal_cert.jl: Julia invariant broken on $(VERSION): `$(T).instance` " *
            "is not an empty GenericMemory (Bennett-hsm3).")
        out[UInt64(UInt(pointer_from_objref(x)))] =
            _EmptyMemoryFact(string(T), getfield(x, :ptr) != C_NULL)
    end
    probe = Memory{UInt8}()
    haskey(out, UInt64(UInt(pointer_from_objref(probe)))) || error(
        "jlglobal_cert.jl: the empty-GenericMemory singleton enumeration missed " *
        "`Memory{UInt8}()` on Julia $(VERSION) — it is broken and must be re-derived " *
        "(Bennett-hsm3; CLAUDE.md Rule 5/9).")
    return out
end

"""
    _gc_pinned(thunk)

Run `thunk()` with the GC disabled (Bennett-hsm3 certification window) and
restore the previous state. The window must contain NO yield point: `GC.enable`
is per-thread state plus a global counter, so a task that migrated threads
inside it would unbalance the counter — asserted loud (Rule 1).
"""
function _gc_pinned(thunk)
    tid = Threads.threadid()
    prev = GC.enable(false)
    try
        return thunk()
    finally
        migrated = Threads.threadid() != tid
        GC.enable(prev)
        migrated && error(
            "jlglobal_cert.jl: the GC-disabled Bennett-hsm3 certification window " *
            "yielded and migrated threads — invariant broken (Rule 1).")
    end
end

# Best-effort DIAGNOSTICS ONLY (never admission): `address => typeof string` for
# every non-isbits literal the inferred source embeds. No extracted address is
# dereferenced: we take the address OF a value we already hold.
function _src_literal_types(src)::Dict{UInt64, String}
    out = Dict{UInt64, String}()
    src isa Core.CodeInfo || return out
    function visit(v, depth::Int)
        depth > 8 && return
        if v isa Expr
            for a in v.args; visit(a, depth + 1); end
        elseif v isa QuoteNode
            visit(v.value, depth + 1)
        elseif v isa Core.ReturnNode
            isdefined(v, :val) && visit(v.val, depth + 1)
        elseif v isa Core.PiNode
            visit(v.val, depth + 1)
        elseif v isa GlobalRef
            val = try
                isconst(v.mod, v.name) ? getglobal(v.mod, v.name) : nothing
            catch e
                e isa InterruptException && rethrow()
                nothing
            end
            val === nothing || visit(val, depth + 1)
        elseif v isa Symbol || v isa Core.SSAValue || v isa Core.Argument ||
               v isa Core.SlotNumber || v isa Type || v isa Core.PhiNode ||
               v isa Core.PhiCNode || v isa Core.UpsilonNode || v isa Module
            return
        elseif !isbits(v)
            a = UInt64(UInt(ccall(:jl_value_ptr, Ptr{Cvoid}, (Any,), v)))
            desc = v isa Core.GenericMemory ? "$(typeof(v)) of length $(length(v))" :
                   string(typeof(v))
            out[a] = desc
        end
    end
    for st in src.code
        visit(st, 0)
    end
    return out
end

# The literal's address from its slot's initializer: follows GlobalAlias →
# `inttoptr (i64 K)` via the existing `_ptr_identity` (constexpr.jl). A String
# result is the refusal reason.
function _jl_global_address(g::LLVM.GlobalVariable)::Union{UInt64, String}
    init = LLVM.API.LLVMGetInitializer(g.ref)
    init == C_NULL && return "the slot has NO initializer (an `external` declaration " *
        "— imaging-mode IR from pkgimage generation / `--image-codegen`, where the " *
        "literal is relocated at load, or a hand-written declaration): there is no " *
        "address to classify"
    id = _ptr_identity(init)
    id === nothing && return "the slot's initializer is not an `inttoptr (i64 K to ptr)` " *
        "address (unreadable / non-address constant)"
    id[1] === :null && return "the slot's initializer is `null`"
    id[1] === :addr || return "the slot's initializer is a named global, not a literal address"
    return id[2]::UInt64
end

"""
    _classify_jl_globals(mod; live, refuse_reason, literal_types) -> _JLGlobalCerts

Certificate for every `jl_global#N` SLOT of `mod`. With `live = false` every
slot is refused with `refuse_reason` (no live producing session ⇒ nothing is
certified). With `live = true` a slot is CERTIFIED iff it is a constant `ptr`
slot whose initializer resolves to an address K that is a member of
`_live_empty_memory_singletons()`. Slots sharing one K share one object key.
"""
function _classify_jl_globals(mod::LLVM.Module; live::Bool,
                              refuse_reason::AbstractString = "",
                              literal_types::Dict{UInt64, String} = Dict{UInt64, String}())::_JLGlobalCerts
    certs = _JLGlobalCerts()
    S = live ? _live_empty_memory_singletons() : nothing
    by_addr = Dict{UInt64, Symbol}()
    refuse(nm, why) = (certs[nm] = _JLGlobalCert(nm, _jl_global_objkey(nm), false, why))
    for g in LLVM.globals(mod)
        nm = LLVM.name(g)
        _is_jl_global_slot_name(nm) || continue
        if !live
            refuse(nm, String(refuse_reason))
            continue
        end
        LLVM.isconstant(g) || (refuse(nm, "the slot is not a `constant` (a writable " *
                                         "slot can be overwritten by the program)"); continue)
        LLVM.global_value_type(g) isa LLVM.PointerType ||
            (refuse(nm, "the slot does not hold a `ptr`"); continue)
        a = _jl_global_address(g)
        a isa String && (refuse(nm, a); continue)
        key = get!(by_addr, a, _jl_global_objkey(nm))
        fact = get(S, a, nothing)
        if fact === nothing
            why = "in the producing session this address is a live heap object that " *
                  "is NOT the empty GenericMemory singleton"
            T = get(literal_types, a, nothing)
            T === nothing || (why *= " — it is a `$(T)` literal")
            certs[nm] = _JLGlobalCert(nm, key, false, why)
        else
            certs[nm] = _JLGlobalCert(nm, key, true, "the empty `$(fact.type)` singleton")
        end
    end
    return certs
end

# Parse `ir` in a private context and classify it (the live producers' path and
# a test hook).
function _classify_jl_globals_ir(ir::AbstractString; live::Bool,
                                 refuse_reason::AbstractString = "",
                                 literal_types::Dict{UInt64, String} = Dict{UInt64, String}())::_JLGlobalCerts
    local certs::_JLGlobalCerts
    LLVM.Context() do _ctx
        mod = parse(LLVM.Module, String(ir))
        try
            certs = _classify_jl_globals(mod; live = live, refuse_reason = refuse_reason,
                                         literal_types = literal_types)
        finally
            dispose(mod)
        end
    end
    return certs
end

const _JLG_NO_SESSION_REASON =
    "no live producing Julia session — this IR was ingested from text/bitcode, " *
    "whose `inttoptr` addresses are meaningless in this process and are never " *
    "classified (BennettVM ADR 0021 Decision 3 Amendment B). Pass " *
    "`jl_globals = :live_session` ONLY for IR that `code_llvm` produced in THIS " *
    "process, while its literals are still alive"

"""
    _live_ir_and_certs(emit, ptr_cells; diag_src = () -> nothing) -> (ir, certs)

The live Julia producers' IR source. Under `ptr_cells`, opens the GC-disabled
window BEFORE emission, emits, and classifies the emitted text inside the same
window (so the object codegen named at K cannot have been freed and its address
reused). `diag_src` optionally supplies the inferred `CodeInfo` for best-effort
diagnostics (only consulted when something was refused). At
`ptr_cells = false` nothing changes: no window, no classification.
"""
function _live_ir_and_certs(emit::Function, ptr_cells::Bool;
                            diag_src::Function = () -> nothing)
    ptr_cells || return (emit(), nothing)
    return _gc_pinned() do
        ir = emit()::String
        certs = _classify_jl_globals_ir(ir; live = true)
        if any(c -> !c.certified, values(certs))
            lt = try
                _src_literal_types(diag_src())
            catch e
                e isa InterruptException && rethrow()
                Dict{UInt64, String}()
            end
            isempty(lt) || (certs = _classify_jl_globals_ir(ir; live = true,
                                                            literal_types = lt))
        end
        (ir, certs)
    end
end

# Inferred source for diagnostics (best effort; same MethodInstance codegen used).
function _diag_src_for_sig(@nospecialize(sig::Type))
    mi = _method_instance_of_sig(sig)
    return Base.Compiler.typeinf_code(
        Base.Compiler.NativeInterpreter(Base.get_world_counter()), mi, true)
end

# `.ll` / `.bc` ingest: the `jl_globals` kwarg.
function _check_jl_globals_kwarg(jl_globals::Symbol)
    jl_globals in (:refuse, :live_session) || throw(ArgumentError(
        "ir_extract.jl: jl_globals=:$(jl_globals) not in (:refuse, :live_session) " *
        "(Bennett-hsm3)"))
    return nothing
end

function _ingest_jl_global_certs(mod::LLVM.Module, ptr_cells::Bool,
                                 jl_globals::Symbol)::Union{Nothing, _JLGlobalCerts}
    _check_jl_globals_kwarg(jl_globals)
    ptr_cells || return nothing
    return _classify_jl_globals(mod; live = (jl_globals === :live_session),
                                refuse_reason = _JLG_NO_SESSION_REASON)
end

# The per-walk certificate (the walker's view): classify with no live session
# when the producer supplied none, and fail loud on a slot the supplied
# certificate does not cover (a producer/walker disagreement — Rule 1).
function _walk_jl_global_certs(mod::LLVM.Module, ptr_cells::Bool,
                               certs::Union{Nothing, _JLGlobalCerts})::_JLGlobalCerts
    ptr_cells || return _JLGlobalCerts()
    certs === nothing && return _classify_jl_globals(mod; live = false,
                                                     refuse_reason = _JLG_NO_SESSION_REASON)
    for g in LLVM.globals(mod)
        nm = LLVM.name(g)
        _is_jl_global_slot_name(nm) && !haskey(certs, nm) && error(
            "ir_extract.jl: Bennett-hsm3 internal: the jl_global certificate has no " *
            "entry for slot `@\"$(nm)\"` of the module being walked — the certified " *
            "IR and the walked IR disagree (Rule 1).")
    end
    return certs
end

# The certified header blob (D3): length@byte-cell 0 = 0, data-ptr@byte-cell 8 =
# the sentinel, ew 8 (the 416r.13 byte-tier layout, unchanged).
function _certified_header_blob(desc_nonnull::Bool = true)::Tuple{Vector{UInt64}, Int}
    blob = zeros(UInt64, 16)
    desc_nonnull && (blob[9] = _EMPTY_MEMORY_DATA_SENTINEL)
    return (blob, 8)
end

function _seed_certified_jl_globals!(globals::Dict{Symbol, Tuple{Vector{UInt64}, Int}},
                                     certs::_JLGlobalCerts)
    for c in values(certs)
        c.certified || continue
        haskey(globals, c.objkey) && continue          # two slots, one object
        globals[c.objkey] = _certified_header_blob(true)
    end
    return globals
end

"""
    _assert_no_refused_jl_global_use(pir, certs, slot_load_dests, fname)

Bennett-hsm3, decision 2: the use-directed backstop, run on EVERY ParsedIR the
walk returns (dict_vm / vec_vm / heap_skel / normal). Fails loud on a surviving
use of (a) a REFUSED literal's object key, (b) a raw SLOT name, or (c) an
un-aliased slot-load result name (a consumer converted before the aliasing
load — block order is not dominance order). Total over IR: every memory access
needs an SSA base or a `.globals` entry, and a refused object has neither.
"""
function _assert_no_refused_jl_global_use(pir::ParsedIR, certs::_JLGlobalCerts,
                                          slot_load_dests::Set{Symbol},
                                          fname::AbstractString)
    isempty(certs) && isempty(slot_load_dests) && return nothing
    uses = compute_ssa_use_counts(pir)
    function first_use(nm::Symbol)
        for b in pir.blocks
            for i in b.instructions
                nm in _ssa_operands(i) && return (b.label, i)
            end
            nm in _ssa_operands(b.terminator) && return (b.label, b.terminator)
        end
        return nothing
    end
    site(nm) = (u = first_use(nm); u === nothing ? "" :
                " First surviving use, in block %$(u[1]): $(u[2]).")
    for c in values(certs)
        if haskey(uses, Symbol(c.gv))
            error("ir_extract.jl: Bennett-hsm3: in @$(fname), the Julia literal SLOT " *
                  "`@\"$(c.gv)\"` itself survives as an SSA value (slot/object " *
                  "confusion — the slot holds the literal's ADDRESS; only a `load ptr` " *
                  "of it yields the object)." * site(Symbol(c.gv)) * " Refusing " *
                  "(CLAUDE.md §1).")
        end
        if !c.certified && haskey(uses, c.objkey)
            error("ir_extract.jl: Bennett-hsm3: in @$(fname), a value read from the " *
                  "interned Julia heap-object literal `@\"$(c.gv)\"` survives into the " *
                  "extracted IR, and that literal is NOT certified as the empty " *
                  "GenericMemory singleton: $(c.desc)." * site(c.objkey) *
                  " Julia names EVERY interned heap literal `jl_global#N` (a const " *
                  "`Ref`, a struct/tuple box, a `String`, an `Array`, a non-empty " *
                  "`Memory`, …); the closed world models only the empty-GenericMemory " *
                  "singleton (a length-0 header), so reading any other literal would " *
                  "read a phantom blob — a silent miscompile (gcf7 D1/D2). Refusing " *
                  "(CLAUDE.md §1; BennettVM ADR 0021 Decision 3 Amendment B).")
        end
        c.certified || haskey(pir.globals, c.objkey) && error(
            "ir_extract.jl: Bennett-hsm3 internal: refused literal `@\"$(c.gv)\"` has a " *
            "`.globals` entry (Rule 1).")
    end
    for d in slot_load_dests
        haskey(uses, d) && error(
            "ir_extract.jl: Bennett-hsm3: in @$(fname), the un-aliased result `%$(d)` " *
            "of a `jl_global` slot load is used before the load was converted (a " *
            "consumer ran ahead of the aliasing load)." * site(d) * " Refusing " *
            "rather than leave a dangling operand (CLAUDE.md §1).")
    end
    return nothing
end

# O1 / Bennett-fnxh: the name of a `jl_global#N.jit` GlobalAlias reached from
# one of `inst`'s RAW operands (directly or inside a ConstantExpr), or nothing.
# Raw C API only: `LLVM.Value` cannot wrap a GlobalAlias (it throws "Unknown
# value kind", which the walk's benign-error swallow would eat — exactly how O1
# silently dropped the instruction).
function _jl_global_jit_alias_operand(inst::LLVM.Instruction)::Union{Nothing, String}
    function scan(ref, depth)
        ref == C_NULL && return nothing
        k = LLVM.API.LLVMGetValueKind(ref)
        if k == LLVM.API.LLVMGlobalAliasValueKind
            nm = unsafe_string(LLVM.API.LLVMGetValueName(ref))
            return _is_jl_global_jit_alias_name(nm) ? nm : nothing
        elseif k == LLVM.API.LLVMConstantExprValueKind && depth < 4
            for j in 0:(Int(LLVM.API.LLVMGetNumOperands(ref)) - 1)
                r = scan(LLVM.API.LLVMGetOperand(ref, j), depth + 1)
                r === nothing || return r
            end
        end
        return nothing
    end
    for i in 0:(Int(LLVM.API.LLVMGetNumOperands(inst.ref)) - 1)
        r = scan(LLVM.API.LLVMGetOperand(inst.ref, i), 0)
        r === nothing || return r
    end
    return nothing
end
