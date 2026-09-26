using Test
using Bennett
using LLVM
using Bennett: IRInst, IRBasicBlock, IRBinOp, IRICmp, IRSelect, IRBranch,
    IRRet, IRAlloca, IRStore, IRLoad, ParsedIR, ssa, iconst

# Bennett-37w3 (Astra review 2026-09-26, B-lowering F1): a store through a
# multi-origin pointer (pointer select / pointer phi) ignored the predicate of
# the block that CONTAINS the store. The multi-origin fan-out in
# `lower_store!` (src/lowering/memory.jl) guarded each origin's write with the
# origin-selection predicate `P_o` only, so when the pointer was selected but
# the store's own branch was not taken, the write still happened — the
# false-path-sensitisation class from CLAUDE.md "Phi Resolution", in memory
# predication. Correct write-enable: `B(store block) ∧ P_o ∧ (idx == k)`.
#
# The bug is invisible to `verify_reversibility` (reversible execution undoes
# a wrongly-enabled write perfectly) — every case below therefore sweeps all
# 256 Int8 inputs against an independent oracle, with folding on AND off.
# `simulate` additionally asserts ancilla-zero + input preservation per input.
#
# Pre-fix (RED): every store shape below is 64/256 wrong in both folding modes;
# the load controls and entry-store controls are 0/256 wrong.

const _37W3_XS = typemin(Int8):typemax(Int8)

_37w3_nwrong(c, oracle) = count(x -> simulate(c, x) != oracle(x), _37W3_XS)

_37w3_bit(x, k) = (reinterpret(UInt8, x) >> k) & 0x01 == 0x01

# Compile an in-memory, LLVM-verified module via the C-API walker (same entry
# point the F1 report used: `_module_to_parsed_ir` + `reversible_compile`).
function _37w3_compile_ll(ir::String; kw...)
    c = nothing
    LLVM.Context() do _ctx
        mod = parse(LLVM.Module, ir)
        LLVM.verify(mod)
        parsed = Bennett._module_to_parsed_ir(mod)
        c = reversible_compile(parsed; kw...)
        dispose(mod)
    end
    return c
end

function _37w3_check(c, oracle)
    nw = _37w3_nwrong(c, oracle)
    @test nw == 0
    @test verify_reversibility(c)
    return nw
end

# ---- LLVM fixture builders -------------------------------------------------
#
# Two i8 arrays a, b of N elements (N == 1 ⇒ scalar alloca, static shadow arm;
# N == 4 ⇒ generated MUX-EXCH 4x8 arm; N == 16 ⇒ shadow-checkpoint arm).
# Index i = (unsigned(x) >> 2) & (N-1) — independent of c = bit0, d = bit1.
# a[i] := 11, b[i] := 22, then the shape-specific pointer/store/observe code.
function _37w3_preamble(N::Int)
    if N == 1
        return """
          %a = alloca i8
          %b = alloca i8
          %pa = getelementptr i8, ptr %a, i32 0
          %pb = getelementptr i8, ptr %b, i32 0
          store i8 11, ptr %a
          store i8 22, ptr %b
          %m1 = and i8 %x, 1
          %c = icmp ne i8 %m1, 0
          %m2 = and i8 %x, 2
          %d = icmp ne i8 %m2, 0
          %m6 = and i8 %x, 64
          %e = icmp ne i8 %m6, 0
        """
    end
    return """
      %a = alloca i8, i32 $N
      %b = alloca i8, i32 $N
      %xz = zext i8 %x to i32
      %xs = lshr i32 %xz, 2
      %i = and i32 %xs, $(N - 1)
      %pa = getelementptr i8, ptr %a, i32 %i
      %pb = getelementptr i8, ptr %b, i32 %i
      store i8 11, ptr %pa
      store i8 22, ptr %pb
      %m1 = and i8 %x, 1
      %c = icmp ne i8 %m1, 0
      %m2 = and i8 %x, 2
      %d = icmp ne i8 %m2, 0
      %m6 = and i8 %x, 64
      %e = icmp ne i8 %m6, 0
    """
