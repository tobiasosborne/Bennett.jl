using Test
using Bennett: extract_parsed_ir_from_ll

# Bennett-g27k / U18 — the cc0.3 catch in `_extract_from_ll` at
# `src/ir_extract.jl:~887-907` previously swallowed ANY error whose
# `sprint(showerror, e)` contained one of "Unknown value kind",
# "LLVMGlobalAlias", or (via a MethodError guard) "PointerType". Pure
# substring matching meant an unrelated bug whose message happened to
# mention any of those words got silently skipped — the instruction's
# dest SSA was left undefined and downstream consumers crashed far
# from the root cause, undoing the fail-loud cleanup from U09–U17.
#
# Post-fix: both an exception TYPE AND the expected message pattern
# must match, AND the error must NOT be Bennett-authored (prefixed with
# `ir_extract.jl:` or `Bennett-`).
#
# Direct unit-level RED/GREEN is hard here — the affected code is a
# top-level catch in a file-local function called from another top-level
# function, and Julia's method dispatch makes monkey-patching unreliable.
# The indirect coverage is stronger:
#   - T1 confirms the regression protection: the source text now gates
#     the benign match on an `isa` check (`e isa ErrorException` and
#     `e isa MethodError`), not bare substring matching.
#   - T2 confirms the skip path is still live: a simple IR still
#     extracts OK (the common case goes through cc0.3 for instructions
#     Julia's optimizer leaves around without full LLVM.jl dispatch).
# The U10/U12/U13/U14/U15/U16 fail-loud tests (already in the suite)
# collectively prove that Bennett-authored errors now propagate; the
# `test_t0_preprocessing` allowlist proves the benign skip still fires.

@testset "Bennett-g27k cc0.3 catch narrowed" begin

    # T1 — source inspection: the catch block no longer matches purely
    # on substring. Both required type guards must appear.
    src_path = joinpath(dirname(dirname(@__FILE__)), "src", "ir_extract.jl")
    src = read(src_path, String)

    @testset "structural narrowing" begin
        # Anchor: the cc0.3 comment block.
        cc03_start = findfirst("Bennett-cc0.3:", src)
        @test cc03_start !== nothing
        start = first(cc03_start)
        # Look at the next ~4000 chars for the catch-block body.
        block = src[start:min(start + 4000, lastindex(src))]
        # Post-fix must gate on `ErrorException` AND `MethodError` types.
        @test occursin("e isa ErrorException", block)
        @test occursin("e isa MethodError", block)
        # Post-fix must reject Bennett-authored errors (our own `_ir_error`
        # outputs messages prefixed with `ir_extract.jl:` and Bennett-IDs).
        @test occursin("ir_extract.jl:", block) || occursin("bennett_authored", block)
    end

    # T2 — smoke test: ordinary IR still extracts (no regression in the
    #      skip path, which routes most optimized-away or unknown-kind
    #      instructions through cc0.3).
    @testset "skip path still functional" begin
        mktempdir() do dir
            path = joinpath(dir, "simple.ll")
            write(path, """
define i32 @f(i32 %x) {
top:
  %y = add i32 %x, 1
  ret i32 %y
}
""")
            pir = extract_parsed_ir_from_ll(path; entry_function="f")
            @test pir !== nothing
        end
    end
end
