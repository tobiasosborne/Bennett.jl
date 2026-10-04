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
# Bennett-omhx (2026-10-04) SUPERSEDES the narrowing: the handler is gone.
# Admission is decided by the initializer's raw value kind (only the four
# materialisable kinds are wrapped), so no exception is caught at all — OOM,
# StackOverflow, MethodError and InterruptException propagate trivially, and
# no decision depends on the text of an error. The static check below pins
# that; test/test_omhx_const_global_alias_init.jl pins the behaviour.

using Test
using Bennett

@testset "Bennett-8kno / U95 — _extract_const_globals catch narrowing" begin

    # Bennett-x3jc / U116 (2026-04-30): ir_extract.jl was split into
    # src/extract/*.jl. `_extract_const_globals` now lives in module_walk.jl.
    src_path = joinpath(dirname(pathof(Bennett)), "extract", "module_walk.jl")
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

    @testset "no exception handling / message matching (Bennett-omhx)" begin
        @test !occursin("catch", body)
        @test !occursin("showerror", body)
        @test !occursin("Unknown value kind", body)
        @test occursin("LLVMGetValueKind", body)
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