end

# select pointer in entry; store 9 through it only when d (or !d if neg).
function _37w3_ll_select_store(N; obs::Symbol=:a, neg::Bool=false)
    br = neg ? "br i1 %d, label %exit, label %write" :
               "br i1 %d, label %write, label %exit"
    """
    define i8 @julia_f_1(i8 %x) {
    entry:
    $(_37w3_preamble(N))
      %p = select i1 %c, ptr %pa, ptr %pb
      $br
    write:
      store i8 9, ptr %p
      br label %exit
    exit:
      %r = load i8, ptr %p$(obs)
      ret i8 %r
    }
    """
end

# diamond on c builds a pointer phi; then independent branch on d stores.
function _37w3_ll_phi_store(N; obs::Symbol=:a)
    """
    define i8 @julia_f_1(i8 %x) {
    entry:
    $(_37w3_preamble(N))
      br i1 %c, label %L, label %R
    L:
      br label %J
    R:
      br label %J
    J:
      %p = phi ptr [ %pa, %L ], [ %pb, %R ]
      br i1 %d, label %write, label %exit
    write:
      store i8 9, ptr %p
      br label %exit
    exit:
      %r = load i8, ptr %p$(obs)
      ret i8 %r
    }
    """
end

# outer branch on e; pointer select defined INSIDE it; store under d.
function _37w3_ll_nested_store(N; obs::Symbol=:a)
    """
    define i8 @julia_f_1(i8 %x) {
    entry:
    $(_37w3_preamble(N))
      br i1 %e, label %O, label %exit
    O:
      %p = select i1 %c, ptr %pa, ptr %pb
      br i1 %d, label %write, label %exit
    write:
      store i8 9, ptr %p
      br label %exit
    exit:
      %r = load i8, ptr %p$(obs)
      ret i8 %r
    }
    """
end

# selected pointer defined before a one-active-iteration loop; the store sits
# in a conditional block of the loop body. Compiled with K=2.
function _37w3_ll_loop_store(N; obs::Symbol=:a)
    """
    define i8 @julia_f_1(i8 %x) {
    entry:
    $(_37w3_preamble(N))
      %p = select i1 %c, ptr %pa, ptr %pb
      br label %H
    H:
      %k = phi i8 [ 0, %entry ], [ %k1, %latch ]
      %done = icmp eq i8 %k, 1
      br i1 %done, label %exit, label %body
    body:
      br i1 %d, label %write, label %latch
    write:
      store i8 9, ptr %p
      br label %latch
    latch:
      %k1 = add i8 %k, 1
      br label %H
    exit:
      %r = load i8, ptr %p$(obs)
      ret i8 %r
    }
    """
end

# Control: store in the ENTRY block through the selected pointer (always
# executes) — must stay correct and its gate count must not move.
function _37w3_ll_entry_store(N; obs::Symbol=:a)
    """
    define i8 @julia_f_1(i8 %x) {
    entry:
    $(_37w3_preamble(N))
      %p = select i1 %c, ptr %pa, ptr %pb
      store i8 9, ptr %p
      %r = load i8, ptr %p$(obs)
      ret i8 %r
    }
    """
end

# Reuse p: conditional store (d) then an unconditional store 7 at the join.
function _37w3_ll_reuse_store(N)
    """
    define i8 @julia_f_1(i8 %x) {
    entry:
    $(_37w3_preamble(N))
      %p = select i1 %c, ptr %pa, ptr %pb
      br i1 %d, label %write, label %exit
    write:
      store i8 9, ptr %p
      br label %exit
    exit:
      store i8 7, ptr %p
      %r = load i8, ptr %pa
      ret i8 %r
    }
    """
end

