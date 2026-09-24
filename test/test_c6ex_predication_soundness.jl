# Bennett-c6ex: soundness of the path-predicate / phi-resolution machinery
# (`src/lowering/phi.jl`, `cfg.jl::lower_loop!`, `driver.jl::lower`).
#
# The v2 review flagged two silent fall-throughs in phi.jl:
#   * `_compute_block_pred!`: `haskey(block_pred, p) || continue` dropped an
#     OR-term, which weakens the block predicate;
#   * `_edge_predicate!`: a conditional source block that does not branch to the
#     phi block got `block_pred[src]`, which over-approximates the edge predicate
#     (false-path sensitisation, CLAUDE.md "Phi Resolution").
# Neither site is reachable from VALID LLVM IR. The 3+1 proposers
# (docs/design/c6ex/) found worse silent miscompiles next to them in
# `lower_loop!`, all reachable from plain Julia at optimize=false:
#   * a loop header with more than one pre-header incoming kept only the LAST
#     pre-header value (pre2 1143/2304 wrong, pre4 1935/2304, g2 77/256,
#     g4 127/256, hand .ll H5 127/256);
#   * a loop with more than one latch kept only the LAST latch value
#     (H6: 256/256 wrong);
#   * a second loop exit (`break`) was never modelled, so iterations ran past
#     the break (l5: 96/256 wrong).
# Plus malformed-IR silent miscompiles: a phi citing a non-predecessor
# (H9 127/256, CE3c 256/256, CE3u 127/256), and an unexpanded IRSwitch in a
# hand-built ParsedIR (3/256 wrong).
#
# The fix (orchestrator_review.md decisions 1-9):
#   * multi-pre-header header phis are merged by edge predicate;
#   * multi-latch loops with distinct latch values throw;
#   * a second loop exit throws;
#   * an up-front CFG validator runs at `lower()` entry;
#   * same-target conditional branches are canonicalised to unconditional ones;
#   * dead blocks record no edges;
#   * every silent arm is an assert;
#   * a debug-mode mutual-exclusion auditor (`PRED_AUDIT`) is added.
# Gate counts of every currently-correct program are unchanged (pinned below).

using Test
using Bennett
using Bennett: reversible_compile, simulate, gate_count, verify_reversibility,
               extract_parsed_ir, extract_parsed_ir_from_ll,
               WireAllocator, ReversibleGate, allocate!,
               _compute_block_pred!, _edge_predicate!, lower_phi!,
               IRPhi, IROperand, IRBasicBlock, IRBranch, IRRet, IRSwitch,
               IRICmp, IRBinOp, IRInst, ParsedIR, ssa, iconst

# ---------------------------------------------------------------- fixtures --

# (1) multi-pre-header loop headers (optimize=false: an if/else falls straight
#     into the `while` header, whose phis then cite BOTH arms).
function _c6ex_pre2(x::Int8, n::Int8)
    if x > Int8(0); a = Int8(1); else; a = Int8(-1); end
    while n > Int8(0); a += x; n -= Int8(1); end
    a
end
function _c6ex_pre4(x::Int8, n::Int8)
    if x > Int8(20); a = Int8(3)
    elseif x < Int8(-20); a = Int8(-5)
    else; a = Int8(7); end
    while n > Int8(0); a += x; n -= Int8(1); end
    a
end
function _c6ex_g2(x::Int8)
    n = x & Int8(7); s = Int8(0)
    if x > Int8(50); s = Int8(5); end
    while n > Int8(0); s += Int8(3); n -= Int8(1); end
    s
end
function _c6ex_g4(x::Int8)
    n = x & Int8(7); s = x
    if x < Int8(0); n = x & Int8(3); s = -x; end
    while n > Int8(0); s ⊻= n; n -= Int8(1); end
    s
end
# (2) second loop exit (break) at optimize=false.
function _c6ex_l5(x::Int8)
    n = x & Int8(7); s = Int8(0)
    while n > Int8(0)
        if s > Int8(9); break; end
        s += Int8(3); n -= Int8(1)
    end
    s
end
# (3) green guards: currently-correct programs whose gate counts are pinned.
function _c6ex_g1(x::Int8)
    n = x & Int8(7)
    if x > Int8(50); n = x & Int8(3); end
    s = Int8(0)
    while n > Int8(0); s += x; n -= Int8(1); end
    s
end
function _c6ex_pre3(x::Int8, n::Int8)
    a = x > Int8(0) ? Int8(1) : Int8(-1)
    while n > Int8(0); a += x; n -= Int8(1); end
    a
end
function _c6ex_cl(x::Int8, n::Int8)
    a = Int8(0)
    if x > Int8(0)
        while n > Int8(0); a += x; n -= Int8(1); end
    else
        a = x
    end
    a
end
function _c6ex_cont(x::Int8, n::Int8)
    a = Int8(0); i = Int8(0)
    while i < n
        i += Int8(1)
        if (i & Int8(1)) == Int8(0); continue; end
        a += x
    end
    a
