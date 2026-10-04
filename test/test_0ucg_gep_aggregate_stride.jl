using Test, Bennett
using Bennett: extract_parsed_ir_from_ll, IRPtrOffset, IRVarGEP

# Bennett-0ucg — INVARIANT: every single-index constant GEP records the NATIVE
# byte offset `index × alloc-size(source element type)` under the module's
# DataLayout — the same number whichever source type spells the address — or
# is refused loud. Before the fix, struct / array / vector / POINTER source
# types stored the RAW index (`gep ptr, %p, 1` → offset 1, want 8;
# `gep [2 x i64], %a, 1` → offset 1, want 16), so two spellings of one native
# address landed on different bytes, silently (verify_reversibility passes).
#
# Generated grid: source type × constant index × downstream consumer, every
# cell checked end-to-end against the native little-endian byte oracle (which
# is spelling-independent, so passing it means all spellings alias).

# (LLVM spelling, alloc size on x86_64/aarch64 Julia datalayouts)
const OUCG_TYPES = [("i8", 1), ("i64", 8), ("double", 8), ("ptr", 8),
                    ("[2 x i64]", 16), ("{ i32, i64 }", 16), ("<2 x i32>", 8)]
const OUCG_IDX = [0, 1, 3, -1]
const OUCG_BASE = 16            # %b = %p + 16, so index -1 stays in range
const OUCG_DEREF = 96           # bytes of pointee modelled as input wires

_oucg_tag(t) = replace(t, r"[^A-Za-z0-9]" => "_")

# Consumers. `load` reads the INPUT through the spelled address (ptr argument;
# k ≥ 0 only — the circuit backend models a pointer argument's bytes from the
# GEP base forward, so a negative step off a derived base is refused there,
# independent of this bead). The alloca consumers cover every index incl. -1
# and test aliasing in BOTH directions; they need 8-byte-aligned offsets (the
# shadow tape refuses sub-slot offsets, Bennett-ixiz), so they skip `i8`.
_oucg_aligned(sz) = sz % 8 == 0

# Julia's x86_64 layout (i64 aligned 8). Without a datalayout LLVM's default
# aligns i64 to 4, so `{ i32, i64 }` really is 12 bytes there — the stride is
# the MODULE's allocation size, never a hardcoded one.
const OUCG_DL = "target datalayout = \"e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128\"\n\n"

function _oucg_module()
    io = IOBuffer()
    print(io, OUCG_DL)
    for (ti, (t, sz)) in enumerate(OUCG_TYPES), k in OUCG_IDX
        nm = "t$(ti)_$(k < 0 ? "m$(-k)" : string(k))"
        if k >= 0      # load: input bytes read through the spelled address
            print(io, """
            define i64 @$(nm)_load(ptr dereferenceable($OUCG_DEREF) %p) {
            top:
              %b = getelementptr i8, ptr %p, i64 $OUCG_BASE
              %q = getelementptr $t, ptr %b, i64 $k
              %v = load i64, ptr %q, align 1
              ret i64 %v
            }

            """)
        end
        _oucg_aligned(sz) || continue
        ahdr = """
            define i64 @$(nm)_CONS(i64 %x) {
            top:
              %a = alloca [12 x i64], align 8
              %b = getelementptr i8, ptr %a, i64 $OUCG_BASE
              %q = getelementptr $t, ptr %b, i64 $k
            """
        # store via the T spelling, read back via the i8 spelling
        print(io, replace(ahdr, "CONS" => "store"), """
              store i64 %x, ptr %q, align 8
              %r = getelementptr i8, ptr %b, i64 $(k * sz)
              %v = load i64, ptr %r, align 8
              ret i64 %v
            }

            """)
        # store via the i8 spelling, read back via the T spelling
        print(io, replace(ahdr, "CONS" => "aload"), """
              %r = getelementptr i8, ptr %b, i64 $(k * sz)
              store i64 %x, ptr %r, align 8
              %v = load i64, ptr %q, align 8
              ret i64 %v
            }

            """)
        # a second T-GEP on top of %q, vs the i8 spelling of that address
        print(io, replace(ahdr, "CONS" => "gep2"), """
              %r = getelementptr i8, ptr %b, i64 $((k + 1) * sz)
              store i64 %x, ptr %r, align 8
              %s = getelementptr $t, ptr %q, i64 1
              %v = load i64, ptr %s, align 8
              ret i64 %v
            }

            """)
    end
    String(take!(io))
