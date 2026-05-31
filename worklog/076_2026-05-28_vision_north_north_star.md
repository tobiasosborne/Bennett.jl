# Worklog chunk 076 — 2026-05-28

## Session log — 2026-05-31 — target=:reversible_vm dispatch arm (Bennett-33zr; BennettVM keystone)

**What changed.** Added the `target=:reversible_vm` dispatch arm to
`src/Bennett.jl` — the keystone letting `reversible_compile(f; target=
:reversible_vm)` route to the BennettVM backend (BennettVM bead `bennettvm-a5j`;
design in BennettVM `docs/adr/0003-target-reversible-vm-dispatch.md`). Cross-repo
change driven from BennettVM; per-diff user-approved 2026-05-31 (Rule 14).

**Mechanism — a registration hook, NOT a direct call.** BennettVM depends on
Bennett (path dep `../Bennett.jl`), so Bennett MUST NOT name BennettVM — a
reverse hard-dep is a forbidden cycle. So: new `const _REVERSIBLE_VM_BACKEND =
Ref{Any}(nothing)` next to `_compile_cache`; `reversible_compile(parsed::ParsedIR)`
intercepts `target===:reversible_vm` BEFORE the cache lock (errors if the Ref is
unset — "`using BennettVM`" message — else returns `_REVERSIBLE_VM_BACKEND[](parsed)`,
a `VMProgram`, bypassing the `ReversibleCircuit`-typed cache); BennettVM's
`__init__` writes `lower_vm` into the Ref at load (the arrow points UP only).

**Load-bearing subtlety (hostile-review catch).** The two tabulate short-circuits
in `reversible_compile(f, ::Type)` (`return bennett(lr)` for explicit
`strategy=:tabulate` and for the `:auto` cost-model pick on small-width mul/div)
run BEFORE the ParsedIR-overload delegation. Unguarded, a small mul/div fn
compiled with `target=:reversible_vm` would SILENTLY return a circuit (Rule-1
fail-silent). Fixed by guarding both with `target !== :reversible_vm`, so a VM
compile falls through to the delegation where the intercept fires. No `driver.jl`
change — the intercept returns before `lower()` sees `:reversible_vm`, so the
`:gate_count`/`:depth` whitelist is untouched and `target=:nonsense` still raises.

**Tests.** New `test/test_reversible_vm_dispatch.jl` — STUB-driven (Bennett.jl
gains NO BennettVM test-dep; the stub returns a sentinel tuple, an `isa` catches
any circuit-path leak): (1) hook-inert→errors both overloads; (2) hook-set→routes
both overloads; (3) both tabulate triggers (`strategy=:tabulate` AND
`bit_width=2,x*x`) route to the hook, complementary circuit-target compiles still
produce circuits; (4) circuit path byte-unchanged + unknown-target rejected.
20/20 in isolation (`--check-bounds=yes`). Full `Pkg.test()`: GREEN —
688498 Pass / 2 Broken (pre-existing `@test_broken`) / 0 fail / 0 error,
26m47s; `test_reversible_vm_dispatch.jl ✓` ran in-suite and `test_hygiene_aqua_jet.jl ✓`
(the new `_REVERSIBLE_VM_BACKEND` Ref + the dispatch arm trip neither Aqua's
export/ambiguity checks nor JET's static analysis of the `Ref{Any}` dynamic
call). Circuit path byte-unchanged.

**Process.** 3+1: 3 read-only research agents (dispatch surface / ParsedIR
contract / Bennett-spqu mandate) → ADR 0003 consensus design → hostile review
(3 defects folded in: tabulate bypass; `:circuit` alias deferred to doc-only;
`lower_vm` stdout digest gated to `@debug`) → 2 convergent proposers → this
implementation; orchestrator as reviewer (+1).

