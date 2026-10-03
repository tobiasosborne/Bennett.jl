using Test
using Bennett
using LLVM
using Random

# Bennett-ytpe (Astra review 2026-09-26, B-extract-core F4): the
# `llvm.fshl` / `llvm.fshr` expansion in `_handle_intrinsic` emitted
# `(a << s) | (b >> (W - s))` (resp. `(a << (W - s)) | (b >> s)`) verbatim:
#   * no reduction of the shift amount modulo W (LangRef: the amount is
#     taken modulo the bit width), so a constant amount ≥ W shifted by a
#     negative / oversized constant;
#   * no zero-shift case: at s ≡ 0 (mod W) the second shift is by W, which
#     the dynamic barrel shifter masks to a shift by 0 — the result was
#     `a | b` instead of `a` (fshl) / `b` (fshr).
# The rotate case a == b hides the bug (`a | a == a`), so every sweep below
# uses distinct operands. Julia's own `bitrotate` guards s == 0 itself, so
# hand-written IR is the only way to reach the raw intrinsic at s ≡ 0.
#
# Reference = LLVM LangRef semantics, written out by hand.

_ytpe_mask(W) = W == 64 ? typemax(UInt64) : (UInt64(1) << W) - 1

function _ytpe_ref(kind::Symbol, W, a, b, s)
    m = _ytpe_mask(W)
    a = UInt64(a) & m; b = UInt64(b) & m
    k = Int(((s % UInt64) & m) % UInt64(W))
    if kind === :fshl
        k == 0 && return a
        return ((a << k) | (b >> (W - k))) & m
    else
        k == 0 && return b
        return ((a << (W - k)) | (b >> k)) & m
    end
end

function _ytpe_compile_ll(ir::String)
    c = nothing
    LLVM.Context() do _ctx
        mod = parse(LLVM.Module, ir)
        LLVM.verify(mod)
        parsed = Bennett._module_to_parsed_ir(mod)
        c = reversible_compile(parsed)
        dispose(mod)
    end
    return c
end

_ytpe_dyn_ir(kind, W) = """
declare i$W @llvm.$kind.i$W(i$W, i$W, i$W)
define i$W @julia_f(i$W %a, i$W %b, i$W %s) {
entry:
  %r = call i$W @llvm.$kind.i$W(i$W %a, i$W %b, i$W %s)
  ret i$W %r
}
"""

_ytpe_const_ir(kind, W, s) = """
declare i$W @llvm.$kind.i$W(i$W, i$W, i$W)
define i$W @julia_f(i$W %a, i$W %b) {
entry:
  %r = call i$W @llvm.$kind.i$W(i$W %a, i$W %b, i$W $s)
  ret i$W %r
}
"""

# Raw output bits of a W-bit result (simulate may return a signed type).
_ytpe_bits(W, v) = UInt64(unsigned(v)) & _ytpe_mask(W)

# Count mismatches, printing the first few.
function _ytpe_sweep(f, cases)
    bad = Any[]
    for args in cases
        got, want = f(args)
        if got != want
            length(bad) < 5 && println("    mismatch args=$args got=$(repr(got)) want=$(repr(want))")
            push!(bad, args)
        end
    end
    return length(bad)
end

const _YTPE_B8 = UInt8[0x00, 0x01, 0x34, 0x5a, 0x80, 0xa5, 0xc3, 0xff]