end
function _c6ex_acc(x::Int8, n::Int8)
    a = Int8(0); i = Int8(0)
    while i < n; a += x; i += Int8(1); end
    a
end
function _c6ex_brbody(x::Int8, n::Int8)
    a = Int8(0); i = Int8(0)
    while i < n
        a = (x > Int8(0)) ? a + x : a - x
        i += Int8(1)
    end
    a
end
function _c6ex_collatz(x::Int8)
    n = x & Int8(7); steps = Int8(0)
    while n > Int8(1)
        n = iseven(n) ? n >> 1 : Int8(3) * n + Int8(1)
        steps += Int8(1)
    end
    steps
end
_c6ex_diamond(x::Int8) = x > Int8(0) ? x + Int8(1) : x - Int8(1)
function _c6ex_nested(x::Int8)
    if x > Int8(0)
        r = x > Int8(50) ? x - Int8(50) : x + Int8(3)
    else
        r = x < Int8(-50) ? x + Int8(50) : x * Int8(2)
    end
    r
end
function _c6ex_multiret(x::Int8)
    x > Int8(100) && return Int8(1)
    x < Int8(-100) && return Int8(2)
    x == Int8(7) && return Int8(3)
    return x + Int8(5)
end
function _c6ex_switchy(x::Int8)
    y = x & Int8(7)
    if y == Int8(0); return Int8(10)
    elseif y == Int8(1); return Int8(20)
    elseif y == Int8(2); return Int8(33)
    elseif y == Int8(3); return x
    else return -x end
end

# ---- hand-written .ll fixtures ----

# H5: two pre-headers P1/P2 into a self-loop header H.
const _C6EX_H5 = """
define i8 @h5(i8 %x) {
top:
  %c = icmp sgt i8 %x, 0
  br i1 %c, label %P1, label %P2
P1:
  %a1 = add i8 %x, 1
  br label %H
P2:
  %a2 = sub i8 %x, 1
  br label %H
H:
  %acc = phi i8 [ %a1, %P1 ], [ %a2, %P2 ], [ %acc2, %H ]
  %i = phi i8 [ 0, %P1 ], [ 1, %P2 ], [ %i2, %H ]
  %acc2 = add i8 %acc, 3
  %i2 = add i8 %i, 1
  %done = icmp sge i8 %i2, 3
  br i1 %done, label %E, label %H
E:
  %r = phi i8 [ %acc2, %H ]
  ret i8 %r
}
"""
_c6ex_h5_ref(x::Int8) = x > 0 ? (x + Int8(1)) + Int8(9) : (x - Int8(1)) + Int8(6)

# H6: two latches LA/LB with DISTINCT loop-carried values.
const _C6EX_H6 = """
define i8 @h6(i8 %x) {
top:
  br label %H
H:
  %acc = phi i8 [ %x, %top ], [ %accA, %LA ], [ %accB, %LB ]
  %i = phi i8 [ 0, %top ], [ %iA, %LA ], [ %iB, %LB ]
  %done = icmp uge i8 %i, 4
  br i1 %done, label %E, label %B
B:
  %bit = and i8 %acc, 1
  %odd = icmp ne i8 %bit, 0
  br i1 %odd, label %LA, label %LB
LA:
  %accA = add i8 %acc, 7
  %iA = add i8 %i, 1
  br label %H
LB:
  %accB = xor i8 %acc, 5
  %iB = add i8 %i, 2
  br label %H
E:
  %r = phi i8 [ %acc, %H ]
  ret i8 %r
}
"""

# H12: a latch ending in `br i1 %q, label %H, label %H` (duplicate latch
# incomings carrying the same value) — correct today, must stay byte-identical.
const _C6EX_H12 = """
define i8 @h12(i8 %x) {
top:
  br label %H
H:
  %acc = phi i8 [ %x, %top ], [ %acc2, %L ], [ %acc2, %L ]
  %i = phi i8 [ 0, %top ], [ %i2, %L ], [ %i2, %L ]
  %done = icmp uge i8 %i, 3
  br i1 %done, label %E, label %L
L:
  %acc2 = add i8 %acc, 5
  %i2 = add i8 %i, 1
  %q = icmp sgt i8 %acc2, 0
  br i1 %q, label %H, label %H
E:
  %r = phi i8 [ %acc, %H ]
  ret i8 %r
}
"""
_c6ex_h12_ref(x::Int8) = x + Int8(15)

