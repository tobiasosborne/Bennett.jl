# Bennett-mrhg — `bit_width` narrowing (src/narrow.jl) is an ALLOWLIST, and
# everything outside it must fail LOUD rather than return a plausible-looking
# wrong circuit.
#
# THE DEFECT (Astra 2026-09-26 B-lowering F3 + F13, re-verified in
# B-lowering.verification.md).  `_narrow_ir` rewrote EVERY width in the
# already-extracted ParsedIR from the source scalar width S (8 for Int8) to W,
# but the values and *guards* the Julia front end bakes into that IR are
# expressed at the SOURCE width:
#
#   * `Int8(1) << x` at W=4, optimize=false returned [0,0,0,0,0] and
#     optimize=true returned 1 for x=4 — both `verify_reversibility == true`.
#     The IR compares the Int64-promoted shift amount against the *source*
#     constant 8 and shifts by a runtime amount; the barrel shifter only
#     consumes the low ceil(log2 W) bits.
#   * `x >> 1` at W=3/W=4, optimize=false died inside `lower_ashr!` with
#     "constant shift k=7 out of [0, W]" (the sign-fill `ashr x, 7` guard).
#   * `Int8(1) << x` at bit_width == 8 (== the natural width, so NO data width
#     changes at all) returned 0 for x=1 instead of 2: the i64
#     `icmp sle typemin(Int64), sext(x)` undef-guard has its constant re-typed
#     to `sle 0, x`, which then fires for every x >= 0.
#   * a 2-tuple return `(x, x+1)` at W=4 died deep inside lowering
#     (`_lower_store_via_shadow!: idx=2 out of range [0, 2)` at optimize=false,
#     `resolve!: ... length(wires)=8 but caller advertised width=4` at
#     optimize=true): the packed aggregate layout and the uniform width
#     rewrite disagree.
#
# THE CONTRACT PINNED HERE.  Narrowing re-types a function to W-bit
# two's-complement MODULAR semantics:
#
#   * the W-bit input pattern is a W-bit two's-complement value (the sign bit
#     is at W-1; it is the sign/zero-extension of that pattern that the source
#     type sees);
#   * every arithmetic step happens AT W bits and is reduced mod 2^W, so an
#     out-of-range literal is first reduced mod 2^W and every value that flows
#     onward is a W-bit value;
#   * shifts are W-bit shifts.  A shift amount is a COUNT, not data, so it is
#     only reinterpretable while 0 <= k <= W (see `_narrow_inst(::IRBinOp)`);
#   * comparisons are W-bit comparisons of W-bit operands, in the operands'
#     signedness, against a constant that still fits in W bits.
#
# A function whose operations do not commute with truncation to W bits (a
# runtime shift amount, division, a source-width limit such as
# `typemin(Int8)`, a widening cast, a bit count, an aggregate return, memory, a
# loop) has NO sound W-bit meaning, so the compile must throw `ArgumentError`
# naming Bennett-mrhg.  It must never return a wrong circuit.
#
# SCOPE OF THE CLAIM (stated so the tests below are not read as more than they
# are).  The contract is about the value of what the circuit computes relative
# to the ParsedIR that `extract_parsed_ir(f, T; optimize)` produced.  Width-
# dependent rewrites the LLVM optimizer has ALREADY made at the source width
# (e.g. folding `x < x & 3` to a constant) are upstream of `_narrow_ir` and
# cannot be undone by it; the corpus below is therefore restricted to functions
# whose extracted IR is a faithful rendering of the source in both optimization
# modes (checked by extraction, not assumed — see the `optimize=false` cells).
#
# Every accepted circuit is compared against an oracle written independently of
# the compiler (plain `Int` arithmetic, masked/sign-extended to W bits after
# every step) over the WHOLE 2^W input domain, and additionally checked with
# `verify_reversibility` (CLAUDE.md §3/§4).  At W = 8 the oracle is the native
# Julia function over all 256 inputs.

using Test
using Bennett
using Bennett: ParsedIR, IRBasicBlock, IRInst, IRBinOp, IRICmp, IRCast, IRRet,
                SSAOperand, ConstOperand, ssa, iconst

# ---- the W-bit oracle toolkit (independent of src/) ------------------------

"2^W - 1: the W-bit mask."
wmask(W::Int) = (1 << W) - 1

"Reduce a value to its W-bit pattern (W-bit two's-complement modular arithmetic)."
wwrap(v::Integer, W::Int) = mod(v, 1 << W)

