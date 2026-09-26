# Verification — B-lowering — 2026-09-26

Independent re-execution of the S0/S1 findings of `B-lowering.md` (F1–F8, F13, F15–F18),
c6ex-relation check for the phi/CFG findings (F1, F5, F8, F16, F18), and dedup of all
F1–F18 against `B-circuit-core.triage.md`, `B-arith.verification.md` and `.beads/issues.jsonl`.
All probes: `julia --project --check-bounds=yes --compiled-modules=existing --startup-file=no <scratch>.jl`
from the repo root (scratch scripts A–D in the session scratchpad; not committed).
No src/test edits, no `bd`, no commit, no full suite. F9–F12, F14 were NOT re-executed (dedup only).

## Summary

| F# | Verdict | Severity ok? | c6ex relation | Dedup | Note |
|---|---|---|---|---|---|
| F7 QROM free-list → compact callee | CONFIRMED (ParsedIR + real Julia) | S0 yes (opt-in `compact_calls=true`; default `false` is loud) | n/a | DUPLICATE-OF Bennett-9k7n = B-arith F1 | Julia `lookup_review` opt=true cc=true: 192/256 wrong, sim(0)=65, rev=true. opt=false: 0 wrong both cc. |
| F1 store via selected ptr ignores block pred | CONFIRMED (ParsedIR + LLVM-verified .ll) | S0 yes | Unrelated (memory.jl multi-origin path, cb9y 2026-05-01; c6ex never touched memory.jl). Same false-path class CLAUDE.md warns about, but in store predication. | NEW (hole next to closed oio4/tzb7/cb9y) | 64/256 wrong, fold on/off, rev=true. `block_label` unused in multi-origin fan-out (memory.jl:615-648). |
| F2 zero-offset GEP after dynamic GEP | CONFIRMED (ParsedIR + LLVM-verified .ll; persistent forms too) | S0 yes | n/a | NEW (adjacent z2ia, xv0u) | 256/256 return 0 vs 42. Persistent `PtrOffset 0`/`VarGEP(p1,0)`: 11 vs 22 on 256/256. |
| F3 narrowing keeps old-width shift guards | CONFIRMED (real Julia) | S0 yes | n/a | NEW (g7d6 = metadata only; theme-overlap with B-arith F3 / iwj6, different path) | `bit_width=4`: opt=false `[0,0,0,0,0]`, opt=true x=4→1; `bit_width=8`,opt=false: f(1)=0 vs 2. `x>>1` W=4 throws. |
| F5 loop-header side effects after exit | CONFIRMED (ParsedIR + LLVM-verified .ll) | S0 yes | Hole c6ex left: header non-phi insts run under constant `block_pred[hlabel]` every iteration and in the s0tn check-only pass (cfg.jl ~419-420, 549-562); c6ex did not touch these lines. Not a regression. | OVERLAPS Bennett-8nfb | 8nfb names the done-flag fix but claims all shapes fail loud; this silent memory case is additional. |
| F18 irreducible region accepted as loop | CONFIRMED (LLVM-verified .ll) | S0 yes | Hole c6ex left: `find_back_edges` (DFS, no dominance) unchanged since U40 split; `_check_predication_cfg` has no reducibility check. Not a regression. | NEW (adjacent 8nfb, vysm spike) | 128/256 → 11 vs 42 at K=1,3, fold on/off, rev=true. No Julia-source witness. |
| F6 missing store/alloca groups → ValueEager | CONFIRMED (hand-built ParsedIR, exported `bennett(lr; strategy=)` API) | S0 yes, but only with `fold_constants=false` (default folding empties groups → safe fallback, F10) | n/a | NEW (overlaps exb3/F10 which masks it; same family as core F5 uhk3) | groups `[(:__pred_entry,1,1),(:r,26,33)]` of 33 gates; ValueEager 255/256 wrong, rev=true; Checkpoint/PebbledGroup throw `_remap_wire`. |
| F15 persistent dynamic alloca history overflow | CONFIRMED (hand-built ParsedIR, opt-in `mem=:persistent`) | S0 yes | n/a | NEW (adjacent deferred uxn2, closed hmn0) | 5 writes: 7 vs 11 on 256/256, 7298 gates, rev=true; 4-write control returns 11. |
| F17 bounds-error branches vanish | CONFIRMED (real Julia) | S1 yes | c6ex's `_check_predication_cfg` (V2) explicitly admits `:__unreachable__` targets; erasure itself predates c6ex. | NEW (8nfb covers only loop-region `__unreachable__` KeyError) | Both opt: Julia throws on 254, circuit throws on 0; sim(-1)=11, rev=true. |
| F8 untaken loop fails convergence guard | CONFIRMED (real Julia) | S1 yes | Hole c6ex left and self-filed as n9o8 (guard not ANDed with `block_pred[hlabel]`, cfg.jl:567-575). Not a regression (pre-c6ex behaviour not re-run). | DUPLICATE-OF Bennett-n9o8 | opt=false K=3: 128/256 throw, first x=-124; opt=true 0. Loud. |
| F4 MUX-EXCH rejects negative const store | CONFIRMED (hand-built ParsedIR) | S1 yes | n/a | NEW | `InexactError: convert(UInt64, -1)` at memory.jl:1153 `UInt64(op.value)`; `iconst(5)` control 0/256 wrong. |
| F16 loop-exit heuristic rejects valid loop | CONFIRMED (LLVM-verified .ll) | S1 yes (loud) | Hole c6ex left and self-documented in 8nfb ("'br c, body, exit' headers mis-identified -> 'IRRet in loop body'"). | DUPLICATE-OF Bennett-8nfb | 5-block H/body/latch: `IRRet in loop body at exit`; 4-block control 0/256 wrong. |
| F13 narrowing breaks tuple layout | CONFIRMED (real Julia) | S1 yes | n/a | NEW (g7d6 metadata-only; iwj6 tabulate-only) | Both errors reproduce verbatim; unnarrowed control returns (3,4). |
| F9 callee drops caller options | not re-run | S2 ok | n/a | DUPLICATE-OF Bennett-0a6f + jgyx + vpgj (= B-arith F8) | — |
| F10 folding disables group strategies | not re-run | S2 ok | n/a | DUPLICATE-OF Bennett-exb3 (= core F20) | Also the reason F6 is masked at defaults. |
| F11 unknown-ptr dead load silent | not re-run | S2 ok | n/a | DUPLICATE-OF Bennett-sy9t | — |
| F12 allocator frees invalid ids | not re-run | S3 ok | n/a | NEW (swee closed covers alloc(-1)/double free only; vt0a broader design) | — |
| F14 MUX-EXCH 6-14× shadow | not re-run | S3 ok | n/a | DUPLICATE-OF Bennett-vscb | Adds same-shape measured table (vscb has extrapolated numbers). |

