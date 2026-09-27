# test_i5zn_loop_header_effects.jl — Bennett-i5zn (Astra B-lowering F5;
# review reviews/2026-09-26-astra/verify-37w3.md §C1).
#
# THE BUG. `lower_loop!` unrolls a bounded loop K times. The header's NON-PHI
# instructions run under `iter_block_pred[hlabel] = block_pred[hlabel]`, which
# is constant for every unrolled iteration, and again in the Bennett-s0tn
# "check-only" convergence pass. Only the loop-carried PHIs are frozen on the
# header's exit condition. So a header that does load / increment / store
# BEFORE the exit test (including a store through a select-ed pointer) keeps
# mutating memory after the source loop exited, and the s0tn check-only pass
# replays those effects on an already-exited path.
#
# SILENT, and self-contradictory: `verify_reversibility` passes (reversible
# execution undoes a wrongly-enabled write perfectly), yet RAISING the
# supposedly safe bound K CHANGES the answer (the header is evaluated K+1
# times for a trip count of n ≤ K).
#
# THE INVARIANT THIS FILE PINS. For every K ≥ the true trip count the circuit
# computes the SAME function of the input — namely the source semantics — on
# all 256 Int8 values. Every fixture is compiled at the true bound, +1, +3 and
# +8, with `fold_constants` off AND on, exhaustively compared against an
# independent oracle, and `verify_reversibility`-checked. With K BELOW the
# trip count the existing fail-loud s0tn overflow guard must still fire.
#
# Evidence for the two header-side-effect fixtures:
#   * F1 is the bead's witness, verbatim from
#     reviews/2026-09-26-astra/B-lowering.md F5.
#   * F2 is a faithful re-creation of verify-37w3 §C1 (selected-pointer store
#     in the loop header). It reproduces that review's numbers EXACTLY —
#     192/256 wrong at K=4, 256/256 at K=6, `simulate(c, Int8(0)) == 16`,
#     `simulate(c, Int8(-128))` vs oracle 19, `verify_reversibility == true`
#     in both folding modes.
#
# PRE-FIX (RED, this file before the cfg.jl change): 82 passed, 56 failed.
# The 56 failures are exactly fixtures F1–F4 × {fold off, fold on} × {oracle
# mismatch at every K, K-invariance violation at K > true bound}: 4 × 4 ×
# (1 + 3) = ... concretely 4 circuits per cell, each contributing one failing
# oracle comparison plus (from the second circuit on) one failing K-invariance
# comparison. The 82 passes are the `verify_reversibility` calls — the bug is
# INVISIBLE to reversibility, which is the whole point — plus the controls F5
# (body-store-only), F7 (optimize=true pure-SSA loop) and the loud-rejection /
# fail-loud assertions (6) and (8). F1 returns K+1 for EVERY input, F4
# likewise: the answer moves with the "safe" bound.

using Test
using Bennett
using LLVM
using Bennett: IRInst, IRBasicBlock, IRAlloca, IRStore, IRLoad, IRBinOp, IRICmp,
    IRPhi, IRBranch, IRRet, ParsedIR, ssa, iconst, find_back_edges,
    extract_parsed_ir

const _I5ZN_XS = typemin(Int8):typemax(Int8)

_i5zn_u(x::Int8) = reinterpret(UInt8, x)

# Compile an in-memory, LLVM-VERIFIED module through the real C-API walker
# (same path the reviews used). `LLVM.verify` first: a hand-written fixture
# that does not pass the LLVM verifier is a malformed fixture, not evidence.
function _i5zn_compile_ll(ir::AbstractString; kw...)
    c = nothing
    LLVM.Context() do _ctx
        mod = parse(LLVM.Module, ir)
        LLVM.verify(mod)
        c = reversible_compile(Bennett._module_to_parsed_ir(mod); kw...)
        dispose(mod)
    end
    return c
end