"Interpret a W-bit pattern as a W-bit two's-complement value (sign bit at W-1)."
wsign(p::Integer, W::Int) = p >= (1 << (W - 1)) ? p - (1 << W) : p

"A source-typed circuit input carrying the bit pattern `p` (sign/zero-extended)."
srcin(::Type{Int8}, p::Integer)  = reinterpret(Int8, UInt8(p & 0xff))
srcin(::Type{UInt8}, p::Integer) = UInt8(p & 0xff)

# ---- compile + classify ----------------------------------------------------

"""
    mrhg_compile(f, T...; bit_width, optimize, kwargs...)

Return `(circuit, nothing)` on success or `(nothing, err)` when the compile
threw.  A non-`ArgumentError` is rethrown: a narrowing refusal must be a
loud, typed error, not an arbitrary crash.
"""
function mrhg_compile(f, T...; bit_width, optimize, kwargs...)
    return try
        (reversible_compile(f, T...; bit_width, optimize, strategy=:expression,
                            kwargs...), nothing)
    catch e
        e isa ArgumentError || rethrow()
        (nothing, e)
    end
end

"Does this rejection name the bead (i.e. is it a narrowing refusal)?"
is_mrhg_rejection(e) =
    occursin("Bennett-mrhg", e isa ArgumentError ? e.msg : string(e))

# ---- the accepted corpus ----------------------------------------------------
#
# `(name, f, T, oracle)`, where `oracle(p, W)` is the expected W-bit OUTPUT
# PATTERN for the W-bit input pattern `p` (or `nothing` for the rare inputs
# where the W-bit semantics of the function is undefined, e.g. a negative
# shift amount, which Julia's `<<` does not define).

# add / sub with a literal (the literal is reduced mod 2^W, like any data).
mrhg_add1(x::Int8) = x + Int8(1)
mrhg_sub5(x::Int8) = x - Int8(5)
oracle_add1(p, W) = wwrap(wsign(p, W) + 1, W)
oracle_sub5(p, W) = wwrap(wsign(p, W) - 5, W)

# mul with two SSA operands, and a 3-term polynomial (mul + add + add).
mrhg_sq(x::UInt8)   = x * x
mrhg_poly(x::Int8) = x * x + Int8(3) * x + Int8(1)
oracle_sq(p, W)   = wwrap(p * p, W)
function oracle_poly(p, W)
    s = wsign(p, W)
    return wwrap(wwrap(wwrap(s * s, W) + wwrap(3 * s, W), W) + 1, W)
end

# the bitwise trio at data width
mrhg_band(x::UInt8) = x & UInt8(0x0f)
mrhg_bor(x::UInt8)  = x | UInt8(0x03)
mrhg_bxor(x::UInt8) = x ⊻ UInt8(0x5a)
oracle_band(p, W) = wwrap(p & 0x0f, W)
oracle_bor(p, W)  = wwrap(p | 0x03, W)
oracle_bxor(p, W) = wwrap(p ⊻ 0x5a, W)

# constant left shift (k = 1 is in range at every W; k = 3 only for W >= 3)
mrhg_shl1(x::Int8) = x << 1
mrhg_shl3(x::Int8) = x << 3
oracle_shl1(p, W) = wwrap(p << 1, W)
oracle_shl3(p, W) = wwrap(p << 3, W)

# constant right shift, logical (UInt8) and arithmetic (Int8).  Julia's
# unoptimised front end emits the sign-fill guard `ashr x, 7` next to the
# signed shift; that guard is a SOURCE-width constant, so it is refused for
# W < 8 instead of being silently re-typed.
mrhg_lshr2(x::UInt8) = x >>> 2
mrhg_ashr1(x::Int8)  = x >> 1
oracle_lshr2(p, W) = wwrap(wwrap(p, W) >> 2, W)
oracle_ashr1(p, W) = wwrap(wsign(p, W) >> 1, W)

# abs: icmp + select + sub (a cmov-shaped lowering, not a branch)
mrhg_abs(x::Int8) = abs(x)
function oracle_abs(p, W)
    s = wsign(p, W)
    return wwrap(s < 0 ? -s : s, W)
end

# ifelse: icmp + i1 xor + select over two different arithmetic arms
mrhg_ifelse3(x::Int8) = ifelse(x < Int8(0), x * Int8(3), x + Int8(1))
function oracle_ifelse3(p, W)
    s = wsign(p, W)
    return wwrap(s < 0 ? wwrap(3 * s, W) : wwrap(s + 1, W), W)
