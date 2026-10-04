# test_cohv_loop_held_ptr.jl — Bennett-cohv (review 2 finding S2, 2026-10-03).
#
# THE BUG. Bennett-i5zn holds every load-dependent header value that is used
# after the loop at its exit-visit value (`_loop_hold!` in
# src/lowering/cfg.jl). For a POINTER that is not enough: loads and stores
# through a provenance-carrying pointer never read its value wires, they
# follow `ptr_provenance[p]` — per origin an alloca, an element-index OPERAND
# and a selection-predicate WIRE. The index operand is an SSA name resolved
# lazily against the value map, and the predicate wire is whatever the last
# replay computed. After the loop both belong to the LAST unrolled replay of
# the header (or the s0tn check-only pass), not to the header visit that
# really exited, so an exit-block load / store through `p` used the post-exit
# address. Review witness: (20, true) where the source returns 10.
#
# THE FIX holds each escaping pointer's per-origin index wires and predicate
# wire (under `active_k`, like the value hold) and publishes a provenance that
# names the held wires. Kinds covered: one origin with a runtime index, a
# select of two allocas (constant indices, held predicates), a select of two
# arrays with a runtime index, a GEP-of-GEP composed index, and a header-phi
# index (pure: NOT held, gates pinned unchanged). An alloca made inside the
# loop cannot escape soundly; it is already refused loud before the hold.
#
# THE ORACLE is `_cohv_interp`, an independent interpreter of the UInt8
# ParsedIR fixtures with real arrays (a pointer is (alloca, element index)).
# Every fixture: all 256 inputs, fold_constants off and on, K below / at /
# above the trip count; inputs whose header visits exceed K+1 must be refused
# by the Bennett-s0tn guard; `verify_reversibility` on every circuit whose K
# covers every input. The checker also records whether each exit-visit class
# (first visit, visit K, the (K+1)-th convergence pass) was exercised.

using Test
using Bennett
using Bennett: IRInst, IRBasicBlock, IRAlloca, IRStore, IRLoad, IRBinOp, IRICmp,
    IRPhi, IRBranch, IRRet, IRSelect, IRPtrOffset, IRVarGEP, ParsedIR,
    SSAOperand, ssa, iconst

const _COHV_XS = typemin(Int8):typemax(Int8)
const _COHV_FOLDS = (false, true)
_cohv_u(x::Int8) = reinterpret(UInt8, x)

# ---- independent reference interpreter (8-bit elements only) ----
function _cohv_interp(p::ParsedIR, x::UInt8; fuel::Int=100_000)
    env = Dict{Symbol,Any}(p.args[1][1] => x)
    mem = Dict{Tuple{Symbol,Int},UInt8}()
    size = Dict{Symbol,Int}()
    blocks = Dict(b.label => b for b in p.blocks)
    visits = Dict{Symbol,Int}()
    val(op) = op isa SSAOperand ? env[op.name] : UInt8(mod(op.value, 256))
    addr(op) = (q = val(op); (0 <= q[2] < size[q[1]]) || error("interp: OOB $q"); q)
    binop(op, a, b) = op === :add ? a + b : op === :sub ? a - b :
                      op === :mul ? a * b : op === :and ? a & b :
                      op === :or  ? a | b : op === :xor ? a ⊻ b :
                      op === :lshr ? (b < 8 ? a >> b : 0x00) :
                      error("interp: binop $op")
    icmp(pr, a, b) = pr === :eq ? a == b : pr === :ne ? a != b :
                     pr === :ult ? a < b : pr === :uge ? a >= b :
                     error("interp: icmp $pr")
    prev = nothing
    cur = p.blocks[1]
    while true
        (fuel -= 1) > 0 || error("interp: out of fuel")
        visits[cur.label] = get(visits, cur.label, 0) + 1
        phivals = [(i.dest, val(first(v for (v, b) in i.incoming if b == prev)))
                   for i in cur.instructions if i isa IRPhi]
        for (d, v) in phivals
            env[d] = v
        end
        for i in cur.instructions
            if i isa IRPhi
            elseif i isa IRAlloca
                size[i.dest] = i.n_elems.value
                env[i.dest] = (i.dest, 0)
            elseif i isa IRStore
                mem[addr(i.ptr)] = val(i.val)
            elseif i isa IRLoad
                env[i.dest] = mem[addr(i.ptr)]
            elseif i isa IRPtrOffset
                b = val(i.base); env[i.dest] = (b[1], b[2] + i.offset_bytes)
            elseif i isa IRVarGEP
                b = val(i.base); env[i.dest] = (b[1], b[2] + Int(val(i.index)))
            elseif i isa IRBinOp
                env[i.dest] = binop(i.op, val(i.op1), val(i.op2))
            elseif i isa IRICmp
                env[i.dest] = icmp(i.predicate, val(i.op1), val(i.op2))
            elseif i isa IRSelect
                env[i.dest] = val(i.cond) ? val(i.op1) : val(i.op2)
            else
                error("interp: unsupported $(typeof(i))")
            end
        end
        t = cur.terminator
        t isa IRRet && return (val(t.op), visits)
        nxt = t.cond === nothing ? t.true_label :
              (val(t.cond) ? t.true_label : t.false_label)
        prev = cur.label
        cur = blocks[nxt]
    end
