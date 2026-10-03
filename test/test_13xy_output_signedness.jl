using Test
using Bennett
using Bennett: ReversibleCircuit, ReversibleGate, CNOTGate

# Bennett-13xy: `ReversibleCircuit` records the output element signedness from
# the Julia return type at compile time (`output_elem_unsigned`), and every
# simulate path decodes with it instead of the Bennett-zc50 width-equality
# heuristic. Invariant: for a circuit compiled from a Julia function whose
# return type is a fixed-width integer (or a tuple of them) at its natural
# width, `simulate(c, x) === f(x)` — value AND type — and the typed
# `simulate(c, T, x) === f(x) % T`. Circuits with no Julia return type (raw
# ParsedIR / .ll, hand-built) record `nothing` and keep the heuristic.
#
# Witness: f(x::UInt16) = x % UInt8 decoded 0xffff → Int8(-1), so the typed
# `simulate(c, UInt16, 0xffff)` returned 0xffff instead of 0x00ff.

const _13XY_INTS = (Int8, UInt8, Int16, UInt16, Int32, UInt32, Int64, UInt64)

# One named method per (input, output) pair: a closure capturing the type
# would be a non-isbits capture (Bennett-o9sv).
for IT in _13XY_INTS, OT in _13XY_INTS
    @eval $(Symbol(:_f13xy_, IT, :_, OT))(x::$IT) = x % $OT
end

const _13XY_PATTERNS = UInt64[0, 1, 2, 0x7f, 0x80, 0xff, 0x100, 0x7fff, 0x8000,
                              0xffff, 0x7fffffff, 0x80000000, 0xffffffff,
                              0x7fffffffffffffff, 0x8000000000000000,
                              0xffffffffffffffff, 0x0123456789abcdef,
                              0xfedcba9876543210]

_13xy_inputs(::Type{T}) where {T} =
    sizeof(T) == 1 ? [x % T for x in 0x00:0xff] : unique([p % T for p in _13XY_PATTERNS])

