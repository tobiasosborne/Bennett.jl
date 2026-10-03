using Test
using Bennett
using Bennett: _parsed_ir_from_ir_string

# Bennett-9fke: `src/extract/module_walk.jl`'s cc0.3 catch SKIPPED any
# instruction whose conversion raised a MethodError mentioning `PointerType`
# (LLVM.jl has no `width(::PointerType)` — e.g. `extractvalue [2 x ptr]`,
# `insertvalue [2 x ptr]`), with no certificate. A skipped value still read
# by a live consumer left an undefined SSA name: `load i8, ptr %e` /
# `store i8 %x, ptr %e` through such a value extracted WITHOUT error.
#
# Invariant: such an instruction is skipped ONLY when it is a side-effect-free
# value AND transitively dead (every user is itself a dead side-effect-free
# value). Otherwise extraction raises `_ir_error` naming Bennett-9fke and the
# instruction.

function _9fke_err(ir)
    try
        _parsed_ir_from_ir_string(ir)
    catch e
        return sprint(showerror, e)
    end
    return nothing
end

# Live consumers of a pointer read out of a `[N x ptr]` aggregate.
const _9FKE_CONSUMERS = [
    "load"   => (e -> "  %l = load i8, ptr $e, align 1\n  ret i8 %l"),
    "store"  => (e -> "  store i8 %x, ptr $e, align 1\n  ret i8 %x"),
    "icmp"   => (e -> "  %c = icmp eq ptr $e, %q\n  %r = zext i1 %c to i8\n  ret i8 %r"),
    "select" => (e -> "  %c = icmp eq i8 %x, 0\n  %s = select i1 %c, ptr $e, ptr %q\n" *
                      "  %l = load i8, ptr %s, align 1\n  ret i8 %l"),
]

@testset "Bennett-9fke: PointerType MethodError skip requires a dead-value certificate" begin

    @testset "live extractvalue [$n x ptr] idx $i -> $cname is loud" for n in (2, 3, 4),
            i in (0, n - 1), (cname, cons) in _9FKE_CONSUMERS
        ir = "define i8 @julia_f(i8 %x, [$n x ptr] %a, ptr %q) {\n" *
             "  %e = extractvalue [$n x ptr] %a, $i\n" * cons("%e") * "\n}"
        msg = _9fke_err(ir)
        @test msg !== nothing
        msg === nothing && continue
        @test occursin("Bennett-9fke", msg)
        @test occursin("ir_extract.jl:", msg)
        @test occursin("extractvalue [$n x ptr] %a, $i", msg)   # names the instruction
        @test occursin("PointerType", msg)
    end

    # A live chain: insertvalue -> extractvalue -> load. The FIRST instruction
    # of the chain is live (transitively), so it is the one reported.
    @testset "live insertvalue [$n x ptr] chain is loud" for n in (2, 3)
        ir = "define i8 @julia_f(i8 %x, ptr %p) {\n" *
             "  %a = insertvalue [$n x ptr] undef, ptr %p, 0\n" *
             "  %e = extractvalue [$n x ptr] %a, 0\n" *
             "  %l = load i8, ptr %e, align 1\n  ret i8 %l\n}"
        msg = _9fke_err(ir)
        @test msg !== nothing
        msg === nothing && continue
        @test occursin("Bennett-9fke", msg)
        @test occursin("insertvalue [$n x ptr] undef, ptr %p, 0", msg)
    end

    # Certified skips: the pointer aggregate is transitively dead, so dropping
    # it changes nothing. The circuit must still compute the arithmetic exactly.
    dead_bodies = [
        "dead extractvalue" => "  %e = extractvalue [2 x ptr] %a, 1\n",
        "dead insertvalue"  => "  %b = insertvalue [3 x ptr] undef, ptr %p, 2\n",
        "dead chain"        => "  %b = insertvalue [2 x ptr] undef, ptr %p, 0\n" *
                               "  %c = insertvalue [2 x ptr] %b, ptr %p, 1\n" *
                               "  %d = extractvalue [2 x ptr] %c, 0\n",
    ]
    @testset "$dname is skipped and the circuit is exact" for (dname, body) in dead_bodies
        ir = "define i8 @julia_f(i8 %x, ptr %p) {\n" *
             "  %a = insertvalue [2 x ptr] undef, ptr %p, 0\n" *
             body *
             "  %r = mul i8 %x, 3\n  %t = add i8 %r, 7\n  ret i8 %t\n}"
        pir = _parsed_ir_from_ir_string(ir)
        c = reversible_compile(pir)
        for v in typemin(Int8):typemax(Int8), p in (Int64(0), Int64(-1), Int64(0x1234))
            @test simulate(c, (v, p)) == v * Int8(3) + Int8(7)
        end
        @test verify_reversibility(c)
    end
end
