using Test
using Bennett
using Bennett: register_callee!, extract_parsed_ir, extract_parsed_ir_from_ll

# Bennett-08xz — the U15 benign-drop allowlist (src/extract/instructions.jl)
# dropped every call whose callee name STARTS WITH `j_throw_`, `ijl_throw`,
# `jl_throw`, `ijl_bounds_error` or `jl_bounds_error`, as a Julia runtime error
# helper that never returns. Julia mangles a user function `throw_foo` as
# `j_throw_foo_NNN`, so an unregistered user `throw_*` call was deleted: a
# returned value became an undefined SSA name (opaque lowering crash), and a
# call made only for its effect (one that may throw) vanished without a word —
# a circuit that answers where native Julia throws. A `.ll` input can name a C
# function `jl_throw_x` / `ijl_bounds_error_x` the same way.
#
# Fix: the throw/bounds prefixes are dropped only when the call cannot return:
# `noreturn` on the call site or callee declaration, or `unreachable` as the
# next instruction. Every genuine helper carries the attribute — measured
# at both optimize modes for `ijl_throw` (div), `ijl_bounds_error_int` (tuple /
# Vector index), `j_throw_inexacterror_NNN`, `j_throw_boundserror_NNN`,
# `j_throw_overflowerr_binaryop_NNN`, `j_throw_complex_domainerror_NNN`. A
# returning `throw_*` call now takes the normal path: registered → inlined,
# unregistered → the loud U15 error.

# ---- user functions whose names hit (or, for `Throw_x`, miss) the prefix ----
# Three functions per name, all sharing the LLVM symbol prefix: the value form
# (the bare name), the effect-only form (`<name>!`, returns `nothing`, throws
# on one input), the always-throw form (`<name>_fail`, inferred `Union{}` ⇒
# `noreturn`). Separate functions, because gate-level inlining needs a callee
# with one method (Bennett-atf4).
@noinline throw_x(x::Int8) = x * x + Int8(3)
@noinline throw_x!(x::Int8) = (x == Int8(42) && error("x is 42"); nothing)
@noinline throw_x_fail(x::Int8) = error("throw_x_fail $x")
@noinline throw_(x::Int8) = xor(x, Int8(0x5a)) - Int8(1)
@noinline throw_!(x::Int8) = (x == Int8(42) && error("x is 42"); nothing)
@noinline throw__fail(x::Int8) = error("throw__fail $x")
@noinline Throw_x(x::Int8) = x - Int8(7)
@noinline Throw_x!(x::Int8) = (x == Int8(42) && error("x is 42"); nothing)
@noinline Throw_x_fail(x::Int8) = error("Throw_x_fail $x")

used_throw_x(x::Int8) = throw_x(x) + Int8(1)
used_throw_(x::Int8)  = throw_(x) + Int8(1)
used_Throw_x(x::Int8) = Throw_x(x) + Int8(1)
branch_throw_x(x::Int8) = x > Int8(0) ? throw_x(x) : x     # the call is the only thing in the arm
branch_throw_(x::Int8)  = x > Int8(0) ? throw_(x) : x
branch_Throw_x(x::Int8) = x > Int8(0) ? Throw_x(x) : x
effect_throw_x(x::Int8) = (throw_x!(x); x + Int8(1))
effect_throw_(x::Int8)  = (throw_!(x); x + Int8(1))
effect_Throw_x(x::Int8) = (Throw_x!(x); x + Int8(1))
error_throw_x(x::Int8) = x > Int8(100) ? throw_x_fail(x) : x + Int8(1)
error_throw_(x::Int8)  = x > Int8(100) ? throw__fail(x) : x + Int8(1)
error_Throw_x(x::Int8) = x > Int8(100) ? Throw_x_fail(x) : x + Int8(1)

# ---- genuine Base error paths: must keep compiling exactly as before ----
g_inexact(x::Int16) = Int8(x)                     # j_throw_inexacterror_NNN
g_unsigned(x::Int8) = convert(UInt8, x)           # j_throw_inexacterror_NNN
g_tup(x::Int8) = (Int8(3), Int8(5), Int8(7))[x]   # ijl_bounds_error_int
g_div(x::Int8) = div(Int8(100), x)                # ijl_throw (DivideError)

function _x8_try(f; kw...)
    try
        return reversible_compile(f, Int8; kw...)
    catch e
        e isa InterruptException && rethrow()
        return e
    end
end

_x8_native(f, x) = try f(x) catch; nothing end

# Exhaustive check on every Int8 input where native Julia returns; inputs where
# it throws are skipped (what a circuit does there is Bennett-jzhh's business).
function _x8_exhaustive(c, f; min_ok::Int=1)
    @test c isa Bennett.ReversibleCircuit
    c isa Bennett.ReversibleCircuit || return
    bad = Int8[]
    n = 0
    for x in typemin(Int8):typemax(Int8)
        want = _x8_native(f, x)
        want === nothing && continue
        n += 1
        simulate(c, x) == want || push!(bad, x)
    end
    isempty(bad) || @info "Bennett-08xz mismatches" f first(bad, 5)
    @test isempty(bad)
    @test n >= min_ok
    @test verify_reversibility(c)
end

function _x8_loud_unregistered(f, callee::String)
    for opt in (true, false)
        r = _x8_try(f; optimize=opt)
        @test r isa Exception
        r isa Exception || continue
        msg = sprint(showerror, r)
        ok = occursin(callee, msg) && occursin("register_callee!", msg)
        ok || @info "Bennett-08xz unexpected error" f opt first(msg, 300)
        @test ok
    end
end

