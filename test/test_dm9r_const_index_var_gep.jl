using Test
using Bennett
using LLVM
using Bennett: IRInst, IRBasicBlock, IRBinOp, IRRet, IRAlloca, IRStore, IRLoad,
    IRVarGEP, IRPtrOffset, ParsedIR, ssa, iconst

# Bennett-dm9r: an `IRVarGEP` whose index is a CONSTANT, applied to a plain
# (non-persistent) alloca, crashed in `lower_var_gep!` with the internal
# "resolve!: width=0" error — the legacy MUX-tree view resolved the index at
# width 0. The extractor emits exactly this node for the two-index array GEP
# `getelementptr [N x iM], ptr %a, i64 0, i64 K` (clang -O0 for `a[K]` on a
# local C array; Case C in `src/extract/instructions.jl`). Fix: a constant
# index is the constant byte offset `K * elem_width/8`, lowered by the
# existing `lower_ptr_offset!` (provenance + legacy slice).
#
# Every case sweeps all 256 Int8 inputs against an independent memory oracle,
# folding on and off; `simulate` asserts ancilla-zero + input preservation.

const _DM9R_XS = typemin(Int8):typemax(Int8)
_dm9r_u(x) = Int(reinterpret(UInt8, x))

function _dm9r_check(c, oracle)
    bad = [(x, simulate(c, x), oracle(x)) for x in _DM9R_XS if simulate(c, x) != oracle(x)]
    isempty(bad) || @info "Bennett-dm9r mismatches" first(bad, 4)
    @test isempty(bad)
    @test verify_reversibility(c)
end

_dm9r_parsed(insts, ret) =
    ParsedIR(8, [(:x, 8)], [IRBasicBlock(:entry, IRInst[insts...], IRRet(ret, 8))], [8])

# N-slot i8 array a[j] := 10 + j; o = (x >> 2) & (N-1) is a runtime
# observation index (read through a separate runtime GEP).
function _dm9r_preamble(N; ew=8)
    insts = IRInst[IRAlloca(:a, ew, iconst(N))]
    for j in 0:N-1
        push!(insts, IRPtrOffset(Symbol(:init, j), ssa(:a), j * (ew ÷ 8), ew))
        push!(insts, IRStore(ssa(Symbol(:init, j)), iconst(10 + j), ew))
    end
    append!(insts, IRInst[IRBinOp(:xs2, :lshr, ssa(:x), iconst(2), 8),
                          IRBinOp(:o, :and, ssa(:xs2), iconst(N - 1), 8),
                          IRBinOp(:i, :and, ssa(:x), iconst(N - 1), 8)])
    return insts
end

_dm9r_mem(N) = [10 + j for j in 0:N-1]

function _dm9r_compile_ll(ir; fold)
    c = nothing
    LLVM.Context() do _ctx
        mod = parse(LLVM.Module, ir)
        LLVM.verify(mod)
        c = reversible_compile(Bennett._module_to_parsed_ir(mod); fold_constants=fold)
        dispose(mod)
    end
    return c
end

