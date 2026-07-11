using Test
using Bennett
using Bennett: extract_parsed_ir, extract_parsed_ir_from_ll,
               extract_parsed_ir_set_from_julia, register_callee!
using Bennett: IRRet, IRCall, IRAlloca, SSAOperand

# Bennett bennettvm-416r.17 — sret-forwarding ptr-cell argument carry.
#
# Root cause: under `ptr_cells=true`, the Wall-A sret-forwarding recognizer
# `_try_handle_sret_memcpy_reject!` built the forwarded `SretCallReturn` args
# with an INTEGER-ONLY loop (`ot isa LLVM.IntegerType || continue`) that
# predated the first-class-function cell world. That silently DROPPED every
# pointer operand of the producing call — including the callee-ABI-required
# `h::Dict` cell — so the recursive `ht_keyindex2_shorthash!` call forwarded
# only `[key]` (widths `[8]`) instead of `[h, key]` (widths `[64, 8]`). The
# consumed-call path already did this right via `_cell_call_args`.
#
# Fix: on the ptr_cells=true forwarding path, build the args via
# `_cell_call_args(...; skip_sret=true)` — carry ptr operands as 64-bit cells,
# integers at their own width, and elide the sret-out box by its call-site
# `sret` attribute (the forwarded box is a local temp whose aggregate IS this
# block's IRRet; LangRef permits ≤1 sret param ⇒ exactly one skip). The
# ptr_cells=false branch stays the integer-only loop VERBATIM (gate baselines
# pin it — Rule 6).

# x86-64 SysV datalayout (matches Julia's; {i64,i8} → 16 padded bytes).
const _416r17_dl =
    "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"

function _416r17_write_ll(body::String)
    path = tempname() * ".ll"
    open(path, "w") do io
        write(io, "target datalayout = \"$_416r17_dl\"\n\n")
        write(io, body)
    end
    return path
end

# A registered Julia leaf for the Function-callee arm. Resolution is by NAME
# only (`_lookup_callee("leafY416r17")` → this Function), so the Julia signature
# need not match the .ll declare — extraction only records the callee object.
leafY416r17(k::Int8) = (Int64(k) + 7, k)

