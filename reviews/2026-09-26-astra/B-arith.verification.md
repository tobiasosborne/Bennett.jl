# Verification — B-arith — 2026-09-26

Independent re-execution of `B-arith.md` F1–F5 (S0/S1) and dedup of F1–F15 against
`B-circuit-core.triage.md`, `B-lowering.md` (partial) and `.beads/issues.jsonl`.
All probes: `julia --project --check-bounds=yes --compiled-modules=existing <scratch>.jl`
from the repo root. No src/test edits, no `bd`, no commit, no full suite.
F6–F15 were NOT re-executed (dedup only; F14 checked by code trace).

## Summary

| F# | Verdict | Severity ok? | Dedup status | Note |
|---|---|---|---|---|
| F1 QROM free-list → compact callee | CONFIRMED (byte-exact) | S0 yes | DUPLICATE-OF Bennett-9k7n + B-lowering F7 | Same root cause (call.jl contiguous `wire_count` offset). Lowering F7's public `reversible_compile(ParsedIR)` witness also re-run: `(65,true)`, 192/256 wrong. Arith adds only the direct-primitive witness + noncompact numbers. |
| F2 tabulate truncates return width | CONFIRMED | S0 yes | DUPLICATE-OF Bennett-iwj6 (core F3) | Identical witness (`Int16(x)*Int16(x)`, -112 vs 400). |
| F3 tabulate ≠ narrowed semantics | CONFIRMED | S0 yes | DUPLICATE-OF Bennett-iwj6 (core F2) | New witness `(x*x)>>1, W=2` only; same mechanism. Also overlaps B-lowering F3/F13 (narrowing), different code path. |
| F4 aliased shadow store writes 0 | CONFIRMED | S0 overstated → S2 (latent) | NEW; overlaps Bennett-lcye | Primitive-API only; both callers in lowering/memory.jl pass `resolve!`d value wires, no public path shown (reviewer says so). Emitted gate is literally `CNOTGate(1,1)` / `ToffoliGate(3,1,1)` — lcye constructor check would make it loud. |
| F5 QCLA `x+x` self-CNOTs | CONFIRMED (254/256 throw) | S1 yes | NEW (not a stwr hole — different path); overlaps Bennett-lcye | stwr (7bf563e) was scoped to `add=:cuccaro` only; the `:qcla` branch (arith.jl:269-270) never consults `inplace_targets` and `lower_add_qcla!` got no alias guard. Also fails for non-argument `z+z`. |
| F6 toffoli_depth drops CNOT deps (multiplier) | not re-run | S2 ok | OVERLAPS Bennett-u3b2 (core F16) | Additional: test_mul_qcla_tree_paper_match.jl / test_qcla.jl re-implement the flawed metric and pin a false <0.5 paper ratio; Bennett-q22p's "already beats paper" claim rests on it. Note on u3b2 + q22p. |
| F7 y-broadcast linear depth | not re-run | S2 ok | NEW | No bead mentions y broadcast (9wmk=recycling, q22p=adder scheduling). |
| F8 strategies dropped at callee/loop | not re-run | S2 ok | DUPLICATE-OF Bennett-0a6f + Bennett-vpgj (= B-lowering F9; jgyx adjacent) | Adds executed byte-identical gate-stream witness; note only. |
| F9 Feistel permutation/odd-width contract | not re-run | S2 ok | NEW | Only persistent-map Feistel beads exist (sqtd/7pgw, closed). |
| F10 guarded softmem store clears high bits | not re-run | S2 ok | NEW | i2a6/nj6c (closed) built the shapes; none covers pred=0 identity on non-normalized words. |
| F11 QROM T-count/scratch claims | not re-run | S2 ok | NEW (adjacent Bennett-p4ch) | p4ch is future QROAM, not the false cost claim. |
| F12 BENCHMARKS arithmetic rows stale | not re-run | S2 ok | OVERLAPS Bennett-t3ou | Additional: unqualified x+1 rows (BENCHMARKS.md:9-12, 100/204/412/828) also stale, not just Cuccaro rows; widen t3ou. |
| F13 tabulate skips add/mul/target validation | not re-run | S2 ok | DUPLICATE-OF Bennett-iwj6 (core F23) | Only addition: retired `mul=:karatsuba` accepted on the tabulate path. |
| F14 QROM non-pow2 → InexactError | code-trace confirmed (qrom.jl:47 `Int(log2(L))` precedes the pow2 check) | S2 → S3 | NEW | Still fails loud (wrong message); only internal callers, which pad. |
| F15 adder-tree doc + inert `reuse_pool` | not re-run | S3 ok | NEW (adjacent q22p / 9wmk / closed d1ee) | Doc/API hygiene. |

