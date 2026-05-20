#!/usr/bin/env julia
"""
BC.T5 — Head-to-head Pareto-front benchmark of the persistent-map
dispatcher implementations (Bennett-ktt8 / T5-P7a).

Sweeps the four wired `persistent_impl` arms against a parameterised
build-then-lookup workload and records, per cell:

    gates (total), ancilla count, Toffoli count, Toffoli depth,
    verify_reversibility pass/fail, compile wall-clock seconds.

Output: a JSONL results artifact (one line per cell) plus a Markdown
table printed to stdout, with a per-(W,depth) winner and a recommended
default impl.

────────────────────────────────────────────────────────────────────────
SCOPE NOTES (current reality as of 2026-05-20 — the original 2026-04-17
bead text is stale; see Bennett-ktt8 description for the correction):

  * FOUR persistent_impl arms are wired: :linear_scan, :okasaki, :hamt,
    :cf  (Bennett-z2dj / 6883 / d746 / qi6c, all closed). All four are
    resolved in `_resolve_persistent_impl` in src/lowering/memory.jl.

  * ONLY hashcons=:none is wired. hashcons=:naive and :feistel are NYI
    and THROW ArgumentError at `validate_persistent_config`. So the
    hashcons axis collapses to a SINGLE state today. The :naive/:feistel
    cells of the original 3×3×W×depth grid are future work — tracked as
    Bennett-z2dj follow-ups. This benchmark fixes hashcons = :none.

  * WIDTH AXIS IS NOT SUPPORTED. Every wired `*_pmap_set/get` callee is
    hard-typed to K = V = Int8 (W = 8) — see e.g.
    `src/persistent/linear_scan.jl:47` (`k::Int8, v::Int8`). There is no
    Int16/Int32/Int64 persistent-map callee, so the bead's W ∈ {16,32,64}
    axis is not reachable through the wired dispatcher. This benchmark
    runs W = 8 only and FAILS LOUD (records an error cell) for any wider
    W requested — see `_compile_cell`. A separate bead is needed to add
    wide-W persistent callees before the W axis can be benchmarked.

  * HAMT COLLISION CAVEAT (Bennett-2xws, open bug). The HAMT impl is a
    single-level node — keys congruent mod 32 collide with silent
    latest-write-wins. The HAMT demo therefore draws collision-free keys
    (distinct low-5-bits) via `_distinct_hamt_keys`, mirroring
    `test/test_6883_hamt_dispatch.jl`. linear_scan / okasaki / cf are
    collision-free and use plain sequential keys.

  * CAPACITY CAPS. linear_scan / okasaki / cf cap at max_n = 4 stored
    pairs; hamt at max_n = 8. The "depth" axis is the NUMBER OF set()
    calls in the build sequence — for depth > capacity the structures
    saturate (capacity-clamped / latest-write-wins), but each set() call
    still lowers to its own gate block, so circuit cost grows ~linearly
    in depth regardless. The oracle (`_cell_oracle`) models exactly the
    same saturating semantics so verify still has a faithful reference.
────────────────────────────────────────────────────────────────────────

USAGE

  # Full (parameterised) sweep — may be intractable at large W·depth:
  julia --project=. benchmark/bc_t5_head_to_head.jl

  # Reduced sweep (recommended for a first run / scaffolding validation):
  julia --project=. benchmark/bc_t5_head_to_head.jl --reduced

  # Single cell (subprocess-isolated; an OOM kills only this process):
  julia --project=. benchmark/bc_t5_head_to_head.jl --cell <impl> <W> <depth> [results.jsonl]

The driver intentionally runs cells IN-PROCESS and serially. For a heavy
full sweep, prefer invoking --cell per (impl,W,depth) from an external
serial loop so each cell gets a fresh process.
"""

using Bennett
using Dates
using Printf

# ════════════════════════════════════════════════════════════════════════
# Sweep parameters
# ════════════════════════════════════════════════════════════════════════

