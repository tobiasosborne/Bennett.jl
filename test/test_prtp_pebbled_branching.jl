# Bennett-prtp / U04: checkpoint_bennett / pebbled_group_bennett /
# pebbled_bennett crash or produce broken circuits on branching CFGs.
#
# Three sibling strategies share the defect:
#
# 1. `pebbled_group_bennett` (src/pebbled_groups.jl:273) — has an in-place
#    fallback (Cuccaro) and an empty-groups fallback, but no branching-CFG
#    fallback. Diamond CFG hits `_remap_wire` error "Unmapped wire N"
#    because `__pred_*` result wires live outside wmap.
# 2. `checkpoint_bennett` (src/pebbled_groups.jl:351) — same fallback gap.
# 3. `pebbled_bennett` (src/pebbling.jl:112) — runs Knill gate-level
#    recursion assuming per-gate fresh target wires; `__pred_*` gate groups
#    use wires shared across the forward pass, breaking the index-reverse
#    state-matching argument.
#
# Fix: for each of the three functions, add a precondition refusing any
# `LoweringResult` that contains a `__pred_*` gate group; fall back to
# `bennett(lr)`. Mirrors Bennett-rggq / U02 for value_eager_bennett.
#
# Catalogue: reviews/2026-04-21/UNIFIED_CATALOGUE.md U04. Reports: #09 F4,
# #09 F5 (umbrella), #09 F7 (pebbled_bennett in-place).

using Test
using Bennett
using Bennett: pebbled_group_bennett, checkpoint_bennett, pebbled_bennett,
               bennett, extract_parsed_ir, lower, verify_reversibility,
               simulate

# Small diamond-CFG function — minimal reproduction from the catalogue.
function _u04_branching(x::Int8)
    if x > Int8(0)
        return x + Int8(1)
    else
        return x - Int8(1)
    end
end

# Small straight-line function for regression-no-regression checks.
_u04_linear(x::Int8) = x + Int8(3)

@testset "Bennett-prtp / U04: pebbled/checkpoint strategies fall back on branching" begin

    @testset "T1: pebbled_group_bennett on diamond CFG falls back safely" begin
        parsed = extract_parsed_ir(_u04_branching, Tuple{Int8}; optimize=false)
        lr = lower(parsed)
        # Pre-fix: `_remap_wire` error "Unmapped wire N" on first input with
        # a branch active. Post-fix: fallback to bennett(lr).
        c = pebbled_group_bennett(lr; max_pebbles=4)
        @test verify_reversibility(c; n_tests=16) == true
        for x in Int8(-128):Int8(127)
            @test simulate(c, x) == _u04_branching(x)
        end
    end

    @testset "T2: checkpoint_bennett on diamond CFG falls back safely" begin
        parsed = extract_parsed_ir(_u04_branching, Tuple{Int8}; optimize=false)
        lr = lower(parsed)
        c = checkpoint_bennett(lr)
        @test verify_reversibility(c; n_tests=16) == true
        for x in Int8(-128):Int8(127)
            @test simulate(c, x) == _u04_branching(x)
        end
    end

    @testset "T3: pebbled_bennett on diamond CFG falls back safely" begin
        parsed = extract_parsed_ir(_u04_branching, Tuple{Int8}; optimize=false)
        lr = lower(parsed)
        n_gates = length(lr.gates)
        c = pebbled_bennett(lr; max_pebbles=max(2, n_gates ÷ 3))
        @test verify_reversibility(c; n_tests=16) == true
        for x in Int8(-128):Int8(127)
            @test simulate(c, x) == _u04_branching(x)
        end
    end

    @testset "T4: straight-line pebbled_group_bennett still active (no regression)" begin
        parsed = extract_parsed_ir(_u04_linear, Tuple{Int8}; optimize=false)
        lr = lower(parsed)
        c = pebbled_group_bennett(lr; max_pebbles=4)
        @test verify_reversibility(c; n_tests=16) == true
        for x in Int8(-128):Int8(127)
            @test simulate(c, x) == _u04_linear(x)
        end
    end

    @testset "T5: straight-line checkpoint_bennett still active (no regression)" begin
        parsed = extract_parsed_ir(_u04_linear, Tuple{Int8}; optimize=false)
        lr = lower(parsed)
        c = checkpoint_bennett(lr)
        @test verify_reversibility(c; n_tests=16) == true
        for x in Int8(-128):Int8(127)
            @test simulate(c, x) == _u04_linear(x)
        end
    end
end
