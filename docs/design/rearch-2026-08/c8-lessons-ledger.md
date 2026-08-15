# C8 — Ledger of Hard-Won Lessons (Bennett.jl, Apr–Aug 2026)

**Purpose.** A from-scratch reimplementation on Julia 1.13 will regenerate the code
for free. It will not regenerate the *debugging*. This is the set of facts that were
paid for in executed counterexamples, silent miscompiles, hostile reviews and
mis-closed beads — the things a v2 must carry forward or re-lose.

**Sources swept.** `WORKLOG.md` (index, 254 lines of dense per-arc summaries) + the
107 `worklog/NNN_*.md` chunks (headers all skimmed; ~20 read deeply);
`reviews/2026-04-21/` (19-agent audit → `UNIFIED_CATALOGUE.md`, 165 unified findings)
and `reviews/00_MASTER_REVIEW.md`; `docs/design/` consensus + scout docs;
`CLAUDE.md`'s 14 numbered principles; BennettVM.jl's 20 ADRs (`docs/adr/`); the 10
`bd remember` persistent memories.

**Rewrite-status legend.**
- **INVARIANT** — must hold in any design that compiles a real language to reversible
  circuits. Losing it re-creates a correctness bug.
- **SCAR** — matters only if v2 keeps a specific design choice; the choice is named.
- **TEST-CONVENTION** — a testing/verification rule to port verbatim into v2's suite.

**Size note.** 103 entries, not the 30–60 first scoped. Each of the priority classes
turned out to carry 9–19 independently paid-for lessons, and dropping any of them
drops a specific executed bug. **If you read only one pass, read the 40 below**; the
rest are real but second-order.

> **The 40 that matter most** — A1 A3 A4 A5 A9 · B1 B2 B3 B5 B6 B8 B10 · C1 C3 C4 C5
> C10 · D1 D3 D4 D6 D7 D8 D9 D13 D18 · E1 E2 E10 · F1 F2 · G1 G2 G3 G4 G5 G7 G8 ·
> H1 H6 H7 · I2 I3

---

## A. Phi resolution, control flow, false-path sensitization

The single most expensive correctness area in the project's history, and the one
CLAUDE.md carries a dedicated warning block for.

