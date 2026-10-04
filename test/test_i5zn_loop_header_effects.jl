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

# ============================================================================
# Part 2 — header SSA values live after the loop (review1 R2, 2026-10-03).
#
# THE BUG. Freezing header STORES is not enough. Every remaining unrolled
# iteration and the s0tn check-only pass re-lower the header into the same
# value map, and a load ignores the block predicate. So a header load placed
# ABOVE a store, replayed after the exit, reads the post-exit memory (the
# value that store wrote) and replaces the SSA value the exit block returns.
# The fix holds every header value that is used outside the loop AND depends
# on a load at its exit-visit value (`_loop_header_hold_set` / `_loop_hold!`
# in src/lowering/cfg.jl), folding in the check-only pass's values only when
# that (K+1)-th header visit really happens — a loop whose trip count is
# exactly K exits THERE.
#
# THE ORACLE is `_i5zn_interp`, a direct interpreter of the small UInt8
# ParsedIR fixtures (no Bennett code involved). For every one of the 256
# inputs and every K: if the source executes the header at most K+1 times the
# circuit must return the interpreter's value (simulate also asserts the
# ancillae are clean); otherwise simulate must refuse loudly through the
# Bennett-s0tn guard. `verify_reversibility` runs on every circuit whose K
# covers every input.
#
# PRE-FIX (RED, parked branch 8b272a8 without the hold): the R2 witness gives
# (20, 10) instead of (10, 20); see the per-testset notes below.
# ============================================================================

using Bennett: IRSelect, SSAOperand, ConstOperand

# ---- independent reference interpreter ----
function _i5zn_interp(p::ParsedIR, x::UInt8; fuel::Int=100_000)
    env = Dict{Symbol,Any}(p.args[1][1] => x)
    mem = Dict{Symbol,UInt8}()
    blocks = Dict(b.label => b for b in p.blocks)
    visits = Dict{Symbol,Int}()
    val(op) = op isa SSAOperand ? env[op.name] : UInt8(mod(op.value, 256))
    s8(v::UInt8) = reinterpret(Int8, v)
    binop(op, a, b) = op === :add ? a + b : op === :sub ? a - b :
                      op === :mul ? a * b : op === :and ? a & b :
                      op === :or  ? a | b : op === :xor ? a ⊻ b :
                      op === :shl ? (b < 8 ? a << b : 0x00) :
                      op === :lshr ? (b < 8 ? a >> b : 0x00) :
                      error("interp: binop $op")
    icmp(pr, a, b) = pr === :eq ? a == b : pr === :ne ? a != b :
                     pr === :ult ? a < b : pr === :ule ? a <= b :
                     pr === :ugt ? a > b : pr === :uge ? a >= b :
                     pr === :slt ? s8(a) < s8(b) : pr === :sle ? s8(a) <= s8(b) :
                     pr === :sgt ? s8(a) > s8(b) : pr === :sge ? s8(a) >= s8(b) :
                     error("interp: icmp $pr")
    prev = nothing
    cur = p.blocks[1]
    while true
        (fuel -= 1) > 0 || error("interp: out of fuel")
        visits[cur.label] = get(visits, cur.label, 0) + 1
        # phis read the predecessor's values simultaneously
        phivals = [(i.dest, val(first(v for (v, b) in i.incoming if b == prev)))
                   for i in cur.instructions if i isa IRPhi]
        for (d, v) in phivals
            env[d] = v
        end
        for i in cur.instructions
            if i isa IRPhi
            elseif i isa IRAlloca
                env[i.dest] = i.dest              # a pointer is its alloca's name
            elseif i isa IRStore
                mem[val(i.ptr)] = val(i.val)
            elseif i isa IRLoad
                env[i.dest] = mem[val(i.ptr)]
            elseif i isa IRBinOp
                env[i.dest] = binop(i.op, val(i.op1), val(i.op2))
            elseif i isa IRICmp
                env[i.dest] = icmp(i.predicate, val(i.op1), val(i.op2))
            elseif i isa IRSelect
                env[i.dest] = val(i.cond) ? val(i.op1) : val(i.op2)
            else
                error("interp: unsupported $(typeof(i))")
            end
        end
        t = cur.terminator
        t isa IRRet && return (val(t.op), visits)
        nxt = t.cond === nothing ? t.true_label :
              (val(t.cond) ? t.true_label : t.false_label)
        prev = cur.label
        cur = blocks[nxt]
    end
end

