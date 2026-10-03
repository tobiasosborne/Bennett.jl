using Test
using Bennett
using Bennett: extract_parsed_ir_from_ll, extract_parsed_ir, IRPtrOffset

# Bennett-edt9 (Astra B-extract-core F13) — a GEP step is the source element's
# ALLOCATION size (LLVM `getTypeAllocSize` = `LLVMABISizeOfType`), not its bit
# width ÷ 8. `getelementptr i24, ptr %p, i64 1` steps 4 bytes on every
# datalayout Julia uses (i24 takes i32's alignment), but the extractor emitted
# `IRPtrOffset(…, 3, 24)` — a silent miscompile that still passes
# `verify_reversibility`. The adjacent non-integer branch stored the RAW index
# (`getelementptr float, ptr %p, i64 1` → byte offset 1, want 4). Both are
# Julia-reachable (`unsafe_load(Ptr{U24}(p), 2)`, `unsafe_load(Ptr{Float32}(p), 2)`).
# Strides IRVarGEP cannot express (alloc size ≠ bit width ÷ 8) now fail loud.

primitive type EDT9U24 24 end

# Native oracles: Julia's own pointer arithmetic on a real 8-byte buffer.
_with_bytes(f, x::UInt64) = (r = Ref(x); GC.@preserve r f(Ptr{UInt8}(pointer_from_objref(r))))
_nat_u24(x)  = _with_bytes(p -> Core.Intrinsics.zext_int(UInt32, unsafe_load(Ptr{EDT9U24}(p), 2)), x)
_nat_f32(x)  = _with_bytes(p -> reinterpret(UInt32, unsafe_load(Ptr{Float32}(p), 2)), x)
_nat_u16(x)  = _with_bytes(p -> unsafe_load(Ptr{UInt16}(p), 3), x)
_nat_u32(x)  = _with_bytes(p -> unsafe_load(Ptr{UInt32}(p), 2), x)
_nat_u8(x)   = _with_bytes(p -> unsafe_load(p, 6), x)

const EDT9_LL = """
define i32 @edt9_i24(ptr dereferenceable(8) %p) {
top:
  %q = getelementptr inbounds i24, ptr %p, i64 1
  %v = load i24, ptr %q, align 1
  %r = zext i24 %v to i32
  ret i32 %r
}

define i32 @edt9_f32(ptr dereferenceable(8) %p) {
top:
  %q = getelementptr inbounds float, ptr %p, i64 1
  %v = load i32, ptr %q, align 1
  ret i32 %v
}

define i16 @edt9_i16(ptr dereferenceable(8) %p) {
top:
  %q = getelementptr inbounds i16, ptr %p, i64 2
  %v = load i16, ptr %q, align 1
  ret i16 %v
}

define i32 @edt9_i32(ptr dereferenceable(8) %p) {
top:
  %q = getelementptr inbounds i32, ptr %p, i64 1
  %v = load i32, ptr %q, align 1
  ret i32 %v
}

define i8 @edt9_i8(ptr dereferenceable(8) %p) {
top:
  %q = getelementptr inbounds i8, ptr %p, i64 5
  %v = load i8, ptr %q, align 1
  ret i8 %v
}
"""

function _edt9_ll(f, body::AbstractString)
    mktempdir() do dir
        path = joinpath(dir, "edt9.ll")
        write(path, body)
        f(path)
    end
end

_ptroffs(pir) = [i for b in pir.blocks for i in b.instructions if i isa IRPtrOffset]

# Random 8-byte inputs + edge patterns; one @test per function on a mismatch list.
const EDT9_INPUTS = let rng_vals = UInt64[0x0000009907000000, 0x0000009900000700,
                                         0x0706050403020100, 0, typemax(UInt64),
                                         0x8000000000000000, 0x00000000ffffffff]
    s = UInt64(0x9e3779b97f4a7c15)
    for _ in 1:200
        s = s * 0x5851f42d4c957f2d + 0x14057b7ef767814f
        push!(rng_vals, s)
    end
    rng_vals
end

