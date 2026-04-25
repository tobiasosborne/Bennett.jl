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

    src_path = joinpath(dirname(pathof(Bennett)), "ir_extract.jl")
    src = read(src_path, String)
    lines = split(src, '\n')

    # Find every line that introduces a catch clause. Excludes comments
    # mentioning "catch" (`# try/catch because ...`) by requiring the
    # `catch` keyword to be at the start of trimmed text or follow
    # whitespace, with no `#` before it on the same line.
    catch_starts = Int[]
    for (i, line) in enumerate(lines)
        stripped = strip(line)
        # Skip pure comment lines
        startswith(stripped, "#") && continue
        # Strip inline comments
        hash_idx = findfirst('#', line)
        code = hash_idx === nothing ? line : line[1:hash_idx-1]
        m = match(r"(^|[^A-Za-z_])catch(\s|$)", code)
        m === nothing && continue
        push!(catch_starts, i)
    end

    @test !isempty(catch_starts)  # sanity: file has catches

    # For each catch, confirm the next ≤3 lines either:
    #   (a) include "InterruptException" (the narrowed rethrow guard), OR
    #   (b) the catch itself binds an exception variable AND the next
    #       few lines either rethrow it or contain "InterruptException"
    #       (covers `catch e` with explicit handling), OR
    #   (c) is a `catch e` line where `e` is genuinely re-thrown via
    #       `rethrow()` later (covered by #a since rethrow goes through
    #       InterruptException path) — but those ALSO have the guard,
    #       so #a catches them.
    bare_offenders = Int[]
    for ci in catch_starts
        # Inspect this line + the next 3
        window = join(lines[ci:min(ci+3, end)], "\n")
        if !occursin("InterruptException", window)
            # Allow `catch e` where the body just rethrows or otherwise
            # propagates — but the bead's invariant is specifically about
            # InterruptException, so any catch without that mention is a
            # potential offender.
            push!(bare_offenders, ci)
        end
    end

    @test isempty(bare_offenders)
    if !isempty(bare_offenders)
        for ln in bare_offenders
            @info "ir_extract.jl line $ln has a catch without an InterruptException guard within 3 lines: $(strip(lines[ln]))"
        end
    end
end