"""
    _i5zn_k_invariant(circuits, oracle; label)

The invariant: every circuit in `circuits` (one per K, all with K ≥ the true
trip count) returns the SAME 256-entry answer vector, and that vector equals
the independent oracle. Plus `verify_reversibility` per circuit (ancillae back
to zero, inputs preserved).
"""
function _i5zn_k_invariant(circuits::Vector, oracle; label::AbstractString)
    want = Int8[oracle(x) for x in _I5ZN_XS]
    ref = nothing
    for c in circuits
        got = Int8[simulate(c, x) for x in _I5ZN_XS]
        @test got == want                                  # oracle-correct
        @test verify_reversibility(c)                      # ancillae clean
        if ref === nothing
            ref = got
        else
            @test got == ref                               # K-invariance
        end
    end
    return nothing
end

# ---- oracles (independent of the compiler; plain UInt8 arithmetic) ----
# F1: header visits = trip count + 1, each visit does a += 1 on `a`.
_i5zn_f1_oracle(x::Int8) = Int8(Int(_i5zn_u(x) & 0x03) + 1)

# F2: a := 11, b := 22; p := a iff bit 0; n := ((u >> 2) & 3) + 1.
# Header: *p += 1, then `k == n` exits. Body: iff bit 1, *p := 40 + k;
# k += 1. Returns a XOR b.
function _i5zn_f2_oracle(x::Int8)
    u = _i5zn_u(x)
    pa = (u & 0x01) != 0x00
    n = Int((u >> 2) & 0x03) + 1
    a = UInt8(0x0b); b = UInt8(0x16)
    k = 0
    while true
        if pa; a += 0x01 else; b += 0x01 end
        k == n && break
        if (u & 0x02) != 0x00
            if pa; a = 0x28 + k else; b = 0x28 + k end
        end
        k += 1
    end
    return Int8(a ⊻ b)
end

# F3: a += 1 in the HEADER, b += 1 in the BODY, trip count n := u & 3,
# returns a XOR b.
function _i5zn_f3_oracle(x::Int8)
    u = _i5zn_u(x)
    n = Int(u & 0x03)
    a = UInt8(n + 1)
    b = UInt8(n)
    return Int8(a ⊻ b)
end

# F4: a 4-element array; the header-only self loop load/increments/stores slot
# (k & 3) — the DYNAMIC-INDEX (`_lower_store_via_mux_4x8!`) store arm, not the
# static shadow arm of F1. Trip count n := (u >> 2) & 3 ∈ 0:3, so slots 0..n
# each take one increment and the return is the XOR of all four slots.
function _i5zn_f4_oracle(x::Int8)
    n = Int((_i5zn_u(x) >> 2) & 0x03)
    s = UInt8[11, 22, 33, 44]
    for k in 0:n
        s[k+1] += 0x01
    end
    return Int8(s[1] ⊻ s[2] ⊻ s[3] ⊻ s[4])
end

# F5 (regression control): pure header, body does a += 3 into `a`; trip count
# n := (u & 3) + 1.
_i5zn_f5_oracle(x::Int8) = Int8(11 + 3 * (Int(_i5zn_u(x) & 0x03) + 1))

# ---- fixtures ----

# F1 — the bead's witness (B-lowering F5, verbatim). The loop header IS the
# loop's only block (self-loop latch) and its non-phi instructions are
# load / increment / store, executed BEFORE the exit test.
function _i5zn_f1_parsed()
    ParsedIR(8, [(:x, 8)], [
        IRBasicBlock(:entry, IRInst[IRAlloca(:a, 8, iconst(1)),
            IRStore(ssa(:a), iconst(0), 8),
            IRBinOp(:n, :and, ssa(:x), iconst(3), 8)],
            IRBranch(nothing, :h, nothing)),
        IRBasicBlock(:h, IRInst[
            IRPhi(:i, 8, [(iconst(0), :entry), (ssa(:i2), :h)]),
            IRLoad(:v, ssa(:a), 8),
            IRBinOp(:v2, :add, ssa(:v), iconst(1), 8),
            IRStore(ssa(:a), ssa(:v2), 8),
            IRBinOp(:i2, :add, ssa(:i), iconst(1), 8),
            IRICmp(:done, :uge, ssa(:i), ssa(:n), 8)],
            IRBranch(ssa(:done), :exit, :h)),
        IRBasicBlock(:exit, IRInst[IRLoad(:r, ssa(:a), 8)], IRRet(ssa(:r), 8))],
        [8])
end

