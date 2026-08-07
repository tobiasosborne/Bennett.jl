# Worklog chunk 106 — 2026-08-07 — Bennett-57hd hostile review FAILED + fix cycle

## Session log — 2026-08-07 — SESSION WIND-DOWN: 5viz landed UNREVIEWED-WIP (Bennett-gcf7); six-arc session retrospective

### Wind-down state (user-directed, graceful)

The 5viz (wall 11) implementer was stopped mid-flight at "Now the BVM E2E
test file:" — its Bennett-side work is COMPLETE and was orchestrator-verified
green before landing: test_5viz 91/91, ALL EIGHT marker advances green
(sy29 98, 57hd 101, 40ys 135, 7wsz 113, bvmd 91, foz5 70, p06b 624,
vau9 76), gate-count 39/39, all --check-bounds=yes. Landed UNREVIEWED-WIP
per the a8nw precedent. **Bennett-gcf7 (P1) is the completion bead** —
runtests registration, the BVM E2E gate, the hostile review, then the
single full-suite close gate. Do NOT build walls 12-14 on the arm until
gcf7 passes.

### The session in one paragraph (2026-08-06 → 08-07)

Six arcs landed and pushed in lockstep across both repos: the a8nw review
debt paid (jbko PASS-WITH-CONCERNS, sku0/vckk filed), then FIVE frontier
walls cleared — p06b (wall 6, aggregate stores), foz5 (wall 7, ADR 0017
§4a CONFINED-VALUE), bvmd (wall 8, root-scale coherence), sy29 (wall 9,
arena-src memcpy), 57hd (wall 10, ADR 0017 §4b VALUE-IDENTITY — the
strongest contract: full oracle match, no arena premise). _growend!
extracts completely. Ten consecutive beads with ZERO BennettVM src
changes. Hostile reviews caught ~12 real defects pre-commit including
FOUR executed miscompiles (p06b capacity clobber, sy29 cross-allocation
overlap, 57hd self-store escape, bvmd's rejected route-iii cross-function
re-stamp); every one died before landing.

### Recommendations for the next agent, in priority order

1. **Bennett-hk5i + bennettvm-ciff (P0, USER DIRECTIVE)** — the docs
   epics (kickass READMEs/tutorials/animations, the
   almost-idempotent-channels bar). These OUTRANK the frontier. Split
   into child beads on claim; doc-work mode is binding.
2. **Bennett-gcf7 (P1)** — complete + review the 5viz WIP (spec in the
   bead; scout design in docs/design/5viz_scout.md).
3. **The endgame is measured**: after 5viz, walls 12 (1zow silent-skip),
   13 (second 8bys memcpy), 14 (env-alloca tier decision, bvmd family —
   the 5viz scout PROVED byte-stamping the three env memcpys makes the
   ROOT extract with NO WALL AT ALL). Then bennettvm-rxgy for the
   full-corpus RUN.
4. **Process rules now binding** (user-ratified this session): exactly
   ONE full Pkg.test per arc, AFTER the review verdict + fix cycles, on
   the final landing tree; reviewers run NO full suites; scout-with-
   tripwire before every wall arc; prose-vs-predicate on every message
   (bd memory); check marker discriminators against MESSAGE TEXT, not IR.

### Gotchas worth re-reading before the next arc

- worklog/098-106 carry the arc-by-arc lessons; the bd memories carry the
  cross-session rules (prose-vs-predicate; h0ai layers; cwd-rerun-lf14).
- The uinn meta-test still false-positives on prose 'catch' in
  extract/ docstrings (Bennett-gb39) — say 'detect', or fix the scanner.
- AGENTS.md at the repo root is stale-untracked (Bennett-6gfu); BVM's
  references/ PDFs are untracked (user decision pending).


Chunk 105 closed at 189 lines and this entry is ~140, which would put it past
the ~280-line cap, so starting 106 per CLAUDE.md §0.

## Session log — 2026-08-07 — Bennett-57hd: HOSTILE REVIEW **FAILED**, fix cycle landed (same day)

