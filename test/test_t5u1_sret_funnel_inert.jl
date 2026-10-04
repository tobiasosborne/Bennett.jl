using Test, Bennett
using Bennett: extract_parsed_ir_from_ll, reversible_compile, simulate,
               verify_reversibility

# Bennett-t5u1 — the sret `ret void` return funnel (Bennett-jghk
# `sret_drop_block`) is deleted WHOLESALE at sret synthesis. Invariant: it is
# deleted only when every instruction in it is certified inert — the `ret void`
# itself, an sret-accounted instruction, or a side-effect-free value (dead once
# the successor-less block goes). Any other instruction in a funnel → loud
# extraction error naming function, block and instruction. Pre-fix, the Astra
# B-extract-core F3 witness (`call @mutate(ptr %out)` in the funnel) compiled
# and returned the un-mutated value 3 instead of 99.

const _T5U1_DL = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"

const _T5U1_PRELUDE = """
@g = global i8 0

define void @mutate(ptr %p) {
entry:
  store i8 99, ptr %p
  ret void
}

define i8 @ident(i8 %v) {
entry:
  ret i8 %v
}
"""

# Funnel contents. `nothing` → must compile; otherwise the needle the refusal
# must carry.
const _T5U1_FUNNELS = [
    ("empty",          "",                                              nothing),
    ("dead_pure",      "  %d0 = add i8 %x, 1\n  %d1 = icmp eq i8 %d0, 5\n" *
                       "  %d2 = select i1 %d1, i8 %d0, i8 %x\n",        nothing),
    # a store to slot 0 makes the funnel a (partial) store block → jghk refusal
    ("sret_slot_store","  store i8 42, ptr %out\n",                     "never written"),
    # a plain dead store to a local alloca is removed by the sret-forced SROA /
    # mem2reg before extraction — genuinely inert, so it compiles faithfully
    ("alloca_store",   "  store i8 42, ptr %tmp\n",                     nothing),
    # a volatile one survives the passes and reaches the funnel check
    ("alloca_vstore",  "  store volatile i8 42, ptr %tmp\n",            "Bennett-t5u1"),
    ("global_store",   "  store i8 %x, ptr @g\n",                       "Bennett-t5u1"),
    ("call_mutate",    "  call void @mutate(ptr %out)\n",               "Bennett-t5u1"),
    ("call_pure",      "  %r = call i8 @ident(i8 %x)\n",                "Bennett-t5u1"),
]

# Return-path topologies feeding the funnel. Each writes BOTH [2 x i8] slots
# then branches unconditionally to `%common` (the jghk MVP shape), so the code
# under test — the funnel drop — is actually reached.
function _t5u1_module(topo::Symbol, name::String, funnel::String)
    head = "define void @$name(ptr sret([2 x i8]) %out, i8 %x, i8 %c) {\n" *
           "entry:\n  %tmp = alloca i8\n"
    body = if topo === :single
        """
          %a0 = add i8 %x, 1
          store i8 %a0, ptr %out
          %p1 = getelementptr inbounds i8, ptr %out, i64 1
          store i8 %x, ptr %p1
          br label %common
        """
    else  # :two_arm
        """
          %cc = icmp ne i8 %c, 0
          br i1 %cc, label %A, label %B
        A:
          %a0 = add i8 %x, 1
          store i8 %a0, ptr %out
          %pa = getelementptr inbounds i8, ptr %out, i64 1
          store i8 %x, ptr %pa
          br label %common
        B:
          store i8 %x, ptr %out
          %pb = getelementptr inbounds i8, ptr %out, i64 1
          store i8 7, ptr %pb
          br label %common
        """
    end
    return "target datalayout = \"$_T5U1_DL\"\n\n" * _T5U1_PRELUDE * "\n" *
           head * body * "common:\n" * funnel * "  ret void\n}\n"
end

_t5u1_expected(topo, x::UInt8, c::UInt8) =
    (topo === :single || c != 0) ? (x + 0x01, x) : (x, 0x07)

function _t5u1_extract(topo, name, funnel)
    path = tempname() * "_t5u1.ll"
    write(path, _t5u1_module(topo, name, funnel))
    return extract_parsed_ir_from_ll(path; entry_function=name)
end

@testset "Bennett-t5u1: sret return funnel deleted only when inert" begin
    for topo in (:single, :two_arm), (tag, funnel, needle) in _T5U1_FUNNELS
        name = "t5u1_$(topo)_$(tag)"
        @testset "$name" begin
            if needle === nothing
                c = reversible_compile(_t5u1_extract(topo, name, funnel))
                @test verify_reversibility(c)
                ok = true
                for x in 0x00:0xff, cv in (0x00, 0x01, 0x80)
                    out = simulate(c, (x, cv))
                    exp = _t5u1_expected(topo, x, cv)
                    ok &= (out[1] % UInt8, out[2] % UInt8) == exp
                end
                @test ok
            else
                err = try
                    _t5u1_extract(topo, name, funnel); nothing
                catch e
                    sprint(showerror, e)
                end
                @test err !== nothing
                err === nothing || @test occursin(needle, err)
                # the error names the function and the funnel block
                (err === nothing || needle != "Bennett-t5u1") ||
                    @test occursin("@$name:%common", err)
            end
        end
    end

    @testset "Astra F3 witness: sret pointer escapes to a mutating call" begin
        path = tempname() * "_t5u1_f3.ll"
        write(path, "target datalayout = \"$_T5U1_DL\"\n\n" * """
        define void @mutate(ptr %p) {
        entry:
          store i8 99, ptr %p
          ret void
        }
        define void @julia_sret(ptr sret([1 x i8]) %out, i8 %x) {
        entry:
          store i8 %x, ptr %out
          br label %common
        common:
          call void @mutate(ptr %out)
          ret void
        }
        """)
        err = try
            extract_parsed_ir_from_ll(path; entry_function="julia_sret"); nothing
        catch e
            sprint(showerror, e)
        end
        @test err !== nothing
        err === nothing || @test occursin("Bennett-t5u1", err)
        err === nothing || @test occursin("call void @mutate", err)
    end
end
