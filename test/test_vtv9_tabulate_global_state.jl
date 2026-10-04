# Bennett-vtv9: `strategy=:tabulate` evaluates `f` classically on every input
# at compile time and stores the results in a QROM table. The callable-state
# rule (Bennett-o9sv / 2op8 / sfq8) only inspects the callable's OWN fields, so
# state reached through GLOBALS was frozen into the table: with
# `const cell = Ref(Int8(3)); (::Stateless)(x::Int8) = x + cell[]`, the
# circuit kept returning `x + 3` after `cell[] = 9` (input 1: circuit 4,
# native 10) and `verify_reversibility` still passed.
#
# Invariant: a table is built only when Julia's effect analysis certifies `f`
# (on the declared argument types) as free of external state —
#   effect_free  (no store to global state, no impure / foreign call), and
#   consistent OR inaccessiblememonly  (no read of a global Ref / Vector / Dict
#   / mutable struct or a non-const global variable).
# Explicit `strategy=:tabulate` otherwise raises an ArgumentError naming the
# dependency class; the `:auto` redirect shares the same decision
# (`_tabulate_circuit`) and falls through to expression lowering.

using Test
using Bennett

const CELL_vtv9 = Ref(Int8(3))
struct Stateless_vtv9 end
(::Stateless_vtv9)(x::Int8) = x + CELL_vtv9[]
g_ref_vtv9(x::Int8) = x + CELL_vtv9[]
g_bool_vtv9(a::Bool, b::Bool) = a & b & (CELL_vtv9[] > 0)

nc_vtv9 = Int8(4)
g_nonconst_vtv9(x::Int8) = x + nc_vtv9
tnc_vtv9::Int8 = Int8(4)
g_typednc_vtv9(x::Int8) = x + tnc_vtv9
const VEC_vtv9 = Int8[1, 2, 3, 4]
g_vec_vtv9(x::Int8) = x + VEC_vtv9[(x & 3) + 1]
const DICT_vtv9 = Dict{Int8,Int8}(Int8(0) => Int8(1))
g_dict_vtv9(x::Int8) = x + get(DICT_vtv9, x, Int8(0))
mutable struct MS_vtv9
    v::Int8
end
const MSI_vtv9 = MS_vtv9(Int8(2))
g_mstruct_vtv9(x::Int8) = x + MSI_vtv9.v
g_rand_vtv9(x::Int8) = x + rand(Int8)
g_time_vtv9(x::Int8) = x + (time_ns() % Int8)
const CNT_vtv9 = Ref(0)
g_mutate_vtv9(x::Int8) = (CNT_vtv9[] += 1; x + Int8(1))
g_throw_vtv9(x::Int8) = x < 0 ? throw(DomainError(x)) : x + Int8(1)

# Pure functions: must stay accepted (some only tabulation can compile cheaply).
const CK_vtv9 = Int8(5)
g_const_vtv9(x::Int8) = x + CK_vtv9
const TAB_vtv9 = (Int8(1), Int8(7), Int8(-3), Int8(9))
g_ctup_vtv9(x::Int8) = TAB_vtv9[(x & 3) + 1] + x
g_div_vtv9(x::Int8) = x == 0 ? Int8(0) : div(Int8(100), x)
g_loop_vtv9(x::Int8) = (s = Int8(0); for i in 1:(x & 7); s += x; end; s)
g_localvec_vtv9(x::Int8) = (v = Int8[x, x + Int8(1)]; v[1] + v[2])
g_localms_vtv9(x::Int8) = (m = MS_vtv9(x); m.v *= Int8(3); m.v)
g_while_vtv9(x::UInt8) = (n = 0; y = x; while y != 0; y >>= 1; n += 1; end; UInt8(n))
g_poly_vtv9(x::Int8) = x * x + Int8(3) * x + Int8(1)
# Pure, but `reinterpret` of a primitive type taints every Julia effect (it
# goes through a memcpy foreigncall): certified by the expression-path tier.
primitive type P24vtv9 24 end
(k::P24vtv9)(x::Int8) = x + reinterpret(NTuple{3,Int8}, k)[1]

const READS_vtv9 = "reads mutable or non-constant global state"
const SIDE_vtv9 = "side effect"