const IMPLS = (:linear_scan, :okasaki, :hamt, :cf)

# Full sweep grid (per the corrected bead scope). W is fixed at 8 because
# no wide-W persistent callee exists; the wider entries are kept here only
# so the file is *parameterised* for the full sweep — they will produce
# explicit error cells until wide-W callees land.
const FULL_WIDTHS = (8, 16, 32, 64)
const FULL_DEPTHS = (3, 8, 32, 128)

# Reduced sweep for scaffolding validation: W=8, shallow depths.
const REDUCED_WIDTHS = (8,)
const REDUCED_DEPTHS = (3, 8)

const DEFAULT_RESULTS = joinpath(@__DIR__, "bc_t5_head_to_head_results.jsonl")

# ════════════════════════════════════════════════════════════════════════
# Demo-function factory
# ════════════════════════════════════════════════════════════════════════
#
# For a given (impl, depth) we build a top-level closure-free demo:
#
#     f(k1,v1, k2,v2, ..., kD,vD, lookup) ->
#         s = <impl>_pmap_new()
#         s = <impl>_pmap_set(s, k1, v1)
#         ... (D set calls) ...
#         return <impl>_pmap_get(s, lookup)
#
# Top-level (not closure) is required so Bennett's IR extractor threads the
# state through the registered callees — see the header of
# test/test_t5_p6_persistent_dispatch.jl.
#
# WORLD-AGE NOTE: the demos MUST be `@eval`'d at PARSE TIME (top level),
# not inside `main()`. `reversible_compile` does method-table lookup
# (`which`) on the demo; a method defined inside the same dynamic call
# that later invokes `reversible_compile` is in a newer world age and is
# invisible to that lookup ("has no method for arg_types"). Generating
# every demo up front — before `main()` runs — sidesteps this.

# Per-impl pmap callee symbols (all in the Bennett module's namespace).
function _pmap_callees(impl::Symbol)
    impl === :linear_scan && return (:linear_scan_pmap_new, :linear_scan_pmap_set, :linear_scan_pmap_get)
    impl === :okasaki     && return (:okasaki_pmap_new,     :okasaki_pmap_set,     :okasaki_pmap_get)
    impl === :hamt        && return (:hamt_pmap_new,        :hamt_pmap_set,        :hamt_pmap_get)
    impl === :cf          && return (:cf_pmap_new,          :cf_pmap_set,          :cf_pmap_get)
    error("bc_t5_head_to_head: unknown persistent_impl :$impl (wired: $(IMPLS))")
end

_demo_name(impl::Symbol, depth::Int) = Symbol("_bct5_demo_", impl, "_d", depth)

# Build the `function` Expr for one (impl, depth) demo.
function _demo_expr(impl::Symbol, depth::Int)
    depth >= 1 || error("bc_t5_head_to_head: depth must be >= 1, got $depth")
    (newc, setc, getc) = _pmap_callees(impl)
    fname = _demo_name(impl, depth)
    sig = Any[fname]
    for i in 1:depth
        push!(sig, :($(Symbol("k", i))::Int8))
        push!(sig, :($(Symbol("v", i))::Int8))
    end
    push!(sig, :(lookup::Int8))
    body = Expr(:block)
    push!(body.args, :(s = Bennett.$(newc)()))
    for i in 1:depth
        push!(body.args, :(s = Bennett.$(setc)(s, $(Symbol("k", i)), $(Symbol("v", i)))))
    end
    push!(body.args, :(return Bennett.$(getc)(s, lookup)::Int8))
    return Expr(:function, Expr(:call, sig...), body)
end

# All (impl, depth) combinations needed across BOTH the full and reduced
# sweeps. Pre-generate every demo at parse time. If invoked in `--cell`
# mode with a one-off depth, that depth is folded in here too — so the
# demo exists before `main()` runs (world-age requirement).
const _ALL_DEPTHS = let base = vcat(collect(FULL_DEPTHS), collect(REDUCED_DEPTHS))
    if length(ARGS) >= 4 && ARGS[1] == "--cell"
        push!(base, parse(Int, ARGS[4]))
    end
    sort(unique(base))
