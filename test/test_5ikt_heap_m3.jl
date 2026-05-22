# Bennett-5ikt / M3 — Julia heap-memory support, Milestone 3.
#
# M3 makes a `push!`-built `Vector{T}` with a STATICALLY-INFERABLE element
# count compile under `mem=:heap`. M1 handled the wholly-dead heap collection;
# M2 handled `Array{T}(undef,N)` whose element data is live. M3 is the
# remaining case: `Int8[]` grown by `push!` — there is NO constant-N Memory
# length store (the empty literal allocates Julia's shared empty-Memory global,
# capacity 0) and NO Memory `gc_small_alloc` (only the 32-byte Array WRAPPER is
# heap-allocated). The capacity-check `growend!` diamonds are dead skeleton; the
# element count is inferred from the constant element-store offset set.
#
# Reference fixture (T5 corpus TJ1): three pushes + `reduce(+, v)` → 3x+3.
#
# CLAUDE.md §1 (FAIL LOUD — a wrong "dead" judgement feeding the return is the
# worst possible bug), §3 (red-green TDD), §4 (every test pairs
# verify_reversibility with an output-vs-oracle sweep).

using Test
using Bennett
using LLVM

# ---------------------------------------------------------------------------
# M3 happy-path reference functions.
# ---------------------------------------------------------------------------

# TJ1: push×3 + reduce(+,v). Oracle: x + (x+1) + (x+2) = 3x+3 (mod 256).
f_tj1(x::Int8) = let v = Int8[]
    push!(v, x)
    push!(v, x + Int8(1))
    push!(v, x + Int8(2))
    reduce(+, v)
end

# Two-push variant: x + (x+1) = 2x+1 (mod 256).
f_tj1_2push(x::Int8) = let v = Int8[]
    push!(v, x)
    push!(v, x + Int8(1))
    reduce(+, v)
end

# Heap vector escapes into a non-inlined callee — the array pointer flows into
# `@j_*sink*`, a non-allowlisted heap callee. M3 MUST reject loud.
@noinline _m3_sink(v::Vector{Int8}) = length(v)
_m3_escape(x::Int8) = let v = Int8[]
    push!(v, x)
    push!(v, x + Int8(1))
    Int8(_m3_sink(v)) + reduce(+, v)
end

const _M3_FIX = joinpath(@__DIR__, "fixtures")

# Compile a hand-written .ll fixture under mem=:heap (reject-case driver).
function _m3_compile_ll(name::AbstractString)
    ir = read(joinpath(_M3_FIX, name), String)
    LLVM.Context() do _ctx
        mod = parse(LLVM.Module, ir)
        parsed = Bennett._module_to_parsed_ir(mod; mem=:heap)
        lr = Bennett.lower(parsed)
        Bennett.bennett(lr)
    end
end

# Run `thunk`, assert it throws, and PIN the failure reason — a bare
# `@test_throws ErrorException` passes even when the case rejects for an
# UNINTENDED reason, masking a future regression (orchestrator review,
# Bennett-5ikt). `substr` must appear in the thrown message.
function _m3_assert_rejects(thunk, substr::AbstractString)
    threw = false
    msg = ""
    try
        thunk()
    catch e
        threw = true
        msg = sprint(showerror, e)
    end
    @test threw
    @test occursin(substr, msg)
    return msg
end

