# Bennett-4ddk: the module-scoped compile caches must be sound.
#
#   F1  — redefining a compiled method (or a callee it inlines) must not return
#         the stale circuit: both `_parsed_ir_cache` and `_compile_cache` keyed on
#         things (the function object, `objectid(parsed)`) that do not change
#         when the method does.
#   F15 — callable structs, which `extract_parsed_ir` accepts, must not
#         MethodError at the `_extract_parsed_ir_cached(f::Function, ...)` boundary.
#   F21 — repeated identical narrowed (`bit_width`) compiles must reuse one
#         entry instead of retaining a duplicate circuit per call; the cache
#         must stay bounded.
#
# Redefinitions run via `@eval` inside a testset, whose body executes in the
# world it started in — so every compile / oracle call after a redefinition
# goes through `Base.invokelatest` to see the new method.
#
# Gotcha (Julia 1.12): a closure literal evaluated at top level — including
# inside a `@testset` body — defines its type and method when reached, which
# moves the world and so empties both caches. Identity (`===`) assertions must
# therefore come before any such literal in the same testset.

using Test
using Bennett

g4ddk(x::Int8) = x + Int8(1)
h4ddk(x::Int8) = x + Int8(1)
k4ddk(x::Int8) = h4ddk(x) * Int8(2)

struct Inc4ddk end
(::Inc4ddk)(x::Int8) = x + Int8(1)

struct Add4ddk
    k::Int8
end
(a::Add4ddk)(x::Int8) = x + a.k

function _check_all_int8(c, oracle)
    @test verify_reversibility(c)
    for x in typemin(Int8):typemax(Int8)
        @test simulate(c, x) == oracle(x)
    end
end

@testset "Bennett-4ddk: compile-cache soundness" begin

    @testset "F1: redefined top-level method recompiles" begin
        c1 = Base.invokelatest(reversible_compile, g4ddk, Int8)
        _check_all_int8(c1, x -> x + Int8(1))
        @eval g4ddk(x::Int8) = x + Int8(2)
        c2 = Base.invokelatest(reversible_compile, g4ddk, Int8)
        @test c2 !== c1
        _check_all_int8(c2, x -> Base.invokelatest(g4ddk, x))
        @test simulate(c2, Int8(0)) == 2
    end

    @testset "F1: redefined transitive callee recompiles" begin
        c1 = Base.invokelatest(reversible_compile, k4ddk, Int8)
        _check_all_int8(c1, x -> (x + Int8(1)) * Int8(2))
        @eval h4ddk(x::Int8) = x + Int8(3)
        c2 = Base.invokelatest(reversible_compile, k4ddk, Int8)
        @test c2 !== c1
        _check_all_int8(c2, x -> Base.invokelatest(k4ddk, x))
        @test simulate(c2, Int8(0)) == 6
    end

    @testset "same-world repeat compile still hits" begin
        c1 = reversible_compile(g4ddk, Int8)
        c2 = reversible_compile(g4ddk, Int8)
        @test c1 === c2
        @test verify_reversibility(c1)
    end

    @testset "F15: callable struct compiles" begin
        c = reversible_compile(Inc4ddk(), Int8)
        @test reversible_compile(Inc4ddk(), Int8) === c
        _check_all_int8(c, x -> x + Int8(1))
        # A functor with a field: the field is bound as a constant (Bennett-2op8;
        # before, it was an extra circuit input), per value of the field.
        for k in Int8[-128, -1, 0, 3, 127]
            ca = reversible_compile(Add4ddk(k), Int8)
            @test ca.input_widths == [8]
            @test verify_reversibility(ca)
            @test all(simulate(ca, x) == x + k for x in typemin(Int8):typemax(Int8))
        end
    end

    @testset "F21: identical narrowed compiles share one entry" begin
        Bennett._clear_compile_cache!()
        cs = [reversible_compile(g4ddk, Int8; bit_width=4, strategy=:expression)
              for _ in 1:10]
        @test all(c -> c === cs[1], cs)
        # Bennett-5y48 (differential): both readings of `x + 1` narrow, so the
        # compile cache holds the unoptimised- and the optimised-IR circuits
        # (the result is the first), and the cross-check verdict is cached.
        @test length(Bennett._compile_cache) == 2
        @test verify_reversibility(cs[1])
        # A different width is a different circuit.
        c3 = reversible_compile(g4ddk, Int8; bit_width=3, strategy=:expression)
        @test c3 !== cs[1]
        @test verify_reversibility(c3)
    end

    @testset "F21: compile cache is bounded" begin
        Bennett._clear_compile_cache!()
        n = Bennett._COMPILE_CACHE_MAX + 8
        for m in 1:n
            reversible_compile(g4ddk, Int8; max_loop_iterations=m)
        end
        @test length(Bennett._compile_cache) <= Bennett._COMPILE_CACHE_MAX
    end
end
