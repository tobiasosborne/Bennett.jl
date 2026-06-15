using Test
using Bennett
using Bennett: reversible_compile, simulate, verify_reversibility,
               gate_count, extract_parsed_ir, extract_parsed_ir_from_ll

# Bennett-dv1z — heterogeneous bits-struct sret support.
#
# Julia routes tuple returns of >16 bytes (x86_64 SysV) through the sret
# calling convention. When the tuple fields have DIFFERING integer widths
# (e.g. `(Int64, Int8)`) the sret pointee is an LLVM `StructType` like
# `{i64, i8}`, NOT the homogeneous `[N x iM]` array the pre-dv1z extractor
# handled. dv1z adds: an `IRInsertBits` IR node (arbitrary-bit-offset packing),
# its lowering, the `StructType` detection arm + per-field layout extraction,
# the exact-byte-offset → field-index store map, and the `IRInsertBits` chain
# synthesis at `ret void`.
#
# Correctness contract verified here element-by-element via `simulate`:
#   * `ret_width == sum(field widths)` — the PACKED bit width, NOT the padded
#     ABI size (e.g. 72 for {i64,i8}, never 128/16).
#   * `ret_elem_widths == [field widths in field order]`.
#   * wire order = field0-low / field1-high (contiguous bit offsets in field
#     order), so `simulate`'s tuple element `k` reads back exactly field `k`.

@testset "dv1z heterogeneous bits-struct sret" begin

    @testset "{i64, i8} single-return oracle" begin
        f(x::Int64) = (x + 1, Int8(x & 0x7f))
        pir = extract_parsed_ir(f, Tuple{Int64})
        @test pir.ret_elem_widths == [64, 8]
        @test pir.ret_width == 72          # packed, NOT the padded ABI size (128)

        circuit = reversible_compile(f, Int64)
        @test verify_reversibility(circuit)
        @test circuit.output_elem_widths == [64, 8]

        for x in Int64[0, 1, 5, -1, -100, 127, 128, 12345678,
                       typemax(Int64), typemin(Int64)]
            out = simulate(circuit, (x,))
            expected = f(x)
            # field0 (low 64 bits) == x+1 ; field1 (high 8 bits) == Int8(x & 0x7f)
            @test (out[1] % Int64) == expected[1]
            @test (out[2] % UInt8) == (expected[2] % UInt8)
        end
    end

    @testset "{i8, i64} reversed field order" begin
        g(x::Int64) = (Int8(x & 0x7f), x + 1)
        pir = extract_parsed_ir(g, Tuple{Int64})
        @test pir.ret_elem_widths == [8, 64]
        @test pir.ret_width == 72

        circuit = reversible_compile(g, Int64)
        @test verify_reversibility(circuit)
        @test circuit.output_elem_widths == [8, 64]
        for x in Int64[0, 5, -1, 127, 128, typemax(Int64), typemin(Int64)]
            out = simulate(circuit, (x,))
            expected = g(x)
            @test (out[1] % UInt8) == (expected[1] % UInt8)
            @test (out[2] % Int64) == expected[2]
        end
    end

    @testset "{i32, i8, i64} three fields, mixed widths" begin
        h(x::Int64) = (Int32(x & 0x7fffffff), Int8(x & 0x7f), x + 2)
        pir = extract_parsed_ir(h, Tuple{Int64})
        @test pir.ret_elem_widths == [32, 8, 64]
        @test pir.ret_width == 104         # 32+8+64, NOT padded 16 bytes (128)

        circuit = reversible_compile(h, Int64)
        @test verify_reversibility(circuit)
        @test circuit.output_elem_widths == [32, 8, 64]
        for x in Int64[0, 5, -1, 127, 1 << 40, typemax(Int64), typemin(Int64)]
            out = simulate(circuit, (x,))
            expected = h(x)
            @test (out[1] % UInt32) == (expected[1] % UInt32)
            @test (out[2] % UInt8)  == (expected[2] % UInt8)
            @test (out[3] % Int64)  == expected[3]
        end
    end

    # ---- Reject fixtures: non-integer / nested fields fail loud --------------
    # Written as inline .ll so we can exercise field types Julia won't emit
    # directly. Each must throw with BOTH the "only fixed-width integer
    # bits-struct fields" breadcrumb and the "Bennett-dv1z" tag.

    _dv1z_dl = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"

    function _dv1z_reject(name::String, body::String)
        path = tempname() * ".ll"
        open(path, "w") do io
            write(io, "target datalayout = \"$_dv1z_dl\"\n\n")
            write(io, body)
        end
        @test_throws ErrorException extract_parsed_ir_from_ll(path; entry_function=name)
        try
            extract_parsed_ir_from_ll(path; entry_function=name)
            @test false  # unreachable
        catch e
            msg = sprint(showerror, e)
            @test occursin("only fixed-width integer bits-struct fields", msg)
            @test occursin("Bennett-dv1z", msg)
        end
    end

    @testset "reject sret({i64, ptr}) — pointer field" begin
        _dv1z_reject("ret_ptr_field", """
        define void @ret_ptr_field(ptr noalias nocapture sret({ i64, ptr }) align 8 %ret, i64 %x) {
          store i64 %x, ptr %ret, align 8
          %g = getelementptr inbounds i8, ptr %ret, i64 8
          store ptr null, ptr %g, align 8
          ret void
        }
        """)
    end

    @testset "reject sret({double, i8}) — float field" begin
        _dv1z_reject("ret_double_field", """
        define void @ret_double_field(ptr noalias nocapture sret({ double, i8 }) align 8 %ret, double %x) {
          store double %x, ptr %ret, align 8
          %g = getelementptr inbounds i8, ptr %ret, i64 8
          store i8 0, ptr %g, align 8
          ret void
        }
        """)
    end

    @testset "reject nested sret({i64, {i64,i64}}) — nested struct field" begin
        _dv1z_reject("ret_nested_field", """
        define void @ret_nested_field(ptr noalias nocapture sret({ i64, { i64, i64 } }) align 8 %ret, i64 %x) {
          store i64 %x, ptr %ret, align 8
          ret void
        }
        """)
    end

    # ---- Homogeneous regression re-pin (gate-count baseline unchanged) -------
    @testset "regression: homogeneous [N x iM] path unchanged" begin
        # The dv1z StructType arm must not perturb the homogeneous ArrayType arm.
        swap2(a::Int8, b::Int8) = (b, a)
        circuit = reversible_compile(swap2, Int8, Int8)
        for a in Int8(0):Int8(7), b in Int8(0):Int8(7)
            @test simulate(circuit, (a, b)) == (b, a)
        end
        @test verify_reversibility(circuit)
        @test gate_count(circuit).total == 66   # CLAUDE.md rule 6 baseline
    end
end
