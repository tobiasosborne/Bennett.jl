## NEXT AGENT — start here — 2026-04-24 (evening session close)

**Two more catalogue items shipped; all of Section A (U01–U31) + two of
Section B (U53, U58) + one Section C (U100) now closed. Section B has 33
items remaining, Section C has 85, Section D has 20 — ~138 remaining out
of 173 total.** `Bennett-cc0.5` and `Bennett-z2dj` still in-progress and
carry forward.

### What shipped in the evening session

Two RED-GREEN catalogue closes, plus a preparatory sync commit to get
the embedded-Dolt state aligned with the canonical remote.

| Bead | U# | One-line | Effect |
|---|---|---|---|
| — | — | `d4bd7ac` bd: sync dolt cache | Pulled Dolt remote into committed cache; noms/vvvvv was 3 bytes ahead of `e1bd81a`. Prepared the tree for further bd operations. |
| Bennett-sljv | U53 | refresh CLAUDE.md §6 baselines | 86/174/350/702 → 58/114/226/450 (post-U27/U28). Scaling: `total(2W) == 2·total(W) - 2`, `T(2W) == 2·T(W) + 4`. Added pointer to `test_gate_count_regression.jl`. |
| Bennett-zc50 | U100 | simulate preserves signedness | `UInt8` in → `UInt8` out; tuple outputs keep declared widths with input-derived signedness. Width-alignment gate protects packed inputs (`NTuple{3,Int8}` as `UInt64` still → `Int8`). 10 test files' `reinterpret(UIntN, IntN(simulate(...)))` workarounds dropped. |

Filed as follow-up but not worked: **Bennett-ji9n** (CLAUDE.md §2 and
§93 still reference the old filename `bennett.jl`; the file was renamed
to `bennett_transform.jl`).

### Velocity on the catalogue — honest measurement (and why my first estimate was wrong)

**Closed so far**: 35 of 173 Uxx items. Wall-clock observations:

| Day | Span | Items | Min/item | Shape |
|---|---|---|---|---|
| 04-22 | 2h 51m | 7 (U01–U06, U49) | 24 | Meta-bug U01 unlocks everything below |
| 04-23 AM | 2h 16m | 8 (U07–U14) | 17 | ir_extract fail-loud rhythm; peak velocity |
| 04-23 PM | 2h 25m | 12 (U15–U26) | 12 | Some bundled 2-in-1s; still single-site |
| 04-24 AM | 2h 16m | 6 (U27–U31, U58) | 22 | Dispatcher tweaks, partition invariants |
| 04-24 PM | 56m | 2 (U53, U100) | 28 | U100 dragged 10 test files into a cascade |

