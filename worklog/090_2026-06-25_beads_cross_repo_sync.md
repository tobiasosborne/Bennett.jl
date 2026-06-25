# Worklog chunk 090

## Session log — 2026-06-25 — Bennett-qmv7: gc_loaded heap-Memory value-store memcpy under ptr_cells (3+1 implementer)

**FULL-SUITE POSTSCRIPT (orchestrator, post-push).** The qmv7 push's pre-push
`Pkg.test()` FAILED on `689837 passed, 1 failed` — a single fragile assertion in
qmv7's OWN test, **GATE (d)** (`test_qmv7_gc_loaded_memcpy.jl:341`), NOT a source
regression (the source's deterministic peers + 34/34 all passed; gate-count 39/39).
Diagnosis: GATE (d)'s `:err` branch pinned the EXACT `--check-bounds=yes`
downstream wall to a `ptrtoint`/iwo9 disjunction. But the wall is **registry-
ORDER-dependent**: `test_59zi` registers `ht_keyindex2_shorthash!`/`rehash!` and
**leaks them into the global `_known_callees`**, so when GATE (d) later extracts
`setindex!` the recursive walk advances PAST the iwo9 wall to the **dq8l/U81
VoidType `_type_width`** wall — a message outside the disjunction. Passes
standalone (clean registry → iwo9), fails in-suite (polluted registry → dq8l).
The load-bearing MODE-INVARIANT negative (`!_is_37mt_dst_wall`) PASSED — qmv7's
guarantee (memcpy wall gone) holds in every context; only the over-specified
positive failed. Fix: broadened GATE (d) to accept BOTH walls (kept the
negative). Reproduced the suite order (`include 59zi; include qmv7` under
`--check-bounds=yes`) → 545/545 + 34/34 green. **Lessons:** (1) a per-file
"green" can mask a suite-order failure — registry-sensitive extraction tests
must not pin order-dependent outcomes; (2) the 32-thread vs 1-thread difference
between the 59zi (passed, pre-qmv7) and qmv7 (failed) pushes was a RED HERRING —
the failure was deterministic suite-order, the thread count coincidental;
(3) the `pkill -f "Pkg.test"` I used to kill a diagnostic run left the child
`runtests.jl` alive (its cmdline lacks "Pkg.test") → a stray suite oversubscribed
the cores; kill the `runtests.jl` child too. Registry-isolation hygiene filed as
**Bennett-6rqq**.

**Orchestrated 3+1** (2 Opus proposers → A explicit-split / B reuse; Opus
implementer; orchestrator +1). Cleared the `setindex!(Dict{Int8,Int8})` extraction
wall at `instructions.jl` Predicate-6 (`dst_root === nothing`): the Int8
value-store memcpy whose DST is a RUNTIME-indexed `julia.gc_loaded` heap-Memory
cell (`memcpy(p0 %memoryref_data40, p0 %sret_box, 1)` where dst =
`getelementptr i8, ptr %gc_loaded, i64 %byteoffset`). The dual of vbv9 (const-offset
gc_alloc ARENA dst); here the byte offset is RUNTIME (`mul %off, STRIDE`).

**The decisive probe (Rule 10) — B's "already-named IRVarGEP" claim is TRUE, but
reusing it is eln6-WRONG.** Instrumented `_handle_memcpy_arm` to print
`names[dst_v.ref]` at memcpy time: `dst_named=true, dst_sym=:addr` — the dst GEP IS
already lowered to a named `IRVarGEP(:addr,:d,:bo,8)` before the memcpy processes
(B's load-bearing claim confirmed). **BUT** that IRVarGEP is BYTE-OFFSET-indexed
(index=`:bo`, the `mul %off, STRIDE` result) at the i8 GEP width 8. For
`Dict{Int8,Int8}` (STRIDE=1) `bo==off` (coincidence), but for an **i64-vals**
Memory (STRIDE=8) the real GEP is `getelementptr i8, ptr %d, i64 (off*8)` so
`:bo == off*8` → BVM's stride-1-cell VarGEP would address **cell off*8, an 8×
misaddress** (the exact eln6 trap). **So pure B-reuse is unsafe for the general
case.** Probed `Dict{Int64,Int64}` to ground-truth this: confirmed the i64 value
GEP is i8-typed with a `mul %off, 8` index — NOT the element-typed `getelementptr
i64, ptr %d, i64 %off` B's design §3c *assumed* (B's i64-GEP claim was WRONG).

**Design path = HYBRID (B's recognition + A's eln6-safe emission).** Recognise the
gc_loaded dst (B), but RECOVER the raw element index by splitting `mul %off, STRIDE`
(A / the proven `vector_vm_walk.jl` D6 pattern) and emit a FRESH
`IRVarGEP(dst, gc_loaded_base, %off, value_ew) + IRLoad(src) + IRStore` at the VALUE
width. Probe-verified emission: i8 → `IRVarGEP(:__v4,:d,:off,8)`; i64 →
`IRVarGEP(:__v4,:d,:off,64)` — **index is the RAW `%off` (cell `off`), NEVER the
byte offset `%bo`; width is N*8 (the Memory element width), NEVER the i8 GEP type,
NEVER blind 64.** The dead `IRVarGEP(:addr,...,:bo,8)` (the dst GEP's own lowering,
now unconsumed) is harmless dead SSA.

**The value-width source — NOT the src alloca.** First cut derived `value_ew` from
`_alloca_elem_width_bits(src_root)` and it RED-failed the i8 fixture: the src is the
setindex! sret box `alloca [2 x i64]` (→ 64) read via a const-i8-GEP, so the box
width mis-reports 64 for an i8 store. Fix: `value_ew = N*8` (the memcpy byte count),
gated on `N == stride_bytes` (single element) so all three (N, stride, value width)
agree. Reject multi-element (N != stride) loud (`Bennett-qmv7-multi`).

**Changes (Bennett.jl only, additive):**
- `src/extract/instructions.jl`: `_gc_loaded_dst_elem_ref` (~70 LOC, recognises
  `gep i8 (gc_loaded), (mul %off, STRIDE)` → `(gcl_ref, off_ref, stride)`); a
  `ptr_cells && dst_root===nothing` dispatch in `_handle_memcpy_arm` Predicate-6
  (~12 LOC); `_handle_memcpy_gc_loaded` (~75 LOC). NO new IR node (reuses
  IRVarGEP/IRLoad/IRStore — Rule 12). `ptr_cells` already threaded by vbv9.
- `test/test_qmv7_gc_loaded_memcpy.jl` (new, 5 gates) + `runtests.jl` registration.

**Gating (orchestrator point 3):** the `if ptr_cells && dst_root===nothing` branch
is the only entry; circuit path (`ptr_cells=false`) falls to the BYTE-IDENTICAL
302 reject — proven by GATE(b) (same fixture, cells=false, unchanged 37mt wall) and
gate_count 39/39 unchanged.

**Fail-loud matrix (Rule 1):** multi-element (N!=stride) → `qmv7-multi`; src not
alloca → `qmv7` src reject; value_ew ∉ {8,16,32,64} → reject; non-`mul` index (e.g.
`add %idx, 3`) → `_gc_loaded_dst_elem_ref` returns nothing → UNCHANGED 302 wall
(proven: the recogniser is narrow, no previously-rejected program silently passes).

**RED→GREEN.** RED: new test vs `git show HEAD:instructions.jl` = 12 pass / 5 fail
(GATE a/c/d/e fail; b passes = current behaviour, correct). GREEN:
`--check-bounds=yes` 34/34, no-bounds 35/35.

**Bennett-2mj3 (--check-bounds=yes) gotcha — WRITE THIS DOWN.** Under suite mode
(`--check-bounds=yes`) `code_llvm` for `setindex!` emits EXTRA bounds-check IR that
surfaces the EARLIER `ptrtoint ptr %memory_data to i64` GenericMemory wall
(Bennett-iwo9 / jfw6) at block L8 BEFORE the memcpy — so under suite mode setindex!
walls at the ptrtoint, NOT clean-extract. Under `optimize=false` WITHOUT bounds
checks it extracts CLEAN (ret_width=64, 12 blocks — the bead's recon shape). The
memcpy wall (qmv7's target) IS cleared in BOTH modes (the synthetic .ll GATE-a/c
prove it directly; no-bounds setindex! proves the full extraction). GATE(d) is
written mode-INVARIANT: the load-bearing assertion is NEGATIVE (no longer the memcpy
dst wall) + an inclusive disjunction; the clean-extract branch fires only off-bounds.

**Wall-walk result.** The memcpy "not alloca-backed" wall is GONE. Next setindex!
wall (suite mode) = the **iwo9/jfw6 ptrtoint GenericMemory data-pointer** wall —
the next CW-D frontier (separate bead, the "LINCHPIN" Bennett-jfw6). NO new
extraction-side interlock (unlike vbv9's G5).

**Cross-repo (orchestrator point 6) — NO BVM change for EXTRACTION.** Verified
`BennettVM/src/ir/ingest_body.jl`: `IRVarGEP→VarGEP(stride=1 cells)`,
`IRLoad→MemoryLoad`, `IRStore→MemoryStore` all ingest the qmv7 emission unchanged.
The DOWNSTREAM execution blockers (separate beads, NOT solved here): (1) the
`julia.gc_loaded` IRCall is in NEITHER `_HEAP_DISPATCH` nor
`_NONDETERMINISTIC_CALLEES` (`ingest_call.jl:124,144`) → fail-loud allowlist reject
at BVM execution — needs a `bennettvm-qmv7-gcloaded` BVM bead (model gc_loaded as a
data-ptr passthrough). (2) jfw6 GenericMemory virtual-base binding (the heap Memory
needs a concrete VM base for VarGEP/MemoryStore to resolve a real cell).

**Peer regressions GREEN (suite mode):** gate_count 39/39 (zero drift), vbv9 19/19,
6bu3 162/162, ares 57/57, lf14 27/27, beaw 17/17, 37mt 86/86, doih 85/85, ixiz
53/53, lqif 12/12, uyf9 11/11, iwo9 30/30, haiy 39/39, r92o 22/22, lower 6/6.

**Cleared / NOT cleared (honest).** CLEARED: the setindex! memcpy *extraction* wall
(both modes); the eln6-safe raw-index emission for ALL Memory widths (i8 AND i64
proven). NOT cleared (out of scope, downstream beads): the BVM gc_loaded IRCall
ingest, jfw6 base binding, the full fdict e2e run (still ~several walls + the two
BVM beads away). Multi-element heap memcpy fails loud (qmv7-multi follow-up).

## Session log — 2026-06-25 — Bennett-59zi: sret-returning CALL → memcpy(sret) forwarding (3+1 implementer)

Cleared the EXTRACTION wall for `Base.ht_keyindex2_shorthash!` (CW-D fdict
runway, blocks `bennettvm-7xa`). The recursive-tail block forwards a recursive
self-call's `sret({i64,i8})` result into the parent sret via a local alloca +
whole-aggregate `llvm.memcpy`. Implemented per the 3+1 adjudication (reuse
`IRCall→IRRet`, NO new IR subtype; recognise in the sret PRE-WALK; bind by
call-site `sret` attr + data-flow, not textual adjacency).

### TWO walls, not one (Proposer B was right; A's "padding already tolerated" was WRONG)

Re-confirmed empirically (Rule 10): neutralized the Wall-A reject, re-extracted,
and the NEXT error was the L5 padding memcpy `memcpy(%sret_return+9, <[7 x i8]
junk>, 7)` hitting `_handle_memcpy_arm`'s "dst not alloca-backed" reject. So BOTH
walls had to close:
- **Wall A** (`_try_handle_sret_memcpy_reject!` triage, now a recognise/reject
  split): `memcpy(dst===sret_param, src===call-sret alloca, N==agg_byte_size,
  non-volatile)` → record a `SretCallReturn`, suppress box/memcpy/producing-call,
  re-synthesize ONE `IRCall` (ret_width from the PARENT sret packed width — the
  void producing call has no width) → `IRRet`. The call-return block is EXCLUDED
  from `ret_void_blocks` (else silently dropped) and becomes its own value-bearing
  IRRet, merged by the existing `resolve_phi_predicated!` (no new merge/false-path
  surface).
- **Wall B** (`_try_handle_sret_padding_memcpy!`): an sret-derived GEP memcpy
  whose byte range is DISJOINT from every field byte-range → INERT, suppressed.
  Range OVERLAPPING a field → loud reject (value-write via memcpy out of scope).

### Gotchas a future agent will want

- **SROA scalarizes a const-size memcpy from a fresh junk alloca into a `store`**,
  so the Wall-B *padding* / *overlap* `.ll` fixtures must use a `ptr` PARAMETER
  src (which SROA can't scalarize) for the memcpy to survive to the classifier.
  A junk-alloca src becomes `store iN undef, ...` and hits the EXISTING
  scalar-store "matches no field" reject instead (still loud — different message).
- **THIRD wall under `--check-bounds=yes`** (the Pkg.test mode, Bennett-2mj3):
  after 59zi, ht_keyindex2 extracts fully under DEFAULT bounds (ret_width=72, 6
  IRRet blocks, 1 recursive IRCall), but under `--check-bounds=yes` Julia codegen
  emits an extra `ptrtoint ptr %memory_data to i64` in L71 that hits the
  pre-existing **iwo9** ptrtoint reject — unrelated to 59zi. The 59zi test handles
  both modes; filed as **Bennett-kvdv**.
- **`counter` (Ref{Int}) is shared** between the pre-walk and the second pass;
  `_auto_name` is monotonic so the synthesized IRCall dest never collides with a
  second-pass temporary. The pre-walk runs AFTER the naming pass (module_walk:264),
  so the counter is already past all named instructions.

### Files changed (additive, no ir_types/lower/bennett_transform touched)
- `src/extract/sret.jl`: `SretCallReturn` record; +2 `SretWrites` fields
  (`block_call_returns`, `call_return_suppressed`); Wall-A triage + Wall-B padding
  classifier; R12 both-shapes assert; `ret_void_blocks` excludes call-return
  blocks; empty-store assert relaxed; `_collect_sret_writes` takes `counter`.
- `src/extract/module_walk.jl`: `sret_call_return_block` classification;
  suppression skip; post-loop `IRCall→IRRet` synthesis; pass `counter`.
- `test/test_59zi_sret_call_memcpy.jl` (new, registered): leaf `.ll` fixture
  END-TO-END (`verify_reversibility` + exhaustive 256-input simulate, caller==leaf),
  Wall-B padding variant, 7-row reject matrix (each with Bennett-59zi breadcrumb),
  ht_keyindex2 extraction-shape-only (both bounds modes).

### Verification
- 59zi test: 545 pass (`--check-bounds=yes`), 546 pass (default bounds). RED→GREEN.
- Peers ALL green: test_sret 4195, jghk 43, dv1z 142, uyf9 11, 0c8o 103, land 65,
  6bu3 162, q04a 9, 0zsk 16, atf4 23, ir_extract 8, beaw 17, k3ej 29.
- **Gate-count regression 39/39 UNCHANGED** (add=:ripple baselines untouched).
- d1b julia_set: 30 pass + 1 broken (GATE-E still `@test_broken` — 59zi alone does
  NOT flip it, as predicted; gated on 6x2w/lf14 + Bennett-t7zu self-recursive
  lowering + Bennett-kvdv iwo9 wall).

### SCOPED OUT (filed)
- **Bennett-t7zu** (P3): lower the self-recursive sret callee to a circuit
  (bounded-unroll / fixpoint inlining) — `lower_call!` recurses unboundedly today.
- **Bennett-kvdv** (P3): the iwo9 `ptrtoint ptr %memory_data` wall under
  `--check-bounds=yes`.

---

## Session log — 2026-06-25 — Cross-repo beads sync (Bennett.jl + BennettVM.jl) + orientation

Operational session: bring beads into sync via git and reconcile the local
dolt DBs via `bd import` in **both** repos. No source/compiler changes. Also
re-familiarised with both projects (BennettVM orientation via a read-only
Explore subagent — Phase 2 production, CW-D closed-world Julia producer the
active front, epic `bennettvm-416r.11`).

### The two repos use DIFFERENT beads-over-git sync models — this matters

- **Bennett.jl — embedded-dolt-IN-git.** `.beads/embeddeddolt/` IS git-tracked
  (the `dolt` remote is `git+https://github.com/tobiasosborne/Bennett.jl.git` —
  `bd dolt push/pull` rides the git remote via `git-remote-cache/`). So the
  authoritative dolt store travels in git commits; `issues.jsonl` is a
  secondary export.
- **BennettVM.jl — jsonl-ONLY.** `.beads/embeddeddolt/` is NOT tracked
  (0 files in `git ls-files`). Bead state crosses machines purely through the
  git-tracked `.beads/issues.jsonl`. The local dolt DB is per-machine, so
  `bd import .beads/issues.jsonl` is the ONLY way it picks up a peer's changes.

Implication: in BennettVM, `git pull` alone leaves the local dolt DB stale —
the `bd import` step is load-bearing, not cosmetic.

### Bennett.jl — what was found and done

- Was **10 commits behind** origin/main (the 2026-06-23 CW-D cluster:
  3ptu/iwo9/r92o/beaw/vbv9/6bu3/...), 0 ahead. 8 untracked `git-remote-cache`
  objects were **byte-identical** to objects already in origin/main
  (content-addressed) — removed them to unblock a clean fast-forward; the pull
  restored them as tracked.
- **GOTCHA — origin's own `issues.jsonl` was stale.** The dolt store advanced
  to **575** issues across those commits but `issues.jsonl` was never
  re-exported, leaving it pinned at **568**. A fresh clone doing `bd import`
  would have loaded a stale snapshot (missing 7 beads: amah/beaw/eln6/pljv/
  r92o/sxse/vbv9; and 5 state changes: 37ib/3ptu/6bu3/iwo9 closed, 8bys
  updated). Regenerated the export and committed it (`08a5c0e`, jsonl-only).
- **GOTCHA — `repo_state.json` carries a machine-specific path.** `bd import`
  dirtied the dolt working set, incl. flipping the `backup_export` URL from
  `/home/tobiasosborne/...` (origin's machine) to `/home/tobias/...` (this
  machine). That ping-pongs between the user's two machines — **reverted** the
  embeddeddolt churn; committed ONLY `issues.jsonl`. (The dolt store already
  had all 575 pre-import, so reverting lost nothing.)
- Pushed with `SKIP_PUSH_TESTS=1` (the pre-push hook's own sanctioned escape
  hatch for docs/beads-only pushes — no source changed, so `Pkg.test()` is
  unaffected). Final: 0/0, clean.

### BennettVM.jl — what was found and done

- Was **2 commits behind** origin/master (140766e 6bu3 consumer + 3760f8b
  CW-D3 Lever 3), 0 ahead. Had a **staged 217-line `issues.jsonl` rewrite**
  that turned out to be a **stale, lossy older export**: semantically it
  differed from origin by exactly one bead (`416r.12` open/2026-06-10 vs
  origin in_progress/2026-06-23) and it had **dropped the lone memory record**
  (`case-b-closed-world-settled`). Discarded it (no unique local state), then
  fast-forwarded.
- `bd import` then upserted origin's jsonl into the local dolt DB:
  416r.12 → in_progress/2026-06-23, memory re-imported. ("216 issues + 1
  memory".)
- **GOTCHA — bd's auto-export drops memories.** After import, bd auto-re-staged
  `issues.jsonl`, and that re-export (a) was 0-semantic-diff vs origin for all
  216 issues but 435 lines of pure reordering churn, AND (b) **dropped the
  memory line** (default `bd export` excludes memories unless
  `--include-memories`). Committing it would delete the memory from the
  git-tracked export and ping-pong serialization with the other machine —
  **reverted** it, keeping origin's canonical jsonl (memory intact). Net:
  nothing to commit (BennettVM was purely behind); final 0/0.

### Reusable lessons

1. After any `bd import`, **diff semantically (id,status,updated_at) before
   committing the re-export** — bd's default auto-export reorders every line
   and silently drops memory records. A 400-line diff is usually 0-semantic
   churn + a lost memory, not real work. Revert it unless the semantic diff is
   non-empty.
2. `repo_state.json`'s `backup_export` URL is a per-machine absolute path
   (`/home/<user>/...`); never commit its flip. It's effectively local-only
   even though it's tracked.
3. Bennett.jl's `issues.jsonl` can lag its dolt store (the dolt store is the
   git-tracked source of truth there). If you want the portable jsonl current,
   `bd import` then commit the jsonl deliberately.
