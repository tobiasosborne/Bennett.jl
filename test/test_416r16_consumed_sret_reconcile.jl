# Bennett bennettvm-416r.16 — caller-side CONSUMED-sret reconciliation.
#
# The LAST static wall of the CW-D fdict chain. `setindex!`'s
# `ht_keyindex2_shorthash!(sret_box, h, key)` call returns `{i64,i8}` by sret
# into a LOCAL alloca box whose fields setindex! reads back (NOT forwards to a
# parent sret). Pre-416r.16 that extracted (Bennett-xrd6) as a box-cell-arg
# IRCall (ret_width=64) + IRLoads off the box — the sret_box MEMORY ABI, which
# BennettVM's guard-5 walls on (callee returns a 72-bit aggregate, ret_width 64
# ≠ 72). The reconciliation (ptr_cells-gated) rewrites it to the VALUE ABI BVM
# ingests: box alloca SUPPRESSED, call `ret_width = Σ field widths` (72), field
# loads → `IRExtractValue` reading the call's aggregate slots.
#
# The field byte offsets {0,8} are `{i64,i8}`'s x86-64 SysV layout, read from
# the call-site `sret(<ty>)` pointee via the datalayout (NEVER reconstructed
# from widths — hetero structs have padding). Gated on `ptr_cells=true` (Rule
# 6): the circuit path is byte-identical.

using Test
using Bennett
using Bennett: extract_parsed_ir_from_ll, extract_parsed_ir_set_from_julia,
               register_callee!
using Bennett: IRCall, IRAlloca, IRLoad, IRPtrOffset, IRExtractValue, SSAOperand

# x86-64 SysV datalayout (matches Julia's; {i64,i8} → fields at bytes 0 and 8).
const _416r16_dl =
    "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"

function _416r16_write_ll(body::String)
    path = tempname() * ".ll"
    open(path, "w") do io
        write(io, "target datalayout = \"$_416r16_dl\"\n\n")
        write(io, body)
    end
    return path
end

# Assert .ll extraction of `name` rejects with a message containing `needle`.
function _416r16_reject(name::String, body::String, needle::String;
                        ptr_cells::Bool=true)
    path = _416r16_write_ll(body)
    threw = false
    try
        extract_parsed_ir_from_ll(path; entry_function=name, ptr_cells=ptr_cells)
    catch e
        e isa InterruptException && rethrow()
        threw = true
        msg = sprint(showerror, e)
        occursin(needle, msg) || @info "416r.16 reject message mismatch" name needle msg
        @test occursin(needle, msg)
    end
    @test threw
end

# Registered Function leaf (name-only resolution; the Julia signature is nominal).
leafZ416r16(k::Int8) = (Int64(k) + 3, k)