end
for impl in IMPLS, depth in _ALL_DEPTHS
    # :hamt caps at 32 distinct 5-bit slots — skip deeper hamt demos.
    impl === :hamt && depth > 32 && continue
    @eval $(_demo_expr(impl, depth))
end

function _get_demo(impl::Symbol, depth::Int)
    name = _demo_name(impl, depth)
    isdefined(@__MODULE__, name) ||
        error("bc_t5_head_to_head: demo $name not pre-generated " *
              "(impl=$impl depth=$depth — add depth to FULL_DEPTHS/REDUCED_DEPTHS)")
    return getfield(@__MODULE__, name)
end

# ════════════════════════════════════════════════════════════════════════
# Oracle — pure-Julia reference matching the wired impl semantics
# ════════════════════════════════════════════════════════════════════════
#
# Calls the *actual* pure-Julia pmap callees (same ones the compiled
# circuit lowers) so the reference faithfully models capacity saturation /
# latest-write-wins, not an idealised Dict.

function _cell_oracle(impl::Symbol, kv::Vector{NTuple{2,Int8}}, lookup::Int8)::Int8
    (newc, setc, getc) = _pmap_callees(impl)
    new_fn = getfield(Bennett, newc)
    set_fn = getfield(Bennett, setc)
    get_fn = getfield(Bennett, getc)
    s = new_fn()
    for (k, v) in kv
        s = set_fn(s, k, v)
    end
    return get_fn(s, lookup)
end

# ════════════════════════════════════════════════════════════════════════
# Key generation
# ════════════════════════════════════════════════════════════════════════
#
# HAMT needs collision-free keys (distinct low-5-bits). The other three are
# collision-free for any distinct keys. We generate `depth` DISTINCT Int8
# keys deterministically; for HAMT we additionally require distinct 5-bit
# slots, which caps usable depth at 32 (only 32 distinct slots exist).

_hamt_slot(k::Int8) = Int(reinterpret(UInt8, k)) & 0x1F

"""
    _gen_keys(impl, depth) -> Vector{Int8}

Deterministic distinct keys for the build sequence. For :hamt the keys
also occupy distinct 5-bit HAMT slots. Throws if depth exceeds what is
representable (depth > 256 for any impl; depth > 32 for :hamt).
"""
function _gen_keys(impl::Symbol, depth::Int)
    depth <= 256 || error("bc_t5_head_to_head: depth=$depth exceeds Int8 key space (256)")
    if impl === :hamt
        depth <= 32 || error("bc_t5_head_to_head: :hamt depth=$depth exceeds 32 distinct 5-bit slots")
        keys = Int8[]
        used = Set{Int}()
        k = Int8(1)
        while length(keys) < depth
            sl = _hamt_slot(k)
            if !(sl in used)
                push!(keys, k); push!(used, sl)
            end
            k = k == Int8(127) ? Int8(-128) : k + Int8(1)
        end
        return keys
    else
        # Distinct keys: 1,2,3,... wrapping through the Int8 range.
        keys = Int8[]
        k = Int8(1)
        for _ in 1:depth
            push!(keys, k)
            k = k == Int8(127) ? Int8(-128) : k + Int8(1)
        end
        return keys
    end
end

# Deterministic values — derived from the key so the oracle is reproducible.
_val_for(k::Int8) = Int8((Int(reinterpret(UInt8, k)) * 7 + 3) & 0x7F)

# ════════════════════════════════════════════════════════════════════════
# Cell measurement
# ════════════════════════════════════════════════════════════════════════

