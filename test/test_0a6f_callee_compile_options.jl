using Test, Bennett
using Bennett: register_callee!, LoopGuard

# Bennett-0a6f / Bennett-jgyx — a registered callee (soft-float, the division
# helpers, the pmap / soft-memory helpers) is inlined by `lower_call!` under
# the SAME resolved compile options as its caller: add, mul (with target=:depth
# already resolved into it), fold_constants, compact_calls, use_inplace,
# auto_self_reversing, mem / persistent_impl / hashcons. Before the fix every
# callee was lowered with DEFAULT options and a hard-coded loop bound of 64, so
# `reversible_compile(f, Float64; target=:depth)` produced the byte-identical
# circuit to the default (Astra B-tests-api F18: 149,456 gates both ways).
#
# Loop-bound policy (`Bennett._callee_loop_bound`): always 64, whatever the
# caller's max_loop_iterations (which governs the caller's own loops only).

fm(x, y) = x * y
fa(x, y) = x + y
dv(x, y) = y == 0 ? x : x ÷ y      # b == 0 is LLVM-poison in a circuit; keep it out

counts(c) = (gate_count(c).total, gate_count(c).Toffoli, toffoli_depth(c))

const F64_PAIRS = [(1.5, 2.25), (-3.0, 7.0), (0.1, 0.2), (1.0e300, 1.0e10),
                   (5.0e-324, 0.5), (-0.0, 3.0), (Inf, 2.0), (2.0^-1022, 2.0^-3),
                   (123.456, -0.001), (prevfloat(1.0), nextfloat(1.0))]

function check_f64(c, op)
    for (a, b) in F64_PAIRS
        r = reinterpret(UInt64, simulate(c, (reinterpret(UInt64, a), reinterpret(UInt64, b))))
        @test r == reinterpret(UInt64, op(a, b))
    end
    @test verify_reversibility(c; n_tests=3)
end

@testset "Bennett-0a6f: callees lowered under the caller's compile options" begin
    @testset "loop-bound policy" begin
        for K in (0, 10, 64, 200, 256)                 # independent of the caller's bound
            @test Bennett._callee_loop_bound(K) == 64
        end
        # every LowerOptions field reaches the callee, under the same name
        o = Bennett.LowerOptions(max_loop_iterations=7, use_inplace=false,
                                 fold_constants=false, compact_calls=true, add=:qcla,
                                 mul=:qcla_tree, target=:depth, auto_self_reversing=false,
                                 mem=:persistent, persistent_impl=:hamt, hashcons=:naive)
        kw = Bennett._callee_lower_kwargs(o)
        @test Set(keys(kw)) == Set(fieldnames(Bennett.LowerOptions))
        for f in fieldnames(Bennett.LowerOptions)
            f === :max_loop_iterations && continue
            @test kw[f] == getfield(o, f)
        end
        @test kw.max_loop_iterations == 64
        @test Bennett._callee_lower_kwargs(Bennett.LowerOptions()) ==
              merge(NamedTuple(f => getfield(Bennett.LowerOptions(), f)
                               for f in fieldnames(Bennett.LowerOptions)),
                    (max_loop_iterations = 64,))   # defaults → pre-fix callee lowering
    end

    @testset "Float64 mul: default pinned, qcla_tree reaches soft_fmul; :depth never deeper" begin
        c0 = reversible_compile(fm, Float64, Float64)
        @test counts(c0) == (149456, 38884, 3104)      # pre-fix default — must not move
        cq = reversible_compile(fm, Float64, Float64; mul=:qcla_tree)
        cd = reversible_compile(fm, Float64, Float64; target=:depth)
        # Bennett-bnfk: target=:depth keeps shift_add (qcla_tree is deeper
        # here), so the callee-lowered circuit equals the default.
        @test counts(cd) == counts(c0)
        # The strategy now reaches soft_fmul's 64-bit multiplies (pre-fix:
        # identical to default). qcla_tree costs ~3x the Toffolis, as it does
        # on plain Int64; it does NOT lower toffoli_depth at this width (nor
        # does it on Int32: 180 → 256) — pinned so a change is noticed.
        @test gate_count(cq).Toffoli > 2 * gate_count(c0).Toffoli
        @test counts(cq) == (340424, 113452, 3382)
        check_f64(c0, *)
        check_f64(cq, *)
    end

    @testset "Float64 add: default pinned, add=:qcla reaches soft_fadd" begin
        c0 = reversible_compile(fa, Float64, Float64)
        @test counts(c0) == (63058, 12488, 2796)
        cq = reversible_compile(fa, Float64, Float64; add=:qcla)
        # qcla trades Toffolis for carry-lookahead (as on plain Int64:
        # 250 → 596); inside soft_fadd it does not shorten toffoli_depth.
        @test gate_count(cq).Toffoli > gate_count(c0).Toffoli
        @test counts(cq) == (67260, 16204, 3022)
        cc = reversible_compile(fa, Float64, Float64; add=:cuccaro)
        @test cc.n_wires < c0.n_wires                  # Cuccaro's point: in-place, fewer wires
        check_f64(c0, +)
        check_f64(cq, +)
        check_f64(cc, +)
    end

    @testset "Int32 ÷: default pinned, fold_constants=false reaches soft_udiv" begin
        c0 = reversible_compile(dv, Int32, Int32)
        @test counts(c0) == (1597248, 165104, 35218)
        cn = reversible_compile(dv, Int32, Int32; fold_constants=false)
        # Pre-fix only the caller's own 126 gates were unfolded (1,597,374);
        # the 64-bit soft_udiv callee is now unfolded too.
        @test gate_count(cn).total > 1597374
        @test gate_count(cn).total == 3306288
        for c in (c0, cn), (a, b) in ((Int32(100), Int32(7)), (Int32(-100), Int32(7)),
                                      (typemax(Int32), Int32(-3)), (Int32(5), Int32(0)))
            @test simulate(c, (a, b)) == dv(a, b)
        end
        @test verify_reversibility(c0; n_tests=2)
        @test verify_reversibility(cn; n_tests=2)
    end
