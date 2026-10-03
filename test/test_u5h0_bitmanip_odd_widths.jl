using Test
using Bennett
using LLVM
using Random

# Bennett-u5h0 (audit, from Bennett-ytpe): the bit-manipulation intrinsics
# expanded in `_handle_intrinsic` (ctpop, ctlz, cttz, bitreverse, bswap, abs,
# smax/smin/umax/umin) checked against LLVM LangRef semantics at widths plain
# Julia never emits: W ∈ {1, 3, 7, 8, 9, 16, 24, 32, 64}. Odd widths only
# arrive as hand-written / foreign .ll, which `extract_parsed_ir_from_ll` does
# NOT run through the LLVM verifier.
#
# Finding: every expansion is correct at every width except `llvm.bswap`,
# which LangRef defines only for an even number of bytes (W % 16 == 0; the
# verifier says "bswap must be an even number of bytes"). Unverified i9 bswap
# silently dropped bit 8 (byte loop over w ÷ 8 bytes), i8/i24 produced a
# circuit for IR LLVM rejects, and i1/i3/i7 died on a negative shift. Those
# widths are now rejected naming the bead.
#
# References below are written out by hand (bit loops) — they do not call
# Julia's count_ones / leading_zeros / bswap, nor any Bennett helper.
# W ≤ 9: every input (every pair for the binary intrinsics). W ≥ 16: edge
# values (0, 1, all-ones, sign bit, every single bit, every low/high mask)
# plus a seeded random sweep.

_u5h0_mask(W) = W == 64 ? typemax(UInt64) : (UInt64(1) << W) - 1
_u5h0_bits(W, v) = (v % UInt64) & _u5h0_mask(W)
_u5h0_signed(W, x) = (x >> (W - 1)) & 1 == 1 ? Int128(x) - (Int128(1) << W) : Int128(x)
_u5h0_itype(W) = W <= 8 ? Int8 : W <= 16 ? Int16 : W <= 32 ? Int32 : Int64
_u5h0_in(W, x) = x % _u5h0_itype(W)

function _u5h0_ctpop(W, x)
    n = 0
    for i in 0:(W - 1); n += Int((x >> i) & 1); end
    return UInt64(n)
end
function _u5h0_ctlz(W, x)
    n = 0
    for i in (W - 1):-1:0
        (x >> i) & 1 == 1 && break
        n += 1
    end
    return UInt64(n)
end
function _u5h0_cttz(W, x)
    n = 0
    for i in 0:(W - 1)
        (x >> i) & 1 == 1 && break
        n += 1
    end
    return UInt64(n)
end
function _u5h0_bitreverse(W, x)
    r = UInt64(0)
    for i in 0:(W - 1); r |= ((x >> i) & 1) << (W - 1 - i); end
    return r
end
function _u5h0_bswap(W, x)
    nb = W ÷ 8
    r = UInt64(0)
    for b in 0:(nb - 1); r |= ((x >> (8b)) & 0xff) << (8 * (nb - 1 - b)); end
    return r
end
# abs with is_int_min_poison=false: INT_MIN maps to itself (mod 2^W).
_u5h0_abs(W, x) = UInt64(mod(abs(_u5h0_signed(W, x)), Int128(1) << W))
_u5h0_smax(W, a, b) = _u5h0_signed(W, a) >= _u5h0_signed(W, b) ? a : b
_u5h0_smin(W, a, b) = _u5h0_signed(W, a) <= _u5h0_signed(W, b) ? a : b
_u5h0_umax(W, a, b) = a >= b ? a : b
_u5h0_umin(W, a, b) = a <= b ? a : b

_u5h0_unary_ir(name, W, flag) = """
declare i$W @llvm.$name.i$W(i$W$(flag === nothing ? "" : ", i1"))
define i$W @julia_f(i$W %x) {
entry:
  %r = call i$W @llvm.$name.i$W(i$W %x$(flag === nothing ? "" : ", i1 $flag"))
  ret i$W %r
}
"""
_u5h0_binary_ir(name, W) = """
declare i$W @llvm.$name.i$W(i$W, i$W)
define i$W @julia_f(i$W %a, i$W %b) {
entry:
  %r = call i$W @llvm.$name.i$W(i$W %a, i$W %b)
  ret i$W %r
}
"""

# Does LLVM itself accept this IR?
function _u5h0_llvm_valid(ir)
    try
        LLVM.Context() do _ctx
            m = parse(LLVM.Module, ir)
            LLVM.verify(m)
            dispose(m)
        end
        return true
    catch e
        e isa InterruptException && rethrow()
        return false
    end
end

# The .ll text path, deliberately unverified (what a foreign frontend gets).
function _u5h0_compile(ir)
    path = tempname() * ".ll"
    write(path, ir)
    try
        return reversible_compile(Bennett.extract_parsed_ir_from_ll(path; entry_function="julia_f"))
    finally
        rm(path; force=true)
    end
end

