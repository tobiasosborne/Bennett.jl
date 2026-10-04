# Bennett-n9o8 — the s0tn loop-convergence guard is gated by the loop header's
# path predicate.
#
# Invariant: the guard can fire only on an execution that actually reaches the
# loop header (block_pred[header] = 1). On an execution that skips the loop the
# unrolled body still runs on its seed values (branchless lowering), its
# convergence bit is garbage, and the guard must stay silent — and the values
# flowing out of the skipped loop must not reach the result. Conversely an
# execution that DOES enter the loop and needs more than K+1 header visits is
# still refused loud (the gating must not create a false negative).
#
# Every fixture is checked on all 256 Int8 inputs at several K against a
# hand-written oracle `(value, header_visits)`; visits == 0 means "loop not
# entered". Inputs with visits ≤ K+1 must simulate to the oracle; the rest must
# raise the s0tn "did not converge … max_loop_iterations=K" error.

using Test
using Bennett
using Bennett: IRInst, IRBasicBlock, IRBinOp, IRICmp, IRPhi, IRBranch, IRRet,
    IRAlloca, IRStore, IRLoad, ParsedIR, ssa, iconst

const _N9O8_XS = typemin(Int8):typemax(Int8)
_n9o8_u(x::Int8) = reinterpret(UInt8, x)
_n9o8_msg(f) = try f(); "no error" catch e; sprint(showerror, e) end

# A counted loop `h` (header-exit form): i from 0, s from `seed`; exits to
# `exit` when i ≥ n, else s += step, i += 1 via body `b`.
function _n9o8_loop(h::Symbol, b::Symbol, exit::Symbol,
                    seeds::Vector{Tuple{Any,Symbol}}, n, step::Int)
    sp, ip, sn, inx, dn = Symbol(h, :_s), Symbol(h, :_i), Symbol(h, :_s2),
                          Symbol(h, :_i2), Symbol(h, :_done)
    pre = unique(last.(seeds))
    [IRBasicBlock(h, IRInst[
         IRPhi(ip, 8, vcat([(iconst(0), p) for p in pre], [(ssa(inx), b)])),
         IRPhi(sp, 8, vcat([(v, p) for (v, p) in seeds], [(ssa(sn), b)])),
         IRICmp(dn, :uge, ssa(ip), n, 8),
     ], IRBranch(ssa(dn), exit, b)),
     IRBasicBlock(b, IRInst[
         IRBinOp(sn, :add, ssa(sp), iconst(step), 8),
         IRBinOp(inx, :add, ssa(ip), iconst(1), 8),
     ], IRBranch(nothing, h, nothing))]
end

# L1 — the loop sits in ONE arm of a branch; the other arm skips it.
#   entry: n = x & 3; br (x < 0) other, h
#   h/b:   s = x + 3n           other: y = x ^ 5
#   exit:  r = phi(s@h, y@other)
function _n9o8_l1()
    ParsedIR(8, [(:x, 8)], [
        IRBasicBlock(:entry, IRInst[
            IRBinOp(:n, :and, ssa(:x), iconst(3), 8),
            IRICmp(:c, :slt, ssa(:x), iconst(0), 8),
        ], IRBranch(ssa(:c), :other, :h)),
        _n9o8_loop(:h, :b, :exit, Tuple{Any,Symbol}[(ssa(:x), :entry)], ssa(:n), 3)...,
        IRBasicBlock(:other, IRInst[IRBinOp(:y, :xor, ssa(:x), iconst(5), 8)],
            IRBranch(nothing, :exit, nothing)),
        IRBasicBlock(:exit, IRInst[
            IRPhi(:r, 8, [(ssa(:h_s), :h), (ssa(:y), :other)]),
        ], IRRet(ssa(:r), 8)),
    ], [8])
end
function _n9o8_l1_oracle(x::Int8)
    u = _n9o8_u(x)
    x < 0 && return (u ⊻ 0x05, 0)
    n = Int(u & 0x03)
    return (UInt8(mod(Int(u) + 3n, 256)), n + 1)