struct CellResult
    impl::Symbol
    W::Int
    depth::Int
    ok::Bool                 # compiled + verified + oracle-matched
    gates_total::Int
    not_gates::Int
    cnot_gates::Int
    toffoli::Int
    toffoli_depth::Int
    ancillae::Int
    wires::Int
    verified::Bool
    compile_seconds::Float64
    error_msg::String        # "" on success
end

function vlog(msg::AbstractString)
    println("[", Dates.format(now(), "HH:MM:SS"), "] ", msg)
    flush(stdout)
end

"""
    _compile_cell(impl, W, depth; n_oracle_trials) -> CellResult

Compile + measure ONE (impl, W, depth) cell. FAIL LOUD: any compile /
verify failure is captured into the returned CellResult as `ok=false`
with the error text — the caller records it as an explicit error cell
rather than skipping it.
"""
function _compile_cell(impl::Symbol, W::Int, depth::Int; n_oracle_trials::Int=12)
    # Width gate: the wired persistent callees are Int8-only. Any W != 8 is
    # a hard, loud failure — not a silent skip.
    if W != 8
        return CellResult(impl, W, depth, false, 0, 0, 0, 0, 0, 0, 0, false, 0.0,
            "W=$W unsupported: all wired *_pmap_* callees are Int8-only (W=8). " *
            "Wide-W persistent callees are NYI — needs a follow-up bead.")
    end
    # :hamt is a single-level node — only 32 distinct 5-bit slots exist, so
    # a collision-free build sequence cannot exceed depth 32 (Bennett-2xws).
    if impl === :hamt && depth > 32
        return CellResult(impl, W, depth, false, 0, 0, 0, 0, 0, 0, 0, false, 0.0,
            "depth=$depth unsupported for :hamt: single-level node has only " *
            "32 distinct 5-bit slots; a collision-free build sequence caps at " *
            "depth 32 (Bennett-2xws).")
    end

    vlog("[cell] impl=$impl W=$W depth=$depth — building demo + compiling ...")
    local c
    t0 = time()
    try
        demo = _get_demo(impl, depth)
        argtypes = ntuple(_ -> Int8, 2 * depth + 1)
        c = reversible_compile(demo, argtypes...;
                               mem=:persistent, persistent_impl=impl, hashcons=:none,
                               optimize=false)
    catch e
        elapsed = time() - t0
        msg = sprint(showerror, e)
        vlog("[cell]   COMPILE FAILED in $(round(elapsed, digits=1))s: $(first(msg, 200))")
        return CellResult(impl, W, depth, false, 0, 0, 0, 0, 0, 0, 0, false,
                          round(elapsed, digits=3), msg)
    end
    elapsed = time() - t0
    vlog("[cell]   compiled in $(round(elapsed, digits=1))s — measuring ...")

    gc  = gate_count(c)
    td  = toffoli_depth(c)
    ac  = ancilla_count(c)
    nw  = c.n_wires

    # Reversibility — Bennett's correctness invariant (CLAUDE.md §4).
    verified = false
    try
        verified = verify_reversibility(c; n_tests=8)
    catch e
        msg = sprint(showerror, e)
        vlog("[cell]   verify_reversibility THREW: $(first(msg, 200))")
        return CellResult(impl, W, depth, false, gc.total, gc.NOT, gc.CNOT,
                          gc.Toffoli, td, ac, nw, false, round(elapsed, digits=3),
                          "verify_reversibility threw: $msg")
    end

    # Oracle check — exhaustive verification, not "runs without errors".
    keys = _gen_keys(impl, depth)
    vals = Int8[_val_for(k) for k in keys]
    kv   = NTuple{2,Int8}[(keys[i], vals[i]) for i in 1:depth]
    oracle_ok = true
    oracle_err = ""
    try
        # Deterministic corner cases: lookup the first key, the last key,
        # and a guaranteed-miss key.
        miss = Int8(-100)
        in(miss, keys) && (miss = Int8(-101))
        probes = Int8[keys[1], keys[end], miss]
        # Plus a small deterministic spread of stored keys.
        for i in 1:min(depth, n_oracle_trials)
            push!(probes, keys[((i * 13) % depth) + 1])
        end
        for lookup in probes
            args = Tuple(vcat(reduce(vcat, [[k, v] for (k, v) in kv]; init=Int8[]),
                              Int8[lookup]))
            expected = _cell_oracle(impl, kv, lookup)
            got = simulate(c, args)
            if got != expected
                oracle_ok = false
                oracle_err = "oracle mismatch: lookup=$lookup expected=$expected got=$got"
                break
            end
        end
    catch e
        oracle_ok = false
        oracle_err = "oracle/simulate threw: " * sprint(showerror, e)
    end

    if !oracle_ok
        vlog("[cell]   ORACLE FAILED: $(first(oracle_err, 200))")
    end
    ok = verified && oracle_ok
    vlog("[cell]   $(ok ? "GREEN" : "RED")  gates=$(gc.total) Toffoli=$(gc.Toffoli) " *
         "Tdepth=$td anc=$ac verified=$verified")

    return CellResult(impl, W, depth, ok, gc.total, gc.NOT, gc.CNOT, gc.Toffoli,
                      td, ac, nw, verified, round(elapsed, digits=3),
                      oracle_ok ? "" : oracle_err)