@testset "Bennett-13xy: ReversibleCircuit carries output signedness" begin

    @testset "witness: UInt16 → UInt8 truncation, typed simulate" begin
        c = reversible_compile(_f13xy_UInt16_UInt8, UInt16)
        @test c.output_elem_unsigned == [true]
        @test simulate(c, UInt16, 0xffff) === 0x00ff
        @test simulate(c, 0xffff) === 0xff
        @test verify_reversibility(c)
    end

    @testset "$IT → $OT" for IT in _13XY_INTS, OT in _13XY_INTS
        f = getfield(@__MODULE__, Symbol(:_f13xy_, IT, :_, OT))
        c = reversible_compile(f, IT)
        @test c.output_elem_unsigned == [OT <: Unsigned]
        ok_untyped = ok_typed = ok_wide = true
        for x in _13xy_inputs(IT)
            want = f(x)
            ok_untyped &= simulate(c, x) === want
            ok_typed   &= simulate(c, OT, x) === want
            # A wider T is sign-/zero-extended from the RECORDED signedness.
            ok_wide    &= simulate(c, OT <: Unsigned ? UInt64 : Int64, x) ===
                          want % (OT <: Unsigned ? UInt64 : Int64)
        end
        @test ok_untyped
        @test ok_typed
        @test ok_wide
        @test verify_reversibility(c)
    end

    @testset "multi-argument, mixed signedness" begin
        g1(a::Int8, b::UInt16) = (a % UInt16) + b            # → UInt16
        g2(a::UInt8, b::UInt8) = reinterpret(Int8, a ⊻ b)     # → Int8, all-unsigned in
        g3(a::UInt32, b::Int16) = (a % Int16) - b             # → Int16, narrowing
        for (g, T1, T2) in ((g1, Int8, UInt16), (g2, UInt8, UInt8), (g3, UInt32, Int16))
            c = reversible_compile(g, T1, T2)
            ok = true
            for a in _13xy_inputs(T1)[1:min(end, 40)], b in _13xy_inputs(T2)[1:min(end, 12)]
                ok &= simulate(c, (a, b)) === g(a, b)
            end
            @test ok
            @test verify_reversibility(c)
        end
    end

    @testset "tuple returns decode per element" begin
        # Mixed-WIDTH tuples (`{ i8, i16 }`) are rejected by extraction today,
        # so mix signedness at a common width.
        t1(x::UInt8) = (x % Int8, x + 0x01)
        t2(x::Int16) = (x % UInt16, x, -x, (x >> 3) % UInt16)
        for (t, T) in ((t1, UInt8), (t2, Int16))
            c = reversible_compile(t, T)
            @test c.output_elem_unsigned == [R <: Unsigned for R in fieldtypes(typeof(t(zero(T))))]
            @test all(simulate(c, x) === t(x) for x in _13xy_inputs(T))
            @test verify_reversibility(c)
        end
    end

    @testset "controlled(...) propagates the field" begin
        c = reversible_compile(_f13xy_UInt16_UInt8, UInt16)
        cc = controlled(c)
        @test cc.circuit.output_elem_unsigned == [true]
        @test simulate(cc, true, 0xffff) === 0xff
        @test simulate(cc, false, 0xffff) === 0x00
        cs = controlled(reversible_compile(_f13xy_UInt8_Int8, UInt8))
        @test simulate(cs, true, 0xff) === Int8(-1)
        @test verify_reversibility(cc)
    end

    @testset "compose(...) takes the right circuit's signedness" begin
        c1 = reversible_compile(_f13xy_UInt16_UInt8, UInt16)   # UInt16 → UInt8
        c2s = reversible_compile(_f13xy_UInt8_Int8, UInt8)     # UInt8 → Int8
        c2u = reversible_compile(_f13xy_Int8_UInt8, Int8)      # Int8 → UInt8
        cs = compose(c1, c2s)
        @test cs.output_elem_unsigned == [false]
        @test simulate(cs, 0xffff) === Int8(-1)
        c1s = reversible_compile(_f13xy_UInt16_Int8, UInt16)
        cu = compose(c1s, c2u)
        @test cu.output_elem_unsigned == [true]
        @test simulate(cu, 0xffff) === 0xff
        @test verify_reversibility(cs)
        @test verify_reversibility(cu)
    end

    @testset "tabulate path records signedness too" begin
        c = reversible_compile(_f13xy_UInt8_Int8, UInt8; strategy=:tabulate)
        @test c.output_elem_unsigned == [false]
        @test all(simulate(c, x) === x % Int8 for x in 0x00:0xff)
        @test verify_reversibility(c)
    end

    @testset "capturing closure keeps the field" begin
        k = 0x05
        h = x::UInt16 -> (x % UInt8) + k
        c = reversible_compile(h, UInt16)
        @test c.output_elem_unsigned == [true]
        @test all(simulate(c, x) === h(x) for x in _13xy_inputs(UInt16))
        @test verify_reversibility(c)
    end

    @testset "raw ParsedIR / hand-built circuits stay unknown (heuristic)" begin
        p = Bennett.extract_parsed_ir(_f13xy_UInt16_UInt8, Tuple{UInt16})
        c_raw = reversible_compile(p)
        @test c_raw.output_elem_unsigned === nothing
        @test simulate(c_raw, 0xffff) === Int8(-1)      # zc50 fallback, unchanged
        c = reversible_compile(_f13xy_UInt16_UInt8, UInt16)
        @test gate_count(c) == gate_count(c_raw)          # no gate-count change
        @test c.gates == c_raw.gates
        id8 = ReversibleCircuit(16, ReversibleGate[CNOTGate(i, 8 + i) for i in 1:8],
                                collect(1:8), collect(9:16), Int[], [8], [8])
        @test id8.output_elem_unsigned === nothing
        @test simulate(id8, 0xff) === 0xff
        @test simulate(id8, Int8(-1)) === Int8(-1)
        # Explicit record overrides the heuristic; length must match.
        id8s = ReversibleCircuit(16, id8.gates, collect(1:8), collect(9:16), Int[],
                                 [8], [8]; output_elem_unsigned=[false])
        @test simulate(id8s, 0xff) === Int8(-1)
        @test_throws ArgumentError ReversibleCircuit(16, id8.gates, collect(1:8),
            collect(9:16), Int[], [8], [8]; output_elem_unsigned=[true, false])
    end

    @testset "repeat compiles stay === (compile cache intact)" begin
        @test reversible_compile(_f13xy_UInt16_UInt8, UInt16) ===
              reversible_compile(_f13xy_UInt16_UInt8, UInt16)
    end

    @testset "Bool / narrowed returns stay unknown" begin
        cb = reversible_compile(x -> x > 0x10, UInt8)
        @test cb.output_elem_unsigned === nothing
        cn = reversible_compile(x -> x + UInt8(1), UInt8; bit_width=4)
        @test cn.output_elem_unsigned === nothing
    end
end
