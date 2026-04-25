# Bennett-8kno / U95 — `_extract_const_globals` used to bare-catch
# around `LLVM.initializer(g)`. The comment at the call site
# explained the catch defends against LLVM.jl errors for unknown
# value kinds (e.g. LLVMGlobalAlias), but the bare form swallowed
# OutOfMemoryError, StackOverflowError, MethodError, etc. as well.
#
# Bennett-uinn / U93 (chunk 040) added the InterruptException re-raise.
# This bead extends it: only swallow the LLVM.jl-specific
# `ErrorException` whose message names "Unknown value kind" or
# "LLVMGlobalAlias"; rethrow anything else.
#
# Static inspection test — ensures the narrowing pattern is present at
# the `_extract_const_globals` site.  An end-to-end OOM test isn't
# feasible without faking the allocator, but the static check is the
# load-bearing invariant: a future agent removing the benign-check
# clause would silently re-introduce the bug.

using Test
using Bennett

@testset "Bennett-8kno / U95 — _extract_const_globals catch narrowing" begin

    src_path = joinpath(dirname(pathof(Bennett)), "ir_extract.jl")
    src = read(src_path, String)
    lines = split(src, '\n')

    # Find the line that begins `_extract_const_globals`.
    fn_line_idx = findfirst(l -> occursin("function _extract_const_globals", l),
                            lines)
    @test fn_line_idx !== nothing

    # Slice the function body — up to the next top-level `function` or end-of-file.
    end_idx = findnext(l -> startswith(l, "function ") || startswith(l, "# ----"),
                      lines, fn_line_idx + 1)
    body = join(lines[fn_line_idx:something(end_idx, length(lines))], "\n")

    @testset "InterruptException is rethrown" begin
        @test occursin("InterruptException", body)
        @test occursin("rethrow()", body)
    end

    @testset "benign LLVM.jl errors are narrowed" begin
        # Both characteristic substrings of the LLVM.jl error must
        # appear: "Unknown value kind" (initializer of unknown kind)
        # and "LLVMGlobalAlias" (the most common offender).
        @test occursin("Unknown value kind", body)
        @test occursin("LLVMGlobalAlias", body)
    end

    @testset "non-benign errors propagate" begin
        # The conditional rethrow that propagates OOM/etc.  Look for
        # `benign ? nothing : rethrow()` or equivalent.
        @test occursin(r"benign\s*\?\s*nothing\s*:\s*rethrow\(\)", body)
    end

    @testset "end-to-end: real compile still extracts globals" begin
        # If the new narrowing accidentally rejected a benign LLVM.jl
        # error that's actually fired during normal compilation, every
        # downstream test would fail. Pin the canonical baseline.
        c = reversible_compile(x -> x + Int8(1), Int8)
        @test gate_count(c).total == 58
        @test verify_reversibility(c)
    end
end