# Control: conditional LOAD through the selected pointer (select or phi).
function _37w3_ll_select_load(N; phi::Bool=false)
    ptr = phi ? """
      br i1 %c, label %L, label %R
    L:
      br label %J
    R:
      br label %J
    J:
      %p = phi ptr [ %pa, %L ], [ %pb, %R ]
      br i1 %d, label %rd, label %exit
    """ : """
      %p = select i1 %c, ptr %pa, ptr %pb
      br i1 %d, label %rd, label %exit
    """
    from = phi ? "%J" : "%entry"
    """
    define i8 @julia_f_1(i8 %x) {
    entry:
    $(_37w3_preamble(N))
    $ptr
    rd:
      %v = load i8, ptr %p
      br label %exit
    exit:
      %r = phi i8 [ %v, %rd ], [ 33, $from ]
      ret i8 %r
    }
    """
end

# ---- oracles ---------------------------------------------------------------
_37w3_orc_a(x)      = (_37w3_bit(x, 1) && _37w3_bit(x, 0))  ? 9 : 11     # (x&3)==3 ? 9 : 11
_37w3_orc_b(x)      = (_37w3_bit(x, 1) && !_37w3_bit(x, 0)) ? 9 : 22     # (x&3)==2 ? 9 : 22
_37w3_orc_a_neg(x)  = (!_37w3_bit(x, 1) && _37w3_bit(x, 0)) ? 9 : 11
_37w3_orc_b_neg(x)  = (!_37w3_bit(x, 1) && !_37w3_bit(x, 0)) ? 9 : 22
_37w3_orc_nest_a(x) = (_37w3_bit(x, 6) && _37w3_bit(x, 1) && _37w3_bit(x, 0))  ? 9 : 11
_37w3_orc_nest_b(x) = (_37w3_bit(x, 6) && _37w3_bit(x, 1) && !_37w3_bit(x, 0)) ? 9 : 22
_37w3_orc_entry_a(x) = _37w3_bit(x, 0) ? 9 : 11
_37w3_orc_entry_b(x) = _37w3_bit(x, 0) ? 22 : 9
_37w3_orc_reuse(x)  = _37w3_bit(x, 0) ? 7 : 11
_37w3_orc_load(x)   = _37w3_bit(x, 1) ? (_37w3_bit(x, 0) ? 11 : 22) : 33

# ---- the F1 ParsedIR fixture (verbatim from reviews/2026-09-26-astra/B-lowering.md F1)
function _37w3_f1_parsed(obs::Symbol)
    entry = IRInst[
        IRAlloca(:a, 8, iconst(1)), IRAlloca(:b, 8, iconst(1)),
        IRStore(ssa(:a), iconst(11), 8), IRStore(ssa(:b), iconst(22), 8),
        IRBinOp(:m1, :and, ssa(:x), iconst(1), 8),
        IRICmp(:c, :ne, ssa(:m1), iconst(0), 8),
        IRBinOp(:m2, :and, ssa(:x), iconst(2), 8),
        IRICmp(:d, :ne, ssa(:m2), iconst(0), 8),
        IRSelect(:p, ssa(:c), ssa(:a), ssa(:b), 0)]
    ParsedIR(8, [(:x, 8)], [
        IRBasicBlock(:entry, entry, IRBranch(ssa(:d), :write, :exit)),
        IRBasicBlock(:write, IRInst[IRStore(ssa(:p), iconst(9), 8)],
                     IRBranch(nothing, :exit, nothing)),
        IRBasicBlock(:exit, IRInst[IRLoad(:r, ssa(obs), 8)], IRRet(ssa(:r), 8))],
        [8])
end

const _37W3_FOLDS = (false, true)