**Verdict on the first landing: FAIL — one EXECUTED counterexample plus four
latent fail-opens.** The orchestrator took MORE than the reviewer's
minimum-blocking set, on the grounds that ADR 0017 §4b's sentence *"every
unmodelled effect terminates the analysis unsuccessfully"* must be **literally
true at landing**. All five fixed, RED-first, no commit.

### D1 (P0) — THE ONLY EXECUTED COUNTEREXAMPLE THIS CONTRACT HAS EVER HAD

`_57hd_alloca_noescape`'s store arm checked only the **ADDRESS** operand. So
`store ptr %a, ptr %a` — the alloca's own address written into itself — passed
the non-escape scan, the reloaded copy `%p = load ptr, ptr %a` classified
`:other`, `_57hd_roots_disjoint(%a, %p)` returned **true**, and a later
`store ptr %junk, ptr %a` (a write straight through the alias) was **SKIPPED**
by the clobber scan.

> **Measured on BennettVM (`probe3_vm.jl`): the admitted `sub` evaluated to 64**,
> against a §4b guarantee of 0 in BOTH worlds, and it escaped into a
> `gc_alloc_obj` size operand.

Fix: `sops[2].ref == a.ref || return false; sops[1].ref == a.ref && return false`
— the address half AND the value half. The GEP recursion already covers the
`store ptr %a, ptr (gep %a, k)` spelling, because the recursive call sees the
same store with `%a` as its VALUE operand. Corpus-neutral (zero self-stores in
either body). Gate **(C3)**, which asserts the HELPER as well as the predicate,
because the helper is what a future edit "simplifies" — and asserts a clean
sibling alloca still passes, so the gate is not vacuously rejecting everything.

**The lesson, and it generalises past this arm:** a two-operand instruction has
TWO roles, and an escape analysis that names only one of them has not looked at
the instruction. `store` is the only LLVM opcode where the pointer can appear as
either operand, which is exactly why it is the one that was got wrong.

### D2 (P1) — OPERAND BUNDLES ARE INVISIBLE TO THE RAW ATTRIBUTE

A **truthfully** `memory(none)`-declared callee, called with
`[ "jl_roots"(ptr %junk) ]`, was ADMITTED (`probe5.jl` R1). LLVM's own
`CallBase::getMemoryEffects()` ORs in `writeOnly()` for a clobbering bundle;
reading the raw `memory` attribute believes the declaration about a call LLVM
itself treats as a writer. Bundles ALSO shift the operand→parameter index
mapping that the `nocapture` scan indexes into, so the same guard went in both
places: `LLVMGetNumOperandBundles(call) == 0 || return nothing` in
`_57hd_mem_effects`, and `... || return false` in the noescape call arm.
Corpus-neutral (zero bundle sites). Gate **(D4)**. The ADR's (P1) declaration
stays true **without amendment** — one added sentence records that bundles fail
closed.

### D3 (P2, both taken) — THE ARM WAS RESTING ON OTHER ARMS' GUARDS

* **undef / poison.** LLVM **UNIQUES** them per type, so two INDEPENDENT chains
  bottoming out in `ptr poison` canonicalise to the SAME ref and (V2)'s equality
  passes for two things that are not even values. Measured `x=>true, y=>true`
  (`probe4.jl` Q2). The extraction happened to fail downstream in Bennett-bjdg's
  arm — **luck, not design.** Gate (D5), both spellings.
* **negative mem-intrinsic length.** `[off, off+n)` with `n < 0` is an INVERTED
  range: empty under the `h <= lo || l >= hi` test, so every real write it
  covers is skipped. Bennett-37mt rejects such a memcpy today; again, another
  arm's guard. `n >= 0 || return :unknown`. Gate (D6).

**Both share one principle, now written into the arm: a contract may not rest
its own soundness surface on a different arm's rejection.** Arms move.

### D4 (P2) — RAW vs CANONICAL ROOTS

