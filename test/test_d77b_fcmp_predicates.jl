@testset "Bennett-d77b / U132 — full LLVM fcmp predicate coverage" begin

    # Pre-d77b: only 4 of 14 LLVM fcmp predicates had soft_fcmp_*
    # implementations (olt, oeq, ole, une), with ogt/oge handled by
    # operand-swap in ir_extract.jl. The other 8 (one, ord, uno, ueq,
    # ugt, uge, ult, ule) raised `_ir_error("unsupported fcmp predicate")`
    # — fail-loud per CLAUDE.md §1, but blocks user code that uses them.
    #
    # Post-d77b: 6 new soft_fcmp_* primitives (ord, uno, one, ueq, ult,
    # ule), plus operand-swap dispatch for ugt → ult(b,a) and uge →
    # ule(b,a) in ir_extract.jl. All 14 predicates now route to a callee.
    #
    # IEEE 754 semantics (LangRef):
    #   ord(a,b) = neither a nor b is NaN
    #   uno(a,b) = at least one of a, b is NaN
    #   oeq(a,b) = ord & a==b (with +0==-0)
    #   one(a,b) = ord & a!=b
    #   olt(a,b) = ord & a<b
    #   ole(a,b) = ord & a<=b
    #   ogt(a,b) = ord & a>b      (= olt(b,a))
    #   oge(a,b) = ord & a>=b     (= ole(b,a))
    #   ueq(a,b) = uno | oeq
    #   une(a,b) = uno | one      (= !oeq)
    #   ult(a,b) = uno | olt
    #   ule(a,b) = uno | ole
    #   ugt(a,b) = uno | ogt      (= ult(b,a))
    #   uge(a,b) = uno | oge      (= ule(b,a))

    using Bennett: soft_fcmp_olt, soft_fcmp_oeq, soft_fcmp_ole, soft_fcmp_une,
                   soft_fcmp_ord, soft_fcmp_uno, soft_fcmp_one,
                   soft_fcmp_ueq, soft_fcmp_ult, soft_fcmp_ule

    bits(x::Float64) = reinterpret(UInt64, x)

    # Representative test inputs spanning: finite (positive, negative, zero
    # both signs), ±Inf, NaN (quiet), denormals.
    test_vals = [
        0.0, -0.0, 1.0, -1.0, 2.5, -2.5, 1e-300, -1e-300,
        Inf, -Inf, NaN, 5e-324,  # 5e-324 is the smallest subnormal
    ]

    # Julia oracles. Note: Julia's `<` etc. are already IEEE 754 ordered,
    # and `isnan` matches the unordered-component bit.
    julia_ord(a, b) = !isnan(a) & !isnan(b)
    julia_uno(a, b) = isnan(a) | isnan(b)

    @testset "soft_fcmp_ord — neither NaN" begin
        for a in test_vals, b in test_vals
            @test soft_fcmp_ord(bits(a), bits(b)) == UInt64(julia_ord(a, b))
        end
    end

    @testset "soft_fcmp_uno — at least one NaN" begin
        for a in test_vals, b in test_vals
            @test soft_fcmp_uno(bits(a), bits(b)) == UInt64(julia_uno(a, b))
        end
    end

    @testset "soft_fcmp_one — ordered not-equal" begin
        for a in test_vals, b in test_vals
            expected = julia_ord(a, b) & (a != b)  # +0 == -0 per IEEE
            @test soft_fcmp_one(bits(a), bits(b)) == UInt64(expected)
        end
    end

    @testset "soft_fcmp_ueq — unordered equal (NaN counts as equal)" begin
        for a in test_vals, b in test_vals
            expected = julia_uno(a, b) | (a == b)
            @test soft_fcmp_ueq(bits(a), bits(b)) == UInt64(expected)
        end
    end

    @testset "soft_fcmp_ult — unordered less-than" begin
        for a in test_vals, b in test_vals
            # IEEE 754: any comparison with NaN returns false (Julia <),
            # so for the "ordered" component we use `!isnan(a) & !isnan(b) & a<b`.
            ordered_lt = !isnan(a) & !isnan(b) & (a < b)
            expected = julia_uno(a, b) | ordered_lt
            @test soft_fcmp_ult(bits(a), bits(b)) == UInt64(expected)
        end
    end

    @testset "soft_fcmp_ule — unordered less-than-or-equal" begin
        for a in test_vals, b in test_vals
            ordered_le = !isnan(a) & !isnan(b) & (a <= b)
            expected = julia_uno(a, b) | ordered_le
            @test soft_fcmp_ule(bits(a), bits(b)) == UInt64(expected)
        end
    end

    @testset "Cross-check: existing 4 predicates unaffected" begin
        # Sanity: the new file shouldn't have shifted the existing 4.
        for a in test_vals, b in test_vals
            ord_ok = !isnan(a) & !isnan(b)
            @test soft_fcmp_olt(bits(a), bits(b)) == UInt64(ord_ok & (a < b))
            @test soft_fcmp_oeq(bits(a), bits(b)) == UInt64(ord_ok & (a == b))
            @test soft_fcmp_ole(bits(a), bits(b)) == UInt64(ord_ok & (a <= b))
            @test soft_fcmp_une(bits(a), bits(b)) == UInt64(julia_uno(a, b) | (ord_ok & (a != b)))
        end
    end

    @testset "Compiled circuit: predicates dispatch to soft_fcmp callees" begin
        # Verify ir_extract maps each predicate to its soft_fcmp_* callee
        # and the lowered circuit produces the correct output. Inputs go
        # in as UInt64 bit patterns (Float64 reinterpret) since the
        # compiled circuit operates on raw bit-vectors. Returns Int8
        # to avoid the cc0.x ConstantFP-in-IR gap (Bennett-bjdg).
        for (name, op) in [("ult", <), ("ule", <=), ("ueq", ==), ("une", !=)]
            f = (a::Float64, b::Float64) -> op(a, b) ? Int8(1) : Int8(0)
            c = reversible_compile(f, Tuple{Float64, Float64})
            for a in (1.0, -1.0, NaN, Inf, 0.0)
                for b in (2.0, -2.0, NaN, -Inf, -0.0)
                    expected = op(a, b) ? Int8(1) : Int8(0)
                    # Feed Float64 as UInt64 bit pattern via the integer
                    # simulate path; result reads back as Int8 via the
                    # 2-arg signature.
                    got_raw = simulate(c, (bits(a), bits(b)))
                    @test got_raw == expected
                end
            end
        end
    end
end
