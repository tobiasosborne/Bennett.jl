# Bennett-t9rh (commit 1): sound poison-lane propagation in the cc0.7 vector
# scalariser (src/extract/vectors.jl).
#
# The LLVM SLP / loop vectorisers emit vector ops some of whose lanes are
# `poison` and never observed (e.g. the horizontal-add idiom
# `shufflevector <1, poison>` -> `add` -> extract lane 0). The scalariser used
# to emit a scalar op for the dead lane with a `PoisonLaneSentinel` operand,
# and — Bennett having no DCE — lowering reached `resolve!`'s catch-all and
# threw an AssertionError. LangRef 18 "Poison Values": lane-wise ops propagate
# poison, and `select` with a poison arm may be refined to the other arm
# (InstSimplify `select ?, X, poison -> X`). Observation points (extract,
# reduce, <N x i1> -> iN bitcast) must still fail loud.
#
# All fixtures are hand-written `.ll` (test/fixtures/ll/t9rh_poison_lanes.ll)
# so this file is HOST-INDEPENDENT: it exercises the scalariser whatever CPU
# the suite runs on.

using Test
using Bennett
using Random

const _T9RH_LL = joinpath(@__DIR__, "fixtures", "ll", "t9rh_poison_lanes.ll")

_t9rh_parse(entry) = Bennett.extract_parsed_ir_from_ll(_T9RH_LL; entry_function=entry)

function _t9rh_compile(entry)
    c = reversible_compile(_t9rh_parse(entry))
    @test verify_reversibility(c)
    return c
end

# Recursively search an IR value for a PoisonLaneSentinel (structural check:
# after propagation no sentinel may survive into any emitted IRInst field).
_t9rh_has_sentinel(x::Bennett.PoisonLaneSentinel) = true
_t9rh_has_sentinel(x::Union{AbstractVector, Tuple}) = any(_t9rh_has_sentinel, x)
function _t9rh_has_sentinel(x)
    x isa Union{Number, Symbol, AbstractString, Nothing, Type} && return false
    isstructtype(typeof(x)) || return false
    return any(f -> isdefined(x, f) && _t9rh_has_sentinel(getfield(x, f)),
               fieldnames(typeof(x)))
end
function _t9rh_insts(p)
    out = Any[]
    for b in p.blocks
        append!(out, b.instructions)
        push!(out, b.terminator)
    end
    return out
end

_t9rh_errmsg(f) = try
    f(); ""
catch e
    e isa InterruptException && rethrow()
    sprint(showerror, e)
end

