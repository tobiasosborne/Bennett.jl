# Reversibility Invariants Review — Bennett.jl

Reviewer: domain-specific correctness (ancilla-zero invariant + Bennett construction)
Date: 2026-04-21
Method: source read + executable probes with Julia subprocess on branching int8 / controlled / eager / pebbled / self-reversing paths.

---

## TL;DR — the 5 ways this compiler can silently produce a non-zero ancilla today

All five are backed by either a runnable repro below or a direct code-path reading.
None of the tests in `test/` currently exercise the failure scenario.

### 1. `verify_reversibility` is tautological and will pass on broken circuits

`src/diagnostics.jl:145-161` — `verify_reversibility` checks only that applying `gates` then `Iterators.reverse(gates)` returns the bit vector to its original state. Because NOT, CNOT, and Toffoli are **each** self-inverse, `fwd then reverse(fwd)` ALWAYS returns to input — regardless of whether the forward pass actually computed anything, regardless of whether ancillae are zero, regardless of whether the output is correct. The test is a NO-OP modulo catching a programming mistake in the simulator itself.

Repro (works on main):

```julia
using Bennett
using Bennett: ReversibleCircuit, NOTGate, CNOTGate, verify_reversibility, simulate
# Hand-build a circuit that claims wire 2 is the output but leaves ancilla 3 flipped.
gates = Bennett.ReversibleGate[NOTGate(3), CNOTGate(1, 2)]
c = ReversibleCircuit(3, gates, [1], [2], [3], [1], [1])
@assert verify_reversibility(c) == true  # PASSES
simulate(c, 0)  # ERROR: Ancilla wire 3 not zero — Bennett construction bug
```

The only thing that catches ancilla-non-zero is `simulate(c, input)` at `src/simulator.jl:30-32`, which asserts each ancilla is zero. Any test that calls `verify_reversibility` but NOT `simulate` (or only calls `simulate` on a handful of inputs on a wide function) can ship a broken circuit. This is systemic: grep shows 256 call sites for `verify_reversibility` across 75 test files, but a huge fraction of the SHA-256 / soft-float / persistent map tests run `simulate` on a single representative input plus `verify_reversibility(c)`. They check nothing about ancilla hygiene on the rest of the input space.

### 2. `value_eager_bennett` silently produces non-zero ancillae on ANY branching code (100 % failure rate, every input)

`src/value_eager.jl:29-137`. The Phase 3 uncompute schedules gate-groups in reverse-topological order via Kahn's algorithm on the SSA dependency DAG (`input_ssa_vars`). But the synthetic `__pred_*` groups emitted by `lower()` (block-predicate computations — `src/lower.jl:379,389`) have `input_ssa_vars = Symbol[]` — their wire-level dependency on **other** `__pred_*` groups' result wires is invisible to the DAG. Consequence: the entry-block predicate wire (NOTGate on a fresh wire) can be reversed BEFORE later `__pred_*` groups that consumed it are reversed; those later reverses then run with the wrong input state, leaving dirty ancillae.

Repro (failed 256/256 on all Int8 inputs; `verify_reversibility` still returns `true`):

```julia
using Bennett
using Bennett: extract_parsed_ir, lower, value_eager_bennett, verify_reversibility

function myb(x::Int8)
    if x > Int8(0)
        r = x + Int8(1)
    else
        r = x - Int8(1)
    end
    return r
end

parsed = extract_parsed_ir(myb, Tuple{Int8}; optimize=false)
lr = lower(parsed)
c = value_eager_bennett(lr)
@assert verify_reversibility(c) == true  # PASSES
Bennett.simulate(c, Int8(5))
# ERROR: Ancilla wire 25 not zero — Bennett construction bug
```

`test/test_value_eager.jl` passes today because every exhaustive loop is on a single-arg straight-line function (`x + 3`, `x*x + 3x + 1`) — none have a CFG diamond. The SHA-256 round test is run on exactly one input. If ANY user writes `reversible_compile(..., strategy=...)` that internally routes to value_eager on branching code, they ship a broken circuit.