end

"""
    _cohv_check(p, Ks; fold) -> Set{Symbol}

Every input, every K, against `_cohv_interp`. Returns the exit-visit classes
exercised by a converging input: `:first` (exits on header visit 1), `:at_K`
(visit K) and `:conv` (visit K+1, the s0tn check-only pass), plus `:loud` when
an under-K input was refused by the guard.
"""
function _cohv_check(p::ParsedIR, Ks; fold::Bool, header::Symbol=:h)
    seen = Set{Symbol}()
    for K in Ks
        c = reversible_compile(p; max_loop_iterations=K, fold_constants=fold)
        bad = Any[]
        all_converge = true
        for x in _COHV_XS
            want, visits = _cohv_interp(p, _cohv_u(x))
            hv = get(visits, header, 0)
            if hv <= K + 1
                hv == 1 && push!(seen, :first)
                hv == K && push!(seen, :at_K)
                hv == K + 1 && push!(seen, :conv)
                got = try
                    UInt8(mod(Int(simulate(c, x)), 256))
                catch e
                    sprint(showerror, e)
                end
                got == want || push!(bad, (K=K, x=x, want=want, got=got))
            else
                all_converge = false
                msg = try
                    simulate(c, x); "no error"
                catch e
                    sprint(showerror, e)
                end
                if occursin("did not converge", msg) && occursin("max_loop_iterations=$K", msg)
                    push!(seen, :loud)
                else
                    push!(bad, (K=K, x=x, want=:loud, got=msg))
                end
            end
        end
        isempty(bad) || @info "cohv mismatches (K=$K, fold=$fold)" length(bad) first(bad, 4)
        @test length(bad) == 0
        all_converge && @test verify_reversibility(c)
    end
    return seen
end

# ---- fixtures ----

# The review's witness, VERBATIM: index cell toggles 0 → 1 in the header, the
# pointer `p = &a[v]` is formed from the PRE-toggle index, the loop exits on its
# first visit, and the exit block loads through `p` (slot 0 = 10).
function _cohv_witness()
    ParsedIR(8, [(:x, 8)], [
        IRBasicBlock(:entry, IRInst[
            IRAlloca(:a, 8, iconst(4)),
            IRStore(ssa(:a), iconst(10), 8),
            IRPtrOffset(:a1, ssa(:a), 1, 8),
            IRStore(ssa(:a1), iconst(20), 8),
            IRAlloca(:idx, 8, iconst(1)),
            IRStore(ssa(:idx), iconst(0), 8),
        ], IRBranch(nothing, :h, nothing)),
        IRBasicBlock(:h, IRInst[
            IRLoad(:v, ssa(:idx), 8),
            IRVarGEP(:p, ssa(:a), ssa(:v), 8),
            IRBinOp(:next, :xor, ssa(:v), iconst(1), 8),
            IRStore(ssa(:idx), ssa(:next), 8),
            IRICmp(:done, :eq, ssa(:x), ssa(:x), 8),
        ], IRBranch(ssa(:done), :exit, :h)),
        IRBasicBlock(:exit, IRInst[
            IRLoad(:r, ssa(:p), 8),
        ], IRRet(ssa(:r), 8)),
    ], [8])
