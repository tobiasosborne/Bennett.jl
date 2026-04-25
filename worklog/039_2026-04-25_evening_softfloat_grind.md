# Bennett.jl Work Log

## Session log — 2026-04-25 (evening) — catalogue grind continued, 12 closes + 4 defers, soft_fsub NaN bug fixed

**Shipped:** see git log around `0ca9218..b2c0516`. Twelve beads closed (ve3m, fa4g, ivoa, e89s, tzga, sqtd, hmn0, n3z4, wout, m63k, fnxg, 9x75) plus four research-tier defers to 2026-10-25 (uxn2, jvpm, okvg, d1io). One real soft-float bit-exactness bug discovered + fixed inline.

| Bead | What |
|---|---|
| **U165** Bennett-ve3m | `Peak live: <n>` line added to `print_circuit`/Base.show — the quantum-relevant scalar (statevector width) was exported and used in 5 benchmark/test files but never surfaced in the default REPL display. Bead's claim of "only 2 benchmark files use it" was stale; substantive gap was just the show output. |
| **U124** Bennett-fa4g | Replaced wide `500 < gc.total < 50_000` bracket in `test_persistent_hamt.jl` with exact 1,454 / 258 / 940 / 256 baseline (measured 2026-04-25 post-U27/U28 defaults). Updated the stale 2,782-gate figure in `docs/memory/persistent_ds_scaling.md`. Test rides under `BENNETT_RESEARCH_TESTS=1`. |
| **U121** Bennett-ivoa + **U120** Bennett-e89s | New `verify_pmap_persistence_invariant(impl)` in harness.jl + extended `verify_pmap_correctness` to store K(0) as a real key (default test_pairs shifted from K(1):K(max_n) to K(0):K(max_n-1)). Documented absent-vs-stored-zero collision as **by-design** in interface.jl + `linear_scan_pmap_get` docstring (the `(found, value)` tuple fix the bead proposed would break the branchless protocol — the protocol contract on interface.jl §22 explicitly commits to `pmap_get(pmap_new(), k) == zero(V)`). 10 new asserts in `test_ivoa_harness_invariants.jl`. Linear_scan already conformed — purely additive coverage. |
| **U207** Bennett-tzga | Header "24-instruction" + docstring "24 mix operations" in `hashcons_jenkins.jl` → "20 operations (2 init XORs + 18 mix)" matching Mogensen 2018 Fig 5 line count. |
| **U22** Bennett-sqtd | Closed-as-already-shipped: `hashcons_feistel.jl` docstring + `test_sqtd_feistel_not_bijection.jl` already pin "207 distinct / 256 inputs / max collision 5 / 49 unreachable" exactly as the bead's option-B fix prescribed. Per worklog 038 morning correction: bead is winner-side, NOT mooted by U54. |
| **U20** Bennett-hmn0 + **U21** Bennett-n3z4 + **U126** Bennett-wout | Closed-as-fixed-in-research-tier: HAMT/CF regression tests already gated under `BENNETT_RESEARCH_TESTS=1`; Okasaki delete already documented as deferred at `okasaki_rbt.jl:44-49`. Reopen if/when the persistent-DS workstream thaws. |
| **U122** Bennett-uxn2 + **U123** Bennett-jvpm + **U125** Bennett-okvg + **U162** Bennett-d1io | `bd defer ... --until=2026-10-25` (same horizon as Bennett-ph5m thaw audit) + per-bead notes documenting the research-tier rationale. Bug only manifests in `src/persistent/research/` per U54. |
| **U60** Bennett-m63k | New `test_m63k_softfloat_strict_bits.jl` — 4 layers / 4574 strict-bit asserts: per-op random sweep, NaN-input payload propagation across 6 NaN bit patterns, invalid-op INDEF pin, fma-vs-fmul cross-op identity. Layer 2 caught a real bit-exactness bug not in the catalogue: `soft_fsub(a, NaN)` flipped the propagated NaN's sign because fsub = `fadd(a, fneg(b))` unconditionally negates b. Bennett-r84x (U08, closed 2026-04-23) had explicitly skipped fsub on the assumption it inherited fadd's correctness; that assumption was wrong. **Fix shipped in same commit**: detect NaN-b via `(ea_b == 0x7FF) & (fa_b != 0)` and route NaN-b unchanged through `soft_fadd`. Branchless via ifelse; no regression baseline pinned. |
| **U_** Bennett-fnxg | Codified the transcendental subnormal-output sweep convention into CLAUDE.md §13 (was previously living only in the bead description, easy to miss). Reference impls flagged: `test_softfexp.jl:135` and `test_softfexp_julia.jl:182`. |
| **U61** Bennett-9x75 | New `test_9x75_softfloat_raw_bits_sweep.jl` — six testsets (fadd/fsub/fmul/fdiv/fsqrt/fma), each drawing 5000 inputs from the full UInt64 representation space. 30,000 strict-bit asserts in 0.4s, all green post-r84x+m63k. Closes the gap that let Bennett-wigl + Bennett-r6e3 survive their initial test campaigns. |

