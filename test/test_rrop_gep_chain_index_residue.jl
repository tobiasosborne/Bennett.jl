using Test
using Random
using Bennett
using Bennett: ParsedIR, IRBasicBlock, IRInst, IRAlloca, IRPtrOffset, IRStore,
    IRBinOp, IRCast, IRVarGEP, IRLoad, IRRet, ssa, iconst

# Bennett-rrop (review 2, 2026-10-03, finding S1) — regression from 137989d
# (Bennett-gw0r). gw0r composed GEP indices at `max(index_bits(n)+1, operand
# widths)` and sign-extended each operand, including an already-composed index,
# to that width. A composed value is only known modulo its width: a positive i4
# index 6 scaled x2 (i16 GEP on i8 elements) is 12, which in 4 bits reads as -4;
# a later i8 displacement -12 then composed to -16 instead of 0, and the MUX path
# zero-extended that to slot 240 -> last slot. LLVM lets a non-`inbounds` GEP
# chain pass through an out-of-allocation address and come back.
#
# Fix: every composed index is a residue mod 2^(index_bits(n)+1) (64 bits for a
# persistent slab) and is never re-sign-extended; see the invariant at
# `_compose_gep_index!`. gw0r's matrix had one composition step; this file
# checks CHAINS of two and three GEPs: mixed element widths along the chain,
# intermediate displacements that go negative or past the end and come back,
# index operand widths from 2 bits to 64, scaled displacements that overflow
# their operand's signed range. Every case runs on all 256 Int8 inputs against
# a byte-level model of LLVM GEP semantics, plus verify_reversibility.

const _RROP_XS = typemin(Int8):typemax(Int8)
_rrop_u(x) = Int(reinterpret(UInt8, x))
# LLVM value of the low w bits read as signed (Int64 arithmetic wraps mod 2^64).
_rrop_sx(v::Int, w::Int) = w >= 64 ? v : (v & ((1 << w) - 1)) - (((v >> (w - 1)) & 1) << w)

_rrop_init(AE, k) = ((k * 0x9E3779B1 + 0x5A + 101 * (k ÷ 256)) & ((1 << AE) - 1))
const _RROP_SENT = 0xA5A5A5A5

# ---- chain description -----------------------------------------------------
# kind :rt     runtime VarGEP, index v = ((x >> sh) & m) * a + c  at IW bits
#      :cancel runtime VarGEP, index v = (x & m) + c - sum_j ext(v_j) * r_j/r
#              at IW bits (cancels every other runtime step, so the final
#              element is r * ((x & m) + c0) whatever the intermediates did)
#      :cgep   constant VarGEP, index K
#      :off    IRPtrOffset by K bytes
struct RropStep
    kind::Symbol
    GE::Int; IW::Int; sh::Int; m::Int; a::Int; c::Int; K::Int
end
struct RropCase
    AE::Int; N::Int
    base::Symbol          # :raw | :zero | :const (B elements)
    B::Int
    steps::Vector{RropStep}
    op::Symbol            # :load | :store (then reload through an independent pointer)
    fold::Bool
end

# Index operand value of every runtime step (LLVM semantics: wrapped at IW).
function _rrop_vals(c::RropCase, x)
    u = _rrop_u(x)
    vals = Dict{Int,Int}()
    for (j, s) in enumerate(c.steps)
        s.kind === :rt && (vals[j] = _rrop_sx(((u >> s.sh) & s.m) * s.a + s.c, s.IW))
    end
    for (j, s) in enumerate(c.steps)
        s.kind === :cancel || continue
        r = s.GE ÷ c.AE
        acc = (u & s.m) + s.c
        for (k, t) in enumerate(c.steps)
            t.kind === :rt && (acc -= _rrop_sx(vals[k], s.IW) * ((t.GE ÷ c.AE) ÷ r))
        end
        vals[j] = _rrop_sx(acc, s.IW)
    end
    return vals
end

