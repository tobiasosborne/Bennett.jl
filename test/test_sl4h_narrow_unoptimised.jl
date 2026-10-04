# Bennett-sl4h: with `bit_width=W` and `optimize=true` (the default), the
# UNOPTIMISED IR is narrowed first; only if extraction or the narrowing
# allowlist refuses it is the optimised IR narrowed (the pre-sl4h path, with
# its Bennett-koi8 folded-comparison checks).
#
# LLVM's folds are only valid at the source width: `x * 16 == 0` on Int8 folds
# to `(x & 15) == 0`, true iff 16 | x — but in 6-bit modular arithmetic
# x * 16 == 0 iff 4 | x.  Every operand and constant of the folded IR is
# narrowable, so narrowing that IR accepted a wrong circuit.  The unoptimised IR
# holds the source's own multiply, which narrows correctly.
#
# Bennett-5y48 (differential): since then optimize=true narrows BOTH readings
# and, when both are accepted, refuses the compile if their circuits disagree
# (test_5y48_differential_narrowing.jl).  `x * 16 == 0` is such a case: the
# unoptimised reading is right, the optimised one wrong, so optimize=true now
# REFUSES it (optimize=false still compiles it right) — the accepted cost of
# cross-checking; the cells are pinned below (SL4H_DIFF_REFUSED).
#
# INVARIANTS, over a generated corpus x T in {Int8, UInt8} x W in {2,3,4,6,7,8}:
#   (1) where the unoptimised narrowing is accepted, optimize=true uses it (the
#       same gate list as optimize=false) or refuses with the Bennett-5y48
#       differential message (exactly the pinned cells);
#   (2) monotonicity: every cell the pre-sl4h path (optimised IR through
#       `_narrow_ir(...; optimized=true)`) accepted is still accepted, except
#       the pinned differential refusals;
#   (3) an accepted circuit is right on all 2^W input patterns and passes
#       verify_reversibility;
#   (4) a refusal is the narrowing ArgumentError (Bennett-mrhg).
# STILL OPEN: a program whose unoptimised IR is refused AND whose optimised IR
# holds a fold that uses an S-bit arithmetic fact.  Bennett-sl4h (a) closed the
# pinned witnesses (Julia's promotion idiom now narrows unoptimised); the i64
# phi and the overshift arm still force the fallback.
#
# THE ORACLE (independent of src/) interprets the source expression in W-bit
# modular arithmetic: x is the W-bit input read in T's signedness, every
# arithmetic result wraps mod 2^W (renormalised to T's signedness), and a
# comparison compares those values against the literal the source wrote.

using Test
using Bennett

sl4h_wmask(W) = (1 << W) - 1
sl4h_wsign(p, W) = p >= (1 << (W - 1)) ? p - (1 << W) : p
sl4h_norm(::Type{Int8}, v, W)  = sl4h_wsign(mod(v, 1 << W), W)
sl4h_norm(::Type{UInt8}, v, W) = mod(v, 1 << W)
sl4h_in(::Type{Int8}, p)  = reinterpret(Int8, UInt8(p & 0xff))
sl4h_in(::Type{UInt8}, p) = UInt8(p & 0xff)

const SL4H_CMP = (:<, :<=, :>, :>=, :(==), :!=)
const SL4H_ARITH = (:+, :-, :*, :&, :|, :⊻, :<<)

"Evaluate source expression `ex` on the W-bit value `v` (already normalised)."
function sl4h_eval(ex, v, T, W)
    ex === :x && return v
    ex isa Integer && return Int(ex)
    ex isa Expr && ex.head === :call || error("sl4h_eval: unexpected $ex")
    op = ex.args[1]
    if op === :ifelse
        return sl4h_eval(ex.args[2], v, T, W) ? sl4h_eval(ex.args[3], v, T, W) :
                                                sl4h_eval(ex.args[4], v, T, W)
    end
    a = sl4h_eval(ex.args[2], v, T, W)
    b = sl4h_eval(ex.args[3], v, T, W)
    a isa Bool && b isa Bool && op in (:&, :|) && return op === :& ? a & b : a | b
    op in SL4H_CMP && return getfield(Base, op)(a, b)
    op in SL4H_ARITH && return sl4h_norm(T, getfield(Base, op)(a, b), W)
    # `>>` is arithmetic for Int8 (on the signed value), logical for UInt8 (the
    # value is already non-negative); `>>>` is logical on the W-bit pattern
    op === :>> && return sl4h_norm(T, a >> b, W)
    op === :>>> && return sl4h_norm(T, mod(a, 1 << W) >>> b, W)
    error("sl4h_eval: unexpected operator $op")
