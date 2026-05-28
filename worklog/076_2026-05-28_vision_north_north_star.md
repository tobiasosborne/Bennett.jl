# Worklog chunk 076 — 2026-05-28

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
