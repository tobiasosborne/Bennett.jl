using Test
using Bennett
using Bennett: ParsedIR, IRBasicBlock, IRInst, IRLoad, IRBinOp, IRRet, IRBranch,
               ssa, iconst

# Bennett-sy9t: `_lower_load_legacy!` used to `return` silently when the load's
# pointer had neither a ptr_provenance entry nor a wire binding ("may be
# pgcstack safepoint load"), leaving `vw[dest]` unbound. A USED result then
# failed later with an unrelated undefined-SSA error; a DEAD one vanished.
#
# Invariant: every IRLoad from a pointer with no wires is refused at the load,
# with a message naming the dest, the pointer and the width — whether or not
# the result is used, in any block, at any width. No dead-load allowlist: an
# empirical sweep of the suite never reached the skip branch.

const _SY9T_MSG = "unknown-pointer loads are refused, not skipped"

# used=true  : ret (x + load)        — the load result feeds the return
# used=false : ret x, load is dead   — formerly compiled silently
function _sy9t_ir(W::Int; used::Bool, ptr = ssa(:q), in_entry::Bool = true)
    load = IRLoad(:v, ptr, W)
    body = used ? IRInst[load, IRBinOp(:r, :add, ssa(:x), ssa(:v), W)] :
                  IRInst[load, IRBinOp(:r, :add, ssa(:x), iconst(1), W)]
    if in_entry
        blocks = [IRBasicBlock(:entry, body, IRRet(ssa(:r), W))]
    else
        blocks = [IRBasicBlock(:entry, IRInst[], IRBranch(nothing, :next, nothing)),
                  IRBasicBlock(:next, body, IRRet(ssa(:r), W))]
    end
    ParsedIR(W, [(:x, W)], blocks, [W])
end

@testset "Bennett-sy9t: unknown-pointer load is refused, not skipped" begin

    @testset "W=$W used=$used in_entry=$in_entry" for W in (1, 8, 16, 32, 64),
                                                    used in (true, false),
                                                    in_entry in (true, false)
        ir = _sy9t_ir(W; used, in_entry)
        err = try
            reversible_compile(ir)
            nothing
        catch e
            e
        end
        @test err isa ErrorException
        msg = err === nothing ? "" : sprint(showerror, err)
        @test occursin(_SY9T_MSG, msg)
        @test occursin("%v", msg)          # dest named
        @test occursin("%q", msg)          # pointer named
        @test occursin("width $W", msg)    # width named
    end

    @testset "non-SSA pointer operand (constant) is refused" begin
        ir = _sy9t_ir(8; used = true, ptr = iconst(0))
        @test_throws _SY9T_MSG reversible_compile(ir)
    end

    @testset "known-pointer loads (NTuple input) still compile and match native" begin
        pack(t) = foldl((acc, (i, v)) -> acc | (UInt64(reinterpret(UInt8, v)) << (8 * (i - 1))),
                        enumerate(t); init = UInt64(0))
        f(t::NTuple{2, Int8})::Int8 = t[1] - t[2]
        c = reversible_compile(f, Tuple{NTuple{2, Int8}})
        for a in typemin(Int8):typemax(Int8), b in Int8(-8):Int8(7)
            @test Int8(simulate(c, pack((a, b)))) == f((a, b))
        end
        @test verify_reversibility(c)
    end
end
