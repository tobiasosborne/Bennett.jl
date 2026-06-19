## Session log — 2026-06-20 — Bennett-zf5v — CW-D2 lever 2: gc_preserve token drop + get_pgcstack allowlist

**Bead:** `Bennett-zf5v` (P1). CORE change (`src/extract/instructions.jl` +
`src/extract/julia_set.jl`) via **3+1** (2 proposers + implementer + orchestrator
review), RED-GREEN TDD. Second lever of CW-D2 (`bennettvm-416r.12`) on the
fdict-closure runway. Consensus doc:
`docs/design/Bennett-zf5v-gc_preserve-consensus.md`.

### The premise was OVERTURNED at optimize=false (the tell — Rule 10)
The bead asked for a `get_pgcstack` **inline-asm** GC-frame recognizer (the
`movq %fs:0` form). Proposer B re-probed at `optimize=FALSE` (the level the
closed-world producer `extract_parsed_ir_set_from_julia` actually extracts
bodies at — julia_set.jl:185/231/261) and found get_pgcstack there is the
**named intrinsic** `@julia.get_pgcstack()`, which ALREADY lowers cleanly to a
64-bit cell IRCall under ptr_cells — NO inline asm. The orchestrator's
definitive probe confirmed: at optimize=false the ROOT `fdict_d1b` walls at
`llvm.julia.gc_preserve_begin` (return type `token` → the ptr_cells C-call arm's
TokenType reject), `has movq %fs:0 asm: false`, `has @julia.get_pgcstack: true`.
Proposer A's GC-frame approach (right answer to the wrong premise) discarded;
`Bennett-6x2w` closed as superseded.

### What landed (two surgical, additive, ptr_cells-gated edits)
1. **instructions.jl** — at the TOP of the `ptr_cells && callee isa LLVM.Function`
   C-call arm (BEFORE the variadic-arg loop AND the `rt = value_type(inst)`
   return-type check), drop `cname == "llvm.julia.gc_preserve_begin"` /
   `"llvm.julia.gc_preserve_end"` → `return nothing`. Pure GC-rooting bookkeeping;
   no value semantics in the deterministic, single-threaded, history-reversible
   VM cell model. The `_begin` token is consumed SOLELY by `_end` (also dropped),
   so no dangling SSA. **Top placement is REQUIRED**: `gc_preserve_begin` is
   variadic (`call token (...)`), so a lower placement hits the arg-carry /
   TokenType error first (probe-verified pre-edit).
2. **julia_set.jl** — add `"julia.get_pgcstack"` to
   `_D1B_BENIGN_INTRINSIC_PREFIXES` so the MODELED get_pgcstack cell IRCall (it
   feeds the `gep -152` current_task chain, NOT dropped) survives
   `_closed_world_check!`. Gotcha worth pinning: the existing `"julia.gc_"`
   prefix does **NOT** match `julia.get_pgcstack` (`gc_` vs `get_pg`) — they are
   genuinely distinct entries.

