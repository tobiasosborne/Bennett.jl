using Test
using Bennett
using LLVM

# Bennett-0gm7 — Bennett-08xz drops a runtime-throw-named call (`ijl_throw`,
# `j_throw_*`, `*_bounds_error*`) only when it provably cannot return. Without a
# `noreturn` attribute the proof was "the NEXT instruction is `unreachable`", so
# a harmless instruction between the call and the block's `unreachable` (an
# `llvm.assume`, a debug intrinsic, a lifetime marker) defeated it and the call
# hit the loud unregistered-callee error, although the block still ends in
# `unreachable` (review 2, finding S7; the witness compiled before a2d296d).
#
# Fix: `_is_noreturn_call` scans forward to the block terminator, skipping only
# instructions that the extractor itself drops and that have no observable
# effect (`llvm.dbg.*`, `llvm.lifetime.*`, `llvm.assume`,
# `llvm.experimental.noalias.scope.decl`, `llvm.trap`, and further
# runtime-throw-named calls), and accepts iff the terminator is `unreachable`.
# Anything else (a store, a call to any other function, a non-call
# instruction, a `ret` / `br` terminator) ends the scan with "can return".
# `_is_noreturn_call` is also the criterion of the Case-A vector_vm skeleton
# check (`_vec_vm_is_skel_callee`), so the helper is pinned directly below too.

const _0GM7_DECLS = """
declare void @ijl_throw(i8)
declare void @ijl_bounds_error_int(i8, i64)
declare void @ext_fn(i8)
declare void @llvm.assume(i1)
declare void @llvm.trap()
declare void @llvm.lifetime.start.p0(i64, ptr)
declare void @llvm.lifetime.end.p0(i64, ptr)
declare void @llvm.dbg.value(metadata, metadata, metadata)
declare void @llvm.dbg.declare(metadata, metadata, metadata)
declare void @llvm.experimental.noalias.scope.decl(metadata)
"""

const _0GM7_META = """
!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!3}
!0 = distinct !DICompileUnit(language: DW_LANG_C99, file: !1, producer: "x", isOptimized: false, runtimeVersion: 0, emissionKind: FullDebug)
!1 = !DIFile(filename: "a.c", directory: "/")
!3 = !{i32 2, !"Debug Info Version", i32 3}
!5 = distinct !DISubprogram(name: "r", scope: !1, file: !1, line: 1, type: !6, unit: !0, retainedNodes: !8)
!6 = !DISubroutineType(types: !7)
!7 = !{null}
!8 = !{}
!9 = !DILocalVariable(name: "x", scope: !5, file: !1, line: 1, type: !11)
!10 = !DILocation(line: 1, scope: !5)
!11 = !DIBasicType(name: "char", size: 8, encoding: DW_ATE_signed)
!20 = !{!21}
!21 = distinct !{!21, !22}
!22 = distinct !{!22}
"""

# x + 1, with a never-taken `fail` block (`icmp ult x, 0` is always false)
# whose body is `call @ijl_throw` + `tail`, where `tail` ends in a terminator.
_0gm7_ir(tail::AbstractString) = """
$(_0GM7_DECLS)
define i8 @julia_review(i8 %x) !dbg !5 {
entry:
  %a = alloca i8
  %bad = icmp ult i8 %x, 0
  br i1 %bad, label %fail, label %ok
fail:
  call void @ijl_throw(i8 %x)
$(tail)
ok:
  %r = add i8 %x, 1
  ret i8 %r
}
$(_0GM7_META)
"""

