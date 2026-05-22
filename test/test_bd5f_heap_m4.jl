# Bennett-bd5f / M4 — Julia heap-memory support, Milestone 4.
#
# M4 is the LAST gf3n milestone: fail-loud scope hardening. It adds NO
# extraction / partition / lowering logic — it is purely a set of PRECISE,
# signpost rejects placed ahead of the generic recognition rejects, so a
# user/agent who hits a scope wall is told exactly WHAT is unsupported and
# WHERE to look. Every case below ALREADY rejected loud pre-M4 (correctness
# was fine); M4 only sharpens the message.
#
# CLAUDE.md §1 (FAIL LOUD — a clear actionable message), §3 (red-green TDD),
# §4 (every reject test PINS the message substring so a future change cannot
# silently reroute the case through a different/wrong reject).
#
# This file mirrors test_5ikt_heap_m3.jl's idiom — see `_m4_assert_rejects`.

using Test
using Bennett
using LLVM

const _M4_FIX = joinpath(@__DIR__, "fixtures")

# Compile a hand-written .ll fixture under mem=:heap (reject-case driver).
# Same idiom as `_m3_compile_ll` in test_5ikt_heap_m3.jl.
function _m4_compile_ll(name::AbstractString)
    ir = read(joinpath(_M4_FIX, name), String)
    LLVM.Context() do _ctx
        mod = parse(LLVM.Module, ir)
        parsed = Bennett._module_to_parsed_ir(mod; mem=:heap)
        lr = Bennett.lower(parsed)
        Bennett.bennett(lr)
    end
end

# Run `thunk`, assert it threw, and PIN the failure reason. A bare
# `@test_throws ErrorException` passes even when the case rejects for an
# UNINTENDED reason, masking a future regression. `substr` must appear in the
# thrown message. Mirrors `_m3_assert_rejects` (test_5ikt_heap_m3.jl).
function _m4_assert_rejects(thunk, substr::AbstractString)
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

@testset "Bennett-bd5f / M4 — fail-loud scope hardening" begin

    @testset "reject — Dict (irreversible hash-table mutation)" begin
        # `d[k] = v` on a Julia Dict. The recogniser's entry function carries
        # a `@j_setindex!_NNN` callee plus three `@ijl_gc_small_alloc` calls.
        # Pre-M4 the generic ≥3-alloc count guard rejected this with a message
        # that said nothing about Dict; M4's scope guard runs first and names
        # Dict precisely + points at the Bennett-800b research workstream.
        fdict(k::Int8, v::Int8) = let d = Dict{Int8,Int8}()
            d[k] = v
            d[k]
        end
        msg = _m4_assert_rejects(
            () -> reversible_compile(fdict, Tuple{Int8,Int8}; mem=:heap),
            "Dict")
        @test occursin("Bennett-800b", msg)
    end

    @testset "reject — mid-array insert!" begin
        # `insert!(v, i, x)` lowers through Julia's `_growat!` — the
        # recogniser sees a `@j__growat!_NNN` callee. Pre-M4 this rejected via
        # the generic M2-O5 escape obligation; M4 names insert!/`_growat!`.
        finsert(x::Int8) = let v = Int8[x]
            insert!(v, 1, x)
            v[1]
        end
        _m4_assert_rejects(
            () -> reversible_compile(finsert, Int8; mem=:heap),
            "insert!")
    end

    @testset "reject — mid-array deleteat!" begin
        # `deleteat!(v, i)` lowers through Julia's `_deleteat!` — the
        # recogniser sees a `@j__deleteat!_NNN` callee. Pre-M4 this rejected
        # via the generic M2-O3 obligation; M4 names deleteat!/`_deleteat!`.
        fdel(x::Int8) = let v = Int8[x, x]
            deleteat!(v, 1)
            v[1]
        end
        _m4_assert_rejects(
            () -> reversible_compile(fdel, Int8; mem=:heap),
            "deleteat!")
    end

    @testset "reject — C/Rust malloc (.ll fixture)" begin
        # heap_m4_malloc.ll is a hand-written C-style function that allocates
        # via `@malloc` with NO `@ijl_gc_small_alloc` present. The M4 scope
        # guard rejects: the recogniser models ONLY the Julia GC allocator.
        # (A live C function is not compilable from Julia source — hence the
        # .ll fixture, same idiom as the heap_m3_*.ll fixtures.)
        _m4_assert_rejects(() -> _m4_compile_ll("heap_m4_malloc.ll"),
                           "malloc")
    end

    @testset "reject — runtime-N Array{T}(undef,n)" begin
        # `Array{Int8}(undef, n)` with a RUNTIME `n`: the `undef` constructor
        # emits a memory-init loop, so the heap allocation sits on a loop
        # body. The M1 back-edge guard rejects it loud — and (Bennett-bd5f /
        # M4) the back-edge message was sharpened to name the runtime-N
        # `Array{T}(undef,n)` case explicitly as a likely cause.
        #
        # NOTE: `_infer_capacity`'s own "runtime-N out of M2 scope" reject is
        # only reachable from a hand-written .ll fixture (an already-recognised
        # heap array with a non-constant length store) — from Julia SOURCE the
        # back-edge guard always fires first. The test pins "back-edge", the
        # message a real user actually sees.
        frtN(n::Int8) = let v = Array{Int8}(undef, n)
            v[1] = Int8(7)
            v[1]
        end
        _m4_assert_rejects(
            () -> reversible_compile(frtN, Int8; mem=:heap),
            "back-edge")
    end

    @testset "reject — runtime-loop push! (.ll fixture)" begin
        # `for k in 1:x; push!(v,k)` — the heap alloc / growend! sit on a loop
        # body. The back-edge guard rejects loud (also covered by M3's
        # test_5ikt_heap_m3.jl; pinned here against the sharpened message).
        #
        # Bennett-2mj3: driven off heap_reject_floop.ll (shared with
        # test_5ikt_heap_m3.jl). `Pkg.test()` runs `--check-bounds=yes`, which
        # makes `code_llvm`'ing `floop` from source inject an
        # `@ijl_bounds_error_int` call — the recogniser then rejects on that
        # bounds reason, NOT the intended back-edge. The fixture (captured
        # under DEFAULT check-bounds by `scripts/gen_heap_fixtures.jl`) makes
        # the reject reason deterministic.
        _m4_assert_rejects(
            () -> _m4_compile_ll("heap_reject_floop.ll"),
            "back-edge")
    end

end
