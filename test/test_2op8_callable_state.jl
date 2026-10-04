# Bennett-2op8 (+ Bennett-gft0): a callable's state is bound or rejected by ONE
# rule, whatever kind of callable holds it. Before, only compiler-generated
# closures (type names starting with `#`) bound their captures (Bennett-o9sv);
# a callable struct or `Base.Fix1` / `Base.Fix2` compiled its fields as hidden
# extra circuit inputs on the expression path (`Base.Fix2(-, k)` -> input
# widths [8, 8]) while `:tabulate` evaluated `f` natively and so bound them
# ([8]) — the circuit interface depended on the strategy (Bennett-gft0).
#
# Invariant: for every callable `f` (closure, callable struct, Fix1/Fix2,
# ComposedFunction), immutable plain-bits state (incl. `Type{T}` fields) is
# bound as constants — the circuit's inputs are exactly the declared arguments
# on EVERY strategy — and any other state (mutable callable, Ref, array) is
# rejected loudly on every strategy.

using Test, Bennett

struct Add2op8 <: Function
    k::Int8
end
(a::Add2op8)(x::Int8) = x + a.k

struct Sub2op8                      # callable struct that is not a Function
    k::Int8
end
(a::Sub2op8)(x::Int8) = x - a.k

struct Two2op8
    a::Int8
    b::Int8
end
(t::Two2op8)(x::Int8) = x * t.a + t.b

struct Unused2op8                   # first field never read
    a::Int8
    b::Int8
end
(u::Unused2op8)(x::Int8) = x ⊻ u.b

struct Inner2op8
    a::Int8
    b::Int8
end
struct Nest2op8
    i::Inner2op8
    c::Int8
end
(n::Nest2op8)(x::Int8) = (x + n.i.a) * n.i.b ⊻ n.c

struct Wide2op8                     # field wider than the argument
    k::Int32
end
(w::Wide2op8)(x::Int8) = x + (w.k % Int8)

struct Typ2op8{T}                   # `Type{T}` field: an 8-byte pointer, not a ghost
    t::Type{T}
    k::Int8
end
(s::Typ2op8)(x::Int8) = x + s.k + zero(s.t)

struct TypOnly2op8{T}
    t::Type{T}
end
(s::TypOnly2op8)(x::Int8) = x + one(s.t)

struct Zero2op8 end
(::Zero2op8)(x::Int8) = x + Int8(1)

mutable struct Mut2op8
    k::Int8
end
(m::Mut2op8)(x::Int8) = x + m.k

struct Ref2op8
    r::Base.RefValue{Int8}
end
(f::Ref2op8)(x::Int8) = x + f.r[]

struct Vec2op8
    v::Vector{Int8}
end
(f::Vec2op8)(x::Int8) = x + f.v[1]

mutable struct MutF2op8
    k::Float64
end
(m::MutF2op8)(x) = x * m.k

_closure2op8(k::Int8) = x -> x - k

const KS_2op8 = Int8[-128, 3, 127]
const STRATS_2op8 = (:expression, :tabulate, :auto)

# (label, constructor k -> callable) — each callable's oracle is itself.
const ACCEPT_2op8 = [
    ("closure",                 k -> _closure2op8(k)),
    ("struct <: Function",      k -> Add2op8(k)),
    ("struct, not a Function",  k -> Sub2op8(k)),
    ("two fields",              k -> Two2op8(k, k + Int8(1))),
    ("unused field",            k -> Unused2op8(Int8(9), k)),
    ("nested isbits struct",    k -> Nest2op8(Inner2op8(k, Int8(3)), Int8(5))),
    ("Int32 field",             k -> Wide2op8(Int32(k) * Int32(1000))),
    ("Type field + Int8",       k -> Typ2op8(Int8, k)),
    ("Type field only",         k -> TypOnly2op8(Int8)),
    ("zero-field struct",       k -> Zero2op8()),
    ("Base.Fix1",               k -> Base.Fix1(-, k)),
    ("Base.Fix2",               k -> Base.Fix2(-, k)),
    ("Base.Fix2 xor",           k -> Base.Fix2(xor, k)),
    ("ComposedFunction",        k -> Base.Fix2(+, k) ∘ Add2op8(Int8(7))),
]

const REJECT_2op8 = [
    ("mutable callable struct", Mut2op8(Int8(3))),
    ("Ref field",               Ref2op8(Ref(Int8(3)))),
    ("Vector field",            Vec2op8(Int8[3])),
    ("Fix2 of a Ref-holder",    Base.Fix2(+, Ref(Int8(3)))),
]

function _err2op8(thunk)
    try
        thunk()
        return nothing
    catch e
        return e
    end
end

@testset "Bennett-2op8: callable state is bound or rejected, on every strategy" begin
    @testset "bound: $label, $strategy" for (label, mk) in ACCEPT_2op8,
                                             strategy in STRATS_2op8
        for k in KS_2op8
            f = mk(k)
            c = reversible_compile(f, Int8; strategy)
            @test c.input_widths == [8]          # the declared argument only
            @test verify_reversibility(c)
            bad = [x for x in typemin(Int8):typemax(Int8) if simulate(c, x) != f(x)]
            @test isempty(bad)
        end
    end

    @testset "rejected: $label, $strategy" for (label, f) in REJECT_2op8,
                                                strategy in STRATS_2op8
        err = _err2op8(() -> reversible_compile(f, Int8; strategy))
        @test err isa ArgumentError
        msg = err === nothing ? "" : sprint(showerror, err)
        @test occursin("immutable plain-bits", msg)
        @test occursin("Bennett-2op8", msg)
    end

    @testset "bound state is unsupported with bit_width / reversible_vm" begin
        for f in (Add2op8(Int8(3)), Base.Fix2(-, Int8(3)))
            err = _err2op8(() -> reversible_compile(f, Int8; bit_width=4,
                                                    strategy=:expression))
            @test err isa ArgumentError &&
                  occursin("bit_width=4", sprint(showerror, err))
            err = _err2op8(() -> reversible_compile(f, Int8; target=:reversible_vm))
            @test err isa ArgumentError &&
                  occursin("reversible_vm", sprint(showerror, err))
        end
    end

    @testset "Float64 entry: same rule (the SoftFloat wrapper captures f)" begin
        f = Base.Fix2(*, 2.5)
        c = reversible_compile(f, Float64)
        @test c.input_widths == [64]
        @test verify_reversibility(c)
        for x in (0.0, -0.0, 1.0, -3.75, 1.0e300, 5.0e-324, Inf, NaN)
            @test simulate(c, reinterpret(UInt64, x)) % UInt64 ==
                  reinterpret(UInt64, f(x))
        end
        err = _err2op8(() -> reversible_compile(MutF2op8(2.5), Float64))
        @test err isa ArgumentError &&
              occursin("immutable plain-bits", sprint(showerror, err))
    end
end