end

# L2 — loop under a nested diamond: header predicate = !(x<0) ∧ (x & 64 ≠ 0).
#   entry: br (x<0) B, A;  A: br (x&64 ≠ 0) h, A2;  h → J;  A2: t = x+1 → J
#   J: r1 = phi(s@h, t@A2) → M;  B: u = x ^ 3 → M;  M: r = phi(r1@J, u@B)
function _n9o8_l2()
    ParsedIR(8, [(:x, 8)], [
        IRBasicBlock(:entry, IRInst[
            IRBinOp(:n, :and, ssa(:x), iconst(3), 8),
            IRICmp(:c1, :slt, ssa(:x), iconst(0), 8),
        ], IRBranch(ssa(:c1), :B, :A)),
        IRBasicBlock(:A, IRInst[
            IRBinOp(:m, :and, ssa(:x), iconst(64), 8),
            IRICmp(:c2, :ne, ssa(:m), iconst(0), 8),
        ], IRBranch(ssa(:c2), :h, :A2)),
        _n9o8_loop(:h, :b, :J, Tuple{Any,Symbol}[(ssa(:x), :A)], ssa(:n), 3)...,
        IRBasicBlock(:A2, IRInst[IRBinOp(:t, :add, ssa(:x), iconst(1), 8)],
            IRBranch(nothing, :J, nothing)),
        IRBasicBlock(:J, IRInst[
            IRPhi(:r1, 8, [(ssa(:h_s), :h), (ssa(:t), :A2)]),
        ], IRBranch(nothing, :M, nothing)),
        IRBasicBlock(:B, IRInst[IRBinOp(:w, :xor, ssa(:x), iconst(3), 8)],
            IRBranch(nothing, :M, nothing)),
        IRBasicBlock(:M, IRInst[
            IRPhi(:r, 8, [(ssa(:r1), :J), (ssa(:w), :B)]),
        ], IRRet(ssa(:r), 8)),
    ], [8])
end
function _n9o8_l2_oracle(x::Int8)
    u = _n9o8_u(x)
    x < 0 && return (u ⊻ 0x03, 0)
    (u & 0x40) == 0 && return (u + 0x01, 0)
    n = Int(u & 0x03)
    return (UInt8(mod(Int(u) + 3n, 256)), n + 1)
end

# L3 — two loops, one in each arm of one branch; each skips on the other side.
#   entry: br (x<0) h1, h2;  h1: s += 3 over n1 = x & 3;  h2: s += 5 over n2 = (x>>2) & 3
#   M: r = phi(s1@h1, s2@h2)
function _n9o8_l3()
    ParsedIR(8, [(:x, 8)], [
        IRBasicBlock(:entry, IRInst[
            IRBinOp(:n1, :and, ssa(:x), iconst(3), 8),
            IRBinOp(:q, :lshr, ssa(:x), iconst(2), 8),
            IRBinOp(:n2, :and, ssa(:q), iconst(3), 8),
            IRICmp(:c, :slt, ssa(:x), iconst(0), 8),
        ], IRBranch(ssa(:c), :h1, :h2)),
        _n9o8_loop(:h1, :b1, :M, Tuple{Any,Symbol}[(ssa(:x), :entry)], ssa(:n1), 3)...,
        _n9o8_loop(:h2, :b2, :M, Tuple{Any,Symbol}[(ssa(:x), :entry)], ssa(:n2), 5)...,
        IRBasicBlock(:M, IRInst[
            IRPhi(:r, 8, [(ssa(:h1_s), :h1), (ssa(:h2_s), :h2)]),
        ], IRRet(ssa(:r), 8)),
    ], [8])
end
function _n9o8_l3_oracle(x::Int8)
    u = _n9o8_u(x)
    if x < 0
        n = Int(u & 0x03);        return (UInt8(mod(Int(u) + 3n, 256)), n + 1)
    else
        n = Int((u >> 2) & 0x03); return (UInt8(mod(Int(u) + 5n, 256)), n + 1)
    end
