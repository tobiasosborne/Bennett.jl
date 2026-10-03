using Test
using Bennett
using Bennett: extract_parsed_ir_from_ll

# Bennett-2glq (Astra 2026-09-26 B-extract-core F5) — the vector-load
# scalariser in src/extract/vectors.jl placed lane i at byte offset
# (i-1) * (w ÷ 8). For a sub-byte element width (`<N x i1>`, a packed
# bit vector) w ÷ 8 == 0, so every lane aliased bit 0 of the first byte:
# `load <8 x i1>` + `extractelement … 1` on input 2 returned 0 (want 1).
#
# Invariant: a vector load is scalarised only when its element width is a
# whole number of bytes (w % 8 == 0); a sub-byte element width is rejected
# loudly at extraction, naming the vector type. Byte-width lanes are
# unchanged: lane k reads bytes [k*w/8, (k+1)*w/8) of the pointee
# (little-endian), as before. Vector stores outside the sret path were
# already rejected ("unsupported vector opcode"); sret vector stores
# require lane width == sret element width ∈ {8,16,32,64}.

function _ll_pir(ir::AbstractString, fname::AbstractString)
    mktempdir() do dir
        path = joinpath(dir, "$fname.ll")
        write(path, ir)
        extract_parsed_ir_from_ll(path; entry_function=fname)
    end
end

_vload_ir(n::Int, w::Int, lane::Int) = """
define i$w @julia_vload(ptr dereferenceable($(max(1, cld(n * w, 8)))) %p) {
entry:
  %v = load <$n x i$w>, ptr %p, align 1
  %r = extractelement <$n x i$w> %v, i32 $lane
  ret i$w %r
}
"""

@testset "Bennett-2glq: sub-byte vector loads are rejected" begin
    # The review witness: <8 x i1>, lane 1.
    @test_throws r"sub-byte element width.*<8 x i1>" _ll_pir(_vload_ir(8, 1, 1), "julia_vload")
    # Generated: every packed-bit vector length / lane selection.
    for n in (2, 4, 8, 16, 32), lane in (0, n - 1)
        @test_throws r"sub-byte element width.*<\d+ x i1>" _ll_pir(_vload_ir(n, 1, lane), "julia_vload")
    end
    # Other sub-byte / non-byte-multiple widths: rejected (earlier, by the
    # vector-shape guard) — never silently scalarised.
    for w in (2, 4, 12)
        @test_throws ErrorException _ll_pir(_vload_ir(4, w, 1), "julia_vload")
    end
end

@testset "Bennett-2glq: packed-bit vector store is rejected" begin
    ir = """
    define i8 @julia_vstore(ptr dereferenceable(1) %p, i8 %x) {
    entry:
      %b = trunc i8 %x to i1
      %v = insertelement <8 x i1> zeroinitializer, i1 %b, i32 1
      store <8 x i1> %v, ptr %p, align 1
      ret i8 %x
    }
    """
    @test_throws r"<8 x i1>.*unsupported vector opcode LLVMStore" _ll_pir(ir, "julia_vstore")
end

@testset "Bennett-2glq: byte-width vector loads read the right lane" begin
    T_of = Dict(8 => UInt8, 16 => UInt16, 32 => UInt32, 64 => UInt64)
    for (n, w) in ((2, 8), (4, 8), (8, 8), (2, 16), (4, 16), (2, 32))
        nbits = n * w
        IT = T_of[nbits]
        WT = T_of[w]
        for lane in 0:(n - 1)
            pir = _ll_pir(_vload_ir(n, w, lane), "julia_vload")
            c = reversible_compile(pir)
            @test verify_reversibility(c)
            xs = IT[typemin(IT), typemax(IT)]
            # little-endian lane markers: lane k holds the value k+1
            push!(xs, reduce(|, (IT(k + 1) << (k * w) for k in 0:(n - 1))))
            append!(xs, rand(IT, 16))
            for x in xs
                want = (x >> (lane * w)) % WT
                @test simulate(c, WT, x) == want
            end
        end
    end
end
