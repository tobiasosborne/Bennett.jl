using LLVM

# Bennett-nj6c (Bennett-dnh phase 1a): runtime-indexed alloca access on
# shapes (N,W) with N·W ≤ 64 outside the original 6 hand-registered ones.
# Pre-nj6c these crashed at src/lowering/aggregate.jl:393 with
# `_lower_load_via_mux!: unsupported (elem_width=W, n_elems=N) for dynamic idx`
# (or the symmetric store-side error at memory.jl:168). The underlying
# packed-UInt64 MUX-EXCH machinery already supported any (N,W) with
# N·W ≤ 64 — only registration was missing.
#
# Tests use hand-crafted LLVM IR because Julia's codegen aggressively
# eliminates allocas before we see them (even at optimize=false most
# small local arrays get promoted). The hand-crafted IR exercises the
# T1b.3 alloca → IRStore → soft_mux_store_NxW path with shapes that
# weren't in `_MUX_SHAPES_NW` before nj6c.

function _nj6c_compile(ir::String)
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

@testset "Bennett-nj6c: runtime-idx MUX-EXCH on extended shapes" begin

    @testset "(3, 8) — alloca i8, i32 3 with runtime idx" begin
        ir = """
        define i8 @julia_f_1(i32 %idx, i8 %v) {
        top:
          %p = alloca i8, i32 3
          %g = getelementptr i8, ptr %p, i32 %idx
          store i8 %v, ptr %g
          %r = load i8, ptr %g
          ret i8 %r
        }
        """
        c = _nj6c_compile(ir)
        @test verify_reversibility(c)
        for idx in UInt32(0):UInt32(2), v in Int8(-4):Int8(2):Int8(4)
            @test simulate(c, (idx, v)) == v
        end
    end

    @testset "(5, 8) — alloca i8, i32 5 with runtime idx" begin
        ir = """
        define i8 @julia_f_1(i32 %idx, i8 %v) {
        top:
          %p = alloca i8, i32 5
          %g = getelementptr i8, ptr %p, i32 %idx
          store i8 %v, ptr %g
          %r = load i8, ptr %g
          ret i8 %r
        }
        """
        c = _nj6c_compile(ir)
        @test verify_reversibility(c)
        for idx in UInt32(0):UInt32(4), v in Int8(-2):Int8(2)
            @test simulate(c, (idx, v)) == v
        end
    end

    @testset "(6, 8) — alloca i8, i32 6 with runtime idx" begin
        ir = """
        define i8 @julia_f_1(i32 %idx, i8 %v) {
        top:
          %p = alloca i8, i32 6
          %g = getelementptr i8, ptr %p, i32 %idx
          store i8 %v, ptr %g
          %r = load i8, ptr %g
          ret i8 %r
        }
        """
        c = _nj6c_compile(ir)
        @test verify_reversibility(c)
        for idx in UInt32(0):UInt32(5), v in Int8(-2):Int8(2)
            @test simulate(c, (idx, v)) == v
        end
    end

    @testset "(7, 8) — alloca i8, i32 7 with runtime idx" begin
        ir = """
        define i8 @julia_f_1(i32 %idx, i8 %v) {
        top:
          %p = alloca i8, i32 7
          %g = getelementptr i8, ptr %p, i32 %idx
          store i8 %v, ptr %g
          %r = load i8, ptr %g
          ret i8 %r
        }
        """
        c = _nj6c_compile(ir)
        @test verify_reversibility(c)
        for idx in UInt32(0):UInt32(6), v in Int8(-2):Int8(2)
            @test simulate(c, (idx, v)) == v
        end
    end

    @testset "(3, 16) — alloca i16, i32 3 with runtime idx" begin
        ir = """
        define i16 @julia_f_1(i32 %idx, i16 %v) {
        top:
          %p = alloca i16, i32 3
          %g = getelementptr i16, ptr %p, i32 %idx
          store i16 %v, ptr %g
          %r = load i16, ptr %g
          ret i16 %r
        }
        """
        c = _nj6c_compile(ir)
        @test verify_reversibility(c)
        for idx in UInt32(0):UInt32(2), v in (Int16(-1000), Int16(0), Int16(1000))
            @test simulate(c, (idx, v)) == v
        end
    end

    # Gate-count baselines for the store-then-load round-trip on each new
    # shape (per CLAUDE.md §6: any change to these is a signal — investigate
    # whether it's an improvement or a bug). Captured 2026-05-01 with
    # explicit-strategy defaults; matches the @eval-generated MUX-EXCH
    # bodies in src/softmem.jl.
    @testset "gate-count baselines (regression anchors)" begin
        function _gc(N::Int, W::Int)
            elem_ty = "i$W"
            ir = """
            define $elem_ty @julia_f_1(i32 %idx, $elem_ty %v) {
            top:
              %p = alloca $elem_ty, i32 $N
              %g = getelementptr $elem_ty, ptr %p, i32 %idx
              store $elem_ty %v, ptr %g
              %r = load $elem_ty, ptr %g
              ret $elem_ty %r
            }
            """
            return gate_count(_nj6c_compile(ir))
        end
        # (N, W) → (total, Toffoli)
        baselines = Dict(
            (3,  8) => (3422, 458),
            (5,  8) => (6022, 896),
            (6,  8) => (7326, 1086),
            (7,  8) => (8596, 1280),
            (3, 16) => (5142, 602),
        )
        for ((N, W), (total, toffoli)) in baselines
            gc = _gc(N, W)
            @test gc.total == total
            @test gc.Toffoli == toffoli
        end
    end

end
