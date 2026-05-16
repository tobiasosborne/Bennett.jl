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
        # 2 + 5 + 2 + 4 + 10 + 5 + 27 + 22 + 11 = 88
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
        # e_asin.c branchless port + shared _asin_R helper, Tier C1.3),
        # then to 18 with Bennett-bd7f (soft_acos: musl acos.c branchless
        # port reusing the same _asin_R helper, Tier C1.4), then to 19 with
        # Bennett-7goc (soft_atan2: musl atan2.c built on soft_atan,
        # Tier C1.5), then one-per-bead through the Tier C1 hyperbolic +
        # Tier C2 family — 20 m2bv (soft_tanh), 21 ky5n (soft_sinh),
        # 22 bybh (soft_cosh), 23 sfx9 (soft_asinh), 24 eq9p (soft_acosh),
        # 25 g82n (soft_atanh, completes Tier C1 11/11), 26 0ulc
        # (soft_log1p, Tier C2.1), 27 o7cy (soft_expm1, Tier C2.2).)
        n_grouped = sum(length(g) for g in Bennett._CALLEE_GROUPS)
        @test n_grouped == 97   # mq6f: +1 (soft_round_away); k2w6+p19b: +6 (_CALLEES_FP_MINMAX, new group); z2dj: +2 (_CALLEES_PERSISTENT, new group)

        # _known_callees may contain more if anything else (test fixtures,
        # other modules) registered, but it must contain at LEAST the 97
        # we register from the groups.
        @test length(Bennett._known_callees) >= 97
    end

    @testset "group sizes match the documented partition" begin
        @test length(Bennett._CALLEES_INTEGER_DIV)        == 2
        @test length(Bennett._CALLEES_FP_BINARY)          == 5
        @test length(Bennett._CALLEES_FP_UNARY)           == 2
        @test length(Bennett._CALLEES_FP_ROUND)           == 5   # 2hhx: 3 → 4; mq6f: 4 → 5 (soft_round_away)
        @test length(Bennett._CALLEES_FP_MINMAX)          == 6   # k2w6 NEW group: 4 (soft_fmin/fmax/fminimum/fmaximum); p19b: 4 → 6 (soft_minimumnum/maximumnum)
        @test length(Bennett._CALLEES_FP_CMP)             == 10  # d77b: 4 → 10
        @test length(Bennett._CALLEES_FP_CONV)            == 5
        @test length(Bennett._CALLEES_FP_TRANS)           == 27  # 582: 6→9 (log family); emv: 9→11 (pow+powi); jexo: 11→12 (soft_pow_julia); 3mo: 12→14 (soft_sin, soft_cos); s1zl: 14→15 (soft_tan); qpke: 15→16 (soft_atan); ckvj: 16→17 (soft_asin); bd7f: 17→18 (soft_acos); 7goc: 18→19 (soft_atan2); m2bv: 19→20 (soft_tanh); ky5n: 20→21 (soft_sinh); bybh: 21→22 (soft_cosh); sfx9: 22→23 (soft_asinh); eq9p: 23→24 (soft_acosh); g82n: 24→25 (soft_atanh); 0ulc: 25→26 (soft_log1p); o7cy: 26→27 (soft_expm1)
        @test length(Bennett._CALLEES_MUX_EXCH)           == 22  # nj6c: 12 → 22
        @test length(Bennett._CALLEES_MUX_EXCH_GUARDED)   == 11  # nj6c:  6 → 11
        @test length(Bennett._CALLEES_PERSISTENT)         == 2   # z2dj NEW group: linear_scan_pmap_set/get
    end
end