end

# L4 — input-dependent header predicate from TWO pre-headers with distinct
# seeds (the c6ex predicated multi-preheader seed) plus a path that skips:
#   entry: br (x<0) P1, Q;  Q: br (x & 64 ≠ 0) P2, X;  P1 → h (seed x);
#   P2 → h (seed x+1);  X: v = x ^ 9 → M;  h → M;  M: r = phi(s@h, v@X)
function _n9o8_l4()
    ParsedIR(8, [(:x, 8)], [
        IRBasicBlock(:entry, IRInst[
            IRBinOp(:n, :and, ssa(:x), iconst(3), 8),
            IRICmp(:c1, :slt, ssa(:x), iconst(0), 8),
        ], IRBranch(ssa(:c1), :P1, :Q)),
        IRBasicBlock(:Q, IRInst[
            IRBinOp(:m, :and, ssa(:x), iconst(64), 8),
            IRICmp(:c2, :ne, ssa(:m), iconst(0), 8),
        ], IRBranch(ssa(:c2), :P2, :X)),
        IRBasicBlock(:P1, IRInst[], IRBranch(nothing, :h, nothing)),
        IRBasicBlock(:P2, IRInst[IRBinOp(:x1, :add, ssa(:x), iconst(1), 8)],
            IRBranch(nothing, :h, nothing)),
        _n9o8_loop(:h, :b, :M, Tuple{Any,Symbol}[(ssa(:x), :P1), (ssa(:x1), :P2)],
                   ssa(:n), 3)...,
        IRBasicBlock(:X, IRInst[IRBinOp(:v, :xor, ssa(:x), iconst(9), 8)],
            IRBranch(nothing, :M, nothing)),
        IRBasicBlock(:M, IRInst[
            IRPhi(:r, 8, [(ssa(:h_s), :h), (ssa(:v), :X)]),
        ], IRRet(ssa(:r), 8)),
    ], [8])
end
function _n9o8_l4_oracle(x::Int8)
    u = _n9o8_u(x)
    x >= 0 && (u & 0x40) == 0 && return (u ⊻ 0x09, 0)
    seed = x < 0 ? Int(u) : Int(u) + 1
    n = Int(u & 0x03)
    return (UInt8(mod(seed + 3n, 256)), n + 1)
end

# S5 — the i5zn witness verbatim: a header load/store loop, skipped for x < 0,
# whose exit-block phi reads the held header value. Returns x + 7n, or 99.
function _n9o8_s5()
    ParsedIR(8, [(:x, 8)], [
        IRBasicBlock(:entry, IRInst[
            IRAlloca(:a, 8, iconst(1)),
            IRStore(ssa(:a), ssa(:x), 8),
            IRBinOp(:n, :and, ssa(:x), iconst(3), 8),
            IRICmp(:skip, :slt, ssa(:x), iconst(0), 8),
        ], IRBranch(ssa(:skip), :exit, :h)),
        IRBasicBlock(:h, IRInst[
            IRPhi(:i, 8, [(iconst(0), :entry), (ssa(:i2), :h)]),
            IRLoad(:v, ssa(:a), 8),
            IRBinOp(:v2, :add, ssa(:v), iconst(7), 8),
            IRStore(ssa(:a), ssa(:v2), 8),
            IRBinOp(:i2, :add, ssa(:i), iconst(1), 8),
            IRICmp(:done, :uge, ssa(:i), ssa(:n), 8),
        ], IRBranch(ssa(:done), :exit, :h)),
        IRBasicBlock(:exit, IRInst[
            IRPhi(:r, 8, [(ssa(:v), :h), (iconst(99), :entry)]),
        ], IRRet(ssa(:r), 8)),
    ], [8])
end
function _n9o8_s5_oracle(x::Int8)
    x < 0 && return (UInt8(99), 0)
    u = _n9o8_u(x); n = Int(u & 0x03)
    return (UInt8(mod(Int(u) + 7n, 256)), n + 1)