"""
    _i5zn_check(p, Ks; fold) -> Int

Every input, every K, against `_i5zn_interp`. Returns the number of
(K, input) pairs that had to — and did — fail loud, so a caller can assert the
below-trip-count side was exercised.
"""
function _i5zn_check(p::ParsedIR, Ks; fold::Bool, header::Symbol=:h)
    nloud = 0
    for K in Ks
        c = reversible_compile(p; max_loop_iterations=K, fold_constants=fold)
        bad = Any[]
        all_converge = true
        for x in _I5ZN_XS
            want, visits = _i5zn_interp(p, _i5zn_u(x))
            if get(visits, header, 0) <= K + 1
                got = try
                    UInt8(mod(Int(simulate(c, x)), 256))
                catch e
                    sprint(showerror, e)
                end
                got == want || push!(bad, (K=K, x=x, want=want, got=got))
            else
                all_converge = false
                msg = try
                    simulate(c, x); "no error"
                catch e
                    sprint(showerror, e)
                end
                if occursin("did not converge", msg) &&
                   occursin("max_loop_iterations=$K", msg)
                    nloud += 1
                else
                    push!(bad, (K=K, x=x, want=:loud, got=msg))
                end
            end
        end
        isempty(bad) || @info "i5zn mismatches (K=$K, fold=$fold)" length(bad) first(bad, 4)
        @test isempty(bad)
        all_converge && @test verify_reversibility(c)
    end
    return nloud
end

# ---- fixtures ----

# R2 — review1's swap witness, VERBATIM (a := 10, b := 20; n := x & 1; the
# header loads both, swaps them, and the exit returns the PRE-swap load `va`).
function _i5zn_r2_swap()
    ParsedIR(8, [(:x, 8)], [
        IRBasicBlock(:entry, IRInst[
            IRAlloca(:a, 8, iconst(1)),
            IRAlloca(:b, 8, iconst(1)),
            IRStore(ssa(:a), iconst(10), 8),
            IRStore(ssa(:b), iconst(20), 8),
            IRBinOp(:n, :and, ssa(:x), iconst(1), 8),
        ], IRBranch(nothing, :h, nothing)),
        IRBasicBlock(:h, IRInst[
            IRPhi(:i, 8, [(iconst(0), :entry), (ssa(:i2), :h)]),
            IRLoad(:va, ssa(:a), 8),
            IRLoad(:vb, ssa(:b), 8),
            IRStore(ssa(:a), ssa(:vb), 8),
            IRStore(ssa(:b), ssa(:va), 8),
            IRBinOp(:i2, :add, ssa(:i), iconst(1), 8),
            IRICmp(:done, :uge, ssa(:i), ssa(:n), 8),
        ], IRBranch(ssa(:done), :exit, :h)),
        IRBasicBlock(:exit, IRInst[], IRRet(ssa(:va), 8)),
    ], [8])
end

# S1 — the swap generalised: data-dependent contents (a := x, b := x ⊻ 0x5a),
# trip count n := (x >> 6) & 3, and the exit combines BOTH pre-store loads
# through a pure chain (`t`, `r` are outside the loop; `va`/`vb` are held).
function _i5zn_s1_swap()
    ParsedIR(8, [(:x, 8)], [
        IRBasicBlock(:entry, IRInst[
            IRAlloca(:a, 8, iconst(1)), IRAlloca(:b, 8, iconst(1)),
            IRStore(ssa(:a), ssa(:x), 8),
            IRBinOp(:x2, :xor, ssa(:x), iconst(0x5a % Int), 8),
            IRStore(ssa(:b), ssa(:x2), 8),
            IRBinOp(:x6, :lshr, ssa(:x), iconst(6), 8),
            IRBinOp(:n, :and, ssa(:x6), iconst(3), 8),
        ], IRBranch(nothing, :h, nothing)),
        IRBasicBlock(:h, IRInst[
            IRPhi(:i, 8, [(iconst(0), :entry), (ssa(:i2), :h)]),
            IRLoad(:va, ssa(:a), 8),
            IRLoad(:vb, ssa(:b), 8),
            IRBinOp(:vb1, :add, ssa(:vb), ssa(:i), 8),
            IRStore(ssa(:a), ssa(:vb1), 8),
            IRStore(ssa(:b), ssa(:va), 8),
            IRBinOp(:i2, :add, ssa(:i), iconst(1), 8),
            IRICmp(:done, :uge, ssa(:i), ssa(:n), 8),
        ], IRBranch(ssa(:done), :exit, :h)),
        IRBasicBlock(:exit, IRInst[
            IRBinOp(:t, :shl, ssa(:vb), iconst(1), 8),
            IRBinOp(:r, :add, ssa(:va), ssa(:t), 8),
        ], IRRet(ssa(:r), 8)),
    ], [8])