@testset "Bennett-5ikt / M3 — push!-built Vector, static count" begin

    # Bennett-2mj3: the happy-path subjects are driven off PRE-CAPTURED .ll
    # fixtures, not `code_llvm`'d in-suite. `Pkg.test()` runs `--check-bounds=
    # yes`, which forces every `@boundscheck` ON — the heap functions' IR then
    # carries an `@ijl_bounds_error_int` call the recogniser (correctly, FAIL-
    # LOUD) rejects, so they cannot be compiled from source inside the suite.
    # heap_m3_tj1.ll / heap_m3_tj1_2push.ll were captured under DEFAULT check-
    # bounds (the IR shape the recogniser was designed for) by
    # `scripts/gen_heap_fixtures.jl`. The oracle sweeps below are unchanged.
    @testset "f_tj1 — push×3 + reduce, oracle 3x+3 (.ll fixture)" begin
        c = _m3_compile_ll("heap_m3_tj1.ll")
        @test verify_reversibility(c)
        for x in Int8(-128):Int8(127)
            @test simulate(c, x) == f_tj1(x)   # oracle: 3x+3 (mod 256)
        end
    end

    @testset "f_tj1_2push — push×2 + reduce, oracle 2x+1 (.ll fixture)" begin
        c = _m3_compile_ll("heap_m3_tj1_2push.ll")
        @test verify_reversibility(c)
        for x in Int8(-128):Int8(127)
            @test simulate(c, x) == f_tj1_2push(x)   # oracle: 2x+1 (mod 256)
        end
    end

    # Bennett-2mj3: the three source-driven reject cases below are driven off
    # PRE-CAPTURED .ll fixtures. Under `Pkg.test()`'s `--check-bounds=yes`,
    # `code_llvm`'ing these from source injects an `@ijl_bounds_error_int`
    # call, so the recogniser rejects on that BOUNDS reason instead of the
    # intended one — making the pinned substring non-deterministic. Driving
    # off fixtures captured under DEFAULT check-bounds (by
    # `scripts/gen_heap_fixtures.jl`) makes the reject reason stable. The
    # Julia reference functions are kept above for documentation/provenance.
    @testset "reject — runtime-count push! in a loop (.ll fixture)" begin
        # heap_reject_floop.ll = `for k in 1:x; push!(v,k)`. The heap alloc /
        # growend! sit on a loop body; the back-edge guard (Bennett-gps7 / M1)
        # rejects loud before any M3 logic. Message pinned so a future M3
        # change cannot silently reroute this through a different reject.
        _m3_assert_rejects(() -> _m3_compile_ll("heap_reject_floop.ll"),
                           "back-edge")
    end

    @testset "reject — push! inside a runtime if (.ll fixture)" begin
        # heap_reject_fif.ll = a real user `if` guarding a push! → a surviving
        # non-growend, non-bounds conditional branch. It rejects EARLY, via
        # the M2 helper `_collapse_bounds_diamond` ("not a bounds-check
        # diamond ... general control flow is out of M2 scope") — NOT via
        # M3's G1. G1 diamond-completeness is a valid backstop for this class,
        # but it is unreachable here because the M2 bounds-diamond collapse
        # runs first and already rejects the surviving user branch.
        _m3_assert_rejects(() -> _m3_compile_ll("heap_reject_fif.ll"),
                           "not a bounds-check diamond")
    end

    @testset "reject — escaping vector whose reduce loops (.ll fixture)" begin
        # heap_reject_escape.ll = `_m3_escape`: the vector is passed to a
        # non-inlined callee `_m3_sink`. The escape forces `reduce` to lower
        # as a runtime loop, so the FIRST obligation hit is the M1 back-edge
        # guard — NOT the M3 G2 pointer-family no-escape obligation. (G2
        # itself is currently unreachable: M2-O5's escape check already covers
        # the whole `data_roots` family that G2 re-scans — see the session
        # log / orchestrator review for Bennett-5ikt M3.)
        _m3_assert_rejects(() -> _m3_compile_ll("heap_reject_escape.ll"),
                           "back-edge")
    end

    @testset "reject — non-contiguous element-store offsets (.ll)" begin
        _m3_assert_rejects(() -> _m3_compile_ll("heap_m3_gap.ll"),
                           "contiguous")
    end

    @testset "reject — impure growend! slow arm (.ll)" begin
        _m3_assert_rejects(() -> _m3_compile_ll("heap_m3_impure_slow.ll"),
                           "SLOW arm")
    end

    @testset "reject — growend!-count ≠ element-store-count (.ll)" begin
        _m3_assert_rejects(() -> _m3_compile_ll("heap_m3_count_mismatch.ll"),
                           "G4:")
    end

    @testset "reject — element-buffer pointer escapes into a callee (M2-O5)" begin
        # heap_m3_escape.ll is the otherwise-valid f_tj1 push×3 IR (un-gapped
        # sibling of heap_m3_gap.ll) with ONE added edit: a non-allowlisted
        # `call void @some_sink(ptr %memory_data)` — `%memory_data` is a
        # `data_roots` buffer-base member. No loop / no back-edge, so it
        # reaches the M3 soundness proof. `_prove_growend_partition_sound`
        # runs M2 O1-O7 first, and M2-O5 — generalised by the M3 step-1
        # `data_roots` refactor to the whole buffer-base family — rejects the
        # escape. There is no separate M3 escape obligation (the old G2 was
        # verified-dead and removed; M2-O5 subsumes it — hence the proof's
        # G1->G3 label gap). This is the genuine M3-path coverage for a
        # `data_roots`-family escape, distinct from M2's single-`data_ptr`
        # shape and from the back-edge `_m3_escape` live-function case below.
        msg = _m3_assert_rejects(() -> _m3_compile_ll("heap_m3_escape.ll"),
                                 "M2-O5")
        @test occursin("escapes", msg)
    end

end