@testset "Bennett-t9rh: poison-lane propagation (host-independent .ll)" begin

    @testset "hadd — SLP horizontal-add idiom" begin
        c = _t9rh_compile("hadd")
        edges = Int64[0, 1, -1, 5, -7, typemax(Int64), typemin(Int64), 12345]
        for a in edges, b in edges
            @test simulate(c, (a, b)) == a + b
        end
        rng = Random.MersenneTwister(0x79b3)
        for _ in 1:100
            a, b = rand(rng, Int64), rand(rng, Int64)
            @test simulate(c, (a, b)) == a + b
        end
    end

    @testset "splat_shl — loop-vectoriser splat with poison mask lanes" begin
        c = _t9rh_compile("splat_shl")
        for x in Int64[0, 1, -1, 7, 12345, typemax(Int64), typemin(Int64)]
            @test simulate(c, x) == 6x
        end
    end

    @testset "cmp_sel — icmp/zext/select over poison lanes, exhaustive UInt8²" begin
        c = _t9rh_compile("cmp_sel")
        ok = true
        for x in UInt8(0):UInt8(255), y in UInt8(0):UInt8(255)
            want = y > 3 ? UInt8(x < 10) : y
            ok &= (simulate(c, (x, y)) % UInt8) == want
        end
        @test ok
    end

    @testset "hsum — poison through add/icmp/zext/umax intrinsic/select" begin
        c = _t9rh_compile("hsum")
        oracle(a, b) = (s = a + b; cc = s < a; z = UInt64(cc); cc ? z : max(s, z))
        cases = [(UInt64(3), UInt64(5)), (typemax(UInt64), UInt64(2)),
                 (UInt64(0), UInt64(0)), (typemax(UInt64), typemax(UInt64)),
                 (UInt64(1) << 63, UInt64(1) << 63)]
        rng = Random.MersenneTwister(0x7a1)
        append!(cases, [(rand(rng, UInt64), rand(rng, UInt64)) for _ in 1:100])
        for (a, b) in cases
            @test (simulate(c, (a, b)) % UInt64) == oracle(a, b)
        end
    end

    @testset "select with one poison arm refines to the other arm" begin
        # For b > 100 LLVM defines the observed lane as `a`; for b <= 100 it
        # is poison and any value is a legal refinement. Bennett's refinement
        # (InstSimplify's) picks `a` for every input — pinned here.
        for entry in ("sel_poison_false", "sel_poison_true")
            c = _t9rh_compile(entry)
            for a in Int64[0, 1, -1, 42, typemax(Int64), typemin(Int64)],
                b in Int64[0, 100, 101, 5000, -1]
                @test simulate(c, (a, b)) == a
            end
        end
    end

    @testset "all-poison dead vector ops emit no IR and no gates" begin
        p = _t9rh_parse("dead")
        pref = _t9rh_parse("dead_ref")
        @test length(_t9rh_insts(p)) == length(_t9rh_insts(pref))
        c = _t9rh_compile("dead")
        cref = _t9rh_compile("dead_ref")
        @test gate_count(c) == gate_count(cref)
        for x in Int64[0, 1, -1, typemax(Int64)]
            @test simulate(c, x) == x + 5
        end
    end

    @testset "structural: no PoisonLaneSentinel survives into ParsedIR" begin
        @test Bennett.UNDEF_LANE isa Bennett.UndefLaneSentinel
        @test Bennett.UNDEF_LANE isa Bennett.IROperand
        @test Bennett.UNDEF_LANE !== Bennett.POISON_LANE
        for entry in ("hadd", "splat_shl", "cmp_sel", "hsum",
                      "sel_poison_false", "sel_poison_true", "dead")
            p = _t9rh_parse(entry)
            @test !any(_t9rh_has_sentinel, _t9rh_insts(p))
        end
    end

    @testset "observation points still fail loud (at extraction, with context)" begin
        # extractelement of a propagated poison lane: ErrorException from
        # _ir_error (NOT the resolve! AssertionError backstop).
        e = try _t9rh_parse("hadd_lane1"); nothing catch err; err end
        @test e isa ErrorException
        msg = sprint(showerror, e)
        @test occursin("poison lane", msg)
        @test occursin("Bennett-t9rh", msg)
        @test occursin("extractelement", msg)
        @test !occursin("undefined behaviour", msg)

        msg = _t9rh_errmsg(() -> _t9rh_parse("reduce_poison"))
        @test occursin("vector reduction", msg) && occursin("poison lane", msg)

        msg = _t9rh_errmsg(() -> _t9rh_parse("bitcast_poison"))
        @test occursin("bitcast", msg) && occursin("poison lane", msg)
    end

    @testset "undef lanes are NOT poison: plumbing ok, computing use fails loud" begin
        # Legacy undef-placeholder splat never reads an undef lane.
        c = _t9rh_compile("undef_splat")
        for x in Int64[0, 1, -1, 7, typemax(Int64), typemin(Int64)]
            @test simulate(c, x) == (x + 1) + (x + 2)
        end
        # `or undef, -1` is exactly -1; conflating undef with poison would let
        # the select refinement silently miscompile this to `a`. Must throw at
        # extraction naming undef.
        e = try _t9rh_parse("undef_or_sel"); nothing catch err; err end
        @test e isa ErrorException
        msg = e === nothing ? "" : sprint(showerror, e)
        @test occursin("undef", msg)
        @test occursin("Bennett-t9rh", msg)
    end
end