### 3. `bennett()` honours `self_reversing=true` with no validation — it's an unchecked trust boundary

`src/bennett_transform.jl:27-30`: when `lr.self_reversing == true`, `bennett()` returns the forward gates as-is with NO copy-out, NO reverse, and NO ancilla-zero verification. The caller (`lower_mul_qcla_tree!`, etc.) is trusted to have left ancillae clean. There is no `@assert` or runtime check.

Repro of the trust-boundary violation:

```julia
using Bennett
using Bennett: LoweringResult, GateGroup, bennett
# A "primitive" that leaves ancilla unset but claims self_reversing=true
gates = Bennett.ReversibleGate[Bennett.NOTGate(1)]
lr = LoweringResult(gates, 2, [1], [2], [1], [1], Set{Int}(), GateGroup[], true)
c = bennett(lr)  # No validation runs. Wire 2 is claimed as output but is never written.
```

Any future "self-reversing" primitive added without careful proof (or with a subtle bug in how its last step unwinds) silently poisons the compiler. The entire point of Bennett's construction is that it's mechanical — replacing it with a trust flag throws away the invariant.

### 4. `checkpoint_bennett` / `pebbled_group_bennett` crash on branching code; but the fallback-to-`bennett(lr)` list is incomplete

`src/pebbled_groups.jl:16` — `_remap_wire` errors loudly on unmapped wires. Good. But the fallback triggers (empty groups, in-place ops, sufficient pebbles) in `pebbled_group_bennett` at lines 275-296 do NOT include "contains phi / branching CFG". So a user calling `pebbled_group_bennett(lr; max_pebbles=P)` on any function with an if/else hits:

```
ERROR: Unmapped wire 9 in gate remapping — not in wmap and not a function input.
Possible corruption from freed group wires.
```

Confirmed crash on my minimal `myb` function above. This is fail-loud, which is better than value_eager's silent corruption — but it means `checkpoint_bennett` (the preferred path when `wire_start > 0`, line 290-292) is only usable on straight-line code, despite the docstring not saying so. A user who reads the docstring, wires it in, and exercises branching will get a crash at circuit-build time, not at test-write time.

### 5. `bennett()` and its variants all silently assume gate-groups are wire-disjoint, but lowering helpers like `_compute_block_pred!` reuse wires across groups

