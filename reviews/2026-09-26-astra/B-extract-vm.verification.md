# Verification — B-extract-vm (F1–F13) — 2026-09-26

Independent re-execution of `B-extract-vm.md`. Julia 1.12.3, `julia --project --check-bounds=yes`,
Bennett.jl working tree at `29f9cfa` (+ unrelated uncommitted `src/pebble/pebbled_groups.jl`), sibling
BennettVM.jl loaded via `push!(LOAD_PATH, "../BennettVM.jl"); using BennettVM` (path-dev dep on this tree).
VM harness exactly as the report's reproduction convention: `vm=lower_vm(p); rs=initial_state(vm,
Dict(p.args[i][1]=>xs[i])); run!(rs,vm)`, read `result(rs)[IRRet.op.name]`, then `unrun!(rs,vm)` and
check `rs.current==rs.initial && isempty(rs.history)` ("clean"). All reproducers ran as written; no
MethodError / signature mismatch. F1–F11 and F13 re-run here; F12 not re-run (hang; already
re-executed as B-extract-core F15 in `B-extract-core.verification-B.md`: n=2000 → timeout 124).
No src/ or test/ files touched; probe scripts live in the session scratchpad only.

**Numbering note.** `B-extract-core.verification-B.md` cites extract-vm "F3" (recursive root), "F5"
(MemorySSA deadlock) and "F8" (memssa parser). Those use a pre-final numbering; in the current report
they are **F9, F12, F13**. `B-extract-core.triage.md` row F26 says "overlaps extract-vm F8/F13"; only
**F13** is correct (current F8 is the empty-Memory pointer finding).

## Summary

| F# | Verdict | Severity ok? | Reachability | Dedup | Note |
|---|---|---|---|---|---|
| F1 | CONFIRMED | S0 yes (predcalc variant S1) | **Real Julia** (`mem=:vm`, optimize=false) | NEW | n=2: native 99, VM 3, clean; n=0,1,3 correct; predcalc(2) → `unbound SSA name :__v1` pc 92 |
| F2 | CONFIRMED | S0 yes | **Real Julia** (`mem=:vm`, optimize=true) | NEW | two Dicts → 2×IRMapInsert(1,·) + 1 get; native 11, VM 22, clean. Promised multi-Dict guard (dict_vm.jl:168–171) absent |
| F3 | CONFIRMED | S0 yes | **Real Julia** | NEW | `mutate!(d)` call erased; native 99, VM 11, clean |
| F4 | CONFIRMED | S0 yes | **Real Julia** | NEW | `isempty` branch flattened, both inserts unconditional; native 11, VM 99, clean |
| F5 | CONFIRMED | S0 yes | **Real Julia** (`mem=:vm`, optimize=false) | NEW (not i30x, not utzc) | narrowvec(1,128): native InexactError, VM 128, clean; x∈[-256,255]: all 256 throwing inputs return silently, all 256 in-range correct |
| F6 | CONFIRMED | S0 yes (latent) | from_ll only (Julia `Threads.Atomic` rejects loudly at opt=true; opt=false stops at get_pgcstack) | **DUPLICATE-OF Bennett-7v22** (extract-core F12, atomicrmw half; same heap.jl lines) | ParsedIR drops atomicrmw; simulate(5)=5, verify=true, 256/256 wrong vs x+1 |
| F7 | CONFIRMED | S0 yes (latent) | from_ll only (Julia global-load variants blocked by hsm3 backstop; const store to `%out` rejects) | NEW (fix shape shared with 7v22) | ParsedIR = `ret x` only; store of @G to caller `%out` erased |
| F8 | CONFIRMED | S0 yes (eqjl's P3 understates) | **Real Julia** (`ptr_cells=true`, optimize=false) | **DUPLICATE-OF Bennett-eqjl** (part 1); consequence of hsm3's D3 sentinel | eqmem(5): native 5, VM 6, clean; same-type control eqsame: native 6 = VM 6 |
| F9 | CONFIRMED | S1 yes (loud; S2 arguable) | **Real Julia** | DUPLICATE-OF extract-core F16 (no bead yet); not t7zu | root in `transitive_callees` (len=1); duplicate canonical key `rec#dcc408c3` |
| F10 | CONFIRMED, **worse** | **Upgrade S1 → S0** | **Real Julia** | DUPLICATE-OF Bennett-wh1p (upgrade P2 → P1) | as written: loud "no registered callee handler" for `Upper`; NEW witness `Foo`/`foo` pair binds both calls to `foo`: native 111, VM 210, clean |
| F11 | CONFIRMED | S2 yes | Real Julia | DUPLICATE-OF Bennett-9tg3 | `isempty(ss)=true`, `skipped` list never surfaced |
| F12 | CONFIRMED (by ext-core verif-B F15; not re-run) | S2 ok (hang; borderline S1) | Real Julia via opt-in `use_memory_ssa=true` | NEW; = extract-core F15 (no bead; deferred to this triage) | pipe buffer deadlock at ~100 kB annotation output |
| F13 | CONFIRMED | S2 yes (no consumer) | from_ll / any function with store-first join block | OVERLAPS Bennett-7nez (same parser, distinct defect) | `def_at_line=Dict(8=>1,14=>3)`, def 2 unlocated; malformed `MemoryDef(unknown)` → empty graph silently |

