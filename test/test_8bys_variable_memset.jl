# Bennett-8bys / CW-D (ADR 0017 CW-D workstream) — VARIABLE-size memset routing.
#
# Under the closed-world `ptr_cells` gate, a VARIABLE-size (non-const N)
# `llvm.memset.p0.i64(dst, byte, nbytes)` routes to
#   IRCall(dest, :memset, [dst_cell, byte, nbytes], [64,8,64], 64)
# instead of the const-N unroll's fail-loud reject. This reuses BennettVM's
# reversible IntrinsicMemset (ingest :memset → IntrinsicMemset; :memset ∈
# _HEAP_DISPATCH). Unblocks fdict `rehash!`, which zeroes the fresh Dict slots
# Memory with a variable-length memset.
#
# Design invariants pinned here:
#   (a) GREEN routing  — variable-N memset under ptr_cells=true → exactly one
#       bare IRCall(:memset), args=[SSA dst, ConstOperand byte, SSA nbytes],
#       arg_widths=[64,8,64], ret_width=64, NO unroll. The byte is passed RAW
#       (no mask, no broadcast) — _const_int_as_int SIGN-EXTENDS the i8 (i8 0→0,
#       i8 1→1, i8 -1/0xFF→-1); BVM's IntrinsicMemset.forward does its own
#       cell-broadcast, so pre-broadcasting here would double-broadcast.
#   (b) const-N unchanged — a CONST-count memset under ptr_cells=true STILL
#       unrolls (case-C IRPtrOffset + IRStore), NO IRCall(:memset). Predicate 5
#       (non-const N) is the only gate touched.
#   (c) gate-off fail loud — under ptr_cells=false the "non-constant byte count"
#       reject is byte-identical (the circuit / :heap models get no
#       IntrinsicMemset). A VOLATILE variable-N memset STILL fails loud under
#       ptr_cells=true (Rule 1).
#   (d) real-target advance — the fdict `rehash!` root no longer walls at the
#       memset "non-constant byte count" reject.
#
# NOTE on the gate-off fixture (c): the primary fixture (a) is a VOID function
# with a `ptr` parameter (the closest analogue of rehash!'s bare slots-zeroing
# memset). Under ptr_cells=FALSE that shape pre-empts at the U81 VoidType
# `_type_width` wall BEFORE the memset is reached, so it cannot prove the memset
# reject itself is byte-identical. The existing `9nwt_memset_var_n_reject.ll`
# (i8-return, alloca-i8 dst) reaches the memset wall in BOTH modes and is the
# correct fixture for the gate-off proof — it also exercises the SAME
# instruction under ptr_cells=true (alloca dst → SSA cell → IRCall), directly
# demonstrating the gate genuinely gates.

using Test
using Bennett

const _F8BYS = joinpath(@__DIR__, "fixtures", "ll", "8bys_memset_var_n.ll")
const _F9NWT_CONST = joinpath(@__DIR__, "fixtures", "ll", "9nwt_memset_cFF_n8_fresh.ll")
const _F9NWT_VARN  = joinpath(@__DIR__, "fixtures", "ll", "9nwt_memset_var_n_reject.ll")

# Extract a single flat instruction list from an .ll entry function.
_8bys_insts(path, entry; ptr_cells=false) = begin
    parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function=entry, ptr_cells=ptr_cells)
    vcat([blk.instructions for blk in parsed.blocks]...)
end

# fdict_d1b — the real closed-world target: a Dict round-trip whose rehash!
# zeroes fresh slots with a variable-size memset. Defined BEFORE the testsets
# so the :skip producer's transitive-callee walk can reach it at run time
# (top-level code runs in textual order).
fdict_d1b(a::Int8, b::Int8) = (d = Dict{Int8,Int8}(); d[a] = b; d[a])

