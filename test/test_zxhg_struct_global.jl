# Bennett-zxhg (2026-05-16, Bennett-doih follow-up under Bennett-hao
# Phase 3) — ConstantStruct global extraction. Extends
# `_extract_const_globals` in `src/extract/module_walk.jl` to accept
# `LLVM.ConstantStruct` initializers (and the LLVM 18 quirk where
# whole-struct `zeroinitializer` parses as `LLVM.ConstantAggregateZero`,
# not `ConstantStruct`).
#
# Scope is intentionally narrow per the Bennett-ixiz "scope it tight"
# lesson (worklog/069):
#   - struct fields must be IntegerType (8/16/32/64),
#     ArrayType-of-IntegerType (8/16/32/64), nested ConstantStruct
#     satisfying same rules, or ConstantAggregateZero (zero-bytes)
#   - any other field type (ptr, float, vector, i128, etc.) hard-rejects
#     the WHOLE global via `_flatten_struct_to_bytes` returning nothing
#     → silently skipped in the dict → G5 fires downstream with the
#     precise `Bennett-zxhg-ptrfield` breadcrumb
#   - byte-granular `elem_width=8` normalization (heterogeneous-width
#     fields force this; pure-i64 structs could in principle stay at
#     elem_width=64 but the uniform dict shape is simpler)
#   - ABI offset/padding honored via `LLVM.offsetof` + `LLVM.abi_size`
#     (covers both packed `<{...}>` and non-packed `{...}` in one path)
#   - little-endian only (asserted at helper entry)
#
# T5 acceptance fixture (t5_tr2_hashmap.ll:153) is the
# `<{ ptr, [24 x i8] }>` ptr-field case; mirrored by
# `zxhg_t5_tr2_smoke.ll` which pins the fail-loud branch.

using Test
using Bennett

