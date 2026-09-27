# Bennett-iwj6 — the tabulate path is a SECOND implementation of compilation
# that was never held to the oracle of the first (expression lowering).
# Three defects, all CONFIRMED by the Astra review B-circuit-core (F2/F3/F23,
# re-executed in B-circuit-core.verification.md, 2026-09-26):
#
#   F2 (S0) narrowed semantics.  `strategy=:tabulate` / the `:auto` cost-model
#        redirect evaluated the ORIGINAL (natural-width) Julia function on
#        `0:2^W-1` and masked the result, while `strategy=:expression` does
#        W-bit modular arithmetic with the SIGN BIT AT W-1.  Witness
#        `fn(x::Int8) = ifelse(x<0, x*x, Int8(1))` at `bit_width=4`:
#        expression → 4, auto/tabulate → 1.  Unsigned witness
#        `fu(x::UInt8) = (x*x)>>2` at `bit_width=4`, input 7: expression 0x0,
#        auto/tabulate 0xc.  All of those circuits passed
#        `verify_reversibility` — the defect is invisible to the reversibility
#        invariant.  Narrowed tabulation is now REJECTED: a function written
#        for Int8 cannot be re-interpreted in fewer bits without a compiler,
#        so a table over the natural-width function cannot reproduce W-bit
#        intermediate overflow.
#
#   F3 (S0) return width.  `out_width` came from the FIRST ARGUMENT's width
#        (src/Bennett.jl), so a widening return was silently truncated:
#        `f(x::Int8) = Int16(x)*Int16(x)` → expression (out=[16], 400),
#        tabulate (out=[8], -112).  `out_width` now comes from the function's
#        actual return type.
#
#   F23 (S2) option validation.  The kwarg *domain* checks lived only in
#        `lower()`, which both tabulate exits bypass, so
#        `reversible_compile(identity, Int8; strategy=:tabulate, add=:bogus)`
#        (likewise `mul` / `target` / `hashcons`) returned a circuit.  The
#        ParsedIR overload accepted `max_loop_iterations=-1`, and the
#        `Tuple{Float64}` route accepted `bit_width=4` although the Float64
#        overload forbids narrowing.  Validation is now shared: one function,
#        one set of allowed-symbol lists, called by `lower()` AND by both
#        tabulate exits before any circuit is returned.
#
# The oracle for every differential test below is NATIVE Julia, exhaustively
# over the whole input domain at the natural width, plus
# `verify_reversibility` on every circuit (CLAUDE.md §3/§4).

using Test
using Bennett

# ---- helpers -----------------------------------------------------------------

# `simulate(c, R, xs)` decodes as `raw % R`, which is the exact native result
# INCLUDING signedness whenever the circuit's output element width is
# `8*sizeof(R)` — true of the expression path for an R-returning function and
# (after Bennett-iwj6) of the tabulate path.  The UNTYPED `simulate(c, xs)`
# instead picks signedness from a width-alignment heuristic (Bennett-zc50 /
# U100), so it is value-exact only when that heuristic lands on R.  Where it
# does not — a widening unsigned return, whose 16-bit result no longer matches
# the 8-bit input width — the differential assertion goes through the typed
# overload, which is exact by construction.  (That heuristic is tracked
# separately as review finding F4; it is not what this file fixes.)
function _untyped_is_exact(R::Type, c, ins)
    (R === Bool || R <: Signed) && return true
    align = !isempty(c.input_widths) &&
            all(w -> w == c.input_widths[1], c.input_widths) &&
            all(w -> w == c.input_widths[1], c.output_elem_widths)
    return align && all(x -> x isa Unsigned, ins)
end

"""Assert :tabulate, :auto and :expression all reproduce `f` natively on `ins`."""
function check_differential(f, arg_types::Type{<:Tuple}, R::Type, ins)
    c_tab = reversible_compile(f, arg_types.parameters...; strategy=:tabulate)
    c_exp = reversible_compile(f, arg_types.parameters...; strategy=:expression)
    c_aut = reversible_compile(f, arg_types.parameters...; strategy=:auto)
    # CLAUDE.md §4: no circuit passes on "it ran".
    @test verify_reversibility(c_tab)
    @test verify_reversibility(c_exp)
    @test verify_reversibility(c_aut)
    # The three strategies must agree on the circuit's shape too (out_width is
    # part of the contract — F3 lived in exactly this field).
    @test c_tab.output_elem_widths == c_exp.output_elem_widths ==
          c_aut.output_elem_widths == [8 * sizeof(R)]
    for xs in ins
        want = f(xs...)
        @test simulate(c_tab, R, xs) === want
        @test simulate(c_aut, R, xs) === want
        @test simulate(c_exp, R, xs) === want
        if _untyped_is_exact(R, c_exp, xs)
            @test simulate(c_tab, xs) == want
            @test simulate(c_aut, xs) == want
            @test simulate(c_exp, xs) == want
        end
    end
    return nothing