end

# icmp eq + `zext i1 -> iS` (the Bool-to-integer cast Julia emits for `?:`)
mrhg_eq1(x::Int8) = Int8(x == Int8(1) ? 1 : 0)
oracle_eq1(p, W) = wwrap(p == wwrap(1, W) ? 1 : 0, W)

# a real CFG: branch on a comparison, join through an iS phi
function mrhg_join(x::Int8)
    if x < Int8(0)
        y = -x
    else
        y = x * Int8(2)
    end
    return y
end
function oracle_join(p, W)
    s = wsign(p, W)
    return wwrap(s < 0 ? wwrap(-s, W) : wwrap(2 * s, W), W)
end

# an early-return CFG: one comparison, TWO `ret` terminators (the multi-return
# merge in `lower`, not a phi)
function mrhg_branch2(x::Int8)
    if x < Int8(0)
        return -x
    else
        return x * Int8(3)
    end
end
function oracle_branch2(p, W)
    s = wsign(p, W)
    return wwrap(s < 0 ? wwrap(-s, W) : wwrap(3 * s, W), W)
end

# a constant return (`ret <const>`), independent of the input
mrhg_constret(x::Int8) = x < Int8(0) ? Int8(1) : Int8(1)
oracle_constret(p, W) = wwrap(1, W)

# two-argument data flow (both arguments at the same source width S)
mrhg_add2(x::Int8, y::Int8) = x + y
mrhg_mulp(x::Int8, y::Int8) = x * y + Int8(1)
oracle_add2(p, q, W) = wwrap(wsign(p, W) + wsign(q, W), W)
oracle_mulp(p, q, W) = wwrap(wwrap(wsign(p, W) * wsign(q, W), W) + 1, W)

# All ten icmp predicates against an INDEPENDENT second argument (independent
# inputs are what keeps the optimizer from applying a width-dependent rewrite
# before the narrowing pass ever sees the IR).  `sgt/sge/ugt/uge` appear as the
# commuted `slt(1,x)` / `ule(1,x)` forms, which `lower_icmp!` normalises.
function mrhg_preds10(x::Int8, y::Int8)
    a = ifelse(x <  y, Int8(1),  Int8(0))
    b = ifelse(x <= y, Int8(2),  a)
    c = ifelse(x >  y, Int8(3),  b)
    d = ifelse(x >= y, Int8(4),  c)
    e = ifelse(x == y, Int8(5),  d)
    f = ifelse(x != y, Int8(6),  e)
    ux = reinterpret(UInt8, x)
    uy = reinterpret(UInt8, y)
    g = ifelse(ux <  uy, Int8(7),  f)
    h = ifelse(ux >  uy, Int8(8),  g)
    i = ifelse(ux <= uy, Int8(9),  h)
    return ifelse(ux >= uy, Int8(10), i)
end
function oracle_preds10(p, q, W)
    s = wsign(p, W)
    t = wsign(q, W)
    u = wwrap(p, W)
    v = wwrap(q, W)
    # each `ifelse` overwrites the previous value only when its own predicate
    # holds, so the chain is evaluated in SOURCE order
    r = (s <  t) ? 1  : 0
    r = (s <= t) ? 2  : r
    r = (s >  t) ? 3  : r
    r = (s >= t) ? 4  : r
    r = (s == t) ? 5  : r
    r = (s != t) ? 6  : r
    r = (u <  v) ? 7  : r
    r = (u >  v) ? 8  : r
    r = (u <= v) ? 9  : r
    r = (u >= v) ? 10 : r
    return wwrap(r, W)
end

# ---- the bead witnesses ----------------------------------------------------

# F3-1/F3-2: the shift-amount guard.  `Int8(1) << x` promotes the amount to
# Int64, so the IR carries `icmp slt/ule/ugt` against typemin/typemax/8 in a
# 64-bit domain plus a runtime barrel shift.
mrhg_w_shl1(x::Int8)   = Int8(1) << x
mrhg_w_shl3(x::Int8)   = Int8(3) << x
mrhg_w_shr1(x::Int8)   = x >> 1
# F13: aggregate return.
mrhg_w_tup(x::Int8)    = (x, x + Int8(1))
mrhg_w_tup3(x::Int8)   = (x, x + Int8(1), x * Int8(2))
# A scalar-memory function: a global Ref store + load.  optimize=false keeps
# the store/load shape; optimize=true promotes it to a plain `add`, which
# legitimately narrows.
const MRHG_G = Ref{Int8}(0)
function mrhg_w_mem(x::Int8)
    MRHG_G[] = x
    return MRHG_G[] + Int8(1)
