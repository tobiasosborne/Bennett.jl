# Bennett.jl Work Log

> **NEXT AGENT — start here:** the most recent sessions live at the top of
> [`worklog/044_2026-04-26_late_night_doh6.md`](worklog/044_2026-04-26_late_night_doh6.md).
> Older session logs are sharded into ~200-300 line chunks under `worklog/`,
> file-numbered chronologically (000 = oldest, 044 = newest as of 2026-04-26).

This file is now an **index** — historical content was sharded out of the
monolithic 9,774-line `WORKLOG.md` per Bennett-fyni / U70. Concatenating the
chunk files in REVERSE filename order (`037 → 036 → … → 000`) reproduces the
original byte-for-byte; `scripts/shard_worklog.py` is the canonical re-shard
tool.

## Adding new entries

When you finish a session, **prepend** a `## Session log — YYYY-MM-DD — …`
block to the current top chunk file (today: `worklog/038_*.md`). When that
file passes ~280 lines, create a new chunk file with the next sequential
`NNN_` prefix and start prepending there. The next agent should always be
able to read the highest-numbered file first to find the latest state.

Re-running `python3 scripts/shard_worklog.py` re-flows everything if structure
drifts; it verifies byte-for-byte that the reverse-concatenation matches the
sum of all chunk files.

## Session-log template (per Bennett-fyni / U70)

Separate "what shipped" (already in git log) from durable knowledge (gotchas,
rejected paths, hand-off pointers). Avoid restating the diff:

```markdown
## Session log — YYYY-MM-DD — Bennett-<id> / U## <one-line summary>

**Shipped:** see git log around <commit-sha>; <one-line summary of intent>.

**Why:** <motivation / context not derivable from the diff>

**Gotchas / Lessons:** <surprising findings worth keeping for future sessions>

**Rejected alternatives:** <approaches tried and why they didn't work>

**Next agent starts here:** <one-line pointer to the next concrete step>
```

## Index — newest first

