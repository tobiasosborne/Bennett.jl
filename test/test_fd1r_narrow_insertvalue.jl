# Bennett-fd1r: src/narrow.jl's `_narrow_inst(::IRInsertValue, W)` once read
# a nonexistent `inst.elem_count` field (the real field is `n_elems`, per
# ir_types.jl) — a latent crash the moment narrowing reached an IRInsertValue
# node, which no end-to-end test could catch because `bit_width` narrowing and
# the StructType/aggregate extraction path were believed to be mutually
# exclusive.  Bennett-6bu3 repaired the handlers to use the real fields, and
# this file drove `_narrow_inst` directly to pin that repair.
#
# Bennett-mrhg (2026-09-26) turned the premise inside out.  The two paths are
# NOT mutually exclusive: a tuple return reaches an IRInsertValue chain (or an
# alloca + store) under `bit_width`, and the Astra F13 witness proved the
# rewrite corrupts the aggregate layout.  Under the Bennett-mrhg SOUNDNESS
# contract these nodes are an aggregate FIELD LAYOUT (element widths, field
# index, per-field StructType widths), so `_narrow_ir` now refuses them loudly
# with an ArgumentError naming the bead instead of rewriting `elem_width`.
# These refusals are pinned here directly on `_narrow_inst`; the end-to-end
# tuple-return witnesses are in test/test_mrhg_narrow_soundness.jl.
using Test
using Bennett

@testset "Bennett-fd1r: _narrow_inst refuses aggregate nodes (Bennett-mrhg)" begin
    @testset "IRInsertValue — homogeneous and StructType both refuse" begin
        inst = Bennett.IRInsertValue(:dest, Bennett.ssa(:agg), Bennett.ssa(:val),
                                      0, 8, 2)  # homogeneous: 2 elements, 8-bit each
        @test isempty(inst.field_widths)
        @test_throws ArgumentError Bennett._narrow_inst(inst, 8, 32)

        inst2 = Bennett.IRInsertValue(:dest2, Bennett.ssa(:agg2), Bennett.ssa(:val2),
                                       1, 0, 2, [8, 64])
        @test !isempty(inst2.field_widths)
        @test_throws ArgumentError Bennett._narrow_inst(inst2, 8, 16)

        err = try
            Bennett._narrow_inst(inst, 8, 32)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test err isa ArgumentError && occursin("Bennett-mrhg", err.msg)
        @test err isa ArgumentError && occursin("IRInsertValue", err.msg)
    end

    @testset "IRExtractValue — homogeneous and StructType both refuse" begin
        inst = Bennett.IRExtractValue(:dest3, Bennett.ssa(:agg3), 0, 8, 3)
        @test isempty(inst.field_widths)
        @test_throws ArgumentError Bennett._narrow_inst(inst, 8, 16)

        inst2 = Bennett.IRExtractValue(:dest4, Bennett.ssa(:agg4), 1, 0, 2, [16, 32])
        @test !isempty(inst2.field_widths)
        @test_throws ArgumentError Bennett._narrow_inst(inst2, 8, 8)

        err = try
            Bennett._narrow_inst(inst, 8, 16)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test err isa ArgumentError && occursin("Bennett-mrhg", err.msg)
        @test err isa ArgumentError && occursin("IRExtractValue", err.msg)
    end
end