# F3 — header load / increment / store in a loop that ALSO has body blocks:
# the body does a load / increment / store of its own (guarded by the body
# block predicate, which was already correct) and a latch block carries `i`.
function _i5zn_f3_parsed()
    ParsedIR(8, [(:x, 8)], [
        IRBasicBlock(:entry, IRInst[IRAlloca(:a, 8, iconst(1)),
            IRAlloca(:b, 8, iconst(1)),
            IRStore(ssa(:a), iconst(0), 8), IRStore(ssa(:b), iconst(0), 8),
            IRBinOp(:n, :and, ssa(:x), iconst(3), 8)],
            IRBranch(nothing, :h, nothing)),
        IRBasicBlock(:h, IRInst[
            IRPhi(:i, 8, [(iconst(0), :entry), (ssa(:k1), :latch)]),
            IRLoad(:v, ssa(:a), 8),
            IRBinOp(:v2, :add, ssa(:v), iconst(1), 8),
            IRStore(ssa(:a), ssa(:v2), 8),
            IRICmp(:done, :uge, ssa(:i), ssa(:n), 8)],
            IRBranch(ssa(:done), :exit, :body)),
        IRBasicBlock(:body, IRInst[
            IRLoad(:w, ssa(:b), 8),
            IRBinOp(:w2, :add, ssa(:w), iconst(1), 8),
            IRStore(ssa(:b), ssa(:w2), 8)],
            IRBranch(nothing, :latch, nothing)),
        IRBasicBlock(:latch, IRInst[IRBinOp(:k1, :add, ssa(:i), iconst(1), 8)],
            IRBranch(nothing, :h, nothing)),
        IRBasicBlock(:exit, IRInst[IRLoad(:ra, ssa(:a), 8),
            IRLoad(:rb, ssa(:b), 8),
            IRBinOp(:r, :xor, ssa(:ra), ssa(:rb), 8)],
            IRRet(ssa(:r), 8))],
        [8])
end

# F2 — verify-37w3 §C1: a POINTER SELECTED BEFORE the loop (multi-origin), a
# store through it in the LOOP HEADER (load / increment / store), a
# conditional body store, a latch block. LLVM-verified text module.
const _I5ZN_F2_LL = """
define i8 @julia_f_2(i8 %x) {
entry:
  %a = alloca i8
  %b = alloca i8
  %pa = getelementptr i8, ptr %a, i32 0
  %pb = getelementptr i8, ptr %b, i32 0
  store i8 11, ptr %pa
  store i8 22, ptr %pb
  %m1 = and i8 %x, 1
  %c = icmp ne i8 %m1, 0
  %p = select i1 %c, ptr %pa, ptr %pb
  %xs = lshr i8 %x, 2
  %t3 = and i8 %xs, 3
  %n = add i8 %t3, 1
  br label %H
H:
  %k = phi i8 [ 0, %entry ], [ %k1, %latch ]
  %pv = load i8, ptr %p
  %inc = add i8 %pv, 1
  store i8 %inc, ptr %p
  %done = icmp eq i8 %k, %n
  br i1 %done, label %exit, label %body
body:
  %m2 = and i8 %x, 2
  %d = icmp ne i8 %m2, 0
  br i1 %d, label %write, label %latch
write:
  %sv = add i8 %k, 40
  store i8 %sv, ptr %p
  br label %latch
latch:
  %k1 = add i8 %k, 1
  br label %H
exit:
  %ra = load i8, ptr %pa
  %rb = load i8, ptr %pb
  %r = xor i8 %ra, %rb
  ret i8 %r
}
"""