# Element displacement (alloca elements) of each step, then partial positions.
function _rrop_positions(c::RropCase, x)
    vals = _rrop_vals(c, x)
    pos = c.base === :const ? c.B : 0
    out = Int[]
    for (j, s) in enumerate(c.steps)
        pos += s.kind in (:rt, :cancel) ? vals[j] * (s.GE ÷ c.AE) :
               s.kind === :cgep ? s.K * (s.GE ÷ c.AE) : s.K ÷ (c.AE ÷ 8)
        push!(out, pos)
    end
    return out
end
_rrop_valid(c) = all(x -> 0 <= last(_rrop_positions(c, x)) < c.N, _RROP_XS)

function _rrop_oracle(c::RropCase, x)
    e = last(_rrop_positions(c, x))
    c.op === :store && return _RROP_SENT & ((1 << c.AE) - 1)
    return _rrop_init(c.AE, e)
end

# ---- IR builder -----------------------------------------------------------
function _rrop_cast!(insts, dest, src, from, to; signed=true)
    from == to ? push!(insts, IRBinOp(dest, :or, src, iconst(0), to)) :
        push!(insts, IRCast(dest, from > to ? :trunc : signed ? :sext : :zext, src, from, to))
end

function _rrop_ir(c::RropCase)
    AE, N, ab = c.AE, c.N, c.AE ÷ 8
    insts = IRInst[IRAlloca(:a, AE, iconst(N))]
    for k in 0:N-1
        push!(insts, IRPtrOffset(Symbol(:init, k), ssa(:a), k * ab, AE))
        push!(insts, IRStore(ssa(Symbol(:init, k)), iconst(_rrop_init(AE, k)), AE))
    end
    bp = c.base === :raw ? ssa(:a) :
         (push!(insts, IRPtrOffset(:p0, ssa(:a), (c.base === :const ? c.B : 0) * ab, AE)); ssa(:p0))
    v(j) = Symbol(:v, j)
    for (j, s) in enumerate(c.steps)          # runtime :rt index values first
        s.kind === :rt || continue
        push!(insts, IRBinOp(Symbol(:s, j), :lshr, ssa(:x), iconst(s.sh), 8))
        push!(insts, IRBinOp(Symbol(:t, j), :and, ssa(Symbol(:s, j)), iconst(s.m), 8))
        _rrop_cast!(insts, Symbol(:w, j), ssa(Symbol(:t, j)), 8, s.IW; signed=false)
        push!(insts, IRBinOp(Symbol(:y, j), :mul, ssa(Symbol(:w, j)), iconst(s.a), s.IW))
        push!(insts, IRBinOp(v(j), :add, ssa(Symbol(:y, j)), iconst(s.c), s.IW))
    end
    for (j, s) in enumerate(c.steps)          # then the cancelling index
        s.kind === :cancel || continue
        r = s.GE ÷ AE
        push!(insts, IRBinOp(:cm, :and, ssa(:x), iconst(s.m), 8))
        _rrop_cast!(insts, :cmw, ssa(:cm), 8, s.IW; signed=false)
        push!(insts, IRBinOp(:acc0, :add, ssa(:cmw), iconst(s.c), s.IW))
        acc = :acc0
        for (k, t) in enumerate(c.steps)
            t.kind === :rt || continue
            _rrop_cast!(insts, Symbol(:e, k), ssa(v(k)), t.IW, s.IW)
            push!(insts, IRBinOp(Symbol(:f, k), :mul, ssa(Symbol(:e, k)),
                                 iconst((t.GE ÷ AE) ÷ r), s.IW))
            push!(insts, IRBinOp(Symbol(:acc, k), :sub, ssa(acc), ssa(Symbol(:f, k)), s.IW))
            acc = Symbol(:acc, k)
        end
        push!(insts, IRBinOp(v(j), :or, ssa(acc), iconst(0), s.IW))
    end
    p = bp
    for (j, s) in enumerate(c.steps)          # the GEP chain itself
        q = Symbol(:q, j)
        push!(insts, s.kind === :off  ? IRPtrOffset(q, p, s.K, AE) :
                     s.kind === :cgep ? IRVarGEP(q, p, iconst(s.K), s.GE) :
                                        IRVarGEP(q, p, ssa(v(j)), s.GE))
        p = ssa(q)
    end
    if c.op === :load
        push!(insts, IRLoad(:r, p, AE))
    else
        # store through the chain, reload through a[E] with E computed
        # independently at 16 bits (exact mod 2^16 for every in-range E)
        push!(insts, IRStore(p, iconst(_RROP_SENT & ((1 << AE) - 1)), AE))
        cst = (c.base === :const ? c.B : 0) +
              sum((s.kind === :cgep ? s.K * (s.GE ÷ AE) : s.kind === :off ? s.K ÷ ab : 0)
                  for s in c.steps)
        push!(insts, IRBinOp(:E0, :or, iconst(cst), iconst(0), 16))
        acc = :E0
        for (j, s) in enumerate(c.steps)
            s.kind in (:rt, :cancel) || continue
            _rrop_cast!(insts, Symbol(:g, j), ssa(v(j)), s.IW, 16)
            push!(insts, IRBinOp(Symbol(:h, j), :mul, ssa(Symbol(:g, j)), iconst(s.GE ÷ AE), 16))
            push!(insts, IRBinOp(Symbol(:E, j), :add, ssa(acc), ssa(Symbol(:h, j)), 16))
            acc = Symbol(:E, j)
        end
        push!(insts, IRVarGEP(:t, ssa(:a), ssa(acc), AE))
        push!(insts, IRLoad(:r, ssa(:t), AE))
    end
    return ParsedIR(AE, [(:x, 8)], [IRBasicBlock(:entry, insts, IRRet(ssa(:r), AE))], [AE])
