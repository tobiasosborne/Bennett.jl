@testset "Loop (LLVM-unrolled)" begin
    function s(x::Int8)
        acc = Int8(0)
        for i in Int8(1):Int8(4)
            acc += x
        end
        return acc
    end

    ir = extract_ir(s, Tuple{Int8})
    parsed = extract_parsed_ir(s, Tuple{Int8})  # Bennett-cs2f / U42 — was parse_ir(ir)
    println("  s(x) blocks: ", length(parsed.blocks), " (LLVM unrolled)")
    println("  s(x) IR:\n", ir)

    circuit = reversible_compile(s, Int8)
    for x in typemin(Int8):typemax(Int8)
        @test simulate(circuit, x) == s(x)
    end
    @test verify_reversibility(circuit)
    println("  Loop (4x): ", gate_count(circuit))
end
