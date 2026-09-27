# Worklog chunk 109 — 2026-09-26 — Astra campaign verdict + handoff

## Session log — 2026-09-27 — Bennett-iwj6 landed (3f3ff1b + ff7d635); model audition; BennettVM worker started

**iwj6 (verdict step (b): second implementations held to the first one's oracle).** Implemented by
`stealth/space-bunny-alpha`; follow-up fix by the orchestrator from a deepseek-flash finding.
- F2: tabulation is refused for ANY explicit `bit_width` (explicit `:tabulate` throws, `:auto`
  falls through to expression lowering). The table evaluates the natural-width Julia function;
  `bit_width=W` means `_narrow_ir` semantics, a different function.
- **`bit_width == natural width` is STILL narrowing.** `_narrow_ir` rewrites every width, so
  `f(x::Int8) = Int16(x)*Int16(x) > 200 ? 1 : 0` at `bit_width=8` differs from native on 191/256
  inputs under `:expression` while the table matched native. The first landing (3f3ff1b) treated
  W == natural as a no-op and tabulated; ff7d635 closes it. That the expression result at
  bit_width=8 differs from native is Bennett-mrhg territory (casts between source widths).
- F3: QROM output width now comes from `Base.return_types` (single concrete supported Integer),
  not the first argument. Int8→Int16 widening gives 16 bits / 400, was 8 bits / -112.
- F23: `_validate_compile_options` (driver.jl) is the single copy of the option whitelists, used
  by `lower()` and every entry point before either tabulate exit. The entry points admit
  `:reversible_vm` via `_VALID_TARGET_ENTRY`; `lower()` does not. `Tuple{Float64}` + `bit_width`
  now throws.
- **Consequence:** the `:auto` → tabulate redirect is UNREACHABLE today (cost model needs total
  input width ≤ 4; every supported scalar type is ≥ 8 bits). test_h0ai T17 takes its documented
  `@test_skip` → suite Broken count 3 → 4. Follow-up Bennett-iq0r (tabulate under true narrowed
  semantics; depends on mrhg).
- test_tabulate.jl's small-W testsets pinned the defect (masked natural-width values); rewritten
  to assert the refusal plus natural-width exhaustive tabulation.
- Known, not this bead: untyped `simulate` decodes UInt8→UInt16 widening returns as signed
  (zc50 heuristic, Astra F4); captured closure variables become extra inputs (Bennett-o9sv).
- Gates: new file 18616/18616; **full suite at 3f3ff1b: 1546540 pass / 4 broken / 0 fail**.
  ff7d635 verified by the iwj6, tabulate, h0ai, xlsz, bennett, reversible_vm_dispatch files.

**Model audition (same iwj6 prompt, separate worktrees).** space-bunny-alpha (`--thinking max`):
47 min, cleaner structure and docs, candid report, but shipped the W == natural hole.
deepseek-flash (`--thinking high`): 27 min, same overall design, and caught that hole unprompted.
Both rewrote test_tabulate.jl for the same reason. Conclusion: space-bunny is a fine default
implementer (and free); its diffs still need witness re-execution and review.

**Orchestration notes.**
- `ps` CPU time is NOT a liveness signal for `pi` (always 00:00:00). An earlier deepseek run was
  killed as "hung" on that signal after an hour without file changes; that diagnosis is unproven.
- Bennett.jl workers run in detached worktrees under the session scratchpad; the full suite runs
  in its own worktree per commit. BennettVM loads Bennett by relative path `../Bennett.jl`, so
  BVM workers cannot use worktrees and see the Bennett.jl main tree live.
- BennettVM: space-bunny started on bennettvm-tghl (independent forward oracle for the property
  gate); queue then 6xy0, wtda, aul4, gn6o, hyi6, av72.


## Session log — 2026-09-27 — rule change (3+1 retired) + Bennett-q7yd / Bennett-lcye landed (7d83702)

**Rule change (maintainer, 2026-09-27):** the 3+1 protocol is RETIRED. One implementer per bead,
plus a semiregular independent code review over the accumulated diff. CLAUDE.md rule 2 rewritten.
Beads/worklog text saying "CORE → 3+1" predates this. Orchestration this session: Claude
orchestrates serially; implementers are `pi` agents (`deepseek/deepseek-flash`,
`openrouter/xiaomi/mimo-v2.6-pro`, and an audition of `openrouter/stealth/space-bunny-alpha`);
`codex exec -m gpt-6-sol` xhigh for review. Workers never commit, never touch `.beads/` or
`worklog/`; the orchestrator re-runs witnesses, runs the full suite, commits, closes.

**q7yd + lcye (verdict step (a): checkers that certify nothing).** Implemented by deepseek-flash.
- Gate primitives now have inner constructors: `CNOTGate(c,c)`, Toffoli with `target ∈ controls`,
  and any wire index < 1 throw `ArgumentError`.
- **`ToffoliGate(c,c,t)` is LEGAL and must stay legal**: `lower_mul_wide!` (multiplier.jl) emits it
  on the diagonal when squaring (`a === b`). Rejecting it breaks `x*x` and trips
  test_gate_count_regression. It is exactly CNOT(c,t). Only target-equals-control is a defect, and
  no emitter in src/ produces that.
- `ReversibleCircuit` constructor: within-class duplicate positions (input/output/ancilla/
  loop-check), non-positive widths, `sum(widths) != length(wires)`, and gate wires outside
  `1:n_wires` all throw. Cross-class `input ∩ output` aliasing remains permitted (self-reversing).
- Cost: gate-bounds scan is 0.06 s on the 11,033,736-gate soft_sin circuit; constructor total
  (~2.7 s there) is dominated by the pre-existing Set partition work.
- test_pksz's rejection testset relied on the constructor NOT checking gate bounds; it now asserts
  construction-time rejection, and pins `controlled()`'s own guard via post-construction
  `push!(c.gates, …)`.
- Inner constructors remove Julia's implicit converting constructor (`CNOTGate(::Int32, …)` is now
  a MethodError). Full suite shows no emitter relied on it.
