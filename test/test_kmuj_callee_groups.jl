# Bennett-kmuj / U106 — register_callee! registry was 45 unstructured
# flat lines in src/Bennett.jl. Refactored into per-domain const tuples
# and a single registration loop.  These tests pin:
#   1. Each group is a tuple of `Function` (not a Vector or list).
#   2. Groups are disjoint (no callee registered twice).
#   3. Every grouped callee actually ends up in `_known_callees` after
#      module load — i.e. the registration loop fires for every entry.
#   4. The total flat count matches the expected 45 (a future
#      ungrouped registration would either show up here or break the
#      disjointness check).

using Test
using Bennett

@testset "Bennett-kmuj / U106 — callee registration groups" begin

    @testset "each group is a tuple of Function" begin
        for group in Bennett._CALLEE_GROUPS
            @test group isa Tuple
            @test !isempty(group)
            for f in group
                @test f isa Function
            end
        end
    end

    @testset "groups are disjoint (no callee registered twice)" begin
        flat = Function[]
        for group in Bennett._CALLEE_GROUPS, f in group
            push!(flat, f)
        end
        @test length(flat) == length(unique(flat))
    end

    @testset "every grouped callee is in _known_callees" begin
        for group in Bennett._CALLEE_GROUPS, f in group
            name = string(nameof(f))
            @test haskey(Bennett._known_callees, name)
            @test Bennett._known_callees[name] === f
        end
    end

    @testset "total registered count matches expected" begin
        # 2 + 5 + 2 + 4 + 10 + 5 + 6 + 12 + 6 = 52
        # (FP_CMP grew from 4 to 10 with Bennett-d77b / U132: 6 new
        # soft_fcmp_* primitives ord/uno/one/ueq/ult/ule completing the
        # LLVM fcmp predicate table.)
        # (FP_ROUND grew from 3 to 4 with Bennett-2hhx / U136: soft_round
        # roundToIntegralTiesToEven joining floor/ceil/trunc.)
        n_grouped = sum(length(g) for g in Bennett._CALLEE_GROUPS)
        @test n_grouped == 52

        # _known_callees may contain more if anything else (test fixtures,
        # other modules) registered, but it must contain at LEAST the 52
        # we register from the groups.
        @test length(Bennett._known_callees) >= 52
    end

    @testset "group sizes match the documented partition" begin
        @test length(Bennett._CALLEES_INTEGER_DIV)        == 2
        @test length(Bennett._CALLEES_FP_BINARY)          == 5
        @test length(Bennett._CALLEES_FP_UNARY)           == 2
        @test length(Bennett._CALLEES_FP_ROUND)           == 4   # 2hhx: 3 → 4
        @test length(Bennett._CALLEES_FP_CMP)             == 10  # d77b: 4 → 10
        @test length(Bennett._CALLEES_FP_CONV)            == 5
        @test length(Bennett._CALLEES_FP_TRANS)           == 6
        @test length(Bennett._CALLEES_MUX_EXCH)           == 12
        @test length(Bennett._CALLEES_MUX_EXCH_GUARDED)   == 6
    end
end
