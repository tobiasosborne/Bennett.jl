using Test
using Bennett
using LLVM
using Bennett: IRInst, IRBasicBlock, IRBinOp, IRRet, IRAlloca, IRStore, IRLoad,
    IRVarGEP, IRPtrOffset, ParsedIR, ssa, iconst

# Bennett-jkf0 (Astra review 2026-09-26, B-lowering F2): a GEP whose base is
# itself a GEP result lost (or reset) the base's pointer provenance.
#   * `lower_ptr_offset!` skipped every origin with a runtime index
#     (`o.idx_op isa ConstOperand || continue`), so `q = p + 0` after
#     `p = &a[x & 3]` had NO provenance; `load q` fell back to the legacy
#     slice-alias path and copied the pre-store snapshot (0 instead of 42).
#   * `lower_var_gep!` only recorded provenance when the base was a raw
#     alloca, and then OVERWROTE the base index instead of adding to it.
#   * the persistent-slab arms reset the index to 0 (`PtrOffset`) or
#     overwrote it (`VarGEP`), so `q = p1 + 0` read slot 0 instead of slot 1.
# Fix: GEP-on-GEP composes the element index (base idx + delta, emitting a
# reversible adder when either side is a runtime value).
#
# Like Bennett-37w3 the bug is invisible to `verify_reversibility` — every
# case sweeps all 256 Int8 inputs against an independent memory oracle, with
# folding on AND off. `simulate` asserts ancilla-zero + input preservation.

const _JKF0_XS = typemin(Int8):typemax(Int8)

_jkf0_u(x) = Int(reinterpret(UInt8, x))

function _jkf0_check(c, oracle)
    nw = count(x -> simulate(c, x) != oracle(x), _JKF0_XS)
    @test nw == 0
    @test verify_reversibility(c)
    return nw
end

_jkf0_parsed(insts, ret) =
    ParsedIR(8, [(:x, 8)], [IRBasicBlock(:entry, IRInst[insts...], IRRet(ret, 8))], [8])

# Shared preamble: an N-slot i8 array a[k] := 10 + k, plus
#   i  = x & (N-1)          (full-range runtime index)
#   lo = x & 1, hi = (x >> 1) & 1   (two runtime sub-indices, lo + hi ≤ 2)
#   o  = (x >> 2) & (N-1)   (independent observation index)
function _jkf0_preamble(N)
    insts = IRInst[IRAlloca(:a, 8, iconst(N))]
    for k in 0:N-1
        push!(insts, IRPtrOffset(Symbol(:init, k), ssa(:a), k, 8))
        push!(insts, IRStore(ssa(Symbol(:init, k)), iconst(10 + k), 8))
    end
    append!(insts, IRInst[
        IRBinOp(:i, :and, ssa(:x), iconst(N - 1), 8),
        IRBinOp(:lo, :and, ssa(:x), iconst(1), 8),
        IRBinOp(:xs1, :lshr, ssa(:x), iconst(1), 8),
        IRBinOp(:hi, :and, ssa(:xs1), iconst(1), 8),
        IRBinOp(:xs2, :lshr, ssa(:x), iconst(2), 8),
        IRBinOp(:o, :and, ssa(:xs2), iconst(N - 1), 8),
    ])
    return insts
end

_jkf0_mem(N) = [10 + k for k in 0:N-1]

# Observe a[o] through a fresh, directly-built pointer.
_jkf0_observe() = IRInst[IRVarGEP(:po, ssa(:a), ssa(:o), 8), IRLoad(:r, ssa(:po), 8)]