end

# S2 — load AFTER store in the header (its replay is benign), next to a
# pre-store load and a pure value derived from the post-store load (`u`).
function _i5zn_s2_load_after_store()
    ParsedIR(8, [(:x, 8)], [
        IRBasicBlock(:entry, IRInst[
            IRAlloca(:a, 8, iconst(1)),
            IRStore(ssa(:a), ssa(:x), 8),
            IRBinOp(:n, :and, ssa(:x), iconst(3), 8),
        ], IRBranch(nothing, :h, nothing)),
        IRBasicBlock(:h, IRInst[
            IRPhi(:i, 8, [(iconst(0), :entry), (ssa(:i2), :h)]),
            IRLoad(:v, ssa(:a), 8),
            IRBinOp(:m, :mul, ssa(:v), iconst(3), 8),
            IRBinOp(:v2, :add, ssa(:m), ssa(:i), 8),
            IRStore(ssa(:a), ssa(:v2), 8),
            IRLoad(:w, ssa(:a), 8),
            IRBinOp(:u, :xor, ssa(:w), ssa(:x), 8),
            IRBinOp(:i2, :add, ssa(:i), iconst(1), 8),
            IRICmp(:done, :uge, ssa(:i), ssa(:n), 8),
        ], IRBranch(ssa(:done), :exit, :h)),
        IRBasicBlock(:exit, IRInst[
            IRBinOp(:r1, :add, ssa(:u), ssa(:v), 8),
            IRBinOp(:r, :add, ssa(:r1), ssa(:i), 8),
        ], IRRet(ssa(:r), 8)),
    ], [8])
end

# S3 — the EXIT TEST itself reads memory: `while *a < lim; *a += step`, with
# the exit returning the pre-store load `v`. Trip count is data-dependent
# (step := (x & 3) + 1, lim := x >> 4; up to 16 header visits).
function _i5zn_s3_load_cond()
    ParsedIR(8, [(:x, 8)], [
        IRBasicBlock(:entry, IRInst[
            IRAlloca(:a, 8, iconst(1)),
            IRStore(ssa(:a), iconst(0), 8),
            IRBinOp(:s0, :and, ssa(:x), iconst(3), 8),
            IRBinOp(:step, :add, ssa(:s0), iconst(1), 8),
            IRBinOp(:lim, :lshr, ssa(:x), iconst(4), 8),
        ], IRBranch(nothing, :h, nothing)),
        IRBasicBlock(:h, IRInst[
            IRPhi(:i, 8, [(iconst(0), :entry), (ssa(:i2), :h)]),
            IRLoad(:v, ssa(:a), 8),
            IRBinOp(:v2, :add, ssa(:v), ssa(:step), 8),
            IRStore(ssa(:a), ssa(:v2), 8),
            IRBinOp(:i2, :add, ssa(:i), iconst(1), 8),
            IRICmp(:done, :uge, ssa(:v), ssa(:lim), 8),
        ], IRBranch(ssa(:done), :exit, :h)),
        IRBasicBlock(:exit, IRInst[
            IRLoad(:fa, ssa(:a), 8),
            IRBinOp(:t, :shl, ssa(:i), iconst(4), 8),
            IRBinOp(:t2, :xor, ssa(:t), ssa(:v), 8),
            IRBinOp(:r, :add, ssa(:t2), ssa(:fa), 8),
        ], IRRet(ssa(:r), 8)),
    ], [8])
end

# S4 — a multi-block loop (header → body → latch): header load / store whose
# pre-store load `v` is returned after the loop, body side effects driven by
# `v`, and the latch-defined counter.
function _i5zn_s4_multiblock(; ret_latch::Bool=false)
    ParsedIR(8, [(:x, 8)], [
        IRBasicBlock(:entry, IRInst[
            IRAlloca(:a, 8, iconst(1)), IRAlloca(:b, 8, iconst(1)),
            IRStore(ssa(:a), ssa(:x), 8), IRStore(ssa(:b), iconst(5), 8),
            IRBinOp(:n, :and, ssa(:x), iconst(3), 8),
        ], IRBranch(nothing, :h, nothing)),
        IRBasicBlock(:h, IRInst[
            IRPhi(:i, 8, [(iconst(0), :entry), (ssa(:k1), :latch)]),
            IRLoad(:v, ssa(:a), 8),
            IRBinOp(:v2, :add, ssa(:v), ssa(:x), 8),
            IRStore(ssa(:a), ssa(:v2), 8),
            IRICmp(:done, :uge, ssa(:i), ssa(:n), 8),
        ], IRBranch(ssa(:done), :exit, :body)),
        IRBasicBlock(:body, IRInst[
            IRLoad(:w, ssa(:b), 8),
            IRBinOp(:w2, :add, ssa(:w), ssa(:v), 8),
            IRStore(ssa(:b), ssa(:w2), 8),
        ], IRBranch(nothing, :latch, nothing)),
        IRBasicBlock(:latch, IRInst[IRBinOp(:k1, :add, ssa(:i), iconst(1), 8)],
            IRBranch(nothing, :h, nothing)),
        IRBasicBlock(:exit, IRInst[
            IRLoad(:rb, ssa(:b), 8),
            IRBinOp(:r, :xor, ssa(ret_latch ? :k1 : :v), ssa(:rb), 8),
        ], IRRet(ssa(:r), 8)),
    ], [8])