Net: 10 NEW (F1, F2, F3, F4, F6, F12, F13, F15, F17, F18); 7 DUPLICATE (F7, F8, F9, F10, F11, F14, F16); 1 OVERLAP needing a note (F5 → 8nfb).
All 13 S0/S1 findings reproduce; no severity changes (caveats on F6/F7/F15 opt-in reachability).

## Bead lookups (`.beads/issues.jsonl`)

All ids named in the report exist and match their described scope:
9k7n open P2 (contiguous `allocate!` assumption, "Not yet reproduced"), 8nfb open P3 (loop exit
heuristic / multi-exit / `__unreachable__` KeyError, "all fail LOUD"), n9o8 open P2 (guard not
gated by header predicate), g7d6 open P2 (narrow drops globals/memssa/provenance), 6bu3 closed,
0a6f open P2, jgyx open P3, vpgj open P3, exb3 open P2, sy9t open P2, vscb open P3, swee closed P1,
vt0a open P3, z2dj closed, uxn2 deferred P3, 2o4r open P3. Keyword sweep (selected ptr / ptr_offset /
narrow shift / `_operand_to_u64` / store group / linear_scan / unreachable / irreducible) found no
further matching open bead; nearest: closed oio4 (conditional-store predicate guarding, single-origin),
closed tzb7/cb9y (multi-origin ptr select), open z2ia (dynamic-n alloca byte-normalisation), open vysm
(StructurizeCFG spike incl. irreducible CFGs).

## Per-finding details