end

# Shared entry: a 4-slot array `a` with x-dependent, mostly distinct slots, a
# second 4-slot array `b`, an index cell `idx` (seeded `seed`), a flag cell `f`
# (seeded x & 1) and the trip count `n` (header visits = n + 1).
function _cohv_entry(; seed::Symbol, n::Symbol)
    IRInst[
        IRAlloca(:a, 8, iconst(4)),
        IRStore(ssa(:a), ssa(:x), 8),
        IRPtrOffset(:a1, ssa(:a), 1, 8),
        IRBinOp(:s1, :xor, ssa(:x), iconst(90), 8), IRStore(ssa(:a1), ssa(:s1), 8),
        IRPtrOffset(:a2, ssa(:a), 2, 8),
        IRBinOp(:s2, :add, ssa(:x), iconst(77), 8), IRStore(ssa(:a2), ssa(:s2), 8),
        IRPtrOffset(:a3, ssa(:a), 3, 8),
        IRBinOp(:s3, :xor, ssa(:x), iconst(-61), 8), IRStore(ssa(:a3), ssa(:s3), 8),
        IRAlloca(:b, 8, iconst(4)),
        IRBinOp(:t0, :add, ssa(:x), iconst(1), 8), IRStore(ssa(:b), ssa(:t0), 8),
        IRPtrOffset(:b1, ssa(:b), 1, 8),
        IRBinOp(:t1, :xor, ssa(:x), iconst(53), 8), IRStore(ssa(:b1), ssa(:t1), 8),
        IRPtrOffset(:b2, ssa(:b), 2, 8),
        IRBinOp(:t2, :add, ssa(:x), iconst(-116), 8), IRStore(ssa(:b2), ssa(:t2), 8),
        IRPtrOffset(:b3, ssa(:b), 3, 8),
        IRBinOp(:t3, :xor, ssa(:x), iconst(-103), 8), IRStore(ssa(:b3), ssa(:t3), 8),
        IRBinOp(:x2, :lshr, ssa(:x), iconst(2), 8),
        IRBinOp(:i0, :and, ssa(:x2), iconst(3), 8),
        IRBinOp(:j0, :and, ssa(:x2), iconst(1), 8),
        IRAlloca(:idx, 8, iconst(1)), IRStore(ssa(:idx), ssa(seed), 8),
        IRAlloca(:f, 8, iconst(1)),
        IRBinOp(:f0, :and, ssa(:x), iconst(1), 8), IRStore(ssa(:f), ssa(:f0), 8),
        IRBinOp(:x4, :lshr, ssa(:x), iconst(4), 8),
        IRBinOp(n, :and, ssa(:x4), iconst(3), 8),
    ]
end

# Header prologue: counter phi + the exit test on it (trip count n).
_cohv_counter() = (IRPhi(:i, 8, [(iconst(0), :entry), (ssa(:i2), :h)]),)
_cohv_exit_test() = IRInst[
    IRBinOp(:i2, :add, ssa(:i), iconst(1), 8),
    IRICmp(:done, :uge, ssa(:i), ssa(:n), 8),
]

# Exit block that READS every slot of a and b after `stmts` (mostly a store
# through the escaping pointer) — weights make a store to the wrong slot visible.
function _cohv_sum_exit(stmts::Vector{IRInst})
    insts = copy(stmts)
    acc = nothing
    for (k, (ptr, w)) in enumerate(((:a, 1), (:a1, 3), (:a2, 5), (:a3, 7),
                                    (:b, 9), (:b1, 11), (:b2, 13), (:b3, 15)))
        push!(insts, IRLoad(Symbol(:ld, k), ssa(ptr), 8))
        push!(insts, IRBinOp(Symbol(:m, k), :mul, ssa(Symbol(:ld, k)), iconst(w), 8))
        if acc === nothing
            acc = Symbol(:m, k)
        else
            push!(insts, IRBinOp(Symbol(:acc, k), :add, ssa(acc), ssa(Symbol(:m, k)), 8))
            acc = Symbol(:acc, k)
        end
    end
    return insts, acc
end