`_57hd_canon` passes CANONICALISED roots to `_57hd_clobbered`, but
`_57hd_write_footprint` returns RAW `_p06b_slot_key` roots. **Not unified** —
that would make the two functions mutually recursive and materially enlarge the
recursion graph of the arm's most delicate walker for no measured gain. Instead
the invariant is written down **as a case analysis, not a hope**: `_57hd_canon`
returns its argument unchanged for everything that is not a pointer `load`, so
alloca / noalias-call / Argument / global roots are canonical == raw already;
the ONLY divergence class is LOAD vs LOAD, both of which classify `:other`,
which `_57hd_roots_disjoint` never calls disjoint, so the `r == root` test fails
and the function returns **true (clobber)**. Every divergence fails CLOSED. The
docstring also names the change that would BREAK the argument (canon returning
an alloca or call for a load-rooted address), so the next reader knows the
trigger.

### D5 (P2) — LOOP SAFETY WAS CORRECT AND STATED NOWHERE

The reviewer's probes confirmed it; nothing in the code or the ADR said it. Now
in both, one paragraph each: **a basic block executes as a straight line on
every entry**, so every fact the walker establishes is per-iteration and the
load reads what the store wrote *in that same iteration*; (V2) forces `%S`/`%T`
into the block, and a cross-iteration value can only arrive through a `phi`,
which (V0) refuses outright. Shipped as gates **(T)** (a loop-body cluster IS
admitted — adding a back-edge veto would be a REGRESSION) and **(T2)** (a
loop-carried pointer `phi` source is refused — the proof that the route is
closed). Without this a future reader adds an unnecessary veto, or doubts the
contract.

### Ledger + prose corrections in the ADR

Two premises the reviewer surfaced, added honestly: **(P4)** LLVM.jl's
instruction iteration yields PROGRAM ORDER (the substrate for the positional
sequence and the definition-order test — an LLVM.jl API premise, shared with
every positional walker in the file), and **(P5)** the VM transport of the
same-slot-reload rule follows **inductively** (base case SSA ref equality =
the same node = the same cell; each store-forward hop is (V3)-certified), not by
assumption. The failure matrix's native-throws cell was loose — "because those
guards' operands are oracle-exact" alone. Corrected to the real justification:
the §4a **conditioning clause** PLUS §4a **clause (iv)**, under which a
§4a-admitted value can only operate a branch with a pruned `:__unreachable__`
successor and therefore **never operates a live guard**, so a §4a admission
elsewhere cannot silently degrade a guard fed by a §4b value. The disclosed
residual now names the executed fail-open rather than describing the class in
the abstract.

### GOTCHA THAT COST A CYCLE

`LLVMIsUndef` / `LLVMIsPoison` return an **`LLVMBool` (`Cint`)**, not a value
ref. `LLVM.API.LLVMIsUndef(res) != C_NULL` compares a `Cint` against a
`Ptr{Nothing}`, which is **true for every input** — it reset every canonical
result and REJECTED THE CORPUS (gates (A)/(A2)/(P)/(D3)/(F3) all went red at
once). The `LLVMIsA*` family returns refs; the `LLVMIs*` predicates return
`Cint`. The note is in the code so nobody "makes them consistent".

### RESULTS

* `test/test_57hd_value_identity.jl` **83 → 99** (gates C3, D4, D5, D6, T, T2
  added; all RED-first — D1/D2/D3a from the reviewer's own pre-fix probes, D3b
  by temporarily disabling the one-line guard, which flipped `pred(a)`
  `true → false`).
* `BennettVM/test/test_57hd_value_identity_vm.jl` **107/107**, unchanged.
* Eleven confirmation files re-run and diffed — **every count identical to the
  pre-fix landing**, i.e. the fix cycle is marker-neutral: 583s 28, foz5 67,
  jbko 73, bvmd 88, p06b 621, sy29 94, 37mt 86, vau9 73, 40ys 132, 7wsz 110,
  gate-count **39/39**.
* **FULL SUITES, implementer-run, verbatim.**
  `Bennett       | 691958       3  691961  28m18.6s` / `Testing Bennett tests passed`
  (**+15** over the pre-review landing's 691943, exactly the 16 assertions the
  six new gates add minus the one `_VI_D6` fixture assertion that replaced an
  older one — the new-file total went 83 → 99.)
  `BennettVM     | 10963  10963  4m47.6s` / `Testing BennettVM tests passed`
  (unchanged — no BVM gate was added or removed by the fix cycle.)