end

# ════════════════════════════════════════════════════════════════════════
# JSONL + Markdown output
# ════════════════════════════════════════════════════════════════════════

function _result_to_json(r::CellResult)
    esc(s) = replace(s, "\\" => "\\\\", "\"" => "\\\"", "\n" => " ")
    return string("{",
        "\"timestamp\":\"", now(), "\",",
        "\"impl\":\"", r.impl, "\",",
        "\"W\":", r.W, ",",
        "\"depth\":", r.depth, ",",
        "\"ok\":", r.ok, ",",
        "\"gates_total\":", r.gates_total, ",",
        "\"NOT\":", r.not_gates, ",",
        "\"CNOT\":", r.cnot_gates, ",",
        "\"Toffoli\":", r.toffoli, ",",
        "\"toffoli_depth\":", r.toffoli_depth, ",",
        "\"ancillae\":", r.ancillae, ",",
        "\"wires\":", r.wires, ",",
        "\"verified\":", r.verified, ",",
        "\"compile_seconds\":", r.compile_seconds, ",",
        "\"error\":\"", esc(r.error_msg), "\"}")
end

function _append_jsonl(path::AbstractString, r::CellResult)
    open(path, "a") do io
        println(io, _result_to_json(r))
        flush(io)
    end
end

function _print_markdown(results::Vector{CellResult}, widths, depths)
    println()
    println("## BC.T5 — persistent-map dispatcher head-to-head")
    println()
    println("hashcons fixed at `:none` (only wired state). W axis is 8 only ",
            "(`*_pmap_*` callees are Int8-typed).")
    println()
    println("| impl | W | depth | gates | NOT | CNOT | Toffoli | T-depth | ancillae | wires | verified | compile s | status |")
    println("|------|---:|------:|------:|----:|-----:|--------:|--------:|---------:|------:|:--------:|----------:|:------:|")
    for r in results
        status = r.ok ? "GREEN" : (isempty(r.error_msg) ? "RED" : "ERROR")
        gcell = r.ok ? string(r.gates_total) : "—"
        println("| ", r.impl, " | ", r.W, " | ", r.depth, " | ", gcell, " | ",
                r.not_gates, " | ", r.cnot_gates, " | ", r.toffoli, " | ",
                r.toffoli_depth, " | ", r.ancillae, " | ", r.wires, " | ",
                r.verified ? "✓" : "✗", " | ", r.compile_seconds, " | ", status, " |")
    end
    println()

    # Per-(W,depth) winner: lowest gate count among GREEN cells.
    println("### Winner per (W, depth) cell — lowest total gates (GREEN only)")
    println()
    println("| W | depth | winner | gates | runners-up |")
    println("|---:|------:|--------|------:|------------|")
    win_tally = Dict{Symbol,Int}()
    for W in widths, depth in depths
        cells = filter(r -> r.W == W && r.depth == depth && r.ok, results)
        if isempty(cells)
            println("| $W | $depth | — (no GREEN cell) | — | — |")
            continue
        end
        sort!(cells, by = r -> r.gates_total)
        win = cells[1]
        win_tally[win.impl] = get(win_tally, win.impl, 0) + 1
        runners = join(["$(c.impl):$(c.gates_total)" for c in cells[2:end]], ", ")
        println("| $W | $depth | $(win.impl) | $(win.gates_total) | $runners |")
    end
    println()

    if !isempty(win_tally)
        best = sort(collect(win_tally), by = p -> -p[2])
        println("### Recommended default")
        println()
        rec = best[1][1]
        println("Per-cell win tally: ",
                join(["$(k) → $(v)" for (k, v) in best], ", "), ".")
        println()
        println("**Recommended `persistent_impl` default: `:$rec`** ",
                "(won $(best[1][2]) of $(length(widths)*length(depths)) cells).")
        println()
        println("NOTE: this is over the GREEN cells measured in this run. ",
                "A reduced sweep is NOT authoritative for the full Pareto front — ",
                "re-run the full grid before feeding this into the T5-P6 dispatcher ",
                "default (Bennett-2uas / dispatcher-default follow-up).")
    end
    println()