# The header steps the index cell (`step`: :inc4 → (v+1)&3, :tog → v⊻1) and
# toggles the flag cell; `ptr` builds the escaping pointer from the PRE-update
# loads `v` (index) and `w` (flag).
function _cohv_loop(ptr::Vector{IRInst}; exit::Symbol=:load, seed::Symbol=:i0,
                    step::Symbol=:inc4, escaping::Symbol=:p)
    stepinst = step === :inc4 ?
        IRInst[IRBinOp(:v1, :add, ssa(:v), iconst(1), 8),
               IRBinOp(:nv, :and, ssa(:v1), iconst(3), 8)] :
        IRInst[IRBinOp(:nv, :xor, ssa(:v), iconst(1), 8)]
    header = IRInst[_cohv_counter()...,
                    IRLoad(:v, ssa(:idx), 8), IRLoad(:w, ssa(:f), 8),
                    IRICmp(:c, :eq, ssa(:w), iconst(0), 8),
                    ptr..., stepinst...,
                    IRStore(ssa(:idx), ssa(:nv), 8),
                    IRBinOp(:nw, :xor, ssa(:w), iconst(1), 8),
                    IRStore(ssa(:f), ssa(:nw), 8),
                    _cohv_exit_test()...]
    exitinsts, ret = if exit === :load
        (IRInst[IRLoad(:r, ssa(escaping), 8)], :r)
    else
        _cohv_sum_exit(IRInst[IRBinOp(:sv, :xor, ssa(:x), iconst(-18), 8),
                              IRStore(ssa(escaping), ssa(:sv), 8)])
    end
    ParsedIR(8, [(:x, 8)], [
        IRBasicBlock(:entry, _cohv_entry(; seed, n=:n), IRBranch(nothing, :h, nothing)),
        IRBasicBlock(:h, header, IRBranch(ssa(:done), :exit, :h)),
        IRBasicBlock(:exit, exitinsts, IRRet(ssa(ret), 8)),
    ], [8])
end

# Pointer kinds (all built from header loads unless noted):
const _COHV_GEP_V   = IRInst[IRVarGEP(:p, ssa(:a), ssa(:v), 8)]             # 1 origin, runtime idx
const _COHV_SEL     = IRInst[IRSelect(:p, ssa(:c), ssa(:a), ssa(:b), 0)]    # 2 origins, const idx
const _COHV_SEL_GEP = IRInst[IRSelect(:s, ssa(:c), ssa(:a), ssa(:b), 0),    # 2 origins, runtime idx
                             IRVarGEP(:p, ssa(:s), ssa(:v), 8)]
const _COHV_GEP_OFF = IRInst[IRVarGEP(:q, ssa(:a), ssa(:v), 8),             # GEP-of-GEP: composed idx
                             IRPtrOffset(:p, ssa(:q), 2, 8)]
const _COHV_PHI_GEP = IRInst[IRVarGEP(:p, ssa(:a), ssa(:i), 8)]             # idx = header phi (pure)
const _COHV_SEL_PHI = IRInst[IRSelect(:s, ssa(:c), ssa(:a), ssa(:b), 0),    # loaded cond, phi idx
                             IRVarGEP(:p, ssa(:s), ssa(:i), 8)]

const _COHV_KS = 1:5     # trip counts 0..3 → header visits 1..4

# Gate totals of the pure escaping-pointer fixture (load exit fold=false, store
# exit fold=true, K=4) measured on main BEFORE Bennett-cohv: a pointer that is
# not load-tainted is never held, so these must not move.
# Bennett-0a6f (0abc3d1, 2026-10-04) moved the FIRST pin 10021 → 12653, by
# design: an inlined callee is now lowered under its caller's options, so the
# explicit `fold_constants=false` of that cell reaches the runtime-index MUX
# callee as well (git bisect over 2ab3748..5c8f465: 0abc3d1 is the first commit
# with 12653; the fold=true pin, 6459, did not move). Nothing about holding
# changed: the pointer is still not held (see the hold-set testset above).
const _COHV_PURE_PIN = (12653, 6459)

