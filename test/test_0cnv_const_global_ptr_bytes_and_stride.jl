# Bennett-0cnv + Bennett-ciss — the byte image of a constant global
# (`parsed.globals`, built by `_extract_const_globals` / `_flatten_struct_to_bytes`
# in src/extract/module_walk.jl).
#
# 0cnv (P1, wrong result): a ptr field of a ConstantStruct global is
# materialised as a SYNTHETIC 64-bit address (Bennett-land) so that a later
# pointer-typed read can recover which global it names. Those bytes are not the
# native address, so they must never be observable as an integer. Pre-fix a
# global GEP + `load i8` (constant or runtime index) read them straight out of
# the QROM table: `{ptr @alias}` byte 7 → 16, native 0. (Bennett-omhx made the
# alias spelling reachable; the named-global spelling had the same hole since
# Bennett-land.)
# Invariant: an integer- (or float-) typed read, by any path, that overlaps a
# pointer byte range of a global is refused loudly, naming the global and the
# range; reads of the plain bytes keep their native value.
#
# ciss (P2, wrong result): array elements inside a struct global were placed at
# `i * store_size` instead of `i * alloc_size` (DataLayout stride).
# Invariant: element i of an array sits at `i * alloc_size(elem)`, exactly
# `store_size(elem)` bytes are written, padding bytes are zero. The expected
# image below is computed from the DataLayout STRING (LLVM's integer-alignment
# rules), and cross-checked against LLVM's own `abi_size`.

using Test, Bennett
using Bennett: LLVM

const _0CNV_DL = "e-m:e-i64:64-f80:128-n8:16:32:64-S128"
const _0CNV_HDR =
    "target datalayout = \"$(_0CNV_DL)\"\n" *
    "declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)\n" *
    "@h = private constant i8 7\n" *
    "@alias = private alias i8, ptr @h\n"

function _0cnv_try(ir)
    try
        return Bennett._parsed_ir_from_ir_string(ir) |> reversible_compile
    catch e
        e isa InterruptException && rethrow()
        return e
    end
end
_0cnv_msg(e) = e isa Exception ? sprint(showerror, e) : ""

_0cnv_fn(g, body) = _0CNV_HDR * g * "\ndefine i8 @julia_f(i8 %x) {\nentry:\n" *
                    body * "\n}\n"