end
# Runtime shift amount.
mrhg_w_vshl(x::Int8, n::Int8) = x << n
# Signed division / remainder.
mrhg_w_sdiv(x::Int8, y::Int8) = x ÷ y
# A comparison against the source type's own limit: re-typing -128 at W=3
# yields 0, which silently INVERTS the test.
mrhg_w_tmin(x::Int8) = x > typemin(Int8) ? Int8(1) : Int8(0)
# A widening cast: Int16 arithmetic is a second data domain that a uniform
# width rewrite corrupts (provably wrong in one optimization mode).
mrhg_w_widen(x::Int8) = (Int16(x) * Int16(x) > Int16(200)) ? Int8(1) : Int8(0)
# A loop: unrolling at the source width is not the same computation at W.
function mrhg_w_loop(x::Int8)
    s = Int8(0)
    i = Int8(0)
    while i < x
        s += i
        i += Int8(1)
    end
    return s
end
# Bit counting: an unrolled body that shifts by each source bit index and
# returns a 64-bit value.
mrhg_w_popc(x::UInt8) = count_ones(x)
# A mixed-sign argument list (no single source width to re-type to).
mrhg_w_mixed(x::Int8, y::Int16) = x < Int8(1) ? Int8(1) : Int8(0)

# =============================================================================
@testset "Bennett-mrhg — bit_width narrowing soundness contract" begin

# -----------------------------------------------------------------------------
@testset "the W-bit oracle agrees with NATIVE Julia at W = 8" begin
    # Self-check of the oracle itself: at W = S the W-bit semantics IS the
    # source semantics, so every oracle below must reproduce the native
    # function on the full 8-bit domain.  (An oracle that drifts from native
    # would make every other testset in this file meaningless.)
    for (name, f, T, oracle) in (("add1", mrhg_add1, Int8, oracle_add1),
                              ("sub5", mrhg_sub5, Int8, oracle_sub5),
                              ("poly", mrhg_poly, Int8, oracle_poly),
                              ("band", mrhg_band, UInt8, oracle_band),
                              ("bor", mrhg_bor, UInt8, oracle_bor),
                              ("bxor", mrhg_bxor, UInt8, oracle_bxor),
                              ("shl1", mrhg_shl1, Int8, oracle_shl1),
                              ("shl3", mrhg_shl3, Int8, oracle_shl3),
                              ("lshr2", mrhg_lshr2, UInt8, oracle_lshr2),
                              ("ashr1", mrhg_ashr1, Int8, oracle_ashr1),
                              ("abs", mrhg_abs, Int8, oracle_abs),
                              ("ifelse3", mrhg_ifelse3, Int8, oracle_ifelse3),
                              ("eq1", mrhg_eq1, Int8, oracle_eq1),
                              ("join", mrhg_join, Int8, oracle_join),
                              ("branch2", mrhg_branch2, Int8, oracle_branch2),
                              ("constret", mrhg_constret, Int8, oracle_constret),
                              ("sq", mrhg_sq, UInt8, oracle_sq))
        @testset "$name" begin
            for p in 0:255
                @test oracle(p, 8) == wwrap(Int(f(srcin(T, p))), 8)
            end
        end
    end
    for (name, f, oracle) in (("add2", mrhg_add2, oracle_add2),
                              ("mulp", mrhg_mulp, oracle_mulp),
                              ("preds10", mrhg_preds10, oracle_preds10))
        @testset "$name" begin
            for p in 0:255, q in 0:255
                @test oracle(p, q, 8) ==
                      wwrap(Int(f(srcin(Int8, p), srcin(Int8, q))), 8)
            end
        end
    end
end