@testset "Bennett-vtv9: tabulate never freezes external state" begin
    @testset "the witness is refused (was: circuit 4, native 10)" begin
        CELL_vtv9[] = Int8(3)
        @test_throws ArgumentError reversible_compile(Stateless_vtv9(), Int8; strategy=:tabulate)
        @test_throws "Bennett-vtv9" reversible_compile(Stateless_vtv9(), Int8; strategy=:tabulate)
        @test_throws READS_vtv9 reversible_compile(Stateless_vtv9(), Int8; strategy=:tabulate)
    end

    # dependency => (f, arg types, message substring)
    refused = [
        "global Ref (plain fn)"     => (g_ref_vtv9, (Int8,), READS_vtv9),
        "global Ref (Bool,Bool)"    => (g_bool_vtv9, (Bool, Bool), READS_vtv9),
        "non-const global"          => (g_nonconst_vtv9, (Int8,), "Bennett-vtv9"),
        "typed non-const global"    => (g_typednc_vtv9, (Int8,), READS_vtv9),
        "const global Vector"       => (g_vec_vtv9, (Int8,), READS_vtv9),
        "const global Dict"         => (g_dict_vtv9, (Int8,), READS_vtv9),
        "const mutable struct"      => (g_mstruct_vtv9, (Int8,), READS_vtv9),
        "rand()"                    => (g_rand_vtv9, (Int8,), SIDE_vtv9),
        "time_ns()"                 => (g_time_vtv9, (Int8,), SIDE_vtv9),
        "mutates a global"          => (g_mutate_vtv9, (Int8,), SIDE_vtv9),
    ]
    @testset "refused: $name" for (name, (f, Ts, msg)) in refused
        @test_throws ArgumentError reversible_compile(f, Ts...; strategy=:tabulate)
        @test_throws "Bennett-vtv9" reversible_compile(f, Ts...; strategy=:tabulate)
        @test_throws msg reversible_compile(f, Ts...; strategy=:tabulate)
        # The decision both tabulate exits share (explicit and the `:auto`
        # redirect) refuses too, so `:auto` can never divert to a table.
        lr, reason = Bennett._tabulate_circuit(f, Tuple{Ts...}, 0, true)
        @test lr === nothing
        @test occursin("Bennett-vtv9", reason)
    end

    @testset "generated: global Ref{$T} read by f(::$A)" for T in (Int8, UInt8, Int16),
            A in (Int8, UInt8)
        r = Ref(one(T))
        f = @eval (x::$A) -> x + ($r)[] % $A   # the Ref is a literal: global mutable memory
        @test_throws "Bennett-vtv9" reversible_compile(f, A; strategy=:tabulate)
        @test_throws READS_vtv9 reversible_compile(f, A; strategy=:tabulate)
    end

    @testset "a function that throws for some inputs is refused loudly" begin
        @test_throws ArgumentError reversible_compile(g_throw_vtv9, Int8; strategy=:tabulate)
        @test_throws "throws" reversible_compile(g_throw_vtv9, Int8; strategy=:tabulate)
    end

    accepted = [
        "const isbits global"  => (g_const_vtv9, Int8),
        "const tuple table"    => (g_ctup_vtv9, Int8),
        "division"             => (g_div_vtv9, Int8),
        "local loop"           => (g_loop_vtv9, Int8),
        "local Vector"         => (g_localvec_vtv9, Int8),
        "local mutable struct" => (g_localms_vtv9, Int8),
        "while loop"           => (g_while_vtv9, UInt8),
        "polynomial"           => (g_poly_vtv9, Int8),
        "closure over isbits"  => (let k = Int8(7); x -> x * k; end, Int8),
        "reinterpret primitive (expression tier)" =>
            (reinterpret(P24vtv9, (0x05, 0x00, 0x00)), Int8),
    ]
    @testset "accepted (pure): $name" for (name, (f, T)) in accepted
        c = reversible_compile(f, T; strategy=:tabulate)
        @test all(x -> simulate(c, x) == f(x), typemin(T):typemax(T))
        @test verify_reversibility(c)
    end

    @testset "accepted circuits do not go stale" begin
        # A dependency that CAN change is refused, so an accepted circuit has
        # none: mutating every global the refused cases read leaves it exact.
        c = reversible_compile(g_ctup_vtv9, Int8; strategy=:tabulate)
        CELL_vtv9[] = Int8(9); VEC_vtv9[1] = Int8(-5); MSI_vtv9.v = Int8(11)
        DICT_vtv9[Int8(1)] = Int8(2)
        @test all(x -> simulate(c, x) == g_ctup_vtv9(x), typemin(Int8):typemax(Int8))
        @test verify_reversibility(c)
    end
end