- Gates: new file 586/586; gate-count 39/39; **full suite at 7d83702: 1527507 pass / 3 broken /
  0 fail** (run in a detached worktree while the next worker used the main tree).

**Orchestration gotchas.**
- A wait loop of the form `while pgrep -f <pattern>` matches ITS OWN command line and never exits;
  likewise `pkill -f` kills the calling shell. Run the worker in the foreground of a background
  task instead and let the harness notify.
- Full suite wall time was ~52 min (vs ~28) with two workers and another Julia job on the box.
- Workers run `bd show`, which churns `.beads/embeddeddolt` in their tree — never stage `.beads/`
  from a worker worktree.


## Session log — 2026-09-26 — VERDICT: does Bennett survive the review? (maintainer question, orchestrator answer) — READ FIRST

Campaign detail, numbers, landed fixes and gotchas: top of `worklog/108`. Finding→bead maps:
`reviews/2026-09-26-astra/*.triage.md`; re-execution evidence: `*.verification*.md`.

**Verdict: survives, as a compiler with a SOUND CORE and an UNSOUND PERIMETER.** Not one of the
162 findings shows Bennett's construction, or ripple/Cuccaro/QCLA arithmetic on ordinary integer
code, computing a wrong answer. About forty show layers AROUND that core accepting programs they
cannot compile and returning a circuit that passes `verify_reversibility`. The lesson is design,
not a bug list: **a clean reverse pass proves nothing about the forward result.**

**What held up (do not churn):** arithmetic lowering (icmp/shift/div/cast) exhaustive on Int8
pairs; Default Bennett on nested diamonds, loops, polynomials — inputs preserved, ancillae zero;
soft-float core arithmetic 1.8 M random bit patterns bit-exact; the positive-budget verifier;
q9pi compose/controlled guards (6,669 adversarial assertions); c6ex, stwr, hsm3 each do what
they claim. Everything built red-first under hostile review was sound.

**Four failure classes (the classes matter more than the count):**
1. **Silent acceptance at the boundary** — `extract/` recognisers (heap, Dict, Vector, sret
   funnel, GC preamble) pattern-match Julia codegen and delete what they believe is machinery;
   at a 90 % match they delete user effects (`fill!` on a Memory → 7v22; Dict mutation behind a
   branch → bc2m; store through a caller pointer → f4z4; sret funnel stores → t5u1). The August
   sweep's "decompiler on a treadmill" prediction, now with executed witnesses.
2. **Predicates locally right, globally wrong** — select-ed pointer stores (37w3, FIXED), loop
   headers after exit (i5zn), irreducible regions (73gr), reachable error branches (jzhh, o6ge).
   All the CLAUDE.md false-path-sensitisation class, in memory and CFG code instead of scalar φ.
3. **Second implementations never held to the first one's oracle** — tabulate (iwj6), narrowing
   (mrhg), compile cache vs method redefinition (4ddk), five strategy fast paths dropping loop
   guards (ui55), Eager/ValueEager cleanup (3vji, htu2).
4. **Checkers certifying what they do not check** — zero-budget verifier (ukup, FIXED),
   set-based partition checks (q7yd), self-controlled gates (lcye), peak_live_wires (kk3y),
   toffoli_depth (u3b2), ~10 test files green under identity mutation (z3j3, oac7, z1o8, s99j,
   bn0p, 8gkj; BVM tghl, jpb).

**Fixability.** Every one of the 107 beads carries a concrete fix; today's six landings prove
the loop (reproduce → red → fix → green → full suite). Classes 3 and 4 are mechanical and
cheap. Class 2 is CORE work, 3+1 each, fixes known (dominance-based loop discovery, an
iteration-active predicate, failure predicates carried as runtime guards) — cost is care, not
invention. **Class 1 is where "fixable" is the wrong question:** each recogniser can be
patched, but without a written input contract every patch is one more wall on the treadmill,
and the correct disposition for most class-1 beads is REJECT LOUDLY, not widen. That is
Bennett-V2-PRD decision **D0** and it is the maintainer's call, not an agent's.

**Recommended order:** (a) make verifier + simulator reject malformed circuits at construction
(q7yd, lcye; qa2g landed) — this changes what every future green means; (b) give tabulate and
narrowing the same exhaustive oracle as expression lowering (iwj6, mrhg); (c) i5zn with the
V-37w3 RED fixture, then 73gr; (d) BVM wtda/aul4/gn6o/hyi6/av72; (e) decide D0 before touching
any class-1 bead.

**Session close state:** both repos level with GitHub; Bennett.jl full suite green at fb18a0e
(uwv2 landed after, validated by its own softfloat files); codex quota 100 % used, resets
2026-10-01 08:14 UTC; no codex to be used further this session per maintainer. Leftovers for a
human: `stash@{0}` (garbage, classifier-refused drop), `repo_state.json` path ping-pong
(never commit), `gh` unauthenticated, stale `origin/wip/a70z-overflow-bit`, BVM `references/`
PDFs untracked.