### Wall-advance ground truth (this is the next lever's input)
Real `fdict_d1b(a,b)=(d=Dict{Int8,Int8}();d[a]=b;d[a])` at `optimize=false,
ptr_cells=true`: the gc_preserve TokenType wall is CLEARED and the root now
advances to **`ptrtoint ... unsupported LLVM opcode`** —
`%Dict = ptrtoint ptr %"+Main.Base.Dict#NNNN" to i64` (the root casts the
freshly gc_alloc'd Dict ptr to i64 right after the dropped gc_preserve_begin).
THAT is CW-D2 lever 3. Gate (d)'s successor disjunction was widened to include
`ptrtoint` / `unsupported llvm opcode` (kept inclusive per Rule 5).

### Gotchas
- The hand-built `.ll` gate-(a) fixture originally ended in `ptrtoint ptr
  %loaded to i64` — which itself walls at the new ptrtoint opcode wall and
  masked the drop proof. Switched the fixture to `ret ptr %loaded` (a ptr-cell
  return, ret_width 64) so the lowered chain is the clean witness:
  `IRCall(get_pgcstack, ret 64)` → 2× `IRPtrOffset(-152, +168)` → `IRLoad(64)`,
  with BOTH gc_preserve intrinsics absent.
- gate (b) byte-identity needed a MINIMAL fixture (no get_pgcstack) so
  gc_preserve_begin is the FIRST wall under cells=false — otherwise get_pgcstack
  (unregistered on the circuit path) walls at U15 first and the assertion text
  pointed at the wrong symbol.
- `test_d1b_julia_set.jl` GATE-E `@test_broken` stays broken (it runs `:skip`
  with the DEFAULT `ptr_cells=false`, where the drop never fires — byte-
  identical). The comment there already aspirationally said
  "root → julia.get_pgcstack … benign-listed"; this edit makes that true.

### Verification
- `test/test_zf5v_gc_preserve.jl` 17/17 (gates a/b/c/d). RED confirmed pre-edit:
  (a) blocked by TokenType wall, (d) still walled at gc_preserve/TokenType.
- Regressions all green: `test_lf14` 27/27, `test_ares` 57/57, gate-count 39/39
  (i8 x+1=58 holds — ptr_cells-gated, circuit path byte-identical),
  `test_d1b_julia_set` 30 pass + 1 broken (unchanged). No baseline disjunction
  needed widening (lf14/ares already inclusive of the relevant successors).

---

## Session log — 2026-06-19 — Bennett-ares — CW-D2 lever 1: VM-gated U14 atomic relaxation

**Bead:** `Bennett-ares` (P1, closed). CORE change (`src/extract/instructions.jl`)
via **3+1** (2 Plan-agent proposers + 1 implementer + orchestrator review),
RED-GREEN TDD. First lever of CW-D2 (`bennettvm-416r.12`) on the fdict-closure
runway. Consensus doc: `docs/design/Bennett-ares-U14-atomic-relax-consensus.md`.

### What landed
Gated the U14 (`Bennett-4mmt`) atomic-load/store fail-loud on the existing
`ptr_cells` flag. Under the closed-world / BennettVM cell model the consumer is
deterministic, single-threaded and history-reversible — **no concurrent
observer**, so a relaxed-consistency ordering contract is vacuous. New helper
`_vm_relaxable_ordering(ord)` accepts the band `{NotAtomic, Unordered, Monotonic,
Acquire, Release}` (= LLVM enum `{0,1,2,4,5}`); each guard became
`if ptr_cells; relaxable || _ir_error(…); else; <ORIGINAL guard VERBATIM>; end`.
Relaxed accesses fall through to the **existing** IRLoad/IRStore lowering
(ptr→cell width 64, integer→width N) — no new lowering. `AcquireRelease(6)`,
`SequentiallyConsistent(7)` and `volatile` stay fail-loud (the closure never
emits them; if one appears it is a new shape worth a human). Circuit path
(`ptr_cells=false`) is **byte-identical** — the else-arm is the original guard
verbatim, so `test_4mmt` substrings + gate-count baselines are untouched.

### Ground truth — the band was PROBED, not predicted (Rule 10)
Skeptical live closure scan (`optimize=false`, this machine) of the three
`fdict_d1b` callees `transitive_callees` returns:

| callee | atomic loads | atomic stores | fences |
|---|---|---|---|
| `setindex!` | 7× unordered | — | 2 |
| `rehash!` | 4× unordered | **6× release** | 2 |
| `ht_keyindex2_shorthash!` | 7× unordered | — | 2 |

(0 volatile, 0 atomicrmw/cmpxchg everywhere.) This **overturned proposer A's
narrow `{unordered,monotonic}` band** — it would re-wall the closure at
`rehash!`'s 6 `release` stores. Adopted proposer B's wider band. Moral (again):
scan the *whole closure*, not just the named callee.

### Wall-advance PROVEN (the deliverable)
With U14 relaxed under `ptr_cells`, both closure write-paths advance past the
atomic wall to their *next* wall — real forward progress on the P0 epic:
- `setindex!(Dict{Int8,Int8},Int8,Int8)` → `insertvalue { ptr, ptr }` memoryref
  aggregate wall (→ `Bennett-6bu3`, StructType insertvalue FILL, now on the
  critical path).
- `rehash!(Dict{Int8,Int8},Int64)` → `llvm.memcpy @"_j_const#1"` wall.

### NEW finding (neither proposer): 2 `fence`/callee
The closure scan surfaced **2 GC-safepoint `fence` instructions in every
callee** — a standalone barrier opcode (`LLVMFence`), a SEPARATE lever from
U14 load/store, and a pure no-op in the single-threaded VM. Filed
`Bennett-3ptu` (CW-D2: fence-as-noop under `ptr_cells`).

### Gotchas surfaced during impl (all LLVM-forced, documented in-test)
- **`AcquireRelease(6)` is unconstructible** on `load atomic`/`store atomic` —
  LLVM rejects it at parse (valid only on atomicrmw/cmpxchg/fence). So the
  strong-ordering test witness is `seq_cst(7)`; the helper's rejection of 6 is
  purely defensive.
- **ptr-RETURNING atomic loads wall at the ptr-return width-query** (in
  `ret_width` derivation) *before* the body load guard under `ptr_cells=false`
  — so the load-guard byte-identity witnesses use **integer** atomic loads
  (which reach U14 first); ptr-load fixtures assert the earlier ptr-return wall.
- **Integer load/store fall-through is gate-INDEPENDENT** — the predicate MUST
  be `ptr_cells && relaxable(ord)`; an ungated relaxation would silently change
  circuit-path integer-atomic behaviour (byte-identity violation). GATE-(c)
  locks this.
- `test_lf14` GATE-B's wall-advance disjunction was pinned to the *old* atomic
  successor this lever removes → orchestrator widened both disjunctions
  (`insertvalue`/`aggregate`/`structtype`/`memcpy`); the load-bearing
  `!_is_ptr_return_wall` assertion is unchanged.

### Verification (orchestrator, `--check-bounds=yes`, fresh subprocess each)
`test_ares_atomic_vm_relax` 57/57 · `test_lf14` 27/27 · `test_4mmt` 8/8
(byte-identity) · `test_gate_count_regression` 39/39 (i8 `x+1`=58, doubling laws).
Full `Pkg.test` deferred to the pre-push hook.

---

# 087 — 2026-06-19 — Bennett-lf14 — ptr_cells gate on the Julia-function entry

**Bead:** `Bennett-lf14` (P1, fdict runway). CORE change (`src/extract/entry.jl`
shard of `ir_extract.jl` + `src/extract/julia_set.jl`) via **3+1**. Closes the
last entry-point gap in the `ptr_cells` cell model.

## What landed
The `ptr_cells` gate (CW-C2 chunk B / Bennett-haiy: model pointers as opaque
64-bit VM cells — `ptr` return → `ret_width=64`, ptr store/load/GEP/ret as cells)
was plumbed for the `.ll`/`.bc` entries but **the Julia-function entry omitted
it**. lf14 adds `ptr_cells::Bool=false` to `extract_parsed_ir(f, types; …)`
(forwarded to `_module_to_parsed_ir`) and to `extract_parsed_ir_set_from_julia`
(threaded once into the sole `_extract_one` closure → reaches both per-callee and
root). Purely additive; default `false` is byte-identical to every prior caller
(`reversible_compile`/`_extract_parsed_ir_cached`/`mem=:heap`), so `gate_count`
stays 39/39 and `x+1`-i8 stays 58.

## Gate-surface decision (the open question for 3+1)
Chose a **raw `ptr_cells::Bool=false` kwarg** (Design A) over (B) hard-wiring
`ptr_cells=true` inside the set producer or (C) deriving it from `mem=:vm`.
Rationale: symmetry — the entire `from_ll`/`from_bc` family already exposes the
identical raw gate; lf14 closes the one gap. Hard-wiring is a one-way door
(removes the legacy-circuit option, makes per-callee `extract_parsed_ir` behave
differently through the producer vs directly). `mem` is the orthogonal ADR-0013
memory-arm selector; coupling it to `ptr_cells` contradicts the family. A future
`mem=:vm` convergence can set the *default* (`ptr_cells = mem===:vm`) at one site
without churning the surface — because the raw gate now exists.

## Wall-advance: probed, NOT predicted (Rule 5 corrected the scoping)
The read-only scoping predicted `rehash!` would advance to a "closed-world
violation" on `jl_alloc_genericmemory_unchecked`. **The live probe showed
otherwise** — under `ptr_cells=true`:
- `setindex!(Dict{Int8,Int8},Int8,Int8)` — ptr-RETURN wall **cleared**, advances
  to a **VoidType/U81 void wall**.
- `rehash!(Dict{Int8,Int8},Int64)` — ptr-RETURN wall **cleared**, advances to the
  **U14 atomic-load wall** (`load atomic ptr … unordered`, Bennett-4mmt).
- The `jl_alloc_genericmemory_unchecked` closed-world frontier lies **past** U14
  (CW-D2 / `bennettvm-416r.12`), not first.
The tests assert the **negative** (`!_is_ptr_return_wall`) plus an inclusive
disjunction of the real successors — no over-claim of full extraction. Moral
(again): probe the wall, don't trust the prediction; the masking wall is rarely
the one you guessed.

## Fail-loud / byte-identity
All cell-model fail-louds (first-index≠0, non-struct pointee, non-8-byte-aligned,
>2 GEP indices, U114/U16/U81 at gate-off) untouched — lf14 only flips the gate
*default reachability* via a new entry. The gate-off path is the exact code that
existed since chunk B.

## Verification (orchestrator, --check-bounds=yes)
- `test_lf14_ptr_return_cells.jl` 27/27 (GATE A ptr-free byte-identity under
  cells default/false/true + `x+1`=58; GATE B setindex!/rehash! wall-advance with
  registry snapshot/restore; GATE C set-producer threading).
- `test_gate_count_regression.jl` 39/39 **byte-identical**.
- `test_d1b_julia_set.jl` 30 pass + 1 broken (GATE E refreshed + `@test_broken`
  kept — `:skip` set still 0 bodies under cells on AND off).
- `test_5ikt_heap_m3.jl` 529/529, `test_bd5f_heap_m4.jl` 13/13 (default-path
  interlocks unperturbed).
- **Push gate:** lf14's behavior change is reachable ONLY via the opt-in
  `ptr_cells=true`, which no production path passes (only the new test). The full
  suite runs everything at `ptr_cells=false` (gate-count-proven byte-identical),
  so it cannot catch an lf14 regression the targeted gate doesn't → pushed with
  `SKIP_PUSH_TESTS=1` (principled, per the isolation argument).

## Runway handoffs (next walls, now concrete)
- `rehash!` → **Bennett-4mmt** (U14 atomic-load) → then `jl_alloc_genericmemory`
  → **bennettvm-416r.12** (CW-D2 intrinsic whitelist).
- `setindex!` → a VoidType/U81 void wall (body).
- `ht_keyindex2` → **Bennett-59zi** (recursive sret self-call + memcpy).
- root → `julia.get_pgcstack` (**Bennett-6x2w**).
All + CW-D3 + 90l remain before `bennettvm-7xa`.