| File | Lines | First section |
|---|---:|---|
| [044_2026-04-26_late_night_doh6.md](worklog/044_2026-04-26_late_night_doh6.md) | 282 | Session log — 2026-04-27 (early morning) — Bennett-3of2 / U112 close (wire-leak investigated, doc-only) + Bennett-vt0a filed |
| [043_2026-04-26_late_afternoon_wlf6_6u9q.md](worklog/043_2026-04-26_late_afternoon_wlf6_6u9q.md) | 274 | Session log — 2026-04-26 (late night) — 9c4o close (lower.jl deps load before lower.jl) |
| [042_2026-04-26_midday_d1ee_f6qa.md](worklog/042_2026-04-26_midday_d1ee_f6qa.md) | 270 | Session log — 2026-04-26 (afternoon) — hjbf + 8p0g closes (Contributing section + ParsedIR seam test) |
| [041_2026-04-26_morning_069e_k7al.md](worklog/041_2026-04-26_morning_069e_k7al.md) | 270 | Session log — 2026-04-26 (late-morning) — 8kno + zy4u closes (LLVM.initializer narrowing + outer @testset) |
| [040_2026-04-25_late_night_348q_tfo8.md](worklog/040_2026-04-25_late_night_348q_tfo8.md) | 280 | Session log — 2026-04-26 (early morning) — uzic + uinn closes (citations + InterruptException narrowing) |
| [039_2026-04-25_evening_softfloat_grind.md](worklog/039_2026-04-25_evening_softfloat_grind.md) | 250 | Session log — 2026-04-25 (post-night) — 6t8s + ej4n closes (mechanical rename + callee ParsedIR cache) |
| [038_2026-04-25_uoem_persistent_ds_research_relocation.md](worklog/038_2026-04-25_uoem_persistent_ds_research_relocation.md) | 269 | Session log — 2026-04-25 (afternoon) — catalogue grind, 13 P2 beads cleared |
| [037_2026-04-25_preamble.md](worklog/037_2026-04-25_preamble.md) | 280 | Session log — 2026-04-25 — Bennett-jppi deferred, Bennett-p1h1 README Project-status refresh |
| [036_2026-04-24_…_evening_session_close.md](worklog/036_2026-04-24_next_agent_start_here_evening_session_close.md) | 315 | NEXT AGENT — start here — 2026-04-24 (evening session close) |
| [035_2026-04-24_session.md](worklog/035_2026-04-24_session.md) | 259 | Session — 2026-04-24 |
| [034_2026-04-22_…_catalogue_beads_phase.md](worklog/034_2026-04-22_next_agent_previous_context_catalogue_beads_phase.md) | 579 | (continuation of 033 — single monolithic narrative; one of the few outliers > 300 lines that resists clean splitting) |
| [033_2026-04-22_…_catalogue_beads_phase.md](worklog/033_2026-04-22_next_agent_previous_context_catalogue_beads_phase.md) | 196 | NEXT AGENT — start here — 2026-04-21 (mother-of-all code review landed) |
| [032_2026-04-21_…_t5_p6_unblocked.md](worklog/032_2026-04-21_next_agent_shipped_t5_p6_unblocked_earlier_in_day.md) | 151 | NEXT AGENT — 2026-04-21 (α+β+γ shipped; T5-P6 unblocked) — earlier in day |
| [031_2026-04-21_…_sret_callee_infrastructure.md](worklog/031_2026-04-21_session_log_sret_callee_infrastructure.md) | 303 | Session log — 2026-04-21 — α + β + γ (sret + callee infrastructure) |
| [030_2026-04-21_…_t5_p5_multi_language.md](worklog/030_2026-04-21_session_log_bennett_lmkb_bennett_f2p9_closed_t5_p5.md) | 196 | Session log — 2026-04-21 — Bennett-lmkb + Bennett-f2p9 (T5-P5a + P5b multi-language ingest) |
| [029_2026-04-21_…_cc0_4_constantexpr_icmp.md](worklog/029_2026-04-21_session_log_bennett_cc0_4_closed_constantexpr_icmp.md) | 268 | Session log — 2026-04-21 — Bennett-cc0.4 closed (ConstantExpr icmp folding) |
| [028_2026-04-20_…_cc0_7_slp_vectorised.md](worklog/028_2026-04-20_session_log_bennett_cc0_7_closed_slp_vectorised_ir.md) | 134 | Session log — 2026-04-20 — Bennett-cc0.7 closed (SLP-vectorised IR support) |
| [027_2026-04-16_…_m1_m2_m3_landed.md](worklog/027_2026-04-16_next_agent_start_here_m1_m2a_d_m3a_landed_m3b_or_m.md) | 263 | NEXT AGENT — start here — 2026-04-16 (M1 + M2a-d + M3a landed) |
| [026_2026-04-20_…_persistent_ds_scaling_sweep.md](worklog/026_2026-04-20_session_log_persistent_ds_scaling_sweep_phase_3_co.md) | 225 | Session log — 2026-04-20 — Persistent-DS scaling sweep (Phase-3 reversed at scale) |
| [025_2026-04-17_…_t5_phase_3_complete.md](worklog/025_2026-04-17_session_log_t5_phase_3_complete_p3a_interface_p3b.md) | 241 | Session log — 2026-04-17 — T5 Phase 3 complete (P3a + P3b/c/d 3 persistent-DS impls) |
| [024_2026-04-16_…_m3a_shadow_checkpoint.md](worklog/024_2026-04-16_session_log_m3a_bucket_a_b_spillover_t4_shadow_che.md) | 167 | Session log — 2026-04-16 — M3a Bucket A/B-spillover T4 shadow-checkpoint MVP (Bennett-jqyt) |
| [023_2026-04-16_…_m2d_mux_store_gating.md](worklog/023_2026-04-16_session_log_m2d_bucket_c3_mux_store_gating_bennett.md) | 223 | Session log — 2026-04-16 — M2d Bucket C3 MUX-store gating (Bennett-i2a6) |
| [022_2026-04-16_…_m2b_pointer_typed_phi.md](worklog/022_2026-04-16_session_log_m2b_bucket_c2_pointer_typed_phi_select.md) | 273 | Session log — 2026-04-16 — M2b Bucket C2 pointer-typed phi/select (Bennett-tzb7) |
| [021_2026-04-16_…_m1_parametric_mux_exch.md](worklog/021_2026-04-16_session_log_m1_bucket_a_parametric_mux_exch_green.md) | 210 | Session log — 2026-04-16 — M1 Bucket A (parametric MUX EXCH) GREEN |
| [020_2026-04-16_…_m2a_cross_block_ptr.md](worklog/020_2026-04-16_session_log_m2a_bucket_c1_cross_block_ptr_provenan.md) | 318 | Session log — 2026-04-16 — M2a Bucket C1 cross-block ptr_provenance |
| [019_2026-04-16_…_soft_fma.md](worklog/019_2026-04-16_session_log_soft_fma_ieee_754_binary64_fma_bennett.md) | 263 | Session log — 2026-04-16 — soft_fma (IEEE 754 binary64 FMA) (Bennett-0xx3) |
| [018_2026-04-16_…_soft_exp_subnormal_fix.md](worklog/018_2026-04-16_session_log_soft_exp_soft_exp2_bit_exact_subnormal.md) | 167 | Session log — 2026-04-16 — soft_exp / soft_exp2 bit-exact subnormal output via musl specialcase |
| [017_2026-04-16_…_soft_exp_base_exp.md](worklog/017_2026-04-16_session_log_soft_exp_soft_exp2_base_exp_softfloat.md) | 292 | Session log — 2026-04-16 — soft_exp / soft_exp2 + Base.exp(::SoftFloat) (Bennett-cel) |
| [016_2026-04-15_…_soft_fsqrt_base_sqrt.md](worklog/016_2026-04-15_session_log_soft_fsqrt_base_sqrt_softfloat_bennett.md) | 316 | Session log — 2026-04-15 — soft_fsqrt + Base.sqrt(::SoftFloat) (Bennett-ux2) |
| [015_2026-04-14_…_workstream_complete.md](worklog/015_2026-04-14_session_log_continuation_workstream_complete.md) | 264 | Session log — 2026-04-14 (continuation) — advanced-arithmetic workstream complete |
| [014_2026-04-13_…_bc_3_full_sha256_sret.md](worklog/014_2026-04-13_session_log_bc_3_full_sha_256_sret_support.md) | 319 | Session log — 2026-04-13 — BC.3 full SHA-256 + sret support |
| [013_2026-04-09_session_log.md](worklog/013_2026-04-09_session_log.md) | 210 | Session log — 2026-04-09 |
| [012_2026-04-09_…_v0_5_float64.md](worklog/012_2026-04-09_session_log_continued_v0_5_float64.md) | 140 | Session log — 2026-04-09 (continued): v0.5 Float64 |
| [011_…_research_overflow_false_path.md](worklog/011_9999-99-99_research_overflow_simulation_bug_false_path_proble.md) | 220 | Research: overflow simulation bug — "false path" problem (literature survey + reference, no date) |
| [010_2026-04-10_…_branchless_soft_fadd.md](worklog/010_2026-04-10_session_log_branchless_soft_fadd_option_a.md) | 317 | Session log — 2026-04-10: branchless soft_fadd (Option A) |
| [009_2026-04-11_…_documentation_narrow_bit_width.md](worklog/009_2026-04-11_session_log_continued_documentation_narrow_bit_wid.md) | 242 | Session log — 2026-04-11 (continued): Documentation + narrow bit-width |
| [008_2026-04-10_…_switch_reversible_memory_research.md](worklog/008_2026-04-10_switch_instruction_reversible_memory_research_benn.md) | 263 | 2026-04-10 — Switch instruction + reversible memory research (Bennett-282) |
| [007_2026-04-10_…_float64_division_multi_arg.md](worklog/007_2026-04-10_fix_float64_division_and_multi_arg_float64_compile.md) | 252 | 2026-04-10 — Fix Float64 division and multi-arg Float64 compile (Bennett-dqc) |
| [006_2026-04-11_…_pebbling_pipeline_eager.md](worklog/006_2026-04-11_pebbling_pipeline_gate_groups_value_level_eager_be.md) | 313 | 2026-04-11 — Pebbling pipeline: gate groups + value-level EAGER (Bennett-an5) |
| [005_2026-04-11_…_checkpoint_bennett_sha256.md](worklog/005_2026-04-11_checkpoint_bennett_66_wire_reduction_on_sha_256_be.md) | 320 | 2026-04-11 — Checkpoint Bennett: 66% wire reduction on SHA-256 (Bennett-an5) |
| [004_2026-04-12_…_irstore_iralloca_types.md](worklog/004_2026-04-12_memory_plan_t1a_1_irstore_iralloca_types_bennett_f.md) | 309 | 2026-04-12 — Memory plan T1a.1: IRStore / IRAlloca types (Bennett-fvh) |
| [003_2026-04-12_…_handoff_session_close.md](worklog/003_2026-04-12_handoff_for_next_agent_session_close.md) | 287 | HANDOFF FOR NEXT AGENT — 2026-04-12 session close |
| [002_2026-04-12_…_qrom_vs_mux_scaling.md](worklog/002_2026-04-12_t1c_3_qrom_vs_mux_scaling_benchmark_bennett_qw8k.md) | 232 | 2026-04-12 — T1c.3: QROM vs MUX scaling benchmark (Bennett-qw8k) |
| [001_2026-04-12_…_4_round_feistel.md](worklog/001_2026-04-12_t3a_1_4_round_feistel_reversible_hash_bennett_bdni.md) | 288 | 2026-04-12 — T3a.1: 4-round Feistel reversible hash (Bennett-bdni) |
| [000_2026-04-12_…_session_close_memory_plan_push.md](worklog/000_2026-04-12_session_close_second_of_day_memory_plan_push.md) | 205 | Session close — 2026-04-12 (second-of-day, memory plan push) |

## Notes on the sharded layout

- **Why the file numbering doesn't match strict date order**: the original
  WORKLOG was *mostly* reverse-chronological but sessions were sometimes
  appended at the bottom rather than prepended at the top, so e.g. some
  2026-04-12 content sits below 2026-04-09 content in the source. The
  chunker preserves source order — the `NNN_` prefix reflects the source
  file's structure, not strict date order. The dates in filenames give the
  approximate timeframe.

- **Single outlier at 579 lines** (`worklog/034_…`): a coherent narrative
  with no internal `### ` subsections to split on. Accepted as-is rather
  than fragmenting.

- **A few chunks under 200 lines** (134-196 each): natural session-log units
  too small to merit their own chunk under strict 200-300 sizing, but
  combining them with adjacent dates would mix unrelated topics. Left as-is.

- **Reference content** (Project purpose / Repository layout / Version
  history / Key design decisions / Sturm.jl integration path) is preserved
  inside `worklog/013_2026-04-09_session_log.md` and adjacent chunks where
  it originally lived. Future cleanup may extract this to `docs/`; for now
  the byte-for-byte preservation is the priority.