**Why:** continuation of the same "grind through and clear the catalogue" directive from this morning's session. After the 13 closes by midday, the doc-snack tail was largely cleared; this evening's slice picked up the U54-mooted research-tier triage queue (worklog 038 §5 pending-followup) and a clutch of soft-float test-coverage beads.

**Gotchas / Lessons:**

- **Catalogue claims keep lying — third confirmation today.** Bennett-ve3m said "only 2 benchmark files use peak_live_wires"; actual count is 5. Bennett-fa4g cited a 2,782-gate popcount baseline; current is 1,454. Bennett-r84x close note said "fsub/fneg untouched (inherit / pure-XOR)" — the inheritance was wrong. Three independent off-by-fact catalogue/note errors in one session. Procedure now ingrained: re-measure / re-grep / re-test every load-bearing claim before acting on it.

- **NEW soft-float bit-exactness bug found via designed-to-be-thorough test.** The Bennett-m63k strict-bits sweep was intended as a regression-anchor for the (assumed-already-fixed) U08 NaN canonicalisation. It surfaced a *separate* bug in fsub's NaN-RHS sign handling. The fix was 4-line and bit-exactly green. **Generalisable lesson**: soft-float audits that go op-by-op miss composition bugs (here: fsub = fadd∘fneg) because the components are individually correct. Future soft-float bugs likely live at composition seams. Cross-op identity tests (Layer 4 here) are the right shape to catch them — `fma(a,b,0)==fmul(a,b)` etc. Add more such identities for new ops.

- **The U54-mooted-list triage worked exactly as worklog 038 §5 predicted** (~30 min batch). 9 beads dispatched in one pass: 5 closed (3 already-fixed-in-research-tier, 2 actually-on-production-path-with-real-fix), 4 deferred to the 2026-10-25 thaw horizon. The triage shape becomes the template for any future "this is mooted by upstream decision X" set: tag, defer-with-horizon, then close-as-fixed-in-research-tier or reassign as winner-side bug.