end

const SL4H_WS = (2, 3, 4, 6, 7, 8)
const SL4H_CASES = Tuple{DataType,String,Any,Function}[]
let n = 0
    for T in (Int8, UInt8)
        t(c) = c % T
        preds = Any[:($op(x, $(t(c)))) for op in SL4H_CMP
                    for c in (0, 1, 3, 16, 100, -1, typemax(T))]
        append!(preds, Any[
            :(x * $(t(16)) == $(t(0))),          # folds to (x & 15) == 0
            :(x * $(t(4)) == $(t(0))),           # folds to (x & 63) == 0
            :(x * $(t(4)) < $(t(3))),
            :((x + $(t(3))) < $(t(2))),
            :((x & $(t(15))) == $(t(0))),
            :((x >> 1) == $(t(0))),
            :((x << 2) != $(t(0))),
            :(x < $(t(0))),                      # Int8: sign test -> lshr 7
            :((x < $(t(2))) | (x >= $(t(128)))), # UInt8: folds to slt x, 2
            :((x >= $(t(248))) & (x <= $(t(248)))),
            :((x >= $(t(9))) & (x <= $(t(12)))), # folds to ult (x - 9), 4
            :((x > $(t(1))) & (x < $(t(6)))),
        ])
        vals = Any[:(x * $(t(16))), :(x * $(t(4))), :(x * x), :(x + $(t(1))),
                   :(x - $(t(5))), :(x << 1), :(x << 3), :(x >> 1), :(x >>> 2),
                   :(x & $(t(15))), :(x | $(t(3))), :(x ⊻ $(t(0x5a))),
                   :(ifelse(x < $(t(3)), x * $(t(3)), x + $(t(1))))]
        for body in preds
            fname = Symbol("sl4h_p_", n += 1)
            f = @eval $fname(x::$T) = ifelse($body, $(T(1)), $(T(0)))
            push!(SL4H_CASES, (T, string(body), :(ifelse($body, 1, 0)), f))
        end
        for body in vals
            fname = Symbol("sl4h_v_", n += 1)
            f = @eval $fname(x::$T) = $body
            push!(SL4H_CASES, (T, string(body), body, f))
        end
    end
end

function sl4h_compile(f, T, W, optimize)
    try
        return reversible_compile(f, T; bit_width=W, optimize,
                                  strategy=:expression), nothing
    catch e
        e isa ArgumentError || rethrow()
        return nothing, e
    end
end
sl4h_is_refusal(e) = e isa ArgumentError && occursin("refusing to narrow", e.msg) &&
                     occursin("Bennett-mrhg", e.msg)
sl4h_is_diff(e) = sl4h_is_refusal(e) && occursin("Bennett-5y48 / Bennett-sl4h", e.msg) &&
                  occursin("narrow to different", e.msg)
# Corpus cells whose two readings disagree (unoptimised right, optimised fold
# wrong): refused at optimize=true since Bennett-5y48 (differential).
const SL4H_DIFF_REFUSED = sort([
    "Int8 x * 16 == 0 @W=6", "Int8 x * 16 == 0 @W=7", "Int8 x * 4 == 0 @W=7",
    "Int8 x << 2 != 0 @W=7", "UInt8 x * 0x10 == 0x00 @W=6", "UInt8 x * 0x10 == 0x00 @W=7",
    "UInt8 x * 0x04 == 0x00 @W=7", "UInt8 x * 0x04 < 0x03 @W=7", "UInt8 x << 2 != 0x00 @W=7"])