Headline: 13/13 confirmed (12 re-executed here). Real-Julia silent wrong results that reverse cleanly
on BennettVM: F1, F2, F3, F4, F5, F8, and F10 (new witness). F6/F7 are from_ll-only latent S0s.

## Per-finding details

### F1 — CONFIRMED, S0, NEW
- `probe` extracted with `optimize=false, mem=:vm`: 39 blocks; entry block is exactly
  `IRAlloca(_vecvm_base#162, 8, n)`, `icmp sle 1,n`, `xor`, branch — no `n==2` test.
- VM vs native for n=0,1,2,3: 0/0, 1/1, **3/99**, 6/6; every run reverses clean.
- `predcalc(2)`: extraction and `lower_vm` succeed; `run!` fails `unbound SSA name :__v1 … pc: 92`
  (native 24). This half is an S1 (crash on valid input, extraction accepted a dominance-broken IR).
- Dedup: open vm-recogniser beads are only 21rj (stream-check bypass) and ckkh (two-loop rejection). NEW.

### F2 — CONFIRMED, S0, NEW
- Extracted ops: `IRMapInsert(1,x)`, `IRMapInsert(1,y)`, `IRMapGet(__v34,1)`, `ret __v34`. VM 22, native 11,
  clean. dict_vm.jl:168–171 claims a "multi-`setindex!`-on-distinct-dicts guard in `_dict_vm_collect_ops`";
  grep finds no such guard (only "more than one surviving ret" / multi-way branch errors). Header lines 69–71
  also promise "a second Dict … REJECTS LOUD". No bead matches "two/second/multi dict". NEW.

### F3 — CONFIRMED, S0, NEW
- Extracted ops: insert(1,x), get(1), ret. The `mutate!` call vanished. VM 11, native 99, clean. Header
  comment (dict_vm.jl:70–71) promises "an unrecognised callee tainted by the Dict REJECTS LOUD". NEW.

### F4 — CONFIRMED, S0, NEW
- Extracted ops: insert(1,x), insert(1,99), get(1), ret — the `isempty` guard is gone. VM 99, native 11,
  clean. Distinct mechanism from F3 (no unknown callee). NEW; fix naturally shares F3's post-taint audit.

### F5 — CONFIRMED, S0, NEW
- `narrowvec(1,128)`: native `InexactError`; VM returns 128 (0x80 zero-extended in the i64 register), clean.
- Extended sweep x∈[-256,255], n=1: 256 inputs throw natively and **all 256** return a value on the VM;
  the other 256 match native `Int8(x)` sums. Wrong-for-every-throwing-input.
- Not Bennett-i30x (over-rejection message) and not Bennett-utzc (closed; generic ptr_cells throw model,
  which the report correctly cites as the baseline to copy). NEW.