end

# S5 — an EXIT-BLOCK PHI takes the held header value on the header edge and a
# constant on an edge that skips the loop entirely (x < 0).
function _i5zn_s5_exit_phi()
    ParsedIR(8, [(:x, 8)], [
        IRBasicBlock(:entry, IRInst[
            IRAlloca(:a, 8, iconst(1)),
            IRStore(ssa(:a), ssa(:x), 8),
            IRBinOp(:n, :and, ssa(:x), iconst(3), 8),
            IRICmp(:skip, :slt, ssa(:x), iconst(0), 8),
        ], IRBranch(ssa(:skip), :exit, :h)),
        IRBasicBlock(:h, IRInst[
            IRPhi(:i, 8, [(iconst(0), :entry), (ssa(:i2), :h)]),
            IRLoad(:v, ssa(:a), 8),
            IRBinOp(:v2, :add, ssa(:v), iconst(7), 8),
            IRStore(ssa(:a), ssa(:v2), 8),
            IRBinOp(:i2, :add, ssa(:i), iconst(1), 8),
            IRICmp(:done, :uge, ssa(:i), ssa(:n), 8),
        ], IRBranch(ssa(:done), :exit, :h)),
        IRBasicBlock(:exit, IRInst[
            IRPhi(:r, 8, [(ssa(:v), :h), (iconst(99), :entry)]),
        ], IRRet(ssa(:r), 8)),
    ], [8])
end

# S6 — control: a PURE header value used after the loop (`s2`, from header
# phis only) is not held — its replay recomputes it from the frozen phis.
function _i5zn_s6_pure()
    ParsedIR(8, [(:x, 8)], [
        IRBasicBlock(:entry, IRInst[IRBinOp(:n, :and, ssa(:x), iconst(7), 8)],
            IRBranch(nothing, :h, nothing)),
        IRBasicBlock(:h, IRInst[
            IRPhi(:i, 8, [(iconst(0), :entry), (ssa(:i2), :h)]),
            IRPhi(:s, 8, [(ssa(:x), :entry), (ssa(:s2), :h)]),
            IRBinOp(:s1, :mul, ssa(:s), iconst(5), 8),
            IRBinOp(:s2, :add, ssa(:s1), ssa(:i), 8),
            IRBinOp(:i2, :add, ssa(:i), iconst(1), 8),
            IRICmp(:done, :uge, ssa(:i), ssa(:n), 8),
        ], IRBranch(ssa(:done), :exit, :h)),
        IRBasicBlock(:exit, IRInst[], IRRet(ssa(:s2), 8)),
    ], [8])
end

# S7 — a second exit (`break` from the body straight to the exit block).
function _i5zn_s7_two_exits()
    ParsedIR(8, [(:x, 8)], [
        IRBasicBlock(:entry, IRInst[IRBinOp(:n, :and, ssa(:x), iconst(3), 8)],
            IRBranch(nothing, :h, nothing)),
        IRBasicBlock(:h, IRInst[
            IRPhi(:i, 8, [(iconst(0), :entry), (ssa(:i2), :body)]),
            IRICmp(:done, :uge, ssa(:i), ssa(:n), 8),
        ], IRBranch(ssa(:done), :exit, :body)),
        IRBasicBlock(:body, IRInst[
            IRBinOp(:i2, :add, ssa(:i), iconst(1), 8),
            IRICmp(:brk, :eq, ssa(:i2), iconst(2), 8),
        ], IRBranch(ssa(:brk), :exit, :h)),
        IRBasicBlock(:exit, IRInst[
            IRPhi(:r, 8, [(ssa(:i), :h), (iconst(77), :body)]),
        ], IRRet(ssa(:r), 8)),
    ], [8])