"W-bit patterns on which circuit `c` disagrees with the W-bit oracle."
function sl4h_mismatches(c, ex, T, W)
    bad = Int[]
    for p in 0:sl4h_wmask(W)
        want = mod(Int(sl4h_eval(ex, sl4h_norm(T, p, W), T, W)), 1 << W)
        got = Int(simulate(c, T, sl4h_in(T, p))) & sl4h_wmask(W)
        got == want || push!(bad, p)
    end
    return bad
end

sl4h_mul16(x::Int8) = ifelse(x * Int8(16) == Int8(0), Int8(1), Int8(0))

# pre-sl4h path: the optimised IR through the koi8-checked narrowing
function sl4h_old_accepts(f, T, W)
    try
        Bennett._narrow_ir(Bennett.extract_parsed_ir(f, Tuple{T}; optimize=true), W;
                           optimized=true)
        return true
    catch e
        e isa ArgumentError || rethrow()
        return false
    end
end
"The narrowed ParsedIR the unoptimised attempt yields, or `nothing` if refused."
function sl4h_unopt_pir(f, T, W)
    try
        return Bennett._extract_parsed_ir_cached(f, Tuple{T}; optimize=false, bit_width=W)
    catch e
        e isa ArgumentError || rethrow()
        return nothing
    end
end
sl4h_wz(W, a) = mod(a, 1 << W) == 0
"Number of W-bit patterns on which `c` disagrees with `oracle(v)` (v: the W-bit value as a T)."
sl4h_nbad(c, T, W, oracle) =
    count(p -> (Int(simulate(c, T, sl4h_in(T, p))) & sl4h_wmask(W)) !=
               mod(Int(oracle(sl4h_norm(T, p, W))), 1 << W), 0:sl4h_wmask(W))

# the ordinary spellings whose unoptimised IR the allowlist refuses (Julia's
# promotion to i64, the `ashr x, 7` overshift arm); they must keep compiling
sl4h_eq5(x::Int8)    = x == 5
sl4h_even(x::Int8)   = iseven(x)
sl4h_gt2(x::UInt8)   = x > 2
sl4h_ieq5(x::Int8)   = Int8(x == 5 ? 1 : 0)
sl4h_ashr1(x::Int8)  = x >> 1
const SL4H_IDIOMS = (
    ("x == 5",               sl4h_eq5,  Int8,  v -> v == 5),
    ("iseven(x)",            sl4h_even, Int8,  v -> iseven(v)),
    ("UInt8 x > 2",          sl4h_gt2,  UInt8, v -> v > 2),
    ("Int8(x == 5 ? 1 : 0)", sl4h_ieq5, Int8,  v -> v == 5 ? 1 : 0),
    ("Int8 x >> 1",          sl4h_ashr1, Int8, v -> v >> 1),
)

# residual hole: `x == 5` (untyped literal) makes the unoptimised IR refused,
# so the fallback narrows the optimised IR, where `x * 16 == 0` is `(x & 15) == 0`
sl4h_hole(x::Int8) = ifelse((x == 5) | (x * Int8(16) == Int8(0)), Int8(1), Int8(0))

# ---- Bennett-sl4h (a): Julia's promotion idiom narrows in unoptimised IR ----
# `x pred c` with an UNTYPED literal is `icmp pred (sext/zext iS x to i64), c`.
# The extension whose every use is such a compare (or a trunc back to iS) is
# dropped and the compare re-typed (case table in src/narrow.jl).  Oracle: the
# W-bit value v of x in T's signedness, compared as an integer against the
# literal the source wrote (Julia's mixed-type comparisons are mathematical).

const SL4H_LITS = (-130, -129, -128, -9, -8, -1, 0, 1, 5, 7, 8, 15, 16, 127, 128, 255, 256)
const SL4H_PROMO = Tuple{DataType,Symbol,Int,Function}[]
let n = 0
    for T in (Int8, UInt8), op in SL4H_CMP, c in SL4H_LITS
        fname = Symbol("sl4h_lit_", n += 1)
        f = @eval $fname(x::$T) = ifelse($op(x, $c), $(T(1)), $(T(0)))
        push!(SL4H_PROMO, (T, op, c, f))
    end
