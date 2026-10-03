# Bennett-o9sv: a closure's captured variables must not silently become extra
# circuit inputs. Julia passes a capturing closure's own object as a hidden
# leading `#self#` pointer parameter, which the walker turned into an input
# (x -> x - k with k::Int8 compiled to input widths [8, 8]; `simulate(c, x)`
# could not compute f(x)). Now:
#   - isbits captures (immutable values, fixed when the closure is built) are
#     bound into the circuit as constants — the circuit takes only the
#     declared arguments;
#   - captures that can change after compilation (Ref, mutable struct, array,
#     a reassigned variable boxed as Core.Box) are rejected loudly, on every
#     strategy, as is narrowing (`bit_width`) and `target=:reversible_vm`.
# Callable structs keep the Bennett-4ddk field-as-input behaviour (pinned in
# test_4ddk_compile_cache_soundness.jl).

using Test
using Bennett

mutable struct Mut_o9sv
    k::Int8
end

# Bennett-u9cc: a user type that merely LOOKS like a closure (name starts with
# `#`) but is mutable.
mutable struct var"#MutableCapture_u9cc" <: Function
    k::Int8
end
(f::var"#MutableCapture_u9cc")(x::Int8) = x + f.k

_sub_closure_o9sv(k::Int8) = x -> x - k
_add2_closure_o9sv(k::Int8) = (x, y) -> x - k + y

function _check_all_int8_o9sv(c, oracle)
    @test verify_reversibility(c)
    bad = [(x, simulate(c, x), oracle(x)) for x in typemin(Int8):typemax(Int8)
           if simulate(c, x) != oracle(x)]
    isempty(bad) || @info "mismatches" first(bad, 5)
    @test isempty(bad)
end

