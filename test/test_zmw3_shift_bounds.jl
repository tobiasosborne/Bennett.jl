# Bennett-zmw3 / U111 — robustness bounds for raw shifts and the
# resolve!() constant mask.
#
# Two related fixes from review #04 F15 and F16:
#
# (1) `resolve!()` (src/lower.jl:195) computes
#     `val = op.value & ((1 << width) - 1)`. At width=64 this works ONLY
#     because Julia's shift saturation makes `1 << 64 == 0` and
#     `0 - 1 == -1` (all-ones). Replaced with an explicit mask via
#     `_wmask(width)` so the bit pattern is correct without leaning on
#     Julia-specific shift semantics.
#
# (2) `lower_shl!` / `lower_lshr!` / `lower_ashr!` (constant-shift path)
#     silently iterated over invalid wire indices for negative `k` and
#     gave shift-by-zero semantics for `k > W` (the bit-select MUX tree
#     ignored high bits of the shift). Now bounded `0 <= k <= W` with
#     a fail-loud assertion. `k == W` is explicitly accepted: shl/lshr
#     return all-zero, ashr sign-extends.
#
# (3) Variable shifts (`lower_var_*`) provide shift-mod-(next-power-of-2-
#     ≥-W) semantics — documented in the variable-shift docstring. Julia's
#     `<<` / `>>` wrappers always emit a guarded select for the >= width
#     case so Julia frontends never hit this; raw LLVM input from a future
#     C/Rust frontend would get the mod-W behaviour. Out of scope for
#     this bead's fix; documented for clarity.

using Test
using Bennett

