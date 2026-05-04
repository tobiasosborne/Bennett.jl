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
        # 2 + 5 + 2 + 4 + 10 + 5 + 16 + 22 + 11 = 77
        # (FP_CMP grew from 4 to 10 with Bennett-d77b / U132: 6 new
        # soft_fcmp_* primitives ord/uno/one/ueq/ult/ule completing the
        # LLVM fcmp predicate table.)
        # (FP_ROUND grew from 3 to 4 with Bennett-2hhx / U136: soft_round
        # roundToIntegralTiesToEven joining floor/ceil/trunc.)
        # (MUX_EXCH grew from 12 to 22 + GUARDED from 6 to 11 with
        # Bennett-nj6c / dnh phase 1a: 5 new shapes (3,8)/(5,8)/(6,8)/
        # (7,8)/(3,16) close the N·W ≤ 64 lattice.)
        # (FP_TRANS grew from 6 to 9 with Bennett-582 (log family), to
        # 11 with Bennett-emv (soft_pow + soft_powi), then to 12 with
        # Bennett-jexo (soft_pow_julia: bit-exact vs Base.:^), then to
        # 14 with Bennett-3mo (soft_sin + soft_cos: musl + Payne-Hanek),
        # then to 15 with Bennett-s1zl (soft_tan: musl __tan + rem_pio2,
        # first close in Tier C1 trig completion), then to 16 with
        # Bennett-qpke (soft_atan: musl s_atan branchless port,
        # Tier C1.2), then to 17 with Bennett-ckvj (soft_asin: musl
        # e_asin.c branchless port + shared _asin_R helper, Tier C1.3).)
        n_grouped = sum(length(g) for g in Bennett._CALLEE_GROUPS)
        @test n_grouped == 78

        # _known_callees may contain more if anything else (test fixtures,
        # other modules) registered, but it must contain at LEAST the 78
        # we register from the groups.
        @test length(Bennett._known_callees) >= 78
    end

    @testset "group sizes match the documented partition" begin
        @test length(Bennett._CALLEES_INTEGER_DIV)        == 2
        @test length(Bennett._CALLEES_FP_BINARY)          == 5
        @test length(Bennett._CALLEES_FP_UNARY)           == 2
        @test length(Bennett._CALLEES_FP_ROUND)           == 4   # 2hhx: 3 → 4
        @test length(Bennett._CALLEES_FP_CMP)             == 10  # d77b: 4 → 10
        @test length(Bennett._CALLEES_FP_CONV)            == 5
        @test length(Bennett._CALLEES_FP_TRANS)           == 17  # 582: 6→9 (log family); emv: 9→11 (pow+powi); jexo: 11→12 (soft_pow_julia); 3mo: 12→14 (soft_sin, soft_cos); s1zl: 14→15 (soft_tan); qpke: 15→16 (soft_atan); ckvj: 16→17 (soft_asin)
        @test length(Bennett._CALLEES_MUX_EXCH)           == 22  # nj6c: 12 → 22
        @test length(Bennett._CALLEES_MUX_EXCH_GUARDED)   == 11  # nj6c:  6 → 11
    end
end