end

_i5zn_errmsg(f) = try f(); "no error" catch e; sprint(showerror, e) end

@testset "Bennett-i5zn part 2: header values live after the loop hold their exit-visit value" begin

    @testset "R2 witness verbatim (review1, K=2): (10, 20)" begin
        # x=0: n=0, one header visit, returns the original a = 10.
        # x=1: n=1, two visits; the 2nd visit loads a = 20 (after one swap).
        # Pre-fix: main (10, 10), parked branch 8b272a8 (20, 10).
        c = reversible_compile(_i5zn_r2_swap(); max_loop_iterations=2, fold_constants=false)
        @test (Int(simulate(c, Int8(0))), Int(simulate(c, Int8(1)))) == (10, 20)
        @test verify_reversibility(c)
    end

    @testset "R2 swap, every input, K ∈ 1:4 — fold=$fold" for fold in _I5ZN_FOLDS
        @test _i5zn_check(_i5zn_r2_swap(), (1, 2, 4); fold) == 0   # trip ≤ 2 visits
    end

    @testset "S1 data-dependent swap, pure exit chain — fold=$fold" for fold in _I5ZN_FOLDS
        # ≤ 4 header visits: K=2 is below the trip count for x>>6 == 3.
        @test _i5zn_check(_i5zn_s1_swap(), (2, 3, 4, 7); fold) > 0
    end

    @testset "S2 load after store in the header — fold=$fold" for fold in _I5ZN_FOLDS
        @test _i5zn_check(_i5zn_s2_load_after_store(), (2, 3, 4, 7); fold) > 0
    end

    @testset "S3 exit test reads memory — fold=$fold" for fold in _I5ZN_FOLDS
        @test _i5zn_check(_i5zn_s3_load_cond(), (8, 15, 16, 19); fold) > 0
    end

    @testset "S4 multi-block loop, pre-store header load returned — fold=$fold" for fold in _I5ZN_FOLDS
        @test _i5zn_check(_i5zn_s4_multiblock(), (2, 3, 4, 7); fold) > 0
    end

    @testset "S5 exit-block phi over a held header value — fold=$fold" for fold in _I5ZN_FOLDS
        # K = 2 is below the trip count for x ≥ 0 with x & 3 == 3 (loud), while
        # the inputs that SKIP the loop (x < 0) must be answered: the s0tn
        # guard is gated by the header's path predicate (Bennett-n9o8; pre-fix
        # they were refused although the header never runs).
        @test _i5zn_check(_i5zn_s5_exit_phi(), (2, 3, 4, 7); fold) > 0
    end

    @testset "S6 control: pure header value is not held — fold=$fold" for fold in _I5ZN_FOLDS
        @test _i5zn_check(_i5zn_s6_pure(), (6, 7, 8, 11); fold) > 0
    end

    @testset "hold set: exactly the load-tainted header values used after the loop" begin
        hs(p) = (bm = Dict(b.label => b for b in p.blocks);
                 Bennett._loop_header_hold_set(bm[:h],
                     Symbol[l for l in (:body, :latch) if haskey(bm, l)], bm))
        @test hs(_i5zn_r2_swap()) == [:va]
        @test hs(_i5zn_s1_swap()) == [:va, :vb]
        @test hs(_i5zn_s2_load_after_store()) == [:v, :u]
        @test hs(_i5zn_s3_load_cond()) == [:v]
        @test hs(_i5zn_s4_multiblock()) == [:v]
        @test hs(_i5zn_s6_pure()) == Symbol[]       # pure: no hold, no extra gate
        @test hs(_i5zn_f1_parsed()) == Symbol[]     # header load not used after
    end

    @testset "S4' latch-defined value used after the loop: loud" begin
        # Not valid SSA (the latch does not dominate the exit), but a
        # hand-written ParsedIR is not verified: refuse rather than return the
        # last unrolled iteration's `k1`.
        msg = _i5zn_errmsg(() -> reversible_compile(_i5zn_s4_multiblock(ret_latch=true);
                                                    max_loop_iterations=4))
        @test occursin("Bennett-i5zn", msg)
        @test occursin("%k1", msg) && occursin("latch", msg)
    end

    @testset "S7 second loop exit (break): loud" begin
        msg = _i5zn_errmsg(() -> reversible_compile(_i5zn_s7_two_exits();
                                                    max_loop_iterations=4))
        @test occursin("second loop exit", msg)
        @test occursin("Bennett-c6ex", msg)
    end
end
