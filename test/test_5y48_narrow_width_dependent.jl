# Bennett-5y48: bit-width narrowing must not re-type an operation whose meaning
# depends on the bit width.  The extractor EXPANDS llvm.ctlz / cttz /
# bitreverse / bswap / fshl / fshr into plain shifts, masks and selects whose
# constants are computed for the source width S (ctlz of 0 is the constant S;
# bitreverse shifts bit i to S-1-i); `_narrow_ir` then saw only plain binops
# and re-typed them into a wrong circuit (`Base.ctlz_int(0x00)` at W = 7 gave
# 8; `bitrotate(x, 3)` at W = 5 was wrong on 28 of 32 inputs; `bswap` of a
# 16-bit value was ACCEPTED at W = 8, 12, 15, widths where it has no meaning).
#
# INVARIANT: a narrowing at W != S is accepted only if the circuit computes the
# W-bit meaning of the operation; otherwise it is the narrowing ArgumentError.
# Provenance, not shape matching: the extractor records every width-dependent
# intrinsic on `ParsedIR.width_dependent_ops`, `_narrow_ir` refuses W != S
# while it is non-empty (unoptimised, optimised and direct calls), and an
# unoptimised narrowing is refused when LLVM's optimiser recognises the
# function's Julia-level idiom (Julia's own `bitreverse` / `bitrotate` are
# masks and shifts folded for S) as such an intrinsic.
#
# The review's witness `ifelse(bitreverse(x) == 0, 1, 0)` is a Julia-level
# width-dependent idiom that LLVM folds away entirely: the optimised IR is
# `x == 0` (no intrinsic), the unoptimised IR holds Julia's S-bit masks.
# Under optimize=true both readings are narrowed and compared (Bennett-5y48
# differential, test_5y48_differential_narrowing.jl): they disagree, so the
# compile is refused.  KNOWN HOLE (pinned below with @test_broken): under
# optimize=false only the unoptimised IR is narrowed, and it is re-typed
# literally — accepted and wrong at W = 4..7.
#
# THE ORACLE (independent of src/) is the W-bit operation on the W-bit input
# pattern p (read signed for Int8): reverse W bits, count W-bit leading /
# trailing zeros (W for p = 0), rotate within W bits, ...

using Test
using Bennett

y48_wmask(W) = (1 << W) - 1
y48_wsign(p, W) = p >= (1 << (W - 1)) ? p - (1 << W) : p
y48_val(T, p, W) = T <: Signed ? y48_wsign(p, W) : p
y48_in(::Type{T}, p) where {T} = reinterpret(T, (p % unsigned(T)))
y48_brev(p, W) = sum(((p >> i) & 1) << (W - 1 - i) for i in 0:W-1)
y48_clz(p, W) = p == 0 ? W : W - (64 - leading_zeros(UInt64(p)))
y48_ctz(p, W) = p == 0 ? W : trailing_zeros(p)
y48_rotl(p, k, W) = (k = mod(k, W); ((p << k) | (p >> (W - k))) & y48_wmask(W))