# Every tail that ends in `unreachable` behind only harmless instructions.
const _0GM7_ACCEPT = [
    "nothing between"     => "  unreachable",
    "llvm.assume"         => "  call void @llvm.assume(i1 true)\n  unreachable",
    "llvm.dbg.value"      => "  call void @llvm.dbg.value(metadata i8 %x, metadata !9, metadata !DIExpression()), !dbg !10\n  unreachable",
    "llvm.dbg.declare"    => "  call void @llvm.dbg.declare(metadata ptr %a, metadata !9, metadata !DIExpression()), !dbg !10\n  unreachable",
    "llvm.lifetime.end"   => "  call void @llvm.lifetime.end.p0(i64 1, ptr %a)\n  unreachable",
    "llvm.lifetime.start" => "  call void @llvm.lifetime.start.p0(i64 1, ptr %a)\n  unreachable",
    "noalias.scope.decl"  => "  call void @llvm.experimental.noalias.scope.decl(metadata !20)\n  unreachable",
    "llvm.trap"           => "  call void @llvm.trap()\n  unreachable",
    "second throw"        => "  call void @ijl_bounds_error_int(i8 %x, i64 1)\n  unreachable",
    "mixed run"           => "  call void @llvm.lifetime.end.p0(i64 1, ptr %a)\n  call void @llvm.assume(i1 true)\n" *
                             "  call void @llvm.dbg.value(metadata i8 %x, metadata !9, metadata !DIExpression()), !dbg !10\n" *
                             "  call void @ijl_throw(i8 %x)\n  call void @llvm.trap()\n  unreachable",
]

# Tails after which the call may return to observable code: pinned as the loud
# U15 unregistered-callee error naming `ijl_throw`.
const _0GM7_REJECT = [
    "store between"        => "  store i8 %x, ptr %a\n  unreachable",
    "unknown call between" => "  call void @ext_fn(i8 %x)\n  unreachable",
    "assume then store"    => "  call void @llvm.assume(i1 true)\n  store i8 %x, ptr %a\n  unreachable",
    "non-call between"     => "  %y = add i8 %x, 1\n  unreachable",
    "block ends in ret"    => "  call void @llvm.assume(i1 true)\n  ret i8 0",
    "block ends in br"     => "  call void @llvm.assume(i1 true)\n  br label %ok",
]

function _0gm7_compile_ok(ir)
    c = reversible_compile(Bennett._parsed_ir_from_ir_string(ir))
    bad = [x for x in 0:255 if simulate(c, UInt8(x)) != (x + 1) % 256]
    isempty(bad) || @info "Bennett-0gm7 mismatches" first(bad, 5)
    return isempty(bad) && verify_reversibility(c)
end

function _0gm7_loud(ir)
    try
        reversible_compile(Bennett._parsed_ir_from_ir_string(ir))
        return false
    catch e
        msg = sprint(showerror, e)
        ok = occursin("call to 'ijl_throw' has no registered callee handler", msg)
        ok || @info "Bennett-0gm7 unexpected error" first(msg, 300)
        return ok
    end
end

@testset "Bennett-0gm7 noreturn tail scan" begin
    @testset "review witness (verbatim)" begin
        ir = """
        declare void @ijl_throw(i8)
        declare void @llvm.assume(i1)
        define i8 @julia_review(i8 %x) {
        entry:
          %bad = icmp ult i8 %x, 0
          br i1 %bad, label %fail, label %ok
        fail:
          call void @ijl_throw(i8 %x)
          call void @llvm.assume(i1 true)
          unreachable
        ok:
          %r = add i8 %x, 1
          ret i8 %r
        }
        """
        p = Bennett._parsed_ir_from_ir_string(ir)
        c = reversible_compile(p)
        @test (Int(simulate(c, UInt8(1))), verify_reversibility(c)) == (2, true)
        @test _0gm7_compile_ok(ir)
    end

    @testset "accepted: $(k)" for (k, tail) in _0GM7_ACCEPT
        @test _0gm7_compile_ok(_0gm7_ir(tail))
    end

    @testset "rejected loud: $(k)" for (k, tail) in _0GM7_REJECT
        @test _0gm7_loud(_0gm7_ir(tail))
    end

    # The shared helper itself — also the vector_vm Case-A skeleton criterion.
    @testset "_is_noreturn_call on the first call of each fail block" begin
        for (tails, want) in ((_0GM7_ACCEPT, true), (_0GM7_REJECT, false)), (k, tail) in tails
            got = LLVM.Context() do _
                m = parse(LLVM.Module, _0gm7_ir(tail))
                f = LLVM.functions(m)["julia_review"]
                bb = only(b for b in LLVM.blocks(f) if LLVM.name(b) == "fail")
                Bennett._is_noreturn_call(first(LLVM.instructions(bb)))
            end
            got == want || @info "Bennett-0gm7 helper" k got want
            @test got == want
        end
    end
end
