using Test, Bennett
@testset "Int64 arithmetic" begin
    f(x::Int64) = x + Int64(1)
    circuit = reversible_compile(f, Int64)

    for x in Int64[0, 1, -1, 42, -42, typemax(Int64), typemin(Int64)]
        @test simulate(circuit, x) == f(x)
    end
    using Random; Random.seed!(99)
    for _ in 1:500
        x = rand(Int64)
        @test simulate(circuit, x) == f(x)
    end
    @test verify_reversibility(circuit)
    println("  Int64 increment: ", gate_count(circuit))

    # Gate count scaling table
    inc8(x::Int8)   = x + Int8(1)
    inc16(x::Int16) = x + Int16(1)
    inc32(x::Int32) = x + Int32(1)
    inc64(x::Int64) = x + Int64(1)
    println("\n  Gate count scaling (x + 1):")
    for (fn, T, W) in ((inc8, Int8, 8), (inc16, Int16, 16), (inc32, Int32, 32), (inc64, Int64, 64))
        c = reversible_compile(fn, T)
        gc = gate_count(c)
        println("    i$W: $(gc.total) gates (NOT=$(gc.NOT) CNOT=$(gc.CNOT) Toffoli=$(gc.Toffoli))")
    end
end
