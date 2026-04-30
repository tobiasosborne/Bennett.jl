# Bennett-vdlg / U40: lower.jl was a 3,172-LOC monolith — split along its
# existing `# ---- section ----` headers into the files below. Loading
# order matches the original textual order so that all parse-time
# references (struct definitions, const dispatch tables) resolve in the
# same order they did pre-split. Late-binding function references
# between files (e.g. `_lower_inst!` dispatchers in types.jl that call
# `lower_phi!` / `lower_binop!` defined later) are unaffected by the
# split since Julia resolves them at call time.

include("lowering/types.jl")      # GateGroup / LoweringResult / LoweringCtx + _lower_inst! dispatch
include("lowering/operand.jl")    # resolve! / _ssa_operands / compute_ssa_liveness
include("lowering/driver.jl")     # lower() / _fold_constants / lower_block_insts!
include("lowering/cfg.jl")        # topo sort / back edges / loop unrolling
include("lowering/phi.jl")        # path-predicate computation + phi resolution
include("lowering/arith.jl")      # binop dispatch + bitwise + shifts + icmp + select + cast
include("lowering/aggregate.jl")  # divrem + ptr_offset + var_gep + load + extract/insertvalue
include("lowering/call.jl")       # function call inlining (callee dispatch)
include("lowering/memory.jl")     # T1b.3 reversible memory: alloca + store + MUX-EXCH dispatch