end

sl4h_trunc_back(x::Int8)  = ifelse(Int(x) < 3, Int(x) % Int8, Int8(0))
sl4h_trunc_backu(x::UInt8) = ifelse(Int(x) > 1, Int(x) % UInt8, 0x00)

# the former residual hole: the untyped literal no longer forces the fallback
sl4h_hole5(x::Int8)  = Int8(x * Int8(16) == 0)
sl4h_holeu(x::UInt8) = ifelse((x > 2) | (x * 0x10 == 0x00), 0x01, 0x00)

const SL4H_EXTEXT = Dict{Tuple{DataType,Symbol},Function}()
for T in (Int8, UInt8), op in SL4H_CMP
    SL4H_EXTEXT[(T, op)] = @eval (x::$T, y::$T) -> $T($op(Int(x), Int(y)))
end
sl4h_arith64(x::Int8) = Int8((Int(x) + 1) % Int8 == 0)
sl4h_sext_vs_zext(x::Int8, y::Int8) = Int8(Int(x) < Int(y % UInt8))
sl4h_sext_ult(x::Int8) = Int8(reinterpret(UInt64, Int64(x)) < UInt64(100))

@testset "Bennett-sl4h — bit_width narrows the unoptimised IR first" begin

@testset "witness: x * 16 == 0 at bit_width=6" begin
    oracle(v) = sl4h_wz(6, 16v) ? 1 : 0
    c, err = sl4h_compile(sl4h_mul16, Int8, 6, false)
    @test err === nothing
    @test c !== nothing && verify_reversibility(c)
    @test c !== nothing && sl4h_nbad(c, Int8, 6, oracle) == 0
    @test c !== nothing && Int(simulate(c, Int8, Int8(4))) == 1  # 4 * 16 == 0 mod 64
    # optimize=true: the optimised reading `(x & 15) == 0` disagrees (at x = 4)
    # with the unoptimised one — refused (Bennett-5y48 differential)
    c1, err1 = sl4h_compile(sl4h_mul16, Int8, 6, true)
    @test c1 === nothing && sl4h_is_diff(err1)
end

@testset "parsed-IR cache: shared entry on success, nothing cached on refusal" begin
    Bennett._clear_parsed_ir_cache!()
    # Bennett-5y48 (differential): each flag's entry is ITS reading — the
    # optimize=false entry holds the source's multiply, the optimize=true entry
    # the optimiser's mask (the compile cross-checks the two)
    p1 = Bennett._extract_parsed_ir_cached(sl4h_mul16, Tuple{Int8};
                                           optimize=true, bit_width=6)
    p0 = Bennett._extract_parsed_ir_cached(sl4h_mul16, Tuple{Int8};
                                           optimize=false, bit_width=6)
    @test p0 !== p1
    @test any(i -> i isa Bennett.IRBinOp && i.op === :mul,
              (i for b in p0.blocks for i in b.instructions))
    @test !any(i -> i isa Bennett.IRBinOp && i.op === :mul,
               (i for b in p1.blocks for i in b.instructions))
    # unoptimised attempt refused (`Int8(x == 5 ? 1 : 0)` merges in an i64
    # phi): the fallback result is cached under the optimize=true key only, and
    # the refused optimize=false attempt left no entry behind.  (`x == 5` itself
    # narrows unoptimised since Bennett-sl4h (a).)
    Bennett._clear_parsed_ir_cache!()
    q1 = Bennett._extract_parsed_ir_cached(sl4h_ieq5, Tuple{Int8};
                                           optimize=true, bit_width=6)
    @test haskey(Bennett._parsed_ir_cache, (sl4h_ieq5, Tuple{Int8}, true, :auto, 6))
    @test !haskey(Bennett._parsed_ir_cache, (sl4h_ieq5, Tuple{Int8}, false, :auto, 6))
    @test q1 === Bennett._extract_parsed_ir_cached(sl4h_ieq5, Tuple{Int8};
                                                   optimize=true, bit_width=6)
    @test_throws ArgumentError Bennett._extract_parsed_ir_cached(sl4h_ieq5, Tuple{Int8};
                                                   optimize=false, bit_width=6)
    # W == S re-types nothing: the optimised path, as before sl4h
    for f in (sl4h_mul16, sl4h_eq5)
        c8 = reversible_compile(f, Int8; bit_width=8, strategy=:expression)
        cold = reversible_compile(Bennett._narrow_ir(Bennett.extract_parsed_ir(
                   f, Tuple{Int8}; optimize=true), 8; optimized=true))
        @test c8.gates == cold.gates
    end
