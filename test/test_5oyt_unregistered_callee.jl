using Test
using Bennett: extract_parsed_ir_from_ll

# Bennett-5oyt / U15 — calls that didn't match any intrinsic pattern and
# weren't in the callee registry were silently dropped. Their dest SSA
# was left undefined; later instructions referencing it crashed with
# "Undefined SSA variable" far from the root cause. CLAUDE.md §1 violation.
# Post-fix: `_ir_error` naming the callee (or "inline-asm") immediately.

# T1 — unregistered external callee.
const UNREG_IR = """
declare i32 @external_fn(i32)
define i32 @julia_caller(i32 %x) {
top:
  %r = call i32 @external_fn(i32 %x)
  ret i32 %r
}
"""

# T2 — inline asm.
const ASM_IR = """
define i32 @julia_asm(i32 %x) {
top:
  %r = call i32 asm "mov \$1, \$0", "=r,r"(i32 %x)
  ret i32 %r
}
"""

# T3 — benign lifetime intrinsic (correctness-neutral drop; must NOT fail loud).
const LIFETIME_IR = """
declare void @llvm.lifetime.start.p0(i64, ptr)
define i32 @julia_lifetime(i32 %x) {
top:
  %p = alloca i32
  call void @llvm.lifetime.start.p0(i64 4, ptr %p)
  store i32 %x, ptr %p
  %r = load i32, ptr %p
  ret i32 %r
}
"""

@testset "Bennett-5oyt unregistered/inline-asm calls fail-loud" begin
    mktempdir() do dir

        # T1 — unregistered callee → loud.
        path1 = joinpath(dir, "unreg.ll")
        write(path1, UNREG_IR)
        try
            extract_parsed_ir_from_ll(path1; entry_function="julia_caller")
            @test false
        catch e
            msg = sprint(showerror, e)
            @test occursin("external_fn", msg) ||
                  occursin("registered callee", lowercase(msg)) ||
                  occursin("no handler", lowercase(msg))
        end

        # T2 — inline asm → loud.
        path2 = joinpath(dir, "asm.ll")
        write(path2, ASM_IR)
        try
            extract_parsed_ir_from_ll(path2; entry_function="julia_asm")
            @test false
        catch e
            msg = sprint(showerror, e)
            @test occursin("inline", lowercase(msg)) ||
                  occursin("asm", lowercase(msg))
        end

        # T3 — lifetime intrinsic → silent drop (extraction succeeds).
        path3 = joinpath(dir, "life.ll")
        write(path3, LIFETIME_IR)
        pir = extract_parsed_ir_from_ll(path3; entry_function="julia_lifetime")
        @test pir !== nothing
    end
end
