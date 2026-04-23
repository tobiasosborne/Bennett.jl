using Test
using Bennett: extract_parsed_ir_from_ll

# Bennett-4mmt / U14 — atomic and volatile load/store were silently
# coerced to plain integer IRLoad / IRStore. A `load atomic i32` or
# `store volatile i32 …` produced the same IR as the non-atomic variant;
# any ordering guarantees the source program relied on were erased with
# no diagnostic. Per CLAUDE.md §1 (fail fast, fail loud), reject them
# explicitly: reversible compilation has no semantics for atomic
# ordering today, so silently accepting the op would be a correctness
# trap.

const ATOMIC_LOAD_IR = """
define i32 @julia_atomic_load(ptr %p) {
top:
  %v = load atomic i32, ptr %p unordered, align 4
  ret i32 %v
}
"""

const VOLATILE_LOAD_IR = """
define i32 @julia_volatile_load(ptr %p) {
top:
  %v = load volatile i32, ptr %p, align 4
  ret i32 %v
}
"""

const ATOMIC_STORE_IR = """
define i32 @julia_atomic_store(ptr %p, i32 %v) {
top:
  store atomic i32 %v, ptr %p unordered, align 4
  ret i32 0
}
"""

const VOLATILE_STORE_IR = """
define i32 @julia_volatile_store(ptr %p, i32 %v) {
top:
  store volatile i32 %v, ptr %p, align 4
  ret i32 0
}
"""

@testset "Bennett-4mmt atomic/volatile load/store fail-loud" begin

    mktempdir() do dir
        for (name, ir, fname, op_kw) in [
            ("atomic_load",   ATOMIC_LOAD_IR,   "julia_atomic_load",    "load"),
            ("volatile_load", VOLATILE_LOAD_IR, "julia_volatile_load",  "load"),
            ("atomic_store",  ATOMIC_STORE_IR,  "julia_atomic_store",   "store"),
            ("volatile_store",VOLATILE_STORE_IR,"julia_volatile_store", "store"),
        ]
            path = joinpath(dir, "$(name).ll")
            write(path, ir)

            try
                extract_parsed_ir_from_ll(path; entry_function=fname)
                @test false  # must raise
            catch e
                msg = sprint(showerror, e)
                # Post-fix message must cite atomic or volatile + load/store.
                @test occursin("atomic", lowercase(msg)) ||
                      occursin("volatile", lowercase(msg))
                @test occursin(op_kw, lowercase(msg))
            end
        end
    end
end
