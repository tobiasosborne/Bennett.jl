# Bennett.jl Work Log

## Session log — 2026-04-27 (qxg9 bisect partial) — cf compile-time regression narrowed to a 3-commit window

**Shipped:** Bennett-qxg9 notes updated with bisect data. No source changes. Followup to the same-day 1xub close.

**Bisect data (`cf` impl, `max_n=64`, `optimize=false`, fresh subprocess via `benchmark/sweep_cell.jl`):**

| Commit (oldest → newest) | Position | Compile time |
|---|---|---|
| 992b70a (Persistent-DS sweep, 2026-04-20) | (baseline) |   36 s — FAST |
| 0ce4000 (Bennett-6t8s, ~2026-04-25)        | line 91/182  | 15.7 s — FAST |
| 9539437 (worklog: doh6 ref, 2026-04-26)    | line 137/182 | 31.3 s — FAST |
| **e4bb6cd (Bennett-5qrn / U57)**           | line 138/182 | INTERRUPTED |
| **db52e1c (Bennett-qcso / U59)**           | line 141/182 | UNTESTED (pure new compose.jl; unlikely) |
| **e8b7127 (Bennett-zmw3 / U111)**          | line 144/182 | >250 s — SLOW |
| f68b353 (Bennett-jepw / U05-followup)      | line 154/182 | >250 s — SLOW |
| fd4bd88 (Bennett-y986 / U05-followup-2)    | line 168/182 | >250 s — SLOW |
| aec5788 (HEAD, today's 1xub commit)        | line 182/182 |  1213 s — SLOW |

Regression appeared between **9539437 (FAST 31s)** and **e8b7127 (SLOW >250s)**. Two suspects in that window — both touch `src/lower.jl`'s hot path:

1. **e4bb6cd — Bennett-5qrn**: trivial-identity peephole (+121 LOC). Per-`lower_binop!` syntactic check.
2. **e8b7127 — Bennett-zmw3 / U111**: shift bounds + `resolve!` mask robustness (+47 LOC). Defensive asserts in `resolve!` — a classic O(N)→O(N²) failure mode at scale.

**db52e1c (qcso)** is a pure new file (`src/compose.jl`, +186 LOC, no callsites added to existing lowering); unlikely to cause regression but should be confirmed.

**Hypothesis:** Strongest suspect is **zmw3** based on the file scope ("resolve! mask cleanup" — `resolve!` is called O(N) times per gate at lowering, and the cf workload at max_n=64 has ~6M gates of SSA materialization to walk). 5qrn's `_try_identity_peephole!` is also called per-binop, but today's 1xub measurement showed cf max_n=16 went 5.1s (peephole on) ↔ 7.6s (peephole off) — a TINY delta that does NOT match a quadratic blowup story. So 5qrn is probably innocent on compile-time grounds, leaving zmw3 as the prime suspect.

**Why:** 1xub close (earlier today) discovered the compile-time regression while running cf max_n=64; filed Bennett-qxg9 and deferred. User asked to follow up now ("when did it appear"); bisect interrupted to switch focus. Findings preserved in qxg9 notes + this entry for the next agent.

**Methodology / gotchas:**

1. **Use `git checkout <commit> -- src benchmark`, NOT detached-HEAD checkout.** The subdir-scoped checkout leaves CLAUDE.md / WORKLOG.md / .beads/ intact, so the bisect doesn't churn the worklog. Restore with `git checkout main -- src benchmark` at the end.

2. **`git checkout <pre-tbm6-commit> -- benchmark` resurrects `benchmark/bc6_mul_strategies.jl`.** Karatsuba's `bc6` benchmark was deleted in 3da37c4 (Bennett-tbm6). Any bisect into pre-tbm6 commits brings the file back. After restoring to main, you must `git rm -f benchmark/bc6_mul_strategies.jl` — `git checkout main -- benchmark` does NOT remove paths absent from main. (Hit this in the cleanup phase of this session.)

3. **The harness is bisect-stable.** `git log 992b70a..HEAD -- benchmark/sweep_cell.jl benchmark/sweep_persistent_impls_gen.jl` returns nothing — both files are byte-identical across the entire bisect window. Safe to compare across commits.

4. **`timeout N` truncates `[compile] done in X s` printout.** The vlog line is printed AFTER the call returns, so a SIGTERM kills before the elapsed time prints. Discriminator becomes binary: completed (fast) vs killed (slow). For a quantitative wall-time, wrap the whole subprocess in `time` or `ts`. The 250s threshold is generous (>7× the 36s 2026-04-20 baseline) and reliably discriminates without false negatives.

5. **Don't bisect cf max_n=64 in a tight loop without a hard timeout.** Each slow run is 5-20 minutes. Today's HEAD measurement (peephole on, full run) was 20 min 13 s.

**Rejected alternatives:**

- **Test 5qrn first** (started, interrupted). Was running when the user asked to switch focus. The 1xub same-day measurement on cf max_n=16 (peephole on 5.1s vs off 7.6s) already weakly evidences that 5qrn is NOT the cause — the gap is too small and the wrong sign for an O(N²) blowup.
- **Run a full git bisect with --good/--bad markers.** Would require ~5-7 iterations of cf max_n=64; ~30-90 min total. Manual sampling is faster given we already have a 3-commit suspect window.

**Filed (follow-ups):** none new (qxg9 notes updated in place).

**Next agent starts here (qxg9 followup):**

1. Check out `e4bb6cd` (5qrn): `git checkout e4bb6cd -- src benchmark && timeout 120 julia --project=. benchmark/sweep_cell.jl cf 64 /tmp/scratch.jsonl`. If FAST → regression is at e8b7127 (zmw3); if SLOW → regression is at e4bb6cd (5qrn).
2. (If 5qrn FAST) confirm db52e1c (qcso) is also FAST as a sanity check, then implicate **zmw3**.
3. Read `src/lower.jl` diff for the implicated commit. For zmw3, focus on what was added inside `resolve!` — likely an assertion or mask-recompute that runs per-call instead of once. Today's chunk-043 worklog entry for zmw3 has full context.
4. **Restore working tree before commit:** `git checkout main -- src benchmark && git rm -f benchmark/bc6_mul_strategies.jl 2>/dev/null` (safe no-op if the bc6 file isn't resurrected).

**Test count:** unchanged (no source/test changes today this session).

---

## Session log — 2026-04-27 (LOC tier, BENCHMARKS.md refresh) — Bennett-1xub close (5qrn delta + sweep refresh) + Bennett-qxg9 filed (cf compile regression)

**Shipped:** see git log around the next commit. Refreshed the persistent-DS sweep:
- Added a numerical persistent-DS section to `BENCHMARKS.md` (8 cells; both impls × 5 max_n values).
- Appended 2026-04-27 (post-pipeline-improvements) rows to `benchmark/sweep_persistent_results.jsonl` (8 → 16 rows total).
- Prepended a "2026-04-27 refresh" section to `benchmark/sweep_persistent_summary.md` covering pipeline-wide gate delta, 5qrn isolated delta, and the cf compile-time regression.
- Filed `Bennett-qxg9` (P2, bug) for the cf compile-time regression discovered while running cf max_n=64.

**Why:** Bennett-1xub's directive was to "verify or adjust the bead's claim of 20-40% gate reduction" for the 5qrn peephole on the persistent-DS sweep. The catalogue claim came from review #17 H-2 — an *estimate*, never measured.

**Headline findings:**

1. **5qrn impact on this workload: 0.5–1.0%** (NOT 20-40%). The slot-preserve pattern in `sweep_ls_pmap_set/get` and cf's diff-bookkeeping lowers to `ifelse`/select chains, not `x+0` / `x*1` / `x|0`. The peephole's syntactic `IROperand` match never fires on the bulk slot-write logic; it only catches a few constant-folded perimeter ops (NOT-count differs by 18-258 per cell). The 5qrn micro-bench wins (`x*1`: 692 → 26 gates) ARE real; they just don't apply here.

2. **Pipeline-wide 3-4× improvement** since 2026-04-20 across all 8 cells, accumulated from the post-2026-04-20 commits (cc0.x ConstantExpr / SLP / pointer / phi work, fold_constants default flip, sret + callee infrastructure, Bennett-y986 loop-header dispatch, Bennett-jepw diamond phi, etc.). linear_scan per-set drops from ~1,400 to ~414 gates (asymptotically constant, both then and now).

3. **cf @ max_n=64 compile-time regression** (33.7×: 36s → 1,214s). Discovered while running the largest cf cell. Other cells got FASTER. cf's variable-depth Diff writes were always O(max_n²) in gates; what's new is the COMPILE-time being super-linear too. Filed as `Bennett-qxg9`, out-of-scope for 1xub.

**Mode:** direct grind (BENCHMARKS.md is doc-tier; not a CLAUDE.md §2 core file).

**Methodology — 5qrn isolation:**

Stubbed `_try_identity_peephole!` at entry (`return nothing` as first statement of function body), ran 5 cells (ls 4/16/64; cf 4/16). `git checkout HEAD -- src/lower.jl` restored verbatim. The reverse-apply attempt of e4bb6cd's diff failed initially (`_wmask` was added by 5qrn but later used by Bennett-zmw3 / e8b7127 — a "load-bearing helper introduced by an optimization" pattern). Worked around by stubbing the peephole entry-point rather than reverting the whole 5qrn diff. Cleanest in the end.

**Cells run (post-peephole, 8 cells):**

| impl | max_n | gates | Toffoli | wires | compile_s |
|---|---:|---:|---:|---:|---:|
| ls | 4    |     1,810 |    210 |   2,205 |    3.1 |
| ls | 16   |     6,642 |    814 |   7,413 |    3.2 |
| ls | 64   |    26,522 |  3,218 |  28,245 |    3.5 |
| ls | 256  |   106,284 | 12,830 | 111,557 |    7.4 |
| ls | 1000 |   414,028 | 50,074 | 434,357 |   76.3 |
| cf | 4    |    15,084 |    934 |  18,877 |    3.3 |
| cf | 16   |   292,528 | 25,938 | 312,985 |    5.1 |
| cf | 64   | 6,206,464 |1,025,894|5,011,657| 1213.5 |

(Pre-peephole: only ran 5 cells — ls 4/16/64 + cf 4/16 — since the 0.5-1.0% delta pattern was already established and the larger cells would just confirm it.)

**Gotchas / Lessons:**

1. **`_wmask` is load-bearing across the whole file post-5qrn.** Reverse-applying e4bb6cd's full diff broke an unrelated commit (Bennett-zmw3 / e8b7127) that started using `_wmask` after 5qrn introduced it. When isolating an optimization for measurement, prefer entry-point stubbing (`return nothing` first) over full diff revert: the optimization's helpers may have grown a second life.

2. **`sweep_cell.jl`'s log line lies.** `vlog("[compile] starting reversible_compile (optimize=true) ...")` — but the actual call at line 70 is `optimize=false`. The print message was never updated when the methodology flipped (CLAUDE.md §5). Cosmetic only; not fixed in this session (out of scope).

3. **The 20-40% catalogue estimate was a "model error" not a measurement error.** Review #17 H-2 modelled "preserve N-1 slots" as arithmetic identities (`x+0`/`x*1`). The actual lowering uses branchless `ifelse(target == i, new_val, old_val)` — these become MUX/select circuits, not zero/one-constant arithmetic. So the peephole had no path to fire on the bulk of the work. A future "ifelse(c, x, x) → copy x" peephole or "AND-with-self" peephole would target this pattern; not currently filed.

4. **cf max_n=64 took 20 minutes to compile.** Don't run the largest cf cells in a tight loop without a long timeout. The result file is correct (`verified=true`), but a future agent running `Pkg.test()` or a sweep should be aware that cf scales horribly in compile time at HEAD until Bennett-qxg9 is fixed.

5. **JSONL append > regenerate.** `sweep_persistent_results.jsonl` grows as cells are run. Don't truncate — the historical 2026-04-20 rows are valuable for trend analysis (and were used to compute the 3-4× pipeline-wide improvement here).

**Rejected alternatives:**

- **Run all 16 cells (8 × peephole on/off).** The 0.5-1.0% delta is consistent across two impls and three sizes spanning two orders of magnitude. Running ls 256 / ls 1000 / cf 64 with peephole off would just confirm the pattern. Per CLAUDE.md §11, scope discipline.
- **Investigate Bennett-qxg9 in this session.** Compile-time bisection across ~35 commits requires its own session. Filed and deferred.
- **Add a `peephole_on/off` field to the JSONL schema.** Would invalidate every prior row. The peephole-off measurements are documented in summary.md tables instead.
- **Full Pkg.test() before commit.** No source files changed (`git checkout HEAD -- src/lower.jl` after experimentation); only docs + JSONL. Per CLAUDE.md §8, run tests when source changes; not needed for doc-only commits.

**Filed (follow-ups):**
- `Bennett-qxg9` (P2, bug) — cf @ max_n=64 compile-time 33× regression. Bisection scope.

**Test count:** unchanged (no src/test changes).

**Next agent starts here:** the bd ready list still has `vdlg` (P2 lower.jl 2,662 LOC split, needs 3+1), `tzrs` stages 2-5 (deferred per chunk 047), `x3jc`, `ehoa` 2nd half, `s92x`, `vt0a`. Smaller no-3+1: `64ob` (softfloat MD5 / soft_fma in BENCHMARKS.md — same flavor as today's 1xub), `qjet` (test reorder, has ordering risk).
