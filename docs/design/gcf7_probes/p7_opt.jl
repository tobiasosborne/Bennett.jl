# t9rh interaction: do the 5viz counterexamples take the 5viz arm at optimize=true?
import Bennett
struct W1; a::Int; end
const RW = Ref(W1(42))
h2(x::Int) = RW[].a + x
for opt in (false, true)
    try
        set = Bennett.extract_parsed_ir_set_from_julia(h2, Tuple{Int}; ptr_cells=true, optimize=opt)
        pir = first(set).second
        println("optimize=$opt EXTRACTED: ", [i for b in pir.blocks for i in b.instructions])
    catch e
        e isa InterruptException && rethrow()
        println("optimize=$opt REJECTED: ", first(sprint(showerror, e), 300))
    end
end