function _x8_unregister!(names...)
    lock(Bennett._known_callees_lock) do
        for n in names
            delete!(Bennett._known_callees, n)
            delete!(Bennett._known_callee_names, n)
        end
    end
    Bennett._clear_parsed_ir_cache!(); Bennett._clear_compile_cache!()
end

const _X8_GROUPS = (
    ("throw_x", throw_x, used_throw_x, branch_throw_x, effect_throw_x, error_throw_x),
    ("throw_",  throw_,  used_throw_,  branch_throw_,  effect_throw_,  error_throw_),
    ("Throw_x", Throw_x, used_Throw_x, branch_Throw_x, effect_Throw_x, error_Throw_x),
)

@testset "Bennett-08xz: user functions are never taken for runtime throw helpers" begin
    for (nm, callee, used, branch, effect, err) in _X8_GROUPS
        mangled = "j_" * nm
        @testset "$nm: unregistered value / branch / effect calls fail loud" begin
            _x8_loud_unregistered(used, mangled)
            _x8_loud_unregistered(branch, mangled)
            # Effect-only form: pre-fix, the `throw_*` call vanished and the
            # circuit returned x+1 at x == 42, where native Julia throws.
            _x8_loud_unregistered(effect, mangled)
        end
        @testset "$nm: registered value / branch calls compile, all 256 inputs" begin
            register_callee!(callee)
            try
                for opt in (true, false)
                    _x8_exhaustive(_x8_try(used; optimize=opt), used; min_ok=256)
                    _x8_exhaustive(_x8_try(branch; optimize=opt), branch; min_ok=256)
                end
            finally
                _x8_unregister!(nm)
            end
        end
    end
    @testset "noreturn user throw_* helper is still dropped as an error path" begin
        for f in (error_throw_x, error_throw_), opt in (true, false)
            _x8_exhaustive(_x8_try(f; optimize=opt), f; min_ok=229)
        end
    end
    @testset "noreturn helper whose name has no throw prefix stays loud" begin
        _x8_loud_unregistered(error_Throw_x, "j_Throw_x_")
    end
    @testset "genuine Base error helpers keep compiling" begin
        for opt in (true, false)
            _x8_exhaustive(_x8_try(g_unsigned; optimize=opt), g_unsigned; min_ok=128)
            _x8_exhaustive(_x8_try(g_tup; optimize=opt), g_tup; min_ok=3)
            c = reversible_compile(g_inexact, Int16; optimize=opt)
            @test all(x -> simulate(c, x) == g_inexact(x), Int16(-128):Int16(127))
            @test verify_reversibility(c)
        end
        _x8_exhaustive(_x8_try(g_div), g_div; min_ok=255)
    end
end

# ---- the other prefixes, reachable only from text/bitcode input (a C name) ----
# A Julia user function always mangles to `j_<name>_NNN` / `julia_<name>_NNN`,
# so only `j_throw_` is reachable from Julia; `ijl_throw` / `jl_throw` /
# `ijl_bounds_error` / `jl_bounds_error` are reachable by a C function name.
_x8_value_ir(cn) = """
declare i8 @$(cn)(i8)
define i8 @julia_caller(i8 %x) {
top:
  %r = call i8 @$(cn)(i8 %x)
  %s = add i8 %r, 1
  ret i8 %s
}
"""
_x8_effect_ir(cn) = """
declare void @$(cn)(i8)
define i8 @julia_caller(i8 %x) {
top:
  call void @$(cn)(i8 %x)
  %s = add i8 %x, 1
  ret i8 %s
}
"""
# The genuine shape: a call on the dead arm of a branch that cannot return —
# by a `noreturn` declaration (real Julia IR), or only by the `unreachable`
# that follows it (hand-written fixtures, e.g. test_3vf2's `@ijl_throw(ptr)`).
_x8_noreturn_ir(cn, attr) = """
declare void @$(cn)(i8)$(attr ? " #0" : "")
define i8 @julia_caller(i8 %x) {
top:
  %c = icmp sgt i8 %x, 100
  br i1 %c, label %fail, label %ok
fail:
  call void @$(cn)(i8 %x)
  unreachable
ok:
  %s = add i8 %x, 1
  ret i8 %s
}
attributes #0 = { noreturn }
"""

@testset "Bennett-08xz: every throw/bounds prefix needs noreturn (.ll input)" begin
    mktempdir() do dir
        for cn in ("j_throw_x_1", "ijl_throw_x", "jl_throw_x", "ijl_bounds_error_x",
                   "jl_bounds_error_x", "ijl_throw", "jl_throw")
            for (form, ir) in (("value", _x8_value_ir(cn)), ("effect", _x8_effect_ir(cn)))
                path = joinpath(dir, "$(cn)_$(form).ll")
                write(path, ir)
                r = try
                    extract_parsed_ir_from_ll(path; entry_function="julia_caller")
                catch e
                    e
                end
                @test r isa Exception
                if r isa Exception
                    msg = sprint(showerror, r)
                    ok = occursin("'$(cn)'", msg) && occursin("register_callee!", msg)
                    ok || @info "Bennett-08xz unexpected .ll error" cn form first(msg, 300)
                    @test ok
                end
            end
            for attr in (true, false)
                path = joinpath(dir, "$(cn)_noreturn_$(attr).ll")
                write(path, _x8_noreturn_ir(cn, attr))
                pir = extract_parsed_ir_from_ll(path; entry_function="julia_caller")
                c = reversible_compile(pir)
                bad = [x for x in typemin(Int8):Int8(100) if simulate(c, x) != x + Int8(1)]
                @test isempty(bad)
                @test verify_reversibility(c)
            end
        end
    end
end