@testset "bennettvm-416r.16 consumed-sret reconciliation" begin

    # =====================================================================
    # (A) Synthetic Symbol-callee (C-track) consumed fixture. @callerZ calls
    #     @leafZ (UNregistered → Symbol callee) whose {i64,i8} sret-out box is
    #     read: field 0 (i64) directly, field 1 (i8) via a byte-8 GEP. The
    #     caller sums them and returns i64.
    # =====================================================================
    callerZ_body = """
    declare void @leafZ416r16u(ptr sret({i64,i8}), ptr, i8)
    define i64 @callerZ416r16(ptr %h, i8 signext %k) {
    top:
      %box = alloca [2 x i64], align 8
      call void @leafZ416r16u(ptr sret({i64,i8}) %box, ptr %h, i8 signext %k)
      %f0 = load i64, ptr %box, align 8
      %g = getelementptr inbounds i8, ptr %box, i64 8
      %f1 = load i8, ptr %g, align 1
      %f1e = zext i8 %f1 to i64
      %r = add i64 %f0, %f1e
      ret i64 %r
    }
    """

    @testset "Symbol-callee: box suppressed, call value-ABI, loads → extractvalue" begin
        path = _416r16_write_ll(callerZ_body)
        pir = extract_parsed_ir_from_ll(path;
                  entry_function="callerZ416r16", ptr_cells=true)
        allinsts = [i for b in pir.blocks for i in b.instructions]

        # Box alloca SUPPRESSED, GEP SUPPRESSED, no leftover box IRLoad.
        @test !any(i -> i isa IRAlloca, allinsts)
        @test !any(i -> i isa IRPtrOffset, allinsts)

        # Exactly one IRCall: value-ABI, Symbol callee, [h(cell), k], rw 72.
        calls = filter(i -> i isa IRCall, allinsts)
        @test length(calls) == 1
        c = calls[1]
        @test c.callee === :leafZ416r16u          # name-only → Symbol
        @test c.arg_widths == [64, 8]             # box dropped; [h(cell), k]
        @test length(c.args) == 2
        @test c.args[1] isa SSAOperand            # the %h cell operand
        @test c.ret_width == 72                   # Σ field widths {64,8}
        agg = c.dest

        # The two field reads are IRExtractValue against the call's aggregate,
        # dense field index, hetero field_widths, dest names PRESERVED.
        evs = filter(i -> i isa IRExtractValue, allinsts)
        @test length(evs) == 2
        f0 = only(filter(e -> e.dest === :f0, evs))
        f1 = only(filter(e -> e.dest === :f1, evs))
        @test f0.index == 0
        @test f1.index == 1
        for e in evs
            @test e.agg isa SSAOperand && e.agg.name === agg
            @test e.field_widths == [64, 8]
            @test e.n_elems == 2
        end
    end

    # =====================================================================
    # (B) Function-callee variant: resolved Function carried, same value ABI.
    # =====================================================================
    callerY_body = """
    declare void @leafZ416r16(ptr sret({i64,i8}), ptr, i8)
    define i64 @callerY416r16(ptr %h, i8 signext %k) {
    top:
      %box = alloca [2 x i64], align 8
      call void @leafZ416r16(ptr sret({i64,i8}) %box, ptr %h, i8 signext %k)
      %f0 = load i64, ptr %box, align 8
      %g = getelementptr inbounds i8, ptr %box, i64 8
      %f1 = load i8, ptr %g, align 1
      %f1e = zext i8 %f1 to i64
      %r = add i64 %f0, %f1e
      ret i64 %r
    }
    """

    @testset "Function-callee: resolved Function carried" begin
        register_callee!(leafZ416r16)
        path = _416r16_write_ll(callerY_body)
        pir = extract_parsed_ir_from_ll(path;
                  entry_function="callerY416r16", ptr_cells=true)
        allinsts = [i for b in pir.blocks for i in b.instructions]
        calls = filter(i -> i isa IRCall, allinsts)
        @test length(calls) == 1
        @test calls[1].callee === leafZ416r16     # resolved Function, not Symbol
        @test calls[1].arg_widths == [64, 8]
        @test calls[1].ret_width == 72
        @test !any(i -> i isa IRAlloca, allinsts)
    end

    # =====================================================================
    # (C) Fail-loud fixtures (ptr_cells=true). Each ALMOST-matches the consumed
    #     shape but breaks an invariant → loud reject (Rule 1), never a silent
    #     fall-through to a miscompile.
    # =====================================================================
    @testset "fail-loud: box escapes / unknown offset / store-into-box" begin
        register_callee!(leafZ416r16)

        # box address ESCAPES via ptrtoint.
        _416r16_reject("cEsc", """
        declare void @leafZ416r16(ptr sret({i64,i8}), ptr, i8)
        define i64 @cEsc(ptr %h, i8 signext %k) {
        top:
          %box = alloca [2 x i64], align 8
          call void @leafZ416r16(ptr sret({i64,i8}) %box, ptr %h, i8 signext %k)
          %p = ptrtoint ptr %box to i64
          ret i64 %p
        }
        """, "bennettvm-416r.16")

        # GEP byte offset 4 matches NO field ({i64,i8} fields at {0,8}).
        _416r16_reject("cOff", """
        declare void @leafZ416r16(ptr sret({i64,i8}), ptr, i8)
        define i64 @cOff(ptr %h, i8 signext %k) {
        top:
          %box = alloca [2 x i64], align 8
          call void @leafZ416r16(ptr sret({i64,i8}) %box, ptr %h, i8 signext %k)
          %g = getelementptr inbounds i8, ptr %box, i64 4
          %f = load i32, ptr %g, align 4
          %fe = zext i32 %f to i64
          ret i64 %fe
        }
        """, "bennettvm-416r.16")

        # a store writes INTO the callee-written box.
        _416r16_reject("cStore", """
        declare void @leafZ416r16(ptr sret({i64,i8}), ptr, i8)
        define i64 @cStore(ptr %h, i8 signext %k) {
        top:
          %box = alloca [2 x i64], align 8
          call void @leafZ416r16(ptr sret({i64,i8}) %box, ptr %h, i8 signext %k)
          store i64 0, ptr %box, align 8
          %f0 = load i64, ptr %box, align 8
          ret i64 %f0
        }
        """, "bennettvm-416r.16")
    end

    # =====================================================================
    # (D) GATE pin: with ptr_cells=FALSE the reconciliation is INERT. The void
    #     sret call then falls to the gate-inlining arm → the pre-existing U81
    #     VoidType wall fires (mirrors test_xrd6's c_cells_off). Proves the
    #     recognizer is ptr_cells-gated (Rule 6): off ⇒ old behaviour, NOT a
    #     silent value-ABI rewrite.
    # =====================================================================
    @testset "ptr_cells=false: reconciliation inert (pre-416r.16 wall fires)" begin
        register_callee!(leafZ416r16)
        _416r16_reject("callerY416r16", callerY_body, "VoidType reached";
                       ptr_cells=false)
    end

    # =====================================================================
    # (E) Natural pin: the fdict_d1b closed-world set. setindex!'s consumed
    #     ht_keyindex2_shorthash! call must be value-ABI (rw 72, [h,key]), the
    #     box alloca gone, and the 5 former box loads all IRExtractValue with
    #     field indices {0,0,0,0,1}. Guarded by findfirst-presence (a deeper
    #     wall under some bounds modes may :skip setindex!, mirroring test_59zi /
    #     test_416r17).
    # =====================================================================
    @testset "natural pin: fdict_d1b setindex! consumed call reconciled" begin
        fdict_d1b(a::Int8, b::Int8) = (d = Dict{Int8,Int8}(); d[a] = b; d[a])
        set = extract_parsed_ir_set_from_julia(fdict_d1b, Tuple{Int8,Int8};
                  ptr_cells=true, on_extract_error=:skip)

        si_i = findfirst(p -> startswith(string(p.first), "setindex!"), set)
        if si_i !== nothing
            pir = set[si_i].second
            allinsts = [i for b in pir.blocks for i in b.instructions]

            # NO sret_box IRAlloca survives.
            @test !any(i -> i isa IRAlloca && i.dest === :sret_box, allinsts)

            # The consumed ht_keyindex2 call is value-ABI: [h, key], rw 72.
            kx = [i for i in allinsts if i isa IRCall &&
                  i.callee === Base.ht_keyindex2_shorthash!]
            @test length(kx) == 1
            @test kx[1].arg_widths == [64, 8]      # box dropped (was [64,64,8])
            @test kx[1].ret_width == 72            # value ABI (was 64)
            @test length(kx[1].args) == 2
            agg = kx[1].dest

            # The 5 former box field loads are now IRExtractValue against the
            # call's aggregate with indices {0,0,0,0,1}; NO box IRLoad remains.
            evs = [i for i in allinsts if i isa IRExtractValue &&
                   i.agg isa SSAOperand && i.agg.name === agg]
            @test length(evs) == 5
            @test sort([e.index for e in evs]) == [0, 0, 0, 0, 1]
            @test all(e -> e.field_widths == [64, 8], evs)
            # No load reads the (now-suppressed) sret_box or its GEP.
            @test !any(i -> i isa IRLoad &&
                            i.ptr isa SSAOperand &&
                            occursin("sret_box", string(i.ptr.name)), allinsts)
            @test !any(i -> i isa IRPtrOffset &&
                            occursin("sret_box", string(i.dest)), allinsts)
        else
            @info "setindex! absent from fdict set (deeper wall) — natural pin skipped"
            @test true
        end
    end
end
