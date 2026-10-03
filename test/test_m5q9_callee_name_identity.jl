using Test
using Bennett
using Bennett: register_callee_name!, extract_parsed_ir, IRCall

# Bennett-m5q9 — the NAME registry for instance-less callees (closures /
# functors, Bennett-40ys) had none of the Bennett-p9a0 module-identity
# protection. `register_callee_name!(bare, canonical)` stored no identity at
# all, so with `Fm5q9` registered (meant for `M5q9B.Fm5q9`), a `ptr_cells=true`
# extraction of a root calling the unrelated `M5q9A.Fm5q9` silently emitted
# `IRCall(:Fm5q9)` — a call a consumer would bind to the registered callee's
# body. Fix: registration carries the callable's type (identity = its
# `TypeName`, shared by every specialisation and call method, all of which
# mangle to the same bare name); a demangled hit under a Julia root is checked
# against the root's `:invoke` edges by the same helper as p9a0; a different
# callable under an already-registered name is rejected.

module M5q9A
    struct Fm5q9
        n::Int64
    end
    @noinline (a::Fm5q9)(x::Int64) = x + a.n * 3
end
module M5q9B
    struct Fm5q9
        n::Int64
    end
    @noinline (a::Fm5q9)(x::Int64) = x - a.n * 7
end

# A parametric functor: two specialisations under one root share one TypeName.
struct Pm5q9{T}
    n::T
end
@noinline (p::Pm5q9)(x::Int64) = x + Int64(p.n)

m5q9_callA(x::Int64) = M5q9A.Fm5q9(x)(x + 1)
m5q9_callB(x::Int64) = M5q9B.Fm5q9(x)(x + 1)
m5q9_callBoth(x::Int64) = M5q9A.Fm5q9(x)(x) + M5q9B.Fm5q9(x)(x)
m5q9_param(x::Int64) = Pm5q9(x)(x) + Pm5q9(x % Int32)(x)

m5q9_inc(x::Int64) = x + 1

_m5q9_calls(pir) = [i.callee for b in pir.blocks for i in b.instructions if i isa IRCall]
_m5q9_cells(f) = extract_parsed_ir(f, Tuple{Int64}; optimize=true, ptr_cells=true)

# Run `body` with the name registry restored afterwards (Rule 7 — no leak).
function _m5q9_with_names(body)
    before = lock(() -> copy(Bennett._known_callee_names), Bennett._known_callees_lock)
    try
        body()
    finally
        lock(Bennett._known_callees_lock) do
            empty!(Bennett._known_callee_names)
            merge!(Bennett._known_callee_names, before)
        end
    end
end

@testset "Bennett-m5q9: name-registered callees respect module identity" begin
    @testset "only M5q9B.Fm5q9 registered" begin
        _m5q9_with_names() do
            register_callee_name!("Fm5q9", :Fm5q9, M5q9B.Fm5q9)
            # The call to the UNREGISTERED namesake must not bind the name.
            @test_throws r"Bennett-m5q9" _m5q9_cells(m5q9_callA)
            # Two same-named callees in one root: rejected, never guessed.
            @test_throws r"Bennett-m5q9" _m5q9_cells(m5q9_callBoth)
            # The registered one still resolves to its bare canonical name.
            @test _m5q9_calls(_m5q9_cells(m5q9_callB)) == [:Fm5q9]
            # Without a Julia root (raw symbol lookup) resolution stays name-only.
            @test Bennett._lookup_callee_name("j_Fm5q9_12") === :Fm5q9
        end
    end

    @testset "only M5q9A.Fm5q9 registered" begin
        _m5q9_with_names() do
            register_callee_name!("Fm5q9", :Fm5q9, M5q9A.Fm5q9)
            @test_throws r"Bennett-m5q9" _m5q9_cells(m5q9_callB)
            @test _m5q9_calls(_m5q9_cells(m5q9_callA)) == [:Fm5q9]
        end
    end

    @testset "specialisations of one callable share its identity" begin
        _m5q9_with_names() do
            register_callee_name!("Pm5q9", :Pm5q9, Pm5q9)
            @test _m5q9_calls(_m5q9_cells(m5q9_param)) == [:Pm5q9, :Pm5q9]
            # A concrete specialisation names the same callable: idempotent.
            register_callee_name!("Pm5q9", :Pm5q9, Pm5q9{Int64})
            @test _m5q9_calls(_m5q9_cells(m5q9_param)) == [:Pm5q9, :Pm5q9]
        end
    end

    @testset "registering a second same-named callable fails loud ($first_ then $second_)" for
            (first_, second_) in ((M5q9A.Fm5q9, M5q9B.Fm5q9), (M5q9B.Fm5q9, M5q9A.Fm5q9))
        _m5q9_with_names() do
            register_callee_name!("Fm5q9", :Fm5q9, first_)
            @test_throws r"Bennett-m5q9" register_callee_name!("Fm5q9", :Fm5q9, second_)
            # Nothing was overwritten; re-registering the same callable is idempotent.
            @test Bennett._known_callee_names["Fm5q9"] == (:Fm5q9, Base.typename(first_))
            register_callee_name!("Fm5q9", :Fm5q9, first_)
            @test Bennett._known_callee_names["Fm5q9"] == (:Fm5q9, Base.typename(first_))
            # Same callable, different canonical Symbol: also a conflict.
            @test_throws r"Bennett-m5q9" register_callee_name!("Fm5q9", :Other, first_)
        end
    end

    @testset "identity is required, and must be instance-less" begin
        _m5q9_with_names() do
            # The identity-free 2-argument form is gone.
            @test_throws MethodError register_callee_name!("Fm5q9", :Fm5q9)
            # A singleton function belongs in `register_callee!`.
            @test_throws r"register_callee!" register_callee_name!("m5q9_inc", :m5q9_inc,
                                                                   typeof(m5q9_inc))
            @test !haskey(Bennett._known_callee_names, "m5q9_inc")
        end
    end

    @testset "closed-world set still binds the call site by bare name" begin
        set = Bennett.extract_parsed_ir_set_from_julia(m5q9_callB, Tuple{Int64};
                                                       ptr_cells=true)
        @test _m5q9_calls(last(first(set))) == [:Fm5q9]
        @test isempty(Bennett._known_callee_names)
    end
end
