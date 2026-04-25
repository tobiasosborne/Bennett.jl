# `docs/design/` — INDEX

Consensus design docs for the project's 3+1-agent core changes (CLAUDE.md
§2). Each `*_consensus.md` file is the orchestrator's synthesis of two
independent proposer designs — the proposer files themselves now live
under `archive/` to keep this directory scannable. The frozen proposer
docs are preserved (do not mutate); they record what was on the table at
decision time.

> **Stale-numbers warning.** Consensus docs and especially proposer docs
> often contain gate counts measured *during the design exploration*.
> Those numbers may diverge from current `BENCHMARKS.md` baselines as
> the codebase evolves (e.g. Cuccaro self-reversing, fold-constants
> defaults, T5 dispatcher work). Always cross-check claimed numbers
> against `BENCHMARKS.md` and `test/test_gate_count_regression.jl`
> before quoting them.

## Consensus docs

| Topic | Bead(s) | One-line scope |
|---|---|---|
| `alpha_consensus.md` | Bennett-atf4 | `lower_call!` derives arg types from `methods()` (T5-P5/P6 prerequisite α) |
| `beta_consensus.md` | Bennett-0c8o | vector-lane sret via deferred resolution + vector-load handler (T5-P5/P6 prerequisite β) |
| `gamma_consensus.md` | Bennett-uyf9 | auto-SROA when sret is detected (T5-P5/P6 prerequisite γ) |
| `cc03_05_consensus.md` | Bennett-cc0.3 + Bennett-cc0.5 | LLVMGlobalAliasValueKind + thread_ptr GEP (Julia TLS allocator) — `ir_extract` gaps |
| `cc04_consensus.md` | Bennett-cc0.4 | ConstantExpr `icmp` folding (constant pointer comparisons) |
| `cc07_consensus.md` | Bennett-cc0.7 | Vector SSA scalarisation in `ir_extract.jl` (InsertElement / ExtractElement / ShuffleVector) |
| `m2b_consensus.md` | Bennett-tzb7 (cc0 / M2b) | Pointer-typed phi/select (memory-plan Bucket C2) |
| `m2d_consensus.md` | Bennett-i2a6 (cc0 / M2d) | Conditional MUX-store guarding (memory-plan Bucket C3) |
| `m3a_consensus.md` | cc0 / M3a | T4 shadow-checkpoint MVP (rescoped from original PRD §10 M3) |
| `p5_consensus.md` | T5-P5a + T5-P5b | Multi-language ingest (`.ll` text + `.bc` bitcode) |
| `p6_consensus.md` | Bennett-z2dj | `_pick_alloca_strategy :persistent_tree` arm (T5-P6, in_progress) |
| `parallel_adder_tree_consensus.md` | Bennett-a439 | A1 — binary tree of QCLA adders (advanced-arithmetic) |
| `qcla_consensus.md` | Bennett-cnyx | Q1 — Draper-Kutin-Rains-Svore quantum carry-lookahead adder |
| `soft_fma_consensus.md` | Bennett-0xx3 | IEEE 754 binary64 fused-multiply-add (soft-float) |

## `archive/` — proposer + research scaffolding

Frozen 3+1 inputs: per-design proposer A/B docs and the two p6 research
notes (local + online survey). Preserved verbatim as a snapshot of the
design space at decision time. **Do not mutate**; if a design needs
revisiting, write a fresh proposer pair against current code state and
land a new consensus.