@testset "Bennett-cohv: an escaping loop-header pointer keeps its exit-visit address" begin

    @testset "review S2 witness verbatim (K=2): (10, true)" begin
        for fold in _COHV_FOLDS
            c = reversible_compile(_cohv_witness(); max_loop_iterations=2, fold_constants=fold)
            @test Int(simulate(c, UInt8(0))) == 10
            @test verify_reversibility(c)
        end
        @test _cohv_check(_cohv_witness(), 1:4; fold=false) ⊇ Set([:first])
        @test _cohv_check(_cohv_witness(), 1:4; fold=true) ⊇ Set([:first])
    end

    exit_classes = Set([:first, :at_K, :conv, :loud])
    for (name, ptr, kw) in (
            ("1 origin, runtime idx", _COHV_GEP_V, (;)),
            ("1 origin, runtime idx, toggled index", _COHV_GEP_V, (; seed=:j0, step=:tog)),
            ("select of two allocas by a loaded cond", _COHV_SEL, (;)),
            ("select of two arrays, runtime idx", _COHV_SEL_GEP, (;)),
            ("GEP-of-GEP composed runtime idx", _COHV_GEP_OFF, (; seed=:j0, step=:tog)),
            ("idx = header phi (pure, not held)", _COHV_PHI_GEP, (;)),
            ("loaded select, idx = header phi", _COHV_SEL_PHI, (;)))
        for exit in (:load, :store), fold in _COHV_FOLDS
            @testset "$name — exit $exit — fold=$fold" begin
                seen = _cohv_check(_cohv_loop(ptr; exit, kw...), _COHV_KS; fold)
                @test seen == exit_classes
            end
        end
    end

    @testset "hold set: the escaping pointer is held iff it depends on a load" begin
        hs(p) = (h = only(b for b in p.blocks if b.label == :h);
                 Bennett._loop_header_hold_set(h, Symbol[],
                                               Dict(b.label => b for b in p.blocks)))
        @test hs(_cohv_loop(_COHV_GEP_V)) == [:p]
        @test hs(_cohv_loop(_COHV_SEL_GEP)) == [:p]
        @test isempty(hs(_cohv_loop(_COHV_PHI_GEP)))
    end

    # A pure-index escaping pointer is recomputed bit-for-bit by every replay
    # and is not held: its gate count is the pre-cohv one.
    @testset "pure escaping pointer: gates unchanged" begin
        for (exit, fold, want) in ((:load, false, _COHV_PURE_PIN[1]),
                                   (:store, true, _COHV_PURE_PIN[2]))
            c = reversible_compile(_cohv_loop(_COHV_PHI_GEP; exit);
                                   max_loop_iterations=4, fold_constants=fold)
            @test gate_count(c).total == want
        end
    end

    # An alloca made INSIDE the loop is re-made by every replay, so a pointer
    # into it cannot escape soundly. Today the loop lowering refuses any header
    # alloca before the hold is reached (the alloca's entry-predicate lookup
    # runs in the iteration-local ctx, which has no entry predicate); pin that
    # it stays LOUD, whichever guard fires.
    @testset "loud: a header alloca escaping the loop" begin
        p = ParsedIR(8, [(:x, 8)], [
            IRBasicBlock(:entry, IRInst[
                IRAlloca(:f, 8, iconst(1)), IRStore(ssa(:f), ssa(:x), 8),
                IRBinOp(:n, :and, ssa(:x), iconst(3), 8),
            ], IRBranch(nothing, :h, nothing)),
            IRBasicBlock(:h, IRInst[
                _cohv_counter()...,
                IRAlloca(:t, 8, iconst(1)),
                IRLoad(:w, ssa(:f), 8),
                IRStore(ssa(:t), ssa(:w), 8),
                IRBinOp(:nw, :add, ssa(:w), iconst(1), 8),
                IRStore(ssa(:f), ssa(:nw), 8),
                _cohv_exit_test()...,
            ], IRBranch(ssa(:done), :exit, :h)),
            IRBasicBlock(:exit, IRInst[IRLoad(:r, ssa(:t), 8)], IRRet(ssa(:r), 8)),
        ], [8])
        err = try
            reversible_compile(p; max_loop_iterations=4); nothing
        catch e
            e
        end
        @test err isa Union{ArgumentError,AssertionError}
        @test err !== nothing && occursin(r"alloca|predicate", sprint(showerror, err))
    end
end
