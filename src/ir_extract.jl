# Bennett-x3jc / U116: ir_extract.jl was a 2,946-LOC monolith — split
# along its existing `# ---- section ----` headers into the files below.
# Loading order matches the original textual order so that all
# parse-time references (struct definitions, const dispatch tables)
# resolve in the same order they did pre-split.

include("extract/entry.jl")         # extract_ir / extract_parsed_ir / from_ll / from_bc / _run_passes!
include("extract/callees.jl")       # known callee registry + cache + _LLVMRef + _auto_name
include("extract/errors.jl")        # _ir_error / _ir_error_msg + _LLVM_OPCODE_NAMES
include("extract/sret.jl")          # sret detection + writes collection + synthesis (Bennett-dv1z)
include("extract/module_walk.jl")   # _find_entry_function / _module_to_parsed_ir / _extract_const_globals / _expand_switches
include("extract/instructions.jl")  # _handle_intrinsic + _convert_instruction (the IR → IRInst dispatcher)
include("extract/heap.jl")          # Bennett-gps7 / M1: GC/heap-skeleton recogniser (_detect_gc_preamble!)
include("extract/constexpr.jl")     # cc0.3 GlobalAlias + cc0.4 ConstantExpr operand folding
include("extract/vectors.jl")       # cc0.7 vector SSA scalarisation + _convert_vector_instruction
include("extract/helpers.jl")       # _get_deref_bytes / _operand / _iwidth / _type_width + _OPCODE_MAP / _PRED_MAP