# (name, body over x::T, oracle(T, p, W) -> W-bit pattern)
const Y48_OPS = [
    ("bitreverse",      :(bitreverse(x)),                    (T, p, W) -> y48_brev(p, W)),
    ("bitreverse==0",   :(ifelse(bitreverse(x) == zero(x), one(x), zero(x))),
                                                             (T, p, W) -> p == 0 ? 1 : 0),
    ("ctlz_int",        :(Base.ctlz_int(x)),                 (T, p, W) -> y48_clz(p, W)),
    ("cttz_int",        :(Base.cttz_int(x)),                 (T, p, W) -> y48_ctz(p, W)),
    ("ctpop_int",       :(Base.ctpop_int(x)),                (T, p, W) -> count_ones(p)),
    ("leading_zeros",   :(leading_zeros(x) % typeof(x)),     (T, p, W) -> y48_clz(p, W)),
    ("trailing_zeros",  :(trailing_zeros(x) % typeof(x)),    (T, p, W) -> y48_ctz(p, W)),
    ("count_ones",      :(count_ones(x) % typeof(x)),        (T, p, W) -> count_ones(p)),
    ("ctz>2",           :(ifelse(Base.cttz_int(x) > 2 % typeof(x), one(x), zero(x))),
                                                             (T, p, W) -> y48_ctz(p, W) > 2 ? 1 : 0),
    ("bitrotate(x,3)",  :(bitrotate(x, 3)),                  (T, p, W) -> y48_rotl(p, 3, W)),
    ("bitrotate(x,-2)", :(bitrotate(x, -2)),                 (T, p, W) -> y48_rotl(p, -2, W)),
    ("fshl_rot1",       :((x << 1) | (x >>> 7)),             nothing),   # see below
    ("abs",             :(abs(x)),            (T, p, W) -> mod(abs(y48_val(T, p, W)), 1 << W)),
    ("min3",            :(min(x, 3 % typeof(x))), (T, p, W) -> mod(min(y48_val(T, p, W), 3), 1 << W)),
    ("max3",            :(max(x, 3 % typeof(x))), (T, p, W) -> mod(max(y48_val(T, p, W), 3), 1 << W)),
    ("x>>>3",           :(x >>> 3),                          (T, p, W) -> p >> 3),
]
# `(x << 1) | (x >>> 7)` is LITERAL source: its W-bit meaning is the literal
# shifts (x >>> 7 is 0 for W <= 7), not a rotate.  LLVM recognises it as
# llvm.fshl, so it is refused — the price of reading the optimiser's
# recognition (a right circuit turned into a refusal, listed in the report).
y48_literal(T, p, W) = ((p << 1) & y48_wmask(W)) | (W > 7 ? (p >> 7) : 0)

# The cells that are still accepted-and-wrong under optimize=false (KNOWN HOLE above).
const Y48_HOLES = Set(["bitreverse==0"])

const Y48_FUNS = Dict{Tuple{String, DataType}, Function}()
let n = 0
    for (name, body, _) in Y48_OPS, T in (Int8, UInt8)
        fname = Symbol("y48_f_", n += 1)
        Y48_FUNS[(name, T)] = @eval $fname(x::$T) = $body
    end
end

y48_bswap_s(x::Int16)  = bswap(x)
y48_bswap_u(x::UInt16) = bswap(x)

y48_is_refusal(e) = e isa ArgumentError && occursin("refusing to narrow", e.msg)

function y48_cell(f, T, W, opt, orc)
    c = try
        reversible_compile(f, T; bit_width=W, optimize=opt, strategy=:expression)
    catch e
        y48_is_refusal(e) || rethrow()
        return :refused
    end
    nbad = count(p -> (Int(simulate(c, T, y48_in(T, p))) & y48_wmask(W)) != orc(T, p, W),
                 0:y48_wmask(W))
    nbad == 0 || return :wrong
    verify_reversibility(c) || return :irreversible
    return :right
end

