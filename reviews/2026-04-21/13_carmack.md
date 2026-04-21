# Bennett.jl — Carmack Code Review

**Date:** 2026-04-21
**Scope:** full tree under `/home/tobiasosborne/Projects/Bennett.jl`,
with emphasis on the compiler core (`ir_extract.jl`, `lower.jl`,
`bennett_transform.jl`, `simulator.jl`, the softfloat library,
and the end-to-end pipeline).
**Ground truth:** measurements from a warm Julia process on the checked-out
commit, not code reading alone.

---

## Top-level take

This is a compiler that works. I compiled `x -> x + Int8(1)` and got 100
gates; compiled `x^2 + 3x + 1` on Int8, ran it over representative inputs
with `simulate`, checked it against the Julia oracle, and everything agreed.
`verify_reversibility` passes on the circuits I poked at. The test suite
is large (627 testsets, ~1,298 `@test` invocations, 100 test files, ~11.3K
LOC of tests) and it all passes. That's the first threshold most projects
of this shape fail, and Bennett.jl crosses it cleanly. The Bennett
construction itself — `src/bennett_transform.jl` — remains the 28 lines of
bookkeeping it needs to be, and the `sizehint!` at line 38 tells me
somebody was paying attention.

What I'm worried about is everything that accumulated around that clean
core. `src/lower.jl` is now 2,662 lines, `src/ir_extract.jl` is 2,394
lines, and they carry history in exactly the way large files do — three
different `LoweringCtx` constructor overloads (`src/lower.jl:86–119`),
three `LoweringResult` constructors for bit-compat with earlier call
sites, a sentinel `Symbol("")` threaded through store/alloca code to
distinguish "this is the entry block" from "caller didn't tell us", and
two parallel phi resolvers (`resolve_phi_predicated!` and the legacy
`resolve_phi_muxes!`) sitting next to each other in the same file. The
compiler works, but every new change lands on top of that sediment, which
is why CLAUDE.md's 3+1 agent rule for core changes exists. That rule is a
symptom: the reason you need three agents to touch phi resolution is that
the code is frightening to touch. The fix is simplification, not more
agents.

The other thing that bothers me is the feedback-loop story. A cold
`julia --project -e 'using Bennett; reversible_compile(x -> x + Int8(1), Int8)'`
takes **15.6 s wall clock** — 10.6 s of which is the first-call compilation
of the compiler itself; subsequent compiles in the same process are
**~1.3 ms**. The full `Pkg.test()` run takes **4m 06s**, not the "about 90
seconds" the README claims. There is no precompile workload
(`grep -r PrecompileTools` and `@compile_workload` both come up empty in
`src/`), no `--dump-ir` / `--dump-gates` / `@verbose` instrumentation
(zero matches for `dump_ir|dump_gates|verbose|VERBOSE` under `src/`), no
caching of re-extracted callees (see below). A developer who lives in a
REPL is fine. A developer who edits `src/lower.jl` and wants to watch one
failing test is paying the 10-second TTFX tax every attempt. That's the
difference between iterating 60 times an hour and iterating 6 times an
hour, and it shows up in what the code becomes.

---

## Notable strengths

**1. The data flow is cleanly defined.** `extract_parsed_ir → lower → bennett → simulate`,
with the in-between representations being values with types
(`ParsedIR`, `LoweringResult`, `ReversibleCircuit`) rather than shared
mutable state. This is the shape Enzyme gets right and a lot of compilers
get wrong, and Bennett.jl is on the right side of that line. The
`ParsedIR` getproperty trick in `src/ir_types.jl:212` for caching
`instructions` is a mild wart but the overall structure is the one I'd
defend.

**2. The soft-float library is real work.** `src/softfloat/fadd.jl` is
137 lines of fully branchless IEEE 754 addition, with the full zoo of
special cases (NaN/Inf/zero/subnormal/overflow/exact-cancel) selected by
a priority chain of `ifelse` at the bottom of the function. `soft_fadd`
is bit-exact with hardware over 10,000 random inputs and an edge-case
battery (`test/test_softfloat.jl:89–106`), and the "branchless to avoid
false-path sensitization in the MUX lowering" constraint is documented in
the function's own comment. This is the right way to write an IEEE 754
implementation that has to reversibilise cleanly: one datapath, all paths
computed, conditions become MUX selectors. The five-ops f64 polynomial
compiles in ~111 ms warm and the circuit agrees with the hardware answer
to the last bit.

