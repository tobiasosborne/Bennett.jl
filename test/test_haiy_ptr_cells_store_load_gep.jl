# Bennett-haiy / BVM ADR 0020 (CW-C2 chunk B) — D3 + D4 under the `ptr_cells` gate.
#
# This is the Bennett.jl-side implementation of chunk B of the BennettVM
# closed-world C-track front-end contract (BennettVM.jl
# docs/adr/0020-c-track-frontend-contract.md, Decisions 3+4). It builds on
# chunk A (Bennett-k3ej: IRCall Symbol callee + C ptr-parameter model).
#
# THE GATE. Chunk B introduces ONE explicit extraction-mode switch — the
# `ptr_cells::Bool=false` kwarg on `extract_parsed_ir_from_ll` (threaded
# down through `_extract_from_module` → `_module_to_parsed_ir(_on_func)` →
# `_convert_instruction`). It is the single switch the C track flips. The
# Julia circuit / `mem=:heap` models are protected by a set of fail-louds —
# the `store ptr` U114 wall, the silent-nothing `load ptr`, the two-index
# GEP U16 reject, the `ptr`/`void` return-width walls — and those MUST keep
# firing byte-identically for the default (gate-off) path. ALL of chunk-B
# acceptance is gated on `ptr_cells=true`.
#
#   D3 (gate-on): `store ptr %v, ptr %p` → 64-bit `IRStore` (a pointer value
#       is one Int64 VM cell, ADR 0018 §A); `load ptr` → 64-bit `IRLoad`; a
#       `ptr` RETURN type → `ret_width = 64`. `void` RETURN is NOT handled
#       here — it entangles with the `IRRet` shape (`op::IROperand` +
#       `width >= 1`), so it is left for chunk C (D5). `ht_free`/`ht_put`
#       (`ret void`) therefore stay at the existing VoidType wall.
#
#   D4 (gate-on): two-index struct GEP `getelementptr %struct.T, ptr %p,
#       i32 0, i32 K` → `IRPtrOffset(dest, base, offset_bytes, elem_width=64)`
#       with `offset_bytes` from the LLVM datalayout (`LLVM.offsetof` /
#       `LLVMOffsetOfElement`, never IR-text parsing — Bennett.jl Rule 5/8).
#       Fail loud (still) on first index ≠ 0, > 2 indices, non-struct pointee,
#       and non-8-byte-aligned member offsets (the BVM cell discipline,
#       `offset_bytes % 8 == 0` per ADR 0018).
#
# The frontier assertions below verify the fixture advances exactly as ADR
# 0020 predicts: with the gate ON, every ptr-touching function's wall moves
# to the call / void-return walls of chunk C; with the gate OFF, every wall
# is byte-identical to chunk A.

using Test
using Bennett
using LLVM
using Bennett: extract_parsed_ir_from_ll

# Read-only BennettVM fixture (never written; probed for the frontier).
const _HAIY_HT_LL =
    "/home/tobias/Projects/BennettVM.jl/test/reference/c/hashtable.O0.ll"

# A struct whose four members are all cell-aligned: { ptr, ptr, i64, i64 }
# has member byte offsets {0, 8, 16, 24} — the `%struct.ht` shape.
const _HAIY_GEP_LL = """
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
%struct.ht = type { ptr, ptr, i64, i64 }
define i64 @haiy_gep(ptr noundef %p) {
entry:
  %a = getelementptr inbounds %struct.ht, ptr %p, i32 0, i32 0
  %b = getelementptr inbounds %struct.ht, ptr %p, i32 0, i32 1
  %c = getelementptr inbounds %struct.ht, ptr %p, i32 0, i32 2
  %d = getelementptr inbounds %struct.ht, ptr %p, i32 0, i32 3
  %v = load i64, ptr %d, align 8
  ret i64 %v
}
"""

# `store ptr` / `load ptr` of a pointer VALUE through a registered SSA slot.
const _HAIY_STORELOAD_LL = """
define i64 @haiy_storeload(ptr noundef %p, ptr noundef %q) {
entry:
  %slot = alloca ptr, align 8
  store ptr %p, ptr %slot, align 8
  %r = load ptr, ptr %slot, align 8
  store ptr %r, ptr %q, align 8
  ret i64 0
}
"""

# A `ptr`-returning function with no body wall before the return.
const _HAIY_PTRRET_LL = """
define ptr @haiy_ptrret(ptr noundef %p) {
entry:
  ret ptr %p
}
"""

_extract_inst(pir) = reduce(vcat, [b.instructions for b in pir.blocks]; init=Bennett.IRInst[])

# Helper: extract via a tempfile (the `.ll` entry point takes a path).
function _extract_ll(ir::AbstractString, fn::AbstractString; ptr_cells::Bool=false)
    mktempdir() do dir
        path = joinpath(dir, "$(fn).ll")
        write(path, ir)
        return extract_parsed_ir_from_ll(path; entry_function=fn, ptr_cells=ptr_cells)
    end
