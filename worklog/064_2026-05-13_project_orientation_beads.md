## Session log — 2026-05-13 — project orientation + beads workflow check

Orientation-only session. Read `README.md`, `AGENTS.md`, `CLAUDE.md`,
top-of-index `WORKLOG.md`, latest worklog shard 063, `src/Bennett.jl`,
`test/runtests.jl`, and sampled the current source/test layout. No
compiler source changes.

Project shape confirmed:

* Public entry point is `reversible_compile`, with tuple/scalar overloads
  in `src/Bennett.jl` and Float64 SoftFloat dispatch in
  `src/softfloat_dispatch.jl`.
* Pipeline is LLVM.jl C-API extraction -> `ParsedIR` -> `lower` ->
  Bennett transform -> simulation/diagnostics.
* `src/lower.jl` and `src/ir_extract.jl` are now split into
  `src/lowering/*` and `src/extract/*` include trees, but the root files
  remain core pipeline surfaces for the 3+1 rule.
* Current recent frontier per worklog is Tier C2 transcendental work:
  `soft_log1p` and `soft_expm1` landed on top of completed Tier C1
  hyperbolics. Important gotcha from 063: every
  `startswith(cname, "llvm.<intrinsic>")` prefix match needs a trailing
  dot when matching LLVM intrinsic families, or sibling names like
  `llvm.expm1.*` can be swallowed by `llvm.exp.*`.

Beads workflow learned/verified:

* Always start with `bd prime` for local workflow context.
* Use `bd ready` / `bd show <id>` / `bd update <id> --claim` to start
  work, and `bd close <id> --reason="..."` to close completed work.
* Do not run multiple `bd` commands concurrently in this checkout: the
  embedded Dolt backend takes an exclusive lock. A parallel `bd ready`
  overlapped with `bd prime` and failed with the expected lock error.
* Current `bd stats`: 481 total issues, 35 open, 3 in progress, 432
  closed, 35 ready. Current in-progress beads observed:
  `Bennett-cc0.5`, `Bennett-tzrs`, `Bennett-z2dj`.
* `bd ready -n 20` shows the top ready queue including `Bennett-7kzr`,
  `Bennett-8guh`, `Bennett-25dm`, `Bennett-ponm`, `Bennett-2uas`,
  `Bennett-ktt8`, `Bennett-glh`, and `Bennett-fg2`.
* `bd prime`/`bd stats` warn `.beads` has mode 0755; recommendation is
  0700. They also try a Dolt auto-push, which fails in the sandboxed
  environment because `github.com` cannot resolve. That failure did not
  block local reads.
* `bd` read commands dirtied embedded Dolt files under
  `.beads/embeddeddolt/...`; treat this as tool-state side effect, not a
  source change or bead close.

Validation:

* Julia smoke check required escalation because the launcher needed to
  create normal user-level lock/config files. Approved prefix:
  `julia --project`.
* Smoke command:
  `julia --project -e 'using Bennett; c = reversible_compile(x -> x + Int8(1), Int8; add=:ripple); println(gate_count(c)); println(simulate(c, Int8(5))); println(verify_reversibility(c))'`
* Result: precompiled Bennett, then printed
  `(total = 58, NOT = 6, CNOT = 40, Toffoli = 12)`, `6`, `true`.
  This matches the pinned explicit ripple i8 increment baseline.

Minor observation for future cleanup: several comments in
`src/softfloat/fasinh.jl`, `facosh.jl`, `fatanh.jl`, and `fsinh.jl`
still say Bennett lacks `soft_log1p` / `soft_expm1`. That was true when
those files landed, but is now historical after the 0ulc/o7cy commits.
Do not "fix" casually if a cleanup bead exists; those comments document
why the original wider polynomial regimes were chosen.