@testset "Bennett-37w3: selected-pointer store honours its block predicate" begin

    @testset "(1) F1 ParsedIR fixture — fold=$fold, obs=$obs" for fold in _37W3_FOLDS,
            (obs, orc) in ((:a, _37w3_orc_a), (:b, _37w3_orc_b))
        c = reversible_compile(_37w3_f1_parsed(obs); fold_constants=fold)
        _37w3_check(c, orc)
    end

    @testset "(2) LLVM-verified .ll, static (N=1) — fold=$fold, obs=$obs, neg=$neg" for fold in _37W3_FOLDS,
            (obs, neg, orc) in ((:a, false, _37w3_orc_a), (:b, false, _37w3_orc_b),
                                (:a, true, _37w3_orc_a_neg), (:b, true, _37w3_orc_b_neg))
        c = _37w3_compile_ll(_37w3_ll_select_store(1; obs=obs, neg=neg); fold_constants=fold)
        _37w3_check(c, orc)
    end

    # (3) N=4 ⇒ `_lower_store_via_mux_4x8!` (generated MUX-EXCH arm);
    #     N=16 ⇒ `_lower_store_via_shadow_checkpoint!` (N·W = 128 > 64).
    @testset "(3) dynamic index N=$N — fold=$fold, obs=$obs" for N in (4, 16), fold in _37W3_FOLDS,
            (obs, orc) in ((:a, _37w3_orc_a), (:b, _37w3_orc_b))
        c = _37w3_compile_ll(_37w3_ll_select_store(N; obs=obs); fold_constants=fold)
        _37w3_check(c, orc)
    end

    @testset "(3b) dynamic N=4, compact_calls=true — obs=$obs" for (obs, orc) in ((:a, _37w3_orc_a), (:b, _37w3_orc_b))
        c = _37w3_compile_ll(_37w3_ll_select_store(4; obs=obs); compact_calls=true)
        _37w3_check(c, orc)
    end

    @testset "(4) diamond pointer phi, then independent conditional store — N=$N, fold=$fold, obs=$obs" for N in (1, 4, 16),
            fold in _37W3_FOLDS, (obs, orc) in ((:a, _37w3_orc_a), (:b, _37w3_orc_b))
        c = _37w3_compile_ll(_37w3_ll_phi_store(N; obs=obs); fold_constants=fold)
        _37w3_check(c, orc)
    end

    @testset "(4b) select inside outer branch e, store under d — N=$N, fold=$fold, obs=$obs" for N in (1, 4, 16),
            fold in _37W3_FOLDS, (obs, orc) in ((:a, _37w3_orc_nest_a), (:b, _37w3_orc_nest_b))
        c = _37w3_compile_ll(_37w3_ll_nested_store(N; obs=obs); fold_constants=fold)
        _37w3_check(c, orc)
    end

    @testset "(5) pointer selected before loop, store in conditional body (K=2) — fold=$fold, obs=$obs" for fold in _37W3_FOLDS,
            (obs, orc) in ((:a, _37w3_orc_a), (:b, _37w3_orc_b))
        c = _37w3_compile_ll(_37w3_ll_loop_store(1; obs=obs);
                             fold_constants=fold, max_loop_iterations=2)
        _37w3_check(c, orc)
    end

    @testset "(6) control: conditional selected-pointer LOAD — N=$N, phi=$phi, fold=$fold" for N in (1, 4, 16),
            phi in (false, true), fold in _37W3_FOLDS
        c = _37w3_compile_ll(_37w3_ll_select_load(N; phi=phi); fold_constants=fold)
        _37w3_check(c, _37w3_orc_load)
    end

    @testset "(7) control: entry-block selected store — N=$N, fold=$fold, obs=$obs" for N in (1, 4, 16),
            fold in _37W3_FOLDS, (obs, orc) in ((:a, _37w3_orc_entry_a), (:b, _37w3_orc_entry_b))
        c = _37w3_compile_ll(_37w3_ll_entry_store(N; obs=obs); fold_constants=fold)
        _37w3_check(c, orc)
    end

    @testset "(8) reuse p: conditional store then unconditional store at join — N=$N, fold=$fold" for N in (1, 4, 16),
            fold in _37W3_FOLDS
        c = _37w3_compile_ll(_37w3_ll_reuse_store(N); fold_constants=fold)
        _37w3_check(c, _37w3_orc_reuse)
    end
end