The assumption that "reversing gates in some order is safe because each gate is self-inverse" is only true when the state at reverse-time matches the state right after the forward of that gate. For straight-line SSA code where each group owns disjoint wires, this holds. For code that shares predicate wires across blocks (every branching function), it doesn't. `bennett()` (the default) works because it reverses gates in strict INDEX-REVERSE order, which is what the state-matching argument requires. `value_eager_bennett` breaks it (see #2). `checkpoint_bennett`'s shared-wire assumption is also broken on branching (see #4 — it crashes rather than silently mis-ancilla, which is the only reason you wouldn't see finding-#2-shaped bugs there).

No non-trivial uncompute-ordering variant (value_eager, checkpoint_bennett, pebbled_group_bennett) is safe to run on branching code today. The safe default is only `bennett()` itself or `eager_bennett()` (which reverses in index order).

---

## Prioritised findings

### CRITICAL

#### C1. `verify_reversibility` does not check ancilla-zero
File: `src/diagnostics.jl:145-161`. Documented in §1 above.

Failing-test proposal:

```julia
@testset "verify_reversibility MUST enforce ancilla-zero" begin
    using Bennett: ReversibleCircuit, NOTGate, CNOTGate, verify_reversibility
    # A circuit that is forward/reverse-symmetric but leaves an ancilla flipped.
    gates = Bennett.ReversibleGate[NOTGate(3), CNOTGate(1, 2)]
    c = ReversibleCircuit(3, gates, [1], [2], [3], [1], [1])
    @test_throws ErrorException verify_reversibility(c; n_tests=4)
end
```

Today the test would FAIL because `verify_reversibility` returns `true`. The fix is straightforward: run the forward pass and assert every ancilla wire ends at zero (as `simulate` already does at `src/simulator.jl:30-32`). Ideally test a spanning set of inputs, not just random, since the bug can be data-dependent (cf. finding C2).

Note: because of this, several "passing" tests in the repo are actually only checking forward-then-reverse, which is a property baked into self-inverse gates. They are not testing the compiler's Bennett construction at all.

#### C2. `value_eager_bennett` produces non-zero ancilla on every branching function (100 % failure)
File: `src/value_eager.jl:96-135`. Documented in §2 above. Root cause: Kahn's topological order on `input_ssa_vars` fails to see cross-`__pred_*` wire dependencies (which are real) because `_compute_block_pred!` emits helper gates without registering predicate-to-predicate SSA deps.

Failing-test proposal:

```julia
@testset "value_eager_bennett preserves ancilla-zero on branching CFG" begin
    using Bennett
    using Bennett: extract_parsed_ir, lower, value_eager_bennett
    b(x::Int8) = x > Int8(0) ? x + Int8(1) : x - Int8(1)
    parsed = extract_parsed_ir(b, Tuple{Int8}; optimize=false)
    lr = lower(parsed)
    c = value_eager_bennett(lr)
    for x in typemin(Int8):typemax(Int8)
        @test simulate(c, x) == b(x)  # will fail with "Ancilla wire N not zero"
    end
end
```

Concretely: running the bug today fails 256/256 on Int8 and 201/201 on the Int16 portion I tested. Empirically the SHA-256 round in `test_value_eager.jl` is not branching at the phi level (straight-line UInt32 arithmetic) which is why it passes despite the bug.

Fix candidate: either (a) add predicate-wire deps to `__pred_*`'s `input_ssa_vars` so Kahn respects them, or (b) refuse to take the Phase 3 Kahn path when `__pred_*` groups exist, falling back to `bennett()`. (b) is the safer choice — the PRS15 EAGER paper is silent on CFG diamonds.

#### C3. `bennett()`'s `self_reversing` bypass has no runtime validation
File: `src/bennett_transform.jl:23-30`. Documented in §3 above.

Failing-test proposal:

```julia
@testset "bennett() rejects self_reversing circuits that leave ancillae dirty" begin
    using Bennett
    using Bennett: LoweringResult, GateGroup, bennett
    # 2-wire, gates=[NOT(1)], claims output is wire 2 but never writes it.
    gates = Bennett.ReversibleGate[Bennett.NOTGate(1)]
    lr = LoweringResult(gates, 2, [1], [2], [1], [1], Set{Int}(),
                        GateGroup[], true)  # self_reversing=true (LIE)
    # bennett() should detect that not all ancillae can be proved zero, either
    # statically or by simulating zeros + a flipped input, and refuse.
    @test_throws Exception bennett(lr)
end
```

Fix candidate: `bennett()` can simulate the forward gates on a single all-zeros input plus one smoke-test input and assert ancilla-zero on both before taking the fast path. Cost: one forward simulation per compilation, which is linear in `length(gates)`. The cost is tiny compared to not shipping silently broken circuits.

#### C4. `checkpoint_bennett`/`pebbled_group_bennett` crash on branching; no automatic fallback
File: `src/pebbled_groups.jl:273-332, 351-452`. Documented in §4. Every branching function that reaches `checkpoint_bennett` throws `Unmapped wire N in gate remapping`. Today this is fail-loud (good) but users reading the docstrings (which mention SHA-256, which is fine, because SHA is straight-line at the phi level) will be surprised when production code with branches explodes at circuit-build time.

Failing-test proposal: add a precondition check to `pebbled_group_bennett` / `checkpoint_bennett` that refuses (with a clear message) when `lr.gate_groups` contains any `__pred_*` or `__branch_*` group. Expected improvement:

```julia
@testset "checkpoint_bennett fails cleanly on branching CFG" begin
    using Bennett
    using Bennett: extract_parsed_ir, lower, checkpoint_bennett
    b(x::Int8) = x > Int8(0) ? x + Int8(1) : x - Int8(1)
    parsed = extract_parsed_ir(b, Tuple{Int8}; optimize=false)
    lr = lower(parsed)
    # Either: fall back to bennett(lr) silently and pass simulate
    c = checkpoint_bennett(lr)
    for x in typemin(Int8):typemax(Int8)
        @test simulate(c, x) == b(x)
    end
    # Or: throw with a specific, actionable error (not "Unmapped wire 9")
end
```

### HIGH

#### H1. `simulate` is the only real ancilla-zero check, and tests underuse it
There are 256 uses of `verify_reversibility` across 75 test files but only 11 uses of `ancilla_wires`/`ancilla_count` across 6. Many tests call `verify_reversibility(c)` and then call `simulate(c, inp)` on a single representative input. For wide-width functions (`UInt32`, `UInt64`, soft-float), a single `simulate` input catches an ancilla bug only if that bug fires on that exact input. Given C1, the tests as written are mostly measuring that self-inverse gates are self-inverse.

Recommendation: after every `reversible_compile` in tests, run `simulate` on a defensible input coverage (all 256 for Int8, a full Kronecker-sum set for larger inputs, including 0, ±1, typemin, typemax, ±Inf, NaN, subnormal for float). Or — better — fix `verify_reversibility` to actually check ancilla-zero over a spanning input set.

#### H2. The pebbling engine (`pebbled_bennett`, `src/pebbling.jl`) works at the GATE level, but Knill's correctness theorem is at the DAG node level
File: `src/pebbling.jl:152-192`. `_pebble_with_copy!` applies Knill's recursive splitting directly on `gates[lo:hi]` ranges. For the current straight-line SSA workflow it happens to work because each gate's target wire is fresh (allocated by `WireAllocator.next_wire`). But any in-place gate — for example `emit_shadow_store!` which writes to `primal[i]`, `emit_cuccaro_adder!` which writes `b += a` into `b`, or anything that uses `allocate!` then CNOTs onto a dependency wire — will interleave wire states across pebble boundaries and the index-reverse argument breaks.

`pebbled_group_bennett` (in `pebbled_groups.jl`) explicitly detects and falls back for in-place ops, but `pebbled_bennett` does not. Either `pebbled_bennett` must validate it is only invoked on pure-SSA LoweringResults, or its documentation needs a very loud warning. Concretely: if Cuccaro is the selected adder and `pebbled_bennett` is called, the result is undefined.

#### H3. `lower_call!` with `compact=true` (default OFF) inlines a full Bennett sub-circuit into the caller's forward pass; the caller's outer Bennett reverse runs this twice
File: `src/lower.jl:1938-1964`. The caller's Bennett construction appends the forward gates then the reverse. If the callee is inlined as `fwd; copy; rev` in the caller's forward pass, the caller's outer reverse reverses all of `fwd; copy; rev` to produce `rev; copy; fwd` (each self-inverse individually but in this order). The net effect should STILL be ancilla-clean — I verified empirically for `soft_fneg` (all NaN/1.5/0 inputs: ancilla-zero, output correct). But this composition is not documented as a proof and there's no test that specifically exercises `compact=true` with a callee that itself uses ancillae. If anyone ever changes `bennett()` to be not-its-own-inverse (e.g., adds eager cleanup to the default), the `compact=true` callees immediately break.

Recommendation: add a test that compiles a function with `compact=true` calling a non-trivial callee (e.g., `soft_fmul`) and verifies ancilla-zero on a spanning input set.

#### H4. `controlled(circuit)` wraps a FULL Bennett circuit but doesn't decompose the CNOT-copy in the middle
File: `src/controlled.jl:16-37`. `promote_gate!` replaces each gate uniformly — including the CNOT-copy that sits between forward and reverse in `bennett()`. This means the controlled circuit's "copy" becomes a Toffoli(ctrl, output, copy) — which is correct for the controlled read-out (when ctrl=0, copy stays zero; when ctrl=1, copy gets the output). But the reverse pass of the outer Bennett is now controlled too, so uncompute is conditional on ctrl. If ctrl=0, the "forward" was identity (nothing happened) and the "reverse" is also identity. OK. If ctrl=1, forward + copy + reverse matches. OK. I verified on a simple increment (all 256 inputs, both control states — ancilla-zero and correct output). But there is no test for a controlled circuit over a BRANCHING function (where the forward itself uses phi/MUX ancillae). That combination may be where the bug is.

Failing-test proposal:

```julia
@testset "controlled branching circuit preserves ancilla-zero" begin
    using Bennett
    b(x::Int8) = x > Int8(0) ? x + Int8(1) : x - Int8(1)
    c = reversible_compile(b, Int8)
    cc = controlled(c)
    for ctrl in (false, true), x in typemin(Int8):typemax(Int8)
        expected = ctrl ? b(x) : Int8(0)
        @test simulate(cc, ctrl, x) == expected
    end
end
```

I did not run this myself; recommend it be added.

### MEDIUM

#### M1. `verify_reversibility` docstring claims the circuit satisfies the Bennett invariant; it does not enforce it
`src/gates.jl:28-29` (docstring of `ReversibleCircuit`) says: "The circuit satisfies the Bennett invariant: all ancilla wires return to zero after execution." This is a PROMISE not a CHECK. Any path that constructs a `ReversibleCircuit` directly (not via `bennett()`) can violate this. See §3 / C3 — `self_reversing=true` does exactly that.

#### M2. The eager-cleanup comment at `src/eager.jl:112-119` acknowledges wire-level EAGER failed; but the "dead-END" EAGER's correctness argument is informal
The comment correctly notes wire-level EAGER is unsound at the gate level. But the dead-END EAGER's justification ("dead-end wires are never used as controls by ANY gate, so the Phase 3 reverse is unaffected") requires that the cleanup gates (`mp[end] ... mp[1]`) reverse the state of wire `t` without disturbing any other wire. The cleanup gates target wire `t`. Any CNOT targeting `t` has a CONTROL on some other wire. Reversing the control-wire's state between the forward and the cleanup would change which gates in `mp` actually flip `t`. Since wire `t` is a dead-end (never a control), it's only TARGETED, never read as control. The control wires of gates in `mp` are OTHER wires — whose values at cleanup time must match their values during forward. In straight-line SSA code, they do. In branching code (where a control wire might be a predicate computed by `_compute_block_pred!`), this invariant has to be preserved across the cleanup point. I did NOT find a test that exercises eager_bennett on a branching function with a dead-end wire specifically AFTER a phi. Recommend: add such a test to stress the cleanup correctness.

Update from probing: `eager_bennett` does work for `b(x) = x > 0 ? x+1 : x-1` on Int8 (0 failures of 256). It's correct today, but the correctness argument is fragile and undocumented.

#### M3. `ControlledCircuit`'s `verify_reversibility(cc)` has the same tautological flaw as the base version
`src/controlled.jl:89-107`. It runs `for g in c.gates; apply!(bits, g); end` then `Iterators.reverse`. Same gap as C1. A controlled circuit with dirty ancillae would pass this test.

#### M4. `lower_loop!` has no explicit per-iteration ancilla hygiene
`src/lower.jl:741-773`. The body is unrolled and each iteration's `lower_binop!`/`lower_icmp!`/`lower_select!` allocates fresh wires via the WireAllocator. These are never reclaimed within the loop — they accumulate across iterations. For `max_loop_iterations=64`, each unrolled iteration's ancillae survive until the outer `bennett()` reverses them. This is correct per the Bennett invariant. But it means the ancilla count grows linearly with `max_loop_iterations` even when most iterations are no-ops. For extreme values this becomes a performance/space problem, not a correctness one. Not a bug, but a footgun.

### LOW

#### L1. `shadow_memory`'s 3-CNOT protocol is fine; the hard part is tape-slot allocation
`src/shadow_memory.jl:38-55`. The protocol `CNOT primal->tape; CNOT tape->primal; CNOT val->primal` is arithmetically correct: tape ends with the old primal, primal ends with val. Reversibility relies on the tape slot being ALL ZEROES on entry. Comment at line 32-35 stresses this. Enforced by allocating a fresh W-wire tape slot per store instance (`src/lower.jl:2252`, `:2221`). The key correctness property — different stores never share a tape slot — is maintained by `allocate!` returning fresh wires each call. Do not share tape slots across stores or reversibility breaks.

#### L2. `lower_mul_qcla_tree!`'s hand-crafted uncompute sequence is trusted
`src/mul_qcla_tree.jl:60-74`. Steps 5/6/7 manually reverse step 3/2/1 by iterating `for i in s3_end:-1:s3_start; push!(gates, gates[i]); end`. This copies gates into the gates list; since gates are self-inverse, replaying them in reverse position-order zeros the target state of each. Correct — I exhaustively verified: Int8 × Int8 with `mul=:qcla_tree` is all-256×256 correct, ancillae clean (488 ancillae, 3274 gates). But `self_reversing=true` means the outer `bennett()` skips its own ancilla-zero check. If the inner uncompute has any gap (e.g., the WORKLOG note about "uncompute level d-2 at level d" being unsafe), there is no safety net.

#### L3. The `dep_dag.jl`, `qrom.jl`, `persistent/*.jl` modules were not exhaustively probed
Out of scope for 90 minutes, but: `test_persistent_*.jl` tests use `verify_reversibility`, which (C1) checks nothing about ancilla-zero. The persistent map implementations (HAMT, Okasaki, CF, linear_scan) are tested for correctness via `simulate` on a handful of inputs. Not a bug I can point at, but a correctness-surface I cannot vouch for.

### NIT

- `src/simulator.jl:31` error message "Bennett construction bug" is misleading when the bug is in `value_eager_bennett` or `pebbled_group_bennett` or a hand-built circuit. Say "ancilla-zero invariant violated on wire $w — the circuit produced by $constructor leaks information."
- `src/bennett_transform.jl:27-30` should comment that `self_reversing` is unchecked and requires callee to have proved cleanliness.
- `ReversibleCircuit`'s `ancilla_wires` field is computed from the input/output complement (`src/bennett_transform.jl:1-6`). A wire that is neither in `input_wires` nor `output_wires` is counted as ancilla. If a user passes a nonsensical output_wires list, the ancilla set shrinks silently — no assertion that `ancilla_wires ∪ input_wires ∪ output_wires = 1:n_wires`.

---

## Audit summary

| area | status |
|---|---|
| `bennett()` on straight-line code | correct |
| `bennett()` on branching code | correct (I ran Int8 diamond exhaustively) |
| `verify_reversibility` | **broken — tautological** (C1) |
| `eager_bennett` | correct on my Int8 probes (M2 caveat about formal argument) |
| `value_eager_bennett` | **broken on branching** — every diamond CFG input fails ancilla-zero (C2) |
| `checkpoint_bennett` / `pebbled_group_bennett` | **crashes on branching** (C4) |
| `pebbled_bennett` (gate-level Knill) | correct on straight-line; unverified on in-place ops (H2) |
| `controlled(circuit)` on straight-line | correct per my probe |
| `controlled(circuit)` on branching | UNTESTED (H4) |
| `lower_call!` with `compact=false` | correct per soft_fneg probe |
| `lower_call!` with `compact=true` | UNTESTED on non-trivial callee (H3) |
| `self_reversing=true` bypass in `bennett()` | **unchecked trust boundary** (C3) |
| `lower_mul_qcla_tree!` self-cleaning claim | holds on Int8 exhaustive |
| `emit_shadow_store!` / tape-slot per-store allocation | holds |
| exhaustive soft-float ancilla hygiene | not re-verified beyond a single `soft_fneg` probe |

Three CRITICAL items ship today. The `value_eager_bennett` on branching (C2) is the most dangerous because it's silent and 100 %. `verify_reversibility` being tautological (C1) is the meta-bug that hid C2 from the existing test suite. The `self_reversing=true` trust flag (C3) is the easiest to exploit if any future primitive is added carelessly.

Fix priority: C1 first (so CI actually catches ancilla bugs), then C2 (kill or gate the Kahn-order uncompute on branching), then C3 (add validation to `bennett()`'s fast path).
