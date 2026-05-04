## Session close — 2026-05-04 — handoff after qpke ship

**Shipped today (commit `53a07e0` on origin/main):** Bennett-qpke (Tier
C1.2 `soft_atan`) — see entry below. Pkg.test confirmed 489,007 pass +
0 fail + 1 environmental error + 3 environmental broken.

**Toolchain installed at session close (resolves all 3 broken):**
`sudo apt install -y clang rustc llvm` — provides `/usr/bin/clang`,
`/usr/bin/rustc`, `/usr/bin/llvm-as`. The 3 broken were
`Bennett-T5-P5b extract_parsed_ir_from_bc` (needed `llvm-as`),
`T5 corpus — C via clang (T5-P2b)` (needed `clang`),
`T5 corpus — Rust via rustc (T5-P2c)` (needed `rustc`). All three pass
in isolation post-install (262 + 6 + 6 = +274 tests now active). The
1 error is `test_hygiene_aqua_jet.jl` `using Aqua` failing — only
loadable via `Pkg.test()`'s `[targets].test` sandbox; future agents
running `julia --project test/runtests.jl` directly will hit it
harmlessly. Use `Pkg.test()` for the canonical-green path.

**Beads filed today:**
- `Bennett-qpke` (P3 task) — CLOSED. soft_atan + llvm.atan dispatch.
- `Bennett-7kzr` (P2 task) — OPEN. Full-scale docs refresh post-Enzyme-
  parity pivot. Drift inventory in description: README opcode table at
  "38 core opcodes" (now ~45+); Project status section frozen at
  "2026-04 mid"; CLAUDE.md file-structure block predates vdlg/x3jc/zpj7
  splits to `src/lowering/`, `src/extract/`, `src/pebble/`; BENCHMARKS
  has no transcendental section; WORKLOG.md root index stops at chunk
  046 (chunks 047-057 missing); VISION-PRD doesn't link to the
  Enzyme-parity-north-star doc. Likely 1-session sub-bead splits if
  scope balloons.
- `Bennett-ao66` (P3 task) — OPEN. Generic vector-form intrinsic
  re-scalarisation in `_convert_vector_instruction`. Surfaced by qpke
  gotcha #1 (4× parallel `soft_fdiv` SLP-vectorising into
  `<4 x i64>` + `llvm.smax.v4i64`). Parent: `Bennett-vb2`. **3+1
  protocol required** — touches `src/extract/vectors.jl`, non-trivial
  design space. Big leverage: one expansion covers smax/smin/umax/
  umin/abs/ctpop/sqrt/sin/cos/exp/log/pow/fma/etc. vector forms.

**Pkg.test wall-clock observation (for the docs-refresh bead):** the
historical 4-5 min figure quoted in CLAUDE.md / README is **stale**.
Current full Pkg.test runtime is ~30-45 min depending on contention,
driven by the LLVM dispatch tests (1pb / 582 / emv / 3mo / s1zl /
qpke) which silently compile multi-million-gate transcendental
circuits. Each compile takes minutes; combined budget ~15-20 min just
for those six. Update README / CLAUDE.md figures via Bennett-7kzr.

**Mistakes captured for the next agent:**
1. **`tail -N` pipes buffer the entire input until EOF.** When running
   long-running julia jobs in background bash, do NOT use
   `... 2>&1 | tail -N` — output will not appear until the process
   exits. Use direct redirect: `... > /tmp/log 2>&1`.
2. **Julia ignores `stdbuf -oL`** because Julia's IO uses libuv, not
   libc stdio. The `stdbuf` no-op is silent — output looks blocked
   but it's just buffered. Use `script -q -f -c "julia ..." log` for
   a PTY (Julia treats PTY as TTY → line-flushes naturally).
3. **`runtests.jl` wraps everything in an outer `@testset "Bennett"`**
   per Bennett-zy4u / U104, so nested testsets DO NOT print Test
   Summary lines; only the outer aggregate prints at the end. Do NOT
   use "Test Summary" as a progress marker — use line-count growth
   plus CPU-time advancement (1:1 = active, < 1:1 = blocked / I/O).
4. **Don't `pgrep -f` against your own bash wrapper.** A monitor that
   does `while pgrep -f "test/runtests.jl"; do …` will match its own
   bash arg-string and never exit. Use `kill -0 <PID>` instead.
5. **Don't SIGINT a long compile to "see what's stuck."** If CPU is
   advancing 1:1 with wall-clock, the process is making progress.
   Forcing a stack trace via SIGINT KILLS the process. Wait it out
   and rely on CPU growth + log-line growth as the liveness signal.
6. **bd dolt remote is misconfigured to ssh://** but bd state IS still
   synced via the regular git push because the `.beads/embeddeddolt/`
   dolt store is committed as regular git blobs. Filing
   `bd dolt push` failures during normal bd operations is a NOP for
   correctness (they're tracked in Bennett-ponm). Just `git push`.

**Next agent — Tier C1 remaining (in cheapest-first order):**
1. `atan2` (2-arg) — verify whether LLVM ingests as `llvm.atan2.f64`
   intrinsic or as `call double @atan2`; LLVM ≤17 doesn't ship the
   intrinsic. Different ingest path than the unary family.
2. `asin` / `acos` — both reduce to `atan` via identities now that
   `soft_atan` exists. File 2 separate beads. ~150 LOC each.
3. `tanh` — needs `soft_exp` (done); `tanh(x) = (e^{2x}-1)/(e^{2x}+1)`
   form with `|x|>20 → ±1` cutoff. ~150 LOC.
4. `sinh` / `cosh` — need `soft_exp` plus overflow handling. Common
   `expm1` trick for sinh near zero — possibly defer until Tier C2
   `expm1` lands.
5. `asinh` / `acosh` / `atanh` — reduce to logs (need `soft_log`,
   done; `soft_fsqrt`, done). Watch atanh cancellation near 0.

**Branch state:** `main @ 53a07e0`, pushed to `origin/main`, working
tree clean. The pre-existing dolt working-tree-modified files are bd
auto-sync metadata that get committed alongside subsequent bd
operations.

**Worklog state:** chunk 057 at 237 lines (qpke + s1zl entries),
this chunk 058 at 96 lines (handoff only). Next session prepends here.