@testset "Bennett-0cnv: synthetic pointer bytes of a const global are never an integer" begin
    @testset "reviewer witness" begin
        r = _0cnv_try(_0cnv_fn("@g = private constant {ptr} {ptr @alias}",
            "%q = getelementptr i8, ptr @g, i64 7\n%v = load i8, ptr %q\nret i8 %v"))
        @test r isa ErrorException
        @test occursin("Bennett-0cnv", _0cnv_msg(r))
        @test occursin("@g", _0cnv_msg(r))
        @test occursin("[0, 8)", _0cnv_msg(r))
    end

    # { i64, ptr, i32 }: i64 at [0,8), ptr at [8,16), i32 at [16,20), pad [20,24).
    native = UInt8[0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
                   0, 0, 0, 0, 0, 0, 0, 0,
                   0x09, 0x0a, 0x0b, 0x0c, 0, 0, 0, 0]
    isptr(b) = 8 <= b < 16
    for (tlabel, tgt) in (("alias", "ptr @alias"), ("named", "ptr @h"), ("null", "ptr null"))
        g = "@g = private constant {i64, ptr, i32} {i64 578437695752307201, $tgt, i32 202050057}"
        @testset "$tlabel / constant-index i8 GEP, every byte" begin
            for b in 0:23
                r = _0cnv_try(_0cnv_fn(g,
                    "%q = getelementptr i8, ptr @g, i64 $b\n%v = load i8, ptr %q\nret i8 %v"))
                if isptr(b)
                    @test r isa ErrorException
                    m = _0cnv_msg(r)
                    @test occursin("Bennett-0cnv", m) && occursin("@g", m) &&
                          occursin("[8, 16)", m)
                else
                    @test r isa Bennett.ReversibleCircuit
                    r isa Bennett.ReversibleCircuit || continue
                    @test all(simulate(r, x) == reinterpret(Int8, native[b + 1])
                              for x in Int8.(-3:3))
                    @test verify_reversibility(r)
                end
            end
        end
        @testset "$tlabel / two-index array GEP" begin
            for b in (0, 7, 8, 15, 16, 23)
                r = _0cnv_try(_0cnv_fn(g,
                    "%q = getelementptr [24 x i8], ptr @g, i64 0, i64 $b\n" *
                    "%v = load i8, ptr %q\nret i8 %v"))
                if isptr(b)
                    @test occursin("Bennett-0cnv", _0cnv_msg(r)) &&
                          occursin("[8, 16)", _0cnv_msg(r))
                else
                    @test r isa Bennett.ReversibleCircuit
                    r isa Bennett.ReversibleCircuit || continue
                    @test simulate(r, Int8(0)) == reinterpret(Int8, native[b + 1])
                    @test verify_reversibility(r)
                end
            end
        end
        @testset "$tlabel / wider integer and float reads overlapping the ptr" begin
            for (off, ty) in ((4, "i64"), (8, "i64"), (12, "i32"), (15, "i16"),
                              (7, "i16"), (8, "double"))
                conv = ty == "double" ? "%w = bitcast double %v to i64\n%t = trunc i64 %w to i8" :
                                        "%t = trunc $ty %v to i8"
                r = _0cnv_try(_0cnv_fn(g,
                    "%q = getelementptr i8, ptr @g, i64 $off\n%v = load $ty, ptr %q\n" *
                    conv * "\nret i8 %t"))
                @test occursin("Bennett-0cnv", _0cnv_msg(r)) &&
                      occursin("[8, 16)", _0cnv_msg(r))
            end
        end
        @testset "$tlabel / runtime-index GEP" begin
            r = _0cnv_try(_0cnv_fn(g,
                "%i = and i8 %x, 15\n%iz = zext i8 %i to i64\n" *
                "%q = getelementptr i8, ptr @g, i64 %iz\n%v = load i8, ptr %q\nret i8 %v"))
            m = _0cnv_msg(r)
            @test occursin("Bennett-0cnv", m) && occursin("@g", m) &&
                  occursin("runtime", m) && occursin("[8, 16)", m)
        end
        @testset "$tlabel / memcpy then load (Bennett-land guard, unchanged)" begin
            for b in (0, 8, 16)
                r = _0cnv_try(_0cnv_fn(g,
                    "%d = alloca [24 x i8]\n" *
                    "call void @llvm.memcpy.p0.p0.i64(ptr %d, ptr @g, i64 24, i1 false)\n" *
                    "%q = getelementptr i8, ptr %d, i64 $b\n%v = load i8, ptr %q\nret i8 %v"))
                @test occursin("Bennett-land-ptrload", _0cnv_msg(r))
            end
        end
    end

    @testset "direct load of a global whose bytes [0, k) hold a pointer" begin
        for ty in ("i8", "i64")
            r = _0cnv_try(_0cnv_fn("@g = private constant {ptr, i64} {ptr @alias, i64 3}",
                "%v = load $ty, ptr @g\n%t = $(ty == "i8" ? "add i8 %v, 0" : "trunc i64 %v to i8")\nret i8 %t"))
            m = _0cnv_msg(r)
            @test occursin("Bennett-0cnv", m) && occursin("@g", m) && occursin("[0, 8)", m)
        end
    end

    @testset "load of a constant-expression GEP of the global" begin
        g = "@g = private constant {i64, ptr} {i64 3, ptr @alias}"
        for (b, ty) in ((9, "i8"), (4, "i64"), (15, "i8"))
            r = _0cnv_try(_0cnv_fn(g,
                "%v = load $ty, ptr getelementptr (i8, ptr @g, i64 $b)\n" *
                "%t = $(ty == "i8" ? "add i8 %v, 0" : "trunc i64 %v to i8")\nret i8 %t"))
            m = _0cnv_msg(r)
            @test occursin("Bennett-0cnv", m) && occursin("[8, 16)", m)
        end
    end

    @testset "an unread ptr-bearing global still costs nothing (Bennett-fpa0)" begin
        r = _0cnv_try(_0cnv_fn("@g = private constant {i64, ptr} {i64 1, ptr @alias}",
                               "ret i8 %x"))
        @test r isa Bennett.ReversibleCircuit
        @test verify_reversibility(r)
    end