### F7 — CONFIRMED, S0 (opt-in)
ParsedIR reproducer from the report, plus compact off:
```
(true, 65, true, 192)          # compact_calls=true: sim(-128)=65, rev=true, 192/256 wrong
(false, THREW "Ancilla wire 68 not zero post-circuit ...")
```
Real Julia (`tab_review` / `@noinline inc_review` / `register_callee!` / `lookup_review`, `strategy=:expression`):
```
opt=true  cc=true  wrong=192 threw=0 sim(0)=65 rev=true
opt=true  cc=false verify_reversibility: ancilla wire 132 not zero after forward pass   # loud
opt=false cc=true  wrong=0   sim(0)=1 rev=true
opt=false cc=false wrong=0   sim(0)=1 rev=true
```
`compact_calls` defaults to `false` (Bennett.jl CompileOptions), so the silent form needs the opt-in
flag; the default is loud. Same root cause as B-arith F1 / Bennett-9k7n.

### F1 — CONFIRMED, S0
Report ParsedIR, fold on/off: `(true, 64, 9, true)`, `(false, 64, 9, true)` → 64/256 wrong, sim(-127)=9
(expected 11), reversibility true. LLVM text (two allocas, `select ptr`, conditional `store i8 9, ptr %p`)
parsed + `LLVM.verify` + `_module_to_parsed_ir`: `(true, 64, true)`, `(false, 64, true)`.
Code: memory.jl:607-648 dispatches each origin with only `o.predicate_wire`; `block_label` (the
store's block) is never ANDed in. Single-origin stores go through `_lower_store_single_origin!(…, block_label)`.
No ordinary Julia witness (reviewer also says none established).

### F2 — CONFIRMED, S0
Report ParsedIR: `(false, 256, 0, true)`, `(true, 256, 0, true)`. LLVM text
(`alloca i8, i32 4; gep %a,(x&3); gep %p,0; store 42,%p; load %q`) extracts to
`[IRAlloca, IRBinOp, IRVarGEP, IRPtrOffset, IRStore, IRLoad]` and gives 256/256 wrong (sim(0)=0), rev=true, both fold modes.
Persistent forms (report underspecified the fixture; rebuilt with dynamic size `(x&1)+2`, `mem=:persistent`,
stores 11/22 to slots 0/1):
```
F2b IRPtrOffset(:q,p1,0)   : (11, 256, true)   # expected 22
F2c IRVarGEP(:q,p1,iconst(0)): (11, 256, true)
control IRVarGEP(:q,a,iconst(1)): (22, 0, true)
```
Side note: the same persistent-style fixture on a *static* alloca throws
`resolve!: width=0 out of supported range` (loud; not claimed by the report).

### F3 — CONFIRMED, S0
```
f(x::Int8)=Int8(1)<<x, bit_width=4: (false,[0,0,0,0,0],true)  (true,[1,2,4,8,1],true)
bit_width=8: opt=false f(1)=0 (expected 2), 8/8 wrong on 0:7;  opt=true 2, 0 wrong
g(x)=x>>1, W=4, opt=false: ArgumentError constant shift k=7 out of [0, W] for W=4
```

### F5 — CONFIRMED, S0
Report ParsedIR `(K,fold,wrong,sim(0),rev)`: `(3,false,192,4,true) (3,true,192,4,true) (5,false,256,6,true) (5,true,256,6,true)`.
LLVM-verified self-loop `.ll` (load/add/store in header `h`): identical four tuples.
Code: cfg.jl:419-420 seeds `iter_block_pred[hlabel] = opts.block_pred[hlabel]` every iteration; the
check-only pass (cfg.jl:549-562, from s0tn 2026-05-22) re-lowers `header_body_insts` including the
`IRStore` under the same predicate. Only PHIs are frozen.
c6ex: its commit touched seed merge / multi-latch / second-exit rejection, not header-effect
predication. Consistent with c6ex; a gap it left (8nfb's "done flag" is the fix, but 8nfb wrongly
asserts every such shape is loud).

### F18 — CONFIRMED, S0
Report `.ll` (entry → H or L; H `br i1 true, exit, L`; L stores 42 → H), `LLVM.verify` ok:
`(K,fold,wrong,sim(0),rev)` = `(1,true,128,11,true) (1,false,128,11,true) (3,true,128,11,true) (3,false,128,11,true)`.
c6ex: `find_back_edges` last changed in the U40 split (68c9f34); no dominance/reducibility check exists
anywhere in `src/lowering/` (grep `irreducib|dominat`: none relevant). c6ex's up-front validator
checks terminators, targets, entry preds and phi incomings, not single-entry loops. Gap left, not a
regression. Fixture uses a constant `br i1 true` (removable by simplification); Julia-source reachability
is not established.

### F6 — CONFIRMED, S0 (non-default folding)
Report fixture (field is `ssa_name`, not `result_name` — my first probe's typo, not the report's):
```
groups [(:__pred_entry,1,1), (:r,26,33)]  ngates=33
DefaultStrategy     (42, 0, true)
ValueEagerStrategy  (0, 255, true)          # 255/256 wrong (only x=0 right), rev=true
CheckpointStrategy  THREW _remap_wire: unmapped wire 10 ...
PebbledGroupStrategy THREW _remap_wire: unmapped wire 10 ...
```
Reachable via exported `LoweringResult`/`ValueEagerStrategy`/`value_eager_bennett` on an LR lowered with
`fold_constants=false`; the ParsedIR `reversible_compile` overload has no Bennett-strategy kwarg, and
default folding empties `gate_groups` (F10/exb3) which triggers the safe DefaultStrategy fallback.

### F15 — CONFIRMED, S0 (opt-in `mem=:persistent`)
`(simulate(c,2), wrong, gates, rev)` = `(7, 256, 7298, true)`; expected 11. Control with only the first
four stores: `(11, true)` — consistent with the 4-entry linear-scan history overwrite.

### F17 — CONFIRMED, S1
`indexed(x::Int8) = (Int8(11),Int8(22))[Int(x)]`, `strategy=:expression`:
```
opt=false julia_throws=254 sim_throws_on_those=0 valid_ok=2 sim(-1)=11 rev=true
opt=true  julia_throws=254 sim_throws_on_those=0 valid_ok=2 sim(-1)=11 rev=true
```
S1 (unsound acceptance) is the right bucket: there is no correct value to be wrong against, but the
error path is silently erased. Worth a P1-level bead since it affects every bounds-checked Julia function.

### F8 — CONFIRMED, S1
`skiploop`, K=3: `opt=false threw=128 wrong=0 first=(-124, "simulate: data-dependent loop with header block
:L4 did not converge within max_loop_iterations=3 ...")`; `opt=true threw=0 wrong=0`.
Code: cfg.jl:567-575 copies raw `conv_cond` into `conv_w`, never ANDed with `opts.block_pred[hlabel]`.
Matches n9o8 (filed by the c6ex close commit d57fad7).

### F4 — CONFIRMED, S1
F2 fixture with `IRStore(p, iconst(-1), 8)` and `load p`: `InexactError: convert(UInt64, -1)`.
Source: memory.jl:1153 `v = UInt64(op.value)` in `_operand_to_u64!`. Control with `iconst(5)`: `(0 wrong, true)`.
Hand-built only; extraction would produce `iconst(-1)` for `store i8 -1` so the shape is producible.

### F16 — CONFIRMED, S1
LLVM-verified 5-block loop (entry→H; H `br (i<n), body, exit`; body→latch→H; exit `ret i`):
`lower_loop!: IRRet in loop body at exit — early return inside a loop not supported`.
Same loop with body==latch (4 blocks): 0/256 wrong, rev=true. Heuristic at driver.jl:214-217 /
cfg.jl:356-357 (`exit_on_true = !(true_label == hl || true_label in latches)`). A Julia body-diamond
while-loop at optimize=false instead hit the other 8nfb symptom (`KeyError: :__unreachable__`).

### F13 — CONFIRMED, S1
`(x::Int8)->(x,x+Int8(1))`, `bit_width=4`: opt=false `_lower_store_via_shadow!: idx=2 out of range [0, 2)`;
opt=true `resolve!: SSA operand %new::Tuple.unbox.fca.1.insert has length(wires)=8 but caller advertised width=4`.
Unnarrowed control returns `(3, 4)`.

## Dedup notes for triage

- F7: note on 9k7n with the Julia witness; raise P2→P1 (already recommended by B-arith verification).
- F8: note on n9o8 (skiploop witness, 128/256 valid inputs rejected).
- F16: note on 8nfb (5-block `.ll` witness). F5: note on 8nfb AND a new bead (silent; 8nfb claims loud).
- F9/F10/F11/F14: notes only (0a6f/vpgj/jgyx, exb3, sy9t, vscb).
- New beads suggested: F1, F2, F3, F4, F6, F13, F15, F17, F18, F12. F3+F13 could share one narrowing bead
  (both `narrow.jl` width/layout contract), distinct from g7d6 and iwj6.