Net: 8 NEW (F4, F5, F7, F9, F10, F11, F14, F15), 5 duplicates (F1, F2, F3, F8, F13), 2 overlaps
needing bead notes (F6 → u3b2/q22p, F12 → t3ou). Severity changes: F4 S0→S2, F14 S2→S3.

## F1 — CONFIRMED, S0

Reproducer copied verbatim from B-arith.md (plus two diagnostic prints and a noncompact rerun).
Signatures checked: `emit_qrom!(gates, wa, data, idx_wires, W)` (qrom.jl:42), `lower_call!(gates, wa, vw, inst; compact, loop_guards)` (call.jl:83) — call is correct.

```
after qrom: wc=15 free=[15, 14, 13, 12]
after call: wc=52 maxgatewire=56
Int8[102, -120, -52, -18]          # expected [6,8,12,14]
true                               # verify_reversibility
noncompact wc=44 maxgatewire=48
ERR: Ancilla wire 38 not zero post-circuit — uncomputation invariant violated. ...
```
Every number in the report reproduces (reviewer's noncompact claim "ancilla error" confirmed; wire id 38).
Public-path confirmation via B-lowering F7's `ParsedIR` + `reversible_compile(p; compact_calls=true)` witness:
`(65, true)` and `192` wrong of 256 — so S0 holds on a public entry point, not just the primitive.
Dedup: Bennett-9k7n (open, P2) describes exactly this root cause and says "Not yet reproduced";
B-lowering F7 is the same finding. Triage action: one note on 9k7n with both witnesses, raise to P1.

## F2 — CONFIRMED, S0

```julia
f(x::Int8)=Int16(x)*Int16(x)
reversible_compile(f,Int8;strategy=:tabulate)   # ([8], -112, true)
reversible_compile(f,Int8;strategy=:expression) # ([16], 400, true)
```
Byte-identical to circuit-core F3, already in Bennett-iwj6 (open P1) description.

## F3 — CONFIRMED, S0

```julia
g(x::UInt8)=(x*x)>>1;  reversible_compile(g,UInt8;bit_width=2,strategy=s)
F3 expression: [0, 0, 0, 0] verify=true gates=22
F3 tabulate:   [0, 0, 2, 0] verify=true gates=21
F3 auto:       [0, 0, 2, 0] verify=true gates=21
```
Same mechanism as circuit-core F2 (`(x*x)>>2`, W=4) in Bennett-iwj6. The W=2 witness is a
smaller regression candidate; nothing else new.

## F4 — CONFIRMED; severity S0 overstated → S2 (latent)

Reconstructed from the prose (no literal code in the report); signatures
`emit_shadow_store!(gates, wa, primal, tape_slot, val, W)`,
`emit_shadow_store_guarded!(..., W, pred_wire)`, `emit_shadow_load!(gates, wa, primal, W)`.
```
guarded=false gates=[CNOT(1,2), CNOT(2,1), CNOT(1,1), CNOT(1,3)]          expected=1 got=0 verify=true
guarded=true  gates=[NOT(3), Toff(3,1,2), Toff(3,2,1), Toff(3,1,1), CNOT(1,4)] expected=1 got=0 verify=true
```
Mechanism exactly as described (phase 2 clears primal before phase 3 reads `val`).
Severity: the only callers (src/lowering/memory.jl:716, 754, 759, 898) pass `val_wires` from
`resolve!`; loads copy into fresh wires (aggregate.jl:517). The reviewer explicitly did not
reproduce an end-to-end miscompile. A silent wrong result from a public entry point is not
shown, so S0 is too high; S2 (unenforced disjointness precondition on an internal primitive)
fits. Note the emitted `CNOTGate(1,1)`/`ToffoliGate(3,1,1)`: Bennett-lcye's constructor
rejection would turn this into a loud error, so it can be a note on lcye plus a
disjointness assert in shadow_memory.jl. NEW (no shadow-alias bead).

## F5 — CONFIRMED, S1 correct; NEW (different path from stwr)

Reproducer as written, extended to exhaustive Int8:
```
self-ctrl gates: CNOTGate[CNOTGate(2, 2), CNOTGate(3, 3), CNOTGate(4, 4), CNOTGate(5, 5)]
x=2: Ancilla wire 12 not zero post-circuit — uncomputation invariant violated.
ok=2 wrong=0 threw=254                  # only 0 and 1 pass, as reported
ripple  all-correct=true verify=true
cuccaro all-correct=true verify=true
qcla optimize=true: true                 # LLVM rewrites x+x to shl; only optimize=false hits it
h(x,y)=(z=x+y; z+z), add=:qcla, optimize=false -> "Ancilla wire 19 not zero ..."
```
Control probes: `x-x` (default) and `x*x` under `mul=:shift_add` / `:qcla_tree` all pass.
Severity: compile silently accepts, simulate throws loudly — "unsound acceptance / crash on
valid input" = S1. Not S0 (no silent wrong value observed: 0 wrong, 254 throw).

stwr coverage: commit 7bf563e is titled "make add=:cuccaro sound"; it added
`compute_inplace_targets` (operand.jl) for Cuccaro's in-place-overwrite decision and an
aliased-register `ArgumentError` in `lower_add_cuccaro!` only. QCLA is out-of-place, so
`compute_inplace_targets` is irrelevant to it; the defect is operand registers `a === b`
inside `lower_add_qcla!` (its propagate init emits `CNOT(a[k], b[k])` = `CNOT(w,w)`).
The dispatcher branch `elseif strat == :qcla; lower_add_qcla!(gates, wa, a, b, W)`
(src/lowering/arith.jl:269-270) has no aliasing handling. So this is not a hole in stwr's
analysis but an adjacent primitive stwr never scoped. The stwr follow-up Bennett-lcye
(reject `CNOTGate(c,c)` at construction) would convert it to a compile-time error.
No existing bead mentions QCLA aliasing (searched issues.jsonl for qcla+alias / x+x / self-CNOT).

## Dedup details for F6–F15

- **F6** — Bennett-u3b2 (open P2) is core F16 (same 3-gate chain). Arith adds: measured
  dependency-respecting multiplier depths (W=8/16/32 → 56/88/128 vs reported 20/24/28), the two
  test files that duplicate the flawed metric and pin a paper ratio, and that Bennett-q22p's
  description ("X3 measurements show our depth ...") relies on it. Append to u3b2; note on q22p.
- **F7** — NEW. Grep for "broadcast" hits only closed 8daw/bo91/cnyx (fast_copy/QCLA impl).
- **F8** — Bennett-0a6f (callees, open P2) and Bennett-vpgj (loops, open P3) descriptions match;
  B-lowering F9 already cites both plus jgyx. Arith contributes only extra witnesses.
- **F9** — NEW. Existing Feistel beads (sqtd, 7pgw closed) concern persistent/soft_feistel.
- **F10** — NEW. No bead on false-predicate identity with nonzero unused high bits.
- **F11** — NEW. p4ch (open P3, QROAM) is future work, not the doc/metric correction.
- **F12** — Bennett-t3ou (open P4) covers Cuccaro rows only; BENCHMARKS.md:9-12 unqualified
  x+1 rows show 100/204/412/828 while the pinned ripple baseline is 58/114/226/450. Widen t3ou.
- **F13** — Bennett-iwj6 already includes core F23 (add/mul/target/hashcons=:bogus on tabulate).
  Only extra: `mul=:karatsuba` (retired, tbm6) accepted there. Note on iwj6.
- **F14** — NEW (the only grep hit, Bennett-7sb7, is an unrelated HAMT issue).
  qrom.jl:47 `n = L == 1 ? 0 : (Int(log2(L)))` throws InexactError before the pow2 check at :48.
  All three internal callers (tabulate.jl:234, qrom.jl:176 padded, bennett_transform.jl:388) pass
  power-of-two tables → loud-on-invalid-input diagnostic only; S3.
- **F15** — NEW (doc + inert kwarg). q22p correctly describes copy-root + uncompute-all.

## Named bead ids — existence check (`.beads/issues.jsonl`)

| Bead | Status | Matches report's characterisation? |
|---|---|---|
| Bennett-9k7n | open P2 | yes — contiguity root cause, "Not yet reproduced" |
| Bennett-b2fs | closed P3 | yes — tabulate PRD/Vector{Any}, not return width |
| Bennett-stwr | closed P2 | yes — Cuccaro-only |
| Bennett-q22p | open P3 | yes — Schedule B; depth claim as described |
| Bennett-9wmk | open P3 | yes — ancilla recycling |
| Bennett-0a6f | open P2 | yes |
| Bennett-vpgj | open P3 | yes |
| Bennett-4iuj | open P3 | yes — target=:depth only steers mul |
| Bennett-sqtd | closed P1 | yes — soft_feistel_int8, not emitter |
| Bennett-p4ch | open P3 | yes — QROAM future work |
| Bennett-t3ou | open P4 | yes — Cuccaro rows only (narrow, as reported) |
| Bennett-tbm6 | closed P3 | yes — Karatsuba removal |
| Bennett-d1ee | closed P3 | yes — WHY comments |
| Bennett-salb | closed P3 | yes — div-by-zero totalisation |

All 14 exist and match. Circuit-core-triage beads used above (iwj6, u3b2, lcye) also exist, open.