# F4 — the loop header is the loop's ONLY block (self-loop latch) and its
# side effect is a load/increment/store through a RUNTIME-INDEXED pointer
# (`_lower_store_via_mux_4x8!`, a different memory arm from F1's static
# shadow store).
const _I5ZN_F4_LL = """
define i8 @julia_f_4(i8 %x) {
entry:
  %a = alloca [4 x i8]
  %p0 = getelementptr i8, ptr %a, i32 0
  %p1 = getelementptr i8, ptr %a, i32 1
  %p2 = getelementptr i8, ptr %a, i32 2
  %p3 = getelementptr i8, ptr %a, i32 3
  store i8 11, ptr %p0
  store i8 22, ptr %p1
  store i8 33, ptr %p2
  store i8 44, ptr %p3
  %xs = lshr i8 %x, 2
  %n = and i8 %xs, 3
  br label %H
H:
  %k = phi i8 [ 0, %entry ], [ %k1, %H ]
  %ki = and i8 %k, 3
  %kz = zext i8 %ki to i32
  %pa = getelementptr i8, ptr %a, i32 %kz
  %v = load i8, ptr %pa
  %v2 = add i8 %v, 1
  store i8 %v2, ptr %pa
  %k1 = add i8 %k, 1
  %done = icmp eq i8 %k, %n
  br i1 %done, label %exit, label %H
exit:
  %r0 = load i8, ptr %p0
  %r1 = load i8, ptr %p1
  %r2 = load i8, ptr %p2
  %r3 = load i8, ptr %p3
  %x01 = xor i8 %r0, %r1
  %x23 = xor i8 %r2, %r3
  %r = xor i8 %x01, %x23
  ret i8 %r
}
"""

# F5 — REGRESSION CONTROL: pure header (phi + test only), the store lives in
# the BODY. This shape was already correct (the body block predicate is the
# header's ¬exit) and must stay correct and K-invariant.
const _I5ZN_F5_LL = """
define i8 @julia_f_5(i8 %x) {
entry:
  %a = alloca i8
  %pa = getelementptr i8, ptr %a, i32 0
  store i8 11, ptr %pa
  %t3 = and i8 %x, 3
  %n = add i8 %t3, 1
  br label %H
H:
  %k = phi i8 [ 0, %entry ], [ %k1, %latch ]
  %done = icmp eq i8 %k, %n
  br i1 %done, label %exit, label %body
body:
  %v = load i8, ptr %pa
  %v2 = add i8 %v, 3
  store i8 %v2, ptr %pa
  br label %latch
latch:
  %k1 = add i8 %k, 1
  br label %H
exit:
  %r = load i8, ptr %pa
  ret i8 %r
}
"""

# F6 — a loop header that is ITSELF the header of an inner loop. The unroller
# does not model nested loops and must keep refusing LOUD (Bennett-httg / U05
# scope): the inner header's iterations cannot be frozen independently.
function _i5zn_f6_nested()
    ParsedIR(8, [(:x, 8)], [
        IRBasicBlock(:entry, IRInst[], IRBranch(nothing, :h, nothing)),
        IRBasicBlock(:h, IRInst[
            IRPhi(:i, 8, [(iconst(0), :entry), (ssa(:i2), :latch)]),
            IRICmp(:stop, :uge, ssa(:i), iconst(3), 8),
            IRBinOp(:i2, :add, ssa(:i), iconst(1), 8)],
            IRBranch(ssa(:stop), :exit, :inner)),
        IRBasicBlock(:inner, IRInst[
            IRPhi(:j, 8, [(iconst(0), :h), (ssa(:j2), :inner)]),
            IRBinOp(:j2, :add, ssa(:j), iconst(1), 8),
            IRICmp(:go2, :ult, ssa(:j2), iconst(2), 8)],
            IRBranch(ssa(:go2), :inner, :latch)),
        IRBasicBlock(:latch, IRInst[], IRBranch(nothing, :h, nothing)),
        IRBasicBlock(:exit, IRInst[], IRRet(ssa(:i), 8))],
        [8])
end

# F7 — the optimize=true companion: a genuine Julia loop that SURVIVES LLVM's
# optimizer (collatz-style; a loop with a statically provable bound is
# eliminated outright and would make this test vacuous, so the back edge is
# asserted below). Its header is its own only block, with no memory effect:
# this is the pure-SSA control for the phi-freeze side of the invariant.
function _i5zn_f7_julia(x::Int8)
    steps = Int8(0)
    val = x
    while val > Int8(1) && steps < Int8(20)
        if val % Int8(2) == Int8(0)
            val = val >> Int8(1)
        else
            val = Int8(3) * val + Int8(1)
        end
        steps += Int8(1)
    end
    return steps
end

const _I5ZN_FOLDS = (false, true)