end

# A registered callee whose data-dependent loop needs > 64 iterations (Collatz
# step count of 27 is 111, capped at 110).
@noinline function _0a6f_collatz(x::UInt16)
    steps = UInt16(0)
    val = x
    while val > UInt16(1) && steps < UInt16(110)
        val = iseven(val) ? val >> 1 : UInt16(3) * val + UInt16(1)
        steps += UInt16(1)
    end
    return steps
end
register_callee!(_0a6f_collatz)
_0a6f_caller(x::UInt16) = _0a6f_collatz(x) + UInt16(1)

# Bennett-0a6f follow-up: the caller's max_loop_iterations governs the
# caller's loops only; an inlined callee is always unrolled 64 times, so its
# gate count does not depend on the caller's bound.
@testset "a callee's gate count does not depend on the caller's max_loop_iterations" begin
    xs = Int8[-128, -127, -1, 0, 1, 7, 100, 127]
    ys = Int8[-128, -127, -3, -1, 1, 3, 100, 127]      # non-zero divisors, extremes
    for K in (0, 64, 256)
        kw = K == 0 ? (;) : (; max_loop_iterations=K)
        t = @elapsed c = reversible_compile((x, y) -> x ÷ y, Int8, Int8; kw...)
        @test counts(c)[1:2] == (1596238, 164892)
        K == 256 && @info "Int8 ÷ compile at max_loop_iterations=256" seconds=t
        for x in xs, y in ys
            (x == typemin(Int8) && y == Int8(-1)) && continue   # overflow, poison
            @test simulate(c, (x, y)) == x ÷ y
        end
        @test verify_reversibility(c; n_tests=2)
    end

    # A callee needing > 64 iterations is NOT given the caller's larger bound:
    # its guard (K == 64) fires loudly for a deep input (Bennett-jgyx open).
    @test any(i -> i isa Bennett.IRCall && i.callee === _0a6f_collatz,
              (i for b in Bennett.extract_parsed_ir(_0a6f_caller, Tuple{UInt16}).blocks
                 for i in b.instructions))
    c = reversible_compile(_0a6f_caller, UInt16; max_loop_iterations=120)
    @test !isempty(c.loop_check_wires)
    @test all(lg -> lg.K == 64, c.loop_check_wires)
    for x in UInt16[1, 2, 7, 9]                      # <= 64 steps
        @test simulate(c, x) == _0a6f_caller(x)
    end
    @test_throws ErrorException simulate(c, UInt16(27))   # 111 steps > 64
end

# Float64 sqrt: soft_fsqrt is inlined by LLVM into the CALLER's own IR (no
# IRCall survives), so its unrolled loop IS the caller's and legitimately
# scales with max_loop_iterations — not callee-bound-independent.
@testset "Float64 sqrt: its loop is the caller's, so it scales with the caller's bound" begin
    @test_throws ArgumentError reversible_compile(sqrt, Float64)
    c64 = reversible_compile(sqrt, Float64; max_loop_iterations=64)
    @test counts(c64)[1:2] == (724785, 155006)
    @test gate_count(reversible_compile(sqrt, Float64; max_loop_iterations=70)).total > 724785
end