Initial extrapolation from these numbers (my first pass, recorded here
because it's useful to remember the failure mode): Section B 33 × 60min +
Section C 85 × 20min + Section D 20 × 10min = **~64h active**. User
pushed back: **that's off by a factor of 5–10×**. Realistic is
**~320–640h of active work** — months of half-days, not weeks.

Why the naive estimate was too optimistic:

1. **Section A's 17 min/item pace is an artefact of the easy-tail distribution**.
   Most of U07–U26 were identical-shape fail-loud asserts. Muscle
   memory, not deepening understanding. That pace doesn't generalise
   to heterogeneous work.
2. **3+1 refactors are the real variance, and my estimate was 60min**.
   U40 (split `lower.jl`, 2,662 LOC) is not a 1-hour task — it's
   multi-session: proposer divergence, synthesis, cascade regression.
   Similarly U41 (`_convert_instruction` god function), U43
   (`LoweringCtx::Any`), U55 (bennett-variant collapse), U69 (legacy
   phi resolver). Each is 4-12h of active work, not 1h.
3. **Test cascade is underestimated**. U100 fixed 4 lines in
   `simulator.jl` and dragged 10 test files behind it — each needed
   inspection to tell "was this a workaround?" from "does this test
   actually care about signed output?". Multiply across 138 items.
4. **Infrastructure friction is real**. Dolt remote HTTPS↔SSH drift
   (see below), pre-push hook ~4min, Pkg.test ~5min per cold run,
   bd sync cadence, context-load per session. Each session eats
   30-60min of non-work overhead before the first productive edit.
5. **Section B items interact**. U54 (persistent-DS EoL) blocks U57
   (peepholes) and simplifies T5-P6. U40 (split lower.jl) touches
   everything else under B. Can't pipeline them independently.
6. **The items get harder from here**. Section A was CRIT + HIGH-easy.
   Section B is HIGH-structural. Section C is MED. If the MED items
   have the complexity of "single-site but touches a hot path" — which
   is what MED usually means — the 20min estimate is wrong too.

Revised wall-clock projection at sustainable rate (user's calibration):
**several months of steady 3-4h/day work**, not weeks. Not all 138
items are equally worth closing — the structural ones (U40, U41, U43,
U55, U69) gate the paper and T5-P6 more than the long MED tail does.

### Gotchas found this session

1. **Dolt remote silently reverts to `git+https://`** in this checkout,
   even after you fix it to SSH. Symptom: `bd create` / `bd close` /
   `bd dolt push` fail with
   `fatal: could not read Username for 'https://github.com': No such device`.
   Fix (matches the existing `bennett-beads-dolt-ssh-fix` bd memory):
   ```
   pushd .beads/embeddeddolt/beads >/dev/null
   dolt remote remove origin
   dolt remote add origin git+ssh://git@github.com/tobiasosborne/Bennett.jl.git
   popd >/dev/null
   ```
   Hit this twice in one session — needs a bead to investigate why the
   URL drifts back. Candidate root causes: some `bd` command rewrites
   the remote; or `repo_state.json` is the wrong file being checked.

2. **`repo_state.json` carries env-specific `/home/tobias/…` path**.
   Committed form has `/home/tobias`, this machine is `/home/tobiasosborne`
   — every `bd dolt pull` re-dirties this file. Workaround: after pull,
   `git checkout -- .beads/embeddeddolt/beads/.dolt/repo_state.json`
   to preserve the committed form. Real fix: add that single file to
   `.gitignore`, or make the backup path relative. Needs a bead.

3. **`widths_align` heuristic in `simulate` is a guess, not a proof**.
   `src/simulator.jl` now infers unsigned output iff `input_widths ==
   output_elem_widths` AND all inputs Unsigned. Two known edge cases
   where this guesses wrong (documented in the commit):
   - `unsafe_trunc(Int64, x::Float64)` compiled against `Tuple{Float64}`,
     called via `reinterpret(UInt64, x)` — heuristic says unsigned
     (widths match, input UInt64), function declares Int64. Test
     normalises via `% Int64`.
   - Heterogeneous tuple returns like `Tuple{Int8, UInt16}` — no
     per-element signedness record on the circuit.
   Proper fix is to carry `input_types::Vector{DataType}` +
   `output_elem_types::Vector{DataType}` on `ReversibleCircuit`, but
   that's CLAUDE.md §2 core-change territory — needs 3+1.

### Recommended next-session starting points

1. **Bennett-p94b (U110) phi-resolver mutex assert** — small, tight,
   lives in CLAUDE.md's highest-risk zone. Two `@assert`s + diamond-CFG
   RED test. ~45 min if nothing goes sideways.
2. **U54 decision** — delete-or-archive persistent-DS impls (`hamt`,
   `cf`, `okasaki`, ~1,500 LOC of losing strategies). Needs user ruling.
   Unlocks U20/U21/U22 (bug fixes in those impls become wontfix) +
   simplifies T5-P6.
3. **Bennett-ji9n** — two-line CLAUDE.md filename drift fix. 5 min
   snack-task if context allows.

Avoid until ready for a multi-session block:
- **T5-P6 (Bennett-z2dj)** — claimed, 13-step plan in
  `docs/design/p6_consensus.md`. Depends on U54 verdict.
- **3+1 refactors** (U40/U41/U43/U55/U69) — each a dedicated session,
  not a snack.

### Previous context (superseded by above but kept for continuity)

### What shipped today

Six HIGH-severity catalogue beads closed with RED→GREEN TDD
(compile/verify/simulate all green after each), plus an infrastructure
change (no CI policy + local pre-push hook).

| Bead | U# | One-line | Headline effect |
|---|---|---|---|
| Bennett-epwy | U28 | `fold_constants` default → `true` | Post-fold poly 872→562 gates; `_fold_constants` preserves self_reversing |
| Bennett-b1vp | U31 | `soft_fptoui` + `LLVMFPToUI` dispatch | fptoui was signed-routed; fixed bit-exact vs native |
| Bennett-xlsz | U29 | Unified kwargs across 3 overloads | MethodError → ArgumentError; `add`/`mul`/`fold_constants` now reach Float64 |
| Bennett-4fri | U30 | `target=:depth` kwarg on mul dispatcher | Promotes `mul=:auto`→`qcla_tree`; 3-6× T-depth win at W≥32 |
| Bennett-spa8 | U27 | `add=:auto`→`:ripple` (was Cuccaro) | i8 x+1 100→58 gates, depth 28→12; fixes value_eager SHA-256 invariant |
| Bennett-6azb | U58 | simulator input-preservation + partition | Caught a real latent bug in `controlled()` |
| — | (§14) | CLAUDE.md §14 no GitHub CI + `scripts/pre-push` | Local quality gate; `SKIP_PUSH_TESTS=1` escape hatch |

### Big-picture wins

**Gate-count baselines rewritten.** U27+U28 interact to roughly
halve every integer-add baseline. CLAUDE.md §6's "key baselines"
line (86/174/350/702) is now triply stale — was 100/204/412/828
after U28 updated `test_gate_count_regression.jl`; now 58/114/226/
450 post-U27. U53 (refresh CLAUDE.md §6) is the cheapest next win.

**value_eager SHA-256 unblocked as a side-effect.** `test_value_
eager.jl:166` was `@test_broken` because Cuccaro's in-place adder
wrote to wires still live later in Kahn's reverse-topo. With U27's
ripple default, writes go to fresh wires; `verify_reversibility`
passes. Upgraded to `@test`. The `Bennett-ca0i` (U02-followup) bead
is effectively resolved for SHA-256; can be closed separately.

**Partition assert caught a real bug in `controlled()`.** U58's
new `ReversibleCircuit` inner constructor surfaced that the
`controlled` wrapper was adding `ctrl_wire` without classifying it —
every wrapped circuit had an unaccounted wire. Fixed by making
ctrl the inner's first input. Side benefit:
`verify_reversibility(cc::ControlledCircuit)` now delegates to the
`ReversibleCircuit` probe — no duplicate probe code.

**`fptoui(1e19, UInt64)` is correct again.** U31: before the fix,
the LLVM `fptoui` opcode was silently routed through the signed
`soft_fptosi`, corrupting every in-range UInt64 value whose MSB
was set. Julia's `unsafe_trunc(UInt64, 1e19)` is a legitimate use
site; this was a live bug.

### Infrastructure / policy

**CLAUDE.md §14 — no GitHub CI.** User has a durable rejection of
GitHub Actions / remote automation: failure-email noise is "worse
than zero info — garbage noise." Added as a NON-NEGOTIABLE rule:
no `.github/workflows/`, no propose-CI beads, no email-on-failure
services. Future agents must substitute local gates. Saved as a
feedback memory (`feedback_no_github_ci.md`) so the rule carries
across projects, not just Bennett.jl.

**Local pre-push hook replaces CI.** `scripts/pre-push` runs
`Pkg.test()` before every `git push`, aborts on failure. Installed
via `scripts/install-hooks.sh` into `.git/hooks/pre-push` (both
versioned in `scripts/` so a fresh clone can re-install with one
command). Escape hatches: `SKIP_PUSH_TESTS=1` to bypass for WIP /
docs / emergency; `BENNETT_HOOK_CMD=...` to override the command.
All four paths smoke-tested before landing.

### Test files added / modified this session

Added (6 new RED-GREEN test files, all registered in `runtests.jl`):
- `test/test_epwy_fold_constants_default.jl` (264 asserts)
- `test/test_b1vp_fptoui.jl` (40 asserts)
- `test/test_xlsz_kwargs_unified.jl` (23 asserts)
- `test/test_4fri_mul_target.jl` (36 asserts)
- `test/test_spa8_add_auto_ripple.jl` (33 asserts)
- `test/test_6azb_input_preservation.jl` (387 asserts)

Baseline-cascade updates (U27+U28 rippled through pinned gate
counts):
- `test/test_gate_count_regression.jl` — every addition baseline;
  scaling invariant `2W+4`→`2W-2`; Toffoli counts halved
- `test/test_sret.jl`, `test/test_0c8o_vector_sret.jl` — swap2
  total 82→66 (post-fold)
- `test/test_uyf9_memcpy_sret.jl`, `test/test_egu6_self_reversing_
  check.jl`, `test/test_httg_loop_multiblock.jl` — i8 x+1 100/28→
  58/12 (post-U27/U28)
- `test/test_value_eager.jl`, `test/test_pebbled_wire_reuse.jl` —
  added `fold_constants=false` at every `lower()` call site where
  the test consumes `lr.gate_groups` (fold invalidates them);
  SHA-256 `@test_broken` upgraded to `@test`
- `test/test_soft_mux_scaling.jl` — gate-level scaling test now
  measures pre-fold to keep the N=4 < N=8 invariant robust
- `test/test_add_dispatcher.jl` — `:auto != :ripple` probe
  inverted to the intended `:auto == :ripple` (U27); cuccaro
  distinguished via the explicit kwarg
- `test/test_toffoli_depth.jl` — `_mk` helper classifies every wire
  as ancilla to satisfy U58's partition invariant

### Learnings / gotchas worth keeping

1. **`_fold_constants` silently cleared `self_reversing`** via the
   7-arg `LoweringResult` constructor. A self-reversing primitive
   routed through fold would have been double-run by `bennett()`.
   Fix was an early-return on `lr.self_reversing`. Look for
   similar additive-passes-that-drop-fields bugs in other LR-
   rewriting transforms.

2. **`simulate` returns `Int64` for i64 outputs regardless of
   Julia signedness.** `reinterpret(UInt64, simulate(c, xb))` or
   `simulate(c, xb) % UInt64` for bit-exact comparisons. Logged
   as `Bennett-zc50` (U100, P3) — quick next-session fix.

3. **Variant-Bennett tests must opt out of fold.** `value_eager_
   bennett`, `pebbled_group_bennett`, `checkpoint_bennett` all
   consume `lr.gate_groups`. `_fold_constants` rewrites the gate
   list and empties groups, so the variants silently fall back to
   full `bennett`. Pass `fold_constants=false` to `lower()` in any
   test that's actually exercising a variant's optimisation path
   (correctness paths are fine either way — fallback is safe).

4. **Cuccaro's in-place 1-wire saving is erased by Bennett copy-
   out.** The theoretical advantage doesn't survive the
   reversibilisation pass, while Cuccaro's MAJ/UMA chain ships a
   strictly worse Toffoli-depth. Ripple wins on every measured
   metric at every width. `:auto` should have been `:ripple` from
   day one; Cuccaro was a premature optimisation.

5. **`target=:depth` pre-resolution at `lower()` entry** avoids
   plumbing a new field through `LoweringCtx` (which per §2 is a
   "core change" demanding 3+1). Rewriting `mul=:auto` to
   `:qcla_tree` up-front lets every downstream site treat it as
   user-explicit. Pattern reusable for future target-aware
   heuristics.

6. **Beads sync to GitHub through `.beads/`** — no separate sync
   step. `bd dolt push` updates the embedded-Dolt git-remote-cache
   inside `.beads/`; `git push` ships everything in the working
   tree. If `.beads/push-state.json` is recent and `git status` is
   clean, beads are on GitHub.

### What's left — priority ordering for next session

**Phase 0 P1 catalogue is empty except for Bennett-cc0 (memory
epic parent, already has in-progress children).**

**Highest-leverage next beads (all P2, catalogue-HIGH):**

1. **U53 (no bead yet) — refresh CLAUDE.md §6 baselines.** Now
   triply stale. Cheap chore (~30 min).
2. **U57 (Bennett-5qrn) — trivial peepholes (x+0, x|0).**
   Extends U28's fold arc. Catalogue claims 20-40% gate reduction
   on persistent-DS sweep, though U54 EoL may delete the
   beneficiary.
3. **U100 (Bennett-zc50) — simulate signedness loss.** Caught it
   myself during U31 work; shallow fix, high ergonomic payoff.
4. **U110 (Bennett-p94b) — phi-mutex assert.** P3 but phi-
   territory is CLAUDE.md's highest-risk zone. Consider escalating
   to P2.
5. **U54 — persistent-DS EoL** (delete ~1,500 LOC of losing
   impls). **Needs user decision** — delete vs move to
   `src/persistent/research/`. Subsumes U20/U21/U22 fixes.
6. **U47 (Bennett-59jj) — type instability in hot paths.** Bigger
   lift; needs profiling pass first.

**3+1 refactor clusters (each a separate session):**
- U40 / U41 / U42 — split `lower.jl` (2.6k LOC) / kill
  `_convert_instruction` god function / delete `ir_parser.jl`.
- U43 / U44 / U69 — concretise `LoweringCtx` `::Any` fields /
  delete legacy phi resolver.
- U55 — collapse five `*_bennett` variants into `BennettStrategy`.

**Session-close context for the next agent:** the pre-push hook is
active and will run `Pkg.test()` (~4 min) before every push. Set
`SKIP_PUSH_TESTS=1` if you've already run the suite in the same
shell session and want to skip the retry. The hook file lives at
`scripts/pre-push` (versioned); `scripts/install-hooks.sh` installs
it into `.git/hooks/` after a fresh clone.

---

## NEXT AGENT — previous context — 2026-04-24 (Phase 0 P1 catalogue grinding, continued)

**19-report code review (2026-04-21) has been triaged into 173 beads with a
unified catalogue at `reviews/2026-04-21/UNIFIED_CATALOGUE.md` and a
U#→bead-ID crosswalk at `reviews/2026-04-21/CATALOGUE_TO_BEADS.md`.
Phase 0 continues; U01–U26 closed previously. U28 closed today.**