function _u5h0_values(W)
    W <= 9 && return collect(UInt64(0):_u5h0_mask(W))
    m = _u5h0_mask(W)
    v = Set{UInt64}([0, 1, m, m >> 1, UInt64(1) << (W - 1), (UInt64(1) << (W - 1)) + 1])
    for i in 0:(W - 1)
        push!(v, UInt64(1) << i, m >> i, (m << i) & m)
    end
    rng = MersenneTwister(0x75356830 + W)
    for _ in 1:300; push!(v, rand(rng, UInt64) & m); end
    return sort!(collect(v))
end

# Count mismatches, printing the first few.
function _u5h0_mismatches(c, W, ref, inputs)
    nbad = 0
    for args in inputs
        got = _u5h0_bits(W, simulate(c, map(a -> _u5h0_in(W, a), args)))
        want = ref(args...) & _u5h0_mask(W)
        if got != want
            nbad < 5 && println("    mismatch W=$W args=$args got=$got want=$want")
            nbad += 1
        end
    end
    return nbad
end

const _U5H0_WIDTHS = (1, 3, 7, 8, 9, 16, 24, 32, 64)

@testset "Bennett-u5h0: bit-manipulation intrinsics at odd widths" begin
    # (name, second i1 flag or nothing, reference). With the flag `true`
    # the poison input (0 for ctlz/cttz, INT_MIN for abs) is skipped — any
    # result refines poison. With `false` it must be exact: ctlz/cttz(0) = W.
    unary = (("ctpop", nothing, _u5h0_ctpop),
             ("ctlz", "false", _u5h0_ctlz), ("ctlz", "true", _u5h0_ctlz),
             ("cttz", "false", _u5h0_cttz), ("cttz", "true", _u5h0_cttz),
             ("bitreverse", nothing, _u5h0_bitreverse),
             ("abs", "false", _u5h0_abs), ("abs", "true", _u5h0_abs))
    @testset "$name.i$W($flag)" for W in _U5H0_WIDTHS, (name, flag, ref) in unary
        ir = _u5h0_unary_ir(name, W, flag)
        @test _u5h0_llvm_valid(ir)
        c = _u5h0_compile(ir)
        poison = flag == "true" ? (name == "abs" ? UInt64(1) << (W - 1) : UInt64(0)) : nothing
        xs = ((x,) for x in _u5h0_values(W) if x !== poison)
        @test _u5h0_mismatches(c, W, x -> ref(W, x), xs) == 0
        @test verify_reversibility(c)
    end

    binary = (("smax", _u5h0_smax), ("smin", _u5h0_smin),
              ("umax", _u5h0_umax), ("umin", _u5h0_umin))
    @testset "$name.i$W" for W in _U5H0_WIDTHS, (name, ref) in binary
        ir = _u5h0_binary_ir(name, W)
        @test _u5h0_llvm_valid(ir)
        c = _u5h0_compile(ir)
        # W ≤ 9: every pair. Wider: every pair from a 64-value edge/random subset.
        vs = W <= 9 ? _u5h0_values(W) : _u5h0_values(W)[round.(Int, range(1, length(_u5h0_values(W)); length=64))]
        @test _u5h0_mismatches(c, W, (a, b) -> ref(W, a, b), ((a, b) for a in vs for b in vs)) == 0
        @test verify_reversibility(c)
    end

    @testset "bswap.i$W (valid width)" for W in (16, 32, 64)
        ir = _u5h0_unary_ir("bswap", W, nothing)
        @test _u5h0_llvm_valid(ir)
        c = _u5h0_compile(ir)
        @test _u5h0_mismatches(c, W, x -> _u5h0_bswap(W, x), ((x,) for x in _u5h0_values(W))) == 0
        @test verify_reversibility(c)
    end

    # LLVM rejects bswap unless W % 16 == 0; so must Bennett (it used to emit
    # x & 0xff at i9, a byte swap at i24, identity at i8, and crash below 8).
    @testset "bswap.i$W rejected" for W in (1, 3, 7, 8, 9, 24)
        ir = _u5h0_unary_ir("bswap", W, nothing)
        @test !_u5h0_llvm_valid(ir)
        err = try
            _u5h0_compile(ir); nothing
        catch e
            e
        end
        @test err !== nothing
        msg = err === nothing ? "" : sprint(showerror, err)
        @test occursin("Bennett-u5h0", msg)
        @test occursin("multiple of 16", msg)
    end

    @testset "Julia bswap end to end" begin
        for (T, xs) in ((UInt32, (0x00000000, 0x12345678, 0xdeadbeef, 0xffffffff, 0x80000001)),
                        (UInt64, (0x0000000000000000, 0x0123456789abcdef, 0xffffffffffffffff, 0x8000000000000001)))
            c = reversible_compile(bswap, T)
            @test all(x -> simulate(c, T, x) == bswap(x), xs)
            @test verify_reversibility(c)
        end
    end
end
