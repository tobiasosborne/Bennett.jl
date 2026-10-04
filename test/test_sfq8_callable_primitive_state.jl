# Bennett-sfq8: the Bennett-2op8 callable-state rule treated "no fields" as
# "no state". `fieldcount` is 0 for every PRIMITIVE type, so a callable `Ptr`
# skipped the pointer refusal: `:tabulate` froze the pointee at compile time
# (wrong after the pointee changed) and `:expression` / `:auto` bound the
# address as a constant and loaded garbage. Separately, the state serialiser
# knew primitive sizes {1,2,4,8,16} only, so a 3- or 5-byte primitive field
# died with an internal `KeyError`.
#
# Invariant: "no state" means a zero-size singleton. Every other callable goes
# through ONE bind-or-refuse rule on every strategy: immutable plain-bits state
# with no pointer leaf (`Ptr`, `Core.LLVMPtr`) — primitive callables of any
# byte width included, with the in-memory padding of the object — is bound as
# constants (the circuit's inputs are exactly the declared arguments, and the
# result equals native Julia on every input); state holding a pointer, or
# anything mutable / non-isbits, is refused with an ArgumentError.

using Test, Bennett

primitive type P24sfq8 24 end
primitive type P40sfq8 40 end
_p24sfq8(b::UInt8) = reinterpret(P24sfq8, (b, 0x00, 0x00))
_p40sfq8(b::UInt8) = reinterpret(P40sfq8, (b, 0x00, 0x00, 0x00, 0x00))

# Callable primitives (methods on Base types are added for this test only;
# Base defines no call on numbers, pointers or chars).
(p::Ptr{Int8})(x::Int8) = x + unsafe_load(p)
(p::Core.LLVMPtr{Int8,0})(x::Int8) = x
(k::Int8)(x::Int8) = x + k
(k::UInt64)(x::Int8) = x ⊻ (k % Int8)
(k::Float64)(x::Int8) = x + unsafe_trunc(Int8, k)
(k::Bool)(x::Int8) = k ? x + Int8(1) : x - Int8(1)
(k::Char)(x::Int8) = x + (UInt32(k) % Int8)
(k::P24sfq8)(x::Int8) = x + reinterpret(NTuple{3,Int8}, k)[1]

struct F24sfq8; k::P24sfq8; end                  # sizeof 4: 1 byte tail padding
(f::F24sfq8)(x::Int8) = x + reinterpret(NTuple{3,Int8}, f.k)[1]
struct F40sfq8; a::Int8; k::P40sfq8; end         # 5-byte field at offset 8
(f::F40sfq8)(x::Int8) = x * f.a + reinterpret(NTuple{5,Int8}, f.k)[1]
struct Pad8sfq8; a::Int8; b::Int64; end          # 7 bytes interior padding
(f::Pad8sfq8)(x::Int8) = x * f.a + (f.b % Int8)
struct Trail8sfq8; b::Int64; a::Int8; end        # 7 bytes trailing padding
(f::Trail8sfq8)(x::Int8) = (x ⊻ f.a) - (f.b % Int8)
struct Three8sfq8; a::Int8; b::Int8; c::Int8; end   # 3 bytes, no padding
(f::Three8sfq8)(x::Int8) = x * f.a + f.b - f.c
struct PtrFsfq8; p::Ptr{Int8}; end
(f::PtrFsfq8)(x::Int8) = x + unsafe_load(f.p)
struct PtrInsfq8; p::Ptr{Int8}; end
struct PtrOutsfq8; a::Int8; i::PtrInsfq8; end    # pointer leaf one level down
(f::PtrOutsfq8)(x::Int8) = x + f.a + unsafe_load(f.i.p)
struct PtrTupsfq8; t::NTuple{2,Ptr{Int8}}; end  # pointer leaf inside a tuple
(f::PtrTupsfq8)(x::Int8) = x + unsafe_load(f.t[2])
struct PtrTypsfq8{T}; t::Type{T}; p::Ptr{Int8}; end   # non-isbits: Type field
(f::PtrTypsfq8)(x::Int8) = x + unsafe_load(f.p) + zero(f.t)
struct Emptysfq8 end
(f::Emptysfq8)(x::Int8) = x + Int8(2)
mutable struct MutEmptysfq8 end                  # mutable: refused, not "stateless"
(f::MutEmptysfq8)(x::Int8) = x + Int8(2)
struct VecFsfq8; v::Vector{Int8}; end           # non-isbits field
(f::VecFsfq8)(x::Int8) = x + f.v[1]
struct RefFsfq8; r::Base.RefValue{Int8}; end    # mutable field
(f::RefFsfq8)(x::Int8) = x + f.r[]
struct AnyFsfq8; a::Any; end                    # abstract field
(f::AnyFsfq8)(x::Int8) = x + (f.a::Int8)

const STRATS_sfq8 = (:expression, :tabulate, :auto)
const KS_sfq8 = (Int8(0), Int8(3), Int8(-7), typemin(Int8), typemax(Int8))
const UK_sfq8 = UInt8.(KS_sfq8 .% UInt8)

