# Bennett-rggq / U02: value_eager_bennett leaks ancillae on ANY branching
# function.
#
# Root cause (src/value_eager.jl:29-137, producers src/lower.jl:379,389):
# Phase-3 Kahn topological uncompute walks `input_ssa_vars`. Synthetic
# `__pred_*` block-predicate groups (emitted for every non-trivial CFG) have
# `input_ssa_vars = Symbol[]` — their wire-level dependencies on other
# `__pred_*` groups' result wires are invisible to the DAG. Reverse-topo
# ordering becomes wrong and predicate wires get reversed out of order,
# leaking ancillae and corrupting input wires.
#
# Surfaced by Bennett-asw2 / U01 (verify_reversibility non-tautological):
# test_value_eager.jl:158 (SHA-256 round) flipped to red. The current U01
# fix catches it via "input wire N changed from X to Y" — exactly the
# PRS15-paper signal.
#
# Safer fix (this commit): refuse the Kahn path whenever any __pred_*
# group exists; fall back to bennett(lr). Preserves full value_eager
# behaviour on straight-line code (no regression).
#
# Catalogue: reviews/2026-04-21/UNIFIED_CATALOGUE.md U02. Reports: #09 F2.

using Test
using Bennett
using Bennett: value_eager_bennett, bennett, extract_parsed_ir, lower,
               verify_reversibility, simulate

@testset "Bennett-rggq / U02: value_eager_bennett preserves Bennett invariants on branching CFG" begin

    @testset "T1: diamond CFG (x > 0 ? x+1 : x-1) — the canonical repro" begin
        # Minimal branching example from the review. Pre-fix: verify_reversibility
        # throws "input wire N changed from X to Y" or "ancilla wire N not zero".
        function b(x::Int8)
            if x > Int8(0)
                return x + Int8(1)
            else
                return x - Int8(1)
            end
        end
        parsed = extract_parsed_ir(b, Tuple{Int8}; optimize=false)
        lr = lower(parsed)
        c_eager = value_eager_bennett(lr)
        @test verify_reversibility(c_eager; n_tests=32) == true
        # Correctness: all 256 Int8 inputs match native.
        for x in Int8(-128):Int8(127)
            @test simulate(c_eager, x) == b(x)
        end
    end

    @testset "T2: nested branching (two-level if/else) — deeper diamond" begin
        function q(x::Int8)
            if x > Int8(0)
                if x > Int8(10)
                    return x + Int8(10)
                else
                    return x + Int8(1)
                end
            else
                return x - Int8(1)
            end
        end
        parsed = extract_parsed_ir(q, Tuple{Int8}; optimize=false)
        lr = lower(parsed)
        c_eager = value_eager_bennett(lr)
        @test verify_reversibility(c_eager; n_tests=32) == true
        for x in Int8(-128):Int8(127)
            @test simulate(c_eager, x) == q(x)
        end
    end

    @testset "T3: straight-line code retains value_eager behaviour (no regression)" begin
        # Straight-line f has no __pred_* groups, so value_eager runs
        # full PRS15 Phase 3 and still saves peak-live wires.
        parsed = extract_parsed_ir(x -> x + Int8(3), Tuple{Int8}; optimize=false)
        lr = lower(parsed)
        c_eager = value_eager_bennett(lr)
        c_full  = bennett(lr)
        @test verify_reversibility(c_eager; n_tests=32) == true
        @test verify_reversibility(c_full;  n_tests=32) == true
        # Correctness
        for x in Int8(-128):Int8(127)
            @test simulate(c_eager, x) == x + Int8(3)
            @test simulate(c_full,  x) == x + Int8(3)
        end
    end
end