@testset "Bennett-jkf0 — GEP-on-GEP keeps (and composes) pointer provenance" begin

    @testset "N=$N fold=$fold" for N in (4, 16), fold in (false, true)
        o(x) = (_jkf0_u(x) >> 2) & (N - 1)

        @testset "F2: q = &a[i] + 0; *p = 42; return *q" begin
            insts = [_jkf0_preamble(N);
                     IRVarGEP(:p, ssa(:a), ssa(:i), 8); IRPtrOffset(:q, ssa(:p), 0, 8);
                     IRStore(ssa(:p), iconst(42), 8); IRLoad(:r, ssa(:q), 8)]
            _jkf0_check(reversible_compile(_jkf0_parsed(insts, ssa(:r)); fold_constants=fold),
                        x -> 42)
        end

        @testset "store through q = &a[i] + 0, load through p" begin
            insts = [_jkf0_preamble(N);
                     IRVarGEP(:p, ssa(:a), ssa(:i), 8); IRPtrOffset(:q, ssa(:p), 0, 8);
                     IRStore(ssa(:q), iconst(42), 8); IRLoad(:r, ssa(:p), 8)]
            _jkf0_check(reversible_compile(_jkf0_parsed(insts, ssa(:r)); fold_constants=fold),
                        x -> 42)
        end

        @testset "q = &a[i] + 0 before a later store elsewhere" begin
            # q is built, then a[o] is overwritten, then *q is read: must see
            # the overwrite iff o == i.
            insts = [_jkf0_preamble(N);
                     IRVarGEP(:p, ssa(:a), ssa(:i), 8); IRPtrOffset(:q, ssa(:p), 0, 8);
                     IRVarGEP(:po, ssa(:a), ssa(:o), 8); IRStore(ssa(:po), iconst(99), 8);
                     IRLoad(:r, ssa(:q), 8)]
            oracle = x -> begin
                m = _jkf0_mem(N); m[o(x) + 1] = 99; m[(_jkf0_u(x) & (N - 1)) + 1]
            end
            _jkf0_check(reversible_compile(_jkf0_parsed(insts, ssa(:r)); fold_constants=fold),
                        oracle)
        end

        @testset "dynamic + const: q = &a[lo] + 2" begin
            insts = [_jkf0_preamble(N);
                     IRVarGEP(:p, ssa(:a), ssa(:lo), 8); IRPtrOffset(:q, ssa(:p), 2, 8);
                     IRStore(ssa(:q), iconst(42), 8); _jkf0_observe()]
            oracle = x -> (m = _jkf0_mem(N); m[(_jkf0_u(x) & 1) + 2 + 1] = 42; m[o(x) + 1])
            _jkf0_check(reversible_compile(_jkf0_parsed(insts, ssa(:r)); fold_constants=fold),
                        oracle)
        end

        @testset "dynamic + negative const: q = &a[lo + 2] - 1" begin
            insts = [_jkf0_preamble(N);
                     IRBinOp(:lo2, :add, ssa(:lo), iconst(2), 8);
                     IRVarGEP(:p, ssa(:a), ssa(:lo2), 8); IRPtrOffset(:q, ssa(:p), -1, 8);
                     IRStore(ssa(:q), iconst(42), 8); _jkf0_observe()]
            oracle = x -> (m = _jkf0_mem(N); m[(_jkf0_u(x) & 1) + 1 + 1] = 42; m[o(x) + 1])
            _jkf0_check(reversible_compile(_jkf0_parsed(insts, ssa(:r)); fold_constants=fold),
                        oracle)
        end

        @testset "dynamic + dynamic: q = &(&a[lo])[hi]" begin
            insts = [_jkf0_preamble(N);
                     IRVarGEP(:p, ssa(:a), ssa(:lo), 8); IRVarGEP(:q, ssa(:p), ssa(:hi), 8);
                     IRStore(ssa(:q), iconst(42), 8); _jkf0_observe()]
            oracle = x -> begin
                m = _jkf0_mem(N)
                m[(_jkf0_u(x) & 1) + ((_jkf0_u(x) >> 1) & 1) + 1] = 42
                m[o(x) + 1]
            end
            _jkf0_check(reversible_compile(_jkf0_parsed(insts, ssa(:r)); fold_constants=fold),
                        oracle)
        end

        @testset "const + dynamic: q = &(a + 1)[lo]" begin
            insts = [_jkf0_preamble(N);
                     IRPtrOffset(:p, ssa(:a), 1, 8); IRVarGEP(:q, ssa(:p), ssa(:lo), 8);
                     IRStore(ssa(:q), iconst(42), 8); _jkf0_observe()]
            oracle = x -> (m = _jkf0_mem(N); m[1 + (_jkf0_u(x) & 1) + 1] = 42; m[o(x) + 1])
            _jkf0_check(reversible_compile(_jkf0_parsed(insts, ssa(:r)); fold_constants=fold),
                        oracle)
        end

        @testset "VarGEP(p, 0) after a dynamic GEP, load after store" begin
            insts = [_jkf0_preamble(N);
                     IRVarGEP(:p, ssa(:a), ssa(:i), 8); IRVarGEP(:q, ssa(:p), iconst(0), 8);
                     IRStore(ssa(:p), iconst(42), 8); IRLoad(:r, ssa(:q), 8)]
            _jkf0_check(reversible_compile(_jkf0_parsed(insts, ssa(:r)); fold_constants=fold),
                        x -> 42)
        end
    end

    @testset "LLVM-verified F2 fixture (C-API walker)" begin
        ir = raw"""
        define i8 @julia_jkf0_f2(i8 %x) {
        top:
          %a = alloca i8, i32 4
          %i = and i8 %x, 3
          %p = getelementptr i8, ptr %a, i8 %i
          %q = getelementptr i8, ptr %p, i32 0
          store i8 42, ptr %p
          %r = load i8, ptr %q
          ret i8 %r
        }
        """
        for fold in (false, true)
            c = nothing
            LLVM.Context() do _ctx
                mod = parse(LLVM.Module, ir)
                LLVM.verify(mod)
                c = reversible_compile(Bennett._module_to_parsed_ir(mod); fold_constants=fold)
                dispose(mod)
            end
            _jkf0_check(c, x -> 42)
        end
    end

    @testset "persistent slab: zero-offset GEP after a const-index GEP" begin
        # Dynamic-size alloca (n = (x & 1) + 2 ≥ 2) routes to :persistent_tree.
        # Slots 0, 1 := 11, 22; p1 = &a[1]; q = p1 + 0 (or &p1[0]) must read 22.
        function pers(qinst)
            insts = IRInst[
                IRBinOp(:b, :and, ssa(:x), iconst(1), 8),
                IRBinOp(:n, :add, ssa(:b), iconst(2), 8),
                IRAlloca(:a, 8, ssa(:n)),
                IRVarGEP(:p0, ssa(:a), iconst(0), 8), IRStore(ssa(:p0), iconst(11), 8),
                IRVarGEP(:p1, ssa(:a), iconst(1), 8), IRStore(ssa(:p1), iconst(22), 8),
                qinst, IRLoad(:r, ssa(:q), 8)]
            lr = Bennett.lower(_jkf0_parsed(insts, ssa(:r)); mem=:persistent)
            return Bennett.bennett(lr)
        end
        _jkf0_check(pers(IRPtrOffset(:q, ssa(:p1), 0, 8)), x -> 22)
        _jkf0_check(pers(IRVarGEP(:q, ssa(:p1), iconst(0), 8)), x -> 22)
        _jkf0_check(pers(IRVarGEP(:q, ssa(:a), iconst(1), 8)), x -> 22)   # control
    end
end