# H9 / CE3: phi cites switch block S, which does not branch to M
# (`_expand_switches` A11 leaves such an incoming alone).
const _C6EX_H9 = """
define i8 @h9(i8 %x) {
top:
  %c = icmp sgt i8 %x, 0
  br i1 %c, label %S, label %M
S:
  %lo = and i8 %x, 3
  switch i8 %lo, label %A [ i8 1, label %Bb ]
A:
  br label %M
Bb:
  br label %M
M:
  %r = phi i8 [ 99, %S ], [ 1, %A ], [ 2, %Bb ], [ 3, %top ]
  ret i8 %r
}
"""
# CE3c: phi cites the conditional entry `top`, which is not a predecessor of M.
const _C6EX_CE3C = """
define i8 @ce3c(i8 %x) {
top:
  %c = icmp sgt i8 %x, 0
  br i1 %c, label %A, label %B
A:
  br label %M
B:
  br label %M
M:
  %r = phi i8 [ 3, %top ], [ 1, %A ], [ 2, %B ]
  ret i8 %r
}
"""
# CE3u: phi cites unconditional A (A -> A2 -> M), not a predecessor of M —
# reaches the NO-branch_info fall-through of `_edge_predicate!`.
const _C6EX_CE3U = """
define i8 @ce3u(i8 %x) {
top:
  %c = icmp sgt i8 %x, 0
  br i1 %c, label %A, label %B
A:
  br label %A2
A2:
  br label %M
B:
  br label %M
M:
  %r = phi i8 [ 5, %A ], [ 1, %A2 ], [ 2, %B ]
  ret i8 %r
}
"""

# H1 / H1b: a same-target conditional branch `br i1 %c2, label %B, label %B`.
const _C6EX_H1 = """
define i8 @h1(i8 %x) {
top:
  %c = icmp sgt i8 %x, 0
  br i1 %c, label %A, label %M
A:
  %c2 = icmp slt i8 %x, 50
  br i1 %c2, label %B, label %B
B:
  %p = phi i8 [ 7, %A ], [ 7, %A ]
  %b = add i8 %x, %p
  br label %M
M:
  %r = phi i8 [ %b, %B ], [ %x, %top ]
  ret i8 %r
}
"""
_c6ex_h1_ref(x::Int8) = x > 0 ? x + Int8(7) : x
const _C6EX_H1B = """
define i8 @h1b(i8 %x) {
top:
  %c = icmp sgt i8 %x, 0
  br i1 %c, label %A, label %M
A:
  %c2 = icmp slt i8 %x, 50
  br i1 %c2, label %B, label %B
B:
  %b = add i8 %x, 5
  br label %M
M:
  %r = phi i8 [ %b, %B ], [ %x, %top ]
  ret i8 %r
}
"""
_c6ex_h1b_ref(x::Int8) = x > 0 ? x + Int8(5) : x
# H2: a switch whose last case targets the default — `_expand_switches` emits
# `_sw_top_2: br i1 %cmp, label %M, label %M`.
const _C6EX_H2 = """
define i8 @h2(i8 %x) {
top:
  %lo = and i8 %x, 3
  switch i8 %lo, label %M [ i8 1, label %A
                            i8 2, label %M ]
A:
  %a = add i8 %x, 10
  br label %M
M:
  %r = phi i8 [ %a, %A ], [ %x, %top ], [ %x, %top ]
  ret i8 %r
}
"""
_c6ex_h2_ref(x::Int8) = (x & 3) == 1 ? x + Int8(10) : x

# CE1 / H4c: a dead (entry-unreachable) block feeding a live diamond arm.
const _C6EX_CE1 = """
define i8 @ce1(i8 %x) {
top:
  %c = icmp sgt i8 %x, 0
  br i1 %c, label %A, label %B
A:
  %a = add i8 %x, 1
  br label %M
dead:
  br label %B
B:
  %b = sub i8 %x, 1
  br label %M
M:
  %r = phi i8 [ %a, %A ], [ %b, %B ]
  ret i8 %r
}
"""
# CE1c: a dead CHAIN dead0 -> dead1 -> B.
const _C6EX_CE1C = """
define i8 @ce1c(i8 %x) {
top:
  %c = icmp sgt i8 %x, 0
  br i1 %c, label %A, label %B
A:
  %a = add i8 %x, 1
  br label %M
dead0:
  br label %dead1
dead1:
  br label %B
B:
  %b = sub i8 %x, 1
  br label %M
M:
  %r = phi i8 [ %a, %A ], [ %b, %B ]
  ret i8 %r
}
"""
_c6ex_ce1_ref(x::Int8) = x > 0 ? x + Int8(1) : x - Int8(1)

# SW2: a two-entry shared-target switch (Bennett-u21m shape).
const _C6EX_SW2 = """
define i8 @sw2(i8 %x) {
top:
  switch i8 %x, label %default [
    i8 1, label %L
    i8 2, label %M
    i8 3, label %L
  ]
L:
  %y = phi i8 [ 10, %top ], [ 10, %top ]
  ret i8 %y
M:
  ret i8 20
default:
  ret i8 0
}
"""
_c6ex_sw2_ref(x::Int8) = (x == 1 || x == 3) ? Int8(10) : x == 2 ? Int8(20) : Int8(0)

