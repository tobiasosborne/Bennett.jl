@testset "Controlled circuits" begin
    @testset "Controlled increment" begin
        f(x::Int8) = x + Int8(3)
        circuit = reversible_compile(f, Int8)
        cc = controlled(circuit)

        for x in typemin(Int8):typemax(Int8)
            @test simulate(cc, true, x) == f(x)
            @test simulate(cc, false, x) == Int8(0)
        end
        @test verify_reversibility(cc)

        gc_orig = gate_count(circuit)
        gc_ctrl = gate_count(cc.circuit)
        println("  Controlled increment:")
        println("    Original:   ", gc_orig)
        println("    Controlled: ", gc_ctrl)
    end

    @testset "Controlled polynomial" begin
        g(x::Int8) = x * x + Int8(3) * x + Int8(1)
        circuit = reversible_compile(g, Int8)
        cc = controlled(circuit)

        for x in Int8(0):Int8(15)
            @test simulate(cc, true, x) == g(x)
            @test simulate(cc, false, x) == Int8(0)
        end
        @test verify_reversibility(cc)
    end

    @testset "Controlled two-arg" begin
        m(x::Int8, y::Int8) = x * y + x - y
        circuit = reversible_compile(m, Int8, Int8)
        cc = controlled(circuit)

        for x in Int8(0):Int8(15), y in Int8(0):Int8(15)
            @test simulate(cc, true, (x, y)) == m(x, y)
            @test simulate(cc, false, (x, y)) == Int8(0)
        end
        @test verify_reversibility(cc)
    end

    @testset "Controlled Int16" begin
        f16(x::Int16) = x + Int16(7)
        circuit = reversible_compile(f16, Int16)
        cc = controlled(circuit)

        for x in [Int16(0), Int16(1), Int16(-1), typemin(Int16), typemax(Int16)]
            @test simulate(cc, true, x) == f16(x)
            @test simulate(cc, false, x) == Int16(0)
        end
        @test verify_reversibility(cc)
    end

    @testset "Controlled tuple return" begin
        swap(x::Int8, y::Int8) = (y, x)
        circuit = reversible_compile(swap, Int8, Int8)
        cc = controlled(circuit)

        for x in Int8(0):Int8(7), y in Int8(0):Int8(7)
            @test simulate(cc, true, (x, y)) == swap(x, y)
            @test simulate(cc, false, (x, y)) == (Int64(0), Int64(0))
        end
        @test verify_reversibility(cc)
    end
end