# -----------------------------------------------------------------------------
@testset "exhaustive W-bit contract, W = 2:7, both optimization modes" begin
    # (name, f, T, oracle, Ws-required, opts-required).  The "required" lists
    # pin that the allowlist is not vacuous: every accepted instruction kind
    # must be accepted somewhere and verified exhaustively.  Cells outside them
    # are still checked — they must be correct OR refused with a Bennett-mrhg
    # ArgumentError.
    corpus = [
        ("add1",    mrhg_add1,   Int8,  oracle_add1,   2:7, (false, true)),
        ("sub5",    mrhg_sub5,   Int8,  oracle_sub5,   2:7, (false, true)),
        ("sq",      mrhg_sq,     UInt8, oracle_sq,     2:7, (false, true)),
        ("poly",    mrhg_poly,   Int8,  oracle_poly,   2:7, (false, true)),
        ("band",    mrhg_band,   UInt8, oracle_band,   2:7, (false, true)),
        ("bor",     mrhg_bor,    UInt8, oracle_bor,    2:7, (false, true)),
        ("bxor",    mrhg_bxor,   UInt8, oracle_bxor,   2:7, (false, true)),
        ("shl1",    mrhg_shl1,   Int8,  oracle_shl1,   2:7, (false, true)),
        ("lshr2",   mrhg_lshr2,  UInt8, oracle_lshr2,  2:7, (false, true)),
        ("ifelse3", mrhg_ifelse3, Int8, oracle_ifelse3, 2:7, (false, true)),
        ("join",    mrhg_join,   Int8,  oracle_join,   2:7, (false, true)),
        ("branch2", mrhg_branch2, Int8, oracle_branch2, 2:7, (false, true)),
        ("constret", mrhg_constret, Int8, oracle_constret, 2:7, (false, true)),
        # a shift amount is a COUNT: 3 is in range only for W >= 3
        ("shl3",    mrhg_shl3,   Int8,  oracle_shl3,   3:7, (false, true)),
        # the unoptimised `x == 1 ? 1 : 0` compares in an i64 domain
        # (`sext i8 -> i64`), which the allowlist refuses
        ("eq1",     mrhg_eq1,    Int8,  oracle_eq1,    2:7, (true,)),
        # `abs`/`x >> 1` unoptimised carry the sign-fill guard `ashr x, 7`
        ("ashr1",   mrhg_ashr1,  Int8,  oracle_ashr1,  2:7, (true,)),
        ("abs",     mrhg_abs,    Int8,  oracle_abs,    2:7, (true,)),
    ]

    n_accepted = 0
    n_rejected = 0
    refused = String[]
    accepted_cells = Set{Tuple{String,Int,Bool}}()
    missing_cells = String[]
    wrong_cells = String[]
    n_verified = 0
    for (name, f, T, oracle, needW, needopt) in corpus, W in 2:7,
        optimize in (false, true)
        c, err = mrhg_compile(f, T; bit_width=W, optimize)
        if err !== nothing
            n_rejected += 1
            push!(refused, "$name@W=$W,opt=$optimize")
            # A refusal must be a narrowing refusal, not an unrelated crash.
            @test is_mrhg_rejection(err)
            (optimize in needopt && W in needW) &&
                push!(missing_cells, "$name@W=$W,opt=$optimize")
            continue
        end
        n_accepted += 1
        push!(accepted_cells, (name, W, optimize))
        # CLAUDE.md §4: EVERY accepted cell — required or not — is checked
        # against the oracle on every W-bit input, plus the reversibility
        # invariant.  The required matrix only decides which cells MUST
        # compile; an optional cell that compiles is a claim of correctness
        # like any other (Bennett-m11m: it used to be counted as accepted
        # with no check at all).
        @test c.output_elem_widths == [W]
        @test verify_reversibility(c)
        bad = Int[]
        for p in 0:wmask(W)
            want = oracle(p, W)
            want === nothing && continue
            (simulate(c, T, srcin(T, p)) & wmask(W)) == want || push!(bad, p)
        end
        isempty(bad) || push!(wrong_cells,
                              "$name@W=$W,opt=$optimize inputs $(first(bad, 6))")
        @test isempty(bad)
        n_verified += 1
    end
    println("  mrhg narrowing cells: $n_accepted accepted, $n_rejected refused " *
            "(must-accept cells missing: $missing_cells; WRONG: $wrong_cells)")
    println("  mrhg refused cells: $(join(refused, " "))")

    # The allowlist must be a real allowlist, not "reject everything": pin the
    # (kind, cell) pairs that must have been accepted AND verified above.
    @test isempty(missing_cells)
    @test isempty(wrong_cells)
    @test n_verified == n_accepted          # Bennett-m11m: no unchecked acceptance
    @test n_accepted >= 100
    @test n_rejected > 0
    for cell in (("add1", 4, false), ("sub5", 2, true), ("sq", 4, true),
                 ("poly", 6, false), ("band", 2, true), ("bor", 3, false),
                 ("bxor", 6, false), ("shl1", 3, true), ("lshr2", 5, false),
                 ("ifelse3", 7, true), ("join", 3, false),
                 ("branch2", 2, false), ("branch2", 5, true),
                 ("constret", 4, false), ("constret", 6, true),
                 ("shl3", 4, true),
                 ("eq1", 2, true), ("ashr1", 6, true), ("abs", 3, true))
        @test cell in accepted_cells
    end
