# RED test for Bennett-cc0.7 — ir_extract must handle vectorised IR.
#
# Modeled on the persistent-DS sweep pattern. At N=16 the Julia optimiser
# packs same-type slot updates into <8 x i8> vector SIMD, emitting
# insertelement / extractelement / shufflevector + vector add/icmp. These
# opcodes currently crash extract_parsed_ir with "Unsupported LLVM opcode".
#
# Workaround in use across the codebase: reversible_compile(...; optimize=false),
# which costs 3-50× in gate count (sweep evidence, 2026-04-20).

using Test
using Bennett

# Pull in the generated N=16 linear_scan demo — same fixture used by the sweep.
include(joinpath(@__DIR__, "..", "benchmark", "cc07_repro_n16.jl"))

@testset "cc0.7 — ir_extract handles vectorised IR (optimize=true)" begin
    # RED (pre-fix): crashes with "Unsupported LLVM opcode: LLVMInsertElement".
    # Confirmed: `code_llvm(ls_demo_16, ...; optimize=true)` emits
    # insertelement + shufflevector + vector add/icmp + extractelement.
    parsed = Bennett.extract_parsed_ir(ls_demo_16, Tuple{Int8, Int8}; optimize=true)
    @test parsed isa Bennett.ParsedIR

    # GREEN requires full pipeline: lower + bennett + simulate.
    circuit = reversible_compile(ls_demo_16, Int8, Int8)
    @test verify_reversibility(circuit)

    # Spot-check against Julia oracle (multi-arg simulate takes a tuple).
    for (seed, lookup) in [(Int8(0), Int8(0)), (Int8(1), Int8(3)),
                           (Int8(-1), Int8(5)), (Int8(7), Int8(13))]
        @test simulate(circuit, (seed, lookup)) == ls_demo_16(seed, lookup)
    end
end
