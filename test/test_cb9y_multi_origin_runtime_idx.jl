using LLVM

# Bennett-cb9y (Bennett-dnh phase 1b): multi-origin pointer × runtime
# index. Pre-cb9y the lowering had two `:NYI` walls:
#   - src/lowering/memory.jl:141 lower_store!: 'multi-origin ptr with
#     dynamic idx (origin=$o, strategy=$s) is NYI'
#   - src/lowering/aggregate.jl:362 _lower_load_multi_origin!: 'multi-
#     origin ptr with dynamic idx is NYI'
#
# A multi-origin pointer arises from a phi/select that merges two
# alloca-derived pointers. The const-idx multi-origin path (Bennett-cc0
# M2b) gates each origin's load/store by its path predicate. Cb9y
# extends this to runtime indices: the per-origin predicate AND the
# slot-selection MUX both fire — exactly one origin × one slot is
# touched at runtime.

function _cb9y_compile(ir::String)
    c = nothing
    LLVM.Context() do _ctx
        mod = parse(LLVM.Module, ir)
        parsed = Bennett._module_to_parsed_ir(mod)
        lr = Bennett.lower(parsed)
        c = Bennett.bennett(lr)
        dispose(mod)
    end
    return c
end

@testset "Bennett-cb9y: multi-origin ptr × runtime idx" begin

    @testset "GEP-before-phi: each branch gep's its own alloca, phi merges" begin
        # The pattern: each branch computes a runtime-idx GEP into its
        # OWN alloca, then phi-merges the two derived pointers. Each
        # origin (alloca) has its own runtime idx_op + predicate_wire.
        # Pre-cb9y: NYI in lower_store!. Post-cb9y: per-origin guarded
        # MUX-EXCH dispatch.
        ir = raw"""
        define i8 @julia_f_1(i8 %x, i1 %c, i32 %idx) {
        top:
          %a = alloca i8, i32 4
          %b = alloca i8, i32 4
          br i1 %c, label %L, label %R
        L:
          %ga = getelementptr i8, ptr %a, i32 %idx
          br label %J
        R:
          %gb = getelementptr i8, ptr %b, i32 %idx
          br label %J
        J:
          %p = phi ptr [ %ga, %L ], [ %gb, %R ]
          store i8 %x, ptr %p
          %v = load i8, ptr %p
          ret i8 %v
        }
        """
        c = _cb9y_compile(ir)
        @test verify_reversibility(c)
        # The store/load pair on the same pointer is the identity:
        # whichever branch fires, we write %x to (alloca, idx) and read
        # it back. Result should equal %x.
        for cond in (false, true), idx in UInt32(0):UInt32(3),
            x in (Int8(-1), Int8(0), Int8(42), Int8(-128))
            @test simulate(c, (x, cond, idx)) == x
        end
    end

    @testset "GEP-before-phi at (8, 16) — N·W > 64 shadow_checkpoint × multi-origin" begin
        # Shape (8, 16) = 128 bits — outside the MUX-EXCH packed-UInt64
        # regime. Routes through `_lower_store_via_shadow_checkpoint!` and
        # `_lower_load_via_shadow_checkpoint!` (T4). Cb9y extends the T4
        # store helper with `extern_pred_wire` so multi-origin dispatch
        # works for these shapes too. T4 load handles multi-origin via
        # the synthetic-IRLoad path in `_lower_load_multi_origin!`
        # (synthetic-IRLoad routes through `_lower_load_via_mux!` which
        # already dispatches to `:shadow_checkpoint` when needed).
        ir = raw"""
        define i16 @julia_f_1(i16 %x, i1 %c, i32 %idx) {
        top:
          %a = alloca i16, i32 8
          %b = alloca i16, i32 8
          br i1 %c, label %L, label %R
        L:
          %ga = getelementptr i16, ptr %a, i32 %idx
          br label %J
        R:
          %gb = getelementptr i16, ptr %b, i32 %idx
          br label %J
        J:
          %p = phi ptr [ %ga, %L ], [ %gb, %R ]
          store i16 %x, ptr %p
          %v = load i16, ptr %p
          ret i16 %v
        }
        """
        c = _cb9y_compile(ir)
        @test verify_reversibility(c)
        for cond in (false, true), idx in UInt32(0):UInt32(2):UInt32(7),
            x in (Int16(-1000), Int16(0), Int16(12345))
            @test simulate(c, (x, cond, idx)) == x
        end
    end

    @testset "GEP-before-phi at (3, 8) — Bennett-nj6c shape × cb9y wall" begin
        # Compose with phase-1a: the new (3,8) shape combined with the
        # multi-origin pattern. Verifies the dispatch table indirection
        # works for the extended shape lattice too.
        ir = raw"""
        define i8 @julia_f_1(i8 %x, i1 %c, i32 %idx) {
        top:
          %a = alloca i8, i32 3
          %b = alloca i8, i32 3
          br i1 %c, label %L, label %R
        L:
          %ga = getelementptr i8, ptr %a, i32 %idx
          br label %J
        R:
          %gb = getelementptr i8, ptr %b, i32 %idx
          br label %J
        J:
          %p = phi ptr [ %ga, %L ], [ %gb, %R ]
          store i8 %x, ptr %p
          %v = load i8, ptr %p
          ret i8 %v
        }
        """
        c = _cb9y_compile(ir)
        @test verify_reversibility(c)
        for cond in (false, true), idx in UInt32(0):UInt32(2),
            x in (Int8(-1), Int8(0), Int8(7))
            @test simulate(c, (x, cond, idx)) == x
        end
    end

end