@testset "Bennett-dm9r — constant-index VarGEP on a plain alloca" begin

    @testset "N=$N k=$k fold=$fold" for (N, ks) in ((4, 0:3), (8, (0, 5, 7))),
                                         k in ks, fold in (false, true)
        o(x) = (_dm9r_u(x) >> 2) & (N - 1)

        # store x through &a[k] (constant VarGEP), read back through it
        insts = [_dm9r_preamble(N); IRVarGEP(:p, ssa(:a), iconst(k), 8);
                 IRStore(ssa(:p), ssa(:x), 8); IRLoad(:r, ssa(:p), 8)]
        _dm9r_check(reversible_compile(_dm9r_parsed(insts, ssa(:r)); fold_constants=fold),
                    x -> x)

        # store x through &a[k], observe a[o] through a runtime GEP
        insts = [_dm9r_preamble(N); IRVarGEP(:p, ssa(:a), iconst(k), 8);
                 IRStore(ssa(:p), ssa(:x), 8);
                 IRVarGEP(:po, ssa(:a), ssa(:o), 8); IRLoad(:r, ssa(:po), 8)]
        oracle = x -> (m = _dm9r_mem(N); m[k + 1] = _dm9r_u(x); m[o(x) + 1] % Int8)
        _dm9r_check(reversible_compile(_dm9r_parsed(insts, ssa(:r)); fold_constants=fold),
                    oracle)

        # store x through a runtime GEP &a[i], read a[k] through the constant GEP
        insts = [_dm9r_preamble(N); IRVarGEP(:pi, ssa(:a), ssa(:i), 8);
                 IRStore(ssa(:pi), ssa(:x), 8);
                 IRVarGEP(:p, ssa(:a), iconst(k), 8); IRLoad(:r, ssa(:p), 8)]
        oracle = x -> (m = _dm9r_mem(N); m[(_dm9r_u(x) & (N - 1)) + 1] = _dm9r_u(x);
                       m[k + 1] % Int8)
        _dm9r_check(reversible_compile(_dm9r_parsed(insts, ssa(:r)); fold_constants=fold),
                    oracle)
    end

    @testset "GEP-on-GEP: q = &(&a[i])[1] (constant VarGEP off a dynamic GEP)" begin
        for fold in (false, true)
            N = 8
            insts = [_dm9r_preamble(N); IRBinOp(:i3, :and, ssa(:x), iconst(3), 8);
                     IRVarGEP(:p, ssa(:a), ssa(:i3), 8); IRVarGEP(:q, ssa(:p), iconst(1), 8);
                     IRStore(ssa(:q), iconst(42), 8);
                     IRVarGEP(:po, ssa(:a), ssa(:o), 8); IRLoad(:r, ssa(:po), 8)]
            oracle = x -> (m = _dm9r_mem(N); m[(_dm9r_u(x) & 3) + 1 + 1] = 42;
                           m[((_dm9r_u(x) >> 2) & 7) + 1])
            _dm9r_check(reversible_compile(_dm9r_parsed(insts, ssa(:r)); fold_constants=fold),
                        oracle)
        end
    end

    @testset "byte-unit constant VarGEP on an i16 alloca (stride conversion)" begin
        # `gep i8, ptr %a, 2` on an i16 array addresses element 1, not 2.
        for fold in (false, true)
            N = 4
            insts = [_dm9r_preamble(N; ew=16); IRVarGEP(:p, ssa(:a), iconst(2), 8);
                     IRStore(ssa(:p), iconst(77), 16);
                     IRVarGEP(:po, ssa(:a), ssa(:o), 16); IRLoad(:r16, ssa(:po), 16);
                     Bennett.IRCast(:r, :trunc, ssa(:r16), 16, 8)]
            oracle = x -> (m = _dm9r_mem(N); m[1 + 1] = 77; m[((_dm9r_u(x) >> 2) & 3) + 1])
            _dm9r_check(reversible_compile(_dm9r_parsed(insts, ssa(:r)); fold_constants=fold),
                        oracle)
        end
        # an odd byte index lands inside an i16 element: loud refusal (Bennett-ixiz)
        insts = [_dm9r_preamble(4; ew=16); IRVarGEP(:p, ssa(:a), iconst(1), 8);
                 IRStore(ssa(:p), iconst(77), 16); IRLoad(:r16, ssa(:p), 16);
                 Bennett.IRCast(:r, :trunc, ssa(:r16), 16, 8)]
        @test_throws DimensionMismatch reversible_compile(_dm9r_parsed(insts, ssa(:r)))
    end

    @testset "sub-byte element width with a constant index is refused" begin
        insts = [IRAlloca(:a, 8, iconst(4)); IRVarGEP(:p, ssa(:a), iconst(1), 4);
                 IRLoad(:r, ssa(:p), 8)]
        err = try
            reversible_compile(_dm9r_parsed(insts, ssa(:r))); nothing
        catch e
            e
        end
        @test err isa ArgumentError && occursin("Bennett-dm9r", sprint(showerror, err))
    end

    @testset "LLVM fixture: two-index array GEP with a constant index (C -O0 shape)" begin
        # uint16_t a[4] = {10,11,12,13}; a[2] = (int16_t)x; return (int8_t)a[(x>>2)&3];
        ir = raw"""
        define i8 @julia_dm9r(i8 %x) {
        top:
          %a = alloca [4 x i16]
          %a0 = getelementptr inbounds [4 x i16], ptr %a, i64 0, i64 0
          store i16 10, ptr %a0
          %a1 = getelementptr inbounds [4 x i16], ptr %a, i64 0, i64 1
          store i16 11, ptr %a1
          %a2 = getelementptr inbounds [4 x i16], ptr %a, i64 0, i64 2
          store i16 12, ptr %a2
          %a3 = getelementptr inbounds [4 x i16], ptr %a, i64 0, i64 3
          store i16 13, ptr %a3
          %xw = sext i8 %x to i16
          %p = getelementptr inbounds [4 x i16], ptr %a, i64 0, i64 2
          store i16 %xw, ptr %p
          %s = lshr i8 %x, 2
          %o = and i8 %s, 3
          %po = getelementptr inbounds [4 x i16], ptr %a, i64 0, i8 %o
          %v = load i16, ptr %po
          %r = trunc i16 %v to i8
          ret i8 %r
        }
        """
        oracle = x -> (m = [10, 11, 12, 13]; m[3] = _dm9r_u(x); m[((_dm9r_u(x) >> 2) & 3) + 1] % Int8)
        for fold in (false, true)
            _dm9r_check(_dm9r_compile_ll(ir; fold), oracle)
        end
    end
end