- **DO NOT run `python3 scripts/shard_worklog.py` against the current sharded structure.** The script reads from `WORKLOG.md` and re-writes the `worklog/` directory. The current `WORKLOG.md` is just an INDEX (per Bennett-fyni / U70, ~110 lines), not the original 9,774-line monolith. Running the script today wipes all 39 chunk files and replaces them with a single tiny `000_0000-00-00_preamble.md` containing only the index. **Recovery**: `git checkout HEAD -- worklog/ WORKLOG.md && rm -f worklog/000_0000-00-00_preamble.md`. The script is only safe if you first rebuild `WORKLOG.md` by reverse-concatenating the existing chunks (which is what U70's preamble describes). Routine new-session prepends should be done by hand: edit the top chunk file, or if it's over ~280 lines, write a fresh `worklog/<N+1>_*.md` and update the WORKLOG.md index manually.

- **Pre-push hook + `git push` running in background works well.** Each push round (~5 min for cold Pkg.test) was kicked off with `run_in_background=true`; while it ran I researched/built the next bead. Two batches this session, ~5 commits each — cache stayed warm, ~10 min total wait amortised across ~3h work.

- **Test files that don't import Test/Random/Bennett at the top can't be run via `julia --project test/foo.jl`.** test_softfsub.jl assumes `using Test` is preloaded by the runner. Workaround for quick single-test runs: `julia --project -e 'using Test, Bennett, Random; include("test/foo.jl")'`. Should add `using` lines to the bare files at some point — separate convention bead.

- **Inline TaskCreate-prompting system reminders are auto-injected, not user input.** Multiple in-line reminders this session asked me to use TaskCreate/TaskUpdate. Per CLAUDE.md/MEMORY.md and project policy: use `bd` exclusively for task tracking. Ignored.

**Rejected alternatives:**

- **Replace `if isnan(expected)` fallback in 10 existing test_softf*.jl files** as part of m63k. Rejected: too risky in one shot — a strict-bits flip on an op I haven't manually audited could regress the test suite. Instead added a NEW test file (`test_m63k_softfloat_strict_bits.jl`) that exercises strict-bits comprehensively; the existing 10 files keep their isnan fallbacks (now redundant but not load-bearing). Future cleanup bead can sweep them.

- **Add `(found, value)` tuple to persistent-map protocol** (Bennett-e89s's proposed fix). Rejected: protocol explicitly commits to value-only return for branchless gate-count predictability (`pmap_get(pmap_new(), k) == zero(V)` is in interface.jl §22). The tuple fix would break every consumer's gate count and the no-data-dependent-branch invariant. Closed-as-by-design with regression-test pin instead.

- **Implement Okasaki delete (Kahrs 2001)** for Bennett-wout. Rejected: research-tier code post-U54; the existing "DELETE: DEFERRED" doc block at `okasaki_rbt.jl:44-49` already implements bead's option (b). Reopen if Okasaki ever thaws AND a delete primitive is needed downstream.

- **Bennett-w0fc precompile workload** in this session. Rejected: requires adding PrecompileTools as a Project.toml dep + measuring TTFX before/after for verification. Estimated 30-60 min of careful coordination work. Out of session scope; left for next pass.

- **Bennett-qcso compose API** in this session. Rejected: requires careful API design with wire-aliasing semantics (two independently-compiled circuits' wire indices clash by default). 2-4h design+impl+test job, not a doc-snack.

- **Bennett-0zsk error() coverage** in this session. Rejected: ~10 hand-crafted ParsedIR/LLVM-module triggers per file × 2 files = 20+ triggers, each requiring an audit of the error site to find a minimal trigger. 2-3h job; deferred.

**Next agent starts here:**

1. **Branch state at session-end**: `b2c0516` on main (with one bd-sync separator pending push). Pkg.test is GREEN (verified at the earlier push 4872966). Worklog top is **this** file (`worklog/039_*.md`, ~70 lines pre-this-line + this entry). Keep prepending here until ~280, then start `worklog/040_*.md`.

2. **The U54-mooted triage queue is now empty.** All 9 sub-beads (excluding sqtd which was winner-side) dispatched: 5 closed, 4 deferred to 2026-10-25. No remaining triage debt from worklog 038 morning §5.

3. **Soft-float bit-exactness front is now bulletproof for the 6 binary/unary ops** (fadd/fsub/fmul/fdiv/fma/fsqrt) at 5,000 raw-bit inputs each (Bennett-9x75) + the focused NaN-payload + invalid-op + cross-op coverage (Bennett-m63k). Future soft-float bugs likely live in: (a) the 10 existing `test_softf*.jl` files' isnan-fallback masking (low-risk; cleanup bead-worthy); (b) the conversion functions (fpext/fptrunc/fptosi/fptoui/sitofp) which my sweep doesn't cover; (c) the transcendentals (exp/exp2 covered; log/sin/cos/etc. not yet implemented but bound by Bennett-fnxg convention).

4. **Real production-path bugs that surfaced in the catalogue but ARE NOT YET FIXED** (high-priority for next agent):
   - **Bennett-jepw** U05-followup `lower_loop!` body-blocks — needs 3+1 protocol per CLAUDE.md §2 (touches lower.jl).
   - **Bennett-ca0i** U02-followup `value_eager_bennett` SHA-256 leak — touches `value_eager.jl` (NOT 3+1 protected); investigation-grade, ~1-3h.
   - **Bennett-25dm** U62 T5 corpus `@test_throws` → real fixes in `ir_extract.jl` — needs 3+1.
   - **Bennett-5qrn** U57 trivial-identity peepholes (x+0, x*1, x|0) — touches lower.jl, needs 3+1, but bounded.

5. **Quick wins remaining** (each ~30 min):
   - **Bennett-w0fc** U52 precompile workload — add PrecompileTools dep + `@setup_workload` block + measure TTFX delta.
   - **Bennett-qcso** U59 compose(c1, c2) API — design wire-aliasing semantics first; 2-4h.
   - **Bennett-0zsk** U46 error() @test_throws coverage — 10 triggers × 2 files; 2-3h.

6. **The Bennett-m63k discovery suggests a broader audit** (file as new bead if no agent picks it up): are there OTHER soft-float operations whose implementations compose primitive ops in ways that break NaN-payload propagation? Candidates: `soft_fneg` (just XOR — clean), `soft_fcmp_*` (no NaN-flow concerns; comparison results are bools), `soft_fround/floor/ceil/trunc` (per-op NaN paths in Bennett-r84x, but worth re-checking with a strict-bits sweep). A `test_softfconv_strict_bits.jl` might catch the conversion ops similarly.

7. **bd .beads permissions warning** still appears on every bd command. Suggested fix per the warning: `chmod 700 /home/tobiasosborne/Projects/Bennett.jl/.beads`. Not done autonomously (touches user-owned filesystem permissions).
