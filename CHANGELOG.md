# Changelog

All notable changes to Bennett.jl. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project follows semantic versioning loosely (pre-1.0).

## [0.5.0] — 2026-04-25

First version cut against the modern PRD chain (`docs/prd/Bennett-PRD.md` through `docs/prd/BennettIR-v05-PRD.md`). v0.1–v0.4 were internal milestones tracked in the PRDs and worklog; this is the first release-shaped tag.

### Added
- **Float64 support via soft-float** (v0.5 PRD). `src/softfloat/` implements IEEE 754 binary64 in pure integer arithmetic — `soft_fadd`, `soft_fsub`, `soft_fmul`, `soft_fdiv`, `soft_fma`, `soft_fsqrt`, `soft_fneg`, `soft_fcmp_*`, plus conversions (`soft_fpext`, `soft_fptrunc`, `soft_fptosi`, `soft_fptoui`, `soft_sitofp`) and rounding (`soft_floor`, `soft_ceil`, `soft_trunc`, `soft_round`). Bit-exact against Julia native at every measured input.
- **Transcendentals** — `soft_exp`, `soft_exp2` (musl-derived; bit-exact including subnormal-output range).
- **Reversible memory primitives** — `softmem.jl` (MUX-store/load on packed UInt64 arrays), `shadow_memory.jl` (universal CNOT-copy pattern), `qrom.jl` (Babbush-Gidney 2018 binary decision tree).
- **Multiplication strategies** — Sun-Borissov 2026 polylog-depth multiplier (`mul_qcla_tree.jl`), parallel adder tree (`parallel_adder_tree.jl`), Karatsuba (`multiplier.jl`; vestigial in current widths — see Bennett-tbm6).
- **QCLA addition** — Draper-Kutin-Rains-Svore 2004 quantum carry-lookahead adder (`qcla.jl`).
- **Bennett strategy variants** — `pebbling.jl` (Knill 1995), `pebbled_groups.jl`, `eager.jl` / `value_eager.jl` (PRS15), `sat_pebbling.jl` (Meuli 2019 via PicoSAT).
- **Persistent map protocol** (T5 workstream) — `src/persistent/` with `linear_scan` as the production winner and `Okasaki RBT`, `HAMT`, `Conchon-Filliâtre`, `Mogensen Jenkins-96`, `Feistel hash-cons` relocated to `persistent/research/` (opt-in via `BENNETT_RESEARCH_TESTS=1`).
- **Multi-language ingest** — `extract_parsed_ir_from_ll`, `extract_parsed_ir_from_bc` for raw LLVM `.ll`/`.bc` (currently exercised by Julia/C/Rust corpora under `test/test_t5_corpus_*.jl`).
- **Diagnostics** — `gate_count`, `ancilla_count`, `depth`, `t_count`, `t_depth`, `toffoli_depth`, `peak_live_wires` (now in `print_circuit` summary), `verify_reversibility`, `print_circuit`.

### Changed
- Default add strategy flipped `:auto` → `:ripple` (Bennett-spa8 / U27); default `fold_constants=true` (U28). Locked baselines: i8 `x+1` = 58 gates / 12 Toffoli; doubling rule `total(2W) = 2·total(W) - 2`, `T(2W) = 2·T(W) + 4`.
- `julia` floor `1.6` → `1.10`. LLVM compat relaxed from exact `9.4.6` pin to `"9, 10"`. PicoSAT compat broadened from `0.4.1` → `"0.4"`.
- `WORKLOG.md` reorganised from a 9,774-line monolith into ~40 sharded chunks under `worklog/` (Bennett-fyni / U70). Root file is now an index.

### Fixed
- **Soft-float NaN canonicalisation** (Bennett-r84x / U08) — invalid-op producers (`Inf−Inf`, `Inf*0`, `0/0`, `Inf/Inf`, `sqrt(-x)`) now emit x86 INDEF `0xFFF8000000000000`; NaN-input passthrough preserves sign + payload per IEEE 754-2019 §6.2.3; `soft_fptosi` saturates to `0x8000000000000000` matching `cvttsd2si`.
- **`soft_fsub` NaN-RHS sign-flip** (Bennett-m63k / U60) — `soft_fsub(a, NaN)` no longer flips the propagated NaN's sign; the previous `soft_fadd(a, soft_fneg(b))` composition was unconditional even when `b` was a NaN. Detected by 4574 strict-bit assertions in `test_m63k_softfloat_strict_bits.jl`.
- **`soft_fdiv` subnormal handling** (Bennett-r6e3) — pre-normalises subnormal mantissae before the 56-bit restoring-division loop.
- **`soft_exp` underflow** (Bennett-wigl) — bit-exact subnormal output across `x ∈ (-1075, -1022)` via musl specialcase.
- **`soft_fmul` subnormal** (Bennett-xy4j / U06) — pre-normalises subnormals; eliminates 11–20% ULP drift.
- **Phi-MUX gating** in diamond CFGs (Bennett-asw2 / U01) — input-preservation invariant restored after the `false-path sensitization` regression.

### Removed
- Legacy regex-based `src/ir_parser.jl` (Bennett-cs2f / U42). All call sites ported to `extract_parsed_ir`.
- `_reset_names!()` no-op stub (Bennett-cs2f / U42 + cleanup commit on 2026-04-25). Per-compilation counters are local now; the global stub had been dead since the v0.3 era.

### Infrastructure
- Local pre-push hook (`scripts/pre-push`) is the intended quality gate per CLAUDE.md §14 (no GitHub CI per project rule). Hook is installable via `scripts/install-hooks.sh`; not installed by default.
- Beads (bd) issue tracker checked in under `.beads/` with embedded Dolt remote.
- `Manifest.toml` not tracked (library convention).

---

## Internal milestones (no published tags)

These versions shipped to the local main branch but were never registered. PRDs preserved under `docs/prd/`.

### v0.4 — Wider Integers, Explicit Loops, Arrays
Int16/Int32/Int64 lowering, explicit loop unrolling via LLVM IR walks, sret-aware aggregate returns, switch instruction, reversible memory T1–T4 plan kickoff.

### v0.3 — Controlled Circuits + Control Flow
`controlled.jl` lifts circuits with an explicit control bit. Branches and LLVM-unrolled loops. Diamond-CFG correctness work.

### v0.2 — LLVM-Level Reversible Compilation POC
Replaced v0.1's `Traced` operator-overloading approach with a real LLVM.jl C-API walker. Straight-line arithmetic, bitwise, compare+select, multi-argument functions on Int8.

### v0.1 — Reversible Compilation POC
Original demonstration that pure Julia functions compile to reversible circuits via Bennett's 1973 construction. Operator overloading on a `Traced` type. `f(x) = x² + 3x + 1` end-to-end.
