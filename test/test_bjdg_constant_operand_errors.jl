@testset "Bennett-bjdg / U80 — precise errors for constant-operand kinds" begin

    # Pre-bjdg: `_operand` (src/ir_extract.jl:2780-2797) handled
    # ConstantInt, ConstantAggregateZero, and ConstantExpr explicitly,
    # then fell through to a generic "unknown operand ref ... — the
    # producing instruction was skipped or is not yet supported; check
    # the cc0.x gaps in the extractor" error. For ConstantFP /
    # UndefValue / PoisonValue / ConstantPointerNull, this message is
    # MISLEADING — the operand is a *constant*, there is no producing
    # instruction. The user goes hunting for a missing extractor branch
    # that doesn't exist.
    #
    # Post-bjdg: `_operand` recognises these constant kinds explicitly
    # and emits a precise error naming the kind, the value's text form,
    # and the relevant Bennett-side limitation.

    @testset "ConstantFP in scalar operand" begin
        # Trigger: `(a, b) -> a < b ? 1.0 : 0.0` — the literal 0.0
        # appears as a ConstantFP operand of the select instruction.
        f = (a::Float64, b::Float64) -> a < b ? 1.0 : 0.0
        try
            reversible_compile(f, Tuple{Float64, Float64})
            @test false  # should not reach
        catch e
            msg = sprint(showerror, e)
            # New error: name the constant kind explicitly.
            @test occursin("ConstantFP", msg)
            # New error: do NOT say "producing instruction was skipped"
            # (which is the misleading old message).
            @test !occursin("producing instruction was skipped", msg)
        end
    end

    @testset "ConstantFP in another shape (return literal)" begin
        # Multi-arg Float64 that just produces a constant.
        # Note: single-arg Float64 takes a special reversible_compile
        # path that doesn't hit _operand the same way, so use 2-arg.
        f = (a::Float64, b::Float64) -> 1.0
        try
            reversible_compile(f, Tuple{Float64, Float64})
            @test false  # should not reach
        catch e
            msg = sprint(showerror, e)
            # Same precise error class.
            @test occursin("ConstantFP", msg) || occursin("Float", msg)
            @test !occursin("producing instruction was skipped", msg)
        end
    end
end