@testset "Bennett-i5zn: loop-header side effects freeze after exit" begin

    @testset "(1) F1 witness: header-only self loop, load/inc/store — fold=$fold" for fold in _I5ZN_FOLDS
        # trip count n := x & 3 ∈ 0:3, so K = 3 is the true bound.
        cs = [reversible_compile(_i5zn_f1_parsed(); max_loop_iterations=K,
                                 fold_constants=fold) for K in (3, 4, 6, 11)]
        _i5zn_k_invariant(cs, _i5zn_f1_oracle; label="F1")
    end

    @testset "(2) F2 verify-37w3 §C1: selected-pointer HEADER store — fold=$fold" for fold in _I5ZN_FOLDS
        # trip count n := ((x >> 2) & 3) + 1 ∈ 1:4, so K = 4 is the true bound.
        cs = [_i5zn_compile_ll(_I5ZN_F2_LL; max_loop_iterations=K, fold_constants=fold)
              for K in (4, 5, 7, 12)]
        _i5zn_k_invariant(cs, _i5zn_f2_oracle; label="F2")
    end

    @testset "(3) F3 header load/inc/store WITH body blocks — fold=$fold" for fold in _I5ZN_FOLDS
        # trip count n := x & 3 ∈ 0:3, so K = 3 is the true bound.
        cs = [reversible_compile(_i5zn_f3_parsed(); max_loop_iterations=K,
                                 fold_constants=fold) for K in (3, 4, 6, 11)]
        _i5zn_k_invariant(cs, _i5zn_f3_oracle; label="F3")
    end

    @testset "(4) F4 header IS the only block, dynamic-idx load/inc/store — fold=$fold" for fold in _I5ZN_FOLDS
        # trip count n := (x >> 2) & 3 ∈ 0:3, so K = 3 is the true bound.
        cs = [_i5zn_compile_ll(_I5ZN_F4_LL; max_loop_iterations=K, fold_constants=fold)
              for K in (3, 4, 6, 11)]
        _i5zn_k_invariant(cs, _i5zn_f4_oracle; label="F4")
    end

    @testset "(5) F5 control: BODY store only, pure header — fold=$fold" for fold in _I5ZN_FOLDS
        cs = [_i5zn_compile_ll(_I5ZN_F5_LL; max_loop_iterations=K, fold_constants=fold)
              for K in (4, 5, 7, 12)]
        _i5zn_k_invariant(cs, _i5zn_f5_oracle; label="F5")
    end

    @testset "(6) nested loops still fail loud" begin
        err = try
            reversible_compile(_i5zn_f6_nested(); max_loop_iterations=4)
            nothing
        catch e
            e
        end
        @test err !== nothing
        msg = sprint(showerror, err)
        @test occursin("nested loop header", msg)
        @test occursin("inner", msg)
        @test occursin("nested loops not supported", msg)
    end

    @testset "(7) optimize=true: loop really survives, K-invariant" begin
        parsed = extract_parsed_ir(_i5zn_f7_julia, Tuple{Int8}; optimize=true)
        @test !isempty(find_back_edges(parsed.blocks))   # not vacuous
        cs = [reversible_compile(_i5zn_f7_julia, Int8; optimize=true,
                                 max_loop_iterations=K) for K in (20, 21, 23, 28)]
        _i5zn_k_invariant(cs, _i5zn_f7_julia; label="F7")
    end

    @testset "(8) K BELOW the trip count still fails loud (Bennett-s0tn)" begin
        for (f, K, x) in ((_i5zn_f1_parsed(), 2, Int8(3)),          # n = 3 > K
                          (_I5ZN_F2_LL, 3, Int8(12)),                # n = 4 > K
                          (_I5ZN_F4_LL, 2, Int8(12)),                 # n = 3 > K
                          (_I5ZN_F5_LL, 3, Int8(3)))                 # n = 4 > K
            c = f isa AbstractString ?
                _i5zn_compile_ll(f; max_loop_iterations=K) :
                reversible_compile(f; max_loop_iterations=K)
            @test_throws ErrorException simulate(c, x)
            msg = sprint(showerror, try simulate(c, x) catch e; e end)
            @test occursin("did not converge", msg)
            @test occursin("max_loop_iterations=$K", msg)
        end
    end
end
