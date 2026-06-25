# Worklog chunk 090

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
