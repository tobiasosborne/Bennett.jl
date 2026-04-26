# Bennett.jl Work Log

## Session log — 2026-04-27 — DAY SUMMARY for 2026-04-26/27 grind + STRICT NEXT-AGENT DIRECTIVE (BUGS ONLY)

### 🚨 NEXT AGENT — READ THIS FIRST 🚨

**You are to work on BUGS ONLY. No exceptions.**

The catalogue has 24 open `[bug]` beads. That is the ONLY work allowed in your session. Specifically:

- **DO NOT** pick refactors, renames, file reorganisations, docstring polish, dead-store cleanups, error-monoculture rewrites, naming-convention fixes, or any cosmetic / structural improvement.
- **DO NOT** file new "follow-up" beads as a substitute for fixing a real bug. If you spot a follow-up worth filing, file it AFTER you've shipped a real bug fix (one bug close minimum per session).
- **DO NOT** procrastinate on hard bugs by picking easier non-bug items. The hard bugs (jepw, 25dm, p94b, fq8n, lgzx, ibz5) have been deferred enough.
- **DO NOT** use "not enough runway" as an excuse. The 3+1 protocol is fast (~2 min per proposer in parallel). Multi-session work is fine — start it, ship a coherent slice, write up the handoff.
- **DO NOT** say "this needs more investigation" without ALSO doing the investigation IN this session. Investigation IS work — close the bead as `investigated, doc-only` if the conclusion is "out of scope, foundational follow-up filed" (see Bennett-3of2 / vt0a today for the template).
- **DO NOT** complain about scope, complexity, the 3+1 trip-wire, or "this would be cleaner as a refactor." Fix the bug.

**The bug list (P2 → P3, in suggested pickup order):**

| Bead | P | Sites | Why now |
|---|---|---|---|
| **jepw** | P2 | `lower.jl` loop unroller | Diamond-in-body phi resolution; needs 3+1; **biggest open bug**; deferred since chunk 043 |
| **25dm** | P2 | `test/test_t5_corpus_*.jl` | T5 multi-lang corpus is `@test_throws` — promised but not delivered; gated on z2dj IN-PROGRESS — drive z2dj forward, don't sit on it |
| **59jj** | P2 | `lower.jl` hot paths | Boxed returns, `Vector{Any}` — type instability — measured perf hit |
| **ponm** | P2 | bd infra | `wisp_dependencies` table missing; affects bd dep tracking; this IS infrastructure but it's tagged `[bug]` — fix |
| **p94b** | P3 | `lower.jl:876-893` | `_compute_block_pred!` OR-folds without mutex assert; CLAUDE.md phi-resolution false-path-sensitisation risk |
| **fq8n** | P3 | `lower.jl` | phi with 0 incoming / mixed widths not validated |
| **lgzx** | P3 | `lower.jl` | `_convert_instruction` result-type filter silently drops stores |
| **ibz5** | P3 | `lower.jl` | OPAQUE_PTR_SENTINEL compiled as zero; ptr icmp loses provenance |
| **t3j0** | P3 | `lower.jl` | `_expand_switches` synthetic labels collide on re-run |
| **2yky** | P3 | `lower.jl` | IRCall arg_widths invariant unchecked |
| **y986** | P3 | `lower.jl` | loop_unroller header-body drops non-arith IR types |
| **salb** | P3 | `lower.jl` | typemin ÷ -1 silently wraps; x ÷ 0 returns garbage |
| **y56a** | P3 | `lower.jl`, `divider.jl` | triple-redundant integer division paths |
| **yys3** | P3 | `softfloat/` | 200+ LOC manual 128-bit arithmetic to avoid `__udivti3` |
| **gboa** | P3 | `lower.jl` | Zero-ancilla in-place ops dirty-bit hygiene undocumented |
| **tpg0** | P3 | `softfloat/` | `_sf_normalize_to_bit52` pathological on m=0 |
| **ys0d** | P3 | `softfloat/fexp.jl` | soft_exp off-by-1-ULP ~0.9% vs Base.exp; soft_exp_julia is bit-exact — fix soft_exp or document deprecation |
| **xiqt** | P3 | `softfloat/` | `_sf_handle_subnormal` flush-to-zero boundary may drop round-up case |
| **d77b** | P3 | `softfloat/fcmp.jl` | Only 4 of 14 LLVM fcmp predicates implemented |

24 [bug] beads total open. (Some additional bugs not enumerated above; run `bd ready -n 200 \| grep '\[bug\]'` to see the full list.)

