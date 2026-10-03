using Test
using Bennett
using Bennett: ParsedIR, IRBasicBlock, IRInst, IRAlloca, IRPtrOffset, IRStore,
    IRBinOp, IRCast, IRVarGEP, IRLoad, IRRet, ssa, iconst

# Bennett-gw0r (review 1, 2026-10-03, findings R1 + R3) — two regressions from
# bcded8f (Bennett-jkf0, GEP-on-GEP index composition):
#   R1 (wrong result): a VarGEP whose base index is zero recorded its runtime
#      index unconverted, i.e. in GEP-element units, as an index in alloca
#      elements. `gep i16, %p0, %i` on an i8 alloca advanced 1 byte per step
#      instead of 2. verify_reversibility stays true; only a value oracle sees it.
#   R3 (rejects valid): the composed index kept the runtime operand's width, so
#      base element 255 + an i8 index into a 257-element alloca was truncated to
#      8 bits and the shadow-checkpoint load threw "need at least 9".
#
# The jkf0 oracle only crossed matching GEP / alloca element widths and small
# arrays. This file crosses GEP element width {8,16,32} x alloca element width
# {8,16,32}; base pointer = raw alloca / zero PtrOffset / constant PtrOffset /
# runtime VarGEP; GEP index = runtime non-negative / runtime negative / constant,
# at index widths below, at and above what the allocation needs; allocation
# sizes on both sides of a power of two. Every case is checked on all 256 Int8
# inputs against a byte-addressed memory model that follows LLVM GEP semantics
# (indices sign-extended, displacement = index * GEP element bytes), plus
# verify_reversibility.

const _GW0R_XS = typemin(Int8):typemax(Int8)
_gw0r_u(x) = Int(reinterpret(UInt8, x))
_gw0r_sext(v, w) = (v & ((1 << w) - 1)) >= (1 << (w - 1)) ? (v & ((1 << w) - 1)) - (1 << w) :
                                                          (v & ((1 << w) - 1))

# Initial element values: distinct in the low byte as far as 8 bits allow,
# and element 256 differs from element 0 (the R3 truncation target).
_gw0r_init(AE, k) = ((k * 0x9E3779B1 + 0x5A + 101 * (k ÷ 256)) & ((1 << AE) - 1))
const _GW0R_SENT = 0xA5A5A5A5

# ---- byte-level memory model (independent of the lowering) --------------
function _gw0r_mem(AE, N)
    ab = AE ÷ 8
    mem = zeros(UInt8, N * ab)
    for k in 0:N-1, b in 0:ab-1
        mem[k * ab + b + 1] = UInt8((_gw0r_init(AE, k) >> (8b)) & 0xff)
    end
    return mem
end
_gw0r_read(mem, addr, ab) = sum(Int(mem[addr + b + 1]) << (8b) for b in 0:ab-1)
function _gw0r_write!(mem, addr, ab, v)
    for b in 0:ab-1
        mem[addr + b + 1] = UInt8((v >> (8b)) & 0xff)
    end
end

# ---- case description ------------------------------------------------------
# base   :raw | :zero | :const | :runtime ; B = base element (runtime: B + bit7(x))
# index  (:pos | :neg, IW, m, d): i = (x & m) - d computed at IW bits
#        (:const, K)
struct GW0RCase
    AE::Int; GE::Int; N::Int
    base::Symbol; B::Int
    idx::Tuple
    op::Symbol             # :load | :store
end

_gw0r_base_elem(c::GW0RCase, x) =
    c.base in (:raw, :zero) ? 0 :
    c.base === :const ? c.B : c.B + ((_gw0r_u(x) >> 7) & 1)

function _gw0r_index_val(c::GW0RCase, x)
    kind = c.idx[1]
    kind === :const && return c.idx[2]
    _, IW, m, d = c.idx
    return _gw0r_sext((_gw0r_u(x) & m) - d, IW)   # LLVM: GEP index is signed
end

# Byte address of q for input x, or nothing when out of bounds.
function _gw0r_addr(c::GW0RCase, x)
    ab, gb = c.AE ÷ 8, c.GE ÷ 8
    addr = _gw0r_base_elem(c, x) * ab + _gw0r_index_val(c, x) * gb
    (0 <= addr && addr + ab <= c.N * ab && addr % ab == 0) || return nothing
    return addr
end
_gw0r_valid(c) = all(x -> _gw0r_addr(c, x) !== nothing, _GW0R_XS)

function _gw0r_oracle(c::GW0RCase, x)
    mem = _gw0r_mem(c.AE, c.N)
    ab = c.AE ÷ 8
    addr = _gw0r_addr(c, x)
    if c.op === :store
        _gw0r_write!(mem, addr, ab, _GW0R_SENT & ((1 << c.AE) - 1))
    end
    return _gw0r_read(mem, addr, ab)