@testset "Bennett-edt9 GEP stride = LLVM allocation size" begin
    @testset "Julia-reachable witnesses extract the native byte offset" begin
        @test Base.aligned_sizeof(EDT9U24) == 4          # Julia's own stride
        h24(p::Ptr{UInt8}) = unsafe_load(Ptr{EDT9U24}(p), 2)
        o = _ptroffs(extract_parsed_ir(h24, Tuple{Ptr{UInt8}}))
        @test length(o) == 1 && o[1].offset_bytes == 4 && o[1].elem_width == 24

        hf(p::Ptr{UInt8}) = reinterpret(UInt32, unsafe_load(Ptr{Float32}(p), 2))
        o = _ptroffs(extract_parsed_ir(hf, Tuple{Ptr{UInt8}}))
        @test length(o) == 1 && o[1].offset_bytes == 4 && o[1].elem_width == 32

        hd(p::Ptr{UInt8}) = reinterpret(UInt64, unsafe_load(Ptr{Float64}(p), 3))
        o = _ptroffs(extract_parsed_ir(hd, Tuple{Ptr{UInt8}}))
        @test length(o) == 1 && o[1].offset_bytes == 16 && o[1].elem_width == 64
    end

    @testset "end-to-end circuits match native loads" begin
        _edt9_ll(EDT9_LL) do path
            for (fn, oracle, T) in (("edt9_i24", _nat_u24, UInt32),
                                    ("edt9_f32", _nat_f32, UInt32),
                                    ("edt9_i16", _nat_u16, UInt16),
                                    ("edt9_i32", _nat_u32, UInt32),
                                    ("edt9_i8",  _nat_u8,  UInt8))
                c = reversible_compile(extract_parsed_ir_from_ll(path; entry_function=fn))
                @test verify_reversibility(c)
                bad = Tuple{UInt64,Any,Any}[]
                for x in EDT9_INPUTS
                    got = simulate(c, x) % T
                    want = oracle(x)
                    got == want || push!(bad, (x, got, want))
                end
                isempty(bad) || @info "edt9 mismatches" fn first(bad, 3)
                @test isempty(bad)
            end
        end
    end

    @testset "non-power-of-two integer strides follow the datalayout" begin
        # i9 occupies 2 bytes, i24 / i40 occupy 4 / 8 bytes (default layout:
        # the next specified integer's alignment).
        ll = """
        define i8 @edt9_odd(ptr dereferenceable(64) %p) {
        top:
          %a = getelementptr i9,  ptr %p, i64 3
          %b = getelementptr i24, ptr %p, i64 3
          %c = getelementptr i40, ptr %p, i64 3
          ret i8 0
        }
        """
        _edt9_ll(ll) do path
            o = Dict(i.dest => i for i in _ptroffs(
                extract_parsed_ir_from_ll(path; entry_function="edt9_odd")))
            @test o[:a].offset_bytes == 6  && o[:a].elem_width == 9
            @test o[:b].offset_bytes == 12 && o[:b].elem_width == 24
            @test o[:c].offset_bytes == 24 && o[:c].elem_width == 40
        end
    end

    @testset "constant memcpy source: ConstantExpr GEP i24 strides 4 bytes" begin
        # memcpy from `getelementptr (i24, ptr @g, i32 1)` reads g[4..7];
        # dst[1] = g[5] = 0x66 (the bit-width stride would read g[4] = 0x55).
        ll = """
        @gtab = private unnamed_addr constant [8 x i8] c"\\11\\22\\33\\44\\55\\66\\77\\88", align 1
        declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)
        define i8 @edt9_cgep(i8 %x) {
        entry:
          %dst = alloca i8, i32 4
          call void @llvm.memcpy.p0.p0.i64(ptr %dst, ptr getelementptr (i24, ptr @gtab, i32 1), i64 4, i1 false)
          %dst1 = getelementptr i8, ptr %dst, i32 1
          %y = load i8, ptr %dst1
          ret i8 %y
        }
        """
        _edt9_ll(ll) do path
            c = reversible_compile(extract_parsed_ir_from_ll(path; entry_function="edt9_cgep"))
            @test verify_reversibility(c)
            @test all(simulate(c, x) == Int8(0x66) for x in typemin(Int8):typemax(Int8))
        end
    end

    @testset "_root_byte_offset (memcpy capacity / offset walker) uses alloc size" begin
        # The arena/global-src memcpy arms measure a constant GEP chain's byte
        # offset from its root with `_root_byte_offset`; i24 steps 4 bytes,
        # [4 x i24] elements 4 bytes, i8 / i32 controls unchanged.
        ll = """
        define i8 @edt9_rbo() {
        top:
          %a = alloca [16 x i32]
          %g24 = getelementptr i24, ptr %a, i64 3
          %garr = getelementptr [4 x i24], ptr %a, i64 0, i64 2
          %g8 = getelementptr i8, ptr %g24, i64 5
          %g32 = getelementptr i32, ptr %a, i64 3
          ret i8 0
        }
        """
        want = Dict("g24" => 12, "garr" => 8, "g8" => 17, "g32" => 12)
        got = Dict{String,Any}()
        Bennett.LLVM.Context() do _
            mod = parse(Bennett.LLVM.Module, ll)
            fn = Bennett.LLVM.functions(mod)["edt9_rbo"]
            for bb in Bennett.LLVM.blocks(fn), inst in Bennett.LLVM.instructions(bb)
                n = Bennett.LLVM.name(inst)
                haskey(want, n) && (got[n] = Bennett._root_byte_offset(inst))
            end
            Bennett.LLVM.dispose(mod)
        end
        @test got == want
    end

    @testset "padded strides IRVarGEP cannot express fail loud" begin
        rejects = Dict(
            # runtime index into a padded integer array (local base)
            "edt9_var" => """
            define i8 @edt9_var(ptr dereferenceable(8) %p, i64 %i) {
            top:
              %q = getelementptr i24, ptr %p, i64 %i
              %v = load i8, ptr %q
              ret i8 %v
            }
            """,
            # constant table of i24 (Case B)
            "edt9_glob" => """
            @t24 = private unnamed_addr constant [2 x i24] [i24 1, i24 2], align 4
            define i24 @edt9_glob(i64 %i) {
            top:
              %q = getelementptr i24, ptr @t24, i64 %i
              %v = load i24, ptr %q
              ret i24 %v
            }
            """,
            # two-index array GEP over [4 x i24] (Case C)
            "edt9_arr" => """
            define i8 @edt9_arr(i64 %i) {
            top:
              %a = alloca [4 x i24]
              %q = getelementptr [4 x i24], ptr %a, i64 0, i64 %i
              %v = load i8, ptr %q
              ret i8 %v
            }
            """)
        for (fn, ll) in rejects
            _edt9_ll(ll) do path
                err = try
                    extract_parsed_ir_from_ll(path; entry_function=fn); nothing
                catch e
                    e
                end
                @test err isa ErrorException
                @test err isa ErrorException && occursin("Bennett-edt9", err.msg)
            end
        end
    end
end
