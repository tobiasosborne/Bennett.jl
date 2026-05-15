using Test
using Bennett

const KH6N_LL = joinpath(@__DIR__, "fixtures", "ll")

function kh6n_reject(file::AbstractString, entry::AbstractString)
    err = try
        Bennett.extract_parsed_ir_from_ll(joinpath(KH6N_LL, file);
                                          entry_function=entry)
        nothing
    catch e
        sprint(showerror, e)
    end
    return err
end

@testset "Bennett-kh6n: trailing-. prefix discipline (scalar intrinsics)" begin
    # Each of the four fixtures targets a *silent* miscompile: the
    # current scalar prefix matchers in src/extract/instructions.jl lack
    # trailing-`.` and so swallow LLVM intrinsic siblings (minimumnum
    # under minimum, maximumnum under maximum, roundeven under round)
    # and dispatch them to the wrong gates. After the kh6n fix the call
    # must produce a clear _ir_error mentioning the offending intrinsic.

    @testset "llvm.minimumnum.f64 not swallowed by llvm.minimum" begin
        err = kh6n_reject("kh6n_minimumnum_f64_reject.ll",
                          "kh6n_minimumnum_f64")
        @test err !== nothing
        @test occursin("llvm.minimumnum", err)
    end

    @testset "llvm.maximumnum.f64 not swallowed by llvm.maximum" begin
        err = kh6n_reject("kh6n_maximumnum_f64_reject.ll",
                          "kh6n_maximumnum_f64")
        @test err !== nothing
        @test occursin("llvm.maximumnum", err)
    end

    @testset "llvm.roundeven.f64 not swallowed by llvm.round" begin
        err = kh6n_reject("kh6n_roundeven_f64_reject.ll",
                          "kh6n_roundeven_f64")
        @test err !== nothing
        @test occursin("llvm.roundeven", err)
    end

    # Bennett-k2w6 superseded the kh6n float-rejects for llvm.minimum.f64
    # and llvm.minnum.f64 with native soft_fminimum / soft_fmin dispatch.
    # The reject fixtures are kept at test/fixtures/ll/kh6n_minimum_f64_reject.ll
    # and test/fixtures/ll/kh6n_minnum_f64_reject.ll for git-history clarity
    # but no longer test rejection — coverage moved to test_k2w6_soft_fminmax.jl.

    # Source-property test: every `startswith(cname, "llvm.<x>")` in
    # src/extract/instructions.jl must end with a trailing `.` to prevent
    # silent swallow of sibling intrinsics. The single intentional
    # exception is `llvm.assume`, which is a complete intrinsic name with
    # no `.<type>` suffix variants.
    @testset "source-property: trailing-. on every llvm.* prefix" begin
        path = joinpath(@__DIR__, "..", "src", "extract", "instructions.jl")
        text = read(path, String)
        # Match: startswith(cname, "llvm.<token>") — but only when the
        # first arg is an identifier, not a string literal (which would
        # be a doc-comment example illustrating the bad-vs-good case).
        rx = r"""startswith\(\s*[A-Za-z_][A-Za-z0-9_]*\s*,\s*\"(llvm\.[A-Za-z0-9._]+)\""""
        bad = String[]
        allowed_no_dot = Set([
            "llvm.assume",
            "llvm.experimental.noalias.scope.decl",
            "llvm.invariant.start",
            "llvm.invariant.end",
            "llvm.sideeffect",
        ])
        for m in eachmatch(rx, text)
            tok = m.captures[1]
            endswith(tok, ".") && continue
            tok in allowed_no_dot && continue
            push!(bad, tok)
        end
        @test isempty(bad)
        if !isempty(bad)
            @info "Untightened llvm prefixes in instructions.jl" bad
        end
    end
end