end

# ---------------------------------------------------------------------------
# ciss: DataLayout-driven array placement.

# ABI alignment (bytes) of iN under a DataLayout string, by LLVM's rule: an
# explicit `iN:A` wins; otherwise the smallest specified integer width > N is
# used (else the largest). LLVM's built-in integer defaults are i1:8 i8:8
# i16:16 i32:32 i64:32, overridden by the string.
function _ciss_int_align(dl::String, n::Int)
    spec = Dict(1 => 8, 8 => 8, 16 => 16, 32 => 32, 64 => 32)
    for tok in split(dl, '-')
        m = match(r"^i(\d+):(\d+)", tok)
        m === nothing || (spec[parse(Int, m[1])] = parse(Int, m[2]))
    end
    haskey(spec, n) && return spec[n] ÷ 8
    bigger = sort([k for k in keys(spec) if k > n])
    return (isempty(bigger) ? spec[maximum(keys(spec))] : spec[bigger[1]]) ÷ 8
end
_ciss_store(n) = cld(n, 8)
_ciss_alloc(dl, n) = cld(_ciss_store(n), _ciss_int_align(dl, n)) * _ciss_int_align(dl, n)
_ciss_roundup(x, a) = cld(x, a) * a

function _ciss_put!(img, off, v::UInt64, n)
    for k in 0:(_ciss_store(n) - 1)
        img[off + k + 1] = UInt8((v >> (8k)) & 0xff)
    end
end

const _CISS_DLS = ["e-m:e-i64:64-f80:128-n8:16:32:64-S128",
                   "e-m:e-i32:64-i64:64-n8:16:32:64-S128"]
const _CISS_WIDTHS = [8, 16, 24, 32, 64]
_ciss_val(n, k) = UInt64(0x0102030405060708 * (k + 1) + 0x1111) & (n == 64 ? typemax(UInt64) : (UInt64(1) << n - 1))

# Container -> (global decl, expected byte image).
function _ciss_struct_case(dl, n)
    # { i8 5, [3 x iN] [v0, v1, v2] }
    a = _ciss_int_align(dl, n); s = _ciss_alloc(dl, n)
    aoff = _ciss_roundup(1, a)
    size = _ciss_roundup(aoff + 3s, max(1, a))
    img = zeros(UInt8, size); img[1] = 5
    for k in 0:2; _ciss_put!(img, aoff + k * s, _ciss_val(n, k), n); end
    vals = join(("i$n $(_ciss_val(n, k))" for k in 0:2), ", ")
    ("@g = constant { i8, [3 x i$n] } { i8 5, [3 x i$n] [$vals] }", img)
end
function _ciss_nested_case(dl, n)
    # { i8 9, { i16 772, [2 x iN] [v0, v1] } }
    a = _ciss_int_align(dl, n); s = _ciss_alloc(dl, n)
    ia = max(2, a)                              # inner struct alignment
    i_aoff = _ciss_roundup(2, a)
    isize = _ciss_roundup(i_aoff + 2s, ia)
    ioff = _ciss_roundup(1, ia)
    size = _ciss_roundup(ioff + isize, ia)
    img = zeros(UInt8, size); img[1] = 9
    img[ioff + 1] = 0x04; img[ioff + 2] = 0x03
    for k in 0:1; _ciss_put!(img, ioff + i_aoff + k * s, _ciss_val(n, k), n); end
    vals = join(("i$n $(_ciss_val(n, k))" for k in 0:1), ", ")
    ("@g = constant { i8, { i16, [2 x i$n] } } { i8 9, { i16, [2 x i$n] } { i16 772, [2 x i$n] [$vals] } }", img)
end

_ciss_byte_reader(dl, g, size) = begin
    p = nextpow(2, size)
    "target datalayout = \"$dl\"\n" *
    "declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)\n" *
    g * "\ndefine i8 @julia_f(i8 %x) {\nentry:\n" *
    "  %d = alloca [$p x i8], align 16\n" *
    "  call void @llvm.memcpy.p0.p0.i64(ptr %d, ptr @g, i64 $size, i1 false)\n" *
    "  %i = and i8 %x, $(p - 1)\n  %iz = zext i8 %i to i64\n" *
    "  %q = getelementptr inbounds i8, ptr %d, i64 %iz\n" *
    "  %v = load i8, ptr %q\n  ret i8 %v\n}\n"
