# Bennett-cc0.7 micro-tests — focused coverage for vector-op extraction.
# Each test exercises a distinct vector-op category in isolation, with a
# Julia oracle cross-check and verify_reversibility.
# See `docs/design/cc07_consensus.md` §6.

using Test
using Bennett

# ─────────────────────────────────────────────────────────────────────────────
# 1. Tuple-of-adds splat+extract — insertelement + shufflevector + vector add
#    + extractelement at element width 8.
# ─────────────────────────────────────────────────────────────────────────────

function f_splat_add(x::Int8)::Int8
    t = (x + Int8(1), x + Int8(2), x + Int8(3), x + Int8(4),
         x + Int8(5), x + Int8(6), x + Int8(7), x + Int8(8))
    Int8(t[1] + t[2] + t[3] + t[4] + t[5] + t[6] + t[7] + t[8])
end

@testset "cc0.7 — splat + vector add + extractelement" begin
    # Bennett-kv7b / U65 (#03 F15) — was 6 sampled inputs.
    # Now exhaustive Int8 (256 inputs).
    c = reversible_compile(f_splat_add, Int8; optimize=true)
    @test verify_reversibility(c)
    for x in typemin(Int8):typemax(Int8)
        @test simulate(c, x) == f_splat_add(x)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# 2. Vector icmp — produces <N x i1>, extracted per-lane. Also exercises the
#    broadcast pattern (insertelement into poison + shufflevector-splat).
# ─────────────────────────────────────────────────────────────────────────────

function f_splat_icmp(x::Int8, y::Int8)::Int8
    m1 = (y == x + Int8(1)); m2 = (y == x + Int8(2))
    m3 = (y == x + Int8(3)); m4 = (y == x + Int8(4))
    m5 = (y == x + Int8(5)); m6 = (y == x + Int8(6))
    m7 = (y == x + Int8(7)); m8 = (y == x + Int8(8))
    Int8((m1 | m2 | m3 | m4 | m5 | m6 | m7 | m8) ? 1 : 0)
end

@testset "cc0.7 — vector icmp + extractelement <N x i1>" begin
    # Bennett-kv7b / U65 (#03 F15) — was 3×4=12 sampled pairs.
    # Now exhaustive 256×256 Int8.
    c = reversible_compile(f_splat_icmp, Int8, Int8; optimize=true)
    @test verify_reversibility(c)
    for x in typemin(Int8):typemax(Int8), y in typemin(Int8):typemax(Int8)
        @test simulate(c, (x, y)) == f_splat_icmp(x, y)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# 3. Constant-vector binop — exercises `ConstantDataVector` path in
#    `_resolve_vec_lanes`. Each slot has a distinct constant operand.
# ─────────────────────────────────────────────────────────────────────────────

function f_const_vec_and(x::Int8)::Int8
    t = (x & Int8(0x01), x & Int8(0x03), x & Int8(0x07), x & Int8(0x0f),
         x & Int8(0x1f), x & Int8(0x3f), x & Int8(0x7f), x & Int8(-1))
    Int8(t[1] | t[2] | t[3] | t[4] | t[5] | t[6] | t[7] | t[8])
end

@testset "cc0.7 — ConstantDataVector operand" begin
    # Bennett-kv7b / U65 (#03 F15) — was 6 sampled inputs.
    # Now exhaustive Int8.
    c = reversible_compile(f_const_vec_and, Int8; optimize=true)
    @test verify_reversibility(c)
    for x in typemin(Int8):typemax(Int8)
        @test simulate(c, x) == f_const_vec_and(x)
    end
end
