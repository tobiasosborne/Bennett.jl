# Execute the 5viz-admitted counterexamples on BennettVM and compare to oracle.
import Bennett, BennettVM
const BV = BennettVM
struct S2; a::Int; b::Int; end
struct W1; a::Int; end
const R  = Ref(S2(3,4))
const RW = Ref(W1(42))
const RI = Ref(42)
const T1 = Ref((77,))
h1(x::Int) = R[].a + x
h2(x::Int) = RW[].a + x
h3(x::Int) = RI[] + x          # PRE-EXISTING direct-load path (not 5viz) — control
h4(x::Int) = T1[][1] + x

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

for (nm, f) in (("h1", h1), ("h2", h2), ("h3 (pre-existing control)", h3), ("h4", h4))
    for x in (0, 10, -5)
        try
            r, rev = runvm(f, x)
            println(rpad(nm, 28), " x=", lpad(x, 3), "  oracle=", lpad(f(x), 4),
                    "  BVM=", lpad(r, 4), "  reversed=", rev,
                    r == f(x) ? "  ok" : "  *** MISMATCH ***")
        catch e
            e isa InterruptException && rethrow()
            println(rpad(nm, 28), " x=", x, "  ERROR: ", first(sprint(showerror, e), 300))
        end
    end
end
