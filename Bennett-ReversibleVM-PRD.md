# Bennett.jl — Reversible-VM Backend PRD

## Status

**Direction PRD — the north star for the next major version of Bennett.jl.**
This document fixes the *direction* and the *rationale*. The *how* — the
concrete machine model, the reversible instruction set, the milestone roadmap —
is produced by a subsequent research + 3+1 design phase (see §8). Design-only
at this stage; no code.

Tracked as **`Bennett-spqu`**. Date: 2026-05-22. Origin: the 2026-05-22
loop-architecture discussion (the A/B/C/D solution-set analysis).

## 1. One-line summary

Add a second lowering target — a **reversible abstract machine** — so Bennett.jl
can compile terminating computations of *statically-unknown length* (unbounded
loops, runtime-sized data structures), which a fixed reversible circuit
fundamentally cannot represent.

## 2. The problem this solves

Bennett.jl today emits a **circuit**: a fixed, finite, loop-free, branch-free
sequence of reversible gates, decided entirely at compile time. That is the
correct target for the founding use case — a quantum oracle for
`when(qubit) do f(x) end` needs a fixed gate sequence.

But it carries an intrinsic limitation. **A circuit has no loop construct and
no runtime-sized memory.** Therefore:

- every loop must be **unrolled** to a compile-time-constant iteration count;
- every data structure must have a compile-time-constant maximum size;
- branches are not control flow — both arms are computed and a multiplexer
  selects.

The four ways to handle a loop under reversibility (the 2026-05-22 analysis):

- **A — bound and unroll.** What the circuit target does today
  (`max_loop_iterations`). Fixed depth ∝ the bound. No finite circuit exists
  for a genuinely unbounded loop.
- **B — log the control history.** The Bennett construction itself; in a
  circuit the "history" is the ancilla wires, and the existing pebbling /
  checkpoint strategies are its space-optimised form. **B does not escape
  finiteness** — a circuit's log is itself made of wires, so it is
  compile-time-fixed-size. A and B compose; they are not alternatives.
- **C — intrinsically reversible loop forms.** Reversible languages (Janus)
  use entry/exit-assertion loops that are invertible by construction. As a
  *compiler analysis* this is a circuit-quality optimisation (cheaper unrolled
  loops); it does not remove the unroll bound.
- **D — a reversible machine, not a precompiled circuit.** A machine with a
  program counter executes the loop *dynamically*. This is the only one of the
  four that handles a terminating loop of unknown length. **This PRD is D.**

The honest core: Bennett.jl compiles functions with fixed-width typed inputs —
a finite input domain — so for any *total* function a finite worst-case bound
always *exists*; the practical limits are *discovering* the bound and the
*size* of the worst-case circuit. The only genuine, universal wall is
**non-termination**, which is undecidable (§6). Everything else is a question
of which backend, and at what cost.

The circuit target handles bounded computation well. For genuinely dynamic
computation — an unbounded-but-terminating loop, a hash table sized by
wide-typed inputs — bound-and-unroll is either impractically large or cannot
be sized at all. **That gap is what the reversible-VM target closes.**

## 3. The proposal — a reversible-VM lowering target

A new value of the **existing `target=` dispatch** on `lower()`. This is **not
a fork**:

- the front-end is fully shared — `extract_parsed_ir` → `ParsedIR` is identical
  for both targets;
- the Bennett construction and the existing pebbling / checkpoint strategies
  are reused — they become the reversible-VM's space-management layer;
- the two targets diverge only at the `lower` / `bennett` stage.

The reversible-VM target emits a **reversible program for a reversible abstract
machine** — a machine with a program counter and reversible state transitions —
instead of a flat gate list. On this target:

- a loop stays a loop and executes dynamically, as many times as the input
  demands;
- reversibility comes from making every transition invertible — logging the
  minimal control/overwrite history (Solution B), with Bennett-style
  checkpointing trading history space against recomputation time;
- memory is sized at runtime.

This is exactly **the architectural choice Enzyme makes**: Enzyme emits a
*program* — which has loops and runtime allocation — not a circuit, which is
why Enzyme never needs a loop bound. The reversible-VM target makes Bennett.jl
emit a *reversible program*, inheriting the same freedom.

## 4. Why this is the north star

1. **It removes the defining limitation.** A terminating computation of
   statically-unknown length — precisely what a fixed circuit cannot represent
   — simply runs. Unbounded `while`, `push!`-grown collections, `Dict` on
   wide-typed inputs all become compilable.
