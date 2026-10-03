using Test
using Bennett

# Bennett-3wk7 (Astra B-extract-core F6): `fptosi` / `fptoui` / `sitofp` /
# `uitofp` whose float side is NOT `double` (f32 `float`, f16 `half`) fell
# through to a width-only IRCast — the float bit pattern was reinterpreted as
# an integer. Reachable from plain Julia: only Float32 ARGUMENTS are rejected
# upstream, Float32 intermediates inside an integer-signature function were
# not. Witness: `unsafe_trunc(Int32, reinterpret(Float32, 0x3fc00000))`
# compiled to 1069547520 (the bit pattern) instead of 1.
#
# There are no native f32/f16 soft-float conversion primitives (CLAUDE.md
# rule 13 / Bennett-3rph), so the extractor now fails loud at the cast site.
# The f64 paths must keep working bit-exactly.

const _3WK7_MSG = r"Bennett-3wk7"

f32_fptosi(b::UInt32) = unsafe_trunc(Int32, reinterpret(Float32, b))
f32_fptoui(b::UInt32) = unsafe_trunc(UInt32, reinterpret(Float32, b))
f32_sitofp(x::Int32)  = reinterpret(UInt32, Float32(x))
f32_uitofp(x::UInt32) = reinterpret(UInt32, Float32(x))
f16_fptosi(b::UInt16) = unsafe_trunc(Int16, reinterpret(Float16, b))
f16_sitofp(x::Int16)  = reinterpret(UInt16, Float16(x))

@testset "Bennett-3wk7: non-f64 int<->float casts fail loud" begin

    @testset "Julia path: $(nameof(f))" for (f, T) in (
            (f32_fptosi, UInt32), (f32_fptoui, UInt32),
            (f32_sitofp, Int32),  (f32_uitofp, UInt32),
            (f16_fptosi, UInt16), (f16_sitofp, Int16))
        err = try
            reversible_compile(f, T)
            nothing
        catch e
            e
        end
        @test err !== nothing
        @test err !== nothing && occursin(_3WK7_MSG, sprint(showerror, err))
    end

    @testset "raw .ll path: $op $(src) to $(dst)" for (op, src, dst) in (
            ("fptosi", "float", "i32"), ("fptoui", "float", "i32"),
            ("sitofp", "i32", "float"), ("uitofp", "i32", "float"),
            ("fptosi", "half", "i16"),  ("sitofp", "i16", "half"))
        # Operand / result are passed through integer bitcasts so the entry
        # signature is integer-only.
        in_ty  = src in ("float", "half") ? (src == "float" ? "i32" : "i16") : src
        out_ty = dst in ("float", "half") ? (dst == "float" ? "i32" : "i16") : dst
        body = if src in ("float", "half")
            "  %f = bitcast $in_ty %x to $src\n  %r = $op $src %f to $dst\n  ret $out_ty %r\n"
        else
            "  %r = $op $src %x to $dst\n  %o = bitcast $dst %r to $out_ty\n  ret $out_ty %o\n"
        end
        ll = "define $out_ty @g($in_ty %x) {\ntop:\n$body}\n"
        path = tempname() * ".ll"
        write(path, ll)
        err = try
            Bennett.extract_parsed_ir_from_ll(path; entry_function="g")
            nothing
        catch e
            e
        end
        rm(path; force=true)
        @test err !== nothing
        @test err !== nothing && occursin(_3WK7_MSG, sprint(showerror, err))
    end

    # The f64 routes are untouched and stay bit-exact (exhaustive over Int8).
    @testset "f64 fptosi / sitofp still correct (Int8 exhaustive)" begin
        g_sitofp(x::Int8) = reinterpret(UInt64, Float64(x))
        c = reversible_compile(g_sitofp, Int8)
        @test verify_reversibility(c)
        for x in typemin(Int8):typemax(Int8)
            @test simulate(c, x) % UInt64 == g_sitofp(x)
        end

        # Float in [64, 128) with x in the top mantissa byte: in range for
        # Int8 (no UB), fractional part exercises truncation.
        g_fptosi(x::UInt8) = unsafe_trunc(Int8,
            reinterpret(Float64, 0x4050000000000000 | (UInt64(x) << 44)))
        c2 = reversible_compile(g_fptosi, UInt8)
        @test verify_reversibility(c2)
        for x in typemin(UInt8):typemax(UInt8)
            @test simulate(c2, x) % Int8 == g_fptosi(x)
        end
    end
end