end

# Helper: capture the showerror message from a failing extraction.
function _extract_err(ir::AbstractString, fn::AbstractString; ptr_cells::Bool=false)
    mktempdir() do dir
        path = joinpath(dir, "$(fn).ll")
        write(path, ir)
        try
            extract_parsed_ir_from_ll(path; entry_function=fn, ptr_cells=ptr_cells)
            return ""
        catch e
            return sprint(showerror, e)
        end
    end
end

@testset "Bennett-haiy ptr_cells store/load/struct-GEP (BVM ADR 0020 D3+D4)" begin

    # ============================================================
    # (a) GATE OFF — the Julia-path fail-louds fire byte-identically.
    # ============================================================
    @testset "GATE OFF — store ptr still rejects at U114" begin
        msg = _extract_err(_HAIY_STORELOAD_LL, "haiy_storeload")
        @test occursin("Bennett-lgzx", msg)
        @test occursin("store of non-integer type", msg)
        @test occursin("U114", msg)
    end

    @testset "GATE OFF — two-index struct GEP still rejects at U16" begin
        msg = _extract_err(_HAIY_GEP_LL, "haiy_gep")
        @test occursin("getelementptr", lowercase(msg))
        @test occursin("U16", msg) && occursin("Bennett-qal5", msg)
        # Must NOT have produced the chunk-B IRPtrOffset path.
        @test !occursin("ADR 0020 D4", msg)
    end

    @testset "GATE OFF — ptr return still rejects at the type-width wall" begin
        msg = _extract_err(_HAIY_PTRRET_LL, "haiy_ptrret")
        @test occursin("unsupported LLVM type", msg)
        @test occursin("PointerType", msg)
    end

    # ============================================================
    # (b) GATE ON — D3: store/load ptr → 64-bit cell; ptr return → 64.
    # ============================================================
    @testset "D3 — store ptr / load ptr lower as 64-bit IRStore / IRLoad" begin
        pir = _extract_ll(_HAIY_STORELOAD_LL, "haiy_storeload"; ptr_cells=true)
        insts = _extract_inst(pir)
        stores = filter(i -> i isa Bennett.IRStore, insts)
        loads  = filter(i -> i isa Bennett.IRLoad,  insts)
        # Two `store ptr` (into %slot and into %q) → two 64-bit IRStores.
        @test length(stores) == 2
        @test all(s -> s.width == 64, stores)
        # One `load ptr` (from %slot) → one 64-bit IRLoad.
        @test length(loads) == 1
        @test all(l -> l.width == 64, loads)
    end

    @testset "D3 — ptr return derives ret_width 64" begin
        pir = _extract_ll(_HAIY_PTRRET_LL, "haiy_ptrret"; ptr_cells=true)
        @test pir.ret_width == 64
        @test pir.ret_elem_widths == [64]
    end

    # ============================================================
    # (b) GATE ON — D4: two-index struct GEP → IRPtrOffset.
    # ============================================================
    @testset "D4 — struct GEP → IRPtrOffset offsets {0,8,16,24}, elem_width 64" begin
        pir = _extract_ll(_HAIY_GEP_LL, "haiy_gep"; ptr_cells=true)
        ptroffs = [i for i in _extract_inst(pir) if i isa Bennett.IRPtrOffset]
        offs = sort(unique([i.offset_bytes for i in ptroffs]))
        @test offs == [0, 8, 16, 24]
        @test all(i -> i.elem_width == 64, ptroffs)
    end

    @testset "D4 — fail-loud edge cases (still reject under the gate)" begin
        # first index ≠ 0
        m1 = _extract_err("""
        %struct.ht = type { ptr, ptr, i64, i64 }
        define i64 @f(ptr %p) {
        e:
          %m = getelementptr inbounds %struct.ht, ptr %p, i32 1, i32 2
          %v = load i64, ptr %m
          ret i64 %v
        }
        """, "f"; ptr_cells=true)
        @test occursin("first index must be the constant 0", m1)
        @test occursin("D4", m1)

        # non-struct pointee (array, two-index)
        m2 = _extract_err("""
        define i64 @f(ptr %p) {
        e:
          %m = getelementptr inbounds [4 x i64], ptr %p, i32 0, i32 2
          %v = load i64, ptr %m
          ret i64 %v
        }
        """, "f"; ptr_cells=true)
        @test occursin("non-struct source element type", m2)
        @test occursin("D4", m2)

        # > 2 indices → U16
        m3 = _extract_err("""
        %struct.n = type { [4 x i64], i64 }
        define i64 @f(ptr %p) {
        e:
          %m = getelementptr inbounds %struct.n, ptr %p, i32 0, i32 0, i32 2
          %v = load i64, ptr %m
          ret i64 %v
        }
        """, "f"; ptr_cells=true)
        @test occursin("3 index(es)", m3)
        @test occursin("U16", m3)

        # packed struct: member 1 at byte offset 1 (sub-cell) → cell discipline
        m4 = _extract_err("""
        %struct.p = type <{ i8, i64 }>
        define i64 @f(ptr %p) {
        e:
          %m = getelementptr inbounds %struct.p, ptr %p, i32 0, i32 1
          %v = load i64, ptr %m
          ret i64 %v
        }
        """, "f"; ptr_cells=true)
        @test occursin("not 8-byte (cell) aligned", m4)
        @test occursin("ADR 0018", m4)

        # i32-member struct: member 1 at byte offset 4 → cell discipline
        m5 = _extract_err("""
        %struct.q = type { i32, i32, i64 }
        define i64 @f(ptr %p) {
        e:
          %m = getelementptr inbounds %struct.q, ptr %p, i32 0, i32 1
          %v = load i64, ptr %m
          ret i64 %v
        }
        """, "f"; ptr_cells=true)
        @test occursin("byte offset 4", m5)
        @test occursin("not 8-byte (cell) aligned", m5)
    end

    # ============================================================
    # (c) The BennettVM C fixture frontier advances as ADR 0020 predicts.
    #     Runs only if the read-only reference fixture is present.
    # ============================================================
    if isfile(_HAIY_HT_LL)
        @testset "Fixture frontier — ht_new advances PAST ptr-return to malloc" begin
            # Gate ON: the `ptr`-return wall (chunk A frontier) is cleared
            # (ret_width 64); the NEXT wall is the `malloc` call — chunk C
            # (call emission, BVM ADR 0020 D5/D6). The struct GEPs in ht_new's
            # body sit AFTER the first malloc, so they are not reached here;
            # the struct-GEP lowering itself is verified in the D4 testset above.
            msg = try
                extract_parsed_ir_from_ll(_HAIY_HT_LL; entry_function="ht_new",
                                          ptr_cells=true)
                ""
            catch e
                sprint(showerror, e)
            end
            @test occursin("malloc", msg)          # the next wall is the malloc call
            @test occursin("U15", msg)             # unregistered callee (chunk C)
            @test !occursin("unsupported LLVM type", msg)  # ptr-return wall is cleared
            @test !occursin("PointerType(ptr)", msg)       # not the return-width wall
        end

        @testset "Fixture frontier — ht_get advances PAST store-ptr + GEP to ht_hash" begin
            # Gate ON: the `store ptr` wall (chunk A frontier) AND the two-index
            # struct GEP (`%cap = getelementptr %struct.ht, ptr %0, i32 0, i32 2`)
            # are both cleared; the NEXT wall is the in-module `ht_hash` call —
            # chunk C (call emission).
            msg = try
                extract_parsed_ir_from_ll(_HAIY_HT_LL; entry_function="ht_get",
                                          ptr_cells=true)
                ""
            catch e
                sprint(showerror, e)
            end
            @test occursin("ht_hash", msg)         # the next wall is the ht_hash call
            @test occursin("U15", msg)             # unregistered callee (chunk C)
            @test !occursin("store of non-integer type", msg)  # store-ptr cleared
            @test !occursin("U16", msg)            # struct GEP cleared
        end

        @testset "Fixture frontier — ht_del advances PAST store-ptr to ht_hash" begin
            msg = try
                extract_parsed_ir_from_ll(_HAIY_HT_LL; entry_function="ht_del",
                                          ptr_cells=true)
                ""
            catch e
                sprint(showerror, e)
            end
            @test occursin("ht_hash", msg)
            @test occursin("U15", msg)
            @test !occursin("store of non-integer type", msg)
        end

        @testset "Fixture frontier — ht_free / ht_put stay at VoidType (chunk C)" begin
            # `void` return is left for chunk C (D5) — it entangles with the
            # IRRet shape (op::IROperand + width >= 1). So these stay at the
            # existing VoidType (Bennett-dq8l / U81) return-width wall EVEN with
            # the gate on. Documented so chunk C knows this is the real frontier.
            for fn in ("ht_free", "ht_put")
                msg = try
                    extract_parsed_ir_from_ll(_HAIY_HT_LL; entry_function=fn,
                                              ptr_cells=true)
                    ""
                catch e
                    sprint(showerror, e)
                end
                @test occursin("VoidType", msg)
                @test occursin("dq8l", msg)
            end
        end

        @testset "Fixture — gate-off frontier byte-identical to chunk A" begin
            # The default path must be unchanged: ht_new at the ptr-return wall,
            # ht_get at store-ptr, ht_free at VoidType.
            new_msg = try
                extract_parsed_ir_from_ll(_HAIY_HT_LL; entry_function="ht_new")
                ""
            catch e; sprint(showerror, e) end
            @test occursin("unsupported LLVM type", new_msg)
            @test occursin("PointerType", new_msg)

            get_msg = try
                extract_parsed_ir_from_ll(_HAIY_HT_LL; entry_function="ht_get")
                ""
            catch e; sprint(showerror, e) end
            @test occursin("store of non-integer type", get_msg)
            @test occursin("U114", get_msg)
        end
    end
end