end

@testset "Bennett-ciss: array elements placed at the DataLayout allocation stride" begin
    @testset "reviewer witness" begin
        dl = "e-m:e-i32:64-i64:64-n8:16:32:64-S128"
        ir = "target datalayout = \"$dl\"\n" *
             "declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)\n" *
             "@g = constant { [2 x i32] } { [2 x i32] [i32 1, i32 2] }\n" *
             "define i8 @julia_f(i8 %x) {\nentry:\n  %d = alloca [16 x i8], align 8\n" *
             "  call void @llvm.memcpy.p0.p0.i64(ptr %d, ptr @g, i64 16, i1 false)\n" *
             "  %q = getelementptr inbounds i8, ptr %d, i64 8\n  %v = load i8, ptr %q\n  ret i8 %v\n}\n"
        c = _0cnv_try(ir)
        @test c isa Bennett.ReversibleCircuit
        c isa Bennett.ReversibleCircuit && @test simulate(c, Int8(42)) == 2
        c isa Bennett.ReversibleCircuit && @test verify_reversibility(c)
    end

    for dl in _CISS_DLS, n in _CISS_WIDTHS
        # The test's own layout model agrees with LLVM's.
        LLVM.Context() do _
            ldl = LLVM.DataLayout(dl)
            @test _ciss_alloc(dl, n) == Int(LLVM.abi_size(ldl, LLVM.IntType(n)))
            @test _ciss_store(n) == Int(LLVM.storage_size(ldl, LLVM.IntType(n)))
        end
        for (cname, mk) in (("array in struct", _ciss_struct_case),
                            ("array in nested struct", _ciss_nested_case))
            @testset "$cname / i$n / $dl" begin
                g, img = mk(dl, n)
                c = _0cnv_try(_ciss_byte_reader(dl, g, length(img)))
                @test c isa Bennett.ReversibleCircuit
                c isa Bennett.ReversibleCircuit || continue
                @test all(simulate(c, Int8(b)) == reinterpret(Int8, img[b + 1])
                          for b in 0:(length(img) - 1))
                @test verify_reversibility(c)
                # The extracted image itself is byte-exact.
                p = Bennett._parsed_ir_from_ir_string(_ciss_byte_reader(dl, g, length(img)))
                @test p.globals[:g] == (UInt64.(img), 8)
            end
        end
        @testset "top-level array / i$n / $dl" begin
            # Element-granular table: a padded element type is refused by the
            # GEP stride check (Bennett-edt9); a packed one reads natively.
            vals = [_ciss_val(n, k) for k in 0:3]
            ir = "target datalayout = \"$dl\"\n" *
                 "@g = constant [4 x i$n] [" * join(("i$n $v" for v in vals), ", ") * "]\n" *
                 "define i$n @julia_f(i8 %x) {\nentry:\n  %i = and i8 %x, 3\n" *
                 "  %iz = zext i8 %i to i64\n  %q = getelementptr i$n, ptr @g, i64 %iz\n" *
                 "  %v = load i$n, ptr %q\n  ret i$n %v\n}\n"
            c = _0cnv_try(ir)
            if _ciss_alloc(dl, n) == _ciss_store(n)
                @test c isa Bennett.ReversibleCircuit
                c isa Bennett.ReversibleCircuit || continue
                @test all((simulate(c, Int8(k)) % UInt64) & (n == 64 ? typemax(UInt64) : (UInt64(1) << n - 1)) ==
                          vals[k + 1] for k in 0:3)
                @test verify_reversibility(c)
            else
                @test occursin("allocation stride", _0cnv_msg(c))
            end
        end
        @testset "array of structs / i$n / $dl (refused loud)" begin
            g = "@g = constant { [2 x { i8, i$n }] } { [2 x { i8, i$n }] [{ i8, i$n } { i8 1, i$n 2 }, { i8, i$n } { i8 3, i$n 4 }] }"
            c = _0cnv_try(_ciss_byte_reader(dl, g, 4 * _ciss_alloc(dl, n)))
            @test occursin("not extractable as a constant integer byte stream", _0cnv_msg(c))
        end
    end
end