end

"""
    _n9o8_check(p, oracle, K; fold) -> (n_ok_skipped, n_loud)

Every Int8 input at loop bound `K`. Inputs whose oracle visit count is ≤ K+1
(including 0 = loop skipped) must simulate to the oracle; the rest must fail
loud with the s0tn message. Returns how many skipped-loop inputs were checked
and how many inputs were (correctly) refused, so the caller can assert both
directions were exercised.
"""
function _n9o8_check(p::ParsedIR, oracle, K::Int; fold::Bool)
    c = reversible_compile(p; max_loop_iterations=K, fold_constants=fold)
    bad = Any[]
    nskip = 0; nloud = 0
    for x in _N9O8_XS
        want, visits = oracle(x)
        if visits <= K + 1
            visits == 0 && (nskip += 1)
            got = try
                UInt8(mod(Int(simulate(c, x)), 256))
            catch e
                sprint(showerror, e)
            end
            got == want || push!(bad, (x=x, want=want, got=got))
        else
            msg = _n9o8_msg(() -> simulate(c, x))
            if occursin("did not converge", msg) && occursin("max_loop_iterations=$K", msg)
                nloud += 1
            else
                push!(bad, (x=x, want=:loud, got=msg))
            end
        end
    end
    isempty(bad) || @info "n9o8 mismatches (K=$K, fold=$fold)" length(bad) first(bad, 4)
    @test isempty(bad)
    nloud == 0 && @test verify_reversibility(c)
    return (nskip, nloud)
end

const _N9O8_CASES = [
    ("S5 i5zn witness (header load/store, skip arm)", _n9o8_s5,  _n9o8_s5_oracle),
    ("L1 loop in one arm of a branch",               _n9o8_l1,  _n9o8_l1_oracle),
    ("L2 loop under a nested diamond",               _n9o8_l2,  _n9o8_l2_oracle),
    ("L3 two loops in the two arms",                 _n9o8_l3,  _n9o8_l3_oracle),
    ("L4 two pre-headers + skip path",               _n9o8_l4,  _n9o8_l4_oracle),
]

@testset "Bennett-n9o8: loop guard gated by the header predicate" begin

    @testset "oracle sanity: every fixture has skipped AND entered inputs" begin
        for (_, _, o) in _N9O8_CASES
            vs = [o(x)[2] for x in _N9O8_XS]
            @test any(==(0), vs) || o === _n9o8_l3_oracle   # L3: one loop always runs
            @test maximum(vs) == 4
        end
    end

    @testset "$name — fold=$fold" for (name, mk, oracle) in _N9O8_CASES, fold in (false, true)
        p = mk()
        # K = 1, 2: below the trip count for some ENTERED inputs → those are
        # loud (false-negative direction), while every skipped input is
        # answered (the bug: skipped inputs were refused).
        for K in (1, 2)
            nskip, nloud = _n9o8_check(p, oracle, K; fold)
            @test nloud > 0
            @test nskip > 0 || mk === _n9o8_l3
        end
        # K = 3: every input converges → correct everywhere + reversible.
        _, nloud = _n9o8_check(p, oracle, 3; fold)
        @test nloud == 0
    end

    @testset "L3: each loop's guard fires only for its own arm" begin
        # K=1: arm x<0 refuses n1 = x&3 ≥ 2; arm x≥0 refuses n2 = (x>>2)&3 ≥ 2.
        c = reversible_compile(_n9o8_l3(); max_loop_iterations=1)
        for x in _N9O8_XS
            u = _n9o8_u(x)
            n = x < 0 ? Int(u & 0x03) : Int((u >> 2) & 0x03)
            msg = _n9o8_msg(() -> simulate(c, x))
            if n >= 2
                @test occursin("did not converge", msg)
                @test occursin(x < 0 ? ":h1 " : ":h2 ", msg)
            else
                @test msg == "no error"
            end
        end
    end
end
