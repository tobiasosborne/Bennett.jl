# Bennett-fd1r: src/narrow.jl's `_narrow_inst(::IRInsertValue, W)` once read
# a nonexistent `inst.elem_count` field (the real field is `n_elems`, per
# ir_types.jl). That would have been a MethodError/`has no field elem_count`
# crash the moment narrowing ever reached an IRInsertValue node — but the
# path is dead in practice: `bit_width` narrowing and the StructType/
# aggregate extraction path are mutually exclusive (see src/narrow.jl's
# Bennett-6bu3 comment), so no end-to-end `reversible_compile(...;
# bit_width=W)` call can drive an IRInsertValue through `_narrow_ir`.
#
# Bennett-6bu3 (closed 2026-06-23, independently of fd1r) already repaired
# both `_narrow_inst(::IRInsertValue, ...)` and `_narrow_inst(::IRExtractValue,
# ...)` to use the real `n_elems` field and the real ctors — but no direct
# regression test existed pinning that repair, so a future refactor could
# silently reintroduce the `elem_count` typo without any test failing (the
# path being dead means no integration test would ever exercise it either).
# This file closes that gap with a direct unit test of the internal
# `_narrow_inst` function, per the "unreachable end-to-end" fallback in
# Bennett-fd1r's task description.
using Test
using Bennett

@testset "Bennett-fd1r: _narrow_inst(::IRInsertValue) uses n_elems, not elem_count" begin
    @testset "homogeneous (empty field_widths) — narrows elem_width to W" begin
        # Reproduces the exact pre-6bu3 crash shape: calling _narrow_inst on
        # an IRInsertValue used to throw `type IRInsertValue has no field
        # elem_count` (or, after the ctor mismatch, a MethodError) the moment
        # this line ran. Would fail RED against the pre-6bu3 body; green now.
        inst = Bennett.IRInsertValue(:dest, Bennett.ssa(:agg), Bennett.ssa(:val),
                                      0, 8, 2)  # homogeneous: 2 elements, 8-bit each
        @test isempty(inst.field_widths)

        narrowed = Bennett._narrow_inst(inst, 32)
        @test narrowed isa Bennett.IRInsertValue
        @test narrowed.dest == :dest
        @test narrowed.agg == Bennett.ssa(:agg)
        @test narrowed.val == Bennett.ssa(:val)
        @test narrowed.index == 0
        @test narrowed.elem_width == 32        # narrowed from 8 to W=32
        @test narrowed.n_elems == inst.n_elems  # count preserved, NOT reinterpreted as width
        @test isempty(narrowed.field_widths)
    end

    @testset "struct (non-empty field_widths) — passes through unchanged" begin
        # StructType aggregates are a ptr-cell-only shape the circuit-width
        # narrowing pass never touches; must round-trip totally rather than
        # attempt to narrow per-field widths.
        inst = Bennett.IRInsertValue(:dest2, Bennett.ssa(:agg2), Bennett.ssa(:val2),
                                      1, 0, 2, [8, 64])
        @test !isempty(inst.field_widths)

        narrowed = Bennett._narrow_inst(inst, 16)
        @test narrowed === inst  # unchanged identity, not just equal fields
        @test narrowed.field_widths == [8, 64]
    end
end

@testset "Bennett-fd1r: _narrow_inst(::IRExtractValue) uses n_elems, not elem_count" begin
    @testset "homogeneous (empty field_widths) — narrows elem_width to W" begin
        inst = Bennett.IRExtractValue(:dest3, Bennett.ssa(:agg3), 0, 8, 3)
        @test isempty(inst.field_widths)

        narrowed = Bennett._narrow_inst(inst, 16)
        @test narrowed isa Bennett.IRExtractValue
        @test narrowed.dest == :dest3
        @test narrowed.agg == Bennett.ssa(:agg3)
        @test narrowed.index == 0
        @test narrowed.elem_width == 16
        @test narrowed.n_elems == inst.n_elems
        @test isempty(narrowed.field_widths)
    end

    @testset "struct (non-empty field_widths) — passes through unchanged" begin
        inst = Bennett.IRExtractValue(:dest4, Bennett.ssa(:agg4), 1, 0, 2, [16, 32])
        narrowed = Bennett._narrow_inst(inst, 8)
        @test narrowed === inst
        @test narrowed.field_widths == [16, 32]
    end
end
