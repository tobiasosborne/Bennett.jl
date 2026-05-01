@testset "Controlled circuits" begin
    @testset "Controlled increment" begin
        f(x::Int8) = x + Int8(3)
        circuit = reversible_compile(f, Int8)
        cc = controlled(circuit)

        for x in typemin(Int8):typemax(Int8)
            @test simulate(cc, true, x) == f(x)
            @test simulate(cc, false, x) == Int8(0)
        end
        @test verify_reversibility(cc)

        gc_orig = gate_count(circuit)
        gc_ctrl = gate_count(cc.circuit)
        println("  Controlled increment:")
        println("    Original:   ", gc_orig)
        println("    Controlled: ", gc_ctrl)
    end

    @testset "Controlled polynomial" begin
        g(x::Int8) = x * x + Int8(3) * x + Int8(1)
        circuit = reversible_compile(g, Int8)
        cc = controlled(circuit)

        for x in Int8(0):Int8(15)
            @test simulate(cc, true, x) == g(x)
            @test simulate(cc, false, x) == Int8(0)
        end
        @test verify_reversibility(cc)
    end

    @testset "Controlled two-arg" begin
        m(x::Int8, y::Int8) = x * y + x - y
        circuit = reversible_compile(m, Int8, Int8)
        cc = controlled(circuit)

        for x in Int8(0):Int8(15), y in Int8(0):Int8(15)
            @test simulate(cc, true, (x, y)) == m(x, y)
            @test simulate(cc, false, (x, y)) == Int8(0)
        end
        @test verify_reversibility(cc)
    end

    @testset "Controlled Int16" begin
        f16(x::Int16) = x + Int16(7)
        circuit = reversible_compile(f16, Int16)
        cc = controlled(circuit)

        for x in [Int16(0), Int16(1), Int16(-1), typemin(Int16), typemax(Int16)]
            @test simulate(cc, true, x) == f16(x)
            @test simulate(cc, false, x) == Int16(0)
        end
        @test verify_reversibility(cc)
    end

    @testset "Controlled tuple return" begin
        swap(x::Int8, y::Int8) = (y, x)
        circuit = reversible_compile(swap, Int8, Int8)
        cc = controlled(circuit)

        for x in Int8(0):Int8(7), y in Int8(0):Int8(7)
            @test simulate(cc, true, (x, y)) == swap(x, y)
            @test simulate(cc, false, (x, y)) == (Int64(0), Int64(0))
        end
        @test verify_reversibility(cc)
    end

    # Bennett-kv7b / U65 (#05 F13): `controlled(c)` was previously
    # exercised only on plain integer arithmetic. The soft-float and
    # memory-backed lowering paths produce ParsedIR with phi-resolved
    # MUX trees + Cuccaro-style in-place operations; lifting those
    # under a control bit was a documented coverage gap. Pin both with
    # exhaustive (soft-float) and corner-case (memory-backed) sweeps.

    @testset "Controlled soft-float (soft_fneg)" begin
        # soft_fneg is the lightest soft-float primitive — flips the
        # IEEE 754 sign bit. Light enough for an exhaustive-on-corners
        # sweep without blowing test time.
        # Note: `simulate` returns Int64 (signedness-blind); reinterpret
        # to UInt64 to match `soft_fneg`'s return type — same pattern as
        # `test/test_float_circuit.jl`.
        circuit = reversible_compile(soft_fneg, UInt64)
        cc = controlled(circuit)

        # IEEE 754 corners + a couple of "ordinary" doubles.
        probes = Float64[1.0, -1.0, 0.0, -0.0, 3.14, -3.14, Inf, -Inf,
                         floatmin(Float64), -floatmin(Float64),
                         floatmax(Float64), -floatmax(Float64)]
        for x in probes
            x_bits = reinterpret(UInt64, x)
            # control=true: must equal forward soft_fneg (after Int64→UInt64 reinterpret)
            on_raw  = simulate(cc, true,  x_bits)
            @test reinterpret(UInt64, Int64(on_raw)) == soft_fneg(x_bits)
            # control=false: no work done; output is zero.
            off_raw = simulate(cc, false, x_bits)
            @test off_raw == 0
        end
        @test verify_reversibility(cc)
    end

    @testset "Controlled memory-backed (registered soft_* callee)" begin
        # The catalogue (#05 F13) called for "memory-backed" composition.
        # Var-indexed `Vector{UInt8}` allocas are not yet end-to-end
        # lowerable in `reversible_compile` (blocked on Bennett-z2dj T5-P6
        # `:persistent_tree` dispatcher), so the canonical "memory-
        # backed" probe here is a function that calls `soft_fmul` (a
        # registered soft-float callee whose lowering goes through the
        # MUX-store / shadow-memory primitives in `src/softmem.jl`).
        # `controlled(c)` must lift that callee-bridged circuit cleanly.
        function fmul_then_neg(a_bits::UInt64, b_bits::UInt64)
            return soft_fneg(soft_fmul(a_bits, b_bits))
        end
        circuit = reversible_compile(fmul_then_neg, UInt64, UInt64)
        cc = controlled(circuit)

        # Multiplicative IEEE 754 corner pairs.
        probes = [(1.0, 1.0), (1.0, -1.0), (2.0, 0.5), (3.14, 2.0),
                  (0.0, 0.0), (-0.0, 1.0), (Inf, 1.0), (1.0, Inf)]
        for (a, b) in probes
            a_bits = reinterpret(UInt64, a)
            b_bits = reinterpret(UInt64, b)
            on_raw  = simulate(cc, true,  (a_bits, b_bits))
            @test reinterpret(UInt64, Int64(on_raw)) == fmul_then_neg(a_bits, b_bits)
            @test simulate(cc, false, (a_bits, b_bits)) == 0
        end
        @test verify_reversibility(cc)
    end
end
