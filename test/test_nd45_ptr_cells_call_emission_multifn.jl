# Bennett-nd45 / BVM ADR 0020 (CW-C2 chunk C) — D5 + D6 under the `ptr_cells` gate.
#
# Bennett.jl-side impl of chunk C of the BennettVM closed-world C-track
# front-end contract (BennettVM.jl docs/adr/0020-c-track-frontend-contract.md,
# Decisions 5+6). Builds on chunk A (Bennett-k3ej: IRCall Symbol callee + C
# ptr-parameter model) and chunk B (Bennett-haiy: ptr store/load + struct GEP).
#
# THE GATE (unchanged from chunk B). Everything here is gated on the
# `ptr_cells::Bool=false` kwarg. Gate-off, every existing fail-loud
# (U15 call / U114 store / U16 GEP / U81 void+ptr return) fires
# byte-identically — they protect the Julia circuit / `mem=:heap` models, which
# the C cell model must NOT silently alias.
#
#   D5a (gate-on): a call whose callee is NOT a registered Julia `Function`
#       (the `_lookup_callee` miss) but IS an in-module / libc `LLVM.Function`
#       lowers to an `IRCall` with a `Symbol` callee. libc whitelist
#       {malloc,…,free,…} → BVM `_HEAP_DISPATCH`; in-module `define`d name →
#       BVM guard-5 function table. ptr args/returns are 64-bit cells.
#
#   D5b (gate-on): void CALL (`call void @free` / `@ht_put`) → `IRCall` with a
#       synthesized never-read auto-named `dest` + `ret_width = 64` SENTINEL
#       (IRCall.dest is mandatory + ret_width >= 1; BVM never reads either for a
#       void callee). void RETURN (`ret void`) → the `IRRet()` VOID FORM
#       (`op === nothing`, `width == 0`) + function-level `ret_width = 0` /
#       `ret_elem_widths = Int[]`.
#
#   D5c (gate-on): `alloca ptr` → `IRAlloca(dest, 64, 1)` (one 64-bit cell) so a
#       `store ptr %t, ptr %t.addr` (D3) targets an allocated slot.
#
#   D6: `extract_parsed_ir_set_from_ll(path; ptr_cells) ->
#       Vector{Pair{Symbol,ParsedIR}}` walks EVERY defined function (skipping
#       `declare`d libc); fails loud on zero defines.
#
# The fixture frontier moves to FULLY-EXTRACTING under the gate: ht_new (was
# malloc wall), ht_put / ht_free (was VoidType wall) now extract end-to-end.

using Test
using Bennett
using LLVM
using Bennett: extract_parsed_ir_from_ll, extract_parsed_ir_set_from_ll

# Read-only BennettVM fixture (never written; probed for the frontier).
const _ND45_HT_LL =
    "/home/tobias/Projects/BennettVM.jl/test/reference/c/hashtable.O0.ll"

_extract_inst(pir) = reduce(vcat, [b.instructions for b in pir.blocks];
                            init=Bennett.IRInst[])

function _extract_ll(ir::AbstractString, fn::AbstractString; ptr_cells::Bool=false)
    mktempdir() do dir
        path = joinpath(dir, "$(fn).ll")
        write(path, ir)
        return extract_parsed_ir_from_ll(path; entry_function=fn, ptr_cells=ptr_cells)
    end
end

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

# A minimal libc-call shape: `iptr @f` calls `malloc` (ptr return) + `free`
# (void call, ptr arg).
const _ND45_LIBC_LL = """
declare ptr @malloc(i64)
declare void @free(ptr)
define i64 @nd45_libc(i64 noundef %n) {
entry:
  %p = call ptr @malloc(i64 noundef %n)
  call void @free(ptr noundef %p)
  ret i64 0
}
"""

# An in-module call: `@caller` calls a DEFINED `@callee` (i64 return).
const _ND45_INMOD_LL = """
define i64 @nd45_callee(i64 noundef %x) {
e:
  %r = add i64 %x, 1
  ret i64 %r
}
define i64 @nd45_caller(i64 noundef %y) {
e:
  %z = call i64 @nd45_callee(i64 noundef %y)
  ret i64 %z
}
"""

