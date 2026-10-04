# Bennett-omhx — `_extract_const_globals` (src/extract/module_walk.jl) decides
# which constant globals enter `parsed.globals` by INSPECTING THE VALUE, never
# by matching the text of an exception.
#
# Pre-fix there were two defects for a constant global whose initializer
# references a GlobalAlias (LLVM.jl cannot wrap a GlobalAlias: "Unknown value
# kind LLVMGlobalAliasValueKind"):
#   (1) bare initializer `@g = constant ptr @alias` — `LLVM.initializer(g)`
#       threw, a try/catch matched "Unknown value kind" / "LLVMGlobalAlias" in
#       the MESSAGE and skipped the global, whatever the alias was;
#   (2) struct initializer `@g = constant { i8, ptr } { i8 5, ptr @alias }` —
#       `_flatten_struct_to_bytes` wrapped every field with `LLVM.Value`, so the
#       raw LLVM.jl error escaped and killed the WHOLE compile even when the
#       function never reads `@g` (breaking Bennett-fpa0's "an unread global
#       costs nothing" contract) — for Julia's own `jl_global#N.jit` aliases too.
#
# Invariant: a global is included, or excluded by a value-kind check on its
# initializer; an excluded global costs nothing while unread, and a READ of it
# is a loud error naming it. A ptr field through an alias resolves exactly as
# the aliasee does (`_ptr_identity` follows alias chains): an alias of a global
# or function gets the aliasee's synthetic address (byte-identical to naming
# the aliasee directly); a `jl_global#N.jit` alias (aliasee `inttoptr`) is
# rejected like any inttoptr ptr field.

using Test, Bennett

const _OMHX_HDR =
    "target datalayout = \"e-m:e-i64:64-f80:128-n8:16:32:64-S128\"\n" *
    "declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)\n" *
    "@h = constant i8 5\n" *
    "@\"jl_global#5.jit\" = private alias ptr, inttoptr (i64 1234 to ptr)\n" *
    "@a = alias i8, ptr @h\n" *
    "define void @fn() {\nentry:\n  ret void\n}\n" *
    "@af = alias void (), ptr @fn\n"

_omhx_unread(g) = _OMHX_HDR * g * "\n" * """
define i8 @julia_f(i8 %x) {
entry:
  ret i8 %x
}
"""

# memcpy the whole global into a byte alloca, load byte (x & (nb-1)).
_omhx_memcpy_read(g, nb) = _OMHX_HDR * g * "\n" * """
define i8 @julia_f(i8 %x) {
entry:
  %dst = alloca [$nb x i8], align 1
  call void @llvm.memcpy.p0.p0.i64(ptr %dst, ptr @g, i64 $nb, i1 false)
  %i = and i8 %x, $(nb - 1)
  %iz = zext i8 %i to i64
  %p = getelementptr inbounds i8, ptr %dst, i64 %iz
  %y = load i8, ptr %p
  %r = add i8 %y, %x
  ret i8 %r
}
"""

function _omhx_err(ir)
    try
        Bennett._parsed_ir_from_ir_string(ir)
    catch e
        e isa InterruptException && rethrow()
        return e
    end
    return nothing
end

# (label, operand text, aliasee text or nothing, struct field resolvable?)
const _OMHX_REFS = [
    ("jl_global runtime alias", "@\"jl_global#5.jit\"", nothing, false),
    ("alias of a constant global", "@a", "@h", true),
    ("alias of a function", "@af", "@fn", true),
    ("no alias (control)", "@h", nothing, true),
]

const _OMHX_G5 = "not extractable as a constant integer byte stream"

@testset "Bennett-omhx: alias-referencing const-global initializers" begin
    for (label, ref, aliasee, resolvable) in _OMHX_REFS
        shapes = [
            ("bare ptr", "@g = constant ptr $ref", 8, false),
            ("struct { i8, ptr }",
             "@g = constant { i8, ptr } { i8 5, ptr $ref }", 16, resolvable),
        ]
        for (sname, gdecl, nb, included) in shapes
            @testset "$label / $sname / unread" begin
                p = Bennett._parsed_ir_from_ir_string(_omhx_unread(gdecl))
                @test haskey(p.globals, :g) == included
                if included && aliasee !== nothing
                    # Through the alias == naming the aliasee directly.
                    q = Bennett._parsed_ir_from_ir_string(
                        _omhx_unread(replace(gdecl, ref => aliasee)))
                    @test p.globals[:g] == q.globals[:g]
                end
                if included
                    # Field 0 (i8 5) and the padding are exact; the ptr field
                    # holds a non-zero synthetic address.
                    data = p.globals[:g][1]
                    @test data[1:8] == UInt64[5, 0, 0, 0, 0, 0, 0, 0]
                    @test any(!iszero, data[9:16])
                end
                c = reversible_compile(p)
                @test verify_reversibility(c)
                @test all(simulate(c, x) == x for x in typemin(Int8):typemax(Int8))
            end
            @testset "$label / $sname / read" begin
                err = _omhx_err(_omhx_memcpy_read(gdecl, nb))
                @test err isa ErrorException
                msg = err === nothing ? "" : sprint(showerror, err)
                # Never a raw LLVM.jl "Unknown value kind" escaping the walk.
                @test !occursin("Unknown value kind", msg)
                if included
                    # Same refusal as naming the aliasee directly: the
                    # Bennett-land escape guard on synthetic-address bytes.
                    @test occursin("Bennett-land-ptrload", msg)
                else
                    # Excluded global: G5 refuses the read, naming it.
                    @test occursin(_OMHX_G5, msg)
                    @test occursin("@g", msg)
                end
            end
        end
    end

    @testset "no exception-text matching in _extract_const_globals" begin
        src = read(joinpath(dirname(pathof(Bennett)), "extract", "module_walk.jl"),
                   String)
        i = findfirst("function _extract_const_globals", src)
        @test i !== nothing
        j = findnext(r"\nend\n", src, last(i))
        body = src[first(i):last(j)]
        @test !occursin("catch", body)
        @test !occursin("showerror", body)
        @test !occursin("Unknown value kind", body)
    end
end
