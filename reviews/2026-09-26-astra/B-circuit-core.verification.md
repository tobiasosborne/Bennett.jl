# Independent verification — B-circuit-core (F1–F15) — 2026-09-26

Verifier: independent re-execution of the reviewer's reproducers in `B-circuit-core.md`.
Environment: Julia 1.12.3, `julia --project --check-bounds=yes --compiled-modules=existing`, repo root, HEAD `a3241d7`.
No file under `src/` or `test/` was modified; no `bd`, no commit, no full suite.
Probe scripts lived in the session scratchpad (`p1.jl` F1–F4, `p2.jl` F5–F10, `p3.jl` F11–F15); each
expression was wrapped in a `try` that printed `repr(value)` or `THROWS: <message>`. The constructor
calls were copied verbatim from the report; **none of them hit a MethodError** (the 8-/9-positional
`LoweringResult` forms, the 7-positional `GateGroup`, `LoopGuard(wire,label,K)` and the 7-positional
`ReversibleCircuit` all match `src/lowering/types.jl` / `src/gates.jl`).

## Summary

| F# | Verdict | Severity agree? | Note |
|----|---------|-----------------|------|
| F1 | CONFIRMED | Yes (S0) | `(true, 1, 2)` exactly: redefined `g` returns the stale cached circuit, silently. |
| F2 | CONFIRMED | Yes (S0) | expression 4 vs auto/tabulate 1 (both -2 and 14); unsigned witness 0x0 vs 0xc, all verify `true`. |
| F3 | CONFIRMED | Yes (S0) | expression `([16],400)` vs tabulate `([8],-112)`. |
| F4 | CONFIRMED | Yes (S0) | `(0xff, -1)`; secondary probe `(-1, 0xffff, 0xff)` exactly. |
| F5 | CONFIRMED | Yes (S0), caveat | Default 2, Checkpoint 1, PebbledGroup(1) 1, Checkpoint verify `true`. Hand-built LR; not shown reachable from `lower()`. |
| F6 | CONFIRMED | Yes (S0) | Both probes print `0` silently; F6a is on the public API with a real 64-bit circuit. |
| F7 | CONFIRMED | Partly (S1 fits better) | `(0,true)`, `(0,true)`, width-0 verify `true` while simulate rejects. Needs malformed hand-built metadata, so "unsound acceptance" (S1) fits better than S0. |
| F8 | CONFIRMED | Partly (S1 fits better) | Default throws the Bennett-s0tn error; all 5 other strategies return `(0, 1)`. Contradictory hand-built metadata, so unsound acceptance (S1). |
| F9 | CONFIRMED | Yes (S1) | Toy throws `wire 3`; production QCLA lowering: Julia 3, Default 3, Eager throws `wire 26`; gates 11/26/28/29 match. |
| F10 | CONFIRMED | Yes (S1) | Default 1; ValueEager throws `Ancilla wire 2 not zero`. |
| F11 | CONFIRMED | Yes (S1), borderline | `bennett` accepts the claim and emits 3 gates; `simulate(c,2)` throws `wire 6`. Default-budget `verify_reversibility` also catches it (test 2). |
| F12 | CONFIRMED | Yes (S1) | n=1 throws; n=0 and n=-1 return `true`; the `controlled` overload also returns `true` at 0/-1. |
| F13 | CONFIRMED | Yes (S1) | verify `true`; `CNOT(1,1)` zeroes `Bool[true]` after one application as well as after two. |
| F14 | CONFIRMED | No (S2 fits better) | Both nodes `preds=[]`; fwd `[0,1]` vs reversed `[0,0]`. But `extract_dep_dag` has no callers in `src/` and is not exported. |
| F15 | CONFIRMED | Yes (S1) | extract gives 8; `reversible_compile(Fun(),Int8)` gives the claimed MethodError on `_extract_parsed_ir_cached(::Fun, ...)`. |

"Already tracked?" claims: every named bead id exists and its title matches the claimed topic (details below).
Keyword searches of open beads (`tabulat`, `dep_dag`, `redefin|world.?age`, `n_tests`, `callable|functor`,
`duplicate.*input`, `loop.?guard.*fast.?path`, `controlled.*signed`, checkpoint/result-order) found no bead
that covers F1–F9, F12, F14 or F15. So the "no matching open bead" claims hold.

## Per-finding details

### F1: CONFIRMED
```
g(x::Int8)=x+Int8(1); c1=reversible_compile(g,Int8); @eval g(x::Int8)=x+Int8(2)
c2=reversible_compile(g,Int8); (c1===c2, simulate(c2,Int8(0)), g(Int8(0)))
=> (true, 1, 2)
```
S0 is right: no error, stale function. Beads: `Bennett-uiaq` (closed, "Wire reversible_compile(f, types) through sr8v cache transparently") and `Bennett-sr8v` (closed, "Src-level cache: memoise reversible_compile(parsed::ParsedIR)") exist and match. No open bead mentions redefinition or world age.

