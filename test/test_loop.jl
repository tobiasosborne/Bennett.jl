using Random

# Bennett-kv7b / U65 (#05 F19) — loop tests were Int8-only. Extending
# to Int16/Int32/Int64 (and the matching unsigned widths) so that the
# LLVM-unrolled-loop lowering path is exercised across the full
# scalar-integer range supported by `_SUPPORTED_SCALAR_ARGS` in
# src/Bennett.jl. The loop body `acc += x` repeated 4 times computes
# `4*x` modulo wraparound, which is the same lowering shape across
# all widths so the gate-count grows ~linearly with W.

# Int8 — exhaustive (256 inputs), historical baseline
@testset "Loop (LLVM-unrolled) — Int8" begin
    function s(x::Int8)
        acc = Int8(0)
        for i in Int8(1):Int8(4)
            acc += x
        end
        return acc
    end

    parsed = extract_parsed_ir(s, Tuple{Int8})
    println("  s(x::Int8) blocks: ", length(parsed.blocks), " (LLVM unrolled)")

    circuit = reversible_compile(s, Int8)
    for x in typemin(Int8):typemax(Int8)
        @test simulate(circuit, x) == s(x)
    end
    @test verify_reversibility(circuit)
    println("  Loop (4x) Int8: ", gate_count(circuit))
end

# Int16 — exhaustive (65,536 inputs)
@testset "Loop (LLVM-unrolled) — Int16" begin
    function s(x::Int16)
        acc = Int16(0)
        for i in Int16(1):Int16(4)
            acc += x
        end
        return acc
    end

    circuit = reversible_compile(s, Int16)
    for x in typemin(Int16):typemax(Int16)
        @test simulate(circuit, x) == s(x)
    end
    @test verify_reversibility(circuit)
    println("  Loop (4x) Int16: ", gate_count(circuit))
end

# Int32 / Int64 — sampled (boundary values + a fixed-seed random sweep)
function _loop_sample_inputs(::Type{T}, n::Int) where {T<:Integer}
    rng = Random.MersenneTwister(0x10092a7c)
    edges = T[typemin(T), typemin(T) + one(T), -one(T), zero(T), one(T),
             typemax(T) - one(T), typemax(T)]
    samples = T[T(rand(rng, typemin(T):typemax(T))) for _ in 1:n]
    return vcat(edges, samples)
end

@testset "Loop (LLVM-unrolled) — Int32" begin
    function s(x::Int32)
        acc = Int32(0)
        for i in Int32(1):Int32(4)
            acc += x
        end
        return acc
    end

    circuit = reversible_compile(s, Int32)
    for x in _loop_sample_inputs(Int32, 256)
        @test simulate(circuit, x) == s(x)
    end
    @test verify_reversibility(circuit)
    println("  Loop (4x) Int32: ", gate_count(circuit))
end

@testset "Loop (LLVM-unrolled) — Int64" begin
    function s(x::Int64)
        acc = Int64(0)
        for i in Int64(1):Int64(4)
            acc += x
        end
        return acc
    end

    circuit = reversible_compile(s, Int64)
    for x in _loop_sample_inputs(Int64, 256)
        @test simulate(circuit, x) == s(x)
    end
    @test verify_reversibility(circuit)
    println("  Loop (4x) Int64: ", gate_count(circuit))
end

# Unsigned widths — exhaustive at UInt8/UInt16, sampled at UInt32/UInt64
@testset "Loop (LLVM-unrolled) — UInt8" begin
    function s(x::UInt8)
        acc = UInt8(0)
        for i in UInt8(1):UInt8(4)
            acc += x
        end
        return acc
    end

    circuit = reversible_compile(s, UInt8)
    for x in typemin(UInt8):typemax(UInt8)
        @test simulate(circuit, x) == s(x)
    end
    @test verify_reversibility(circuit)
    println("  Loop (4x) UInt8: ", gate_count(circuit))
end

@testset "Loop (LLVM-unrolled) — UInt64" begin
    function s(x::UInt64)
        acc = UInt64(0)
        for i in UInt64(1):UInt64(4)
            acc += x
        end
        return acc
    end

    circuit = reversible_compile(s, UInt64)
    for x in _loop_sample_inputs(UInt64, 256)
        @test simulate(circuit, x) == s(x)
    end
    @test verify_reversibility(circuit)
    println("  Loop (4x) UInt64: ", gate_count(circuit))
end