end

@testset "fallback trigger: refusals fall back, bugs propagate" begin
    @test Bennett._narrow_attempt_refused(ArgumentError("refusing to narrow"))
    @test Bennett._narrow_attempt_refused(ErrorException("ir_extract.jl: ... unsupported"))
    for e in (InterruptException(), MethodError(+, (1, "a")), BoundsError([1], 2),
              KeyError(:k), AssertionError("x"), UndefVarError(:y))
        @test !Bennett._narrow_attempt_refused(e)
    end
end

@testset "ordinary idioms still compile at optimize=true, right on all 2^W" begin
    for (desc, f, T, oracle) in SL4H_IDIOMS, W in (4, 6, 7)
        c, err = sl4h_compile(f, T, W, true)
        @test err === nothing
        err === nothing || (@info "sl4h idiom refused" desc W; continue)
        @test verify_reversibility(c)
        @test sl4h_nbad(c, T, W, oracle) == 0
    end
end

@testset "generated corpus: $(length(SL4H_CASES)) programs x W x optimize" begin
    n_acc = 0; n_unopt = 0; n_ref = 0
    differ = String[]; lost = String[]; wrong = String[]; unclean = String[]
    bad_err = String[]; diffref = String[]
    for (T, desc, ex, f) in SL4H_CASES, W in SL4H_WS
        cell = "$T $desc @W=$W"
        c0, e0 = sl4h_compile(f, T, W, false)
        c1, e1 = sl4h_compile(f, T, W, true)
        for e in (e0, e1)
            e === nothing || sl4h_is_refusal(e) ||
                push!(bad_err, "$cell: $(sprint(showerror, e))")
        end
        # Bennett-5y48 differential refusal: the unoptimised reading is right
        if e1 !== nothing && sl4h_is_diff(e1)
            push!(diffref, cell)
            (e0 === nothing && isempty(sl4h_mismatches(c0, ex, T, W))) ||
                push!(wrong, "$cell: differential refusal with a wrong unoptimised reading")
        end
        # (2) monotonicity against the pre-sl4h path
        e1 !== nothing && !sl4h_is_diff(e1) && sl4h_old_accepts(f, T, W) && push!(lost, cell)
        # (1) the unoptimised narrowing is accepted => optimize=true builds the
        # same circuit.  (Gates, not ParsedIR identity: this corpus overflows
        # the bounded parsed-IR cache, so an entry can be evicted and rebuilt
        # between the two compiles; identity is checked in the cache testset.)
        if e0 === nothing && W != 8
            n_unopt += 1
            (e1 === nothing && c0.gates == c1.gates &&
             c0.input_widths == c1.input_widths && c0.output_wires == c1.output_wires) ||
             (e1 !== nothing && sl4h_is_diff(e1)) ||
                push!(differ, cell)
        end
        if e1 !== nothing
            n_ref += 1
            continue
        end
        n_acc += 1
        verify_reversibility(c1) || push!(unclean, cell)
        bad = sl4h_mismatches(c1, ex, T, W)
        isempty(bad) || push!(wrong, "$cell wrong at patterns $(first(bad, 6))")
    end
    println("  sl4h corpus: $(length(SL4H_CASES)) programs, $(n_acc + n_ref) cells at ",
            "optimize=true: $n_acc accepted ($n_unopt via the unoptimised IR at W < 8), ",
            "$n_ref refused; $(length(wrong)) accepted-and-wrong")
    foreach(m -> println("    WRONG ", m), first(wrong, 20))
    foreach(m -> println("    DIFFER ", m), first(differ, 10))
    foreach(m -> println("    LOST ", m), first(lost, 10))
    foreach(m -> println("    BAD ERR ", m), first(bad_err, 5))
    @test isempty(differ)    # (1) unoptimised accepted => optimize=true is that circuit
    @test sort(diffref) == SL4H_DIFF_REFUSED   # (1) ... or the pinned differential refusals
    @test isempty(lost)      # (2) nothing the pre-sl4h path accepted is refused
    @test isempty(wrong)     # (3) accepted => right on every W-bit input
    @test isempty(unclean)   # (3) ... and every ancilla returns to zero
    @test isempty(bad_err)   # (4) a refusal is the narrowing ArgumentError
    @test n_acc >= 400       # non-vacuity
    @test n_unopt >= 300