**3. The dispatcher for memory strategies.** `_pick_alloca_strategy` in
`src/lower.jl:2084–2107` is exactly the right shape: a small decision
function that picks between `:shadow`, `:mux_exch_{N}x{W}`, or
`:shadow_checkpoint` based on the static shape of the alloca. The
strategies that sit under it (shadow = 3W CNOT / W CNOT, QROM =
4(L-1) Toffoli, Feistel = 8W Toffoli) all have formulas and baselines
you can check by eye. The README's "297× smaller" and "134× smaller"
numbers are real — they fall out of O(W) vs O(NW) formulas, not from
benchmarking noise.

**4. Gate-count regression tests are load-bearing.** `test/test_gate_count_regression.jl`
pins concrete totals (100/204/412/828) plus the `2× + 4` invariant for
width-doubling, plus `toffoli_depth` baselines. This is the correct use
of gate counts — they're cheap enough to run on every change and rich
enough to catch both algorithmic regressions and subtle wire-allocation
changes. The tracked `GateGroup` structure in `src/lower.jl:7–19` also
gives downstream pebbling / EAGER passes a clean SSA-instruction-to-gate-range
mapping without tagging gates individually.

**5. Path-predicate phi resolution is the right fix.** The shift from
`resolve_phi_muxes!` (reachability-based) to `resolve_phi_predicated!`
(edge-predicates ANDed from `block_pred`) in `src/lower.jl:905` is the
principled answer to the false-path sensitization class of bugs that
CLAUDE.md §"Phi Resolution" rightly flags as the most dangerous part of
the compiler. The entry predicate is a single wire pre-initialised to 1
via `NOTGate(pw[1])` so the single-origin fast path stays byte-identical.
That's how you bolt correctness onto a hot path without paying for it.

---

## Structural concerns

**1. `lower.jl` has outgrown its filename.** 2,662 lines in one file with
90 functions (`^function ` grep). The phi resolver, the MUX lowering, the
memory dispatcher, the call inliner, the loop unroller, `_fold_constants`
(which is doing a dataflow pass), and strategy selection all live
together. At this size a single grep for `ptr_provenance` hits 30+ lines
across a dozen functions and the cognitive cost of a change is dominated
by the time it takes to be sure the change doesn't break an invariant
held four functions away. The mechanical split is clear:
`lower_memory.jl` (alloca/store/load/GEP/ptr-provenance, ~600 lines),
`lower_callsite.jl` (IRCall + argument widths + callee inlining, ~150),
`lower_phi.jl` (the predicated resolver + legacy one + block_pred +
edge_predicate, ~300), `lower_loop.jl` (`lower_loop!` + topo sort + back-edge
detection, ~200), and `lower.jl` proper for the dispatch table and the
simple binops. This isn't cosmetic; it buys reviewers a fighting chance.

**2. Callee IR is re-extracted on every reference, with no cache.**
`src/lower.jl:1935` calls `extract_parsed_ir(inst.callee, arg_types)`
inside `lower_call!`. Measured warm cost of
`extract_parsed_ir(soft_fadd, Tuple{UInt64,UInt64})` is ~21 ms per call.
A function that calls `soft_fadd` five times pays 100 ms for five
identical extractions; `f10(x) = ((...x+1.0)+2.0)+...+10.0` compiled in
368 ms warm and 10 of those milliseconds are the actual work — the other
200 ms is redundant LLVM roundtrips on the same bytes. A plain
`Dict{Tuple{Function, DataType}, ParsedIR}` cache in `Bennett` module
scope would close the gap, and since `register_callee!` already declares
the set of pre-approved callees, you can even precompute the cache at
module load time. This is the single cheapest performance win in the
compiler and it's also the cheapest iteration-speed win, because test
functions that exercise soft-float currently pay this tax in the test
loop.