end

# ---- IR builder --------------------------------------------------------------
function _gw0r_cast!(insts, dest, src, from, to)
    if from == to
        push!(insts, IRBinOp(dest, :or, src, iconst(0), to))
    else
        push!(insts, IRCast(dest, from > to ? :trunc : :sext, src, from, to))
    end
end

function _gw0r_ir(c::GW0RCase)
    AE, GE, N = c.AE, c.GE, c.N
    ab = AE ÷ 8
    insts = IRInst[IRAlloca(:a, AE, iconst(N))]
    for k in 0:N-1
        push!(insts, IRPtrOffset(Symbol(:init, k), ssa(:a), k * ab, AE))
        push!(insts, IRStore(ssa(Symbol(:init, k)), iconst(_gw0r_init(AE, k)), AE))
    end
    # base pointer :p and its element index :be (16 bits) for the reload check
    if c.base === :raw
        bp = ssa(:a)
        push!(insts, IRBinOp(:be, :and, ssa(:x16), iconst(0), 16))
    elseif c.base === :zero
        push!(insts, IRPtrOffset(:p, ssa(:a), 0, AE)); bp = ssa(:p)
        push!(insts, IRBinOp(:be, :and, ssa(:x16), iconst(0), 16))
    elseif c.base === :const
        push!(insts, IRPtrOffset(:p, ssa(:a), c.B * ab, AE)); bp = ssa(:p)
        push!(insts, IRBinOp(:be, :or, iconst(c.B), iconst(0), 16))
    else
        append!(insts, IRInst[
            IRBinOp(:t7, :lshr, ssa(:x16), iconst(7), 16),
            IRBinOp(:b7, :and, ssa(:t7), iconst(1), 16),
            IRBinOp(:be, :add, ssa(:b7), iconst(c.B), 16),
            IRVarGEP(:p, ssa(:a), ssa(:be), AE)])
        bp = ssa(:p)
    end
    insert!(insts, 2, IRCast(:x16, :zext, ssa(:x), 8, 16))
    if c.idx[1] === :const
        push!(insts, IRVarGEP(:q, bp, iconst(c.idx[2]), GE))
        # displacement already in alloca elements (shift 0 below)
        push!(insts, IRBinOp(:i16, :or, iconst((c.idx[2] * GE) ÷ AE), iconst(0), 16))
    else
        _, IW, m, d = c.idx
        push!(insts, IRBinOp(:xm, :and, ssa(:x), iconst(m), 8))
        _gw0r_cast!(insts, :xmw, ssa(:xm), 8, IW)
        push!(insts, IRBinOp(:i, :sub, ssa(:xmw), iconst(d), IW))
        push!(insts, IRVarGEP(:q, bp, ssa(:i), GE))
        _gw0r_cast!(insts, :i16, ssa(:i), IW, 16)
    end
    if c.op === :load
        push!(insts, IRLoad(:r, ssa(:q), AE))
    else
        # store through q, reload through an independently built pointer
        # a[be + i * GE/AE] (16-bit index straight off the raw alloca)
        push!(insts, IRStore(ssa(:q), iconst(_GW0R_SENT & ((1 << AE) - 1)), AE))
        sh = c.idx[1] === :const ? 0 : trailing_zeros(GE ÷ AE)
        push!(insts, IRBinOp(:is, :shl, ssa(:i16), iconst(sh), 16))
        push!(insts, IRBinOp(:te, :add, ssa(:be), ssa(:is), 16))
        push!(insts, IRVarGEP(:t, ssa(:a), ssa(:te), AE))
        push!(insts, IRLoad(:r, ssa(:t), AE))
    end
    return ParsedIR(AE, [(:x, 8)], [IRBasicBlock(:entry, insts, IRRet(ssa(:r), AE))], [AE])
end

function _gw0r_check(c::GW0RCase; fold=true)
    circ = reversible_compile(_gw0r_ir(c); fold_constants=fold)
    mask = (1 << c.AE) - 1
    bad = [(x, Int(simulate(circ, x)) & mask, _gw0r_oracle(c, x))
           for x in _GW0R_XS if (Int(simulate(circ, x)) & mask) != _gw0r_oracle(c, x)]
    isempty(bad) || @info "gw0r mismatch" c first(bad, 3)
    @test isempty(bad)
    @test verify_reversibility(circ)
end

# Pick the widest runtime index pattern for which every input stays in bounds.
function _gw0r_pick(AE, GE, N, base, B, kind, IW, op)
    for m in (63, 31, 15, 7, 3, 1)
        m < (1 << (IW - 1)) || kind === :neg || continue
        ds = kind === :pos ? (0,) : (m, m ÷ 2 + 1, 1)
        for d in ds
            kind === :neg && d > (1 << (IW - 1)) && continue
            c = GW0RCase(AE, GE, N, base, B, (kind, IW, m, d), op)
            _gw0r_valid(c) && return c
        end
    end
    return nothing