@testset "Bennett-5y48: width-dependent operations under bit_width narrowing" begin

    @testset "grid: op × T × W < 8 × optimize — accepted ⇒ right" begin
        counts = Dict(:right => 0, :refused => 0, :wrong => 0, :hole => 0)
        for (name, _, orc0) in Y48_OPS, T in (Int8, UInt8), W in 2:7, opt in (false, true)
            orc = orc0 === nothing ? y48_literal : orc0
            r = y48_cell(Y48_FUNS[(name, T)], T, W, opt, orc)
            if r === :wrong && name in Y48_HOLES && !opt
                counts[:hole] += 1
                @test_broken r !== :wrong
                continue
            end
            r === :wrong && @info "accepted-and-WRONG" name T W opt
            @test r in (:right, :refused)
            counts[r === :irreversible ? :wrong : r] += 1
        end
        @info "Bennett-5y48 grid" accepted=counts[:right] refused=counts[:refused] wrong=counts[:wrong] known_hole=counts[:hole]
        @test counts[:wrong] == 0
        @test counts[:right] > 0   # the width-agnostic operations still narrow
    end

    @testset "W == S: every operation compiles and is right" begin
        for (name, _, _) in Y48_OPS, T in (Int8, UInt8), opt in (false, true)
            f = Y48_FUNS[(name, T)]
            c = reversible_compile(f, T; bit_width=8, optimize=opt, strategy=:expression)
            @test all(p -> Int(simulate(c, T, y48_in(T, p))) & 0xff == Int(f(y48_in(T, p))) & 0xff,
                       0:255)
            @test verify_reversibility(c)
        end
    end

    @testset "bswap (16-bit source): refused at every W != 16" begin
        for T in (Int16, UInt16), opt in (false, true), W in (8, 12, 15)
            f = T === Int16 ? y48_bswap_s : y48_bswap_u
            err = try
                reversible_compile(f, T; bit_width=W, optimize=opt, strategy=:expression)
                nothing
            catch e
                e
            end
            @test y48_is_refusal(err)
        end
        c = reversible_compile(y48_bswap_u, UInt16; bit_width=16)
        @test all(x -> Int(simulate(c, UInt16, x)) & 0xffff == Int(bswap(x)),
                  UInt16(0):UInt16(0x0fff):typemax(UInt16))
        @test verify_reversibility(c)
    end

    @testset "provenance is recorded and refused on a direct _narrow_ir call" begin
        f = Y48_FUNS[("ctlz_int", UInt8)]
        for opt in (false, true)
            p = Bennett.extract_parsed_ir(f, Tuple{UInt8}; optimize=opt)
            @test p.width_dependent_ops == Set(["llvm.ctlz.i8"])
            err = try Bennett._narrow_ir(p, 7; optimized=opt); nothing catch e; e end
            @test err isa ArgumentError && occursin("Bennett-5y48", err.msg) &&
                  occursin("llvm.ctlz.i8", err.msg)
            @test Bennett._narrow_ir(p, 8; optimized=opt).width_dependent_ops ==
                  Set(["llvm.ctlz.i8"])   # W == S: kept, nothing re-typed
        end
        # Julia's bitreverse: no intrinsic unoptimised, recognised by LLVM
        g = Y48_FUNS[("bitreverse", UInt8)]
        @test isempty(Bennett.extract_parsed_ir(g, Tuple{UInt8}; optimize=false).width_dependent_ops)
        @test Bennett.extract_parsed_ir(g, Tuple{UInt8}; optimize=true).width_dependent_ops ==
              Set(["llvm.bitreverse.i8"])
        err = try reversible_compile(g, UInt8; bit_width=7, optimize=false); nothing catch e; e end
        @test err isa ArgumentError && occursin("Bennett-5y48", err.msg) &&
              occursin("llvm.bitreverse.i8", err.msg)
    end

    @testset "the review witness (LLVM folds the idiom away)" begin
        f = Y48_FUNS[("bitreverse==0", UInt8)]
        # optimize=true: the two readings disagree — refused (Bennett-5y48 differential)
        err = try reversible_compile(f, UInt8; bit_width=7); nothing catch e; e end
        @test err isa ArgumentError && occursin("Bennett-5y48 / Bennett-sl4h", err.msg) &&
              occursin("narrow to different 7-bit functions", err.msg)
        # optimize=false: KNOWN HOLE — the unoptimised IR alone, re-typed literally
        c = reversible_compile(f, UInt8; bit_width=7, optimize=false)
        nbad = count(p -> simulate(c, UInt8, UInt8(p)) != (p == 0 ? 1 : 0), 0:127)
        @test_broken nbad == 0
        @test verify_reversibility(c)
    end
end

