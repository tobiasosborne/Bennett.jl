# Bennett-0ysp: `strategy=:tabulate` evaluates `f` natively on every input and
# stores the results in a QROM, so it freezes whatever state `f` holds. For a
# MUTABLE callable that state can change after compilation: a
# `mutable struct var"#X" <: Function` compiled with k=3 kept returning x+3
# after `c.k = 7`. Bennett-u9cc fixed the closure-capture binding on the
# expression path only.
#
# Invariant: no strategy bakes in state of a mutable callable. Bennett-2op8:
# every strategy now refuses it loudly (`:expression` / `:auto` used to keep
# the field as an explicit circuit input).

using Test
using Bennett

mutable struct var"#Mut0ysp" <: Function
    k::Int8
end
(f::var"#Mut0ysp")(x::Int8) = x + f.k

mutable struct PlainMut0ysp
    k::Int8
end
(f::PlainMut0ysp)(x::Int8) = x * f.k

struct var"#Imm0ysp" <: Function
    k::Int8
end
(f::var"#Imm0ysp")(x::Int8) = x + f.k

struct HoldsRef0ysp
    r::Base.RefValue{Int8}
end
(f::HoldsRef0ysp)(x::Int8) = x + f.r[]

const KS_0ysp = Int8[-128, -1, 0, 3, 7, 127]

@testset "Bennett-0ysp: tabulate never bakes in mutable callable state" begin
    @testset "every strategy refuses mutable state ($(nameof(typeof(f))), $strategy)" for f in
            (var"#Mut0ysp"(Int8(3)), PlainMut0ysp(Int8(3)),
             HoldsRef0ysp(Ref(Int8(3)))), strategy in (:tabulate, :expression, :auto)
        @test_throws r"immutable plain-bits.*Bennett-2op8" reversible_compile(
            f, Int8; strategy)
    end

    @testset "immutable callable compiles on every strategy ($strategy, k=$k)" for
            strategy in (:tabulate, :expression, :auto), k in KS_0ysp
        f = var"#Imm0ysp"(k)
        c = reversible_compile(f, Int8; strategy)
        @test c.input_widths == [8]
        @test verify_reversibility(c)
        @test all(simulate(c, x) == f(x) for x in typemin(Int8):typemax(Int8))
    end
end