end

# -----------------------------------------------------------------------------
@testset "two-argument data flow + all ten icmp predicates (W = 2:4)" begin
    for W in 2:4
        for (f, oracle) in ((mrhg_add2, oracle_add2), (mrhg_mulp, oracle_mulp),
                            (mrhg_preds10, oracle_preds10))
            for optimize in (false, true)
                c, err = mrhg_compile(f, Int8, Int8; bit_width=W, optimize)
                @test err === nothing
                if err === nothing
                    @test c.output_elem_widths == [W]
                    @test verify_reversibility(c)
                    for p in 0:wmask(W), q in 0:wmask(W)
                        @test (simulate(c, Int8, (srcin(Int8, p), srcin(Int8, q))) &
                               wmask(W)) == oracle(p, q, W)
                    end
                end
            end
        end
    end
end

# -----------------------------------------------------------------------------
@testset "W = 8 (the natural width) must equal NATIVE Julia, exhaustively" begin
    # bit_width=8 is not a no-op: `_narrow_ir` still re-types every width, and
    # the front end's source-width guards (typemin/typemax/8) are re-typed with
    # them.  An IR that only lives in the i8/i1 domains must reproduce the
    # native function on ALL 256 inputs; anything else must be refused loudly.
    for (name, f) in (("add1", mrhg_add1), ("sub5", mrhg_sub5),
                      ("poly", mrhg_poly), ("shl1", mrhg_shl1),
                      ("shl3", mrhg_shl3), ("ashr1", mrhg_ashr1),
                      ("abs", mrhg_abs), ("ifelse3", mrhg_ifelse3),
                      ("join", mrhg_join), ("branch2", mrhg_branch2),
                      ("constret", mrhg_constret), ("eq1", mrhg_eq1))
        for optimize in (false, true)
            c, err = mrhg_compile(f, Int8; bit_width=8, optimize)
            if err !== nothing
                @test is_mrhg_rejection(err)
                continue
            end
            @test verify_reversibility(c)
            for x in typemin(Int8):typemax(Int8)
                @test simulate(c, Int8, x) == f(x)
            end
        end
    end
    for (name, f) in (("sq", mrhg_sq), ("lshr2", mrhg_lshr2),
                      ("band", mrhg_band), ("bor", mrhg_bor), ("bxor", mrhg_bxor))
        for optimize in (false, true)
            c, err = mrhg_compile(f, UInt8; bit_width=8, optimize)
            if err !== nothing
                @test is_mrhg_rejection(err)
                continue
            end
            @test verify_reversibility(c)
            for x in UInt8(0):UInt8(255)
                @test simulate(c, UInt8, x) == f(x)
            end
        end
    end
end

# -----------------------------------------------------------------------------
@testset "casts: trunc/sext/zext between the iS and i1 domains" begin
    # The Julia front end only reaches `trunc iS -> i1` / `sext i1 -> iS` in
    # shapes that also carry a source-width guard, so the cast round-trip is
    # pinned directly on a hand-built ParsedIR (the same style as the other
    # narrow.jl unit tests) and then lowered to a real circuit.
    # (x & 1) truncated to one bit, zero-extended back, then xored with 2.
    cast_p = ParsedIR(8, [(:x, 8)],
        [IRBasicBlock(:entry, IRInst[
            IRBinOp(:t, :and, ssa(:x), iconst(1), 8),
            IRCast(:b, :trunc, ssa(:t), 8, 1),
            IRCast(:r, :zext, ssa(:b), 1, 8),
            IRBinOp(:o, :xor, ssa(:r), iconst(2), 8)],
            IRRet(ssa(:o), 8))], [8])
    for W in 2:6
        c = reversible_compile(Bennett._narrow_ir(cast_p, W))
        @test verify_reversibility(c)
        for p in 0:wmask(W)
            @test (simulate(c, Int8, Int8(p)) & wmask(W)) == wwrap((p & 1) ⊻ 2, W)
        end
    end
    # sext of a one-bit comparison result: the W-bit value is 0 or all-ones.
    sext_p = ParsedIR(8, [(:x, 8)],
        [IRBasicBlock(:entry, IRInst[
            IRICmp(:c, :slt, ssa(:x), iconst(0), 8),
            IRCast(:s, :sext, ssa(:c), 1, 8)],
            IRRet(ssa(:s), 8))], [8])
    for W in 2:6
        c = reversible_compile(Bennett._narrow_ir(sext_p, W))
        @test verify_reversibility(c)
        for p in 0:wmask(W)
            want = wsign(p, W) < 0 ? wmask(W) : 0
            @test (simulate(c, Int8, Int8(p)) & wmask(W)) == want
        end
    end
    # A cast to a SECOND scalar width (i8 -> i16) is not reinterpretable: the
    # widened side is a second data domain, not a W-bit re-typing of the i8
    # domain — even when the value is truncated straight back to i8.  (The
    # surrounding IR is a legal single-scalar-return function, so it is the
    # CAST rule that refuses it, not the return-layout rule.)
    widen_p = ParsedIR(8, [(:x, 8)],
        [IRBasicBlock(:entry, IRInst[
            IRCast(:s, :sext, ssa(:x), 8, 16),
            IRCast(:t, :trunc, ssa(:s), 16, 8)],
            IRRet(ssa(:t), 8))], [8])
    @test_throws ArgumentError Bennett._narrow_ir(widen_p, 4)
    err_widen = try
        Bennett._narrow_ir(widen_p, 4); nothing
    catch e
        e
    end
    @test is_mrhg_rejection(err_widen)
    @test err_widen isa ArgumentError && occursin("i16", err_widen.msg)
