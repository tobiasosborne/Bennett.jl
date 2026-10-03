using Test
using Bennett
using LLVM

# Bennett-ovzp (Astra B-lowering F4): storing a NEGATIVE integer constant
# through a runtime-indexed pointer into a packed alloca threw
# `InexactError: convert(UInt64, -1)` — `_operand_to_u64!` (the MUX-EXCH
# operand materialiser in src/lowering/memory.jl) converted the constant with
# the value-checked `UInt64(op.value)`. Every other store arm (shadow,
# shadow-checkpoint, persistent) goes through `resolve!(::ConstOperand)`,
# which already takes the bit pattern. The fix materialises the constant's
# two's-complement bit pattern masked to the store width, matching the SSA
# arm (which zero-extends the iW wires).
#
# Hand-built IR because Julia's codegen promotes small local arrays out of
# memory before Bennett sees them (see test_nj6c_extended_mux_shapes.jl).
# Every fixture first fills all N slots with the runtime value %v through
# constant-index stores, so the oracle covers the stored slot AND every
# neighbour (a sign-extended constant leaking into the next slot would show).

function _ovzp_compile(ir::String; kw...)
    c = nothing
    LLVM.Context() do _ctx
        mod = parse(LLVM.Module, ir)
        parsed = Bennett._module_to_parsed_ir(mod)
        lr = Bennett.lower(parsed; kw...)
        c = Bennett.bennett(lr)
        dispose(mod)
    end
    return c::Bennett.ReversibleCircuit
end

const _OVZP_T = Dict(8 => Int8, 16 => Int16, 32 => Int32, 64 => Int64)

# typemin, -1, and a mixed-bit negative pattern (0xA5…A5) at width W.
_ovzp_consts(::Type{T}) where {T} =
    T[typemin(T), T(-1), reinterpret(T, unsigned(T)(0xA5A5A5A5A5A5A5A5 % unsigned(T)))]

# Fill + (optionally guarded) store of constant C at runtime index %i + load at %j.
# guarded=false: store lives in the entry block (unguarded callee / arm).
# guarded=true : store lives in a non-entry block taken when %f != 0.
function _ovzp_ir(W::Int, N::Int, C::Integer; guarded::Bool, const_idx::Union{Nothing,Int}=nothing)
    ty = "i$W"
    fill = join(["  %s$k = getelementptr $ty, ptr %p, i32 $k\n  store $ty %v, ptr %s$k" for k in 0:N-1], "\n")
    idx = const_idx === nothing ? "i32 %i" : "i32 $const_idx"
    st = "  %g = getelementptr $ty, ptr %p, $idx\n  store $ty $C, ptr %g"
    body = guarded ? """
      %c = icmp ne i8 %f, 0
      br i1 %c, label %then, label %join
    then:
    $st
      br label %join
    join:
    """ : st * "\n"
    return """
    define $ty @julia_ovzp(i32 %i, i32 %j, i8 %f, $ty %v) {
    top:
      %p = alloca $ty, i32 $N
    $fill
    $body  %h = getelementptr $ty, ptr %p, i32 %j
      %r = load $ty, ptr %h
      ret $ty %r
    }
    """
end

function _ovzp_check(W, N, C; guarded, const_idx=nothing, vs)
    T = _OVZP_T[W]
    c = _ovzp_compile(_ovzp_ir(W, N, C; guarded, const_idx))
    @test verify_reversibility(c)
    bad = Any[]
    idxs = UInt32(0):UInt32(N - 1)
    is = const_idx === nothing ? idxs : (UInt32(const_idx):UInt32(const_idx))
    for i in is, j in idxs, f in (guarded ? (Int8(0), Int8(1)) : (Int8(1),)), v in vs
        got = simulate(c, (i, j, f, v))
        want = (f != 0 && i == j) ? T(C) : v
        reinterpret(unsigned(T), T(got % T)) == reinterpret(unsigned(T), want) ||
            (length(bad) < 5 && push!(bad, (i, j, f, v, got, want)))
    end
    isempty(bad) || @info "Bennett-ovzp mismatches" W N C guarded const_idx bad
    @test isempty(bad)
end

_ovzp_vs(::Type{Int8}; exhaustive::Bool=false) =
    exhaustive ? collect(typemin(Int8):typemax(Int8)) : Int8[0, 1, -1, 0x5a % Int8, typemin(Int8), typemax(Int8)]
_ovzp_vs(::Type{T}; exhaustive::Bool=false) where {T} =
    T[zero(T), one(T), T(-1), typemin(T), typemax(T), reinterpret(T, unsigned(T)(0x5A5A5A5A5A5A5A5A % unsigned(T)))]

@testset "Bennett-ovzp: negative constant stores into packed allocas" begin

    @testset "MUX-EXCH runtime idx, every registered shape (N=$N, W=$W)" for (N, W) in Bennett._MUX_SHAPES_NW
        T = _OVZP_T[W]
        for C in _ovzp_consts(T), guarded in (false, true)
            # Exhaustive over Int8 %v on the (4,8) shape; representative elsewhere.
            _ovzp_check(W, N, C; guarded, vs=_ovzp_vs(T; exhaustive=(N, W) == (4, 8)))
        end
    end

    @testset "shadow arm (constant idx), W=$W" for (N, W) in ((4, 8), (2, 16), (2, 32), (2, 64))
        T = _OVZP_T[W]
        for C in _ovzp_consts(T), guarded in (false, true)
            _ovzp_check(W, N, C; guarded, const_idx=N - 1, vs=_ovzp_vs(T; exhaustive=W == 8))
        end
    end

    @testset "shadow-checkpoint arm (runtime idx, N·W > 64), (N=$N, W=$W)" for (N, W) in ((9, 8), (5, 16), (3, 32), (2, 64))
        T = _OVZP_T[W]
        for C in _ovzp_consts(T), guarded in (false, true)
            _ovzp_check(W, N, C; guarded, vs=_ovzp_vs(T))
        end
    end

    @testset "persistent arm (dynamic n, linear_scan), i8 C=$C" for C in _ovzp_consts(Int8)
        ir = """
        define i8 @julia_ovzp_p(i32 %n, i8 %k, i8 %lookup) {
        top:
          %slab = alloca i64, i32 %n
          %gs = getelementptr i64, ptr %slab, i8 %k
          store i8 $C, ptr %gs
          %gl = getelementptr i64, ptr %slab, i8 %lookup
          %r = load i8, ptr %gl
          ret i8 %r
        }
        """
        c = _ovzp_compile(ir; mem=:persistent, persistent_impl=:linear_scan)
        @test verify_reversibility(c)
        bad = Any[]
        for k in Int8[0, 1, 7, -1, typemin(Int8)], lookup in Int8[0, 1, 7, -1, typemin(Int8)]
            got = simulate(c, (UInt32(4), k, lookup)) % Int8
            want = k == lookup ? Int8(C) : Int8(0)
            got == want || push!(bad, (k, lookup, got, want))
        end
        @test isempty(bad)
    end
end