### F6 — CONFIRMED, S0 (latent), DUPLICATE-OF Bennett-7v22
- Fixture as written: ParsedIR = `IRAlloca(_kuza_heap#3,8,1)`, ptroffset, store x, ptroffset, load r, ret r.
  `reversible_compile` ok; `simulate(c,Int8(5))=5`; `verify_reversibility(c;n_tests=256)=true`; 256/256
  wrong vs x+1.
- Reachability probes: `Threads.Atomic{Int8}` + `atomic_add!` under `mem=:heap, ptr_cells=true` rejects
  loudly (opt=true: `LLVMAtomicRMW … unsupported LLVM opcode`; opt=false: `julia.get_pgcstack` Symbol
  callee). No Julia witness found → from_ll only.
- Bennett-7v22 (open P1, filed today from extract-core F12) names the same heap.jl lines (1521–1536,
  1873–1895, 2061–2062) and its source finding already executed an `atomicrmw xchg` variant on
  `heap_m2_cond_pair.ll`. `verification-A` calls extract-vm's sibling a "different recogniser"; for F6
  that is wrong — it is the same heap.jl M2/M3 forbidden-opcode omission. Add this fixture to 7v22.

### F7 — CONFIRMED, S0 (latent), NEW
- Fixture as written → `[IRBasicBlock(:top, IRInst[], IRRet(SSAOperand(:x), 8))]`, args `(:x,8),(:out,64)`.
  The store of `@G`'s value to caller-owned `%out` is erased.