### F2: CONFIRMED
```
fn(x::Int8)=ifelse(x<Int8(0),x*x,Int8(1)); bit_width=4, optimize=false
strategy=:expression  input=-2 => 4    input=14 => 4
strategy=:auto        input=-2 => 1    input=14 => 1
strategy=:tabulate    input=-2 => 1    input=14 => 1
fu(x::UInt8)=(x*x)>>2; bit_width=4, optimize=false, input UInt8(7)
:expression => 0x0000000000000000  (verify true)
:auto       => 0x000000000000000c  (verify true)
:tabulate   => 0x000000000000000c  (verify true)
```
Matches the claim. The output is decoded as `UInt64` (`0x000…0c`), where the report writes `0xc`; the value is the same. Which W-bit semantics is "correct" is arguably up to the definition. Still, `:auto` silently producing a different function from `:expression` is S0. `Bennett-g7d6` exists (open, narrow.jl drops globals) and is a different topic, as the report says.

### F3: CONFIRMED
```
f3(x::Int8)=Int16(x)*Int16(x)
:expression => ([16], 400)      :tabulate => ([8], -112)
```
S0 is right.

### F4: CONFIRMED
```
c=reversible_compile(identity,UInt8;strategy=:expression); (simulate(c,0xff), simulate(controlled(c),true,0xff))
=> (0xff, -1)
f8(x::UInt16)=x%UInt8; c8=...; (simulate(c8,0xffff), simulate(c8,UInt16,0xffff), f8(0xffff))
=> (-1, 0xffff, 0xff)
```
S0 is right. `Bennett-zc50` (closed, "U100: simulate loses signedness…") exists and matches the claim that it fixed the uncontrolled path only.

### F5: CONFIRMED
```
lr = LoweringResult(ReversibleGate[CNOTGate(1,2)], 3, [1], [3,2], [1], [2],
       [Bennett.GateGroup(:a,1,1,[3,2],Symbol[],2,3)], false)
Default => 2   CheckpointStrategy() => 1   PebbledGroupStrategy(1) => 1
verify_reversibility(Checkpoint circuit) => true
```
S0 is plausible: `GateGroup` has no documented ascending-order contract, and the result is silently wrong while the verifier says `true`. Caveat: the fixture is hand-built, and the report does not show real lowering emitting non-ascending `result_wires`.

### F6: CONFIRMED
```
c=reversible_compile(identity,UInt64;strategy=:expression); simulate(c, UInt128(1)<<64)   => 0x0000000000000000
c=ReversibleCircuit(128, ReversibleGate[], collect(1:128), collect(1:128), Int[], [128], [128]);
simulate(c, UInt128(1)<<100)                                                                => 0x0000000000000000
```
S0 is right for the first probe, which uses the public API and silently wraps. The 128-bit element case needs a hand-built circuit.

### F7: CONFIRMED (severity: S1 fits better)
```
c=ReversibleCircuit(2, ReversibleGate[CNOTGate(1,2)], [1,1], [2], Int[], [1,1], [1]); (simulate(c,(1,0)), verify_reversibility(c))
=> (0, true)
c=ReversibleCircuit(3,ReversibleGate[NOTGate(3)],[1],[2,3],Int[],[1],[1]); (simulate(c,0),verify_reversibility(c))
=> (0, true)
c=ReversibleCircuit(2,ReversibleGate[CNOTGate(1,2)],[1],[2],Int[],[0],[1])
verify_reversibility(c) => true ; simulate(c,0) => ArgumentError: simulate: input 1 has width 0 (must be > 0)
```
All three sub-claims reproduce. Every witness is malformed constructor metadata, which the compiler never produces. So this is "unsound acceptance / verifier certifies a malformed circuit" (S1), not a wrong result on valid input. `Bennett-6azb` exists (closed, "U58: Simulator does not verify Bennett input-preservation invariant") and matches.

### F8: CONFIRMED (severity: S1 fits better)
```
lr() = LoweringResult(ReversibleGate[CNOTGate(1,2)], 3, [1], [2], [1], [1], Bennett.GateGroup[], true, [Bennett.LoopGuard(3,:L,1)])
Default                 => THROWS: bennett: lr.self_reversing=true but lr.loop_guards is non-empty (1 guard(s)) ... (Bennett-s0tn)
EagerStrategy()         => (0, 1)
ValueEagerStrategy()    => (0, 1)
CheckpointStrategy()    => (0, 1)
PebbledStrategy(2)      => (0, 1)
PebbledGroupStrategy(2) => (0, 1)
```
Reproduces exactly. The input is contradictory metadata that Default already treats as invalid, so the real defect is that strategies accept an invalid LoweringResult inconsistently (S1). It would be S0 only if `lower()` could emit `self_reversing=true` together with loop guards, which the report does not show. `Bennett-rjk7` exists (closed, "Auto self_reversing: extend fast-path to non-default Bennett strategies") and matches.