**Gotcha for next agent.** Bennett.jl's `bd` hit a Dolt-remote corruption on
auto-push (`fatal: bad object refs/dolt/remotes/origin/...`) when creating
`Bennett-33zr` — the bead landed in the LOCAL Dolt DB (`.beads/embeddeddolt/`,
git-tracked) but `bd dolt push` to the dolt remote failed. Pre-existing infra;
local DB + git-bundled `.beads/embeddeddolt/` are intact. Needs a separate
`bd dolt` repair — do NOT `bd init --force`.

## Session log — 2026-05-28 — Vision PRD: north-north-star (quantum-taint toolchain)

**What changed.** Updated `Bennett-VISION-PRD.md` to fold in a broader vision
that emerged from stakeholder discussions, sitting one level *above* the two
existing direction docs (`Bennett-Enzyme-Parity-NorthStar.md` = opcode
coverage; `Bennett-ReversibleVM-PRD.md` = the dynamic-control-flow VM target).
Doc-only edit — no code, no tests, so the §2 3+1 protocol does not apply.

Three edits to `Bennett-VISION-PRD.md`:
1. New top-of-doc blockquote (a "north-north star") above the existing
   reversible-VM blockquote, nesting the reversible-VM direction inside the
   wider toolchain.
2. New §1.1 (larger picture: the taint-driven quantum compiler toolchain +
   our scope boundary + the identity-on-untainted-code property) and §1.2
   (operating order: reversible-first then recycle; what recycles; the three
   quantum-phase walls).
3. §10 Non-Goals reconciled — "not a general-purpose quantum compiler" kept
   (literally still true) but repositioned as "the classical-oracle core of
   one"; hardware-synth non-goal annotated as a downstream toolchain stage.

**The vision (the non-derivable WHY).** Bennett.jl + BennettVM.jl are the
classical-oracle-synthesis core of a full quantum compiler toolchain organised
around *taint*. Upstream (owned by others, C/Rust actively being targeted):
minimal language extensions introduce "quantum taints"; clang/LLVM propagate
them and optimise the classical remainder. **Our boundary: from the tainted
LLVM opcodes on down** — Bennett.jl reversibilises the bounded straight-line
slice, BennettVM the rest (jumps, unbounded loops, runtime memory), targeting
a *quantum* version of the Bennett VM, the common target for quantum languages,
itself lowered to hardware. Litmus: the toolchain is the identity on untainted
code (the "compile Linux for the quantum VM" thought experiment).

**User's stated operating order:** get classical reversible compilation
excellent first, THEN reuse learnings + recycle results (Toffoli libs,
soft-float, memory strategies, VM history/pebbling) for the quantum layer.
Quantum is a later phase, not a parallel track. **So near-term work does not
redirect** — the Enzyme-parity opcode coverage + BennettVM dynamic-control-flow
roadmaps remain the priority; the vision contextualises them.

**Quantum-phase walls recorded for later (not problems now):** (1) reversible
≠ unitary — the genuinely-quantum gates come from the quantum source, not from
reversibilising C; (2) tainted control flow can't run on a classical PC →
back to bound-and-unroll or repeat-until-success; (3) quantum uncomputation
must *disentangle* ancillae, stricter than classical ancilla-zero (maps to the
Unqomp/Reqomp/Qurts work BennettVM already references). Keep ancilla cleanup as
a per-wire postcondition so it tightens to disentanglement without redesign.

**Near-term design touch-point noted in the PRD:** the real input is a tainted
*slice* of LLVM (classical inputs as known/constant wires), implying a
fragment-compile entry mode alongside today's whole-function
`reversible_compile`. Not urgent; flagged so it isn't designed out.

**Housekeeping observation (not fixed — out of task scope):** the
`WORKLOG.md` "Index — newest first" table starts at chunk 074; chunk 075
(479 lines) is missing an index row. Two pre-existing stale cross-refs in
`Bennett-VISION-PRD.md` call Non-Goals "§9" when it is §10 (predate this edit).
Left untouched to keep this diff focused.
