using Test
using Bennett
using Bennett: IRInst, IRBasicBlock, IRBinOp, IRVarGEP, IRLoad, IRCall, IRRet,
    ParsedIR, ssa, iconst

# Bennett-9k7n — `lower_call!` mapped callee wire k to `wire_count(wa) + k`,
# assuming `allocate!` returned one contiguous block. A preceding QROM lookup
# (constant-table IRVarGEP → `_emit_qrom_from_gep!`) frees its scratch wires,
# so `allocate!` handed back those holes first and the remapped callee landed
# on wires it never reserved. Silent miscompile with verify_reversibility=true
# (Astra 2026-09-26 B-lowering F7 / B-arith F1).

inc8_9k7n(x::UInt8) = x + UInt8(1)

# table[x & mask] → inc8 → optionally (+ k). Oracle: (x & mask) + 1 + k.
function _9k7n_ir(nentries::Int, post_add::Int)
    mask = nentries - 1
    insts = IRInst[IRBinOp(:i, :and, ssa(:x), iconst(mask), 8),
                   IRVarGEP(:p, ssa(:table), ssa(:i), 8),
                   IRLoad(:v, ssa(:p), 8),
                   IRCall(:c, inc8_9k7n, [ssa(:v)], [8], 8)]
    ret = :c
    if post_add != 0
        push!(insts, IRBinOp(:r, :add, ssa(:c), iconst(post_add), 8))
        ret = :r
    end
    ParsedIR(8, [(:x, 8)], [IRBasicBlock(:entry, insts, IRRet(ssa(ret), 8))],
             [8], Dict(:table => (UInt64.(0:nentries-1), 8)))
end

@testset "Bennett-9k7n: callee wire remap survives free-list reuse" begin
    @testset "ParsedIR QROM → call: n=$n post=$post compact=$cc fold=$fc" for
            n in (16, 32, 64), post in (0, 3), cc in (false, true), fc in (false, true)
        c = reversible_compile(_9k7n_ir(n, post); compact_calls=cc, fold_constants=fc)
        bad = 0
        for x in typemin(Int8):typemax(Int8)
            expected = (Int(x) & (n - 1)) + 1 + post     # ≤ 67, fits Int8
            # Pre-fix the non-compact shape also threw dirty-ancilla errors.
            got = try simulate(c, x) catch; nothing end
            got == expected || (bad += 1)
        end
        @test bad == 0
        @test verify_reversibility(c)
    end
end

const _TAB_9K7N = ntuple(i -> UInt8(i - 1), 32)
@noinline inc_9k7n(x::UInt8) = x + UInt8(1)
Bennett.register_callee!(inc_9k7n)
lookup_9k7n(x::UInt8) = inc_9k7n(_TAB_9K7N[Int(x & UInt8(31)) + 1])

@testset "Bennett-9k7n: Julia const-table → registered callee" begin
    @testset "optimize=$opt compact=$cc" for opt in (false, true), cc in (false, true)
        c = reversible_compile(lookup_9k7n, UInt8; optimize=opt, compact_calls=cc)
        bad = 0
        for x in typemin(UInt8):typemax(UInt8)
            got = try simulate(c, x) catch; nothing end
            got == lookup_9k7n(x) || (bad += 1)
        end
        @test bad == 0
        @test verify_reversibility(c)
    end
end