2. **Enzyme parity.** Bennett.jl's stated vision (`Bennett-VISION-PRD.md`) is
   "the Enzyme of reversible computation." Enzyme's coverage of dynamic
   control flow and dynamic memory is a direct consequence of emitting a
   program. A reversible-program target is the structural step that brings
   Bennett.jl to genuine parity rather than parity-modulo-loops.
3. **Quantum-architecture research target.** A reversible VM with dynamic,
   classically-controlled execution is structurally close to **dynamic quantum
   circuits** — mid-circuit measurement with classical feed-forward,
   conditional gates, repeat-until-success — which modern quantum hardware
   increasingly supports. A reversible-program target is therefore not merely
   "the classical fallback for when a circuit won't do"; it is a plausible
   compilation target for quantum architectures with classical control.
   Establishing that mapping precisely is an open research question this
   workstream should pursue.

## 5. Scope — the two targets coexist

The circuit target is **not** replaced. A quantum oracle on a static-gate
substrate genuinely needs a fixed gate sequence — you cannot place a VM with a
program counter on it. The two targets coexist, selected by dispatch:
`target=:circuit` (default, unchanged) and `target=:reversible_vm` (opt-in).
Choosing per function is a feature, not a compromise.

## 6. What stays hard — the honest wall

**Non-termination.** If the source computation never halts on some input, no
reversible scheme — circuit or machine — rescues it; the reversible simulation
diverges too, and whether it halts is undecidable in general. This is a true,
universal wall and the reversible-VM target does not move it. It is, however,
the *only* such wall: "halts, but the bound is unknown" is **not** a wall for
the VM target — the machine simply runs until it halts.

## 7. Relationship to existing work and prior art

- **Bennett 1973**, *Logical Reversibility of Computation* — the reversible
  Turing machine; logical reversibility preserves computational universality.
  This is the theoretical license for D.
- **Bennett 1989**, *Time/Space Trade-Offs for Reversible Computation* —
  already implemented in Bennett.jl as the pebbling / checkpoint strategies;
  they carry over directly as the VM's history-space management.
- **Janus** (Lutz & Derby 1986; Yokoyama & Glück 2007) — a reversible
  imperative language; its entry/exit-assertion loop form is the model for
  reversible dynamic control flow (Solution C, and the VM's loop semantics).
- **Reversible instruction-set architectures** — Pendulum / PISA (Vieri, MIT)
  and related reversible-processor work — prior art for a concrete reversible
  ISA.

This citation set is a *starting point*; a full literature review is part of
the §8 research phase.

## 8. Required next step

A **research + 3+1 design phase**, before any implementation — mirroring how
the heap-memory epic (`Bennett-gf3n`) began with a design brief and a consensus
design doc rather than code. Deliverables of that phase:

1. a problem/design brief and a validation spike (is the chosen machine model
   sound and tractable?);
2. a consensus design (2 independent architects + synthesis) fixing the
   machine model, the reversible instruction set, the history/checkpoint
   scheme, and the `target=:reversible_vm` dispatch surface;
3. a milestone roadmap (the implementation is then milestone-by-milestone,
   each independently testable, core changes via the 3+1 protocol).

Only after that design exists does implementation begin.

## 9. Provisional success criteria (refined by the design phase)

- A terminating `while` of statically-unknown trip count compiles under
  `target=:reversible_vm` with no `max_loop_iterations` supplied.
- A `Vector`/`Dict` of runtime-dependent size compiles under the VM target.
- **Round-trip reversibility:** the emitted reversible program, executed
  forward then backward, restores the input and zeroes all scratch — the
  reversible-VM analogue of the circuit target's ancilla-zero invariant.
- The circuit target (`target=:circuit`) is byte-unchanged — all existing
  tests and gate-count baselines hold.
- The non-termination wall (§6) is rejected fail-loud where detectable, never
  silently mishandled.

## 10. Related beads

- **`Bennett-spqu`** — this workstream (the reversible-VM backend).
- `Bennett-lqlc` — auto-infer loop bounds by classical evaluation: a
  *circuit-target* improvement that narrows the set of functions which need
  the VM target at all. Complementary.
- `Bennett-q2ny` — structurally-reversible loop recognition (Solution C).
- `Bennett-s0tn` — silent loop-truncation bug on the circuit target (P1).
- `Bennett-jefu` — document the fixed-circuit constraint in README + docs.
