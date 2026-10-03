using Test
using Bennett
using Bennett: register_callee!, extract_parsed_ir, IRCall

# Bennett-p9a0 — the known-callee registry is keyed by the BARE function name
# (`string(nameof(f))`), and the LLVM symbol `j_<name>_<NNN>` carries no module.
# So with `P9a0B.same` registered, a call to the unrelated `P9a0A.same` resolved
# to `P9a0B.same` and its body was inlined: 256/256 Int8 outputs wrong,
# `verify_reversibility` still true. And registering both silently overwrote
# the first. Fix: a Julia-function extraction checks the registered callee
# against the root's typed `:invoke` edges (module identity), and
# `register_callee!` rejects a different function under an already-registered
# bare name.

module P9a0A
    Base.@noinline same(x::Int8) = x + Int8(1)
end
module P9a0B
    Base.@noinline same(x::Int8) = x + Int8(2)
end

p9a0_callA(x::Int8) = P9a0A.same(x)
p9a0_callB(x::Int8) = P9a0B.same(x) + Int8(3)
p9a0_callBoth(x::Int8) = P9a0A.same(x) + P9a0B.same(x)

_p9a0_calls(pir) = [i.callee for b in pir.blocks for i in b.instructions if i isa IRCall]

# Run `body` with the registry restored afterwards (Rule 7 — no leak), and with
# the extraction / compile caches emptied on both sides: a registry change does
# not move the world, so the Bennett-4ddk world gate cannot see it.
function _p9a0_with_registry(body)
    before = lock(() -> copy(Bennett._known_callees), Bennett._known_callees_lock)
    Bennett._clear_parsed_ir_cache!(); Bennett._clear_compile_cache!()
    try
        body()
    finally
        lock(Bennett._known_callees_lock) do
            empty!(Bennett._known_callees)
            merge!(Bennett._known_callees, before)
        end
        Bennett._clear_parsed_ir_cache!(); Bennett._clear_compile_cache!()
    end
end

function _p9a0_exhaustive(f)
    c = reversible_compile(f, Int8)
    bad = [x for x in typemin(Int8):typemax(Int8) if simulate(c, x) != f(x)]
    isempty(bad) || @info "Bennett-p9a0 mismatches" f first(bad, 5)
    @test isempty(bad)
    @test verify_reversibility(c)
end

@testset "Bennett-p9a0: callee resolution respects module identity" begin
    @testset "only P9a0B.same registered" begin
        _p9a0_with_registry() do
            register_callee!(P9a0B.same)
            # The call to the UNREGISTERED namesake must not bind P9a0B.same.
            @test_throws r"Bennett-p9a0" extract_parsed_ir(p9a0_callA, Tuple{Int8})
            @test_throws r"Bennett-p9a0" reversible_compile(p9a0_callA, Int8)
            # Two same-named callees in one root: rejected, never guessed.
            @test_throws r"Bennett-p9a0" extract_parsed_ir(p9a0_callBoth, Tuple{Int8})
            # The registered one still resolves to its own body.
            @test _p9a0_calls(extract_parsed_ir(p9a0_callB, Tuple{Int8})) == [P9a0B.same]
            _p9a0_exhaustive(p9a0_callB)
        end
    end

    @testset "only P9a0A.same registered" begin
        _p9a0_with_registry() do
            register_callee!(P9a0A.same)
            @test_throws r"Bennett-p9a0" extract_parsed_ir(p9a0_callB, Tuple{Int8})
            @test _p9a0_calls(extract_parsed_ir(p9a0_callA, Tuple{Int8})) == [P9a0A.same]
            _p9a0_exhaustive(p9a0_callA)
        end
    end

    @testset "registering a second same-named function fails loud ($first_ then $second_)" for
            (first_, second_) in ((P9a0A.same, P9a0B.same), (P9a0B.same, P9a0A.same))
        _p9a0_with_registry() do
            register_callee!(first_)
            @test_throws r"Bennett-p9a0" register_callee!(second_)
            # Nothing was overwritten; re-registering the same function is idempotent.
            @test Bennett._known_callees["same"] === first_
            register_callee!(first_)
            @test Bennett._known_callees["same"] === first_
            _p9a0_exhaustive(first_ === P9a0A.same ? p9a0_callA : p9a0_callB)
        end
    end
end