# A hand-built ParsedIR with an UNEXPANDED IRSwitch terminator. Pre-fix, the
# driver had no terminator arm for it: S recorded no edges, X's predicate
# silently dropped the S -> X edge, and x in 1:3 took the R return (3 wrong).
function _c6ex_unexpanded_switch_ir()
    blocks = IRBasicBlock[
        IRBasicBlock(:top, IRInst[IRICmp(:c, :sgt, ssa(:x), iconst(0), 8)],
                     IRBranch(ssa(:c), :S, :P)),
        IRBasicBlock(:S, IRInst[],
                     IRSwitch(ssa(:x), 8, :R,
                              [(iconst(1), :X), (iconst(2), :X), (iconst(3), :X)])),
        IRBasicBlock(:P, IRInst[IRICmp(:c2, :slt, ssa(:x), iconst(-50), 8)],
                     IRBranch(ssa(:c2), :X, :R)),
        IRBasicBlock(:X, IRInst[IRBinOp(:vx, :add, ssa(:x), iconst(10), 8)],
                     IRRet(ssa(:vx), 8)),
        IRBasicBlock(:R, IRInst[IRBinOp(:vr, :sub, ssa(:x), iconst(3), 8)],
                     IRRet(ssa(:vr), 8)),
    ]
    return ParsedIR(8, [(:x, 8)], blocks, [8])
end

# ----------------------------------------------------------------- helpers --

const _C6EX_I8 = typemin(Int8):typemax(Int8)
_c6ex_i8n(K) = [(x, n) for x in _C6EX_I8 for n in Int8(0):Int8(K)]

function _c6ex_ll(ir::AbstractString, fname::AbstractString)
    mktempdir() do dir
        path = joinpath(dir, "$fname.ll")
        write(path, ir)
        extract_parsed_ir_from_ll(path; entry_function=fname)
    end
end

# Number of inputs on which the circuit disagrees with the reference. A
# `simulate` that throws (ancilla / input-preservation / loop-guard failure)
# counts as wrong. `simulate` asserts ancilla-zero on every call (CLAUDE.md §4).
function _c6ex_wrong(c, f, inputs)
    wrong = 0
    for inp in inputs
        expected = inp isa Tuple ? f(inp...) : f(inp)
        got = try
            simulate(c, inp)
        catch
            nothing
        end
        (got !== nothing && (got % UInt8) == (expected % UInt8)) || (wrong += 1)
    end
    return wrong
end

# Structural witness: the largest number of DISTINCT non-latch incoming blocks
# of any loop-header phi. Guards the multi-pre-header tests against a Julia
# codegen change that would silently stop exercising the shape.
function _c6ex_max_preheaders(pir)
    back = Bennett.find_back_edges(pir.blocks)
    best = 0
    for b in pir.blocks
        latches = Set(s for (s, d) in back if d == b.label)
        isempty(latches) && continue
        for inst in b.instructions
            inst isa IRPhi || continue
            pre = Set(blk for (_, blk) in inst.incoming
                      if !(blk in latches) && blk != b.label)
            best = max(best, length(pre))
        end
    end
    return best
end

_c6ex_bi() = Dict{Symbol,Tuple{Vector{Int},Symbol,Symbol}}()

# ------------------------------------------------------------------- tests --