| # | Lesson | Provenance | Status |
|---|---|---|---|
| A1 | **False-path sensitization is the named failure mode**: in a branchless/speculative datapath *all* paths are computed, so a condition wire from a not-taken path can be genuinely true (subtracting two equal mantissas *is* zero) and its MUX fires without its dominating guard. This is the v0.5 `0.5 + 0.5 → 0` soft-float bug. Literature anchor: Bergamaschi 1992, "The Effects of False Paths in High-Level Synthesis". | `worklog/011`; CLAUDE.md §"Phi Resolution — CORRECTNESS RISK" | **INVARIANT** |
| A2 | **No published reversible compiler solves this** — ReVerC/Revs has no dynamic control flow, Janus has explicit exit assertions LLVM erases, VOQC works post-synthesis, XAG works on Boolean functions, Bennett's pebble game is DAG-only. v2 is in uncharted territory here and should not expect to find the algorithm in a paper. | `worklog/011` literature survey | **INVARIANT** (scoping) |
| A3 | **The principled fix is path predicates** (Gated SSA / Psi-SSA): `pred[entry]=1`; conditional branch gives `AND(pred[B],cond)` / `AND(pred[B],¬cond)`; merges `OR`; a phi becomes a MUX chain over path predicates. Correct for arbitrary CFGs, ~50 extra 1-bit gates for a 12-way phi. Shipped as `_compute_block_pred!` + `resolve_phi_predicated!`. | `worklog/011` Option B; `src/lowering/phi.jl` | **INVARIANT** (algorithm), SCAR for details |
| A4 | **Two preconditions of the predicate scheme are easy to violate silently**: (a) the predecessor list must be *distinct* — a duplicate OR-folds the same predicate twice and destroys "exactly one fires"; (b) every `block_pred` entry must be a *single-bit* wire, since only bit 0 is consumed by the AND/OR helpers. Both are now construction-time assertions. | Bennett-p94b / U110 | **INVARIANT** |
| A5 | **The cheapest real fix was upstream, not in the resolver**: rewriting `soft_fadd` branchless (`ifelse` → LLVM `select`, no phi at all) killed the entire bug class for ~5–10 % gates. Choosing the datapath style is a correctness decision, not a performance one. | `worklog/010` (Option A), `worklog/011` | **INVARIANT** |
| A6 | **Loop bodies get double-processed** — body blocks appear both in the function-level topo order and inside `lower_loop!`. A diamond inside a loop body needs BOTH per-iteration *local* block-pred dicts AND a top-level `loop_body_labels` skip set; either alone fails (crash on the merge block's phi against a stale predicate). | Bennett-jepw, `worklog/045` | **SCAR** — only if v2 unrolls loops during lowering |
| A7 | **Switch expansion patched phis only in already-emitted blocks**, and overwrote `phi_remap` when two cases targeted the same block — a silent miscompile on cascading `@enum` dispatch. Patch phis in one sweep *after* all blocks exist. | U11 / `reviews/…/10` CRIT-3 | **SCAR** — if v2 expands `switch` into synthetic blocks |
| A8 | **Phi validation was absent**: 0-incoming phis, mixed-width incoming, and self-referencing non-loop phis were all accepted at extraction and crashed or miscompiled downstream. Validate at the node, at the earliest point. | `reviews/…/10` §4 | **INVARIANT** |
| A9 | **A pointer-typed phi/select carries a width-0 sentinel**, and coercing a value sourced from one is a *silent* miscompile: native computes `p − p = 0` while the VM reads the sentinel as 0 and computes `0 − φ(p) ≠ 0`. Every pointer-identity contract in the project explicitly refuses phi/select sources. | cc0 M2b; foz5 `(C0)` hole; 57hd clause (V0) | **SCAR** — if v2 models pointers as cells |

---

## B. Ancilla hygiene and the Bennett construction contract

| # | Lesson | Provenance | Status |
|---|---|---|---|
| B1 | **`verify_reversibility` was tautological for months.** NOT/CNOT/Toffoli are each self-inverse, so *forward then reverse* always returns to the input — regardless of whether anything was computed, whether ancillae are zero, or whether the output is right. 256 call sites across 75 test files were measuring that self-inverse gates are self-inverse. It was the meta-bug hiding U02–U05, U23, U80. **The reversibility check must assert ancilla-zero after the FORWARD pass** (plus input preservation), never `fwd∘rev`. | U01, `reviews/…/09` §1; fixed 2026-04-22 | **INVARIANT** |
| B2 | **Reversibility ≠ correctness.** Always pair `verify_reversibility` with an output-vs-oracle assertion; this became a standing rule in the worklog header after the 3of2 close. | `worklog/044–045`, WORKLOG standing rule | **TEST-CONVENTION** |
| B3 | **Any uncompute schedule that is not strict index-reverse is unsound on branching code until proven otherwise.** `value_eager_bennett` ran Kahn's algorithm on `input_ssa_vars`, which cannot see the *wire-level* dependencies between synthetic `__pred_*` groups → 100 % ancilla leak on every diamond CFG, every input, silently. | U02, `reviews/…/09` §2 | **INVARIANT** |
| B4 | **The correctness argument for index-reverse uncompute is state-matching**, not gate self-inverseness: reversing gate *g* is only correct if the state at reverse time equals the state right after *g*'s forward. Straight-line SSA with disjoint group wires satisfies this; shared predicate wires across blocks do not. | `reviews/…/09` §5 | **INVARIANT** |
| B5 | **A `self_reversing=true` tag is an unchecked trust boundary** and must be validated at runtime, uniformly, in every strategy. Pre-fix, only `EagerStrategy` silently accepted a forged tag; the other four threw — but each from an unrelated algorithm-internal check, never from the contract probe. Generalizable rule: **when extending a contract across an axis, measure WHERE the throw originates, not just WHETHER it throws.** | U03 / Bennett-egu6; Bennett-rjk7 | **INVARIANT** |
| B6 | **Knill's pebbling theorem is stated at DAG-node level; applying it to raw `gates[lo:hi]` ranges is valid only for pure-SSA (fresh-target) gates.** Any in-place op — Cuccaro's `b += a`, `emit_shadow_store!` — interleaves wire states across pebble boundaries and breaks the argument. `pebbled_group_bennett` detects and falls back; `pebbled_bennett` did not. | `reviews/…/09` H2, `worklog/006` | **INVARIANT** |
| B7 | **Interleaved cleanup during the forward pass is safe only for dead-end values** (never read as a control). Cleaning a value with a live consumer makes that consumer's later uncompute read zero. Attempted and disproved empirically. | `worklog/006` (value-level EAGER) | **INVARIANT** |
| B8 | **Wires must form a validated partition at circuit-construction time.** `ancilla ∩ input` or `ancilla ∩ output` makes the ancilla-zero check fire on a data value (false positive *or* negative); `input ∩ output` IS legal (self-reversing primitives write onto their inputs); the union must cover `1:n_wires` so nothing escapes classification. Later became a four-set partition with loop-guard wires. | Bennett-6azb / U58; Bennett-s0tn; `src/gates.jl:96` | **INVARIANT** |
| B9 | **Shadow-memory store correctness rests entirely on a FRESH all-zero tape slot per store.** Sharing tape slots across stores breaks reversibility. | `reviews/…/09` L1 | **INVARIANT** |
| B10 | **A data-dependent loop needs a runtime convergence witness, not just a compile-time K.** An undersized `max_loop_iterations` leaves the check wire at 0 *and* dirties ancillae; the guard is checked FIRST so the user sees "loop did not converge, recompile with larger K" instead of a mysterious dirty-ancilla crash. **Diagnostic ordering is part of the design.** | Bennett-s0tn; `src/diagnostics.jl:254` | **INVARIANT** |
| B11 | **Callee inlining hardcodes `max_loop_iterations=64`** regardless of the caller's kwarg — gate count blows up as O(K × callee_gates) with nothing in the source to suggest it. | `worklog/075` loops audit; `src/lowering/call.jl:88` | **SCAR** — inline-callee lowering |

---

## C. Verification and test conventions to port

| # | Lesson | Provenance | Status |
|---|---|---|---|
| C1 | **The subnormal-output sweep rule.** Every transcendental must have a testset sweeping inputs `x` where `Base.f(x)` is *subnormal*, in steps fine enough to populate every binade (0.25–0.5), asserting bit-exactness. Filed from the `soft_exp` post-mortem: the `x ∈ [−708.4, −745]` garbage-output bug survived initial testing because the random sweep ran on `[−50, 50]` and never visited the subnormal-output region. Reference implementations: `test/test_softfexp.jl:135`, `test_softfexp_julia.jl:182`. | CLAUDE.md §13; Bennett-fnxg, Bennett-wigl; `worklog/018` | **TEST-CONVENTION** |
| C2 | **Exhaustive for Int8 (all 256); spanning sets + edge cases above.** A single representative `simulate` input catches an ancilla bug only if the bug fires on that exact input — and 5 test files compiled circuits with no ancilla check at all. | U23, `reviews/…/09` H1 | **TEST-CONVENTION** |
| C3 | **When two code paths emit the same bytes for one value of a flag, only the OTHER value is a test.** The both-constant overflow table had `uadd` at bit 0 only — byte-identical to the pre-existing fold-to-zero shape — so the fixture would have passed with the feature deleted. Coverage in name only. | Bennett-tl1l hostile review | **TEST-CONVENTION** |
| C4 | **Admitting fixtures must include the UNSAFE parameter values, not only safe ones.** p06b's capacity clobber survived two blind proposers and 527 green assertions because every admitting fixture happened to pick a big-enough alloca. | bd memory `prose-vs-predicate…` | **TEST-CONVENTION** |
| C5 | **Mutation-verify that the predicate under test actually evaluates there.** sy29's in-object range guard was proved live by flipping `<=`→`<` and watching the corpus reject; 57hd's gates were RED-first, one by temporarily disabling a one-line guard and watching `pred(a)` flip `true → false`. A green run alone proves nothing about a guard with broad early-out conditions. | sy29 D2; 57hd | **TEST-CONVENTION** |
| C6 | **The K=1 trap.** At a canonical offset of 0, a wrongly-scaled address is indistinguishable from a right one — so the whole `push!` corpus (all K=1) hid a latent K≥2 defect behind green pins. Any address/stride test must be K≥2. | sy29; pre-4y0d vbv9 | **TEST-CONVENTION** |
| C7 | **Non-vacuity assertions for zero-difference theorems.** When the claim under test is `d == 0` and an unstored cell also reads 0, degenerate agreement passes. Assert `x != y && y != 0` alongside. | 57hd BVM E2E | **TEST-CONVENTION** |
| C8 | **`return` inside `@testset begin…end` silently aborts the testset** — a RED run can under-report to 2 assertions and look like it ran. Use `if`, never an early return. | `worklog/097`, Bennett-3vf2 | **TEST-CONVENTION** |
| C9 | **Static-inspection tests are the cheap enforcement of "this idiom must be present everywhere"** (bare-`catch` narrowing, error-message prefixes, toolchain-skip guards): ~50 LOC, zero runtime cost, reliable. One false-positive class — prose in docstrings — and it bit: the English word *"catch"* in a docstring failed the entire 691 801-assertion suite from a file no per-file gate covered. Skip docstring bodies. | Bennett-uinn / f6qa / srsy; sy29 D1; Bennett-gb39 | **TEST-CONVENTION** |
| C10 | **A per-file "green" is only meaningful in the suite's flag mode.** `Pkg.test()` hard-codes `--check-bounds=yes`, which changes the LLVM IR Julia emits (see D18). Bennett-k31q was mis-closed *twice* as a "test-ordering bug" for this reason. | Bennett-k31q, Bennett-2mj3; CLAUDE.md Build&Test | **TEST-CONVENTION** |
| C11 | **Never truncate an error message before keyword-matching it.** A benign-skip allowlist was neutered because the capture did `sprint(showerror,e)[1:80]` and the keyword sat at char ~130. Match the full string; truncate char-safely for display only. | Bennett-k31q root cause | **TEST-CONVENTION** |
| C12 | **Assert that the test registry matches the test directory.** a70z's new test file was never wired into `runtests.jl` (would never have run); five more files sat unregistered on disk for months — silent regression-surface shrinkage. | a70z D2; Bennett-llqc | **TEST-CONVENTION** |
| C13 | **Hand-built IR fixtures beat round-trip extraction** whenever the lowering under test doesn't depend on an LLVM quirk; and hand-written `.ll` through the *real* front end beats hand-built `ParsedIR`, because the shape under test is then whatever the extractor emits today rather than a transcription of it. Some paths (persistent-state dispatch) are testable *only* via `.ll` fixtures, because Julia's SROA dissolves the construct before any alloca materialises. | `worklog/042`; tl1l; Bennett-smjd key learning | **TEST-CONVENTION** |

---

## D. LLVM API and IR-extraction traps

| # | Lesson | Provenance | Status |
|---|---|---|---|
| D1 | **`LLVMIsUndef` / `LLVMIsPoison` return an `LLVMBool` (`Cint`), not a value ref** — so `LLVM.API.LLVMIsUndef(x) != C_NULL` is TRUE for every input. It reset every canonical result and rejected the whole corpus (five gates red at once). **The `LLVMIsA*` family returns refs; the `LLVMIs*` predicates return `Cint`.** Cost a full review cycle. | 57hd hostile review | **INVARIANT** (API fact) |
| D2 | **LLVM UNIQUES `undef`/`poison` per type**, so two *independent* chains canonicalise to the SAME ref and any equality/identity predicate passes for two things that are not even values. Must be refused explicitly. | 57hd D3a | **INVARIANT** |
| D3 | **Operand bundles are invisible to the raw `memory` attribute.** LLVM's own `CallBase::getMemoryEffects()` ORs in `writeOnly()` for a clobbering bundle, so reading the declared attribute believes a call LLVM itself treats as a writer; bundles ALSO shift the operand→parameter index mapping a `nocapture` scan indexes into. Guard `GetNumOperandBundles == 0` in both places. | 57hd D2 | **INVARIANT** |
| D4 | **The `memory` attribute is a raw packed integer with an LLVM-internal encoding.** Decode must fail closed on any bit outside the locations the pinned LLVM version defines, carry two decode canaries that move in OPPOSITE directions (`memory(argmem: readwrite)` must reject, `memory(none)` must admit), and look attribute kind-ids up **by name per call** — never `const`-cache them, or precompilation bakes one LLVM build's numbering into the `.ji`. | 57hd O-1 | **INVARIANT** |
| D5 | **LLVM auto-populates intrinsic attributes** — deleting `nocapture` from a `declare void @llvm.memcpy…` fixture has no effect. Put such gates on an ordinary callee. | 57hd | **TEST-CONVENTION** |
| D6 | **An IR claim is valid only for the exact pipeline configuration that produced it.** A `raw=true` `code_llvm` dump "falsified" a scout with an `addrspacecast` sighting — the dump was the artifact; zero addrspacecasts exist on the real (`raw=false`) extraction path. Likewise the "two live aggregate stores" a bead reported was a raw-dump artifact (post-SROA there is exactly one). Always re-dump in the walker's own configuration. | Bennett-3vf2; `worklog/092`; p06b | **INVARIANT** |
| D7 | **`convert(Int, ::ConstantInt)` sign-extends and silently truncates.** i8 `192` arrives as `−64`; an i128 constant is truncated to its low 64 bits, so `ret i128 2^127` compiled to a circuit returning 0 for every input. Constants need a width-carrying representation. | U09 / CRIT-1; a70z gotcha | **INVARIANT** |
| D8 | **Never guess a GEP stride.** `offset_bytes` stored the raw *index*, not bytes (safe only for i8 element types, i.e. Julia's opaque-pointer default), and `IRVarGEP.elem_width` defaulted to 8 bits for non-integer source types — so `getelementptr double, ptr %p, i64 %i` read the 2nd *bit*. Both silent miscompiles on any C/Rust-typed GEP. Read `LLVMGetGEPSourceElementType`; error loudly when it isn't modelled. | U12/U13, CRIT-4/5 | **INVARIANT** |
| D9 | **Silent drops are the anti-pattern, not a soft failure.** Multi-index GEPs (`%S, ptr %p, i32 0, i32 1` — the standard struct access), 3-index global-array GEPs, inline-asm calls and unregistered callees were all dropped at extraction and surfaced as `Undefined SSA variable: %r` at lowering. Fail at the earliest opportunity, with the instruction in the message. | U15/U16, CRIT-7/8; CLAUDE.md §1 | **INVARIANT** |
| D10 | **A crash still has to be loud with context.** `extractvalue`/`insertvalue` assumed `ArrayType` and died with a bare `UndefRefError` from inside LLVM.jl on any literal `StructType` — i.e. every `*.with.overflow` intrinsic and every mixed-width tuple. | U10 / CRIT-2 | **INVARIANT** |
| D11 | **Read attributes per-parameter through the typed API, never by regex over the IR text.** A function-wide `dereferenceable\((\d+)\)` regex on the `define` line gave *every* pointer parameter the first one's byte count (phantom input wires, doubled input-wire count) — and it was the sole live path because the typed `LLVM.parameter_attributes` call was raising a `MethodError` that a try/catch swallowed. | U17 / CRIT-9 | **INVARIANT** |
| D12 | **Broad string-matched catch blocks are time bombs.** `e isa MethodError && occursin("PointerType", msg)` silences any unrelated bug whose message mentions a ubiquitous LLVM type name; and a bare `catch` also swallows `InterruptException`. Standing idiom: `catch e; e isa InterruptException && rethrow(); …`. | U18/CRIT-10; Bennett-uinn | **INVARIANT** |
| D13 | **Intrinsic-name prefix matching must carry the trailing dot.** `startswith(cname, "llvm.atan")` matched `llvm.atan2.f64` and silently compiled `atan2(3,4)` as `atan(3) ≈ 1.249` instead of `0.6435`. The same class recurred twice more in one session (`llvm.exp` swallowing `llvm.expm1`; `llvm.round` dispatching to banker's rounding instead of round-half-away). Ruled: every `startswith(cname,"llvm.<x>")` carries the `.` from the moment of insertion — enforced by codemod across 32 sites. | Bennett-7goc, o7cy, kh6n, mq6f | **INVARIANT** |
| D14 | **Atomic/volatile flags were silently dropped from load/store.** Semantically harmless for a single-observer circuit — but silently dropping a semantic marker is still the §1 violation, and it is a trap for any future concurrency/quantum-control work. Model it or refuse it. | U14 / CRIT-6; Bennett-ares | **INVARIANT** |
| D15 | **LLVM.jl's coverage is uneven; budget for raw C-API fallbacks.** `LLVM.operands()` crashes on `GlobalAlias` operands; `LLVM.isvolatile` isn't exported (use `LLVM.API.LLVMGetVolatile`/`LLVMGetOrdering`); `LLVM.parameter_attributes` MethodErrors on the pinned version. LLVM.jl instruction iteration *does* yield program order — an API premise worth recording explicitly, since every positional walker rests on it. | Bennett-gps7; `worklog/097`; 57hd (P4) | **SCAR** — LLVM.jl-specific |
| D16 | **A "VoidType reached `_type_width`" extraction error can mean the function doesn't compile at all.** A missing method makes Julia infer `Union{}`, emit a `jl_f_throw_methoderror` + `unreachable` body with LLVM return type `void` — which extraction correctly refuses. Check `hasmethod` / `Base.return_types` before suspecting the extractor. | Bennett-l5v8 (2026-08-14) | **INVARIANT** (diagnostic) |
| D17 | **Julia's mangled names drift per compilation.** `jlplt_<callee>_<N>_got` discriminators and `#4a8d3eda` type digests are `hash(::DataType)`-based and PROCESS-VARYING. Never pin the discriminator; strip it and match the stem. (`string(hash;base=16)` also drops leading zero nibbles for ~1/16 of hashes — lpad.) | Bennett-klgz, utzc, 40ys | **INVARIANT** |
| D18 | **`--check-bounds=yes` changes the IR Julia emits.** `x -> [x,-x][1+Int(x<0)]` stops stack-allocating its array literal and brings a GC frame with a *volatile* memset, an inline-asm TLS read (`movq %fs:0`) and an external `ijl_gc_small_alloc` call; and it surfaces *earlier* extraction walls (`ptrtoint` before memcpy). Some walls are `--check-bounds=yes`-only artifacts. | Bennett-k31q, 2mj3; `worklog/090`, `worklog/092` | **INVARIANT** |
| D19 | **Closed-world callee acquisition must go by SIGNATURE, not by instance.** Julia 1.12 outlines slow paths into non-singleton closures; `.instance` throws a bare `UndefRefError` outside any rescuable frame, `nameof(ClosureType)` yields a type name no LLVM symbol matches (use `mi.def.name`), and an argtypes-only cache digest **provably collided** (Int32 vs Int64 `push!` closures keyed identically) — digest the full `specTypes`. | Bennett-40ys | **SCAR** — closed-world multi-body ingest |

---

## E. Soft-float and numeric conventions

| # | Lesson | Provenance | Status |
|---|---|---|---|
| E1 | **Declare the deviation and refuse, don't approximate.** f32 routed through `soft_fpext → f64 op → soft_fptrunc` double-rounds and is NOT bit-exact; rather than ship a nearly-right f32, `reversible_compile(f, Float32)` is *rejected* and the bit-exactness contract is scoped to f64 in the docstring header. | CLAUDE.md §13; Bennett-3rph / U137 | **INVARIANT** |
| E2 | **Bit-exactness outranks a compiler permission**: vector reductions fold strictly left-to-right and LLVM's `reassoc` flag is deliberately IGNORED. | Bennett-pg5 / lx5h | **INVARIANT** |
| E3 | **Port faithfully and reuse kernels** (musl / Julia stdlib), don't invent polynomials. The log1p-based refactors dropped K=25/K=30 minimax polynomials for ~13 soft-float ops with *better* accuracy; `soft_acos` reuses `soft_asin`'s R-coefficients verbatim. | CLAUDE.md §12; 0ulc, 8ygo, bipw, tfmo, bd7f | **INVARIANT** |
| E4 | **Julia evaluates all `ifelse` arguments eagerly**, so branchless code must clamp intermediates that would throw (`UInt64(negative)` → `InexactError`) even where the select will discard them. | `worklog/010` | **INVARIANT** for branchless soft-float |
| E5 | **Derive regime thresholds, don't guess them.** `soft_log1p`'s first draft used a tiny-threshold of 2⁻²⁶ and gave 2.4 M ULP at x = 1e-9; the correct value is 2⁻⁵⁴, established empirically *and* algebraically. Sweep the regime boundary in the test. | Bennett-0ulc | **TEST-CONVENTION** |
| E6 | **Operator ordering is load-bearing.** `(0.5·E)·E` not `(E·E)·0.5` in sinh's huge arm; `muladd` vs `mul + add` at `@noinline` sites changed integer-exponent `^` results. Also: a 5-op unified formula lost 3–4 ULP where a 3-op regime split held ≤2. | ky5n, jexo | **INVARIANT** |
| E7 | **`isnan()`-only tests mask NaN payload/sign bugs** — soft-float ops were canonicalising both across the board. Compare BIT PATTERNS, not predicates. | U08 / U60 | **TEST-CONVENTION** |
| E8 | **Native `UInt128` in compile-to-gates code emits i128 constants the extractor rejects** — the `(hi, lo)` UInt64-pair representation is mandatory for Payne-Hanek reduction, even though a sibling bead said "UInt128 ops compile". | Bennett-3mo (l9cl vs yys3) | **SCAR** — if v2 keeps a 64-bit constant ceiling |
| E9 | **`@noinline` on the SoftFloat wrapper methods is wrong** — it produces struct-passing IR with `alloca`/`store`/`load` instead of a clean `call @soft_fmul(i64,i64)`. But `@noinline` in *body* position IS load-bearing for closed-world extraction (else inlining empties the call graph). Know which one you're doing. | `worklog/010`; Bennett-40ys | **SCAR** |
| E10 | **The dispatch surface is a separate layer from the primitives and rots independently.** Eighteen `Base.<f>(::SoftFloat)` overloads were missing while every soft primitive existed and was registered — so `reversible_compile(sin, Float64)` failed with an extraction-shaped error for four months. Assert dispatch-surface completeness against the primitive registry. | Bennett-l5v8 | **TEST-CONVENTION** |

---

## F. Gate-count baselines and benchmark methodology

| # | Lesson | Provenance | Status |
|---|---|---|---|
| F1 | **Gate counts are regression tests, and the scaling laws are the real assertion**: for `add=:ripple, fold_constants=true`, i8 `x+1` = 58 gates → i16 114 → i32 226 → i64 450, obeying `total(2W) == 2·total(W) − 2`; Toffolis 12/28/60/124 obeying `T(2W) == 2·T(W) + 4`. A changed count is a signal to investigate, not to update. | CLAUDE.md §6; `test/test_gate_count_regression.jl` (39 pins) | **TEST-CONVENTION** |
| F2 | **Pin baselines to EXPLICIT strategy kwargs, never to `:auto`.** This is what lets the default dispatcher evolve (e.g. `add=:auto` migrating `:ripple → :qcla`) without tripping the suite; default-vs-explicit deltas go in BENCHMARKS.md instead. | Bennett-hjwp / U150 | **INVARIANT** (methodology) |
| F3 | **Docstring cost formulas drift from the implementation** — one claimed `2n/5n/2n` while emitting `2W−2/4W−2/0`, with no test asserting either. Any docstring stating a gate count must be paired with a pinned measurement. | Bennett-op6a | **TEST-CONVENTION** |
| F4 | **Measure before optimizing.** Hours went into carry cleanup (8.1 % of SHA-256 wires) when barrel shifters were 55.8 %. | `worklog/005` | **INVARIANT** (process) |
| F5 | **A wire win can be a depth loss.** A mid-algorithm `fast_copy` swap saved ~25 % wires and added 30 % depth, breaking the polylog-depth promise — the bead was left OPEN with the finding rather than shipped. The Pareto axis is part of the contract. | Bennett-9wmk | **INVARIANT** |
| F6 | **A committed plot is a passing test, drawn** — the plotting scripts recompile the circuits, assert `verify_reversibility` and the pinned baselines, *then* draw. (Related doc-accuracy nit: `peak_live_wires` measures the all-zero-input run specifically, not a worst case.) | Bennett-hk5i, `worklog/106` | **TEST-CONVENTION** |

---

## G. Pointer/memory modelling and escape analysis — the 57hd hostile-review arc

The last five frontier arcs (p06b → foz5 → bvmd → sy29 → 57hd, Aug 2026) produced the
project's sharpest correctness lessons, four of them backed by *executed* miscompiles.

| # | Lesson | Provenance | Status |
|---|---|---|---|
| G1 | **A two-operand instruction has two roles, and an escape analysis that names only one of them has not looked at the instruction.** The store arm checked only the ADDRESS operand, so `store ptr %a, ptr %a` — the alloca's own address written into itself — passed the non-escape scan; the reloaded alias classified `:other`, roots were called disjoint, and a later write straight through the alias was skipped. **Measured on the VM: a difference guaranteed to be 0 in both worlds evaluated to 64, and escaped into a `gc_alloc_obj` size operand.** `store` is the only LLVM opcode where the pointer can appear as either operand — which is exactly why it is the one that was got wrong. | Bennett-57hd D1 (the only executed counterexample this contract ever had) | **INVARIANT** |
| G2 | **A contract may not rest its own soundness surface on a different arm's rejection — arms move.** Two 57hd fail-opens (uniqued `poison`; a negative mem-intrinsic length inverting `[off, off+n)` into an empty range so every real write was skipped) were saved only by *other* beads' guards. Luck, not design. | 57hd D3 | **INVARIANT** |
| G3 | **A canonicalisation tuned for EQUALITY is not automatically valid for DISJOINTNESS.** `_p06b_slot_key` stopping at a variable index and making that GEP its own root is a sound equality key and a disaster in the other direction: a variable-GEP store into a non-escaping alloca was then called disjoint from the object it writes (measured ADMITTED pre-fix). | 57hd implementer finding | **INVARIANT** |
| G4 | **"Distinct static allocation sites yield disjoint ranges" is a FALSE THEOREM** once a GEP walks out of its own object. Two adjacent arena boxes make `%a + 24` *be* `%b + 8`; the ascending load-then-store miscopied it — **executed: s = 222 against an oracle of 333**, plus a second symptom where a range past its own reservation silently read the next object. Monotone bump allocators make distinct *allocations* disjoint; they say nothing about distinct *roots*. Fix: an in-object range guard `0 ≤ off && off + N ≤ capacity` on BOTH operands. | Bennett-sy29 D2 | **INVARIANT** |
| G5 | **Certify what is RESERVED, not what would be EMITTED.** p06b's predicate certified that the target's producer *would emit an IRAlloca*, never that it *reserves ≥ N cells*; an undersized alloca receiving a 2-field store clobbered its neighbour — **EXPECTED 999, ACTUAL 42, no error**. | p06b D1 | **INVARIANT** |
| G6 | **"A registered SSA name is evidence of nothing"** in an extractor with a suppression pass — three separate p06b defects were instances of that single mistake. Certification must consult the suppressed set. Generalises: a *name table* is not a *fact table*. | p06b D1b | **SCAR** (extractor with suppression) / general pattern |
| G7 | **Don't ship a guard that appears to close a hole it cannot.** A reserved-regions bounds check provably CANNOT catch adjacent-allocation clobbers (no region table, three monotone cursors) — every repro clobbers a *live neighbour*, not unreserved space. Rejecting that needs pointer provenance, which neither repo had; the limitation was disclosed in the arm, the test header and the worklog rather than papered over. | bennettvm-pdqx; p06b escalation | **INVARIANT** |
| G8 | **Facts a walker establishes inside a basic block are per-iteration facts, and remain valid in loops** precisely because a block executes as a straight line on every entry; the only cross-iteration channel is a `phi`, which the contract refuses. The argument was CORRECT and stated NOWHERE — so the next reader would have added an unnecessary back-edge veto (a regression). **Write down the loop-safety argument, and name the change that would break it.** | 57hd D5 | **INVARIANT** |
| G9 | **When two things must agree and unifying them is costly, write the divergence as a CASE ANALYSIS, not a hope.** Raw vs canonical roots were deliberately left un-unified (unifying made two functions mutually recursive for no measured gain); instead every divergence class was enumerated and shown to fail CLOSED, with the docstring naming the change that would break the argument. | 57hd D4 | **INVARIANT** |
| G10 | **Coherence and expressibility are different properties.** `gep i8 %obj, 4` off a byte-tier root is perfectly scale-coherent, yet a byte tier names a 64-bit value only at its BASE address, so an 8-byte chunk at byte 4 straddles two named cells and no load/store pair expresses it. | sy29 predicate 6c | **SCAR** (cell model) — but "prove it can be SAID" generalises |
| G11 | **Address/value conflation is its own bug class.** One width variable served both the stored VALUE's width (must stay 64) and the pointer STAMP (must be 8 for a byte-tier destination); a K=1 pin literally asserting `elem_width == 64` stayed green over the latent defect, because the pin was protecting the *cell*, which was unchanged. | Bennett-4y0d / vbv9 | **SCAR** |
| G12 | **Widening a recogniser can STEAL another arm's witness and regress the frontier** — measured by probe (`p07_steal.jl`) before deciding, and the fix was a *second disjunct* with the original keeping first refusal, leaving the shared root recogniser byte-for-byte untouched. Overlap between `||`-disjuncts is not the forbidden thing; widening the shared primitive is. | Bennett-foz5 | **INVARIANT** (process) |
| G13 | **Count certainties, not possibilities, when adjudicating designs.** Proposal A had two *unproven* failure directions; proposal B had one *proved* to occur on every out-of-bounds input. B lost. | foz5 adjudication | **INVARIANT** (process) |
| G14 | **When you claim a shape needs a NEW contract, evaluate EVERY SHIPPED CONTRACT'S OWN PREDICATE on it** — not your prototypes against each other. The 57hd scout's central framing ("neither route dominates") was overturned by measurement: the values it called unadmitted were *already admitted* by a shipped predicate, and the true coverage of the proposed alternative was an overlap, not a gain. A table-shaped executable gate catches this; a prose claim does not. | 57hd, banked as a methodological rule | **INVARIANT** (process) |

---

## H. Determinism, the closed world, and the VM boundary

| # | Lesson | Provenance | Status |
|---|---|---|---|
| H1 | **Address-identity hashing is a determinism FLOOR, not a modelling gap** — and the two must be *different error classes*. `ijl_object_id` (mutable-struct `objectid`, an address hash) is non-deterministic across replays and can never be modelled; `memhash_seed` (String/Symbol content hashing) is deterministic, in scope, and merely not-yet-modelled. Same syntax at the reject site, opposite prognosis. | Bennett-klgz | **INVARIANT** |
| H2 | **Pointer comparisons: admit `eq`/`ne` only.** Ordering predicates on addresses are allocator-layout-dependent / UB, and the value of a pointer identity arm rests entirely on the use-shape gate. | Bennett-8g7m, jbko | **INVARIANT** |
| H3 | **A trapped program must still be fully reversible** — a program halting at the `:__unreachable__` sink must `unrun!` to the exact initial state. | jbko BVM E2E | **INVARIANT** |
| H4 | **Dead-block pruning is sound by SSA domination alone** (a block with no successors dominates only itself), a strictly stronger argument than the "the pruner empties those blocks" one both designs used. Hostile review found the better proof. | Bennett-3vf2 | **INVARIANT** |
| H5 | **Model an ABI verbatim; never fuse split fields.** Julia's split-roots ABI routes the GC-tracked half through a `return_roots` out-param and stores a literal `i64 −1` into ptr-*typed* sret slots — so field matching must be WIDTH-based, not type-equality-based, and fusing `return_roots` into the aggregate is a silent pointer miscompile (guarded by explicit anti-fusion pins). | Bennett-7wsz | **SCAR** (Julia ABI) |
| H6 | **A paper's rule carries its preconditions.** Mogensen's RSSA note 2 ("uses as parameters to labels in exit points destroy these variables") presupposes *parameterized blocks*; implemented literally in a VM without them, it deleted live names mid-run (`KeyError` 4 603 steps into a 10 790-step trace). Verify the precondition against your own construction, not the sentence. | BennettVM ADR 0022 | **INVARIANT** |
| H7 | **Verify a design premise against real IR before building on it.** ADR 0015's whole route rested on "the Dict's keys/vals `Memory` backing is the store-level floor"; a `code_llvm` probe showed the backings are *interned globals* and the mutating write lives in an *opaque callee*. The ADR was amended in place and superseded by ADR 0017. | ADRs 0015 → 0017 | **INVARIANT** |
| H8 | **"Advances to the next wall" is NOT monotone in program order.** Clearing a pre-walk wall exposed the body walk's FIRST instruction, so the frontier moved *backwards*; both proposals' forecasts came from ungated monkey-patches and were wrong. | Bennett-7wsz | **INVARIANT** (process) |
| H9 | **Extracting a function in isolation can succeed where extracting it as a registered callee fails**, because the isolation path takes a different, more forgiving arm. Isolation success is not evidence about the real pipeline. | Bennett-xrd6, `worklog/091` | **INVARIANT** |

---

## I. Process and institutional-memory mechanics

| # | Lesson | Provenance | Status |
|---|---|---|---|
| I1 | **Two *blind* proposers + implementer + orchestrator-reviewer (the "3+1") repeatedly caught premise errors a single agent accepted.** Concretely: a bead saying "two gate sites" had five; a bead's central premise was not expressible by the extractor at all; a bead's manglings were wrong; a bead's suggested discriminator did not exist in the message text. **Bead/spec text is user-filed and routinely wrong at the line-number AND architectural level — verify against source before scoping.** A rewrite's own design docs inherit this failure mode. | CLAUDE.md §2; `worklog/045`, `worklog/069` lessons 1–2 | **INVARIANT** (process) |
| I2 | **Hostile review as a landing GATE, not a formality.** In one six-arc session it caught ~12 real defects pre-commit including FOUR executed miscompiles (p06b capacity clobber, sy29 cross-allocation overlap, 57hd self-store escape, bvmd's rejected cross-function re-stamp); every one died before landing. Two of the five arcs FAILED review and shipped a same-day fix cycle. | `worklog/106` retrospective | **INVARIANT** (process) |
| I3 | **Prose-vs-predicate.** Any fail-loud message or comment naming a hazard class must cite the exact line/predicate that CHECKS it — a message asserting a guarantee no code checks is *worse than silence*, because it stops the next reader looking. Both p06b P0s were exactly this shape and survived a full 3+1. | p06b hostile review; banked bd memory | **INVARIANT** |
| I4 | **The orchestrator's own confident assertions need empirical probes too.** One `code_llvm` call would have caught the widening-mul claim that the implementer had to correct. | `worklog/068` | **INVARIANT** (process) |
| I5 | **Two triage hygiene rules that recur on every pickup**: (a) "investigated, doc-only" is a legitimate disposition, and the tested-and-rejected decision belongs in a source comment so nobody re-walks it; (b) cited line numbers are write-once-read-stale — grep for the symbol, never the line. | 3of2, 2yky, vt0a; `worklog/043`, `worklog/045` | **process** |
| I6 | **Institutional memory needs a *checkable* pointer, not a hardcoded one.** CLAUDE.md's "prepend to `worklog/038_*.md`" was 37 chunks stale and would have sent agents to write into a three-month-old file; it was replaced with "check `ls worklog/ \| sort -r \| head -1`". Sharding was necessary (a 9 774-line monolith), and the re-shard script is destructive and must not be re-run. | `worklog/075`; Bennett-fyni / U70 | **INVARIANT** (for v2's own docs) |
| I7 | **Exactly ONE full suite run per arc, after the review verdict and fix cycles, on the final landing tree; reviewers run none.** And never report an arc without a green FULL suite — a single English word in a docstring failed the suite from a file no per-file gate covered. Targeted per-file runs are necessary but NOT sufficient: one push failed the gate solely because one `occursin`-disjunction test was omitted from the targeted subset. | user-ratified 2026-08-07; sy29 D1; bd memory `cwd-ptr-cells-rerun-lf14` | **process** |
| I8 | **A cross-cutting fix must be applied everywhere the axis reaches, and the axis must be enumerated.** The catalogue's own dependency analysis is the template: U01 (tautological verifier) is the *meta-bug* whose fix exposes U02–U05, U23 and U80 — so it had to land first, or every subsequent fix would be validated by a broken oracle. | `reviews/…/UNIFIED_CATALOGUE.md` §E | **INVARIANT** (process) |

---

## J. Environment and toolchain

| # | Lesson | Provenance | Status |
|---|---|---|---|
| J1 | **Suite cost is COMPILE-bound, not simulate-bound**: 65 % of a 28-minute suite is 12 transcendental LLVM-dispatch files (47–126 s each), each building 2.4 M+-gate circuits single-threaded. Threading the inner simulate sweeps is the wrong instinct (single-digit seconds across the whole suite); gains need circuit caching or compile parallelism. | bd memory `suite-cost-is-compile-bound-2026-05-23` | **SCAR** — but the measurement discipline ports |
| J2 | **No concurrent Julia processes** — precompile-cache corruption; `pgrep -af julia` before any invocation. Related: `Pkg.test()` output must be filtered by *signal terms* (`tests passed` / `Test Failed`), never by `tail -N` — pipe buffering once turned a passing run into an alarming 15-line stack-trace fragment. | user memory; `worklog/095`; `worklog/040` | **process** |
| J3 | **No GitHub CI, by explicit standing user policy** — failure-email noise is judged worse than zero signal. Quality gates are local: `Pkg.test()`, a pre-push git hook, `bd`. A v2 that "adds CI" is reversing a decision, not filling a gap. | CLAUDE.md §14 | **INVARIANT** (project policy) |
| J4 | **`Pkg.test()` filtering exists and the "hidden flag" was measured and declined**: `julia_args=["--check-bounds=auto"]` reuses the REPL precompile cache but *changes the semantics the suite pins* (see D18); a full precompile is 104 s against a 28-min suite, so it buys nothing. Substring file filters from `test_args` were shipped instead, with fail-fast if a pattern matches nothing. | Bennett-uxyy, `worklog/107` | **SCAR** / **process** |

---

## Top-of-mind for the v2 architect

Five structural conclusions the ledger points at, stated as design pressure rather
than as findings:

1. **The verification oracle is load-bearing infrastructure and must be built first.**
   B1 is the single most expensive lesson in the project: an oracle that cannot fail
   validated everything below it for months.
2. **"Silent drop" must be structurally impossible.** Nearly every CRITICAL in the
   19-agent audit is a `return nothing` in an opcode dispatcher. A total dispatch
   (every opcode either handled or explicitly refused, checked by construction) removes
   a whole severity class that v1 spent four months mopping up.
3. **Branchless-by-construction where it is affordable.** A5 shows the cheapest fix to
   the hardest correctness problem was upstream of the resolver.
4. **Pointer/cell modelling is where the remaining executed miscompiles live** (§G).
   If v2 keeps a cell model, it inherits G3/G4/G5/G10/G11 wholesale; if it chooses a
   different memory abstraction, those become SCARs and G1/G2/G8/G9 remain.
5. **Every guarantee stated in an error message must be a predicate** (I3) — and every
   soundness argument that is "obvious" must be written down with its breaking change
   named (G8, G9).