# A void function (`ret void`) that takes a ptr param.
const _ND45_VOIDFN_LL = """
define void @nd45_void(ptr noundef %t, i64 noundef %v) {
e:
  store i64 %v, ptr %t, align 8
  ret void
}
"""

# `alloca ptr` + `store ptr` into it (the C `%t.addr` idiom).
const _ND45_ALLOCAPTR_LL = """
define i64 @nd45_allocaptr(ptr noundef %t) {
e:
  %t.addr = alloca ptr, align 8
  store ptr %t, ptr %t.addr, align 8
  %r = load ptr, ptr %t.addr, align 8
  store i64 7, ptr %r, align 8
  ret i64 0
}
"""

# A module of ONLY declarations (no defines) — the D6 fail-loud case.
const _ND45_DECLONLY_LL = """
declare ptr @malloc(i64)
declare void @free(ptr)
"""

@testset "Bennett-nd45 ptr_cells call emission + multi-fn (BVM ADR 0020 D5+D6)" begin

    # ============================================================
    # (a) GATE OFF — the U15 call fail-loud fires byte-identically.
    # ============================================================
    @testset "GATE OFF — libc call still rejects at U15" begin
        msg = _extract_err(_ND45_LIBC_LL, "nd45_libc")
        @test occursin("U15", msg)
        @test occursin("malloc", msg)
        @test occursin("registered callee", lowercase(msg) * msg)  # message text
        # Must NOT have produced a chunk-C IRCall path.
        @test !occursin("ADR 0020 D5", msg)
    end

    @testset "GATE OFF — in-module call still rejects at U15" begin
        msg = _extract_err(_ND45_INMOD_LL, "nd45_caller")
        @test occursin("U15", msg)
        @test occursin("nd45_callee", msg)
    end

    @testset "GATE OFF — void return still rejects at VoidType (U81)" begin
        msg = _extract_err(_ND45_VOIDFN_LL, "nd45_void")
        @test occursin("VoidType", msg)
        @test occursin("dq8l", msg) || occursin("U81", msg)
    end

    @testset "GATE OFF — alloca ptr is silently skipped (no IRAlloca)" begin
        # Gate-off, `alloca ptr` returns nothing; the matching `store ptr`
        # then hits the U114 store wall (store of non-integer type).
        msg = _extract_err(_ND45_ALLOCAPTR_LL, "nd45_allocaptr")
        @test occursin("U114", msg)
        @test occursin("store of non-integer type", msg)
    end

    # ============================================================
    # (b) GATE ON — D5a/b: libc + in-module call emission, void shapes.
    # ============================================================
    @testset "D5a — libc malloc (ptr ret) + free (void call) → Symbol IRCall" begin
        pir = _extract_ll(_ND45_LIBC_LL, "nd45_libc"; ptr_cells=true)
        calls = filter(i -> i isa Bennett.IRCall, _extract_inst(pir))
        @test length(calls) == 2
        bycallee = Dict(c.callee => c for c in calls)
        @test haskey(bycallee, :malloc) && haskey(bycallee, :free)
        # malloc: i64 arg, ptr return → cell width 64.
        @test bycallee[:malloc].callee isa Symbol
        @test bycallee[:malloc].ret_width == 64
        @test bycallee[:malloc].arg_widths == [64]
        # free: void call → ret_width 64 sentinel, ptr arg as a 64-bit cell.
        @test bycallee[:free].callee isa Symbol
        @test bycallee[:free].ret_width == 64
        @test bycallee[:free].arg_widths == [64]
    end

    @testset "D5a — in-module call → Symbol IRCall (BVM guard-5 route)" begin
        pir = _extract_ll(_ND45_INMOD_LL, "nd45_caller"; ptr_cells=true)
        calls = filter(i -> i isa Bennett.IRCall, _extract_inst(pir))
        @test length(calls) == 1
        @test calls[1].callee === :nd45_callee
        @test calls[1].ret_width == 64
        @test calls[1].arg_widths == [64]
    end

    @testset "D5b — void RETURN → ret_width 0 + IRRet() void form" begin
        pir = _extract_ll(_ND45_VOIDFN_LL, "nd45_void"; ptr_cells=true)
        @test pir.ret_width == 0
        @test pir.ret_elem_widths == Int[]
        terms = [b.terminator for b in pir.blocks]
        rets = filter(t -> t isa Bennett.IRRet, terms)
        @test length(rets) == 1
        @test rets[1].op === nothing          # the void form
        @test rets[1].width == 0
    end

    @testset "D5b — IRRet() void form is distinct from IRRet(op, 0) reject" begin
        # The pinned k7al invariant must still hold: a width-0 VALUE return throws.
        @test_throws "width=0" Bennett.IRRet(Bennett.ssa(:x), 0)
        # The void form constructs cleanly.
        v = Bennett.IRRet()
        @test v.op === nothing && v.width == 0
    end

    # ============================================================
    # (b) GATE ON — D5c: alloca ptr → one 64-bit cell.
    # ============================================================
    @testset "D5c — alloca ptr → IRAlloca(_, 64, 1)" begin
        pir = _extract_ll(_ND45_ALLOCAPTR_LL, "nd45_allocaptr"; ptr_cells=true)
        insts = _extract_inst(pir)
        allocas = filter(i -> i isa Bennett.IRAlloca, insts)
        @test length(allocas) == 1
        @test allocas[1].elem_width == 64
        @test allocas[1].n_elems == Bennett.iconst(1)
        # The matching store ptr / load ptr (D3) now have an allocated dest.
        stores = filter(i -> i isa Bennett.IRStore, insts)
        loads  = filter(i -> i isa Bennett.IRLoad,  insts)
        @test any(s -> s.width == 64, stores)   # store ptr → 64-bit cell
        @test any(l -> l.width == 64, loads)    # load ptr  → 64-bit cell
    end

    # ============================================================
    # (c) D6 — the multi-function producer.
    # ============================================================
    @testset "D6 — fail loud on a declaration-only module" begin
        mktempdir() do dir
            path = joinpath(dir, "declonly.ll")
            write(path, _ND45_DECLONLY_LL)
            @test_throws ArgumentError extract_parsed_ir_set_from_ll(path; ptr_cells=true)
            msg = try
                extract_parsed_ir_set_from_ll(path; ptr_cells=true); ""
            catch e; sprint(showerror, e) end
            @test occursin("no DEFINED", msg)
            @test occursin("D6", msg)
        end
    end

    @testset "D6 — set walker returns each defined function (skips declares)" begin
        mktempdir() do dir
            path = joinpath(dir, "inmod.ll")
            write(path, _ND45_INMOD_LL)
            set = extract_parsed_ir_set_from_ll(path; ptr_cells=true)
            @test set isa Vector{Pair{Symbol,Bennett.ParsedIR}}
            @test [p.first for p in set] == [:nd45_callee, :nd45_caller]
        end
    end

    # ============================================================
    # (d) The BennettVM C fixture: full extraction + multi-fn set.
    #     Runs only if the read-only reference fixture is present.
    # ============================================================
    if isfile(_ND45_HT_LL)
        @testset "Fixture — ht_new extracts FULLY (malloc IRCall + struct GEPs)" begin
            pir = extract_parsed_ir_from_ll(_ND45_HT_LL; entry_function="ht_new",
                                            ptr_cells=true)
            insts = _extract_inst(pir)
            calls = filter(i -> i isa Bennett.IRCall, insts)
            # Three mallocs (the header + keys + vals arrays).
            mallocs = filter(c -> c.callee == :malloc, calls)
            @test length(mallocs) == 3
            @test all(c -> c.callee isa Symbol, calls)
            @test all(c -> c.ret_width == 64, mallocs)   # ptr return = cell
            # The struct GEPs {0,8,16,24} are now reached (after the malloc).
            ptroffs = filter(i -> i isa Bennett.IRPtrOffset, insts)
            offs = sort(unique([p.offset_bytes for p in ptroffs]))
            @test offs == [0, 8, 16, 24]
            @test all(p -> p.elem_width == 64, ptroffs)
            # ht_new returns a pointer → ret_width 64.
            @test pir.ret_width == 64
        end

        @testset "Fixture — ht_put extracts FULLY (void fn, in-module ht_hash)" begin
            pir = extract_parsed_ir_from_ll(_ND45_HT_LL; entry_function="ht_put",
                                            ptr_cells=true)
            @test pir.ret_width == 0               # void function
            @test pir.ret_elem_widths == Int[]
            calls = filter(i -> i isa Bennett.IRCall, _extract_inst(pir))
            @test any(c -> c.callee === :ht_hash, calls)   # in-module call emitted
            @test all(c -> c.callee isa Symbol, calls)
        end

        @testset "Fixture — ht_free extracts FULLY (void ret + 3 free void calls)" begin
            pir = extract_parsed_ir_from_ll(_ND45_HT_LL; entry_function="ht_free",
                                            ptr_cells=true)
            @test pir.ret_width == 0
            insts = _extract_inst(pir)
            frees = filter(i -> i isa Bennett.IRCall && i.callee === :free, insts)
            @test length(frees) == 3               # frees keys, vals, header
            @test all(c -> c.ret_width == 64, frees)   # void sentinel
            # Block terminator is the void IRRet form.
            rets = filter(t -> t isa Bennett.IRRet, [b.terminator for b in pir.blocks])
            @test length(rets) == 1 && rets[1].op === nothing && rets[1].width == 0
        end

        @testset "D6 — fixture set: exactly the 12 defined functions, named" begin
            set = extract_parsed_ir_set_from_ll(_ND45_HT_LL; ptr_cells=true)
            names = [p.first for p in set]
            # libc malloc/free are `declare`d → SKIPPED; only the 12 defines.
            @test length(set) == 12
            @test Set(names) == Set([:ht_demo_basic, :ht_new, :ht_put, :demo_key,
                                     :demo_val, :ht_del, :ht_third_pass, :ht_get,
                                     :ht_free, :ht_demo_grow, :ht_grow, :ht_hash])
            byname = Dict(set)
            # Pin per-function arg counts + ret widths (the C signatures).
            @test length(byname[:ht_demo_basic].args) == 1 && byname[:ht_demo_basic].ret_width == 64
            @test length(byname[:ht_new].args) == 1       && byname[:ht_new].ret_width == 64    # ptr ret
            @test length(byname[:ht_demo_grow].args) == 1  && byname[:ht_demo_grow].ret_width == 64  # (nit 3)
            @test length(byname[:ht_put].args) == 3       && byname[:ht_put].ret_width == 0      # void
            @test length(byname[:ht_get].args) == 3       && byname[:ht_get].ret_width == 64
            @test length(byname[:ht_del].args) == 2       && byname[:ht_del].ret_width == 64
            @test length(byname[:ht_free].args) == 1      && byname[:ht_free].ret_width == 0     # void
            @test length(byname[:ht_grow].args) == 1      && byname[:ht_grow].ret_width == 0     # void
            @test length(byname[:ht_third_pass].args) == 2 && byname[:ht_third_pass].ret_width == 0
            @test length(byname[:ht_hash].args) == 1      && byname[:ht_hash].ret_width == 64
            @test length(byname[:demo_key].args) == 1     && byname[:demo_key].ret_width == 64
            @test length(byname[:demo_val].args) == 1     && byname[:demo_val].ret_width == 64
        end

        @testset "Fixture — gate-off frontier byte-identical (ht_new ptr wall)" begin
            new_msg = try
                extract_parsed_ir_from_ll(_ND45_HT_LL; entry_function="ht_new")
                ""
            catch e; sprint(showerror, e) end
            @test occursin("unsupported LLVM type", new_msg)
            @test occursin("PointerType", new_msg)

            free_msg = try
                extract_parsed_ir_from_ll(_ND45_HT_LL; entry_function="ht_free")
                ""
            catch e; sprint(showerror, e) end
            @test occursin("VoidType", free_msg)
            @test occursin("dq8l", free_msg) || occursin("U81", free_msg)
        end
    end
end