@testset "Bennett-ytpe: llvm.fshl / llvm.fshr" begin
    @testset "review witness: fshl.i8(0x12, 0x34, s)" begin
        c = _ytpe_compile_ll(_ytpe_dyn_ir("fshl", 8))
        for s in (0, 8, 16, 1, 9, 255)
            @test _ytpe_bits(8, simulate(c, (Int8(0x12), Int8(0x34), reinterpret(Int8, UInt8(s))))) ==
                  _ytpe_ref(:fshl, 8, 0x12, 0x34, s)
        end
        @test _ytpe_bits(8, simulate(c, (Int8(0x12), Int8(0x34), Int8(0)))) == 0x12
        @test verify_reversibility(c)
    end

    @testset "$kind.i8, runtime amount: every s × every a × 8 b, plus every rotate" for kind in (:fshl, :fshr)
        c = _ytpe_compile_ll(_ytpe_dyn_ir(kind, 8))
        r8(x) = reinterpret(Int8, UInt8(x))
        cases = ((a, b, s) for s in 0:255 for a in 0:255 for b in _YTPE_B8)
        nbad = _ytpe_sweep(cases) do (a, b, s)
            (_ytpe_bits(8, simulate(c, (r8(a), r8(b), r8(s)))), _ytpe_ref(kind, 8, a, b, s))
        end
        @test nbad == 0
        rot = ((a, a, s) for s in 0:255 for a in 0:255)
        nbad_rot = _ytpe_sweep(rot) do (a, b, s)
            (_ytpe_bits(8, simulate(c, (r8(a), r8(b), r8(s)))), _ytpe_ref(kind, 8, a, b, s))
        end
        @test nbad_rot == 0
        @test verify_reversibility(c)
    end

    @testset "$kind.i8, constant amount (incl. ≥ W and negative)" for kind in (:fshl, :fshr)
        # IR constants are printed signed: -1 ≡ 255, -8 ≡ 248, -128 ≡ 128.
        for s in vcat(collect(0:17), [24, 31, 64, 127, -128, -9, -8, -1])
            c = _ytpe_compile_ll(_ytpe_const_ir(kind, 8, s))
            r8(x) = reinterpret(Int8, UInt8(x))
            cases = ((a, b) for a in 0:255 for b in _YTPE_B8)
            nbad = _ytpe_sweep(cases) do (a, b)
                (_ytpe_bits(8, simulate(c, (r8(a), r8(b)))), _ytpe_ref(kind, 8, a, b, s))
            end
            @test nbad == 0
            @test verify_reversibility(c)
        end
    end

    @testset "$kind.i$W, runtime amount, random + edge" for kind in (:fshl, :fshr), W in (16, 64)
        T = W == 16 ? Int16 : Int64
        U = W == 16 ? UInt16 : UInt64
        c = _ytpe_compile_ll(_ytpe_dyn_ir(kind, W))
        rng = Random.MersenneTwister(0x7f9e)
        m = _ytpe_mask(W)
        ss = vcat(UInt64.(0:W+1), UInt64[2W - 1, 2W, 3W + 5, m], rand(rng, UInt64, 8) .& m)
        abs_ = [(rand(rng, U), rand(rng, U)) for _ in 1:6]
        push!(abs_, (U(0), typemax(U)), (typemax(U), U(0)), (U(1), U(0)))
        cases = ((a, b, s) for s in ss for (a, b) in abs_)
        nbad = _ytpe_sweep(cases) do (a, b, s)
            (_ytpe_bits(W, simulate(c, (reinterpret(T, a), reinterpret(T, b), reinterpret(T, U(s))))),
             _ytpe_ref(kind, W, a, b, s))
        end
        @test nbad == 0
        @test verify_reversibility(c)
    end

    @testset "$kind.i16, constant amount" for kind in (:fshl, :fshr)
        rng = Random.MersenneTwister(0x16)
        abs_ = [(rand(rng, UInt16), rand(rng, UInt16)) for _ in 1:24]
        for s in (0, 1, 7, 15, 16, 17, 32, -1, -16)
            c = _ytpe_compile_ll(_ytpe_const_ir(kind, 16, s))
            nbad = _ytpe_sweep(abs_) do (a, b)
                (_ytpe_bits(16, simulate(c, (reinterpret(Int16, a), reinterpret(Int16, b)))),
                 _ytpe_ref(kind, 16, a, b, reinterpret(UInt64, Int64(s))))
            end
            @test nbad == 0
            @test verify_reversibility(c)
        end
    end

    @testset "non-power-of-two width: constant ok, runtime rejected" begin
        # i7 constant amounts reduce mod 7 exactly; a runtime amount would need
        # a urem-by-7 circuit, which the expansion does not build — fail loud.
        for kind in (:fshl, :fshr), s in (0, 3, 7, 10, -1)
            c = _ytpe_compile_ll(_ytpe_const_ir(kind, 7, s))
            cases = ((a, b) for a in 0:127 for b in (0, 1, 0x2a, 0x55, 0x7f))
            nbad = _ytpe_sweep(cases) do (a, b)
                (_ytpe_bits(7, simulate(c, (Int8(a), Int8(b)))) ,
                 _ytpe_ref(kind, 7, a, b, reinterpret(UInt64, Int64(s))))
            end
            @test nbad == 0
            @test verify_reversibility(c)
        end
        for kind in ("fshl", "fshr")
            err = try
                _ytpe_compile_ll(_ytpe_dyn_ir(kind, 7)); nothing
            catch e
                e
            end
            @test err !== nothing
            @test occursin("Bennett-ytpe", sprint(showerror, err))
        end
    end

    @testset "Julia bitrotate (rotate idiom through the full pipeline)" begin
        c = reversible_compile((x, k) -> bitrotate(x, k), UInt8, Int8)
        nbad = _ytpe_sweep(((x, k) for x in 0x00:0xff for k in typemin(Int8):typemax(Int8))) do (x, k)
            (UInt8(_ytpe_bits(8, simulate(c, (x, k)))), bitrotate(x, k))
        end
        @test nbad == 0
        @test verify_reversibility(c)
        # Literal amounts (a captured loop variable would make the closure a
        # 2-argument function); 0, 8 and 11 exercise the k mod W reduction.
        for (k, f) in ((0, x -> bitrotate(x, 0)), (1, x -> bitrotate(x, 1)),
                       (3, x -> bitrotate(x, 3)), (8, x -> bitrotate(x, 8)),
                       (11, x -> bitrotate(x, 11)), (-3, x -> bitrotate(x, -3)))
            c1 = reversible_compile(f, UInt8)
            @test all(x -> UInt8(_ytpe_bits(8, simulate(c1, x))) == bitrotate(x, k), 0x00:0xff)
            @test verify_reversibility(c1)
        end
    end
end
