using Test
using Bennett
using LLVM

# T3b.3 — Universal dispatcher. For each alloca-backed store/load, pick the
# cheapest correct strategy from:
#
#   :shadow           (T3b.2)  static idx; cheap direct CNOT
#   :mux_exch_4x8     (T1b.3)  dynamic idx, shape (W=8, N=4)
#   :mux_exch_8x8     (T1b.3)  dynamic idx, shape (W=8, N=8)
#   :qrom             (T1c.2)  already routed in lower_var_gep! for globals
#
# Tests verify (a) end-to-end correctness, (b) strategy actually fires,
# (c) mixed-strategy functions work (static-idx stores + dynamic-idx load).

function _compile_ir(ir_string::String)
    c = nothing
    LLVM.Context() do _ctx
        mod = parse(LLVM.Module, ir_string)
        parsed = Bennett._module_to_parsed_ir(mod)
        lr = Bennett.lower(parsed)
        c = Bennett.bennett(lr)
        dispose(mod)
    end
    return c
end

@testset "T3b.3 universal memory dispatcher" begin

    @testset "static-idx store + static-idx load (pure shadow path)" begin
        # Ref pattern forces a scalar alloca with static idx = 0 for every op.
        f(x::UInt8) = let r = Ref(UInt8(0))
            r[] = x
            r[]
        end
        c = reversible_compile(f, UInt8)
        @test verify_reversibility(c)
        for x in UInt8(0):UInt8(255)
            @test simulate(c, x) == reinterpret(Int8, x)
        end
    end

    @testset "static-idx stores + dynamic-idx load (shadow + MUX EXCH mixed)" begin
        # Hand-crafted IR: 4 static-idx stores into a (8, 4) alloca, then a
        # dynamic-idx load. Stores should go through shadow (static idx),
        # load through MUX EXCH (dynamic idx, shape matches). Mixed-strategy
        # compatibility is the key invariant: MUX EXCH load must see the
        # post-shadow-store primal state.
        ir = raw"""
        define i8 @julia_mixed_1(i8 %x, i8 %y, i8 %z, i8 %w, i8 %i) {
        top:
          %p  = alloca i8, i32 4
          %g0 = getelementptr i8, ptr %p, i32 0
          %g1 = getelementptr i8, ptr %p, i32 1
          %g2 = getelementptr i8, ptr %p, i32 2
          %g3 = getelementptr i8, ptr %p, i32 3
          store i8 %x, ptr %g0
          store i8 %y, ptr %g1
          store i8 %z, ptr %g2
          store i8 %w, ptr %g3
          %idx = zext i8 %i to i32
          %gvar = getelementptr i8, ptr %p, i32 %idx
          %v = load i8, ptr %gvar
          ret i8 %v
        }
        """
        c = _compile_ir(ir)
        @test verify_reversibility(c)
        tbl = (Int8(3), Int8(-5), Int8(42), Int8(127))
        for i in 0:3
            got = simulate(c, (tbl[1], tbl[2], tbl[3], tbl[4], Int8(i)))
            @test got == tbl[i+1]
        end
    end

    @testset "global constant table goes through QROM (already T1c.2)" begin
        # Regression: T1c.2 dispatch for global constant tables still works
        # and is unaffected by the T3b.3 alloca-strategy pick.
        f(x::UInt8) = let tbl = (UInt8(0x63), UInt8(0x7c), UInt8(0x77), UInt8(0x7b))
            tbl[(x & UInt8(0x3)) + 1]
        end
        c = reversible_compile(f, UInt8)
        @test verify_reversibility(c)
        @test gate_count(c).total < 300  # QROM not MUX
        for x in UInt8(0):UInt8(15)
            @test simulate(c, x) == reinterpret(Int8, f(x))
        end
    end

    @testset "strategy picker returns :shadow for static idx" begin
        @test Bennett._pick_alloca_strategy((8, 4), Bennett.iconst(2)) == :shadow
        @test Bennett._pick_alloca_strategy((8, 16), Bennett.iconst(0)) == :shadow
        @test Bennett._pick_alloca_strategy((16, 4), Bennett.iconst(0)) == :shadow
    end

    @testset "strategy picker returns :mux_exch_* for dynamic idx on supported shapes" begin
        @test Bennett._pick_alloca_strategy((8, 4), Bennett.ssa(:idx)) == :mux_exch_4x8
        @test Bennett._pick_alloca_strategy((8, 8), Bennett.ssa(:idx)) == :mux_exch_8x8
        # M1 additions (Bennett-cc0): N·W ≤ 64 single-UInt64 shapes.
        @test Bennett._pick_alloca_strategy((8, 2),  Bennett.ssa(:idx)) == :mux_exch_2x8
        @test Bennett._pick_alloca_strategy((16, 2), Bennett.ssa(:idx)) == :mux_exch_2x16
        @test Bennett._pick_alloca_strategy((16, 4), Bennett.ssa(:idx)) == :mux_exch_4x16
        @test Bennett._pick_alloca_strategy((32, 2), Bennett.ssa(:idx)) == :mux_exch_2x32
    end

    @testset "strategy picker returns :shadow_checkpoint for dynamic idx on N·W > 64 shapes" begin
        # Bennett-cc0 M3a (Bennett-jqyt): multi-word shapes (N·W > 64) now
        # dispatch to the T4 shadow-checkpoint MVP fallback rather than
        # :unsupported. MUX EXCH is still preferred for N·W ≤ 64 shapes
        # (cheaper per-op cost); T4 is the universal correctness fallback.
        @test Bennett._pick_alloca_strategy((8, 100), Bennett.ssa(:idx)) == :shadow_checkpoint
        @test Bennett._pick_alloca_strategy((16, 8),  Bennett.ssa(:idx)) == :shadow_checkpoint
        @test Bennett._pick_alloca_strategy((32, 4),  Bennett.ssa(:idx)) == :shadow_checkpoint
        @test Bennett._pick_alloca_strategy((64, 2),  Bennett.ssa(:idx)) == :shadow_checkpoint
    end
end