end

"Every value of one scalar type (exhaustive for Int8/UInt8)."
one_domain(::Type{T}) where {T} = (v for v in typemin(T):typemax(T))
"Every input tuple of `arg_types` (65536 entries for a 2-arg Int8 pair)."
function all_inputs(T::Type{<:Tuple})
    return Iterators.product(map(one_domain, T.parameters)...)
end

# Narrowed-semantics oracles, written independently of the compiler: the
# input is sign-extended from W bits, the comparison reads bit W-1, and every
# arithmetic step wraps mod 2^W.  These pin what `:expression` is supposed to
# compute at `bit_width=W` (the semantics the tabulate path used to differ
# from).  Inputs are raw W-bit patterns.
function narrowed_f2_signed(raw::Int, W::Int)
    xv = raw & ((1 << W) - 1)
    sx = xv >= (1 << (W - 1)) ? xv - (1 << W) : xv   # sign bit at W-1
    return sx < 0 ? mod(sx * sx, 1 << W) : 1
end
function narrowed_f2_ushift(raw::Int, W::Int)
    xv = raw & ((1 << W) - 1)
    return (mod(xv * xv, 1 << W)) >> 2                # overflow BEFORE the shift
end

# ---- the differential corpus ------------------------------------------------

# F2 witness 1 (signed branch on the narrowed sign bit), natural width.
iwj6_f2_signed(x::Int8) = ifelse(x < Int8(0), x * x, Int8(1))
# F2 witness 2 (intermediate overflow before a shift), natural width.
iwj6_f2_ushift(x::UInt8) = (x * x) >> 2
# F3 witness (Int8 -> Int16 widening return).
iwj6_widen(x::Int8) = Int16(x) * Int16(x)
# F3 sibling (UInt8 -> UInt16 widening return).
iwj6_widen_u(x::UInt8) = UInt16(x) + UInt16(x)
# Same-width unsigned.
iwj6_unsigned(x::UInt8) = x ⊻ UInt8(0x5a)
# Bool return (narrower than the argument).
iwj6_boolret(x::Int8) = x > Int8(3)
# The cost-model target: the function `:auto` would tabulate if widths allowed.
iwj6_poly(x::Int8) = x * x + Int8(3) * x + Int8(1)