**3. Assertion density is skewed toward `error()`, not `@assert`.** `grep
-c '@assert'` over `src/` returns 2, while `grep -c '^\s*error('` returns
121. Both do fail-loud, but `@assert` is disabled under `--check-bounds=no`
and `error()` isn't; the consequence is that all of the invariant checks
are on the hot path at runtime with full string formatting. The
shadow-memory primitive `emit_shadow_store_guarded!` validates wire-count
three ways with string interpolation on each call
(`src/shadow_memory.jl:101–103`). The same check gets emitted every time
that primitive is invoked across a 10,000-gate compile. For defensive
depth-1 invariants like "lengths match", `@assert` is the right tool —
it's free in release and keeps the "fail fast, fail loud" contract. Keep
`error()` for user-facing failures (unsupported opcode, wrong strategy
name); downgrade the internal length/shape checks.

**4. Three constructors for `LoweringCtx`, three for `LoweringResult`, and
a sentinel `Symbol("")` threading through `lower_store!` and `lower_alloca!`
to distinguish "entry block" from "direct caller didn't tell me".** This
is exactly the pattern a file develops when you add four sequential
features (M2a → M2b → M2c → M3a) and need to keep every test green at
each step. The sentinel-based branching in `_lower_store_via_shadow!`
(`src/lower.jl:2259`) is extra nerve-wracking because the behavior it
guards is semantic, not cosmetic — entry-block stores are unconditional
3W-CNOT, other-block stores are 3W-Toffoli-guarded, and confusing them is
a correctness bug. Converge on a single builder that always takes a
`block_pred::Vector{Int}` (use a literal `[_const_one_wire]` for the
entry case), delete the overloads, and mechanical-replace in the call
sites. This is one patch; the merge conflict risk is low because the
overloads are only used at call sites that already spell out the full
argument list. Do it in one session and don't touch anything else.

**5. The simulator is a bit-vector, gate-at-a-time interpreter.** `src/simulator.jl`:
`apply!(b::Vector{Bool}, g::NOTGate)` does `b[g.target] ⊻= true`. That's
correct, and for 100-gate circuits it runs in 0.2 ms, which is fine. But
for the 95k-gate `soft_fadd` circuit it's 180 µs per input, and
`verify_reversibility(; n_tests=100)` runs the gate list twice (forward +
reverse) × 100 trials = 200 × 95,000 = 19 M `apply!` calls. This is also
where EAGER / pebbling experiments will live. Three wins line up nicely:
(a) pack wires into `BitVector` or `UInt64` chunks — 64× throughput for
free on wide circuits; (b) batch gates of the same type (the circuit is
~90% CNOT, 10% Toffoli — `findall` once, then a straight loop beats
dispatch); (c) vectorise across **inputs** for verification, running N
simulations in parallel on an N-lane bitvec. These are classic bitslice
tricks and they pay for themselves the first time someone tries to
brute-force-verify a 16-bit circuit. None of this breaks the `simulate`
API; it's an internal rewrite of the hot loop.

**6. Return type of `simulate` is `Union{Int8,Int16,Int32,Int64,Tuple{Vararg{Int64}}}`.**
`@code_warntype` confirms. The cause is legitimate — output width depends
on circuit metadata, not the call site — but it means every downstream
consumer is boxed. For test code that runs `simulate(c, x)` in a loop
over all 256 Int8 inputs, boxing dominates. Fix: add a typed overload
`simulate(c::ReversibleCircuit, ::Type{T}, inputs...)::T` that asserts
the return width matches and narrows the inferred type; keep the dynamic
one for the REPL ergonomics. Same trick works for tuple returns.

**7. TTFX is a ten-second tax on iteration.** Cold `reversible_compile(x
-> x + Int8(1), Int8)` takes **15.6 s**; warm in the same process is
**1.3 ms**. The gap is 99.87% Julia compilation per `@time`. Bennett does
no precompilation — `grep -r PrecompileTools\|@compile_workload src/`
returns zero matches. A 50-line `@setup_workload` block that runs
`reversible_compile` once for each concrete argument-type tuple the test
suite uses would drop first-compile time to ~2 s and change the character
of the project's inner loop. This is the single highest-leverage
developer-experience win available and it is approximately four hours of
work.