end

function _rrop_check(c::RropCase)
    circ = reversible_compile(_rrop_ir(c); fold_constants=c.fold)
    mask = (1 << c.AE) - 1
    bad = [(x, Int(simulate(circ, x)) & mask, _rrop_oracle(c, x))
           for x in _RROP_XS if (Int(simulate(circ, x)) & mask) != _rrop_oracle(c, x)]
    isempty(bad) || @info "rrop mismatch" c first(bad, 3)
    @test isempty(bad)
    @test verify_reversibility(circ)
end

# ---- case generator -----------------------------------------------------------
const _RROP_IWS = (2, 3, 4, 5, 8, 16, 64)

function _rrop_gen_step(rng, AE, kind)
    rs = [r for r in (1, 2, 4, 8) if AE * r <= 64]
    GE = AE * rand(rng, rs)
    IW = rand(rng, _RROP_IWS)
    lim = IW >= 64 ? 1 << 20 : 1 << (IW - 1)
    kind === :rt   && return RropStep(:rt, GE, IW, rand(rng, 0:6), rand(rng, (1, 3, 7, 15)),
                                      rand(rng, -3:3), rand(rng, -lim:lim-1), 0)
    kind === :cgep && return RropStep(:cgep, GE, 0, 0, 0, 0, 0, rand(rng, -40:40))
    return RropStep(:off, AE, 0, 0, 0, 0, 0, (AE ÷ 8) * rand(rng, -300:300))
end

# A chain of `len` GEPs with exactly one cancelling runtime step; nothing when
# no in-range variant was found.
function _rrop_gen(rng, AE, N, len, op)
    for _ in 1:200
        kinds = [rand(rng, (:rt, :rt, :rt, :cgep, :off)) for _ in 1:len]
        kinds[rand(rng, 1:len)] = :cancel
        steps = [k === :cancel ? nothing : _rrop_gen_step(rng, AE, k) for k in kinds]
        base = rand(rng, (:raw, :zero, :const))
        B = base === :const ? rand(rng, -20:N+20) : 0
        rts = [s.GE ÷ AE for s in steps if s !== nothing && s.kind === :rt]
        cdisp = B + sum((s === nothing || s.kind === :rt) ? 0 :
                        s.kind === :cgep ? s.K * (s.GE ÷ AE) : s.K ÷ (AE ÷ 8) for s in steps)
        r = rand(rng, (1, 1, 2, 4))
        AE * r <= 64 && all(q -> q % r == 0, rts) && cdisp % r == 0 || (r = 1)
        m = rand(rng, (0, 1, 3, 7))
        hi = (N - 1) ÷ r - m
        hi >= 0 || continue
        c0 = rand(rng, 0:hi)
        IW = rand(rng, _RROP_IWS)
        cancel = RropStep(:cancel, AE * r, IW, 0, m, 0, c0 - cdisp ÷ r, 0)
        steps = RropStep[s === nothing ? cancel : s for s in steps]
        # A runtime GEP straight off the raw alloca also builds the legacy MUX
        # view, which needs at least one whole GEP element in the allocation
        # (pre-existing DimensionMismatch otherwise; not this bead).
        base === :raw && steps[1].kind in (:rt, :cancel) && steps[1].GE > N * AE && continue
        c = RropCase(AE, N, base, B, steps, op, rand(rng, Bool))
        _rrop_valid(c) && return c
    end
    return nothing