# label => callables to bind (several state values each)
const ACCEPT_sfq8 = [
    "callable Int8"     => [k for k in KS_sfq8],
    "callable UInt64"   => [UInt64(0), UInt64(0x0123456789abcdef), typemax(UInt64)],
    "callable Float64"  => [0.0, -0.0, 3.75, -100.5, 127.0],
    "callable Bool"     => [true, false],
    "callable Char"     => ['a', '\0', 'é', '\U1F600'],
    "callable P24 (3-byte primitive)" => [_p24sfq8(b) for b in UK_sfq8],
    "struct with P24 field (padded)"  => [F24sfq8(_p24sfq8(b)) for b in UK_sfq8],
    "struct with P40 field"           => [F40sfq8(k, _p40sfq8(0x05)) for k in KS_sfq8],
    "struct with interior padding"    => [Pad8sfq8(k, Int64(-300)) for k in KS_sfq8],
    "struct with trailing padding"    => [Trail8sfq8(Int64(1) << 40 + 9, k) for k in KS_sfq8],
    "struct of three Int8"            => [Three8sfq8(k, Int8(5), Int8(-2)) for k in KS_sfq8],
    "zero-size struct"  => [Emptysfq8()],
    "plain function"    => [identity, -],
    "closure capturing Int8" => [(let k = k; y -> y + k; end) for k in KS_sfq8],
    "closure capturing P24"  => [(let k = _p24sfq8(b); y -> y + reinterpret(NTuple{3,Int8}, k)[1]; end)
                                 for b in UK_sfq8],
]

function _errsfq8(thunk)
    try
        thunk()
        return nothing
    catch e
        return e
    end
end

@testset "Bennett-sfq8: callable primitive state is bound or refused" begin
    @testset "bound: $label, $strategy" for (label, fs) in ACCEPT_sfq8,
                                             strategy in STRATS_sfq8
        for f in fs
            c = reversible_compile(f, Int8; strategy)
            @test c.input_widths == [8]            # the declared argument only
            @test verify_reversibility(c)
            bad = [x for x in typemin(Int8):typemax(Int8) if simulate(c, x) != f(x)]
            @test isempty(bad)
        end
    end

    # Pointer state: refused on every strategy, so a later change of the
    # pointee cannot leave a stale or garbage circuit behind.
    cell = Ref(Int8(3))
    other = Ref(Int8(11))
    GC.@preserve cell other begin
        p = Base.unsafe_convert(Ptr{Int8}, cell)
        q = Base.unsafe_convert(Ptr{Int8}, other)
        REJECT_sfq8 = [
            "callable Ptr"             => p,
            "callable LLVMPtr"         => reinterpret(Core.LLVMPtr{Int8,0}, p),
            "struct with Ptr field"    => PtrFsfq8(p),
            "nested struct, Ptr leaf"  => PtrOutsfq8(Int8(1), PtrInsfq8(p)),
            "tuple of Ptr field"       => PtrTupsfq8((q, p)),
            "Type field + Ptr field"   => PtrTypsfq8(Int8, p),
            "closure capturing Ptr"    => (let p = p; y -> y + unsafe_load(p); end),
            "Fix2 holding a Ptr"       => Base.Fix2((x, p) -> x + unsafe_load(p), p),
            "mutable zero-field struct" => MutEmptysfq8(),
            "struct with Vector field" => VecFsfq8(Int8[3]),
            "struct with Ref field"    => RefFsfq8(Ref(Int8(3))),
            "struct with Any field"    => AnyFsfq8(Int8(3)),
        ]
        @testset "refused: $label, $strategy" for (label, f) in REJECT_sfq8,
                                                   strategy in STRATS_sfq8
            for pointee in (Int8(3), Int8(9))
                cell[] = pointee                 # mutation cannot matter: no circuit
                err = _errsfq8(() -> reversible_compile(f, Int8; strategy))
                @test err isa ArgumentError
                msg = err === nothing ? "" : sprint(showerror, err)
                @test occursin("immutable plain-bits", msg)
                @test occursin("Bennett-sfq8", msg)
            end
        end
        @test p(Int8(1)) == Int8(10)             # the pointee did change natively
    end

    # The parsed-IR cache compared `f` by `isequal`, which equates callables of
    # different types (`Int8(0)`, `UInt64(0)`, `0.0`, `false`): the second
    # compile got the first one's IR. Back-to-back, each must match native.
    @testset "isequal callables of different types do not share IR, $strategy" for
            strategy in (:expression, :auto)
        for fs in ((Int8(0), UInt64(0), 0.0, false), (Int8(1), true, 1.0, UInt64(1)))
            for f in fs
                c = reversible_compile(f, Int8; strategy)
                @test c.input_widths == [8]
                @test verify_reversibility(c)
                @test all(simulate(c, x) == f(x) for x in typemin(Int8):typemax(Int8))
            end
        end
    end
end