@testset "Bennett-zmw3 / U111 — shift bounds + resolve! mask robustness" begin

    @testset "resolve! mask at width=64 (no shift-saturation reliance)" begin
        # Compile a function with a 64-bit all-ones constant. Pre-fix this
        # worked by accident (Julia saturation); post-fix it's explicit.
        c = reversible_compile(x -> x ⊻ Int64(-1), Int64; optimize=false, fold_constants=false)
        @test verify_reversibility(c)
        for x in Int64[Int64(0), Int64(1), Int64(-1), typemax(Int64), typemin(Int64),
                        Int64(0x12345678), Int64(0xDEADBEEF)]
            @test simulate(c, x) == x ⊻ Int64(-1)
        end
    end

    @testset "resolve! mask at width=63 (boundary)" begin
        # 5qrn's _wmask handles width<64 via `(UInt64(1) << width) - UInt64(1)`.
        # At width=63 that's `0x7FFFFFFFFFFFFFFF`. Verify via UInt64 (we
        # don't have a 63-bit Julia integer type to test directly, so this
        # is more of a "still works at the highest sub-64 width" sanity).
        c = reversible_compile(x -> x ⊻ Int64(0x7FFFFFFFFFFFFFFF), Int64; optimize=false)
        @test verify_reversibility(c)
        for x in Int64[Int64(0), Int64(1), Int64(-1), typemax(Int64)]
            @test simulate(c, x) == x ⊻ Int64(0x7FFFFFFFFFFFFFFF)
        end
    end

    @testset "constant shift k=W returns zero for shl/lshr, sign-ext for ashr" begin
        for W in (8, 16, 32, 64)
            # Set up: inputs at wires 1..W, ask for shift k=W.
            gates_shl  = Bennett.ReversibleGate[]
            gates_lshr = Bennett.ReversibleGate[]
            gates_ashr = Bennett.ReversibleGate[]
            wa_shl  = Bennett.WireAllocator()
            wa_lshr = Bennett.WireAllocator()
            wa_ashr = Bennett.WireAllocator()
            a_shl  = Bennett.allocate!(wa_shl,  W)
            a_lshr = Bennett.allocate!(wa_lshr, W)
            a_ashr = Bennett.allocate!(wa_ashr, W)
            a = a_shl  # for the gate-shape assertions below; same pattern in all three

            r_shl  = Bennett.lower_shl!(gates_shl,   wa_shl,  a_shl,  W, W)
            r_lshr = Bennett.lower_lshr!(gates_lshr, wa_lshr, a_lshr, W, W)
            r_ashr = Bennett.lower_ashr!(gates_ashr, wa_ashr, a_ashr, W, W)

            # shl/lshr: empty gate list (no CNOTs emitted).
            @test isempty(gates_shl)
            @test isempty(gates_lshr)
            @test length(r_shl) == W
            @test length(r_lshr) == W

            # ashr: W CNOTs all from a_ashr[W] (sign bit) to result wires.
            @test length(gates_ashr) == W
            for g in gates_ashr
                @test g isa Bennett.CNOTGate && g.control == a_ashr[W]
            end
        end
    end

    @testset "constant shift k > W rejected" begin
        for W in (8, 16, 32, 64)
            gates = Bennett.ReversibleGate[]
            wa = Bennett.WireAllocator()
            a = Bennett.allocate!(wa, W)
            @test_throws ErrorException Bennett.lower_shl!(gates,  wa, a, W + 1, W)
            @test_throws ErrorException Bennett.lower_lshr!(gates, wa, a, W + 1, W)
            @test_throws ErrorException Bennett.lower_ashr!(gates, wa, a, W + 1, W)
            # Negative k also rejected (would silently iterate over invalid
            # wire indices in the pre-fix code).
            @test_throws ErrorException Bennett.lower_shl!(gates,  wa, a, -1, W)
            @test_throws ErrorException Bennett.lower_lshr!(gates, wa, a, -1, W)
            @test_throws ErrorException Bennett.lower_ashr!(gates, wa, a, -1, W)
        end
    end

    @testset "constant shift k=W-1 still works (boundary)" begin
        # Verify the assertion isn't off-by-one — k = W-1 is the largest
        # NORMAL shift and must produce a single CNOT (shl/lshr) or two CNOTs (ashr).
        for W in (8, 16, 32, 64)
            gates_shl = Bennett.ReversibleGate[]
            wa = Bennett.WireAllocator()
            a = Bennett.allocate!(wa, W)
            r = Bennett.lower_shl!(gates_shl, wa, a, W - 1, W)
            @test length(gates_shl) == 1
            @test gates_shl[1] == Bennett.CNOTGate(a[1], r[W])
        end
    end

    @testset "resolve! width=0 / width=65 rejected" begin
        # Width validation pre-fix was implicit (downstream loops just no-op).
        # Now explicit per Bennett-zmw3 / U111.
        gates = Bennett.ReversibleGate[]
        wa = Bennett.WireAllocator()
        vw = Dict{Symbol, Vector{Int}}()
        op = Bennett.iconst(42)
        @test_throws ErrorException Bennett.resolve!(gates, wa, vw, op, 0)
        @test_throws ErrorException Bennett.resolve!(gates, wa, vw, op, 65)
    end

    @testset "Julia frontend shift end-to-end (must keep working)" begin
        # Julia's `<<` / `>>` wraps a guarded select; reversible_compile
        # of a shift-using lambda should still work end-to-end.
        c_shl = reversible_compile(x -> x << 3, Int8; optimize=false)
        @test verify_reversibility(c_shl)
        for x in Int8(-128):Int8(127)
            @test simulate(c_shl, x) == x << 3
        end
        c_ashr = reversible_compile(x -> x >> 2, Int8; optimize=false)
        @test verify_reversibility(c_ashr)
        for x in Int8(-128):Int8(127)
            @test simulate(c_ashr, x) == x >> 2
        end
    end

    @testset "regression: pinned baselines unchanged" begin
        # Mask cleanup at resolve! is bit-exact; assertions only fire on
        # invalid input. Existing gate-count baselines must not move.
        @test gate_count(reversible_compile(x -> x + Int8(1),  Int8;  optimize=false)).total == 58
        @test gate_count(reversible_compile(x -> x + Int16(1), Int16; optimize=false)).total == 114
        @test gate_count(reversible_compile(x -> x + Int32(1), Int32; optimize=false)).total == 226
        @test gate_count(reversible_compile(x -> x + Int64(1), Int64; optimize=false)).total == 450
    end
end
