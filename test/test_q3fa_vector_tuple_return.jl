# Bennett-q3fa — tuple returns built with vector lane bookkeeping into sret.
#
# Under optimize=true (pinned x86-64-v3 target), `x -> (x, x, x, x)` becomes
#
#     %0 = insertelement <4 x i64> poison, i64 %x, i64 0
#     %1 = shufflevector <4 x i64> %0, <4 x i64> poison, <4 x i32> zeroinitializer
#     store <4 x i64> %1, ptr %sret_return
#
# Both producers are pure lane bookkeeping: their conversion emits NO IR
# instruction. Pre-fix the pass-2 walker `continue`d on a `nothing` result
# before resolving the pending sret vector store, so the store's lanes were
# never filled and the funnel raised an AssertionError at `ret void`.
#
# Invariant: every instruction that defines vector lanes — including the
# lane-only producers (`VEC_LANES_ONLY` result) — resolves every pending sret
# vector store that reads those lanes; a store whose lanes are still pending
# when the walker reaches it is a loud `_ir_error`, and a constant stored
# vector is resolved at the store itself.

using Test, Bennett
using Bennett: reversible_compile, simulate, verify_reversibility

const _Q3FA_VEC_RE = r"insertelement|shufflevector|store <\d+ x i"

_q3fa_uses_vector(f, argT) =
    occursin(_Q3FA_VEC_RE, Bennett.extract_ir(f, argT; optimize=true))

# Build `(args...) -> (e1, ..., eL)` with literal tuple syntax, so each cell
# is a fully specialised function (no Val / ntuple dispatch).
function _q3fa_make(T::Type, L::Int, shape::Symbol)
    elems = if shape === :same
        [:x for _ in 1:L]
    elseif shape === :xy
        [isodd(i) ? :x : :y for i in 1:L]
    elseif shape === :ramp
        [i == 1 ? :x : :(x + $(T(i - 1))) for i in 1:L]
    elseif shape === :const
        [i == 2 ? :($(T(7))) : :x for i in 1:L]
    elseif shape === :rev
        [isodd(i) ? :y : :x for i in 1:L]
    else
        error("unknown shape $shape")
    end
    nargs = shape in (:xy, :rev) ? 2 : 1
    body = Expr(:tuple, elems...)
    f = nargs == 1 ? @eval((x::$T) -> $body) : @eval((x::$T, y::$T) -> $body)
    return f, nargs
end

function _q3fa_inputs(T::Type, nargs::Int)
    edge = T[typemin(T), typemin(T) + one(T), -one(T), zero(T), one(T),
             T(5), typemax(T) - one(T), typemax(T)]
    if nargs == 1
        return T === Int8 ? [(x,) for x in typemin(Int8):typemax(Int8)] :
                            [(x,) for x in edge]
    end
    return [(a, b) for a in edge for b in edge]
end

# Built in its own top-level statement so the testset below runs in a world
# that sees every `@eval`-defined cell function.
const _Q3FA_CELLS = [(T, L, shape, _q3fa_make(T, L, shape)...)
                     for T in (Int8, Int16, Int32, Int64), L in (2, 3, 4, 8, 16),
                         shape in (:same, :xy, :ramp, :const, :rev)]

@testset "Bennett-q3fa vector-built tuple returns via sret" begin
    @testset "witnesses" begin
        f4 = x -> (x, x, x, x)
        c = reversible_compile(f4, Int64)
        for x in Int64[0, 1, -1, 42, typemin(Int64), typemax(Int64)]
            @test simulate(c, x) == f4(x)
        end
        @test verify_reversibility(c)
        @test _q3fa_uses_vector(f4, Tuple{Int64})

        f8 = x -> ntuple(_ -> x, 8)
        c8 = reversible_compile(f8, Int32)
        for x in Int32[0, 1, -1, 1234567, typemin(Int32), typemax(Int32)]
            @test simulate(c8, x) == f8(x)
        end
        @test verify_reversibility(c8)
        @test _q3fa_uses_vector(f8, Tuple{Int32})
    end

    @testset "grid: eltype × length × shape" begin
        n_vec = 0; n_cells = 0; n_memset = 0
        for (T, L, shape, f, nargs) in _Q3FA_CELLS
            argT = nargs == 1 ? Tuple{T} : Tuple{T, T}
            n_cells += 1
            _q3fa_uses_vector(f, argT) && (n_vec += 1)
            ir = Bennett.extract_ir(f, argT; optimize=true)
            if occursin("llvm.memset", ir)
                # A DIFFERENT construct (not vector lanes): LLVM fills a run of
                # identical i8 elements with `llvm.memset` into the sret slot,
                # which the sret collector does not model. Pinned refusal —
                # follow-up bead, out of q3fa's scope.
                n_memset += 1
                @testset "$T × $L × $shape (memset sret, refused)" begin
                    @test T === Int8
                    err = try
                        reversible_compile(f, argT.parameters...); nothing
                    catch e
                        e
                    end
                    @test err !== nothing
                    @test occursin(r"never materialised|is never written",
                                   sprint(showerror, err))
                end
                continue
            end
            @testset "$T × $L × $shape" begin
                c = reversible_compile(f, argT.parameters...)
                for inp in _q3fa_inputs(T, nargs)
                    want = f(inp...)
                    got = nargs == 1 ? simulate(c, inp[1]) : simulate(c, inp)
                    @test got == want
                end
                @test verify_reversibility(c)
            end
        end
        println("  Bennett-q3fa grid: $n_vec / $n_cells cells use vector IR " *
                "(insertelement / shufflevector / vector store); " *
                "$n_memset memset-sret cells pinned as refused")
        @test n_memset <= 2
        # The grid must actually exercise the vector path, not only scalar stores.
        @test n_vec >= 20
    end

    # .ll-level: the two pass-1 / pass-2 edges no Julia witness reaches.
    function _q3fa_ll(body::String, args::String)
        dir = mktempdir()
        path = joinpath(dir, "q3fa.ll")
        write(path, """
            define void @q3fa(ptr noalias nocapture sret([4 x i64]) align 8 dereferenceable(32) %sret_return, $args) {
            top:
            $body
              ret void
            }
            """)
        return path
    end

    @testset "constant stored vector resolves at the store" begin
        path = _q3fa_ll("  store <4 x i64> <i64 1, i64 -2, i64 3, i64 40>, ptr %sret_return, align 8",
                       "i64 %x")
        pir = Bennett.extract_parsed_ir_from_ll(path; entry_function="q3fa")
        c = reversible_compile(pir)
        for x in Int64[0, 5, -1]
            @test simulate(c, x) == (1, -2, 3, 40)
        end
        @test verify_reversibility(c)
    end

    @testset "pending store whose value defines no lanes: loud _ir_error" begin
        # The stored value is a vector ARGUMENT — no producer instruction ever
        # resolves the pending store. Pre-q3fa: AssertionError at `ret void`.
        path = _q3fa_ll("  store <4 x i64> %v, ptr %sret_return, align 8",
                        "i64 %x, <4 x i64> %v")
        err = try
            Bennett.extract_parsed_ir_from_ll(path; entry_function="q3fa"); nothing
        catch e
            e
        end
        @test err isa ErrorException
        @test err !== nothing && !(err isa AssertionError)
        msg = err === nothing ? "" : sprint(showerror, err)
        @test occursin("Bennett-q3fa: sret vector store of lanes 0..3", msg)
        @test occursin("still pending", msg)
        println("  Bennett-q3fa vector-arg sret store refusal: ", first(split(msg, '\n')))
    end
end