end

@testset "promotion grid: T x pred x untyped literal x W in 2:7" begin
    tally = Dict(:acc => 0, :ref => 0, :wrong => 0)
    tally1 = Dict(:acc => 0, :ref => 0, :wrong => 0)
    wrong = String[]; unclean = String[]; bad_err = String[]; differ = String[]
    for (T, op, c, f) in SL4H_PROMO, W in 2:7
        cell = "$T x $op $c @W=$W"
        oracle(v) = getfield(Base, op)(v, c) ? 1 : 0
        c0, e0 = sl4h_compile(f, T, W, false)
        c1, e1 = sl4h_compile(f, T, W, true)
        for (circ, err, t) in ((c0, e0, tally), (c1, e1, tally1))
            if err !== nothing
                sl4h_is_refusal(err) || push!(bad_err, "$cell: $(sprint(showerror, err))")
                t[:ref] += 1
                continue
            end
            t[:acc] += 1
            verify_reversibility(circ) || push!(unclean, cell)
            if sl4h_nbad(circ, T, W, oracle) != 0
                t[:wrong] += 1
                push!(wrong, cell)
            end
        end
        # unoptimised accepted => optimize=true is that very circuit
        e0 === nothing && !(e1 === nothing && c0.gates == c1.gates) &&
            push!(differ, cell)
    end
    println("  sl4h promotion grid ($(length(SL4H_PROMO)) programs x 6 W): ",
            "optimize=false $(tally[:acc]) accepted / $(tally[:ref]) refused / ",
            "$(tally[:wrong]) wrong; optimize=true $(tally1[:acc]) / $(tally1[:ref]) / ",
            "$(tally1[:wrong])")
    foreach(m -> println("    WRONG ", m), first(wrong, 20))
    foreach(m -> println("    BAD ERR ", m), first(bad_err, 5))
    @test isempty(wrong)
    @test isempty(unclean)
    @test isempty(bad_err)
    @test isempty(differ)
    @test tally[:acc] >= 600        # non-vacuity (measured at landing: see worklog)
end

@testset "promotion: both sides extended (ext/ext), all 2^(2W) inputs" begin
    n_acc = 0
    for T in (Int8, UInt8), op in SL4H_CMP, W in (2, 3, 4)
        f = SL4H_EXTEXT[(T, op)]
        pir = Bennett.extract_parsed_ir(f, Tuple{T, T}; optimize=false)
        casts = [i for b in pir.blocks for i in b.instructions if i isa Bennett.IRCast &&
                 i.op in (:sext, :zext) && i.to_width == 64]
        @test length(casts) == 2                       # the shape under test
        c, err = try
            reversible_compile(f, T, T; bit_width=W, optimize=false), nothing
        catch e
            e isa ArgumentError || rethrow(); nothing, e
        end
        @test err === nothing
        err === nothing || continue
        n_acc += 1
        @test verify_reversibility(c)
        nbad = count(((p, q),) -> (Int(simulate(c, T, (sl4h_in(T, p), sl4h_in(T, q)))) &
                                   sl4h_wmask(W)) !=
                                  Int(getfield(Base, op)(sl4h_norm(T, p, W), sl4h_norm(T, q, W))),
                     Iterators.product(0:sl4h_wmask(W), 0:sl4h_wmask(W)))
        @test nbad == 0
    end
    @test n_acc == 2 * 6 * 3
