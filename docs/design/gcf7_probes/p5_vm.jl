# Store-forward (canon) shape with a NON-EMPTY jl_global: the global pointer is
# boxed into a fresh gc_alloc_obj Ref, reloaded, then memcpy'd from.
import Bennett, BennettVM
using InteractiveUtils
const BV = BennettVM
struct S2; a::Int; b::Int; end
struct W1; a::Int; end
const RR = Ref(S2(3,4))
const RW = Ref(W1(42))
k1(x::Int) = (b = Ref(RW); b[][].a + x)
k2(x::Int) = (b = Ref(RR); b[][].a + x)
k3(x::Int) = (b = Base.RefValue{Any}(RW); (b[]::Base.RefValue{W1})[].a + x)

function runvm(f, x)
    set = Bennett.extract_parsed_ir_set_from_julia(f, Tuple{Int}; ptr_cells=true)
    prog = BV.lower_vm(set; entry = first(set).first)
    entry_pir = first(set).second
    inputs = Dict(n => Int64(v) for ((n, _w), v) in zip(entry_pir.args, (x,)))
    mc = BV.compute_must_cache(prog)
    rs = BV.initial_state(prog, inputs)
    init = deepcopy(rs.current)
    BV.run!(rs, prog; max_steps = 100_000, checkpoint_interval = 8, must_cache_set = mc)
    @assert BV.is_halted(rs)
    entry_vm = BV._vm_funcname(first(set).first)
    ret = only(b.exit.returns for b in prog.blocks
               if b.exit isa BV.EndInstruction && b.exit.label === entry_vm &&
                  !isempty(b.exit.returns))[1]
    r = BV.result(rs)[ret]
    BV.unrun!(rs, prog; max_unsteps = 200_000)
    return r, rs.current == init
end

for (nm, f) in (("k1", k1), ("k2", k2), ("k3", k3))
    s = sprint(io->code_llvm(io, f, Tuple{Int}; debuginfo=:none, optimize=false))
    println("----- ", nm)
    for l in split(s, '\n')
        (occursin("memcpy", l) || occursin("jl_global", l) || occursin("gc_alloc", l) ||
         occursin("store", l) || occursin("load ptr", l)) && println("   IR| ", l)
    end
    for x in (0, 10)
        try
            r, rev = runvm(f, x)
            println(rpad(nm, 6), " x=", lpad(x, 3), "  oracle=", lpad(f(x), 4),
                    "  BVM=", lpad(r, 4), "  reversed=", rev,
                    r == f(x) ? "  ok" : "  *** MISMATCH ***")
        catch e
            e isa InterruptException && rethrow()
            println(rpad(nm, 6), " x=", x, "  ERROR: ", first(sprint(showerror, e), 500))
        end
    end
end