# Bennett-f66g: overflow-checking and saturating intrinsics are width-dependent
# too (the flag / clamp threshold is the source width).  Hand-written i8 IR,
# extracted with ptr_cells=true (the only mode that accepts them today; the
# plain extraction refuses every one of these upstream).
@testset "Bennett-f66g: overflow / saturating intrinsics refuse narrowing" begin
    dl = "target datalayout = \"e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128\"\n"
    ovf(n) = dl * "declare {i8,i1} @llvm.$n.with.overflow.i8(i8, i8)\n" *
        "define i8 @f(i8 %x) {\n %r = call {i8,i1} @llvm.$n.with.overflow.i8(i8 %x, i8 16)\n" *
        " %o = extractvalue {i8,i1} %r, 1\n %z = zext i1 %o to i8\n ret i8 %z\n}\n"
    sat(n) = dl * "declare i8 @llvm.$n.i8(i8, i8)\n" *
        "define i8 @f(i8 %x) {\n %r = call i8 @llvm.$n.i8(i8 %x, i8 3)\n ret i8 %r\n}\n"
    load(src; kw...) = (path = tempname() * ".ll"; write(path, src);
        Bennett.extract_parsed_ir_from_ll(path; entry_function="f", kw...))
    # native oracles at the source width 8 (flag as 0/1; clamp)
    s8(x) = x >= 128 ? x - 256 : x
    oracles = Dict(
        "uadd.with.overflow" => x -> x + 16 > 255 ? 1 : 0,
        "sadd.with.overflow" => x -> (v = s8(x) + 16; v > 127 || v < -128) ? 1 : 0,
        "umul.with.overflow" => x -> x * 16 > 255 ? 1 : 0,
        "smul.with.overflow" => x -> (v = s8(x) * 16; v > 127 || v < -128) ? 1 : 0,
        "uadd.sat" => x -> min(x + 3, 255),
        "usub.sat" => x -> max(x - 3, 0),
        "sadd.sat" => x -> clamp(s8(x) + 3, -128, 127) & 255,
        "ssub.sat" => x -> clamp(s8(x) - 3, -128, 127) & 255,
        "ushl.sat" => x -> min(x << 3, 255),
        "sshl.sat" => x -> clamp(s8(x) << 3, -128, 127) & 255)
    for n in ("uadd.with.overflow", "sadd.with.overflow", "umul.with.overflow",
              "smul.with.overflow", "uadd.sat", "usub.sat", "sadd.sat", "ssub.sat",
              "ushl.sat", "sshl.sat")
        @testset "$n" begin
            src = endswith(n, "overflow") ? ovf(n[1:findfirst('.', n)-1]) : sat(n)
            # the plain (non-ptr_cells) extraction refuses it upstream
            @test_throws Exception load(src)
            p = load(src; ptr_cells=true)
            @test length(p.width_dependent_ops) == 1 &&
                  occursin("llvm.$(n)", first(p.width_dependent_ops))
            for W in (4, 7)
                err = try Bennett._narrow_ir(p, W); nothing catch e; e end
                @test err isa ArgumentError && occursin("Bennett-5y48", err.msg) &&
                      occursin("llvm.$(n)", err.msg)
            end
            if endswith(n, "overflow")
                q = Bennett._narrow_ir(p, 8)   # W == S: nothing re-typed
                c = Bennett.reversible_compile(q)
                @test all(x -> Int(simulate(c, x)) & 255 == oracles[n](x), 0:255)
                @test verify_reversibility(c)
            else
                # ptr_cells extraction keeps a sat intrinsic as an opaque call
                # with no lowering: it never compiles (nor narrows) at any width.
                @test_throws Exception Bennett.reversible_compile(p)
            end
        end
    end
    @testset "ssub / usub .with.overflow are refused at extraction" begin
        for n in ("ssub", "usub")
            @test_throws Exception load(ovf(n); ptr_cells=true)
        end
    end
    @testset "the review witness: umul.with.overflow flag of 8 at W = 7" begin
        p = load(ovf("umul"); ptr_cells=true)
        c8 = Bennett.reversible_compile(Bennett._narrow_ir(p, 8))
        @test simulate(c8, 8) == 0                 # 128 fits in 8 bits
        err = try Bennett._narrow_ir(p, 7); nothing catch e; e end
        @test err isa ArgumentError && occursin("llvm.umul.with.overflow.i8", err.msg)
    end
end
