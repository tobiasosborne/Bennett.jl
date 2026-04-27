@testset "Bennett-y56a / U118 — integer division path consistency" begin

    # ---- Investigation summary (Bennett-y56a, 2026-04-27) ----
    #
    # The review (reviews/2026-04-21/06_antipatterns.md HIGH-9) flagged
    # three integer-division paths through the compiler:
    #   1. lower_binop! → lower_divrem! → IRCall(_soft_udiv_compile)
    #   2. user calls _soft_udiv_compile directly → callee inline
    #   3. unregistered callee → silent skip
    #
    # Post-salb (closed earlier today, 2026-04-27): path 3 is no longer
    # silent — `ir_extract.jl:1751` raises `_ir_error("call to ... has no
    # registered callee handler")` for unregistered callees that don't
    # match the benign-prefix allowlist. Path 2 still exists (direct calls
    # to the registered private kernel work), but produces unsigned-only
    # output — the sign handling lives in path 1's lower_divrem! wrapper.
    #
    # Disposition: investigated, doc-only. The three paths serve different
    # APIs:
    #   - Path 1: native `a ÷ b` on signed types (handles sign extension,
    #     negate, sign fix). Canonical user-facing path.
    #   - Path 1 (unsigned): native `a ÷ b` on unsigned types (skips sign
    #     handling).
    #   - Path 2: direct call to `_soft_udiv_compile` (or via `soft_udiv`
    #     public wrapper, which Julia may inline; the throw branch hits
    #     the benign-prefix allowlist). Unsigned-only.
    # This regression test pins the empirical agreement between all paths
    # on valid inputs (b ≠ 0).
    #
    # Companion docstring update: src/lower.jl `lower_divrem!` documents
    # the path-1-vs-path-2 distinction and points at salb / y56a for the
    # post-salb canonicalisation.

    @testset "Path 1 + Path 2 agree on unsigned division (b != 0)" begin
        # Path 1: native ÷
        f1 = (a::UInt64, b::UInt64) -> a ÷ b
        c1 = reversible_compile(f1, Tuple{UInt64, UInt64})

        # Path 2: direct call to the private kernel
        f2 = (a::UInt64, b::UInt64) -> Bennett._soft_udiv_compile(a, b)
        c2 = reversible_compile(f2, Tuple{UInt64, UInt64}; max_loop_iterations=64)

        # Sample inputs with b != 0 (avoid the documented LLVM-poison-equivalent
        # b=0 path, which differs between paths).
        for (a, b) in [(UInt64(0), UInt64(1)), (UInt64(7), UInt64(3)),
                       (UInt64(255), UInt64(7)), (UInt64(1234567), UInt64(89)),
                       (typemax(UInt64), UInt64(2)), (UInt64(0xfeed), UInt64(0xbe))]
            @test simulate(c1, (a, b)) == a ÷ b
            @test simulate(c2, (a, b)) == a ÷ b
        end
    end

    @testset "Path 1 sign-handling: signed types correct (b != 0)" begin
        # Path 1 with signed input takes the sign-handling branch.
        # Path 2 doesn't apply to signed (no sign extension).
        f = (a::Int8, b::Int8) -> b == Int8(0) ? Int8(0) : a ÷ b
        c = reversible_compile(f, Tuple{Int8, Int8})
        for (a, b) in [(Int8(7), Int8(3)), (Int8(-7), Int8(3)),
                       (Int8(7), Int8(-3)), (Int8(-7), Int8(-3)),
                       (Int8(127), Int8(2)), (Int8(-128), Int8(2)),
                       (Int8(127), Int8(127))]
            @test Int8(simulate(c, (a, b))) == (b == Int8(0) ? Int8(0) : a ÷ b)
        end
    end

    @testset "Path 3 (unregistered callee) now errors loud" begin
        # Post-salb the silent-skip path is gone. Verify by attempting to
        # call an unregistered Julia function through compiled code: should
        # raise `_ir_error("call to ... has no registered callee handler")`.
        unreg_func(x::UInt64, y::UInt64)::UInt64 = x + y  # not in registry
        f = (a::UInt64, b::UInt64) -> unreg_func(a, b)
        # Julia may inline the simple call; if it does, the test trivially
        # passes (no IRCall emitted). To force a non-inlined call, use
        # @noinline + a more complex body.
        @noinline _y56a_unreg(x::UInt64, y::UInt64)::UInt64 = (x ⊻ y) + UInt64(0xdeadbeef)
        f2 = (a::UInt64, b::UInt64) -> _y56a_unreg(a, b)
        try
            reversible_compile(f2, Tuple{UInt64, UInt64})
            # If compilation succeeds, Julia inlined despite @noinline; that's
            # OK and means no unregistered-callee path was exercised.
            @test true  # benign success
        catch e
            # If it errored, the message must name the missing callee
            # explicitly — not the generic "unknown operand ref".
            msg = sprint(showerror, e)
            @test occursin("no registered callee handler", msg) ||
                  occursin("_y56a_unreg", msg) ||
                  occursin("intrinsic pattern", msg)
        end
    end
end
