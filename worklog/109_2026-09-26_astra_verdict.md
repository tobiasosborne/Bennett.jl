# Worklog chunk 109 — 2026-09-26 — Astra campaign verdict + handoff

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