@testset "Bennett-8bys: variable-size memset routing" begin

    # ======================================================================
    # (a) GREEN — variable-N memset under ptr_cells=true routes to IRCall(:memset)
    # ======================================================================
    @testset "(a) variable-N memset → IRCall(:memset) [c=0]" begin
        all_insts = _8bys_insts(_F8BYS, "memset_var_n"; ptr_cells=true)
        calls = filter(i -> i isa Bennett.IRCall && i.callee === :memset, all_insts)
        @test length(calls) == 1
        c = calls[1]
        @test c.callee === :memset
        @test length(c.args) == 3
        @test c.args[1] isa Bennett.SSAOperand              # dst cell
        @test c.args[2] isa Bennett.ConstOperand
        @test c.args[2].value == 0                          # byte, RAW (i8 0 → 0)
        @test c.args[3] isa Bennett.SSAOperand              # nbytes (variable SSA)
        @test c.arg_widths == [64, 8, 64]
        @test c.ret_width == 64                             # void sentinel
        # NO unroll: no case-C IRPtrOffset, no width-8 IRStore.
        @test !any(i -> i isa Bennett.IRPtrOffset, all_insts)
        @test !any(i -> i isa Bennett.IRStore && i.width == 8, all_insts)
    end

    @testset "(a) byte is RAW, not broadcast [c=1]" begin
        # Unambiguous raw-not-broadcast probe: raw byte 0x01 → 1, whereas a
        # 64-bit broadcast of 0x01 would be 0x0101010101010101.
        all_insts = _8bys_insts(_F8BYS, "memset_var_n_c1"; ptr_cells=true)
        calls = filter(i -> i isa Bennett.IRCall && i.callee === :memset, all_insts)
        @test length(calls) == 1
        @test calls[1].args[2] isa Bennett.ConstOperand
        @test calls[1].args[2].value == 1                   # raw, NOT 0x0101010101010101
    end

    @testset "(a) 0xFF byte sign-extends to -1 (raw) [spec '255' case]" begin
        # The spec named `i8 255`; _const_int_as_int sign-extends the i8, so
        # 0xFF → -1. (0xFF is degenerate for raw-vs-broadcast: broadcast is also
        # -1 — the c=1 case above is the discriminating probe.)
        all_insts = _8bys_insts(_F8BYS, "memset_var_n_cff"; ptr_cells=true)
        calls = filter(i -> i isa Bennett.IRCall && i.callee === :memset, all_insts)
        @test length(calls) == 1
        @test calls[1].args[2] isa Bennett.ConstOperand
        @test calls[1].args[2].value == -1
    end

    # ======================================================================
    # (b) const-N memset under ptr_cells=true STILL unrolls — no IRCall(:memset)
    # ======================================================================
    @testset "(b) const-N memset unchanged: case-C unroll, no IRCall(:memset)" begin
        all_insts = _8bys_insts(_F9NWT_CONST, "memset_cFF_n8"; ptr_cells=true)
        @test any(i -> i isa Bennett.IRPtrOffset, all_insts)
        @test count(i -> i isa Bennett.IRStore && i.width == 8, all_insts) == 8
        @test !any(i -> i isa Bennett.IRCall && i.callee === :memset, all_insts)
    end

    # ======================================================================
    # (c) gate-off fail loud + volatile guard
    # ======================================================================
    @testset "(c) ptr_cells=false: variable-N memset still fails loud" begin
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            _F9NWT_VARN; entry_function="memset_var_n", ptr_cells=false)
        msg = try
            Bennett.extract_parsed_ir_from_ll(_F9NWT_VARN;
                entry_function="memset_var_n", ptr_cells=false)
            ""
        catch e
            sprint(showerror, e)
        end
        @test occursin("non-constant byte count", msg)
        @test occursin("Bennett-8bys", msg)
    end

    @testset "(c) volatile variable-N memset fails loud under ptr_cells=true (Rule 1)" begin
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            _F8BYS; entry_function="memset_var_n_volatile", ptr_cells=true)
        msg = try
            Bennett.extract_parsed_ir_from_ll(_F8BYS;
                entry_function="memset_var_n_volatile", ptr_cells=true)
            ""
        catch e
            sprint(showerror, e)
        end
        @test occursin("volatile", msg)
    end

    # ======================================================================
    # (d) real-target advance — fdict rehash! no longer walls at the memset.
    #     Runs under BOTH check-bounds modes (standalone: default; suite:
    #     --check-bounds=yes, via runtests.jl).
    # ======================================================================
    @testset "(d) rehash! advances past the variable-size memset wall" begin
        before = lock(Bennett._known_callees_lock) do
            copy(Bennett._known_callees)
        end
        try
            at = Tuple{Dict{Int8,Int8},Int64}

            # RED anchor: pre-fix this throws "non-constant byte count".
            on_msg = try
                extract_parsed_ir(Base.rehash!, at; optimize=false, ptr_cells=true)
                nothing
            catch e
                e isa InterruptException && rethrow()
                sprint(showerror, e)
            end
            if on_msg === nothing
                @test true   # fully extracted — even stronger than wall-advance
            else
                # LOAD-BEARING NEGATIVE: the memset reject is cleared.
                @test !occursin("non-constant byte count", on_msg)
                # POSITIVE: advanced to a plausible CW-D successor wall.
                lc = lowercase(on_msg)
                @test occursin("genericmemory", lc)      ||
                      occursin("gc_alloc_obj", lc)       ||
                      occursin("jl_alloc_genericmemory", lc) ||
                      occursin("closed-world", lc)       ||
                      occursin("no registered callee", lc) ||
                      occursin("unsupported", lc)        ||
                      occursin("ptrtoint", lc)           ||
                      occursin("inttoptr", lc)
            end

            # :skip set producer — the message (if any) no longer mentions the
            # memset reject either.
            skmsg = try
                extract_parsed_ir_set_from_julia(fdict_d1b, Tuple{Int8,Int8};
                    ptr_cells=true, on_extract_error=:skip)
                ""
            catch e
                e isa InterruptException && rethrow()
                sprint(showerror, e)
            end
            @test !occursin("non-constant byte count", skmsg)
        finally
            lock(Bennett._known_callees_lock) do
                empty!(Bennett._known_callees)
                merge!(Bennett._known_callees, before)
            end
        end

        after = lock(Bennett._known_callees_lock) do
            copy(Bennett._known_callees)
        end
        @test after == before                # registry restored — no leak (Rule 7)
    end

end
