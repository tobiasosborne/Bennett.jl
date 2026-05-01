using LLVM

# Bennett-4eu: indirectbr is a Bennett hard stop. The static-CFG model
# that Bennett's phi resolution + loop unrolling + Bennett construction
# depend on requires compile-time-known branch targets. `indirectbr`
# defers target resolution to runtime via a block-address pointer.
# Same philosophical category as atomicrmw / invoke / landingpad —
# fail-loud with a precise message rather than attempt a partial
# implementation that would silently misbehave on the patterns we don't
# handle.

@testset "Bennett-4eu: indirectbr fails loud (hard stop)" begin

    @testset "indirectbr in .ll fixture rejected with precise message" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "4eu_indirectbr_reject.ll")
        # The error fires from the lowering pipeline (extract walks the
        # IR; lowering converts each instruction). Confirm the error
        # mentions Bennett-4eu so a reader can find this design note.
        try
            Bennett.extract_parsed_ir_from_ll(path; entry_function="julia_f_1")
            @test false  # should have thrown
        catch e
            msg = sprint(showerror, e)
            @test occursin("indirectbr", msg)
            @test occursin("Bennett-4eu", msg)
        end
    end

end