- Controls: `store i8 9, ptr %out` (constant, not skeleton-tainted) **rejects** ("surviving (non-skeleton)
  instruction … M1 only compiles …"), so the drop needs the taint-from-non-instruction-load path the report
  describes. Removing the allocation skeleton keeps `IRStore(out, v)` but with `:v` undefined (load of a
  mutable non-jl_global `@G` elided) — a separate from_ll oddity outside this report's scope.
- Julia probes (`const G7=Ref(Int8(9))`, store via `unsafe_store!(p::Ptr)` or `r::RefValue`) are all rejected
  by the hsm3 jl_global backstop; the constant-store Julia variant is correct (Memory optimised away).
  → from_ll only. NEW (shares 7v22's "classify writes by destination provenance" fix).

### F8 — CONFIRMED, S0, DUPLICATE-OF Bennett-eqjl
- `eqmem(5)`: native 5 (pointers 0x…b570 vs 0x…6470), VM **6**, clean. Control with two `Memory{Int64}()`
  literals (`EM1===EM3` is true in Julia — per-type singleton): native 6, VM 6. So the bug is exactly the
  cross-type distinct-singleton case.
- Relation to hsm3 (closed 2026-09-24, commit 411ae9b): hsm3 replaced name trust with semantic membership
  certification and introduced the D3 data-pointer sentinel `_EMPTY_MEMORY_DATA_SENTINEL`
  (jlglobal_cert.jl:76, written at :369). F8 is a direct consequence of that sentinel design, not a
  certification false positive; hsm3's close reason itself lists "data-ptr sentinel (D3)".
- Bennett-eqjl (open P3) part (1) describes this exactly; part (2) (per-function globals windows) was not
  executed by either review. Recommend raising eqjl to P1/P2 with this Julia-reachable witness.
- Bennett-23ml (open P2, 5viz real-front-end E2E gate) is unrelated to the sentinel identity; F8 neither
  closes nor blocks it. The report's claim that 23ml remains outstanding is consistent with the bead state.

### F9 — CONFIRMED, S1, DUPLICATE-OF extract-core F16 (no bead)
- `transitive_callees(rec, Tuple{Int64})` has length 1 and contains `typeof(rec)`, contradicting the
  callgraph.jl:85 docstring ("ROOT … EXCLUDED"); `visited` starts empty (callgraph.jl:101–103).
- Set extraction: `duplicate canonical key rec#dcc408c3 — a hash collision or a re-extracted callee leaked
  through (Rule 1)`. Loud; S1 defensible (valid input rejected), S2 arguable. Not t7zu. File one bead for
  both reports.

### F10 — CONFIRMED and WORSE than reported: S0, DUPLICATE-OF Bennett-wh1p
- As written: `rootupper` fails with `call to 'j_Upper_3295' has no registered callee handler … (Bennett-5oyt
  / U15)`; lowercase control `lower_h` extracts (len=2). callees.jl:81 lowercases the query;
  julia_set.jl:236 lowercases the capture.
- **New Julia witness (silent):** `@noinline Foo(x::Int64)=x+1; @noinline foo(x::Int64)=x+100;
  r2(x)=Foo(x)+foo(x)`. The set extracts cleanly (keys `r2`, `foo`, `Foo`) but **both** IRCalls in `r2`
  bind to `foo`. Multi-function `lower_vm(s)`: VM `r2(5)` = **210**, native 111, reversal clean.
  This is the "latent silent-unlink risk" wh1p predicted — now executed. Upgrade wh1p P2 → P1 and add
  the case-distinct pair as its regression test.

### F11 — CONFIRMED, S2, DUPLICATE-OF Bennett-9tg3
- `isempty(ss) = true`, `typeof(ss) = Vector{Pair{Symbol,ParsedIR}}`. `skipped` (julia_set.jl:385, pushed
  at :404) is never returned or logged. 9tg3 (open P3) matches.

### F12 — CONFIRMED (not re-run here), S2, NEW (= extract-core F15)
- Re-executed by `B-extract-core.verification-B.md` F15 (n=1000 stores → 53,886 B OK; n=2000 → timeout
  124). Mechanism memssa.jl:123–142 (read after `LLVM.run!`). No bead (`memssa` keyword search: only
  closed T2a/U44 beads, g7d6, 7nez). extract-core triage deferred it here → needs one new bead.

### F13 — CONFIRMED, S2, OVERLAPS Bennett-7nez
- Real LLVM printer on the diamond: `def_at_line=Dict(8=>1, 14=>3)`, `def_clobber=Dict(2=>3,
  1=>:live_on_entry)` — MemoryDef 2 has no location (phi 3 overwrote it). Malformed
  `"; 1 = MemoryDef(unknown)"` returns empty dicts silently.
- 7nez (open P3, extract-core F26) covers cross-function ID merging in the same parser; phi/def slot
  collision and malformed-line silence are distinct defects → append to 7nez or file a sibling. No
  lowering consumer of `memssa` (per verification-B), so S2 stands.

## Bead-id check (ids named by the report)

| Id | Exists | Status | Report's use | Matches? |
|---|---|---|---|---|
| Bennett-eqjl | yes | open P3 | F8 tracking | yes (part 1) |
| Bennett-wh1p | yes | open P2 | F10 tracking | yes; severity understated |
| Bennett-9tg3 | yes | open P3 | F11 tracking | yes |
| Bennett-t7zu | yes | open P3 | F9 "not this" | correct — recursive sret circuit lowering |
| Bennett-i30x | yes | open P3 | F5 "not this" | correct — over-rejection message |
| Bennett-ares | yes | closed | F6 "not this" | correct — VM atomic load/store relaxation |
| Bennett-hsm3 | yes | closed 2026-09-24 | sound-section / F8 | yes |
| Bennett-23ml | yes | open P2 | still outstanding | yes |
| Bennett-21rj | yes | open P2 | recogniser stream-check bypass | yes |
| Bennett-zuk5 | yes | open P3 | Symbol-path ambiguity (unconfirmed) | yes |

Not named by the report but relevant: **Bennett-7v22** (F6 duplicate), **Bennett-7nez** (F13 overlap).

## Suggested new beads from this report
F1, F2, F3 (+F4 may share one "dict_vm post-taint effect/control audit" bead but are distinct
witnesses), F5, F7, F9 (joint with extract-core F16), F12 (joint with extract-core F15). Priority upgrades:
wh1p → P1 (F10 silent witness), eqjl → P2 or higher (F8 Julia-reachable S0). Append F6 fixture to 7v22,
F13 defects to 7nez.