end

# Coverage of the dimension this file exists for.
function _rrop_flags(c::RropCase)
    f = Set{Symbol}()
    for x in _RROP_XS
        ps = _rrop_positions(c, x)
        for p in ps[1:end-1]
            p < 0 && push!(f, :mid_negative)
            p >= c.N && push!(f, :mid_past_end)
        end
        vals = _rrop_vals(c, x)
        for (j, s) in enumerate(c.steps)
            s.kind in (:rt, :cancel) || continue
            d = vals[j] * (s.GE ÷ c.AE)
            s.IW < 64 && d >= (1 << (s.IW - 1)) && push!(f, :scaled_past_signed_range)
            vals[j] < 0 && push!(f, :negative_index)
        end
    end
    count(s -> s.kind in (:rt, :cancel), c.steps) >= 2 && push!(f, :runtime_runtime)
    length(unique(s.GE for s in c.steps if s.kind !== :off)) >= 2 && push!(f, :mixed_elem_widths)
    length(c.steps) == 3 && push!(f, :three_deep)
    return f
end

@testset "Bennett-rrop — GEP chains compose indices as residues" begin

    @testset "S1 witness: i16 GEP (i4 index 6) then i8 GEP back by 12 bytes" begin
        p = ParsedIR(8, [(:x, 8)], [
            IRBasicBlock(:entry, IRInst[
                IRAlloca(:a, 8, iconst(4)),
                IRStore(ssa(:a), iconst(10), 8),
                IRPtrOffset(:a3, ssa(:a), 3, 8),
                IRStore(ssa(:a3), iconst(40), 8),
                IRBinOp(:bit, :and, ssa(:x), iconst(1), 8),
                IRBinOp(:i8, :add, ssa(:bit), iconst(6), 8),
                IRCast(:i4, :trunc, ssa(:i8), 8, 4),
                IRBinOp(:bytes, :shl, ssa(:i8), iconst(1), 8),
                IRBinOp(:back, :sub, iconst(0), ssa(:bytes), 8),
                IRPtrOffset(:p0, ssa(:a), 0, 8),
                IRVarGEP(:p, ssa(:p0), ssa(:i4), 16),
                IRVarGEP(:q, ssa(:p), ssa(:back), 8),
                IRLoad(:r, ssa(:q), 8),
            ], IRRet(ssa(:r), 8)),
        ], [8])
        c = reversible_compile(p; fold_constants=false)
        @test (Int(simulate(c, UInt8(0))), verify_reversibility(c)) == (10, true)
        @test all(x -> Int(simulate(c, x)) == 10, _RROP_XS)
    end

    @testset "three-deep, one width: i4 (6+b) + i4 (7-b) = 13 (reads -3), then i8 b-12" begin
        insts = IRInst[
            IRAlloca(:a, 8, iconst(4)),
            IRStore(ssa(:a), iconst(10), 8),
            IRPtrOffset(:a1, ssa(:a), 1, 8), IRStore(ssa(:a1), iconst(20), 8),
            IRPtrOffset(:a2, ssa(:a), 2, 8), IRStore(ssa(:a2), iconst(30), 8),
            IRPtrOffset(:a3, ssa(:a), 3, 8), IRStore(ssa(:a3), iconst(40), 8),
            IRBinOp(:b, :and, ssa(:x), iconst(1), 8),
            IRCast(:b4, :trunc, ssa(:b), 8, 4),
            IRBinOp(:i, :add, ssa(:b4), iconst(6), 4),
            IRBinOp(:j, :sub, iconst(7), ssa(:b4), 4),
            IRBinOp(:k, :sub, ssa(:b), iconst(12), 8),
            IRPtrOffset(:p0, ssa(:a), 0, 8),
            IRVarGEP(:p1, ssa(:p0), ssa(:i), 8),
            IRVarGEP(:p2, ssa(:p1), ssa(:j), 8),
            IRVarGEP(:q, ssa(:p2), ssa(:k), 8),
            IRLoad(:r, ssa(:q), 8)]
        p = ParsedIR(8, [(:x, 8)], [IRBasicBlock(:entry, insts, IRRet(ssa(:r), 8))], [8])
        for fold in (false, true)     # element 1 + b
            c = reversible_compile(p; fold_constants=fold)
            @test all(x -> Int(simulate(c, x)) == (isodd(_rrop_u(x)) ? 30 : 20), _RROP_XS)
            @test verify_reversibility(c)
        end
    end

    @testset "persistent slab: three-deep chain composes at 64 bits" begin
        # n = (x & 1) + 2 routes to :persistent_tree. Slots 0, 1 := 11, 22.
        # key = (6 + b) + (7 - b) + (b - 13) = b at i4/i4/i8; gw0r read the
        # composed 13 back as -3 and looked up key 240 + b.
        insts = IRInst[
            IRBinOp(:b, :and, ssa(:x), iconst(1), 8),
            IRBinOp(:n, :add, ssa(:b), iconst(2), 8),
            IRAlloca(:a, 8, ssa(:n)),
            IRVarGEP(:s0, ssa(:a), iconst(0), 8), IRStore(ssa(:s0), iconst(11), 8),
            IRVarGEP(:s1, ssa(:a), iconst(1), 8), IRStore(ssa(:s1), iconst(22), 8),
            IRCast(:b4, :trunc, ssa(:b), 8, 4),
            IRBinOp(:i, :add, ssa(:b4), iconst(6), 4),
            IRBinOp(:j, :sub, iconst(7), ssa(:b4), 4),
            IRBinOp(:k, :sub, ssa(:b), iconst(13), 8),
            IRVarGEP(:p1, ssa(:a), ssa(:i), 8),
            IRVarGEP(:p2, ssa(:p1), ssa(:j), 8),
            IRVarGEP(:q, ssa(:p2), ssa(:k), 8),
            IRLoad(:r, ssa(:q), 8)]
        p = ParsedIR(8, [(:x, 8)], [IRBasicBlock(:entry, insts, IRRet(ssa(:r), 8))], [8])
        c = Bennett.bennett(Bennett.lower(p; mem=:persistent))
        @test all(x -> Int(simulate(c, x)) == (isodd(_rrop_u(x)) ? 22 : 11), _RROP_XS)
        @test verify_reversibility(c)
    end

    rng = MersenneTwister(0x7272_6f70)
    cover = Dict{Symbol,Int}()
    ncases = Ref(0)
    sizes(AE) = AE == 8 ? (4, 5, 16, 257) : AE == 16 ? (4, 16, 257) : (2, 9, 257)
    @testset "chains AE=$AE N=$N" for AE in (8, 16, 32), N in sizes(AE)
        for len in (2, 3), op in (:load, :store), _ in 1:(N > 64 ? 2 : 5)
            c = _rrop_gen(rng, AE, N, len, op)
            c === nothing && continue
            _rrop_check(c)
            ncases[] += 1
            for f in _rrop_flags(c)
                cover[f] = get(cover, f, 0) + 1
            end
        end
    end
    @info "Bennett-rrop: $(ncases[]) GEP chains checked" cover
    @test ncases[] >= 150
    for f in (:mid_negative, :mid_past_end, :scaled_past_signed_range, :negative_index,
              :runtime_runtime, :mixed_elem_widths, :three_deep)
        @test get(cover, f, 0) >= 10
    end
end