**8. `_fold_constants` in `src/lower.jl:473–566` is a 94-line linear pass
that mixes three concerns — (a) known-wire propagation, (b) gate
simplification (Toffoli with one known-true control → CNOT), (c)
end-of-pass materialisation of residual 1-values as NOTGates. Each
concern deserves its own pass. As written, a bug in (b) can silently
drop a materialisation from (c) because they share the `known` dict by
mutation. The test `test_constant_fold.jl` exercises the happy path but
cannot catch that class of bug. Split into three passes each with its
own `before/after` invariant, or — since constant-folding is opt-in
(`fold_constants=true`) — rewrite on top of a proper worklist pass.

**9. No CI workflow.** `ls .github/workflows/` returns nothing. There is
no automated check that `Pkg.test()` passes on a clean machine with the
pinned `LLVM 9.4.6`. For a compiler whose IR walker is explicitly
documented as LLVM-version-sensitive (CLAUDE.md §5: "LLVM IR is not
stable"), this is a non-trivial risk: Julia 1.12 bumps LLVM
under you, the test suite starts to silently fail on some local machine,
and nobody knows for a week. A GitHub Actions workflow running `julia -e
'Pkg.test()'` on the pinned Julia version, on every PR and on push to
`main`, is a half-hour of work that catches the class of breakage that
`CLAUDE.md` is specifically worried about.

**10. Debuggability tooling is missing.** There is no `--dump-ir`,
no `--dump-gates`, no verbose flag. When a test fails with "Ancilla wire
47 not zero — Bennett construction bug" (`src/simulator.jl:32`) there is
no path from that error message to "which SSA instruction produced wire
47". The `GateGroup` structure is carrying that mapping but it isn't
exposed. A tiny `diagnose_nonzero(circuit, input)` that walks the
simulation, flags the first ancilla that goes wrong, and prints the
`GateGroup` (SSA name, gate range, input SSA vars) that produced that
wire would turn a 30-minute forensic into a 30-second lookup. The data
is already there.

---

## Specific bugs / suspected bugs

**Documented gate-count baselines are stale.** `CLAUDE.md` §6 asserts
"Key baselines: i8 addition = 86 gates, i16 = 174, i32 = 350, i64 = 702".
Measured today with default `add=:auto`: 98/202/410/826. With
`add=:ripple`: 86/174/350/702 — the CLAUDE.md numbers correspond to the
pre-auto-Cuccaro ripple strategy, which is no longer the default. The
regression test `test/test_gate_count_regression.jl:18–21` has been
updated to the current numbers (100/204/412/828 — the extra 2 is the
entry-block predicate NOT gate), so the tests and CLAUDE are disagreeing
with each other. Not a correctness bug, but CLAUDE.md is going to keep
sending new agents on wild-goose chases until it's corrected.

**Loop unrolling + soft-float interact badly.** A simple Julia loop
`for _ in 1:n; y = y + 1.0; end` compiled via `reversible_compile(f,
Float64; max_loop_iterations=32)` fails with "Undefined SSA variable"
from `resolve!` (`src/lower.jl:172`) inside `lower_loop!`
(`src/lower.jl:762`). Specifically, the loop-unroller doesn't appear to
handle soft-float `IRCall` instructions in the loop body — its inner
`if inst isa IRBinOp; lower_binop!(...) elseif inst isa IRICmp; ...`
cascade at `src/lower.jl:744–748` handles exactly four instruction
types and silently ignores everything else, including `IRCall`, `IRCast`,
`IRSelect`, `IRStore`, and `IRLoad`. So any loop whose body contains a
`call` (which every soft-float loop does) produces a gate list that
references SSA names that were never defined. The manual unrolled form
(`((x+1.0)+2.0)+3.0`) works fine. This is a real limitation that should
be a loud error rather than a stack trace from `resolve!`. The fix is
either to call the full `_lower_inst!` dispatcher from `lower_loop!`
(which does everything correctly already) or to validate the loop body
up-front and refuse to unroll what it can't. Either is a 10-line change;
currently this is trapped at an IR-layer call site with no clear
diagnostic for the user.

**Re-extraction of callee without width compatibility check, despite
`_assert_arg_widths_match`.** `lower_call!` at `src/lower.jl:1935–1936`
calls `extract_parsed_ir(inst.callee, arg_types)` where `arg_types` is
derived from `methods()` — but `_assert_arg_widths_match` at line 1934
has already verified that `inst.arg_widths` match the method signature.
So if `arg_types` is `Tuple{UInt64, UInt64}` and `inst.arg_widths ==
[64, 64]`, we're fine. But if `inst.arg_widths == [32, 32]` against the
same callee, the widths-check fails loudly (good), but the
extraction-then-use path that would emit the too-narrow wires is still
reachable from outside `lower_call!` via code paths that call
`extract_parsed_ir` directly (e.g. `lower_divrem!` hard-codes 64-bit
widening in `src/lower.jl:1427–1438`). No bug in the current call graph
— everything routes through `lower_call!` — but the IRCall invariant
"arg_widths matches the callee's concrete method" is only checked in one
place and not in the struct constructor. Move the check to `IRCall`'s
default constructor and this class of latent bug disappears.

---

## Next-quarter priorities

**1. Callee IR caching + precompile workload = compile-loop halved.**
Cache key is `(Function, DataType)`, value is `(ParsedIR, LoweringResult)`.
Pre-populate at module load for every `register_callee!`'d function
against its canonical signature. Measured win: ~200 ms saved per 10-fadd
float circuit, ~100 ms saved per polynomial circuit, and the test suite
is dominated by soft-float tests. Add a `@compile_workload` in
`Bennett.jl` that runs `reversible_compile` against a representative
mix (`x+Int8(1)`, `x+1.0`, `x*y on Int32`, one SHA-256 round). Expected
impact: cold compile from 15.6 s to ~2 s, full test suite from 4m06s to
~2m. This is the single-biggest lever on the developer-experience side,
it carries zero algorithmic risk, and it's probably two days of work.

**2. Cleave `lower.jl` into four files along the natural seams, and
collapse the overloaded `LoweringCtx` / `LoweringResult` constructors to
a single authoritative one each.** No algorithmic change, no test change
beyond path adjustment. The immediate win is that the next agent who
needs to touch phi resolution doesn't have to load 2,662 lines into
their head to not break memory dispatch. The compounding win is that
`CLAUDE.md`'s 3+1 agent rule becomes unnecessary for most patches — the
rule exists because the code is scary, and this makes the code less
scary. Two days of careful, mechanical refactoring. The tests either
pass or they don't; there is no middle ground.

**3. BitVec-packed simulator + batched gate application.** The 95k-gate
`soft_fadd` circuit simulates in 180 µs single-input today. Pack the
wires into `Vector{UInt64}` (each gate reads/writes one bit of one
word), vectorise across inputs for `verify_reversibility` (64 trials per
pass instead of 1), and the SHA-256 integration test gets 20-50× faster.
This unlocks *much* more exhaustive verification — you can actually
brute-force all 2^32 inputs on a 32-bit circuit in the time it currently
takes to do 100 random trials. I'd expect this to catch a nonzero number
of subtle bugs that `n_tests=100` doesn't. This is where I'd spend week
three of the quarter: it's where the "compiler meets reality" margin
lives, and where cheap tools pay for themselves forever.

---

## Small things worth fixing on the way

- `@assert` audit: downgrade the internal `length(x) == W || error(...)`
  style invariants in `src/shadow_memory.jl`, `src/adder.jl`,
  `src/qcla.jl` to `@assert`. Keep `error()` for user-facing messages.
  This removes string-formatting overhead on every primitive emission
  and lets `--check-bounds=no` runs drop the checks in production.
- README claim of "about 90 seconds" for test suite needs updating to
  ~4 minutes, or explicitly document that it was measured before the
  persistent-DS + multiplier-tree tests landed. WORKLOG hints the
  baseline shifted around T5 and nobody went back.
- CLAUDE.md gate-count baselines need a 30-second edit to match current
  defaults or to specify `add=:ripple`.
- The `gpucompiler/` directory at project root is a checked-out copy of
  the upstream `GPUCompiler.jl` package that doesn't appear to be
  referenced by `Project.toml` or any `include` in `src/`. Either it's
  dev-link scaffolding that should be in `.gitignore` or it's
  orphaned; either way it shouldn't show up in `git status` as `??`.
- Add one-line `Pkg.test()` GitHub Actions workflow. The rest of the CI
  hardening can come later; the zero-CI state is the thing that will
  bite when Julia next bumps LLVM.

The core is solid. The buildup around the core is where the next
quarter's attention should go, and in the order above the investment is
heavily front-loaded: TTFX + file split pay back the week they land.
Everything else can be paced.