### F9: CONFIRMED
```
lr=LoweringResult(ReversibleGate[CNOTGate(1,3), NOTGate(1), CNOTGate(1,3)], 3, [1], [2], [1], [1])
Default in=0 => 0 ;  Eager in=0 => THROWS Ancilla wire 3 not zero post-circuit ; Eager in=1 => same throw
f(x::Int8)=(x+Int8(3))*(x+Int8(1)); lr=Bennett.lower(extract_parsed_ir(f,Tuple{Int8};optimize=false);add=:qcla,fold_constants=false)
f(-128) => 3 ; Default => 3 ; Eager => THROWS Ancilla wire 26 not zero post-circuit
gates[11,26,28,29] => ToffoliGate(8,17,26), ToffoliGate(25,17,26), ToffoliGate(24,29,26), ToffoliGate(22,30,26)
```
Reproduces exactly, including the production-lowering witness. It crashes loudly rather than returning a silent wrong answer, so S1 is right.

### F10: CONFIRMED
```
gates=[CNOTGate(1,2), CNOTGate(2,3)]; groups=[GateGroup(:a,1,1,[2],Symbol[],2,2), GateGroup(:b,2,2,[3],[:a],3,3)]
lr=LoweringResult(gates,3,[1],[1],[1],[1],groups,false)
Default => 1 ; ValueEager => THROWS Ancilla wire 2 not zero post-circuit
```
S1 is right. `Bennett-htu2` exists (open, "Possible ValueEager leak: a group cleaned early as dead never releases its dependencies' consumer counts") and matches exactly.

### F11: CONFIRMED (borderline S1/S2)
```
lr=LoweringResult(ReversibleGate[CNOTGate(1,5), CNOTGate(2,6), CNOTGate(3,6)], 6, [1,2,3,4], [5], [4], [1], Bennett.GateGroup[], true)
c=Bennett.bennett(lr): length(c.gates) => 3
simulate(c,2) => THROWS Ancilla wire 6 not zero ; simulate(c,0) => 0 ; simulate(c,15) => 1
verify_reversibility(c) (default budget) => THROWS (test 2): ancilla wire 6 not zero after forward pass
```
Reproduces. As the report itself says, the fast-path check accepts the claim but downstream checks catch it; the default verifier budget catches it too. S1 ("unsound acceptance") is defensible. Beads `Bennett-lxk7` (open, "U03: extend probe battery from 4 deterministic to 4 + 8 randomised inputs") and `Bennett-egu6` (closed, "U03: self_reversing=true is an unchecked trust boundary") exist and match.

### F12: CONFIRMED
```
c=ReversibleCircuit(3, ReversibleGate[NOTGate(3)], [1], [2], [3], [1], [1])
n_tests=1 => THROWS (test 1): ancilla wire 3 not zero ; n_tests=0 => true ; n_tests=-1 => true
cc=controlled(c): n_tests=0 => true ; n_tests=-1 => true ; n_tests=50 => THROWS (test 3)
```
S1 (vacuous verifier) is right. Side note, not a report claim: `verify_reversibility(controlled(c); n_tests=1)` returned `true` in one run, because the dirtying only happens when the random control is 1. Small positive budgets on controlled circuits can pass by chance. `Bennett-asw2` exists (closed, "U01: verify_reversibility is tautological") and matches.

### F13: CONFIRMED
```
c=ReversibleCircuit(1, ReversibleGate[CNOTGate(1,1)], Int[], [1], Int[], Int[], [1]); verify_reversibility(c) => true
apply! CNOTGate(1,1) twice on Bool[true] => Bool[0]   (a single application already gives Bool[0])
```
S1 is right. `Bennett-lcye` exists (open, "gates.jl hardening: reject CNOTGate(c,c) and Toffoli with target ∈ controls at construction") and matches.

### F14: CONFIRMED (severity: S2 fits better)
```
c=Bennett.bennett(LoweringResult(ReversibleGate[CNOTGate(1,2), NOTGate(1)],2,[1],[2],[1],[1]))
c.gates => [CNOTGate(1,2), NOTGate(1), CNOTGate(2,3), NOTGate(1), CNOTGate(1,2)]
extract_dep_dag(c).nodes => DAGNode(1, Int64[], Int64[], 2), DAGNode(2, Int64[], Int64[], 1)
forward gates 1:2 on Bool[1,0] => [0,1] ; reversed => [0,0]
```
Reproduces: the DAG has no edge for the write-after-read. However, `grep -rn extract_dep_dag src` finds no caller outside `src/dep_dag.jl`, and the function is not exported. The report concedes it is not a demonstrated miscompile. A wrong but unused analysis is S2 (latent), not S1.

### F15: CONFIRMED
```
struct Fun end; (::Fun)(x::Int8)=x+Int8(1)
extract_parsed_ir(Fun(),Tuple{Int8}).ret_width => 8
reversible_compile(Fun(),Int8) => MethodError: no method matching _extract_parsed_ir_cached(::Fun, ::Type{Tuple{Int8}}; optimize::Bool, mem::Symbol)
```
Confirmed: `src/extract/callees.jl:52` has the signature `_extract_parsed_ir_cached(f::Function, ...)`, while `reversible_compile(f, arg_types)` at `src/Bennett.jl:281` is untyped. It crashes on valid input, so S1 is right. (My extra closure probe used a non-constant global, not a capture, so it tested something else and is omitted.)
