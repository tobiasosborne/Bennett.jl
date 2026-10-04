using Test, Bennett

# Bennett-1qws: `llvm.floor.f64` / `llvm.ceil.f64` / `llvm.trunc.f64` /
# `llvm.rint.f64` lower through `soft_floor` / `soft_ceil` / `soft_trunc` /
# `soft_round` (rint under the default round-to-nearest-ties-to-even mode),
# bit-exact against native Julia; any non-f64 width is refused loudly.
# Pre-1qws all four were rejected ("no registered callee handler") because
# `_handle_intrinsic` had an empty conditional for them.

_1qws_bits(x::Float64) = reinterpret(UInt64, x)

# ~45 inputs: signed zeros, infinities, NaNs (quiet, payload, signalling,
# negative), subnormals, normal-range boundaries, halfway cases, values just
# below/above integers, |x| >= 2^52 (already integral), huge values.
const _1QWS_INPUTS = UInt64[
    _1qws_bits.(Float64[
        0.0, -0.0, Inf, -Inf,
        5.0e-324, -5.0e-324, prevfloat(floatmin(Float64)), -prevfloat(floatmin(Float64)),
        floatmin(Float64), -floatmin(Float64),
        0.5, -0.5, 1.5, -1.5, 2.5, -2.5, 3.5, -3.5,
        0.49999999999999994, -0.49999999999999994, nextfloat(0.5), -nextfloat(0.5),
        prevfloat(1.0), -prevfloat(1.0), nextfloat(1.0), -nextfloat(1.0),
        1.0, -1.0, prevfloat(2.0), nextfloat(-3.0), 0.7, -0.7,
        123456.789, -123456.789,
        2.0^52, -2.0^52, 2.0^52 - 0.5, -(2.0^52 - 0.5), 2.0^52 + 1, 2.0^53 + 2,
        1e300, -1e300, floatmax(Float64), -floatmax(Float64)])...,
    0x7ff8000000000000,   # canonical qNaN
    0xfff8000000000000,   # negative qNaN
    0x7ff8000000000123,   # qNaN with payload
    0x7ff0000000000001,   # sNaN (quieted by native)
    0xfff4000000000abc,   # negative sNaN with payload
]

# (name, intrinsic, native Float64 op, SoftFloat-route op)
const _1QWS_OPS = (
    ("floor", "llvm.floor", x -> floor(x),             x -> floor(x)),
    ("ceil",  "llvm.ceil",  x -> ceil(x),              x -> ceil(x)),
    ("trunc", "llvm.trunc", x -> trunc(x),             x -> trunc(x)),
    # `round(x, RoundNearest)` on a Float64 emits `llvm.rint.f64`.
    ("rint",  "llvm.rint",  x -> round(x, RoundNearest), x -> round(x)),
)

_1qws_native(op, b::UInt64) = _1qws_bits(op(reinterpret(Float64, Base.inferencebarrier(b))))

function _1qws_ll(intr::AbstractString, ty::AbstractString, ity::AbstractString)
    """
    declare $ty @$intr.$(ty == "double" ? "f64" : "f32")($ty)

    define $ity @w($ity %a) {
    entry:
      %fa = bitcast $ity %a to $ty
      %r  = call $ty @$intr.$(ty == "double" ? "f64" : "f32")($ty %fa)
      %z  = bitcast $ty %r to $ity
      ret $ity %z
    }
    """
end

function _1qws_from_ll(src::AbstractString)
    path, io = mktemp()
    write(io, src); close(io)
    try
        return Bennett.extract_parsed_ir_from_ll(path; entry_function="w")
    finally
        rm(path; force=true)
    end
end

@testset "Bennett-1qws: llvm.{floor,ceil,trunc,rint}.f64 dispatch" begin
    @testset "$name" for (name, intr, nat, sfop) in _1QWS_OPS
        # (a) Julia-level witness: Int64 argument reinterpreted as Float64.
        f = x::Int64 -> reinterpret(Int64, nat(reinterpret(Float64, x)))
        ir = sprint(io -> print(io, Bennett.extract_ir(f, Tuple{Int64})))
        @test occursin("@$intr.f64", ir)   # the witness really emits the intrinsic
        c = reversible_compile(f, Int64)
        @test verify_reversibility(c)
        for b in _1QWS_INPUTS
            @test simulate(c, reinterpret(Int64, b)) % UInt64 == _1qws_native(nat, b)
        end

        # (a') Float64 (SoftFloat) route still agrees with native.
        cf = reversible_compile(sfop, Float64)
        @test verify_reversibility(cf)
        for b in _1QWS_INPUTS
            @test simulate(cf, b) % UInt64 == _1qws_native(nat, b)
        end

        # (b) hand-written IR through extract_parsed_ir_from_ll.
        p = _1qws_from_ll(_1qws_ll(intr, "double", "i64"))
        cl = reversible_compile(p)
        @test verify_reversibility(cl)
        for b in _1QWS_INPUTS
            @test simulate(cl, reinterpret(Int64, b)) % UInt64 == _1qws_native(nat, b)
        end

        # (c) f32 form refused loudly (no native f32 primitives, CLAUDE.md §13).
        err = try
            _1qws_from_ll(_1qws_ll(intr, "float", "i32")); nothing
        catch e
            sprint(showerror, e)
        end
        @test err !== nothing
        @test occursin("$intr: only f64 supported (got width=32)", err)
        @test occursin("Bennett-1qws", err)
    end
end