@testset "Bennett-c6ex: predication soundness" begin

    @testset "T1: multi-pre-header loop header phis merge by edge predicate" begin
        for (f, T) in ((_c6ex_pre2, Tuple{Int8,Int8}), (_c6ex_pre4, Tuple{Int8,Int8}),
                       (_c6ex_g2, Tuple{Int8}), (_c6ex_g4, Tuple{Int8}))
            @test _c6ex_max_preheaders(extract_parsed_ir(f, T; optimize=false)) >= 2
        end
        # RED pre-fix: 1143 / 1935 wrong of 2304.
        for f in (_c6ex_pre2, _c6ex_pre4)
            c = reversible_compile(f, Int8, Int8; optimize=false, max_loop_iterations=8)
            @test _c6ex_wrong(c, f, _c6ex_i8n(8)) == 0
        end
        # RED pre-fix: 77 / 127 wrong of 256 (n = x & 7 <= 7 < K: every input converges).
        for f in (_c6ex_g2, _c6ex_g4)
            c = reversible_compile(f, Int8; optimize=false, max_loop_iterations=9)
            @test _c6ex_wrong(c, f, _C6EX_I8) == 0
        end
        # H5 (.ll): two pre-headers into a self-loop header. RED pre-fix: 127/256.
        pir = _c6ex_ll(_C6EX_H5, "h5")
        @test _c6ex_max_preheaders(pir) == 2
        c = reversible_compile(pir; max_loop_iterations=4)
        @test _c6ex_wrong(c, _c6ex_h5_ref, _C6EX_I8) == 0
        @test verify_reversibility(c; n_tests=16)
    end

    @testset "T2: multi-latch loops with distinct latch values fail loud" begin
        # RED pre-fix: 256/256 wrong, silently.
        pir = _c6ex_ll(_C6EX_H6, "h6")
        @test_throws "multi-latch" reversible_compile(pir; max_loop_iterations=6)
        # Duplicate latch incomings from ONE latch (same value) stay supported.
        c = reversible_compile(_c6ex_ll(_C6EX_H12, "h12"); max_loop_iterations=4)
        @test _c6ex_wrong(c, _c6ex_h12_ref, _C6EX_I8) == 0
        @test verify_reversibility(c; n_tests=16)
    end

    @testset "T3: a second loop exit (break) fails loud" begin
        # RED pre-fix: 96/256 wrong, silently (iterations ran past the break).
        @test_throws "second loop exit" reversible_compile(_c6ex_l5, Int8;
                                                           optimize=false,
                                                           max_loop_iterations=8)
        # optimize=true folds the break into the header condition: still correct.
        c = reversible_compile(_c6ex_l5, Int8; max_loop_iterations=8)
        @test _c6ex_wrong(c, _c6ex_l5, _C6EX_I8) == 0
    end

    @testset "T4: phi citing a non-predecessor fails loud" begin
        # RED pre-fix: 127 / 256 / 127 wrong of 256, silently.
        for (ir, fn) in ((_C6EX_H9, "h9"), (_C6EX_CE3C, "ce3c"), (_C6EX_CE3U, "ce3u"))
            pir = _c6ex_ll(ir, fn)
            @test_throws "not a CFG predecessor" reversible_compile(pir)
        end
    end

    @testset "T5: unexpanded IRSwitch reaching lower() fails loud" begin
        # RED pre-fix: 3/256 wrong, silently.
        @test_throws "IRSwitch must be expanded" reversible_compile(_c6ex_unexpanded_switch_ir())
    end

    @testset "T6: same-target conditional branches compile (canonicalised)" begin
        # RED pre-fix: Bennett-p94b duplicate-predecessor AssertionError on valid IR.
        for (ir, fn, ref) in ((_C6EX_H1, "h1", _c6ex_h1_ref),
                              (_C6EX_H1B, "h1b", _c6ex_h1b_ref),
                              (_C6EX_H2, "h2", _c6ex_h2_ref))
            c = reversible_compile(_c6ex_ll(ir, fn))
            @test _c6ex_wrong(c, ref, _C6EX_I8) == 0
            @test verify_reversibility(c; n_tests=16)
        end
    end

    @testset "T7: dead (entry-unreachable) blocks" begin
        # CE1: a dead block feeding a live block is benign (pinned below).
        c = reversible_compile(_c6ex_ll(_C6EX_CE1, "ce1"))
        @test _c6ex_wrong(c, _c6ex_ce1_ref, _C6EX_I8) == 0
        # CE1c: a dead chain. RED pre-fix: "no predicate contributions for block dead1".
        c = reversible_compile(_c6ex_ll(_C6EX_CE1C, "ce1c"))
        @test _c6ex_wrong(c, _c6ex_ce1_ref, _C6EX_I8) == 0
        @test verify_reversibility(c; n_tests=16)
    end

    @testset "T8: phi.jl asserts (unit)" begin
        # _edge_predicate!: conditional source that branches to neither side.
        let gates = ReversibleGate[], wa = WireAllocator()
            bp = Dict{Symbol,Vector{Int}}(:A => allocate!(wa, 1))
            bi = _c6ex_bi(); bi[:A] = (allocate!(wa, 1), :B, :C)
            @test_throws AssertionError _edge_predicate!(gates, wa, :A, :D, bp, bi)
        end
        # _edge_predicate!: same-target conditional branch (must be canonicalised).
        let gates = ReversibleGate[], wa = WireAllocator()
            bp = Dict{Symbol,Vector{Int}}(:A => allocate!(wa, 1))
            bi = _c6ex_bi(); bi[:A] = (allocate!(wa, 1), :B, :B)
            @test_throws AssertionError _edge_predicate!(gates, wa, :A, :B, bp, bi)
        end
        # _compute_block_pred!: a recorded predecessor without a predicate.
        let gates = ReversibleGate[], wa = WireAllocator()
            bp = Dict{Symbol,Vector{Int}}(:A => allocate!(wa, 1))
            preds = Dict{Symbol,Vector{Symbol}}(:C => [:A, :X])
            @test_throws AssertionError _compute_block_pred!(gates, wa, :C, preds,
                                                             _c6ex_bi(), bp)
        end
        # _compute_block_pred!: preds and branch_info disagree (neither target).
        let gates = ReversibleGate[], wa = WireAllocator()
            bp = Dict{Symbol,Vector{Int}}(:A => allocate!(wa, 1), :B => allocate!(wa, 1))
            bi = _c6ex_bi(); bi[:A] = (allocate!(wa, 1), :D, :E)
            preds = Dict{Symbol,Vector{Symbol}}(:C => [:A, :B])
            @test_throws AssertionError _compute_block_pred!(gates, wa, :C, preds, bi, bp)
        end
        # _compute_block_pred!: same-target conditional branch.
        let gates = ReversibleGate[], wa = WireAllocator()
            bp = Dict{Symbol,Vector{Int}}(:A => allocate!(wa, 1))
            bi = _c6ex_bi(); bi[:A] = (allocate!(wa, 1), :C, :C)
            preds = Dict{Symbol,Vector{Symbol}}(:C => [:A])
            @test_throws AssertionError _compute_block_pred!(gates, wa, :C, preds, bi, bp)
        end
        # lower_phi!: an incoming block that is not a registered predecessor.
        let gates = ReversibleGate[], wa = WireAllocator()
            vw = Dict{Symbol,Vector{Int}}(:a => allocate!(wa, 8), :b => allocate!(wa, 8))
            bp = Dict{Symbol,Vector{Int}}(:A => allocate!(wa, 1), :B => allocate!(wa, 1),
                                          :Z => allocate!(wa, 1))
            phi = IRPhi(:d, 8, Tuple{IROperand,Symbol}[(ssa(:a), :A), (ssa(:b), :Z)])
            preds = Dict{Symbol,Vector{Symbol}}(:M => [:A, :B])
            @test_throws AssertionError lower_phi!(gates, wa, vw, phi, :M, preds,
                                                   _c6ex_bi(), Dict{Symbol,Int}();
                                                   block_pred=bp)
            # Consistent preds: lowers.
            phi_ok = IRPhi(:d, 8, Tuple{IROperand,Symbol}[(ssa(:a), :A), (ssa(:b), :B)])
            lower_phi!(gates, wa, vw, phi_ok, :M, preds, _c6ex_bi(), Dict{Symbol,Int}();
                       block_pred=bp)
            @test length(vw[:d]) == 8
        end
    end

    @testset "T9: CFG validator + canonicaliser (unit)" begin
        chk = Bennett._check_predication_cfg
        canon = Bennett._canonicalize_same_target_branches
        ret(v) = IRRet(iconst(v), 8)
        br(t) = IRBranch(nothing, t, nothing)
        cbr(t, f) = IRBranch(ssa(:c), t, f)
        cmpc = IRInst[IRICmp(:c, :sgt, ssa(:x), iconst(0), 8)]
        # Happy path: returns the entry-unreachable set.
        ok = IRBasicBlock[IRBasicBlock(:top, cmpc, cbr(:A, :B)),
                          IRBasicBlock(:A, IRInst[], br(:M)),
                          IRBasicBlock(:dead, IRInst[], br(:B)),
                          IRBasicBlock(:B, IRInst[], br(:M)),
                          IRBasicBlock(:M, IRInst[IRPhi(:r, 8,
                              Tuple{IROperand,Symbol}[(iconst(1), :A), (iconst(2), :B)])],
                              IRRet(ssa(:r), 8))]
        @test chk(ok) == Set([:dead])
        # V1: unexpanded IRSwitch.
        @test_throws "IRSwitch must be expanded" chk(IRBasicBlock[
            IRBasicBlock(:top, IRInst[], IRSwitch(ssa(:x), 8, :A, [(iconst(1), :B)])),
            IRBasicBlock(:A, IRInst[], ret(1)), IRBasicBlock(:B, IRInst[], ret(2))])
        # V2: branch to a label that is not a block of the function.
        @test_throws "not a block of this function" chk(IRBasicBlock[
            IRBasicBlock(:top, IRInst[], br(:nowhere))])
        # `:__unreachable__` is a legal sentinel target.
        @test chk(IRBasicBlock[IRBasicBlock(:top, cmpc, cbr(:A, :__unreachable__)),
                               IRBasicBlock(:A, IRInst[], ret(1))]) == Set{Symbol}()
        # V3: the entry block has a predecessor.
        @test_throws "entry block" chk(IRBasicBlock[
            IRBasicBlock(:top, cmpc, cbr(:top, :A)), IRBasicBlock(:A, IRInst[], ret(1))])
        # V4a: phi incoming from a non-predecessor.
        @test_throws "not a CFG predecessor" chk(IRBasicBlock[
            IRBasicBlock(:top, cmpc, cbr(:A, :M)),
            IRBasicBlock(:A, IRInst[], br(:M)),
            IRBasicBlock(:M, IRInst[IRPhi(:r, 8, Tuple{IROperand,Symbol}[
                (iconst(1), :A), (iconst(2), :top), (iconst(3), :Q)])], IRRet(ssa(:r), 8)),
            IRBasicBlock(:Q, IRInst[], ret(4))])
        # V4b: a CFG predecessor with no incoming (coverage).
        @test_throws "no incoming for CFG predecessor" chk(IRBasicBlock[
            IRBasicBlock(:top, cmpc, cbr(:A, :M)),
            IRBasicBlock(:A, IRInst[], br(:M)),
            IRBasicBlock(:M, IRInst[IRPhi(:r, 8, Tuple{IROperand,Symbol}[(iconst(1), :A)])],
                         IRRet(ssa(:r), 8))])
        # V4c: duplicate incomings from one block that disagree.
        @test_throws "twice with different values" chk(IRBasicBlock[
            IRBasicBlock(:top, cmpc, cbr(:A, :M)),
            IRBasicBlock(:A, IRInst[], br(:M)),
            IRBasicBlock(:M, IRInst[IRPhi(:r, 8, Tuple{IROperand,Symbol}[
                (iconst(1), :A), (iconst(2), :top), (iconst(3), :top)])], IRRet(ssa(:r), 8))])
        # Canonicaliser: identity (===) when there is no same-target branch ...
        @test canon(ok) === ok
        # ... and `br c, X, X` -> `br X` otherwise.
        same = IRBasicBlock[IRBasicBlock(:top, cmpc, cbr(:A, :A)),
                            IRBasicBlock(:A, IRInst[], ret(1))]
        out = canon(same)
        @test out !== same
        @test out[1].terminator.cond === nothing
        @test out[1].terminator.true_label === :A
        @test out[1].terminator.false_label === nothing
        @test out[2] === same[2]
    end

    @testset "T10: green guards — exhaustive + pinned gate counts (explicit strategies)" begin
        kw = (add=:ripple, mul=:shift_add)
        # (name, circuit thunk, reference, inputs, pinned total gates). Pins were
        # measured on the PRE-c6ex code (2026-09-24) and must not move: every
        # program here was already correct, so the fix is gate-neutral for it.
        cases = [
            ("diamond f", () -> reversible_compile(_c6ex_diamond, Int8; optimize=false, kw...),
             _c6ex_diamond, _C6EX_I8, 318),
            ("diamond t", () -> reversible_compile(_c6ex_diamond, Int8; kw...),
             _c6ex_diamond, _C6EX_I8, 228),
            ("nested f", () -> reversible_compile(_c6ex_nested, Int8; optimize=false, kw...),
             _c6ex_nested, _C6EX_I8, 868),
            ("nested t", () -> reversible_compile(_c6ex_nested, Int8; kw...),
             _c6ex_nested, _C6EX_I8, 618),
            ("multiret f", () -> reversible_compile(_c6ex_multiret, Int8; optimize=false, kw...),
             _c6ex_multiret, _C6EX_I8, 540),
            ("multiret t", () -> reversible_compile(_c6ex_multiret, Int8; kw...),
             _c6ex_multiret, _C6EX_I8, 552),
            ("switchy f", () -> reversible_compile(_c6ex_switchy, Int8; optimize=false, kw...),
             _c6ex_switchy, _C6EX_I8, 526),
            ("switchy t", () -> reversible_compile(_c6ex_switchy, Int8; kw...),
             _c6ex_switchy, _C6EX_I8, 634),
            ("g1 f K9", () -> reversible_compile(_c6ex_g1, Int8; optimize=false,
                                                 max_loop_iterations=9, kw...),
             _c6ex_g1, _C6EX_I8, 3709),
            ("g2 t K9", () -> reversible_compile(_c6ex_g2, Int8; max_loop_iterations=9, kw...),
             _c6ex_g2, _C6EX_I8, 274),
            ("l5 t K8", () -> reversible_compile(_c6ex_l5, Int8; max_loop_iterations=8, kw...),
             _c6ex_l5, _C6EX_I8, 566),
            ("pre3 f K8", () -> reversible_compile(_c6ex_pre3, Int8, Int8; optimize=false,
                                                   max_loop_iterations=8, kw...),
             _c6ex_pre3, _c6ex_i8n(8), 3437),
            ("cl f K8", () -> reversible_compile(_c6ex_cl, Int8, Int8; optimize=false,
                                                 max_loop_iterations=8, kw...),
             _c6ex_cl, _c6ex_i8n(8), 3367),
            ("cont f K8", () -> reversible_compile(_c6ex_cont, Int8, Int8; optimize=false,
                                                   max_loop_iterations=8, kw...),
             _c6ex_cont, _c6ex_i8n(8), 3443),
            ("acc f K6", () -> reversible_compile(_c6ex_acc, Int8, Int8; optimize=false,
                                                  max_loop_iterations=6, kw...),
             _c6ex_acc, _c6ex_i8n(6), 1875),
            ("acc t K6", () -> reversible_compile(_c6ex_acc, Int8, Int8;
                                                  max_loop_iterations=6, kw...),
             _c6ex_acc, _c6ex_i8n(6), 506),
            ("brbody f K4", () -> reversible_compile(_c6ex_brbody, Int8, Int8; optimize=false,
                                                     max_loop_iterations=4, kw...),
             _c6ex_brbody, _c6ex_i8n(4), 2297),
            ("brbody t K4", () -> reversible_compile(_c6ex_brbody, Int8, Int8;
                                                     max_loop_iterations=4, kw...),
             _c6ex_brbody, _c6ex_i8n(4), 774),
            ("collatz t K20", () -> reversible_compile(_c6ex_collatz, Int8;
                                                       max_loop_iterations=20, kw...),
             _c6ex_collatz, _C6EX_I8, 12663),
            ("CE1 .ll", () -> reversible_compile(_c6ex_ll(_C6EX_CE1, "ce1"); kw...),
             _c6ex_ce1_ref, _C6EX_I8, 320),
            ("H12 .ll K4", () -> reversible_compile(_c6ex_ll(_C6EX_H12, "h12");
                                                    max_loop_iterations=4, kw...),
             _c6ex_h12_ref, _C6EX_I8, 1081),
            ("SW2 .ll", () -> reversible_compile(_c6ex_ll(_C6EX_SW2, "sw2"); kw...),
             _c6ex_sw2_ref, _C6EX_I8, 310),
        ]
        for (name, mk, ref, inputs, pinned) in cases
            @testset "$name" begin
                c = mk()
                @test _c6ex_wrong(c, ref, inputs) == 0
                @test gate_count(c).total == pinned
            end
        end
    end

    @testset "T11: PRED_AUDIT mutual-exclusion oracle" begin
        # Forward-simulate `lower(...; fold_constants=false)` and check, at every
        # recorded merge, that #distinct sources with a live edge predicate is
        # exactly 1 when the merge block is live and 0 otherwise (P4).
        function audit_violations(pir, inputs; K=0)
            recs = Bennett.PredAuditRecord[]
            lr = Base.ScopedValues.with(Bennett.PRED_AUDIT => recs) do
                Bennett.lower(pir; max_loop_iterations=K, fold_constants=false)
            end
            @test !isempty(recs)
            bad = 0
            for inp in inputs
                bits = falses(lr.n_wires)
                vals = inp isa Tuple ? inp : (inp,)
                k = 0
                for (v, w) in zip(vals, lr.input_widths)
                    for i in 1:w
                        bits[lr.input_wires[k + i]] = ((v >> (i - 1)) & 1) == 1
                    end
                    k += w
                end
                for g in lr.gates
                    if g isa Bennett.NOTGate
                        bits[g.target] = !bits[g.target]
                    elseif g isa Bennett.CNOTGate
                        bits[g.control] && (bits[g.target] = !bits[g.target])
                    else
                        (bits[g.control1] && bits[g.control2]) &&
                            (bits[g.target] = !bits[g.target])
                    end
                end
                for r in recs
                    live = all(w -> bits[w], r.active_pos)
                    fired = Set(r.srcs[i] for i in eachindex(r.srcs) if bits[r.edge_wires[i]])
                    length(fired) == (live ? 1 : 0) || (bad += 1)
                end
            end
            return bad, Set(r.site for r in recs)
        end
        ex(f, T...) = extract_parsed_ir(f, Tuple{T...}; optimize=false)
        @test audit_violations(ex(_c6ex_diamond, Int8), _C6EX_I8)[1] == 0
        @test audit_violations(ex(_c6ex_nested, Int8), _C6EX_I8)[1] == 0
        bad, sites = audit_violations(ex(_c6ex_multiret, Int8), _C6EX_I8)
        @test bad == 0
        @test :multi_ret in sites
        @test audit_violations(ex(_c6ex_brbody, Int8, Int8), _c6ex_i8n(4); K=4)[1] == 0
        bad, sites = audit_violations(ex(_c6ex_pre2, Int8, Int8), _c6ex_i8n(8); K=8)
        @test bad == 0
        @test :loop_seed in sites
        @test audit_violations(ex(_c6ex_g4, Int8), _C6EX_I8; K=9)[1] == 0
        @test audit_violations(_c6ex_ll(_C6EX_H5, "h5"), _C6EX_I8; K=4)[1] == 0
        # Off by default: no recording, and the audited lowering is gate-identical.
        pir = ex(_c6ex_nested, Int8)
        @test Bennett.PRED_AUDIT[] === nothing
        lr0 = Bennett.lower(pir; fold_constants=false)
        lr1 = Base.ScopedValues.with(Bennett.PRED_AUDIT => Bennett.PredAuditRecord[]) do
            Bennett.lower(pir; fold_constants=false)
        end
        @test lr0.gates == lr1.gates
        # Negative control: two sources sharing one predicate wire overlap.
        let gates = ReversibleGate[], wa = WireAllocator(), recs = Bennett.PredAuditRecord[]
            p = allocate!(wa, 1)
            bp = Dict{Symbol,Vector{Int}}(:A => p, :B => p, :M => p)
            inc = [(allocate!(wa, 8), :A), (allocate!(wa, 8), :B)]
            Base.ScopedValues.with(Bennett.PRED_AUDIT => recs) do
                Bennett.resolve_phi_predicated!(gates, wa, inc, bp, 8; phi_block=:M,
                                                branch_info=_c6ex_bi())
            end
            @test length(recs) == 1
            r = recs[1]
            @test r.srcs == [:A, :B]
            @test r.edge_wires == [p[1], p[1]]   # both fire whenever M is live
        end
    end
end