@testset "Bennett-zxhg: ConstantStruct global extraction" begin

    # ---- Positive (extraction + lowering + reversibility) ----

    @testset "<{ i8, [3 x i8] }> pure-integer struct (4 bytes)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "zxhg_struct_int_field.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(
            path; entry_function="zxhg_struct_int_field")
        @test haskey(parsed.globals, :gstruct)
        (gdata, gw) = parsed.globals[:gstruct]
        @test gw == 8
        @test gdata == UInt64[0x10, 0x11, 0x12, 0x13]
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        # Oracle: dst[2] = 0x12 = 18.
        for x in Int8(-3):Int8(3)
            @test simulate(c, x) == Int8(0x12)
        end
    end

    @testset "<{ [8 x i8], [8 x i8] }> (mirrors t5_tr2 @anon.7665…1)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "zxhg_struct_two_i8_arrays.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(
            path; entry_function="zxhg_struct_two_i8_arrays")
        @test haskey(parsed.globals, :gtwo)
        (gdata, gw) = parsed.globals[:gtwo]
        @test gw == 8
        @test length(gdata) == 16
        # Spot-check: byte 0 = 0x01, byte 8 = 0x11.
        @test gdata[1] == 0x01
        @test gdata[9] == 0x11
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        # Oracle: dst[9] = byte 9 of concatenated = 0x12 = 18.
        for x in Int8(-3):Int8(3)
            @test simulate(c, x) == Int8(0x12)
        end
    end

    @testset "<{ i64, i32, [4 x i8] }> LSB-first byte packing" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "zxhg_struct_mixed_widths.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(
            path; entry_function="zxhg_struct_mixed_widths")
        @test haskey(parsed.globals, :gmix)
        (gdata, gw) = parsed.globals[:gmix]
        @test gw == 8
        @test length(gdata) == 16
        # i64 1234605616436508552 = 0x1122334455667788
        # LSB-first bytes 0..7 = [0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11]
        @test gdata[1] == 0x88
        @test gdata[2] == 0x77
        @test gdata[8] == 0x11
        # i32 -16777216 = 0xff000000 LSB-first bytes 8..11 = [0x00, 0x00, 0x00, 0xff]
        @test gdata[9]  == 0x00
        @test gdata[12] == 0xff
        # [4 x i8] AA BB CC DD at bytes 12..15
        @test gdata[13] == 0xaa
        @test gdata[16] == 0xdd
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        # Oracle: dst[0] = 0x88 reinterpret as signed Int8 = -120.
        for x in Int8(-3):Int8(3)
            @test simulate(c, x) == Int8(-120)
        end
    end

    @testset "<{ [4 x i8], [4 x i8] }> zeroinitializer (ConstantAggregateZero arm)" begin
        # LLVM 18 quirk: a whole-struct `zeroinitializer` parses as
        # `LLVM.ConstantAggregateZero` (not a `ConstantStruct` of zero
        # fields). The companion ConstantAggregateZero arm in
        # `_extract_const_globals` handles this directly.
        path = joinpath(@__DIR__, "fixtures", "ll", "zxhg_struct_aggregate_zero.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(
            path; entry_function="zxhg_struct_aggregate_zero")
        @test haskey(parsed.globals, :gzero)
        (gdata, gw) = parsed.globals[:gzero]
        @test gw == 8
        @test length(gdata) == 8
        @test all(b -> b == 0, gdata)
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        for x in Int8(-3):Int8(3)
            @test simulate(c, x) == Int8(0)
        end
    end

    @testset "{ i8, i32 } non-packed: ABI padding honored via LLVM.offsetof" begin
        # Layout under e-p:64-i64:64-... : i8 at off 0, 3 bytes padding,
        # i32 at off 4. Total 8 bytes. With i32=256 (0x00000100 LE =
        # [00, 01, 00, 00]), byte 5 = 0x01.
        path = joinpath(@__DIR__, "fixtures", "ll", "zxhg_struct_non_packed.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(
            path; entry_function="zxhg_struct_non_packed")
        @test haskey(parsed.globals, :gnp)
        (gdata, gw) = parsed.globals[:gnp]
        @test gw == 8
        @test length(gdata) == 8
        @test gdata[1] == 0x63       # i8 99 at off 0
        @test gdata[2] == 0x00       # padding
        @test gdata[3] == 0x00       # padding
        @test gdata[4] == 0x00       # padding
        @test gdata[5] == 0x00       # i32 256 LSB
        @test gdata[6] == 0x01
        @test gdata[7] == 0x00
        @test gdata[8] == 0x00
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        for x in Int8(-3):Int8(3)
            @test simulate(c, x) == Int8(1)
        end
    end

    # ---- Reject (precise breadcrumb assertion) ----

    @testset "ptr-field struct rejects with Bennett-zxhg-ptrfield" begin
        # `<{ ptr, [24 x i8] }>` mirrors the t5_tr2_hashmap.ll:153 shape
        # exactly. `_flatten_struct_to_bytes` returns nothing on the ptr
        # field; the global never enters parsed.globals; G5 fires with
        # the precise breadcrumb.
        path = joinpath(@__DIR__, "fixtures", "ll", "zxhg_struct_ptr_field_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="zxhg_struct_ptr_field")
        try
            Bennett.extract_parsed_ir_from_ll(
                path; entry_function="zxhg_struct_ptr_field")
            @test false
        catch e
            msg = sprint(showerror, e)
            @test occursin("Bennett-doih", msg)
            @test occursin("Bennett-zxhg-ptrfield", msg)
            @test occursin("gptrstruct", msg)
        end
    end

    @testset "nested struct with inner ptr rejects (recursive)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "zxhg_struct_nested_struct_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="zxhg_struct_nested")
        try
            Bennett.extract_parsed_ir_from_ll(
                path; entry_function="zxhg_struct_nested")
            @test false
        catch e
            msg = sprint(showerror, e)
            @test occursin("Bennett-doih", msg)
            @test occursin("Bennett-zxhg-ptrfield", msg)
        end
    end

    @testset "float-field struct rejects" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "zxhg_struct_float_field_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="zxhg_struct_float")
        try
            Bennett.extract_parsed_ir_from_ll(
                path; entry_function="zxhg_struct_float")
            @test false
        catch e
            msg = sprint(showerror, e)
            @test occursin("Bennett-doih", msg)
            @test occursin("Bennett-zxhg-ptrfield", msg)
        end
    end

    @testset "i128-field struct rejects (64-bit-max policy)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "zxhg_struct_too_wide_int_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="zxhg_struct_too_wide")
        try
            Bennett.extract_parsed_ir_from_ll(
                path; entry_function="zxhg_struct_too_wide")
            @test false
        catch e
            msg = sprint(showerror, e)
            @test occursin("Bennett-doih", msg)
            @test occursin("Bennett-zxhg-ptrfield", msg)
        end
    end

    # ---- T5 end-to-end smoke ----

    @testset "T5 acceptance: t5_tr2_hashmap.ll:153 shape fails loud" begin
        # Exact mirror of build/t5_tr2_hashmap.ll:153's
        # `<{ ptr, [24 x i8] }>` global with non-null ptr first field
        # (pointing at a real `[16 x i8]` constant). This pins the
        # explicit "fails loud with a precise message" branch of the
        # Bennett-zxhg acceptance criterion.
        path = joinpath(@__DIR__, "fixtures", "ll", "zxhg_t5_tr2_smoke.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="zxhg_t5_tr2_smoke")
        try
            Bennett.extract_parsed_ir_from_ll(
                path; entry_function="zxhg_t5_tr2_smoke")
            @test false
        catch e
            msg = sprint(showerror, e)
            @test occursin("Bennett-doih", msg)
            @test occursin("Bennett-zxhg-ptrfield", msg)
            @test occursin("anon.7665023084100688a96add9323205da2.0", msg)
        end
    end

end
