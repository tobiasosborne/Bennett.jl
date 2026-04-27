@testset "Bennett-qmk6 / U82 + Bennett-dq8l / U81 — precise _type_width error dispatch" begin

    # Pre-fix: `_type_width` (src/ir_extract.jl:2849) handled IntegerType,
    # ArrayType, FloatingPointType explicitly, then fell through to a
    # generic "unsupported LLVM type for width query: <type>" message.
    # For VectorType / StructType / VoidType this is misleading — the
    # user can't tell whether vectors are unsupported (qmk6) or whether
    # a void return reached an internal width query (dq8l).
    #
    # Post-fix: `_type_width` dispatches VectorType, StructType, and
    # VoidType to precise error messages naming the kind, the type's
    # textual form, and the relevant Bennett-side limitation.

    using LLVM
    using Bennett: _type_width

    @testset "VectorType: precise error (Bennett-qmk6)" begin
        LLVM.Context() do _
            for vt in (LLVM.VectorType(LLVM.Int32Type(), 4),
                       LLVM.VectorType(LLVM.Int64Type(), 2),
                       LLVM.VectorType(LLVM.Int8Type(), 16))
                err = try
                    _type_width(vt); ""
                catch e
                    sprint(showerror, e)
                end
                @test occursin("VectorType", err) || occursin("vector", err)
                @test occursin("qmk6", err) || occursin("cc0.7", err)
                @test !contains(err, "unsupported LLVM type for width query")  # not the generic
            end
        end
    end

    @testset "VoidType: precise error (Bennett-dq8l)" begin
        LLVM.Context() do _
            err = try
                _type_width(LLVM.VoidType()); ""
            catch e
                sprint(showerror, e)
            end
            @test occursin("VoidType", err) || occursin("void", err)
            @test occursin("dq8l", err)
            @test !contains(err, "unsupported LLVM type for width query")  # not the generic
        end
    end

    @testset "StructType: precise error" begin
        LLVM.Context() do _
            st = LLVM.StructType([LLVM.Int32Type(), LLVM.Int64Type()])
            err = try
                _type_width(st); ""
            catch e
                sprint(showerror, e)
            end
            @test occursin("StructType", err) || occursin("struct", err)
        end
    end

    @testset "Existing happy paths unchanged" begin
        LLVM.Context() do _
            @test _type_width(LLVM.Int8Type()) == 8
            @test _type_width(LLVM.Int16Type()) == 16
            @test _type_width(LLVM.Int32Type()) == 32
            @test _type_width(LLVM.Int64Type()) == 64
            @test _type_width(LLVM.DoubleType()) == 64
            @test _type_width(LLVM.FloatType()) == 32
            @test _type_width(LLVM.HalfType()) == 16
            @test _type_width(LLVM.ArrayType(LLVM.Int32Type(), 4)) == 128
        end
    end
end