**Workflow per bug** (fixed by today's grind through 6 closes):

1. `bd update <id> --claim`
2. `bd show <id>` — read claim + sites
3. **MEASURE the actual current behaviour BEFORE designing a fix.** The bead's headline numbers may be stale (today's 5qrn was claimed as "x+0 → 98 gates" — actual was 86; 3of2's "279k wire bloat from this leak" — actual contribution <0.1%).
4. If it touches `lower.jl` / `ir_extract.jl` / `bennett_transform.jl` / `gates.jl` / `ir_types.jl` / phi resolution: **3+1 protocol.** Two `Plan` agents in parallel with full prompt context (CLAUDE.md, the relevant code, the bead, the catalogue entry, the source-report finding). Synthesize. Implement.
5. If it's a defensive cleanup (assertions, mask refactor, doc): **direct grind** — no proposers needed. Be honest about which mode you're in.
6. **`verify_reversibility` is NOT a semantic check.** Pair every test with an output assertion against a Julia-native oracle. Today's 3of2 attempt passed `verify_reversibility` while producing sign-flipped sdiv results — that test pattern would have caught it on the first sweep.
7. Test, commit, close, worklog entry, push. Worklog entry should follow today's pattern: shipped / why / gotchas-and-lessons / rejected-alternatives / next-agent-starts-here.

**If you have time after one bug close**: pick another bug. Repeat. Do not pick non-bug items.

---

### Day summary — 2026-04-26 + early 2026-04-27

**Closes (chronological)**:

| Bead | P | Type | What |
|---|---|---|---|
| ardf | P3 | BUG | fdiv overflow_result discard + bit-exact NaN tests |
| 9c4o | P3 | task | Include reorder so lower.jl deps load first |
| kcxv | P3 | task | Already-fixed-by cs2f; 30s triage close |
| op6a | P3 | BUG | Cuccaro docstring gate counts corrected |
| b2fs | P3 | task | tabulate `Any[]` → `Tuple` (16M-row hot path) |
| g0jb | P3 | BUG | asw2 flake fix (n_tests 4 → 20) |
| 5kio | P3 | task | sizehint! across arithmetic kernels |
| **doh6** + **5ec** | P3 | task | docs/make.jl + Documenter wiring (vision-blocking) |
| **5qrn** | **P2** | **BUG** | Trivial-identity peepholes — x*1 692 → 26 gates (26.6×) |
| **qcso** | **P2** | **FEATURE** | compose(c1, c2) — Sturm vision unblocker |
| **zmw3** | P3 | BUG | Shift bounds + resolve! mask robustness (17-session-procrastinated) |
| **3of2** | P3 | BUG | Investigated → doc-only; vt0a filed for foundational fix |

**Filings** (drive-by follow-ups): 7xng (constant_wires dead store), 1xub (BENCHMARKS refresh post-5qrn), vt0a (Bennett-aware free!).

**Pkg.test growth**: 73,068 → 80,985 (+7,917 assertions). 12 new test files.

**Headline learnings**:

1. **`verify_reversibility` ≠ semantic correctness.** It checks ancilla-zero + input-preservation. Output correctness must be asserted separately against a Julia-native oracle. The 3of2 fix attempt would have shipped silently wrong without this discipline.

2. **3+1 protocol is the right tool for compiler-internals.** Used twice today (5qrn, qcso) — both saw strong proposer convergence and surfaced subtle issues my prompt context had missed (5qrn's stale baseline numbers, qcso's wire-budget compaction). Cost: ~2 min per proposer in parallel. Synthesis: ~5 min. Worth it for any change to `lower.jl` / `ir_extract.jl` / `bennett_transform.jl` / `gates.jl` / `ir_types.jl`.

3. **Direct grind is fine for defensive cleanups.** 3+1 was skipped for zmw3 (assertions + mask refactor — non-algorithmic). Decision recorded so future sessions can use the same calibration: "Algorithmic change → 3+1; defensive change → direct."

4. **Bead-claim numbers go stale.** Always live-measure before designing the fix. 5qrn's "x+0 → 98 gates" claim was actually 86; 3of2's "279k wire bloat from this leak" was actually <0.1% contribution.

5. **`free!()` is incompatible with Bennett's outer reverse pass at the lower_*.jl layer.** Existing `free!` users (feistel, qrom, pebbled_groups) work because they're inside self-contained sub-circuits. At the lower_divrem! / lower_call! interface, reuse crosses Bennett-construction boundaries. See Bennett-vt0a for the foundational fix.

6. **"investigated, doc-only" close is a legitimate disposition.** Updates the source docstring with the analysis + files a foundational follow-up bead. Better than silently leaving the issue OR shipping a broken "fix" that passes verify_reversibility but is semantically wrong.

**Catalogue health snapshot at session-end** (2026-04-27 ~early morning):

- Total beads: 444 / closed 305 / open 125 / blocked 0
- P2: 16 open (4 BUGs)
- P3: 90 open (~18 BUGs)
- P4: 19 open (mostly non-bug)
- 24 [bug] beads total open
- 0 P0/P1 (critical) bugs — project is HEALTHY
- 15% of open backlog is "serious"; 85% is "cosmetic" / refactor / polish

**Vision integration status**: `controlled` ✓, `compose` ✓ (today), `Float64` / soft-float ✓, jldoctest infra ✓ (today). **Remaining for Sturm `when(qubit) do f(x) end`**: 25dm (multi-language ingest — promised but not delivered).

---

### Branch state at session-end

`8c127ae` on main, pushed and verified `up to date with 'origin/main'`. Worklog: chunk 044 hit 282 lines (over the 280 cap); **this entry starts chunk 045**.

### Bd-tracked beads (snapshot)

```
bd stats:
  Total Issues:   444
  Open:           125
  In Progress:    1     (z2dj)
  Closed:         305
  Ready to Work:  125
```