end

@testset "Bennett-gw0r — GEP index composition: element units and index width" begin

    @testset "R1 witness: i16 GEP off a zero-index base into an i8 alloca" begin
        insts = IRInst[
            IRAlloca(:a, 8, iconst(4)),
            IRStore(ssa(:a), iconst(10), 8),
            IRPtrOffset(:p1, ssa(:a), 1, 8),
            IRStore(ssa(:p1), iconst(20), 8),
            IRPtrOffset(:p2, ssa(:a), 2, 8),
            IRStore(ssa(:p2), iconst(30), 8),
            IRPtrOffset(:p0, ssa(:a), 0, 8),
            IRBinOp(:i, :and, ssa(:x), iconst(1), 8),
            IRVarGEP(:q, ssa(:p0), ssa(:i), 16),
            IRLoad(:r, ssa(:q), 8),
        ]
        p = ParsedIR(8, [(:x, 8)],
            [IRBasicBlock(:entry, insts, IRRet(ssa(:r), 8))], [8])
        c = reversible_compile(p; fold_constants=false)
        @test (Int(simulate(c, UInt8(1))), verify_reversibility(c)) == (30, true)
        @test all(x -> Int(simulate(c, x)) == (isodd(_gw0r_u(x)) ? 30 : 10), _GW0R_XS)
    end

    @testset "R3 witness: base element 255 + runtime index into 257 elements" begin
        insts = IRInst[
            IRAlloca(:a, 8, iconst(257)),
            IRPtrOffset(:p255, ssa(:a), 255, 8),
            IRStore(ssa(:p255), iconst(11), 8),
            IRPtrOffset(:p256, ssa(:a), 256, 8),
            IRStore(ssa(:p256), iconst(22), 8),
            IRBinOp(:i, :and, ssa(:x), iconst(1), 8),
            IRVarGEP(:q, ssa(:p255), ssa(:i), 8),
            IRLoad(:r, ssa(:q), 8),
        ]
        p = ParsedIR(8, [(:x, 8)],
            [IRBasicBlock(:entry, insts, IRRet(ssa(:r), 8))], [8])
        c = reversible_compile(p)
        @test (simulate(c, Int8(0)), simulate(c, Int8(1))) == (11, 22)
        @test all(x -> simulate(c, x) == (isodd(_gw0r_u(x)) ? 22 : 11), _GW0R_XS)
        @test verify_reversibility(c)
    end

    # Runtime GEP index whose element is narrower than the alloca's: the
    # displacement is not provably a whole number of alloca elements.
    @testset "runtime index, GEP elem $GE < alloca elem $AE: loud rejection" for
            (AE, GE) in ((16, 8), (32, 8), (32, 16)), base in (:raw, :zero, :const)
        c = GW0RCase(AE, GE, 8, base, 2, (:pos, 8, 1, 0), :load)
        @test_throws ArgumentError reversible_compile(_gw0r_ir(c))
    end

    # Constant byte displacement that is not a whole alloca element.
    @testset "constant sub-element displacement off a runtime base is rejected" begin
        c = GW0RCase(16, 8, 8, :runtime, 2, (:const, 1), :load)
        @test_throws Exception reversible_compile(_gw0r_ir(c))
    end

    ncases = Ref(0)
    sizes(AE) = AE == 8 ? (4, 16, 255, 256, 257) : AE == 16 ? (4, 16, 257) : (4, 9, 257)
    @testset "AE=$AE GE=$GE N=$N" for AE in (8, 16, 32), GE in (8, 16, 32), N in sizes(AE)
        big = N > 64
        for base in (:raw, :zero, :const, :runtime), op in (:load, :store)
            big && op === :store && base in (:raw, :zero) && continue
            Bs = base in (:raw, :zero) ? (0,) : big ? (N ÷ 2, N - 2) : (N ÷ 2,)
            for B in Bs
                cands = Any[]
                if GE >= AE
                    for (kind, IW) in ((:pos, 8), (:pos, 16), (:pos, 3), (:neg, 8), (:neg, 3))
                        big && IW == 3 && continue
                        push!(cands, _gw0r_pick(AE, GE, N, base, B, kind, IW, op))
                    end
                end
                for K in (1, -1, 2)
                    push!(cands, GW0RCase(AE, GE, N, base, B, (:const, K), op))
                end
                for c in cands
                    c === nothing && continue
                    _gw0r_valid(c) || continue
                    _gw0r_check(c)
                    ncases[] += 1
                end
            end
        end
    end
    @test ncases[] > 300
    @info "Bennett-gw0r: $(ncases[]) composed-GEP cases checked"
end