end

_oucg_word(x::BigInt, byteoff::Int) = UInt64((x >> (8 * byteoff)) & typemax(UInt64))

const OUCG_INPUTS = let s = UInt64(0x9e3779b97f4a7c15), v = BigInt[]
    for _ in 1:12
        x = big(0)
        for w in 0:(OUCG_DEREF ÷ 8 - 1)
            s = s * 0x5851f42d4c957f2d + 0x14057b7ef767814f
            x |= big(s) << (64 * w)
        end
        push!(v, x)
    end
    push!(v, big(0), (big(1) << (8 * OUCG_DEREF)) - 1)
    v
end

function _oucg_withll(f, body)
    mktempdir() do dir
        path = joinpath(dir, "oucg.ll")
        write(path, body)
        f(path)
    end
end

_oucg_off(pir, d::Symbol) = only(i for b in pir.blocks for i in b.instructions
                                 if i isa IRPtrOffset && i.dest === d)

@testset "Bennett-0ucg single-index GEP offset = index × alloc size" begin
    _oucg_withll(_oucg_module()) do path
        for (ti, (t, sz)) in enumerate(OUCG_TYPES), k in OUCG_IDX
            nm = "t$(ti)_$(k < 0 ? "m$(-k)" : string(k))"
            @testset "$t index $k" begin
                if k >= 0
                    pir = extract_parsed_ir_from_ll(path; entry_function="$(nm)_load")
                    # ParsedIR: the recorded offset is the native byte offset
                    @test _oucg_off(pir, :q).offset_bytes == k * sz
                    c = reversible_compile(pir)
                    @test verify_reversibility(c)
                    @test all(UInt64(simulate(c, x) % UInt64) ==
                              _oucg_word(x, OUCG_BASE + k * sz) for x in OUCG_INPUTS)
                end
                _oucg_aligned(sz) || continue
                for cons in ("store", "aload", "gep2")
                    pir = extract_parsed_ir_from_ll(path; entry_function="$(nm)_$(cons)")
                    @test _oucg_off(pir, :q).offset_bytes == k * sz
                    cons == "gep2" && @test _oucg_off(pir, :s).offset_bytes == sz
                    c = reversible_compile(pir)
                    @test verify_reversibility(c)
                    xs = UInt64[0, typemax(UInt64), 0x0123456789abcdef,
                                (UInt64(OUCG_INPUTS[i] & typemax(UInt64)) for i in 1:8)...]
                    @test all(UInt64(simulate(c, x) % UInt64) == x for x in xs)
                end
            end
        end
    end

    @testset "cell stamps under ptr_cells: scalar = 8·stride, aggregate = byte unit" begin
        _oucg_withll(_oucg_module()) do path
            for (ti, (t, sz)) in enumerate(OUCG_TYPES)
                pir = extract_parsed_ir_from_ll(path; entry_function="t$(ti)_3_load",
                                                ptr_cells=true)
                n = _oucg_off(pir, :q)
                @test n.offset_bytes == 3 * sz
                scalar = t in ("i8", "i64", "double", "ptr")
                @test n.elem_width == (scalar ? 8 * sz : 8)
                # BennettVM's cell index `offset ÷ (elem_width ÷ 8)` is the
                # native element index for scalars and the byte for aggregates
                @test n.offset_bytes ÷ (n.elem_width ÷ 8) == (scalar ? 3 : 3 * sz)
            end
        end
    end

    @testset "i32 index operand is sign-extended (fixed-width residue)" begin
        ll = """
        define i64 @neg(i64 %x) {
        top:
          %a = alloca [12 x i64], align 8
          %b = getelementptr i8, ptr %a, i64 32
          %q = getelementptr [2 x i64], ptr %b, i32 -1
          store i64 %x, ptr %q, align 8
          %r = getelementptr i8, ptr %a, i64 16
          %v = load i64, ptr %r, align 8
          ret i64 %v
        }
        """
        _oucg_withll(ll) do path
            pir = extract_parsed_ir_from_ll(path; entry_function="neg")
            @test _oucg_off(pir, :q).offset_bytes == -16
            c = reversible_compile(pir)
            @test verify_reversibility(c)
            @test all(UInt64(simulate(c, x) % UInt64) == x
                      for x in (UInt64(0), typemax(UInt64), 0x0123456789abcdef))
        end
    end

    @testset "runtime index: integer sources → IRVarGEP, others refused loud" begin
        io = IOBuffer()
        for (ti, (t, _)) in enumerate(OUCG_TYPES)
            print(io, """
            define i64 @rt$(ti)(ptr dereferenceable($OUCG_DEREF) %p, i64 %i) {
            top:
              %q = getelementptr $t, ptr %p, i64 %i
              %v = load i64, ptr %q, align 1
              ret i64 %v
            }

            """)
        end
        _oucg_withll(String(take!(io))) do path
            for (ti, (t, sz)) in enumerate(OUCG_TYPES)
                if t in ("i8", "i64")
                    pir = extract_parsed_ir_from_ll(path; entry_function="rt$(ti)")
                    g = only(i for b in pir.blocks for i in b.instructions if i isa IRVarGEP)
                    @test g.elem_width == 8 * sz
                else
                    err = try
                        extract_parsed_ir_from_ll(path; entry_function="rt$(ti)"); nothing
                    catch e
                        e
                    end
                    @test err !== nothing && occursin("Bennett-plb7", sprint(showerror, err))
                end
            end
        end
    end

    @testset "Julia-reachable witness: unsafe_load of an NTuple element" begin
        # Julia emits `getelementptr inbounds [2 x i64], ptr %p, i64 1` here;
        # the raw-index branch recorded offset 1 (byte 1), native is byte 16.
        h(p::Ptr{UInt8}) = unsafe_load(Ptr{NTuple{2,UInt64}}(p), 2)[1]
        ir = Bennett.extract_ir(h, Tuple{Ptr{UInt8}})
        @test occursin(r"getelementptr inbounds \[2 x i64\], ptr [^,]+, i64 1", ir)
        o = [i for b in Bennett.extract_parsed_ir(h, Tuple{Ptr{UInt8}}).blocks
             for i in b.instructions if i isa IRPtrOffset]
        @test length(o) == 1 && o[1].offset_bytes == 16 && o[1].elem_width == 8
    end

    @testset "no datalayout: { i32, i64 } strides 12 (the module's own size)" begin
        ll = """
        define i64 @nodl(ptr dereferenceable(64) %p) {
        top:
          %q = getelementptr { i32, i64 }, ptr %p, i64 2
          %v = load i64, ptr %q, align 1
          ret i64 %v
        }
        """
        _oucg_withll(ll) do path
            pir = extract_parsed_ir_from_ll(path; entry_function="nodl")
            @test _oucg_off(pir, :q).offset_bytes == 24
            c = reversible_compile(pir)
            @test verify_reversibility(c)
            @test all(UInt64(simulate(c, x % (big(1) << 512)) % UInt64) ==
                      _oucg_word(x, 24) for x in OUCG_INPUTS)
        end
    end

    @testset "scalable-vector source has no static stride → refused loud" begin
        ll = """
        define i64 @sv(ptr dereferenceable(64) %p) {
        top:
          %q = getelementptr <vscale x 2 x i32>, ptr %p, i64 1
          %v = load i64, ptr %q, align 1
          ret i64 %v
        }
        """
        _oucg_withll(ll) do path
            err = try
                extract_parsed_ir_from_ll(path; entry_function="sv"); nothing
            catch e
                e
            end
            @test err !== nothing && occursin("Bennett-0ucg", sprint(showerror, err))
        end
    end
end