end

# -----------------------------------------------------------------------------
@testset "bead witnesses: correct on every input, or a loud refusal" begin
    # F3-1: `Int8(1) << x`, W = 2:7, both modes.  The unoptimised form
    # returned all-zeros; the optimized form returned 1 for x = 4 at W = 4.
    for W in 2:7, optimize in (false, true)
        c, err = mrhg_compile(mrhg_w_shl1, Int8; bit_width=W, optimize)
        if err !== nothing
            @test is_mrhg_rejection(err)
        else
            @test verify_reversibility(c)
            for p in 0:wmask(W)
                s = wsign(p, W)
                (s < 0 || s >= W) && continue      # Julia's `<<` is undefined here
                @test (simulate(c, Int8, Int8(p)) & wmask(W)) == wwrap(1 << s, W)
            end
        end
    end

    # F3-3 (the bead's "stronger check"): bit_width=8 changes NOTHING about the
    # data widths, yet the pre-fix circuit returned 0 for f(1) instead of 2.
    for optimize in (false, true)
        c, err = mrhg_compile(mrhg_w_shl1, Int8; bit_width=8, optimize)
        if err !== nothing
            @test is_mrhg_rejection(err)
        else
            @test verify_reversibility(c)
            @test simulate(c, Int8, Int8(1)) == Int8(2)
            for x in typemin(Int8):typemax(Int8)
                k = Int(x)
                @test simulate(c, Int8, x) ==
                      (k < 0 || k >= 8 ? Int8(0) : Int8(1) << k)
            end
        end
    end

    # F3-2: `x >> 1` at W = 2..7 (pre-fix: "constant shift k=7 out of [0, W]"
    # from deep inside lower_ashr! at optimize=false).  Accepting it is fine,
    # but then it must be RIGHT.
    for W in 2:7, optimize in (false, true)
        c, err = mrhg_compile(mrhg_w_shr1, Int8; bit_width=W, optimize)
        if err !== nothing
            @test is_mrhg_rejection(err)
        else
            @test verify_reversibility(c)
            for p in 0:wmask(W)
                @test (simulate(c, Int8, Int8(p)) & wmask(W)) == oracle_ashr1(p, W)
            end
        end
    end

    # F13: the tuple return.  Pre-fix this surfaced as two unrelated internal
    # errors; it must now be one loud narrowing refusal.
    for f in (mrhg_w_tup, mrhg_w_tup3), W in (4, 8), optimize in (false, true)
        c, err = mrhg_compile(f, Int8; bit_width=W, optimize)
        @test c === nothing
        @test err isa ArgumentError
        @test err !== nothing && is_mrhg_rejection(err)
    end
end