@testset "Bennett-o9sv: closure captures" begin

    @testset "isbits Int8 capture is a constant, not an input" begin
        for k in Int8[7, -128, -1, 0, 127]
            f = _sub_closure_o9sv(k)
            c = reversible_compile(f, Int8)
            @test c.input_widths == [8]
            _check_all_int8_o9sv(c, x -> x - k)
        end
    end

    @testset "same closure type, different captures: no shared circuit" begin
        f7 = _sub_closure_o9sv(Int8(7))
        f9 = _sub_closure_o9sv(Int8(9))
        @test typeof(f7) === typeof(f9)
        c7 = reversible_compile(f7, Int8)
        c9 = reversible_compile(f9, Int8)
        c7b = reversible_compile(f7, Int8)     # after f9 hit the caches
        for x in Int8[-128, -1, 0, 10, 127]
            @test simulate(c7, x) == x - Int8(7)
            @test simulate(c9, x) == x - Int8(9)
            @test simulate(c7b, x) == x - Int8(7)
        end
        @test verify_reversibility(c9) && verify_reversibility(c7b)
    end

    @testset "two-argument closure keeps both declared inputs" begin
        f = _add2_closure_o9sv(Int8(5))
        c = reversible_compile(f, Int8, Int8)
        @test c.input_widths == [8, 8]
        @test verify_reversibility(c)
        bad = 0
        for x in typemin(Int8):typemax(Int8), y in Int8[-128, -7, 0, 1, 127]
            simulate(c, (x, y)) == x - Int8(5) + y || (bad += 1)
        end
        @test bad == 0
    end

    @testset "multi-field and padded captures bind with Julia's layout" begin
        a = Int8(-3); b = Int16(1000)          # Int8 then Int16: one padding byte
        f = x -> (x ⊻ Int16(a)) + b
        @test sizeof(typeof(f)) == 4
        c = reversible_compile(f, Int16)
        @test c.input_widths == [16]
        @test verify_reversibility(c)
        xs = Int16[typemin(Int16), -1000, -1, 0, 1, 2, 255, 256, 12345, typemax(Int16)]
        @test all(x -> simulate(c, x) == f(x), xs)

        t = (Int8(17), Int8(-90))
        g = x -> x + t[1] - t[2]
        cg = reversible_compile(g, Int8)
        @test cg.input_widths == [8]
        _check_all_int8_o9sv(cg, g)
    end

    @testset "Int64 and Bool captures" begin
        k = -Int64(0x0123456789abcdef)
        f = x -> x + k
        c = reversible_compile(f, Int64)
        @test c.input_widths == [64]
        @test verify_reversibility(c)
        xs = Int64[typemin(Int64), -1, 0, 1, 42, typemax(Int64), 0x0f0f0f0f0f0f0f0f]
        @test all(x -> simulate(c, x) == f(x), xs)

        for flag in (true, false)
            h = x -> flag ? x + Int8(1) : x - Int8(1)
            ch = reversible_compile(h, Int8)
            @test ch.input_widths == [8]
            _check_all_int8_o9sv(ch, h)
        end
    end

    @testset "explicit tabulate on a capturing closure" begin
        f = _sub_closure_o9sv(Int8(33))
        c = reversible_compile(f, Int8; strategy=:tabulate)
        @test c.input_widths == [8]
        _check_all_int8_o9sv(c, x -> x - Int8(33))
    end

    @testset "singleton-typed captures (a captured Type) are skipped" begin
        mk_t(T) = x -> x + zero(T)
        mk_tk(T, k) = x -> x + k + zero(T)
        mk_kt(T, k) = x -> zero(T) + x * k
        mk_nothing(n) = x -> (n === nothing ? x + Int8(1) : x)
        g_o9sv(x) = x + Int8(7)
        mk_fn(g) = x -> g(x) + Int8(1)
        mk_nested(T, a) = (h = y -> y + a + zero(T); x -> h(x) + Int8(1))
        cases = [
            (mk_t(Int8),                x -> x),
            (mk_tk(Int8, Int8(5)),      x -> x + Int8(5)),
            (mk_kt(Int8, Int8(3)),      x -> x * Int8(3)),
            (mk_nothing(nothing),       x -> x + Int8(1)),
            (mk_fn(g_o9sv),             x -> x + Int8(8)),
            (mk_nested(Int8, Int8(2)),  x -> x + Int8(3)),
        ]
        for (f, oracle) in cases
            c = reversible_compile(f, Int8)
            @test c.input_widths == [8]
            _check_all_int8_o9sv(c, oracle)
        end
        @test_throws ArgumentError reversible_compile(
            (r = Ref(Int8(1)); T = Int8; x -> x + r[] + zero(T)), Int8)
    end

    @testset "captures that can change after compilation are rejected" begin
        r = Ref(Int8(7))
        fr = x -> x - r[]
        m = Mut_o9sv(Int8(7))
        fm = x -> x - m.k
        v = Int8[1, 2]
        fv = x -> x + v[1]
        bx = Int8(7)
        fb = x -> x - bx
        bx = Int8(9)                            # reassigned → Core.Box
        for f in (fr, fm, fv, fb), strategy in (:auto, :expression, :tabulate)
            err = try
                reversible_compile(f, Int8; strategy)
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test err !== nothing && occursin("Bennett-o9sv", sprint(showerror, err))
        end
    end

    @testset "unsupported combinations with captures are rejected" begin
        f = _sub_closure_o9sv(Int8(7))
        @test_throws ArgumentError reversible_compile(f, Int8; bit_width=4,
                                                      strategy=:expression)
        @test_throws ArgumentError reversible_compile(f, Int8;
                                                      target=:reversible_vm)
    end

    @testset "Bennett-u9cc: a mutable #-named Function is not a closure" begin
        f = var"#MutableCapture_u9cc"(Int8(3))
        @test !Bennett._is_closure_type(typeof(f))
        @test !Bennett._capture_ok(typeof(f))
        # callable-struct path: the field stays an explicit circuit input
        c = reversible_compile(f, Int8; strategy=:expression)
        @test c.input_widths == [8, 8]
        @test verify_reversibility(c)
        bad = [(x, k) for x in typemin(Int8):typemax(Int8), k in Int8[-128, -1, 0, 3, 7, 127]
               if simulate(c, (k, x)) != var"#MutableCapture_u9cc"(k)(x)]
        @test isempty(bad)
        # nested inside an otherwise-immutable real closure: rejected
        r = var"#MutableCapture_u9cc"(Int8(3))
        g = x -> r(x)
        for strategy in (:auto, :expression, :tabulate)
            err = try
                reversible_compile(g, Int8; strategy)
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test err !== nothing && occursin("Bennett-o9sv", sprint(showerror, err))
        end
    end

    @testset "capture-free closures are unchanged" begin
        c = reversible_compile(x -> x + Int8(3), Int8)
        @test c.input_widths == [8]
        _check_all_int8_o9sv(c, x -> x + Int8(3))
    end
end