@testset "bennettvm-416r.17 sret-forwarding ptr-cell arg carry" begin

    # =====================================================================
    # (a) Synthetic Symbol-callee (C-track) forwarding fixture.
    #     @callerX forwards @leafX's {i64,i8} aggregate via a local box +
    #     whole-aggregate memcpy into its own sret. @leafX takes a POINTER
    #     arg (%h) plus an i8 (%k) — this is the operand the buggy loop drops.
    # =====================================================================
    callerX_body = """
    declare void @leafX416r17(ptr sret({i64,i8}), ptr, i8)
    define void @callerX416r17(ptr noalias nocapture sret({i64,i8}) align 8 %out, ptr %h, i8 signext %k) {
    top:
      %box = alloca [2 x i64], align 8
      call void @leafX416r17(ptr noalias nocapture sret({i64,i8}) align 8 %box, ptr %h, i8 signext %k)
      call void @llvm.memcpy.p0.p0.i64(ptr align 8 %out, ptr align 8 %box, i64 16, i1 false)
      ret void
    }
    declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)
    """

    @testset "Symbol-callee: ptr_cells=true carries the ptr as a 64-bit cell" begin
        path = _416r17_write_ll(callerX_body)
        pir = extract_parsed_ir_from_ll(path;
                  entry_function="callerX416r17", ptr_cells=true)
        @test pir.ret_width == 72
        @test pir.ret_elem_widths == [64, 8]
        blk = only(pir.blocks)
        @test blk.terminator isa IRRet
        calls = filter(i -> i isa IRCall, blk.instructions)
        @test length(calls) == 1
        @test calls[1].callee === :leafX416r17         # name-only → Symbol
        @test calls[1].ret_width == 72                 # PARENT sret packed width
        @test calls[1].arg_widths == [64, 8]           # [h(cell), k] — THE FIX
        @test length(calls[1].args) == 2
        @test calls[1].args[1] isa SSAOperand          # the %h cell operand
        @test !any(i -> i isa IRAlloca, blk.instructions)  # box suppressed
    end

    @testset "Symbol-callee: ptr_cells=false drops the ptr (byte-identical)" begin
        path = _416r17_write_ll(callerX_body)
        pir = extract_parsed_ir_from_ll(path;
                  entry_function="callerX416r17", ptr_cells=false)
        blk = only(pir.blocks)
        calls = filter(i -> i isa IRCall, blk.instructions)
        @test length(calls) == 1
        @test calls[1].callee === :leafX416r17
        @test calls[1].ret_width == 72
        @test calls[1].arg_widths == [8]               # ptr dropped (old policy)
        @test length(calls[1].args) == 1
    end

    # =====================================================================
    # (b) Function-callee variant: the P9 Function arm carries the ptr cell.
    # =====================================================================
    callerY_body = """
    declare void @leafY416r17(ptr sret({i64,i8}), ptr, i8)
    define void @callerY416r17(ptr noalias nocapture sret({i64,i8}) align 8 %out, ptr %h, i8 signext %k) {
    top:
      %box = alloca [2 x i64], align 8
      call void @leafY416r17(ptr noalias nocapture sret({i64,i8}) align 8 %box, ptr %h, i8 signext %k)
      call void @llvm.memcpy.p0.p0.i64(ptr align 8 %out, ptr align 8 %box, i64 16, i1 false)
      ret void
    }
    declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)
    """

    @testset "Function-callee: resolved Function + ptr cell carried" begin
        register_callee!(leafY416r17)
        path = _416r17_write_ll(callerY_body)
        pir = extract_parsed_ir_from_ll(path;
                  entry_function="callerY416r17", ptr_cells=true)
        blk = only(pir.blocks)
        calls = filter(i -> i isa IRCall, blk.instructions)
        @test length(calls) == 1
        @test calls[1].callee === leafY416r17          # resolved Function, not Symbol
        @test calls[1].arg_widths == [64, 8]
        @test calls[1].ret_width == 72
    end

    # =====================================================================
    # (c) Natural integration pin: the fdict_d1b closed-world set (~1-2 min).
    #     The recursive ht_keyindex2_shorthash! call (Wall-A FORWARDING path,
    #     the 416r.17 bug site) must forward [h, key] widths [64, 8] — UNTOUCHED
    #     by 416r.16. The consumed setindex! call was RECONCILED by bennettvm-
    #     416r.16 to the VALUE ABI: the sret_box arg dropped, ret_width the packed
    #     aggregate width 72 (was the pre-416r.16 box-cell-arg [64,64,8]/64).
    # =====================================================================
    @testset "natural pin: fdict_d1b recursive + consumed calls" begin
        fdict_d1b(a::Int8, b::Int8) = (d = Dict{Int8,Int8}(); d[a] = b; d[a])
        # on_extract_error=:skip: some deeper callees (or a check-bounds=yes
        # U114 struct-store wall on ht_keyindex2 itself, Bennett-583s successor)
        # may fail; :skip keeps the members that DID extract so the pin is
        # robust across bounds modes (mirrors test_59zi's check-bounds guard).
        set = extract_parsed_ir_set_from_julia(fdict_d1b, Tuple{Int8,Int8};
                  ptr_cells=true, on_extract_error=:skip)

        htk_i = findfirst(p -> startswith(string(p.first),
                                          "ht_keyindex2_shorthash!"), set)
        if htk_i !== nothing
            pir = set[htk_i].second
            rec = [i for b in pir.blocks for i in b.instructions
                   if i isa IRCall && i.callee === Base.ht_keyindex2_shorthash!]
            @test length(rec) == 1
            @test length(rec[1].args) == 2
            @test rec[1].arg_widths == [64, 8]         # THE BUG (was [8])
            @test rec[1].ret_width == 72               # PARENT sret packed width
            @test rec[1].args[1] isa SSAOperand        # the h::Dict cell operand
            @test rec[1].arg_widths[1] == 64           # h carried as a cell
        else
            @info "ht_keyindex2 absent from set (deeper wall) — recursive pin skipped"
            @test true
        end

        si_i = findfirst(p -> startswith(string(p.first), "setindex!"), set)
        if si_i !== nothing
            pir = set[si_i].second
            cons = [i for b in pir.blocks for i in b.instructions
                    if i isa IRCall && i.callee === Base.ht_keyindex2_shorthash!]
            @test length(cons) == 1
            # Consumed-call path — RECONCILED by bennettvm-416r.16 to value ABI:
            @test cons[1].arg_widths == [64, 8]        # [h, key] (sret_box dropped)
            @test cons[1].ret_width == 72              # value ABI (was 64)
        else
            @info "setindex! absent from set (deeper wall) — consumed pin skipped"
            @test true
        end
    end
end
