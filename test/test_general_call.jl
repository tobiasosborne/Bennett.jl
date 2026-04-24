@testset "General function call inlining" begin

    @testset "user-defined helper function" begin
        # A helper function that the compiler should inline
        double(x::UInt8) = x + x

        # A function that calls the helper
        function quad(x::UInt8)::UInt8
            return double(double(x))
        end

        c = reversible_compile(quad, UInt8)
        for x in UInt8(0):UInt8(63)
            @test simulate(c, x) == quad(x)
        end
        @test verify_reversibility(c)
    end

    @testset "multi-arg helper" begin
        clamp8(x::UInt8, lo::UInt8, hi::UInt8) = max(min(x, hi), lo)

        function clamped_add(a::UInt8, b::UInt8)::UInt8
            return clamp8(a + b, UInt8(0), UInt8(100))
        end

        c = reversible_compile(clamped_add, UInt8, UInt8)
        for a in UInt8(0):UInt8(15), b in UInt8(0):UInt8(15)
            @test simulate(c, (a, b)) == clamped_add(a, b)
        end
        @test verify_reversibility(c)
    end

    @testset "register_callee! for user function" begin
        @noinline function my_helper(x::UInt64)::UInt64
            return (x * x) & UInt64(0xFF)
        end

        register_callee!(my_helper)

        function use_my_helper(x::UInt64)::UInt64
            return my_helper(x) + my_helper(x + UInt64(1))
        end

        c = reversible_compile(use_my_helper, UInt64)
        for x in UInt64(0):UInt64(15)
            @test simulate(c, x) == use_my_helper(x)
        end
        @test verify_reversibility(c)
    end
end
