# ---- Single-cell measurement script ----
#
# Run as:  julia --project=. benchmark/sweep_cell.jl <impl> <max_n> [<results_path>]
# Example: julia --project=. benchmark/sweep_cell.jl linear_scan 16 /tmp/results.jsonl
#
# Compiles ONE (impl, max_n) cell, prints verbose flushed status, appends a
# JSON line to the results file (default: benchmark/sweep_persistent_results.jsonl).
# Designed for subprocess isolation: an OOM kills only this process, the
# parent sweep continues.

using Dates
using Printf

const ARG_IMPL    = ARGS[1]
const ARG_MAX_N   = parse(Int, ARGS[2])
const ARG_RESULTS = length(ARGS) >= 3 ? ARGS[3] :
                    joinpath(@__DIR__, "sweep_persistent_results.jsonl")

# Verbose flush helper — every line hits stdout with a flush so partial
# progress survives a kill (WSL OOM, timeout, etc.).
function vlog(msg::String)
    println("[", Dates.format(now(), "yyyy-mm-dd HH:MM:SS"), "] ", msg)
    flush(stdout)
end

function rss_mb()::Int
    try
        for line in eachline("/proc/self/status")
            if startswith(line, "VmRSS:")
                return parse(Int, split(line)[2]) ÷ 1024
            end
        end
    catch
    end
    return -1
end

vlog("[start] impl=$ARG_IMPL max_n=$ARG_MAX_N pid=$(getpid()) rss=$(rss_mb())MB")
vlog("[load]  loading Bennett + sweep_persistent_impls_gen.jl")
flush(stdout)

using Bennett
# Bennett-4nvl / U212: sweep_persistent_impls_gen.jl is .gitignore'd
# (it's a 1.2MB auto-generated artifact). Auto-regenerate if missing
# so the workflow stays single-command after a fresh checkout.
const _GEN_PATH = joinpath(@__DIR__, "sweep_persistent_impls_gen.jl")
if !isfile(_GEN_PATH)
    vlog("[gen]   sweep_persistent_impls_gen.jl missing — regenerating ...")
    include(joinpath(@__DIR__, "codegen_sweep_impls.jl"))
end
include(_GEN_PATH)

vlog("[load]  done. rss=$(rss_mb())MB")

# Resolve demo function by name — generated functions are top-level, so
# reachable via @__MODULE__ (Main when run as a script).
demo_name = if ARG_IMPL == "linear_scan"
    Symbol("ls_demo_$(ARG_MAX_N)")
elseif ARG_IMPL == "cf"
    Symbol("cf_demo_$(ARG_MAX_N)")
else
    error("sweep_cell.jl: unknown impl '$ARG_IMPL' (supported: linear_scan, cf)")
end

if !isdefined(@__MODULE__, demo_name)
    error("sweep_cell.jl: demo function $demo_name not generated — re-run codegen with max_n=$ARG_MAX_N in the list")
end
demo_fn = getfield(@__MODULE__, demo_name)

vlog("[demo]  resolved demo function: $demo_name")
vlog("[compile] starting reversible_compile (optimize=true) ...")

# NOTE: optimize=false per CLAUDE.md §5 ("LLVM IR is not stable; always
# use optimize=false for predictable IR") — and required at scale because
# Julia auto-vectorises sequential i8 ops into <N x i8> SIMD that
# ir_extract.jl does not yet handle (filed Bennett-cc0.7).
t0 = time()
c = reversible_compile(demo_fn, Int8, Int8; optimize=false)
elapsed = time() - t0

vlog("[compile] done in $(round(elapsed, digits=2)) s. rss=$(rss_mb())MB")

# Measurements
gc = gate_count(c)
nw = c.n_wires

vlog("[result] gates_total=$(gc.total) Toffoli=$(gc.Toffoli) NOT=$(gc.NOT) CNOT=$(gc.CNOT) wires=$nw")

# Verify reversibility (small n_tests so we don't OOM on simulation)
vlog("[verify] running verify_reversibility(c; n_tests=2) ...")
verified = verify_reversibility(c; n_tests=2)
vlog("[verify] $(verified ? "GREEN" : "RED")")

# Append JSONL line — survives any subsequent crash in this process
result = """{"timestamp":"$(now())","impl":"$ARG_IMPL","max_n":$ARG_MAX_N,"gates_total":$(gc.total),"NOT":$(gc.NOT),"CNOT":$(gc.CNOT),"Toffoli":$(gc.Toffoli),"wires":$nw,"compile_seconds":$(round(elapsed, digits=3)),"rss_mb":$(rss_mb()),"verified":$verified}"""

open(ARG_RESULTS, "a") do io
    println(io, result)
    flush(io)
end

vlog("[done]   appended to $ARG_RESULTS")