# -----------------------------------------------------------------------------
@testset "rejection battery: memory, runtime shifts, division, loops, ..." begin
    # A scalar-memory function (global store + load) at optimize=false.
    for W in (4, 8)
        c, err = mrhg_compile(mrhg_w_mem, Int8; bit_width=W, optimize=false)
        @test c === nothing
        @test err isa ArgumentError && is_mrhg_rejection(err)
    end
    # ... and once the front end promotes it to a plain `add` it must compile
    # and be right: the allowlist is not "reject anything that ever touched
    # memory", it is "reject IR with a layout the rewrite would corrupt".
    c_mem, err_mem = mrhg_compile(mrhg_w_mem, Int8; bit_width=4, optimize=true)
    @test err_mem === nothing
    if err_mem === nothing
        @test verify_reversibility(c_mem)
        for p in 0:wmask(4)
            @test (simulate(c_mem, Int8, Int8(p)) & wmask(4)) == oracle_add1(p, 4)
        end
    end

    # Runtime shift amount (the barrel shifter implements `amount mod
    # 2^ceil(log2 W)`, not Julia's saturating W-bit `<<`).
    for W in (4, 8), optimize in (false, true)
        c, err = mrhg_compile(mrhg_w_vshl, Int8, Int8; bit_width=W, optimize)
        @test c === nothing
        @test err isa ArgumentError && is_mrhg_rejection(err)
    end

    # Signed division.
    for W in (4, 8), optimize in (false, true)
        c, err = mrhg_compile(mrhg_w_sdiv, Int8, Int8; bit_width=W, optimize)
        @test c === nothing
        @test err isa ArgumentError && is_mrhg_rejection(err)
    end

    # A comparison against the source type's own limit: re-typing -128 at W=3
    # gives 0, which silently inverts the test (pre-fix: 0 for x = -1, reported
    # as a successful compile).
    for W in 2:4
        c, err = mrhg_compile(mrhg_w_tmin, Int8; bit_width=W, optimize=true)
        @test c === nothing
        @test err isa ArgumentError && is_mrhg_rejection(err)
    end

    # A widening cast (Int16 arithmetic is a second data domain).
    for optimize in (false, true)
        c, err = mrhg_compile(mrhg_w_widen, Int8; bit_width=8, optimize)
        @test c === nothing
        @test err isa ArgumentError && is_mrhg_rejection(err)
    end

    # Mixed-width arguments: there is no single source width to re-type.
    c_mixed, err_mixed = mrhg_compile(mrhg_w_mixed, Int8, Int16; bit_width=4,
                                     optimize=false)
    @test c_mixed === nothing
    @test err_mixed isa ArgumentError && is_mrhg_rejection(err_mixed)

    # A loop (unrolled at the source width is not the same computation at W).
    c_loop, err_loop = mrhg_compile(mrhg_w_loop, Int8; bit_width=4, optimize=true,
                                    max_loop_iterations=3)
    @test c_loop === nothing
    @test err_loop isa ArgumentError && is_mrhg_rejection(err_loop)

    # Bit counting: the unrolled body shifts by each source bit index and the
    # result is 64 bits wide.
    for W in (4, 8)
        c, err = mrhg_compile(mrhg_w_popc, UInt8; bit_width=W, optimize=false)
        @test c === nothing
        @test err isa ArgumentError && is_mrhg_rejection(err)
    end

    # A shift amount beyond W is a COUNT and cannot be re-typed: `x << 3` at
    # W = 2 must be refused, while W = 4 (k = 3 <= W) must work.
    c_shl, err_shl = mrhg_compile(mrhg_shl3, Int8; bit_width=2, optimize=true)
    @test c_shl === nothing
    @test err_shl isa ArgumentError && is_mrhg_rejection(err_shl)
    for optimize in (false, true)
        c_ok, err_ok = mrhg_compile(mrhg_shl3, Int8; bit_width=4, optimize)
        @test err_ok === nothing
        if err_ok === nothing
            @test verify_reversibility(c_ok)
            for p in 0:wmask(4)
                @test (simulate(c_ok, Int8, Int8(p)) & wmask(4)) == oracle_shl3(p, 4)
            end
        end
    end

    # The refusal message must be actionable: it names the bead and the shape.
    err = try
        reversible_compile(mrhg_w_tup, Int8; bit_width=4, optimize=true,
                           strategy=:expression)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test err isa ArgumentError && occursin("Bennett-mrhg", err.msg)
    @test err isa ArgumentError && occursin("tuple", lowercase(err.msg))
    err_mem2 = try
        reversible_compile(mrhg_w_mem, Int8; bit_width=4, optimize=false,
                           strategy=:expression)
        nothing
    catch e
        e
    end
    @test err_mem2 isa ArgumentError
    @test err_mem2 isa ArgumentError && occursin("Bennett-mrhg", err_mem2.msg)
end

end # @testset Bennett-mrhg
