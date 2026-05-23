@testset "Integer division and remainder" begin

    # Bennett-4lij: each testset compiles ONE circuit and runs ~2k independent
    # simulate(c, ...) calls. simulate() only mutates a local Vector{Bool} —
    # pure, thread-safe — so we Threads.@threads over the input Cartesian
    # product and assert the per-input result outside the threaded region.

    @testset "unsigned division (udiv) — expanded" begin
        function udiv_test(a::UInt8, b::UInt8)::UInt8
            return b == UInt8(0) ? UInt8(0) : div(a, b)
        end
        c = reversible_compile(udiv_test, UInt8, UInt8)
        # Full range for a, representative range for b
        bs = (UInt8(1), UInt8(2), UInt8(3), UInt8(7),
              UInt8(15), UInt8(16), UInt8(127), UInt8(128), UInt8(255))
        as = UInt8(0):UInt8(255)
        pairs = [(a, b) for a in as for b in bs]
        results = Vector{Tuple{UInt8,UInt8}}(undef, length(pairs))
        Threads.@threads for i in eachindex(pairs)
            (a, b) = pairs[i]
            results[i] = (UInt8(simulate(c, (a, b))), div(a, b))
        end
        for (got, expected) in results
            @test got == expected
        end
        # Boundary cases
        for (a, b) in [(UInt8(255), UInt8(1)), (UInt8(255), UInt8(255)),
                        (UInt8(128), UInt8(127)), (UInt8(0), UInt8(1))]
            @test simulate(c, (a, b)) == div(a, b)
        end
        @test verify_reversibility(c)
    end

    @testset "unsigned remainder (urem) — expanded" begin
        function urem_test(a::UInt8, b::UInt8)::UInt8
            return b == UInt8(0) ? UInt8(0) : rem(a, b)
        end
        c = reversible_compile(urem_test, UInt8, UInt8)
        bs = (UInt8(1), UInt8(2), UInt8(3), UInt8(7),
              UInt8(15), UInt8(16), UInt8(127), UInt8(128), UInt8(255))
        as = UInt8(0):UInt8(255)
        pairs = [(a, b) for a in as for b in bs]
        results = Vector{Tuple{UInt8,UInt8}}(undef, length(pairs))
        Threads.@threads for i in eachindex(pairs)
            (a, b) = pairs[i]
            results[i] = (UInt8(simulate(c, (a, b))), rem(a, b))
        end
        for (got, expected) in results
            @test got == expected
        end
        @test verify_reversibility(c)
    end

    @testset "signed division (sdiv) — expanded" begin
        function sdiv_test(a::Int8, b::Int8)::Int8
            return b == Int8(0) ? Int8(0) : div(a, b)
        end
        c = reversible_compile(sdiv_test, Int8, Int8)
        bs = (Int8(-4), Int8(-2), Int8(-1), Int8(1), Int8(2), Int8(4))
        pairs = [(a, b) for a in Int8(-8):Int8(7) for b in bs]
        results = Vector{Tuple{Int8,Int8}}(undef, length(pairs))
        Threads.@threads for i in eachindex(pairs)
            (a, b) = pairs[i]
            results[i] = (Int8(simulate(c, (a, b))), div(a, b))
        end
        for (got, expected) in results
            @test got == expected
        end
        # Edge cases (skip typemin/-1 which is UB: overflow)
        for (a, b) in [(typemin(Int8), Int8(1)), (typemax(Int8), Int8(1)),
                        (typemax(Int8), Int8(-1)),
                        (Int8(127), Int8(127)), (Int8(-128), Int8(127))]
            expected = div(a, b)
            got = Int8(simulate(c, (a, b)))
            @test got == expected
        end
        @test verify_reversibility(c)
    end

    @testset "signed remainder (srem)" begin
        function srem_test(a::Int8, b::Int8)::Int8
            return b == Int8(0) ? Int8(0) : rem(a, b)
        end
        c = reversible_compile(srem_test, Int8, Int8)
        bs = (Int8(-4), Int8(-2), Int8(-1), Int8(1), Int8(2), Int8(4))
        pairs = [(a, b) for a in Int8(-8):Int8(7) for b in bs]
        results = Vector{Tuple{Int8,Int8}}(undef, length(pairs))
        Threads.@threads for i in eachindex(pairs)
            (a, b) = pairs[i]
            results[i] = (Int8(simulate(c, (a, b))), rem(a, b))
        end
        for (got, expected) in results
            @test got == expected
        end
        # Edge cases
        for (a, b) in [(typemin(Int8), Int8(1)), (typemax(Int8), Int8(1)),
                        (Int8(7), Int8(3)), (Int8(-7), Int8(3)),
                        (Int8(7), Int8(-3)), (Int8(-7), Int8(-3))]
            expected = rem(a, b)
            got = Int8(simulate(c, (a, b)))
            @test got == expected
        end
        @test verify_reversibility(c)
    end
end