@testset "Bennett-iwj6 — tabulate is held to the expression oracle" begin

    @testset "F3 + parity: exhaustive Int8/UInt8 differential vs native Julia" begin
        for (name, f, arg_types, R) in (
            ("x*x",                  x -> x * x,      Tuple{Int8},  Int8),
            ("x^2+3x+1",             iwj6_poly,       Tuple{Int8},  Int8),
            ("ifelse(x<0,x*x,1)",    iwj6_f2_signed,  Tuple{Int8},  Int8),
            ("abs(x)",               x -> abs(x),     Tuple{Int8},  Int8),
            ("x ÷ 3",                x -> x ÷ Int8(3),Tuple{Int8},  Int8),
            ("x % 5",                x -> x % Int8(5),Tuple{Int8},  Int8),
            ("x > 3 (Bool return)",  iwj6_boolret,    Tuple{Int8},  Bool),
            ("Int16(x)*Int16(x)",    iwj6_widen,      Tuple{Int8},  Int16),
            ("x ⊻ 0x5a (UInt8)",     iwj6_unsigned,   Tuple{UInt8}, UInt8),
            ("(x*x)>>2 (UInt8)",     iwj6_f2_ushift,  Tuple{UInt8}, UInt8),
            ("UInt16(x)+UInt16(x)",  iwj6_widen_u,    Tuple{UInt8}, UInt16),
        )
            @testset "$name" begin
                check_differential(f, arg_types, R, all_inputs(arg_types))
            end
        end
    end

    @testset "two-argument function" begin
        # Two Int8 arguments are the widest case tabulate supports: 2^16
        # table entries ⇒ a 655k-gate QROM, so one simulation costs ~0.2 s and
        # an exhaustive 65536-input sweep would take hours.  End-to-end we
        # therefore sweep a structured sample (both ends of each range, both
        # signs, zero, and the ±1 neighbourhood) and pin ALL 65536 table
        # entries against native Julia separately, below.
        g(a::Int8, b::Int8) = a * b + Int8(1)
        a_vals = (Int8(-128), Int8(-100), Int8(-2), Int8(-1), Int8(0),
                  Int8(1), Int8(2), Int8(100), Int8(126), Int8(127))
        b_vals = (Int8(-128), Int8(-1), Int8(0), Int8(1), Int8(127))
        check_differential(g, Tuple{Int8, Int8}, Int8,
                           Iterators.product(a_vals, b_vals))
        # Exhaustive white-box complement: every table entry is the native
        # result.  (This is the function the QROM encodes; end-to-end
        # equivalence on every input pair is what the sample above checks.)
        widths = [8, 8]
        arg_T = Tuple{Int8, Int8}.parameters
        table = Bennett._tabulate_build_table(g, Tuple{Int8, Int8}, widths, 8)
        @test length(table) == 1 << 16
        @test all(table[raw + 1] ==
                  UInt64(reinterpret(UInt8, g(Bennett._unpack_args(UInt64(raw), widths, arg_T)...)))
                  for raw in 0:((1 << 16) - 1))
    end

    @testset "F2: narrowed :tabulate refused, :auto == :expression" begin
        for W in (2, 3, 4, 5, 6, 7)
            @testset "bit_width=$W" begin
                c_expr = reversible_compile(iwj6_f2_signed, Int8; bit_width=W,
                                            strategy=:expression, optimize=false)
                c_auto = reversible_compile(iwj6_f2_signed, Int8; bit_width=W,
                                            strategy=:auto, optimize=false)
                # The cost model must no longer divert to a wrong table: :auto
                # is now the expression circuit, gate for gate.
                @test gate_count(c_auto) == gate_count(c_expr)
                @test c_auto.output_elem_widths == c_expr.output_elem_widths == [W]
                @test verify_reversibility(c_auto)
                @test verify_reversibility(c_expr)
                # The narrowed semantics, checked against an independent W-bit
                # oracle over every W-bit input pattern (fits in Int8 for W≤7).
                for raw in 0:(2^W - 1)
                    @test simulate(c_expr, Int8(raw)) ==
                          narrowed_f2_signed(raw, W)
                    @test simulate(c_auto, Int8(raw)) ==
                          narrowed_f2_signed(raw, W)
                end
                # The bead's signed witness at W=4: expression 4, :auto used to
                # return 1 (the table's natural-width value).
                if W == 4
                    @test simulate(c_expr, Int8(-2)) == 4
                    @test simulate(c_auto, Int8(-2)) == 4
                    @test simulate(c_auto, Int8(14)) == 4
                end
                # Explicit :tabulate refuses, loudly, naming the bead.
                @test_throws ArgumentError reversible_compile(
                    iwj6_f2_signed, Int8; bit_width=W, strategy=:tabulate)
                err = try
                    reversible_compile(iwj6_f2_signed, Int8; bit_width=W,
                                       strategy=:tabulate)
                    nothing
                catch e
                    e
                end
                @test err isa ArgumentError
                @test err isa ArgumentError && occursin("Bennett-iwj6", err.msg)
                # Same for the unsigned witness (intermediate overflow, then
                # shift): at W=4, input 7 is 0x0 under expression, 0xc under
                # the old table.
                u_expr = reversible_compile(iwj6_f2_ushift, UInt8; bit_width=W,
                                            strategy=:expression, optimize=false)
                u_auto = reversible_compile(iwj6_f2_ushift, UInt8; bit_width=W,
                                            strategy=:auto, optimize=false)
                @test gate_count(u_auto) == gate_count(u_expr)
                @test verify_reversibility(u_auto)
                @test verify_reversibility(u_expr)
                for raw in 0:(2^W - 1)
                    @test simulate(u_expr, UInt8(raw)) ==
                          narrowed_f2_ushift(raw, W)
                    @test simulate(u_auto, UInt8(raw)) ==
                          narrowed_f2_ushift(raw, W)
                end
                @test_throws ArgumentError reversible_compile(
                    iwj6_f2_ushift, UInt8; bit_width=W, strategy=:tabulate)
            end
        end
        # `bit_width` wider than the argument is not narrowing either — the
        # table is still built from the natural-width function, so it is
        # refused for the same reason.
        for W in (12, 16)
            @test_throws ArgumentError reversible_compile(
                iwj6_f2_signed, Int8; bit_width=W, strategy=:tabulate)
            @test reversible_compile(iwj6_f2_signed, Int8; bit_width=W,
                                     strategy=:auto) isa ReversibleCircuit
        end
    end

    @testset "bit_width == natural width is STILL narrowing: tabulation refused" begin
        # `_narrow_ir` rewrites every width, so a function that widens
        # internally differs at bit_width=8 from its natural-width self:
        # pre-fix the table matched native while :expression differed on
        # 191/256 inputs. Any explicit bit_width therefore disables the table.
        widen_cmp(x::Int8) = (Int16(x) * Int16(x) > Int16(200)) ? Int8(1) : Int8(0)
        for f in (iwj6_f2_signed, widen_cmp)
            @test_throws ArgumentError reversible_compile(f, Int8; bit_width=8,
                                                          strategy=:tabulate)
        end
        c_exp = reversible_compile(iwj6_f2_signed, Int8; bit_width=8,
                                  strategy=:expression)
        c_aut = reversible_compile(iwj6_f2_signed, Int8; bit_width=8,
                                  strategy=:auto)
        @test verify_reversibility(c_exp)
        @test verify_reversibility(c_aut)
        # :auto must be the expression circuit, whatever that computes
        # (its own soundness at bit_width=8 is Bennett-mrhg).
        for x in Int8(-128):Int8(127)
            @test simulate(c_aut, x) == simulate(c_exp, x)
        end
        # Bennett-mrhg: an Int16 data domain is NOT narrowable, so the
        # expression and :auto paths now REFUSE it at bit_width=8 instead of
        # re-typing the i16 multiply/compare to 8 bits.  The pre-fix circuit
        # disagreed with itself across optimization modes (optimize=false
        # returned 1 for x=1 where native returns 0), so the old
        # "returns a circuit" expectation was pinning an unsound result.
        for strategy in (:expression, :auto), f in (widen_cmp,)
            err = try
                reversible_compile(f, Int8; bit_width=8, strategy)
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test err isa ArgumentError && occursin("Bennett-mrhg", err.msg)
        end
    end

    @testset "F3: unsupported return shapes are rejected, not truncated" begin
        # A tuple return is not a single scalar Integer: the table must not
        # silently pick a width (that is how F3 truncated Int8→Int16).
        tup(x::Int8) = (x, x * Int8(2))
        @test_throws ArgumentError reversible_compile(tup, Int8; strategy=:tabulate)
        err = try
            reversible_compile(tup, Int8; strategy=:tabulate); nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test err isa ArgumentError && occursin("Bennett-iwj6", err.msg)
        # :auto falls through to expression lowering, which handles the tuple.
        c_auto = reversible_compile(tup, Int8; strategy=:auto)
        @test verify_reversibility(c_auto)
        for x in Int8(-128):Int8(127)
            @test simulate(c_auto, x) == tup(x)
        end
        # A non-Integer return is rejected too (pre-fix this reached
        # `_tabulate_build_table` and died with a bare ErrorException).
        nonint(x::Int8) = Float64(x)
        @test_throws ArgumentError reversible_compile(nonint, Int8;
                                                      strategy=:tabulate)
    end

    @testset "F23: option domains are validated on every exit" begin
        f = x -> x * Int8(3)
        for strategy in (:expression, :tabulate, :auto)
            for kw in (:add, :mul, :target, :hashcons)
                @test_throws ArgumentError reversible_compile(
                    f, Int8; strategy, kw => :bogus)
            end
        end
        # ... and the valid values still work through the tabulate exit.
        c = reversible_compile(f, Int8; strategy=:tabulate, add=:ripple,
                               mul=:shift_add, target=:gate_count, hashcons=:none)
        @test verify_reversibility(c)
        for x in Int8(-128):Int8(127)
            @test simulate(c, x) == f(x)
        end
        # Every entry point, not just the Tuple one: the Float64 overload
        # delegates through it, and the CompileOptions bundle unwraps into
        # the same kwargs.
        @test_throws ArgumentError reversible_compile(x -> x + x, Float64;
                                                      add=:bogus)
        @test_throws ArgumentError reversible_compile(
            f, Tuple{Int8}, CompileOptions(add=:bogus))
        @test_throws ArgumentError reversible_compile(
            extract_parsed_ir(f, Tuple{Int8}); hashcons=:bogus)
    end

    @testset "F23: ParsedIR overload rejects max_loop_iterations < 0" begin
        parsed = Bennett.extract_parsed_ir(x -> x + Int8(1), Tuple{Int8})
        @test_throws ArgumentError reversible_compile(parsed; max_loop_iterations=-1)
        @test_throws "max_loop_iterations must be >= 0" reversible_compile(
            parsed; max_loop_iterations=-1)
        @test reversible_compile(parsed; max_loop_iterations=0) isa ReversibleCircuit
    end

    @testset "F23: Tuple{Float64} rejects bit_width (as the Float64 overload does)" begin
        @test_throws ArgumentError reversible_compile(identity, Tuple{Float64};
                                                      bit_width=4, strategy=:expression)
        @test_throws ArgumentError reversible_compile(identity, Tuple{Float64};
                                                      bit_width=4, strategy=:auto)
        # bit_width=0 (the default) is still fine on that route.
        @test reversible_compile(identity, Tuple{Float64}) isa ReversibleCircuit
    end
end
