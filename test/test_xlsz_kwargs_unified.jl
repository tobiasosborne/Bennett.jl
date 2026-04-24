using Test
using Bennett

# Bennett-xlsz / U29: the three `reversible_compile` overloads
# (Tuple / Float64 / ParsedIR) had divergent kwarg surfaces and would
# raise a raw `MethodError` on any unsupported kwarg — no hint about
# what *is* supported or which overload the kwarg belonged to.
# This pins:
#   1. Unknown kwargs raise `ArgumentError` with a useful message
#      naming the supported set for that overload.
#   2. `add` / `mul` / `fold_constants` reach the Float64 overload
#      (soft-float internally lowers to integer arithmetic, so these
#      strategy picks are meaningful).
#   3. `fold_constants` is reachable on all three overloads (so users
#      of U28's fold-on-by-default can opt out explicitly).
#   4. The ParsedIR overload rejects kwargs that only make sense
#      pre-extraction (`optimize`, `bit_width`, `strategy`) with a
#      clear message.
@testset "Bennett-xlsz / U29: unified kwargs surface" begin

    @testset "Tuple overload rejects bogus kwargs via ArgumentError" begin
        err = try
            reversible_compile(x -> x + Int8(3), Int8; bogus=42)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        # Error must name the offending kwarg AND the supported set so
        # the user knows what was valid.
        @test occursin("bogus", err.msg)
        @test occursin("supported", lowercase(err.msg))
    end

    @testset "Float64 overload accepts add / mul / fold_constants" begin
        # Float64 lowers via SoftFloat → soft_fadd / soft_fmul — those
        # are integer arithmetic internally, so `add`, `mul`, and
        # `fold_constants` are all meaningful knobs.
        c1 = reversible_compile(x -> x + x, Float64; add=:ripple)
        @test verify_reversibility(c1)
        c2 = reversible_compile(x -> x + x, Float64; mul=:shift_add)
        @test verify_reversibility(c2)
        c3 = reversible_compile(x -> x + x, Float64; fold_constants=false)
        @test verify_reversibility(c3)
    end

    @testset "Float64 overload rejects bogus + cross-overload kwargs" begin
        # Unknown kwarg
        err = try
            reversible_compile(x -> x + x, Float64; bogus=42); nothing
        catch e; e; end
        @test err isa ArgumentError
        @test occursin("bogus", err.msg)

        # `bit_width` doesn't make sense for Float64 (always 64). The
        # error should say so, not MethodError-lookup-spew.
        err2 = try
            reversible_compile(x -> x + x, Float64; bit_width=32); nothing
        catch e; e; end
        @test err2 isa ArgumentError
        @test occursin("bit_width", err2.msg)
    end

    @testset "ParsedIR overload rejects pre-extraction kwargs" begin
        parsed = Bennett.extract_parsed_ir(x -> x + Int8(3), Tuple{Int8})

        # `optimize` is an `extract_parsed_ir` kwarg; the IR has
        # already been extracted, so it's meaningless here.
        err1 = try
            reversible_compile(parsed; optimize=false); nothing
        catch e; e; end
        @test err1 isa ArgumentError
        @test occursin("optimize", err1.msg)

        # `bit_width` is Tuple-overload-only (narrowing happens before
        # lowering); post-extraction it does nothing.
        err2 = try
            reversible_compile(parsed; bit_width=16); nothing
        catch e; e; end
        @test err2 isa ArgumentError
        @test occursin("bit_width", err2.msg)

        # `strategy` is `:tabulate`-only; ParsedIR can't tabulate from
        # a pre-extracted IR, so reject.
        err3 = try
            reversible_compile(parsed; strategy=:tabulate); nothing
        catch e; e; end
        @test err3 isa ArgumentError
        @test occursin("strategy", err3.msg)

        # But `fold_constants` IS meaningful post-extraction — it runs
        # during lowering. Reachable on this overload.
        c = reversible_compile(parsed; fold_constants=false)
        @test verify_reversibility(c)
    end

    @testset "ParsedIR overload rejects unknown kwarg" begin
        parsed = Bennett.extract_parsed_ir(x -> x + Int8(3), Tuple{Int8})
        err = try
            reversible_compile(parsed; nonsense=1); nothing
        catch e; e; end
        @test err isa ArgumentError
        @test occursin("nonsense", err.msg)
    end

    @testset "valid kwargs still work — regression guard" begin
        # Every existing valid kwarg call must continue compiling.
        @test reversible_compile(x -> x + Int8(3), Int8) isa ReversibleCircuit
        @test reversible_compile(x -> x + Int8(3), Int8;
                                 optimize=true,
                                 max_loop_iterations=0,
                                 compact_calls=false,
                                 bit_width=0,
                                 add=:auto,
                                 mul=:auto,
                                 strategy=:auto,
                                 fold_constants=true) isa ReversibleCircuit
        @test reversible_compile(x -> x + x, Float64;
                                 optimize=true,
                                 max_loop_iterations=0,
                                 compact_calls=false,
                                 strategy=:auto) isa ReversibleCircuit
        parsed = Bennett.extract_parsed_ir(x -> x + Int8(3), Tuple{Int8})
        @test reversible_compile(parsed;
                                 max_loop_iterations=0,
                                 compact_calls=false,
                                 add=:auto,
                                 mul=:auto) isa ReversibleCircuit
    end
end
