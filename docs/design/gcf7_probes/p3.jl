# Counterexample probe v2: variants whose downstream access is word-coherent.
import Bennett
using InteractiveUtils
struct S2; a::Int; b::Int; end
struct W1; a::Int; end
const R  = Ref(S2(3,4))
const RW = Ref(W1(42))
const RI = Ref(42)
const T1 = Ref((77,))
h1(x::Int) = R[].a + x
h2(x::Int) = RW[].a + x
h3(x::Int) = RI[] + x
h4(x::Int) = T1[][1] + x
h5(x::Int) = (s = R[]; x > 0 ? s.a : s.b)

const FS = (("h1", h1), ("h2", h2), ("h3", h3), ("h4", h4), ("h5", h5))
for (nm, f) in FS
    println("===== ", nm, "  oracle f(10) = ", f(10))
    s = sprint(io->code_llvm(io, f, Tuple{Int}; debuginfo=:none, optimize=false))
    for l in split(s, '\n')
        (occursin("memcpy", l) || occursin("jl_global", l)) && println("   IR| ", l)
    end
    try
        set = Bennett.extract_parsed_ir_set_from_julia(f, Tuple{Int}; ptr_cells=true)
        println("EXTRACTED: ", length(set), " function(s)")
        pir = first(set).second
        for (k, v) in pir.globals
            println("  global ", k, " => ", v)
        end
        for b in pir.blocks, i in b.instructions
            println("   ", i)
        end
    catch e
        e isa InterruptException && rethrow()
        msg = sprint(showerror, e)
        println("REJECTED: ", first(msg, 700))
    end
end
