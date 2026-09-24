# Counterexample probe: a NON-EMPTY Julia constant object reached through a
# `jl_global#N` load, memcpy'd into an alloca. Is it admitted? What value?
import Bennett
struct S2; a::Int; b::Int; end
const R = Ref(S2(3,4))
const T = Ref((5,6))
g1(x::Int) = (s = R[]; s.a + s.b + x)
g3(x::Int) = (t = T[]; t[1] + t[2] + x)

for (nm, f) in (("g1", g1), ("g3", g3))
    println("===== ", nm, "  oracle f(10) = ", f(10))
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
        println("REJECTED: ", first(msg, 900))
    end
end
