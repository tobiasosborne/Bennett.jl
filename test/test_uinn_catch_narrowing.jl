# Bennett-uinn / U93 — every defensive `try/catch` in src/ir_extract.jl
# was bare (`catch` with no exception variable, falling back to nothing
# or "<unknown>"). That swallowed `InterruptException` too: a Ctrl-C
# during compilation could be eaten by the same handler that's meant
# to defend against LLVM-introspection failures.
#
# The fix is the standard Julia pattern at every site:
#
#     catch e
#         e isa InterruptException && rethrow()
#         <existing fallback>
#     end
#
# These tests pin the invariant by static inspection of the source
# file: every `catch` line is followed within ≤2 lines by either an
# `InterruptException` rethrow OR an `isa InterruptException` check.
# (Some catches use a typed `catch e` already and need no narrowing —
# they're allowed via the `catch e` regex matching the fixed forms.)

using Test
using Bennett

@testset "Bennett-uinn / U93 — ir_extract.jl catch sites narrowed" begin

    # Bennett-x3jc / U116 (2026-04-30): ir_extract.jl was split into
    # src/extract/*.jl. Scan every file in that directory; the bead's
    # invariant ("every defensive catch carries an InterruptException
    # guard within 3 lines") is per-catch, so we report offenders with
    # their containing file + line.
    extract_dir = joinpath(dirname(pathof(Bennett)), "extract")
    files = sort!(filter(f -> endswith(f, ".jl"), readdir(extract_dir)))
    @test !isempty(files)  # split survived

    total_catches = 0
    bare_offenders = Tuple{String, Int, String}[]
    for fname in files
        src = read(joinpath(extract_dir, fname), String)
        lines = split(src, '\n')

        # Find every line that introduces a catch clause. Excludes comments
        # mentioning "catch" (`# try/catch because ...`) by requiring the
        # `catch` keyword to be at the start of trimmed text or follow
        # whitespace, with no `#` before it on the same line.
        for (i, line) in enumerate(lines)
            stripped = strip(line)
            # Skip pure comment lines
            startswith(stripped, "#") && continue
            # Strip inline comments
            hash_idx = findfirst('#', line)
            code = hash_idx === nothing ? line : line[1:hash_idx-1]
            m = match(r"(^|[^A-Za-z_])catch(\s|$)", code)
            m === nothing && continue
            total_catches += 1
            window = join(lines[i:min(i+3, end)], "\n")
            if !occursin("InterruptException", window)
                push!(bare_offenders, (fname, i, String(strip(line))))
            end
        end
    end

    @test total_catches > 0  # sanity: some file in extract/ has catches
    @test isempty(bare_offenders)
    if !isempty(bare_offenders)
        for (fname, ln, txt) in bare_offenders
            @info "extract/$fname line $ln has a catch without an InterruptException guard within 3 lines: $(txt)"
        end
    end
end