end

@testset "promotion: trunc back to iS is the identity" begin
    for (f, T, oracle) in ((sl4h_trunc_back, Int8, v -> v < 3 ? v : 0),
                           (sl4h_trunc_backu, UInt8, v -> v > 1 ? v : 0)), W in (3, 4, 6, 7)
        pir = Bennett.extract_parsed_ir(f, Tuple{T}; optimize=false)
        @test any(i -> i isa Bennett.IRCast && i.op === :trunc && i.from_width == 64,
                  (i for b in pir.blocks for i in b.instructions))
        for optimize in (false, true)
            c, err = sl4h_compile(f, T, W, optimize)
            @test err === nothing
            @test c !== nothing && verify_reversibility(c)
            @test c !== nothing && sl4h_nbad(c, T, W, oracle) == 0
        end
    end
end

@testset "promotion: uses outside the allowlist keep the refusal" begin
    msg = "second data domain"
    # i64 arithmetic on the promoted value
    @test_throws msg reversible_compile(sl4h_arith64, Int8;
                                        bit_width=4, optimize=false)
    # i64 phi (Int8(x == 5 ? 1 : 0)), iseven's i64 srem, the overshift guard
    for (f, T) in ((sl4h_ieq5, Int8), (sl4h_even, Int8))
        @test sl4h_unopt_pir(f, T, 6) === nothing
    end
    # sext compared to a zext: not a same-kind pair
    @test_throws msg reversible_compile(sl4h_sext_vs_zext,
                                        Int8, Int8; bit_width=4, optimize=false)
    # an unsigned order on a sign extension, constant outside its W-bit image:
    # the image straddles the constant, so no constant fold exists
    @test_throws "two runs around" reversible_compile(sl4h_sext_ult, Int8;
        bit_width=4, optimize=false)
end

@testset "ordinary idioms: which path they take now" begin
    for (desc, f, T, oracle) in SL4H_IDIOMS, W in (4, 6)
        p0 = sl4h_unopt_pir(f, T, W)
        unopt = p0 !== nothing
        println("  idiom $desc @W=$W: ", unopt ? "unoptimised path" : "fallback")
        # x == 5 and UInt8 x > 2 narrow unoptimised now; iseven (i64 srem),
        # the i64 phi and the overshift arm still fall back
        @test unopt == (desc in ("x == 5", "UInt8 x > 2"))
        if unopt
            c0 = reversible_compile(f, T; bit_width=W, optimize=false)
            c1 = reversible_compile(f, T; bit_width=W, optimize=true)
            @test c0.gates == c1.gates
        end
    end
end

@testset "former residual hole: both readings accepted, they disagree -> refused" begin
    # Bennett-sl4h (a) made the unoptimised reading accept these (and it is
    # right); the optimised reading holds the S-bit fold and is wrong, so the
    # Bennett-5y48 differential refuses them at optimize=true.
    for (f, T, Ws, oracle) in (
            (sl4h_hole,  Int8,  (6,),      (v, W) -> ((v == 5) | sl4h_wz(W, 16v)) ? 1 : 0),
            (sl4h_hole5, Int8,  (5, 6, 7), (v, W) -> sl4h_wz(W, 16v) ? 1 : 0),
            (sl4h_holeu, UInt8, (5,),      (v, W) -> ((v > 2) | sl4h_wz(W, 16v)) ? 1 : 0)),
        W in Ws
        @test sl4h_unopt_pir(f, T, W) !== nothing     # no fallback any more
        c, err = sl4h_compile(f, T, W, false)          # the unoptimised reading: right
        @test err === nothing
        @test c !== nothing && verify_reversibility(c)
        @test c !== nothing && sl4h_nbad(c, T, W, v -> oracle(v, W)) == 0
        c1, err1 = sl4h_compile(f, T, W, true)
        @test c1 === nothing && sl4h_is_diff(err1)
    end
end

end # @testset Bennett-sl4h