end

# ════════════════════════════════════════════════════════════════════════
# Drivers
# ════════════════════════════════════════════════════════════════════════

"""
    run_sweep(widths, depths; results_path, impls) -> Vector{CellResult}

Compile every (impl, W, depth) cell SERIALLY, in-process. Appends a JSONL
line per cell as it completes so partial progress survives a crash.
"""
function run_sweep(widths, depths;
                   results_path::AbstractString = DEFAULT_RESULTS,
                   impls = IMPLS)
    vlog("[sweep] impls=$(collect(impls)) widths=$(collect(widths)) depths=$(collect(depths))")
    vlog("[sweep] results -> $results_path")
    results = CellResult[]
    for W in widths, depth in depths, impl in impls
        r = _compile_cell(impl, W, depth)
        push!(results, r)
        _append_jsonl(results_path, r)
    end
    return results
end

function _run_single_cell(impl_str, W_str, depth_str, results_path)
    impl  = Symbol(impl_str)
    impl in IMPLS || error("bc_t5_head_to_head: --cell impl must be one of $(IMPLS)")
    W     = parse(Int, W_str)
    depth = parse(Int, depth_str)
    r = _compile_cell(impl, W, depth)
    _append_jsonl(results_path, r)
    _print_markdown([r], (W,), (depth,))
    return r
end

function main()
    if !isempty(ARGS) && ARGS[1] == "--cell"
        length(ARGS) >= 4 ||
            error("usage: --cell <impl> <W> <depth> [results.jsonl]")
        results_path = length(ARGS) >= 5 ? ARGS[5] : DEFAULT_RESULTS
        _run_single_cell(ARGS[2], ARGS[3], ARGS[4], results_path)
        return
    end

    reduced = !isempty(ARGS) && ARGS[1] == "--reduced"
    widths  = reduced ? REDUCED_WIDTHS : FULL_WIDTHS
    depths  = reduced ? REDUCED_DEPTHS : FULL_DEPTHS
    vlog("[main] $(reduced ? "REDUCED" : "FULL") sweep")

    # Truncate / start fresh results file for a full driver run.
    results_path = DEFAULT_RESULTS
    open(results_path, "w") do io end

    results = run_sweep(widths, depths; results_path = results_path)
    _print_markdown(results, widths, depths)
    vlog("[main] done — $(length(results)) cells, results in $results_path")
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
