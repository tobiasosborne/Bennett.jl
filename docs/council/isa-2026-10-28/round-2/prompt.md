# Council

You are a member of a three-model council grading the document below, the second normative draft (0.2) of the Bennett virtual ISA specification (the bennett-isa-spec contract named in the north-star document supplied as background). Grade it against the rubric on the absolute scale. Be exacting and skeptical: verify every technical premise against your own knowledge; name any that is false. Grade the vision for being the right vision, stated precisely; do not deduct for things that are not built yet. A blocking issue is one that would make the project build the wrong thing if uncorrected; everything else is a suggestion. Return `accept` only if the blocking list is empty.

Be constructive, not only critical: for every blocking issue the `fix` field must say concretely how to overcome it, at vision level (the sentence or semantics the document should state, or the decision it should take), not merely that it is wrong. Where you see two viable ways out, name both and say which you would take. In `path_to_accept`, state the minimal set of changes that would make you return `accept`; if you already accept, say what would raise the lowest-scoring criterion by one point.

You may read the repository you are running in (read-only) to check claims about the current code; its root contains Bennett-NorthStar.md (the document, identical to the snapshot below), Bennett-Reboot-Blueprint.md and Bennett-V2-PRD.md (the superseded plans), worklog/ (session logs; chunk 121 has the 2026-10-28 ground-truth survey), reviews/2026-09-26-astra/ (the last review campaign), and src/ (the deprecated v1). Reading is optional; the snapshot below is what you grade.

Answer only with JSON matching the schema.

# Previous round (1)

Verdicts: codex: revise, muse: revise, opus: revise

Blocking issues raised last round:
- [codex] B1 (§4.6 fault; §5.2 construction; §5.6): The caller's fault register is simultaneously an arbitrary XOR target and a zero-initialised first-fault accumulator. For fault code c, the prescribed zero-conditional update sends both initial fr=0 and fr=c to c, whereas the oracle contract requires fr=c to become 0. Moreover, exact reversal of the forward computation reverses the fault-register write; omitting that reversal contradicts prefix reversal. Fix proposed: Compute into a private, initially zero fault accumulator and private faulted flag, recording any irreversible updates in history. The forward computation must neither inspect nor modify caller tgt/fr. At one commit point, XOR the canonical payload and private fault code into those caller targets, then invert only the private computation. State this construction for success, explicit faults and budget exhaustion.
- [codex] B2 (§3.6; §5.2; §5.6): HALT has no transition into pc': after a halted step, fresh pc' remains zero and execution returns to the entry index. The exit also reads at_HALT after all at_k wires have been uncomputed, and history movement is specified for control instructions without consistently defining it for fallthrough instructions. Equal elapsed step counts alone do not establish the stated common halt configuration. Fix proposed: Define one transition from an immutable old-state snapshot: compute dispatch predicates, execute exactly the selected instruction, set next_pc including HALT→HALT, preserve old pc and overwritten state in one frame, then clean dispatch predicates from that frame. Recompute the exit predicate from final pc. Specify initial HALT, B=0, exact-boundary termination, fault padding and reversible normalisation of an exhausted pc. Require the same transition semantics for structured replacements.
- [codex] B3 (§3.2 budget counters; §4.2 alloc; §5.4; §14.1): Heap usage and call depth can differ between coherent branches, so their remaining counters cannot generally be classical. Step counting also lacks rules for nested calls, inlining and oracle invocations, and no frozen reference representation binds the ISA instruction count to the north star's materialised-region budget. Different lowerings can consequently change which inputs fault. Fix proposed: Keep budget limits and the padded outer iteration count classical; represent branch-dependent heap/depth usage reversibly in wires. Specify allocation charging, freeing, entry depth, call/return charging and fault precedence. Bind each oracle to an immutable reference instruction stream and accounting version before optimisation; require every lowering to preserve that bounded result. Define how nested work debits parent budgets independently of physical gate counts.
- [codex] B4 (§§3–4; §7.1; §14.1): The executable ISA is not closed: load/store, trap/unreachable and uncall are referenced without complete instruction definitions, while alloc/free and ret lack operational forms. Signed division overflow, memory byte order, allocation validity and pointer behaviour are unspecified. The relationship between classical iN operations and per-basis lifted execution is also unstated; f64 is forbidden outside CC but required as a Q rotation operand. Fix proposed: Provide a complete typed opcode table and memory model, including allocation metadata, access bounds, byte order, pointer width, return values and exceptional cases such as MIN_INT/-1. Explicitly choose whether lifted reference instructions form a separate typed sublanguage or are entirely wire operations with a specified reference mapping. Permit and define classical angle parameters in Q without implying that quantum-dependent values become classical.
- [codex] B5 (§3.1; §5.3; §5.5; §14.1 and T1): Unrestricted oracle→action calls admit non-permutation operations that the oracle reference interpreter explicitly rejects. Action calls can also form recursive cycles without a termination bound, defeating the assertion that each action denotes a unitary and potentially making an oracle step nonterminating. A nested fault being 'handled' merely because code 'tests' its register has no operational definition. Fix proposed: Allow an oracle to call an action only through a certified, phase-free permutation interface understood by its reference interpreter. Alternatively generalise the caller to an action and relinquish its F_B/involution contract; I recommend the former restriction. Require action call graphs to be acyclic or have a verified finite expansion bound. Give nested oracle calls an explicit propagate-versus-return fault policy and define propagation from a fresh local fault result.
- [codex] B6 (§4.4 qinplace): g and ginv are declared mutually inverse quantum actions, but the expansion invokes them as input-preserving out-of-place XOR evaluations. An in-place action implementing g does not acquire that interface merely because g is bijective; conversely, XOR evaluators for g and g⁻¹ are generally not mutually inverse actions. Fix proposed: Define g and ginv here as total classical bijections with certified, fault-free XOR evaluators O_g and O_ginv, then specify O_g(x,t); swap(x,t); O_ginv(x,t), with t initially zero and sufficient evaluation budgets. Alternatively make qinplace a direct call to an in-place permutation action with a certified adjoint, removing the compute–swap expansion. I recommend the XOR-evaluator form to retain the north star's construction.
- [codex] B7 (§3.3; §3.5; §§4.2–4.6; §5.3): The universal 'controlled-U' rule does not define allocation, borrowing or release, which change ownership and are not ordinary unitaries on a fixed wire set. Memory accesses omit the consumed/reproduced memory ownership required by the linear model. Reversing an action body also lacks inverse rules for qcopy, qload and allocation/release; the suggested loop continuation update conflicts with leaving predicate wires unmodified. Fix proposed: Specify unconditional bounded physical allocation with predicated logical use, identical ownership at coherent joins, and clean/restored release on every branch. Give memory a linear token or an explicit equivalent ownership rule. Define inverses for every action construct, including copy/load cleanup and allocation. Implement changing loop predicates through retained immutable predicate versions, rather than modifying an active control.
- [codex] B8 (§3.2; §4.2 qborrow/qfree; §5.3; §14): Basis-value restoration does not establish restoration of an unknown borrowed quantum state. For example, applying s to a borrowed wire preserves every basis value but changes |+⟩ and its correlations; the draft's bit-only model cannot express this failure. It likewise provides no abstract semantics for general actions or measurement. Fix proposed: Define the machine's joint quantum state and the relevant unitary, isometry and measurement-channel transitions. Require a completed region to act as its declared public operation tensor identity on borrowed systems, including arbitrary external references, with clean workspace factored out. Restrict basis-tuple reasoning to certified phase-free permutation implementations; use full quantum semantics elsewhere. Clarify that legitimate correlations among public inputs and outputs are not forbidden.
- [codex] B9 (§6; §11; §12; suite D): Dependency sets and provenance have no transfer rules across writes, exchanges, memory aliases or calls, so the purported scheduling invariant is not checkable from the object. The MUST-clean-before rule also conflicts with the later closed-window exception. Internal MBU is admitted without defining a controlled implementation or its environment/outcome semantics; correctness of an uncontrolled channel does not specify coherent control of that implementation. Fix proposed: Define versioned dependencies, their transfer rules and cleanup preconditions over immutable value versions, including aliases and history. State the MBU exception explicitly and specify its scheduled reference channel and exposed outcomes. Under coherent control, require comparison of the complete controlled implementation, including a reference system and measurement environment; otherwise mandate unitary cleanup, as the north star requires. The adopted const/qfree distinction should be expressed as actual rules, following [Silq's definitions](https://silq.ethz.ch/documentation).
- [codex] B10 (§4.3; §6; §8.3; §12; T6): 'Standard unitaries' leaves phase and angle conventions insufficiently explicit for structural control. The phrase 'non-diagonal rz usage' is technically false for the defined Z-axis rotation: RZ is diagonal, and replacing it by a phase gate changes controlled behaviour. Approximation tolerances are reported but not supplied as an acceptance constraint, and T6 does not distinguish each executor's error from their pairwise distance. Fix proposed: Define exact matrices, basis ordering and finite angle values, for example Rα(θ)=exp(-iθσα/2) with θ in radians; preserve phase under decomposition and control. Correct the RZ wording. Supply an allowed error budget as an object/launch/scheduling constraint; define phase-sensitive operator norm and diamond norm conventions, conversions and composition over actual call multiplicities. Two implementations with bounds ε1 and ε2 are guaranteed pairwise agreement within ε1+ε2. See the distinct [RZ and phase conventions](https://docs.quantum.ibm.com/api/qiskit/qiskit.circuit.library.RZGate).
- [codex] B11 (§3.4; §4.1; §7.3; §9.3; T4): R-tier exceptional execution is unspecified: division by zero defines Q and CC behaviour but omits R, despite the north star requiring recorded faults. Naming console, clock, entropy and block does not define their operation signatures, state transitions or replay inputs. T4 quantifies over every function and initial state without requiring a finite execution or specifying how Q calls and effects are reversed. Fix proposed: Define R fault records and terminal/suspended states, typed versioned device-model operations, and the environmental input trace consumed by nondeterministic effects. Specify forward, reverse and replay transitions, including inverse Q calls. State T4 for finite valid traces with retained history/tape and unchanged required dependencies; reversal restores model state, not already observed external-world events.
- [codex] B12 (§3.6 cost; §8; §11 space_budget): Resource names and units do not determine how to combine gate counts, peak qubits, depth and occupancy integrals. No timing/concurrency model fixes qubit-seconds, and instruction-body costs alone omit dispatch, history and cleanup work. Target legality also lacks class constraints and parameterised controlled-gate/decomposition costs. 'Cheapest' class and qubit-second-weighted peak space are consequently ambiguous. Fix proposed: Give each resource a measurement and aggregation rule, and define schedule timing or an explicit serial default. Report class occupancy as the integral of live qubits over time; express space limits separately as peak capacities. Include dispatch, predicates, history, reversal and fixups in accounting. Define gate/class compatibility and costs as functions of arity, controls, parameters and accuracy, plus objective validation and the rule for choosing any.
- [codex] B13 (§9.1–§9.2; §16): Interned IDs are normally local to an object, so resolving by ID and content hash does not establish a cross-object symbol namespace. Imports, relocations, interface compatibility, recursive definitions and canonical hash inputs are missing. The claimed canonical text has no grammar or normalisation rules, making content identity and independently produced links undefined. Fix proposed: Separate local symbol indices from stable external keys; define typed imports/exports, relocation, duplicate-definition handling and compatibility checks. Specify canonical text and hashing, including a module/SCC rule for recursive definitions and treatment of certificates. Define linking as resolution and validation followed by composition, rather than merely a union of function tables. Binary encoding may remain deferred.
- [codex] B14 (§9.3 reversible ABI): A callee's peak workspace count does not make a shared ancilla frame safe: caller values or history can remain live during a nested call. The ABI also lacks frame layouts, clean-versus-dirty requirements, class requirements and an exact call/uncall state correspondence. Fix proposed: Publish frame descriptors containing typed interface slots, scratch requirements by class and cleanliness, retained-history requirements and ownership transitions. Permit reuse only for disjoint live ranges or through an explicit restoration contract; never infer it from peak size alone. Define invocation identity, argument/result placement and the precise state/history consumed by uncall, including controlled and adjoint variants.
- [codex] B15 (§10; §15 suite G; §17.3): The claim that Q regions 'self-reverse' is false: an oracle cleans its workspace while retaining its XOR update, and an action may be non-involutory. Making reverse a no-op therefore does not undo a Q run. The API also uses an unreturned run_id, omits suspension/resumption, and leaves handle ownership and the purported C ABI unspecified. Fix proposed: Define a launch state machine and actual versioned C declarations, returning invocation IDs and specifying handle validity, aliasing, completion, suspension, resumption and errors. For Q, reverse must invoke the oracle again or the action adjoint with retained parameters and valid live wires; alternatively reject Q reversal and provide an explicit adjoint launch operation. I recommend supporting the inverse operation. Require launch implementations to pass suite G.
- [codex] B16 (§11; §17.3): Compile-time and run-time scheduling do not actually share a specified interface: the latter has an extra budget absent from the signature. There is no schedule interchange format, applicability condition, infeasibility result or rule for validating a stored schedule against changed launch parameters. Deferred C signatures directly prevent the binary substitutability promised by the north star. Fix proposed: Define one versioned C ABI whose request includes the program/reference identity, target identity, classical parameters, budget, accuracy, objective and capacity constraints. Specify serialisable schedule operations, validity domains, required certificates and explicit unsupported/infeasible outcomes. A consumer must validate those bindings and either apply the schedule or request a replacement without changing program semantics.
- [codex] B17 (§12; §13; §15): The certificate and coverage sections are schema sketches, not exchange contracts. Free-text domains and assumptions, seeds without generators/counts, and untyped proof references are insufficient for independent replay or checking. Re-execution alone does not define structural-proof checking or rigorous numerical proof, while linked-object epsilon summation ignores invocation multiplicity. Coverage lacks stable entry identity and shim provenance. Fix proposed: Specify machine-readable schemas bound to object, reference, target and schedule hashes. Encode finite domains, sampling algorithms/versions/counts, proof kinds and checkers, numerical error bounds, verification scope and compositional assumptions. Compose errors over execution bounds, not merely linked symbols. Give coverage entries stable reference locations, classification, reason, fault behaviour and shim identity. Derive conformance fixtures for these schemas and the corrected theorem hypotheses.
- [muse] B1 (3.2, 3.3, 3.6, 4.1): There is no representation for the values a lifted program computes. Classical registers in Q are constants fixed at entry (3.2), ptr is a classical address (3.3), and binop operates on iN (4.1), so none of these can hold superposed data or a superposed pointer. Worse, wires are linear SSA values consumed and produced exactly once (3.3), yet the step machine executes every instruction B times (3.6): an SSA value would be re-produced and re-consumed every machine step. Block parameters (3.4, 16) have no coherent merging rule in Q. Two implementers cannot draw the same state or execute the same body. Fix proposed: State the rule: an oracle body in the ISA is not SSA over wires but a program over a declared register file and quantum memory, where each lifted classical value of width N occupies a named wire[N] location, each instruction lists locations read and locations reversibly updated (by qexch or XOR into clean space with the old value retained as history), block entry coherently multiplexes block parameters from predecessor locations under at_k, and linearity applies to region-boundary wires and action bodies but locations inside an oracle are mutable state re-executed each step. The alternative (keep pure SSA and restrict oracles to structured qif/qloop bodies, abandoning the general step machine) is viable but contradicts the north star's arbitrary-CFG claim; take the register-file rule.
- [muse] B2 (3.6): The step machine has no transition for HALT. Step 2 XORs a next index into a fresh pc' only for k < n, so a halted branch leaves pc' = 0 and restarts the program, re-executing side effects for the remaining steps. Separately, every at_k is uncomputed in step 3, so the at_HALT used at exit (3.6, 5.2) no longer exists; pc := pc' is an assignment, not a defined reversible operation; and the number and allocation of history frames over B steps is never stated. Fix proposed: Add the transition: under at_HALT, XOR HALT into pc' (halted branches self-loop and perform no state change), allocate one history frame of P clean wires per machine step (B frames total, charged to workspace), define pc := pc' as exchange of the pc bundle with the fresh pc' bundle, and state that at exit at_HALT and the faulted flag are recomputed from pc and the internal fault register (B3) after the B-th step before commit.
- [muse] B3 (4.6, 5.2, 5.6): The fault construction is self-defeating in two ways. First, fault XORs the code into the fault register if it is currently 0 (4.6), but fr may hold any value on entry and domain D ranges over all fr values (5.2): with a nonzero initial fr no fault is ever recorded. Second, 5.2 says the fault instruction has already XORed the code during forward execution and then the whole execution is reversed (5.6), which reverses that XOR and erases the fault. As written, faulted branches return fr unchanged or unchanged-for-nonzero-fr, contradicting the interface. Fix proposed: Restate the construction: forward execution writes only to an internal clean fault-code register and faulted flag allocated by the region, first fault wins tested against the internal flag; at commit, under at_HALT and not faulted XOR the result into tgt, under faulted XOR the internal code into fr, under neither XOR FAULT_BUDGET_STEPS into fr; reversal then reverses only the forward computation over internal state and never touches tgt or fr. Assign the numeric fault code values now (FAULT_NONE=0, then 1..8 in the order listed in 5.4); the values are quantum data XORed into fr and are semantic, so deferring them (1.3) makes executors disagree on final states.
- [muse] B4 (5.4, 14.1): The budget contradicts the north star and is partly unphysical. North star 4.2 fixes the budget unit as steps of the reference semantics on the materialised region so the fault set never depends on Bennett's lowering; 5.4 and 14.1 instead count instructions of the lowered ISA body, so the producer's inlining and layout choices change which inputs fault. Heap and depth counters are classical (3.2), but allocation size and call depth in lifted code depend on superposed data, so they cannot be classical values; and whether a call counts as one step or as its callee's steps is undefined, so F_B itself is ambiguous at every call boundary. Fix proposed: Two viable fixes: (a) keep the north-star promise by giving every ISA instruction in an oracle a producer-assigned reference-step weight recorded in the object, define the budget over weights (internal padding steps have weight 0, callee instructions count individually, oracle_call counts its callee's weights), and make heap and depth coherent wire counters in the register file (B1) whose comparisons raise faults, with a stated priority when two budgets trip on one instruction (e.g. depth, then heap, in program order); or (b) redefine the budget over ISA steps and amend the north star and certificate to say the fault set depends on Bennett's lowering. Take (a); (b) surrenders a load-bearing north-star guarantee.
- [muse] B5 (5.1, 5.2, 5.5): Nothing prevents non-permutation gates inside a lifted oracle. Section 5.1 forbids measure, effect and br but not h or rz, and 5.5 lets an oracle call any action. An oracle containing h is not a function F_B on basis inputs, is not an involution, is illegal in the reference interpreter's own oracle mode (14.1), and voids theorems T1 and T3. The central interface of the spec is not enforced by its well-formedness rules. Fix proposed: Add the well-formedness rule: an oracle body may contain only permutation gates, qcopy/qxor/qexch, quantum-memory operations, control, fault, oracle_call, and action_call to actions certified as exact permutations on their encoding; any other gate makes the function a quantum action, not an oracle. Suite F rejects the rest.
- [muse] B6 (4.3, 8.3): Gate semantics are given as 'the standard unitaries' (4.3) with no matrices. Rz has two conventions in wide use differing by a global phase, and since every gate executes controlled on the active predicate (3.5), a global phase becomes a relative, observable phase: two executors choosing different conventions produce different states. The same hole exists for decompositions (8.3): nothing requires a target decomposition of ccx or mcx to be phase-exact, so a relative-phase Toffoli, which the north star 5.1 explicitly excludes from the permutation tier, is a conformant lowering here and silently breaks interference. Fix proposed: Print the matrix of every gate in the computational basis, including rx/ry/rz as exp(-i theta P/2) or another single stated convention, and mcx as the exact multiply-controlled X. Add the legality rule: a decomposition is conformant only if the realised unitary equals the specified unitary exactly, not up to global phase, or equals it within a stated epsilon in a phase-sensitive norm that is preserved under adding controls; relative-phase constructions are legal only where a certificate proves the phase cancels in context.
- [muse] B7 (4.4): qinplace mixes the two region interfaces the spec exists to separate. It requires g and ginv to be quantum actions, whose interface transforms mut wires in place (5.3), but its semantics call them out of place as g x -> t, which no action does. If g were an in-place bijection action one would simply apply it to x and the whole construction is pointless; the compute-exchange-uncompute sequence only makes sense for oracle-style compute functions t ^= g(x). The exhaustive-check bound 'n <= 16' is also an unmotivated constant appearing nowhere else. Fix proposed: Pick the oracle-style reading, which is the one the construction and the north star need: g and ginv are compute functions with target-XOR semantics t ^= g(x) and t ^= ginv(x), total mutually inverse bijections on the declared encoding, and qinplace is compute g into clean t, exchange x and t, compute ginv from the new x into t clearing it, free t; state that the certificate obligation is g after ginv = ginv after g = id over the declared domain, checked exhaustively where the declared width makes that finite and otherwise carried as a library certificate, with no privileged width threshold. The alternative (g as an in-place action applied directly to x) makes qinplace a no-op wrapper and loses the founding use case of lifting a classical bijection.
- [muse] B8 (5.3, 4.7): A quantum action's unitary is never defined on a stated space, and its two derived forms are asserted, falsely, to be automatic. Inputs 'preserved' while usable as controls (5.3) is ambiguous: used as a control against a mut wire in a phase eigenstate, an input acquires phase kickback and entangles with mut, so preserved can only mean basis-value preservation of a joint unitary, which is not said. The adjoint recipe 'body reversed, gates adjointed' is wrong for qalloc/qfree (adjoints of each other), qload (produces wires; its inverse consumes them), qinplace, and any SSA renaming, so 'well-formed by construction' is false. ctl as textual qpred around the body also leaves allocation, oracle commit (B3) and global phase (B6) undefined under control. Fix proposed: Define an action's semantics as a unitary on mut tensor ins that is block-diagonal in the ins computational basis (basis values of ins unchanged; phases and entanglement with mut are part of U and must be declared intended), with all workspace returned clean and unentangled. Define adj by a per-instruction adjoint table (gate to adjoint gate with negated angles, qalloc swapped with qfree, qborrow likewise, qload paired with its consuming inverse, qinplace with g and ginv exchanged, qif/qloop bodies adjointed, sequence reversed with SSA names renamed accordingly) and define ctl at the region level as controlled-U over that unitary with workspace allocated clean independently of the control, leaving the internal realisation (including compute, controlled commit, uncompute for nested oracles) to the executor.
- [muse] B9 (3.5, 5.1, 6, 11): Predication and uncomputation are each described twice, inconsistently. Every instruction executes controlled on the active predicate (3.5), but qalloc, qborrow, qfree and the wire-producing instructions have no unitary 'controlled' meaning. Section 5.1 requires producers to emit regions that free everything clean, yet section 11 makes placement of uncomputation a scheduler output, and no instruction in section 4 expresses uncomputing a qcopy result in program text; so whether cleanup is in the program or inserted by the scheduler, and hence what two executors run, is undecided. Section 6 gives no compositional rules for dependency sets, states validity as dynamic basis-value equality rather than a checkable static discipline, misclassifies rz (a diagonal gate) as 'non-diagonal rz usage' while omitting s, t and cz, and admits measurement-based uncomputation wherever the window closed with correction U D U-dagger, which for arbitrary intervening U is generally not an implementable gate. Fix proposed: Decide and state: allocation and release are unconditional resource operations (the wires exist for the region's static maximum regardless of predicate values; only gates are controlled), cleanup is explicit in the program text (every workspace value is cleaned by named inverse instructions before its qfree), and the schedule's freedom is only to choose the realisation of each cleanup (reverse, recompute, or MBU where the target declares mbu and, per the north star, never under a control until the controlled MBU certificate kind exists). Give per-instruction rules computing dependency sets and provenance, define validity in Silq's terms (the value is a classical function of wires that have only had qfree operations applied since computation), and restrict MBU to schedules where the correction is in the target alphabet and channel-verified; otherwise the schedule is invalid, not merely unverified.
- [muse] B10 (5.5, 5.4): FAULT_CALLEE is magic. Section 5.5 says a nested fault propagates 'unless the lifted code tests the nested fault register', but lifted code cannot test a wire classically, 'handles it' has no syntactic or semantic definition, the nested call's fault register (who supplies it, what it starts as, how its code is mapped to FAULT_CALLEE versus passed through, and what happens when the outer region faults later) is unspecified, and first-fault-wins across nesting levels is therefore indeterminate. Two executors will report different codes for the same nested fault. Fix proposed: Remove the automatic propagation and state: a nested oracle_call is given a fresh clean internal fault register by the caller; fault propagation is ordinary lifted code (compute fr != 0 as a qfree wire, conditionally XOR FAULT_CALLEE into the caller's internal fault register under the first-fault rule of B3, then clear the nested register by calling the nested oracle a second time or retain it as declared output data). The alternative, automatic propagation, is viable only if 'handled' is defined syntactically (the nested register is listed among the caller region's declared outputs); the explicit form is preferred because it keeps F_B a function of the program text.
- [muse] B11 (4.5, 7.1, 7.2): Memory is not specified to implementable level. Classical load and store have no instruction forms at all in section 4 (widths, endianness and alignment unstated, though 7.1 and the executor suites presuppose them). A qregion is 'all clean at creation' (4.5) with no way to initialise it from classical data, yet lifted memory and the north star's classically fixed database require exactly that. And qaddr[A] into a region of 'cells' cells has no relation stated between A and cells and no out-of-range behaviour, while FAULT_UB_MEMFAULT (5.4) presupposes one. Fix proposed: Add: load/store instruction forms with width, signedness for loads, and little-endian byte order in classical memory; a data-initialisation rule for quantum regions (an object-level image mapping declared classical bytes into cells at region creation, bit order little-endian per cell), with the default image all zeros; and an out-of-range rule, either requiring cells = 2^A by well-formedness or defining out-of-range qload to produce 0 and, inside an oracle body, raise FAULT_UB_MEMFAULT through the internal fault register (B3). Prefer requiring producer-emitted range checks against declared allocations for lifted code, with the raw instructions total, and saying so.
- [muse] B12 (3.4, 7.3, 14.3): The reversible tier is asserted invertible without the rules that would make it so. 'Every instruction MUST be invertible given the history' (3.4) does not say what any instruction records: a mul or a store destroys information unless the history rule per instruction is stated, and only stores get one (7.1). The four device models (7.3) are names without operations, state, or inverse deltas; entropy (read) has no stated source, so two executors produce different forward runs and theorem T4 (14.3) is not statable, and clock under reversal is undefined. Fix proposed: Add a history rule table: for each R instruction, exactly what a history frame records (e.g. for store, address and overwritten bytes; for a lossy binop, the destroyed operands; for br, the taken edge). Define each device model's operations, argument and result types, state, and inverse delta. Make clock a device-state counter advanced only by tape records and entropy an input tape supplied at launch and consumed in order, so a run is a function of (program, initial state, entropy tape) and T4 can be stated; a launch that exhausts the entropy tape is a defined R-tier trap recorded on the tape.
- [muse] B13 (8, 11, 3.3): The resource model cannot be accounted twice with the same answer. Qubit_second occupancy (8.1, 4.2) needs elapsed time, but no timing or parallelism model is defined: gate 'time' appears in 8.3 without being a declared resource, and 3.6 sums step costs sequentially while a specialiser may parallelise. ptr width is 'from the target description' (3.3) but section 8 has no such field. Qubit classes have no compatibility or movement rules for two-wire gates across classes, 'cheapest' for any (8.2) has no order, borrowed-wire occupancy double-counts against the owner, mcx and rz costs cannot be static scalars (they depend on k and on synthesis epsilon), the scheduler's space_budget is expressed in 'qubit_second-weighted peak occupancy' (11) which is dimensionally a rate, not a space bound, and the Qualtran/Azure import rule (8.5) restates the north star's aspiration with no conversion table a vendor could apply. Fix proposed: State a timing model: execution is sequential in program order unless the schedule (11) assigns start times; each native gate has a duration from the target (a declared 'time' resource, not an ad hoc field); qubit_second charged per wire is the integral of its live interval in scheduled time at its class rate, borrowed wires charged once to the borrower at dirty_rate replacing, not adding to, the owner's charge. Declare the ISA-level machine all-to-all over logical wires, with routing folded into decomposition costs, or add a topology and a move instruction; prefer all-to-all logical, matching the north star's regime. Make gate costs functions: mcx of k, rz of (theta precision, epsilon) with the synthesis rule named. Redefine space_budget as a per-class peak-wire vector, separate from the objective. Replace 8.5 with a normative import table (named source units to named resources with conversion factors); any unit not in the table imports as a new resource, full stop.
- [muse] B14 (9.1, 9.2, 16): Structural linking as stated is incoherent, and the one interchange format is unwritten. Symbols resolve 'by interned ID and content hash' (9.2), but interned IDs are assigned per object, so equal IDs in two objects are unrelated and different IDs say nothing; resolution by ID across objects cannot work, which is the opposite of how content addressing must be set up. The hash function, what bytes are hashed, undefined symbols, and section conflicts on union are all unstated, and 'certificate composition' is a phrase, not a rule. Meanwhile the canonical textual form (16) that must carry interchange and conformance while binary encodings are deferred has no grammar: section 4's tables use wire[*], 'args', ellipses and prose where a grammar is needed. Fix proposed: Make the content hash the sole global identity: name the hash function and define it over the canonical bytes of the symbol's interface and body (for data, over the image of B11), treat interned IDs as per-object aliases rewritten at link, and state the link rules for undefined symbols (link error unless declared external with a matching interface hash), duplicate definitions with equal hash (deduplicated), and type/device/layout section conflicts (link error). Either write the EBNF for the canonical text in this draft or explicitly demote the text to non-normative examples and declare that no interchange format exists yet; the former is strongly preferred since binary encoding is deferred.
- [muse] B15 (10, 11, 12, 13): The remaining cross-repository contracts are sketches with concrete holes. bennett_run returns only status (10), so the run_id that bennett_reverse requires can never be obtained; there is no operation to load classical basis values into allocated handles or to free them; the suspension the north star 4.4 assigns to the launch ABI is absent; free-text 'exact C signatures deferred' (17) defers the contract itself. The scheduling interface (11) returns a 'schedule' with no serialised form, no infeasible-result, and no rule that a VM honour a compile-time schedule, and the object format (9.1) has no section to carry one, so the north star's substitutability guarantee is unimplemented by construction. Certificate domains are '<description of D>' free text (12), so the checker's defining duty, re-execution without trusting the producer, has nothing mechanical to re-execute; the coverage report (13) counts 'source constructs' the ISA spec nowhere enumerates. Fix proposed: Repair the launch contract minimally: bennett_run returns a run_id (status via a separate query), add bennett_prepare(handle, classical bits) setting clean wires to a basis value and bennett_free(handle), define status/error values, and define suspension as existing only between bennett_run calls at region boundaries (or add explicit suspend/resume for the R tier keyed by run_id; prefer the boundary rule for Q and explicit suspend for R, and say which). Define the schedule as a serialised object section listing per-cleanup realisations (B9), class assignments and decomposition choices, with an infeasible error return, and require a VM to execute a supplied schedule verbatim when the target hash matches. Make certificate domains machine-readable (symbol, input widths, enumerated ranges or seed-and-count sampling, widths exhaustive to N) so re-execution is defined, and either enumerate the coverage constructs by reference to a versioned dialect list or move the coverage format's enumeration to the dialect spec and keep only the container here.
- [muse] B16 (14, 4.6): The formal model omits the quantum half of the machine and misstates its flagship theorem. There is no state space, tensor-product ordering, channel semantics, or measurement rule anywhere (measure 'collapses', 4.6, with no Born probabilities), so actions and suite D have nothing to be checked against except the per-basis bit interpreter of 14.1, which by construction cannot see phases. T3's hypothesis requires the realisation to 'use only permutation gates after decomposition', which excludes the standard exact Clifford+T realisation of a Toffoli and contradicts both 8.3 and the north star's definition of the tier by the realised permutation; T2 is circular (hypothesis: implementing 3.6 and 5.6), and T6 claims agreement 'up to the certificate's epsilon' for actions with no fixed metric, target or decomposition hypotheses. Fix proposed: Add a quantum state semantics for actions and measurement: state space as the tensor product over live wires in bundle order, gates by the matrices of B6, measure as computational-basis measurement with Born probabilities consuming the handle's wires and yielding the little-endian integer. Restate T3 with the hypothesis 'the realised unitary on span(D) is a permutation matrix' (however decomposed), T5 with the static-validity hypotheses of B9, and T6 with fixed hypotheses: same target, same decompositions, exact equality for oracles on D, and for actions equality up to the summed epsilon measured in diamond norm for channels and phase-sensitive operator norm for unitaries, with the summation rule stated for sequential and nested composition.
- [opus] B1 (§3.6, §4.1, §14.1, §3.3): The step machine has no data model. Lifted classical code on superposed data has no ISA instructions: binops act on classical entry constants, so lifted code must be expanded into gates. That makes the budget unit, and therefore the fault set, depend on Bennett's lowering, which contradicts north star §4.2. The step machine also re-executes a fixed static instruction list B times, while §3.3 requires every wire to be produced exactly once. Nothing says how a re-executed instruction's writes are kept reversible; only `pc` gets a history frame. And with no write to pc' at HALT, a halted branch restarts at index 0. Fix proposed: State: (a) Step-machine bodies use a register file of named wire bundles, not linear SSA. Linearity (§3.3) applies to structured code and region interfaces only. (b) Add `lift.*` instructions on wire[N] (binop, icmp, select, cast, load, store, alloc, call). Each computes its result out of place into fresh per-step scratch, `qexch`es it into the destination register, and leaves the displaced old value in that step's history frame. (c) Each lifted instruction is exactly one budget step, and the dialect's reference semantics maps each materialised LLVM instruction to exactly one lifted instruction, so the fault set depends only on program, budget, LLVM version and pipeline. Executors may expand instructions internally but must reproduce this step count. (d) Add to §3.6: 'under at_HALT, XOR HALT into pc''. The alternative is to let producers pre-expand into gates and carry a per-instruction step annotation from the dialect. I would take (b), because it keeps the step unit in the spec rather than in producer metadata.
- [opus] B2 (§3.2, §4.2 alloc, §4.1 call, §5.4): In Q, 'budget counters: classical: steps, heap, depth remaining'. Heap bytes allocated and call depth differ per basis branch, so a classical counter would have to inspect superposed data, which violates §3.1's own invariant. It is also unstated what a lifted `alloc` returns, or where the frame-stack pointer lives, when either depends on superposed data. Fix proposed: State: the step counter is classical, because every branch runs exactly B machine steps. Heap-used and depth are wire bundles in step-machine workspace, updated by lifted alloc, call and ret, compared against the classical limits from the budget token, raise FAULT_BUDGET_HEAP or FAULT_BUDGET_DEPTH when exceeded, and are reversed with the history. A lifted alloc returns a wire[ptr] produced by a per-branch bump allocator over a declared heap qregion of size heap_limit.
- [opus] B3 (§4.6 fault, §5.2, §5.4, §5.5, §17.1): `fault` XORs into the caller's fr 'if the register is currently 0'. That is not injective (fr=0 and fr=code both map to code), it controls on the register it modifies, and it breaks fr⊕code(F_B(x)) whenever fr enters nonzero. The numeric code values are deferred, yet they change the final quantum state, so deferring them is not non-semantic. The rules for FAULT_CALLEE propagation and for how much budget a nested oracle consumes are vague. LLVM's other immediate-UB division case, sdiv/srem INT_MIN/−1, is missing. Fix proposed: State: every lifted oracle has internal clean workspace `faulted:wire` and `code:wire[F]`. The `fault c` instruction XORs c into `code` and flips `faulted` under the active predicate, then jumps to HALT; because pc=HALT predicates everything off afterwards, first-fault-wins needs no zero test. At commit: under at_HALT∧¬faulted XOR result into tgt; XOR `code` into fr; under ¬at_HALT XOR FAULT_BUDGET_STEPS into fr. Then reverse, which cleans `code` and `faulted`. Assign numeric values now (for example NONE=0, BUDGET_STEPS=1 … CALLEE=8, plus UB_SDIV_OVERFLOW=9, or alternatively define that sdiv/srem INT_MIN/−1 returns INT_MIN and 0), F≥4. Define a nested oracle_call as one outer step that consumes its own token, issued from a classical budget fixed at the outer region's entry. Its nonzero fault register, if the lifted code does not test it before the outer region halts, raises FAULT_CALLEE in the outer region.
- [opus] B4 (§4.4 qinplace, §5.3, §5.5, §14.1): `qinplace` requires @g and @ginv to be quantum actions, but calls them out of place into a target t, which is the oracle interface. §5.5 lets an oracle call any action, so an oracle could apply a rotation and stop being a permutation; F_B and the involution would then be undefined, and so would reference-interpreter oracle mode. Fix proposed: State: @g and @ginv in `qinplace` are total permutation oracles. They are permutation-only, and carry a certificate (exhaustive at n≤16 or from a library) that their fault output is FAULT_NONE on the whole n-bit encoding under their declared budgets. They are invoked with an internal clean fault register that the certificate guarantees stays 0. An oracle may call only actions whose bodies are permutation-only; an oracle body that reaches a non-permutation operation is ill-formed (suite F), and the region must instead be declared an action.
- [opus] B5 (§4.6 qloop/qif, §5.3, §5.6): For actions, data-dependent loop exit is 'predicating the body on a continue wire the body maintains'. Overwriting a single flag (c ← c∧cond) is irreversible, and an action has no step-machine history that could undo it without also undoing its rotations. No Quantum Control Machine injectivity or synchronisation condition is given for actions. The §5.6 wording ('all basis branches reach the same halt configuration') is also false as written for oracles, where branches differ in pc and data until the reversal. Fix proposed: State: in an action, `qloop bound {body} while cond` allocates fresh flags c_1..c_bound with c_{i+1} = c_i ∧ cond_i computed out of place. Each cond_i must be a perm-provenance function of wires that no iteration modifies (or that are restored before cleanup), and the flags are uncomputed in reverse order after the loop under §6. Any other data-dependent exit in an action is ill-formed. For oracles, restate exit synchronisation as: every branch has run exactly B machine steps at commit, and the prefix reversal returns all control workspace to clean. The alternative is to forbid data-dependent exit in actions outright and route it through oracles. I prefer the rule above, because it keeps `when` over loops expressible.
- [opus] B6 (§6): The validity rules classify operations by permutation versus non-permutation, but the physical criterion is basis-diagonal. 'Non-diagonal rz' cannot occur. Diagonal gates on dependency wires (s, t, cz, rz) are safe, yet the rules treat them as closing the window. The rules never restrict operations on the garbage wires themselves, so an `h` on garbage before its uncomputation is allowed, and it leaves entangled residue while the spec claims that bug class is unrepresentable. The under-control fallback for measurement-based uncomputation, a north-star contract, is missing. Fix proposed: State: for a perm-provenance value g with dependency set S, between g's computation and its uncomputation (a) every operation touching S either uses S only as controls, or is diagonal in the computational basis on S, or is a permutation of S that is exactly undone before the uncomputation; (b) g's own wires are used only as controls or by diagonal gates; (c) any other operation on S or on g closes the window. Measurement-based uncomputation with fixup is permitted only when the predicate stack is empty and the target sets `mbu: true`; under any active predicate, unitary uncomputation is mandatory until a controlled measurement-based-uncomputation certificate kind is specified. Rename the provenance label `perm` to avoid the clash with the `qfree` instruction.
- [opus] B7 (§10): The launch ABI lets the host hold handles, call `bennett_measure`, and orchestrate region calls. North star §3.1 forbids handle use and measurement-driven control in host native code, and §3.1 of this spec says CC runs on the device. `suspend` (required by north star §4.4) is absent. `bennett_reverse` is a 'no-op' for Q, but running an oracle XORs into tgt and running an action applies U to its mutable wires, so neither has been undone. Fix proposed: State: the launch entry point is a device CC function. The host supplies classical arguments, budgets and opaque register IDs for device-resident quantum state persisting between launches, and receives classical results, fault codes and final read-back measurements. Every measurement whose result affects control runs in device CC. Add `bennett_suspend` and `bennett_resume`, valid only at CC instruction boundaries and never inside a Q region. Define reverse as: R → uncall to entry; action run → U†; oracle run → re-apply (involution). The alternative is to declare Q runs non-reversible through the ABI and say so.
- [opus] B8 (§9.2, §9.3): Hash-only symbol resolution makes separate compilation against an unbuilt or upgraded library impossible, and the scope of 'interned IDs' is undefined. Call/uncall 'matches frames by the history' without saying who owns the history. Wire-argument ordering, the ownership of workspace and borrowed wires across a call, and the shared-ancilla-frame protocol are all left to convention, though two repositories must agree on them. Fix proposed: State: an import is (name, interface signature: tier, kind, wire-bundle widths in order, F, classical arg types, ABI version), with an optional pinned hash. The linker resolves by name+signature, errors on mismatch, and records the resolved hash in the linked certificate. The caller passes interface bundles in declared order and owns them. The callee owns its workspace, unless the caller passes a shared frame of at least the callee's certified peak_workspace clean wires, which the callee must return clean. A callee may qborrow only from a caller-designated idle set, which it must restore. For R uncall, the callee's history frame is pushed onto the caller's history stack at call and popped by uncall.
- [opus] B9 (§8.1–§8.4, §11): `qubit_second` is the mandatory base resource, but there is no timing or parallelism model, so two conformant schedulers or estimators compute different values for the same schedule. Rotation costs cannot be expressed as functions of ε, and the objective of 'peak occupancy weighted by qubit_second' is dimensionally ill-defined. Fix proposed: State: a gate occupies its wires for its declared `time`. Gates on disjoint wires may overlap unless the target declares `max_parallel` or a connectivity or routing constraint. A wire's lifetime runs from qalloc or qborrow to qfree, and qubit_second = Σ lifetime × class rate (dirty_rate for borrowed wires). A gate cost may be a declared function of ε, and the certificate records the per-region ε split. The space budget is peak live qubits per class, a separate bound from qubit_second.

## Editor's response (what changed, what was declined and why)

# Editor's response to ISA round 1

Verdicts: codex, muse, opus all **revise**. Mean 2.12; C3 (coherent
semantics) 1.33. Seventeen + sixteen + nine blocking issues, strongly
overlapping. The diagnosis is accepted in full: draft 0.1 described the
step machine over linear SSA, which cannot hold lifted values; its fault
register design was not injective; oracle bodies were not restricted to
permutation gates; gates had no matrices; superposed quantities were put
in classical counters; adjoint and control of actions were asserted, not
defined; and the cross-repository contracts were sketches. Draft 0.2 is
a rewrite. Status reported to the maintainer: **no-go**.

## What draft 0.2 does, by theme

1. **Register-file sublanguage** (muse B1, opus B1, codex B4). Oracle
   bodies are programs over a declared register file of named `reg[N]`
   locations plus quantum memory, not SSA. New `lift.*` instructions
   (const, binop, div, icmp, select, cast, mov, load, store, alloc, free,
   faultif, call, ret, retval, oracle_call, perm_call) each write exactly
   one location by out-of-place compute then `qexch`, with the displaced
   value retained in the step's history frame. Block parameters lower to
   `lift.mov` on split edges. Linearity applies to structured code and
   interfaces only. Each lifted instruction is one budget step and the
   dialect mapping is one-to-one and versioned, so the fault set never
   depends on executor lowering (§4.2 "reference binding").
2. **Step machine** (codex B2, muse B2, opus B1). One transition from an
   immutable snapshot: dispatch, execute exactly the selected instruction,
   next-pc including **HALT self-loop**, commit pc by two exchanges, clean
   dispatch from the frame's old pc. One frame per step with a fixed
   layout `(old_pc, displaced, flag)`. Exit recomputes `at_HALT` from the
   final pc. B = 0 defined.
3. **Fault construction** (codex B1, muse B3, opus B3). Internal clean
   `faulted` and `code`; `fault c` XORs c into `code`, flips `faulted`,
   jumps to HALT (the self-loop makes first-fault-wins automatic and the
   operation injective); commit XORs into the caller's `tgt`/`fr` once,
   outside the reversed prefix. Numeric fault codes are now normative,
   with `FAULT_UB_SDIV_OVERFLOW` added.
4. **Budgets** (codex B3, muse B4, opus B2). Steps classical (every branch
   runs exactly B); `heap_used` and `depth` are wire counters updated by
   `lift.alloc`/`lift.call`/`lift.ret`; fault precedence stated; nested
   `lift.oracle_call` is one outer step under its own token.
5. **Permutation-only oracles** (muse B5, opus B4, codex B5). Well-
   formedness rule; oracles may call only *permutation actions*; action
   call graphs acyclic; recursion only via `lift.call` under the depth
   budget.
6. **`qinplace`** (codex B6, muse B7, opus B4). `@g`, `@ginv` are total
   permutation oracles (XOR evaluators) with certificates that the fault
   code is `FAULT_NONE` on the encoding and `g∘ginv = id`; the construction
   is spelled out with a clean fault bundle; the `n ≤ 16` constant is gone.
7. **Gate matrices and decomposition legality** (muse B6, codex B10).
   Every matrix printed; `rα(θ) = exp(−iθσ_α/2)`; decompositions must be
   exact including global phase, or within ε in operator norm; relative-
   phase Toffolis excluded unless a certificate proves cancellation.
8. **Action semantics, adjoint, control** (muse B8, codex B7/B8, opus B5).
   U block-diagonal in the `ins` basis, identity on borrowed systems,
   workspace clean; a full per-instruction **adjoint table** (qalloc↔qfree,
   qcopy↔quncopy, qload↔qunload, qinplace g↔ginv, loops); `ctl` at region
   level with unconditional allocation; `qloop … while` via a chain of
   fresh out-of-place flags over permutation-provenance conditions.
9. **Predication and allocation** (muse B9, codex B7). Allocation and
   release are unconditional resource operations; cleanup is explicit
   program text (`quncopy`, `qunload`, adjoints); the schedule chooses
   only realisations.
10. **Borrowed systems** (codex B8). Identity ⊗ on borrowed and external
    reference systems required; discipline: permutation gates only, basis
    restoration over the extended domain, no non-permutation controls.
11. **Uncomputation validity** (opus B6, codex B9, muse B9). Rewritten
    with basis-diagonal criteria, per-instruction provenance transfer
    rules, a window definition, obligations, MBU only with empty
    predicate stack and `mbu: true`, unitary cleanup mandatory under
    control. The "non-diagonal rz" error is gone.
12. **Memory** (muse B11, codex B4). `load`/`store` forms with width and
    sign; little-endian; regions of exactly 2^A cells with data images;
    producer-emitted range checks raising `FAULT_UB_MEMFAULT`; lifted
    alloc as a per-branch bump over a `heap` region; `ptr_width` in the
    target description.
13. **R tier** (muse B12, codex B11). History rule table per instruction;
    device models with state, operations and inverse deltas; clock as a
    tape-advanced counter; entropy as an input tape; R fault records as
    terminal states; T4 over finite traces.
14. **Resources** (muse B13, codex B12, opus B9). Resource kinds (count,
    time, occupancy, peak) with aggregation rules; a timing model; all-to-
    all logical connectivity; borrowed occupancy replaces the owner's
    charge; class capacity and cross-class costs; `mcx`/rotation costs as
    functions; space budget as peak capacity.
15. **Objects and linking** (muse B14, codex B13, opus B8). SHA-256 content
    hash over canonical bytes as sole identity, SCCs hashed as units,
    local indices as aliases; imports by name + signature with optional
    pin; link rules for duplicates, mismatches and section conflicts; an
    **EBNF** for the canonical text with byte-level normalisation rules.
16. **Reversible ABI** (codex B14, opus B8). Frame descriptors; shared
    frames only with disjoint live ranges; call/uncall history-stack
    correspondence; borrowed-from-idle-set rule.
17. **Launch ABI** (opus B7, codex B15, muse B15). Device CC entry point;
    host holds opaque register ids; C declarations with `run_id`, `wait`,
    `prepare`, `free`, `suspend`/`resume` at CC boundaries, `reverse` per
    tier (oracle re-apply, action adjoint, R uncall), enumerated errors.
18. **Scheduling interface** (codex B16, muse B15). One C ABI with a full
    request; serialised schedule as an object section; INFEASIBLE and
    UNSUPPORTED results; verbatim execution of validated stored schedules.
19. **Certificate and coverage** (codex B17). Machine-readable schema
    bound to hashes; finite-domain encodings; sampler algorithm/version/
    seed/count; proof kinds and checker obligations; numerical bound
    method; ε composed over invocation multiplicities; coverage entries
    with stable locations and shim identity.
20. **Formal model** (muse B16, codex B8). Quantum state semantics (tensor
    order, matrices, Born measurement); T2 with a proof sketch and non-
    circular hypotheses; T3 over "realised unitary is a permutation
    matrix"; T5 under static validity; T6 with fixed hypotheses and ε₁+ε₂.
21. **Nested faults** (muse B10, opus B3). No automatic propagation; a
    caller-allocated clean nested register and explicit `lift.faultif
    FAULT_CALLEE` lifted code.

## Declined

- Muse's alternative of keeping pure SSA and restricting oracles to
  structured bodies: declined in favour of the register file, because the
  north star requires arbitrary post-O3 CFGs.
- Muse B4's option (b) (redefine the budget over ISA steps and amend the
  north star): declined; option (a)'s intent is achieved by the one-to-one
  reference binding of §4.2 rather than per-instruction weights.
- Codex's alternative for `qinplace` (direct in-place permutation action
  with certified adjoint): kept legal as a plain `action_call`, but
  `qinplace` itself is the XOR-evaluator form the north star needs.


Re-grade the revised document below from scratch on the absolute scale. For each blocking issue above, state in your summary whether it is resolved; re-raise it in `blocking` only if it is not.


# Rubric

# ISA-specification rubric — the council's scale

The rubric the council (`docs/council/README.md`) uses to grade
`Bennett-ISA-Spec.md`, the founding draft of the Bennett virtual ISA
specification (the `bennett-isa-spec` contract of `Bennett-NorthStar.md`
§4.4 and §6.1). Eight criteria, each scored 1–5 on an absolute scale, plus
blocking issues, a path to accept, and a verdict. Scores are advisory; the
maintainer decides.

## What is being graded

A **specification**, at the level of a first normative draft: the
document a VM author, a circuit-specialiser author, a plugin author, a
scheduler author and a hardware vendor would each implement against,
independently, and be conformance-tested on. It is not an implementation
and not a vision; the vision is `Bennett-NorthStar.md`, supplied as
background and not graded. Grade whether the spec *pins the semantics
precisely enough that two independent executors built from it would
agree*, whether what it pins is physically and mathematically sound, and
whether every cross-repository contract the north star assigns to it is
actually here.

Do not deduct for encodings, binary layouts or performance numbers that
the draft explicitly defers; do deduct, and block, for a semantic rule
that is ambiguous, inconsistent, physically wrong, or missing where an
implementer would have to guess.

## The standard

The PTX ISA document, the JVM specification, the RISC-V unprivileged spec,
the LLVM language reference: a stranger implements from the text alone,
and two strangers get the same machine.

- **Scores are absolute**, not on a curve.
- **Precision over breadth.** A smaller instruction set defined exactly
  scores above a larger one defined loosely.
- **Skepticism is required.** Check the quantum semantics (predicated
  execution, reversibility, uncomputation validity, measurement, fault
  outcomes, phases) against your own knowledge; check reversible-ABI and
  linking claims against how linkers and ABIs actually work.
- **Blocking means blocking.** A blocking issue is one that, uncorrected,
  would make two conformant implementations disagree, would make the
  machine unphysical or irreversible where it claims reversibility, or
  would leave a north-star contract unspecified. Everything else is a
  suggestion.

### Scale

- **5:** implementable by strangers with no questions; sound; complete for
  its declared scope; nothing superfluous.
- **4:** implementable with one gap an implementer names at once.
- **3:** a competent draft; the shape is right but several rules need an
  author's clarification before implementation.
- **2:** aspirational; semantics sketched, not pinned.
- **1:** inconsistent or unphysical at the core.

## Criteria

### C1 Machine model

Are the tiers, the state (classical registers and memory, wires, quantum
memory, predicate stack, budget, fault register, history, effect tape),
the types, and the step relation defined unambiguously? Could two
implementers draw the same state diagram?

### C2 Instruction set

Does every instruction have a form, operands, well-formedness rules,
semantics, and a cost hook? Is the set closed and sufficient for what the
dialect must lower (classical control, allocation classes, gates, quantum-
addressed memory, copy/xor/exchange, predication, the step machine,
regions, measurement, effects, faults)? Is anything underdetermined?

### C3 Coherent semantics

Is the predicated step machine defined so that both executors compute the
same function? Are the lifted-oracle interface F_B, the quantum-action
interface, nesting, exit synchronisation, the prefix-reversal invariant,
the fault register, the budget unit, in-place bijections and the
uncomputation-validity invariant stated as checkable rules? Is anything
irreversible, phase-unsafe, or dependent on inspecting superposed data?

### C4 Resources and targets

Is the resource vector, the qubit-class model, the target-description
format (classes, gate alphabet with costs, capabilities such as QRAM and
measurement, objective as weights or lexicographic order, units) complete
enough that a vendor could write one and the scheduler could consume it?
Is the import rule for existing resource models stated?

### C5 Contracts

Are the object format, link format, reversible ABI (call/uncall, ancilla
frames, structural symbol resolution), host–device launch ABI, scheduling
interface, certificate schema and coverage-report format each specified
to the level the north star promises, so that the thirteen repositories
can be developed independently? Is anything that two repositories must
agree on left to convention?

### C6 Formal model and conformance

Is there an abstract semantics an implementer can check against? Are the
theorems (totality and fault determinism, prefix reversal, the
permutation theorem with its exact domain, round-trip for the reversible
tier, validity implies no residual entanglement, executor agreement)
stated with hypotheses? Can the conformance suite be derived from the
text?

### C7 Consistency with the north star and with prior art

Does the spec contradict `Bennett-NorthStar.md` anywhere? Does it use the
established forms where they exist (linear wire SSA as in Quake/QSSA,
Silq/Unqomp validity, QCM synchronisation, Bennett/Knill history) rather
than reinventing them badly?

### C8 Implementability and clarity

Could a VM author and a specialiser author each start tomorrow from this
text? Are the explicitly deferred items genuinely non-semantic? Is the
document organised so a reader finds a rule where they expect it?

## What the council returns

Per criterion: a score 1–5, one or two sentences of evidence pointing at
the document's text, and the single change that would most raise the
score. Then `blocking` (each with id, section, problem, and a concrete
fix: the rule the spec should state), `suggestions`, `path_to_accept`,
`verdict` (`accept` / `revise` / `reject`), and `summary`.

Consensus is reached when every member returns `accept` with an empty
blocking list.


# Background (not graded): `Bennett-NorthStar.md`

# Bennett — North Star (reboot vision, iteration 7 — council consensus)

**Date:** 2026-10-28. **Status:** vision settled at the level of "what it
truly looks like"; technical design NOT started. Iteration 6 after council
rounds 1–5 (`docs/council/northstar-2026-10-28/round-*/report.md`; the
editor's responses are in `round-*/response.md`). Round 5: one accept, two
revise at mean 4.42/5, every earlier blocker confirmed resolved, one new
one (residual LLVM nondeterminism after poison/undef removal: NaN bits,
`fmuladd`, addresses), folded in here as a complete determinism contract.
Round 6: **all three members accept, no blocking issues, mean 4.46**; the
council loop on this document is closed, and this iteration applies only
wording fixes from that round. Nothing here is
implemented, and no code is to be written on the strength of this
document alone (maintainer process rule: vision, then design, then
spikes, then code).

**Provenance.** Written up from maintainer/agent design discussions on
2026-10-28. The maintainer's position on the quantum VM (§4) was formed
over a year of discussion across the quantum-information community; the
document states that position and the reasons, and asks to be judged on
the reasons.

**Relation to earlier documents.** Supersedes `Bennett-Reboot-Blueprint.md`
§3.1–§3.4 (its standalone "BIR" is dropped: the IR is LLVM IR with a
dialect inside it). The blueprint's §5 keep/kill list, §6 ladder and §7
risks carry over where they do not conflict. `Bennett-V2-PRD.md` remains
parked. `Bennett-VISION-PRD.md`'s Enzyme analogy turns out to be literal.

**Ground truth this was checked against** (2026-10-28 read-only survey of
both repos, the Astra reviews, BENCHMARKS.md, and the checkout of the now-
sunset Sturm.jl at `~/old/Projects/Sturm.jl`): worklog chunk 121, session
2026-10-28. The
current Bennett.jl / BennettVM.jl are deprecated as designs; their research
assets (arithmetic generators, soft-float with its test conventions, gate
algebra, scaling-relation regressions, the 6502 native-oracle harness) are
the only things carried forward.

---

## 0. Thesis

**Every program is already a quantum program.** The user never writes a
circuit, never declares a subset, never learns a new language. They write
C, Rust, Julia, anything LLVM eats, and the toolchain decides at every
instruction whether it runs classically, reversibly, or coherently. The
only thing a quantum programmer adds to a classical codebase is a handful
of marker calls: allocate qubits, rotate by theta, measure, and a way to
condition a region on a qubit. Everything else is inferred.

Tagline: **controlled-anything.** If it compiles with clang, you can put it
under a qubit. "Unmodified" means **no source edits**; build-configuration
flags and runtime shims are allowed and are recorded in the certificate.

Stated precisely, because precision is what makes the slogan true rather
than a slogan: *every execution of any LLVM program that is defined under
the reference semantics of §3.2, effect-bounded, and within a classical
resource budget can be run coherently under a qubit; executions that the
reference machine can see are outside that domain produce a named fault
outcome that is part of the result (§4.2), never a silent wrong answer
and never a crash of the region.* Source-level undefined behaviour that
the optimiser has already erased is not detectable by anyone after the
fact; it is covered by an explicit definedness assumption recorded in the
certificate, not by a fault guarantee (§3.2).

**The project is predicated on the hardware getting good enough:**
scalable logical quantum computation with plentiful logical qubits and
**logical gate times on the order of nanoseconds**. Every cost in this
document is counted in that regime; a kernel boot of billions of steps is
a design target only because of it. Efficiency is pursued hard;
universality is never traded for it.

## 1. Decisions (settled 2026-10-28, refined after council rounds 1–2)

1. **Bennett is the LLVM of quantum.** Language designers introduce quantum
   constructs *as they please*, the way LLVM lets anyone design a classical
   language. We provide the target and the optimiser, never the language.
2. **The IR is LLVM IR. We never fork LLVM.** Forking is the disaster
   scenario. Decades of classical optimisation are kept by sitting inside
   the ecosystem through mechanisms an out-of-tree plugin can actually rely
   on (§3). Where an upstream change would help, it is proposed upstream
   as a patch, never carried as a fork.
3. **Delivery is a pass plugin, a driver, and a runtime.** The plugin runs
   at **link time over whole-program bitcode** (§3.3): optimise, reverse,
   optimise. Any front end that can emit bitcode is supported; per-front-
   end integration is a driver concern, named per front end with its
   costs, never a language change.
4. **Three execution tiers, one program.** Classical (host, native code,
   never ours), reversible (device, deterministic forwards and backwards,
   effects on a tape), coherent (device, closed and effect-free, every
   control decision predicated, every region total with a fault output,
   §4.2). The quantum VM is the device, in the sense a GPU is a device.
5. **One virtual ISA, one target description per hardware.** The PTX move.
   The ISA is a versioned public specification with a conformance suite;
   the formal model is of the spec, not of any implementation.
6. **The VM is a scheduler over an extensible resource vector**, and its
   run-time policy depends only on classical data. Compile-time and run-
   time scheduling are the same optimiser, implemented once
   (`bennett-sched`) behind an interface the ISA spec owns (§4.4).
7. **Correctness is defined by a theorem, two oracles, and a fault
   outcome, never by a reversibility check** (§5.1). Certificates say
   which parts are proof and which are evidence.
8. **QIR, OpenQASM 3, Quil, and MLIR quantum dialects are edge formats**,
   read and written at the boundary. Never the semantics (§7).
9. **Languages: the right tool for the job, taste excluded** (§6).
10. **Many small repositories, published contracts, no monolith** (§6.1).

## 2. The architecture, in one picture

```
  Front ends     clang (C/C++)   rustc   Julia (Bennett.jl)   QIR / Quil / MLIR-dialect importers
                     └──────────────┴────────┴───────────────────────┘
                         emit LLVM bitcode + __bennett_* marker calls (the dialect, §3)
                                              │
  Link time      bennett-driver: whole-program bitcode (LTO) ─► LLVM's own optimiser (unmodified)
                                              │
                 bennett-plugin (C++, the only LLVM-linked component):
                   taint over the resolved call graph → region outlining → controlled/adjoint
                   body generation → lowering to the virtual ISA → bennett-sched (cost, schedule)
                                              │
  Objects        fat object: native host code + ISA object(s) + certificate (ISA spec, §4.4)
                                              │
  Executors       ┌───────────────────────────┴───────────────────────────┐
                  ▼                                                       ▼
        bennett-vm (device runtime)                         bennett-circuits (bounded specialiser)
        reversible + coherent tiers, history layers,        hierarchical circuit IR, placement,
        effect tape, branch-enumeration simulation,         proof-carrying output, exporters
        launch-time lowering to the target alphabet
                  └───────────────────────────┬───────────────────────────┘
                                              ▼
  Backends     Bennett.jl simulators   OpenQASM 3   QIR   Quil   bennett-estimate   hardware via bennett-targets
```

One semantics: the ISA spec's formal model and conformance suite. Two
executors, in separate repositories, each conformant to that spec, and
permanently differentially tested against each other and against native
execution of the same bitcode.

## 3. The dialect: what an out-of-tree plugin can rely on

This section lists only mechanisms that exist for a plugin today, states
what each does and does not guarantee, and names the legality spike that
gates freezing the spec.

### 3.1 Mechanisms

| Need | Mechanism (out-of-tree, stock LLVM) | What it does NOT give, and what covers the gap |
|---|---|---|
| Quantum operations: allocate (clean / dirty / class), release, gate, rotate(θ), measure, quantum-addressed load and store | **Declared external marker functions** `__bennett_*` with fixed signatures, exactly as Enzyme's `__enzyme_autodiff`. Not `llvm.*` intrinsics (a plugin cannot register them). The plugin recognises them by name and signature at link time. **Positive legality requirement:** a marker is declared as an external function that may read and write memory and may not return (no `readnone`, `readonly`, `speculatable`, `willreturn`, `nounwind`-only combinations that would license elimination, commoning or speculation). Stock passes then preserve the *dynamic sequence* of marker calls on every executed path. | Containing functions may be inlined, cloned, unrolled or versioned, so the *static* count of marker call sites is not preserved; the external declaration itself is never inlined. *Explicit quantum registers* are accessed only through markers, never through LLVM `load`/`store`, so no alias-analysis or forwarding pass can touch them. The ordinary loads and stores of lifted classical code (all of SQLite's) are not quantum-register accesses: they are lifted coherently according to the incoming memory model, as classical memory whose contents happen to be superposed. This legality is a property of ordinary effectful external calls, not of any attribute we invent; the legality corpus (§3.2) tests it. |
| Qubit handles | **Portable handles**: an ordinary `ptr` in address space 0 (or an integer handle) returned by `__bennett_qalloc`, which every front end can emit from unmodified source: clang, rustc, Julia. Never dereferenced by host code. The plugin normalises recognised handles into its internal representation after outlining, respecting the incoming target's pointer size. **Reference semantics at the dialect level.** | LLVM cannot enforce linearity; SSA uses are free to duplicate. Linearity is a fail-loud verifier obligation after outlining, plus the ISA's value semantics below. Collections of handles are supported through a **handle table**: an aggregate or array of handles indexed by a classical value (a compile-time constant or a classical-tier value) is lowered to table lookups; a handle that flows through memory at a superposed address, or through an `inttoptr`/`ptrtoint` round trip, is **rejected fail-loud** in v1 of the dialect; any handle use that survives into host native code is rejected likewise. Any code that touches handles or measurement results runs in the device's classical-control tier, never as host native code. This is the point on which QIR is faulted in §7, and the answer is to be explicit about it. |
| Qubit values in the ISA | **Linear value semantics in the virtual ISA** (wire form, as in Quake's wire dialect and QSSA): each use consumes, each definition produces. The plugin converts handles to wires after outlining and verifies the conversion. | Both forms exist, at named pipeline stages, for the same reason CUDA-Q keeps both. |
| Coherent memory and in-place update | **Copy-on-read, XOR-on-write, total-bijection-for-in-place** (§4.2): `__bennett_qload` is a CNOT copy of the register onto fresh wires (source preserved, copy is retained workspace until uncomputed under the validity invariant); `__bennett_qstore` XORs into its target, so a store into a known-clean register is a copy and a store into a register not known to be clean is a **compile-time error** (this source-level restriction is distinct from the oracle ABI, whose targets may hold any value); an in-place update x ← g(x) is written `__bennett_inplace(@g, @ginv, …)` and is admitted **only when g and ginv are mutually inverse total bijections on a declared finite encoding**, with budgets sufficient for forward evaluation and inverse cleanup, and is lowered compute-out-of-place, swap, uncompute-with-g⁻¹; library bijections (add a constant, xor, rotate, modular add, modular multiply with its coprimality condition and its treatment of unused encodings stated) carry their inverses and their g∘ginv = id certificates in `bennett-arith`. | A fallible or budget-limited computation cannot be in-place: it uses the out-of-place oracle interface (§4.2). A declared inverse is a correctness obligation: g∘ginv = id is checked by §5.1 part 1 at exhaustive small widths or carried as a library certificate, and a wrong inverse is caught because swap-then-uncompute leaves the scratch register non-clean. An in-place update with no inverse fails loud at compile time. Front ends may instead compose two compute regions and a swap themselves. This is what makes `when(q) do x += a end`, the founding use case of the Julia language (§6), work as written. |
| Taint: classical vs reversible vs coherent | **Analysis, not types**: a context-sensitive interprocedural analysis over data dependence, control dependence and memory effects, from marker results and region entries, over the whole-program call graph, with polyvariant specialisation when one function is used both classically and coherently. | No per-value attribute survives optimisation and none is needed. "Untainted" is defined relative to the resolved call graph, never per translation unit. |
| Control as structure: adjoint, controlled-by-qubit, compute-with-uncompute, reversible-tier entry | **Function granularity**: a region is outlined to a function (LLVM's `CodeExtractor`) and entered through a marker call `__bennett_ctrl(q, @f, budget, args…)`, `__bennett_adj(@f, …)`, `__bennett_compute(@f, …)`, or `__bennett_reversible(@f, budget, …)` for the reversible tier. The plugin generates controlled and adjoint bodies on demand from one source body. **Well-formedness:** a `ctrl`/`adj`/`compute` region is unitary: user measurement inside it is refused (or, when the front end asks for it, deferred by the deferred-measurement principle, which the certificate states); allocations inside are released clean or borrowed and restored; the compiler's own measurement-based uncomputation is the sole exception, and until its controlled form is fixed in the language's certificate kinds (§9.6) **unitary uncomputation is the fallback under control**. Exceptions and unwinding (`invoke`/`landingpad`, Rust panics, C++ `throw`) inside a region are step-machine control flow where the handler is in the region, and a fault code where it is not. | Front ends that want `when`-style syntax do the outlining themselves (Julia macro, clang attribute, Rust proc-macro) and emit the marker call; the dialect does not require it. Generating a body needs the callee's IR, which is why the plugin runs at link time (§3.3). |
| Bounds for coherent regions | **A region-level classical budget**: dynamic steps, heap bytes and recursion depth, passed as ordinary integer operands of the region-entry marker or supplied out of band by the host or driver (a project-wide default, a per-function table), and applied by the plugin after outlining. **No per-loop source annotation is ever required**, so unmodified SQLite, Linux and the Monte Carlo compile as they are. Per-loop bounds from scalar evolution, and optional per-loop markers, are *refinements* that let the specialiser tighten padding; they are not needed for correctness and no loop identity has to survive O3. | A region whose budget is exhausted on some basis input produces a fault outcome on that input (§4.2); it is never a compile error and never a truncated result. |
| Garbage and uncomputation | **Liveness analysis** on the outlined region plus the compute/uncompute marker; no lifetime intrinsics. | The scheduler decides when to pay to free a dead value; the dialect only has to make deadness computable. |
| Measurement and classical feedback | Marker call returning `i1`, flowing into ordinary `br` / `select` / `phi`, outside unitary regions. | Branching on a measurement result is classical control (§4.2). |
| Effects | Marker calls on the device side for the effects the device models (console, clock, entropy, block device); everything else is a host call. | Effect semantics per tier are in §4.2; an unvirtualisable effect inside a coherent region is a fault code on the executions that reach it, and a coverage-report line at compile time. |

### 3.2 Pipeline placement and the cost of staying in-tree

- **Correctness is invariant under LLVM's optimiser; cost is not.** Any
  semantics-preserving optimisation of the classical part is lowered as it
  stands, so differential testing (§5.1) is against the native binary
  built from the *same* optimised bitcode. Optimisations that erase or
  duplicate intermediate values change gate counts, so tainted regions get
  a curated region pipeline after outlining.
- **Definedness.** Source-level undefined behaviour cannot be "concretised"
  after an optimiser has exploited it (`clang -O3` turns `int y = 10/x;
  return 0;` into `return 0`, and nothing remains to fault on), so the
  document does not claim that. The contract, stated once and referenced
  by §0, §4.2, §5.1 and §8: **the reference semantics is the ISA formal-
  model interpreter run on the *materialised* optimised bitcode of the
  outlined region**, mapped by the dialect's reference semantics, before
  the curated region pipeline. **Materialised normalisation**, not
  `freeze`: LLVM's `freeze` yields an arbitrary fixed value that codegen
  lowers to whatever the register holds, so it cannot define one meaning
  shared by native code and the device. Instead the normaliser rewrites
  the region's optimised bitcode into a **poison-free, undef-free form**:
  poison-generating flags (`nsw`, `nuw`, `exact`, `inbounds` and kin) are
  stripped; partial operations are totalised with a stated result (a
  shift by ≥ width yields 0 through a `select`; division by zero and
  `sdiv`/`srem` of INT_MIN by −1 become faults, below); memory first
  touched inside the region (alloca and heap contents, and the padding
  of region-local objects) is zero-filled; any remaining `undef` operand
  is replaced by a stated constant; `llvm.objectsize`, `llvm.is.constant`
  and similar query intrinsics are lowered before both builds. Region
  inputs are **not** zero-initialised: they are the bytes the host
  supplies.

  Poison and undef are not the only choices LLVM leaves open, and the
  reference semantics **fixes every remaining one** so that the native
  comparison binary and the device implement the same function:

  - **Floating point is deterministic soft-float in both builds.** The
    normaliser rewrites every floating-point operation of lifted code
    into calls to the project's bit-exact soft-float library
    (`bennett-arith`, IEEE 754 binary64, round-to-nearest-even, a single
    canonical NaN with fixed sign and payload produced by *arithmetic*
    operations only, while `fneg`, `fabs`, `copysign`, loads, stores,
    `bitcast`, `select` and `phi` stay bit-exact as LangRef requires; no
    fused multiply-add unless the source wrote `fma` explicitly;
    `llvm.fmuladd` is rewritten to `fmul` + `fadd`; out-of-range
    `fptosi`/`fptoui` and the `minnum`/`maxnum` NaN cases have stated
    results); fast-math flags are stripped. Formats: binary64 and
    binary32 are covered; `half`, `bfloat`, `x86_fp80` and `fp128` are
    coverage-report lines until the library covers them, never silent
    widening. Hardware floating point never executes in either build, so
    NaN bits, fusion and intermediate rounding are identical by
    construction, including through `bitcast` and branches. The native
    comparison binary is the materialised region plus its entire
    materialised callee closure, linked against the same
    `bennett-runtimes` and `bennett-arith`, never against the host libc
    or libm.
  - **Addresses follow a deterministic layout model.** The heap is laid
    out by the same `bennett-runtimes` allocator shim linked into both
    builds at a fixed base with no ASLR; globals and functions are placed
    by a driver-controlled comparison link (non-PIE, fixed section
    addresses, constant merging and identical-code folding disabled) whose
    link map the device loader replicates. Region allocas are rewritten
    by the normaliser onto a shim-managed shadow stack in both builds
    where possible, which shrinks the remaining class: executions in
    which absolute *native stack* address bits still influence the
    payload or the fault are classified by the reference interpreter's
    **address-provenance** tracking as *layout-dependent*, excluded from
    native comparison, counted like the undefined class, validated
    against the reference interpreter instead, and recorded in the
    certificate.
  - **Faulting memory access is defined** by an object-bounds model in the
    reference semantics: a lifted load or store outside any live
    allocation is `FAULT_UB_MEMFAULT`. The artefact may therefore fault
    where native silently reads adjacent memory; "equals native, or is
    flagged" permits this, and the fault rate reports it.
  - **Atomics and volatile** in lifted code are sequentialised in program
    order (the single-thread assumption recorded in the certificate);
    concurrency is §9.11.

  After this the materialised bitcode has **one defined meaning**, which
  native codegen and the ISA interpreter both implement, and the native
  comparison binary is built from that materialised bitcode. Only
  immediate undefined behaviour that the reference machine encounters
  (traps, `unreachable`, faulting memory access, division by zero) remains,
  and it is a fault code (§4.2); compiled artefacts must never fault where
  the reference does not; native execution supplies success values, and
  fault *causes* come from the reference interpreter, since a native trap
  cannot tell division by zero from `unreachable`. Source UB that
  optimisation erased before this point is **not detectable** and is
  covered by an explicit definedness assumption recorded in the
  certificate, together with the LLVM version, the pipeline and the
  normaliser version, since the fault set and the materialised program
  depend on them. The normalisation rules are normative text in
  `bennett-dialect-spec`, enumerating every source they remove (poison
  literals, `nsw`/`nuw`/`exact`/`inbounds`, fast-math `nnan`/`ninf`,
  `!range`/`!nonnull`/`!noundef` metadata and the matching attributes,
  `llvm.assume`, undef vector lanes) and shipping a residual-poison
  validator implemented independently by the plugin and by
  `bennett-conformance`. The conformance
  harness classifies inputs with instrumented builds (UBSan, ASan, MSan)
  or a checked reference interpreter, as a separate build from the
  comparison binary; these are **supplementary classifiers**, not a
  complete decision procedure for source definedness, and inputs they
  flag are reported as *undefined* and excluded from comparison.
- **Regions are functions.** Every `when`, adjoint, compute and
  reversible-tier block outlines first. Enzyme lives with this.
- **Per-LLVM-major builds** of the plugin, as Enzyme is built. A mixed-
  language link (bitcode from different LLVM majors, different front-end
  IR idioms, one target datalayout) is supported only within a **tested
  compatibility envelope** published with each driver release: bitcode-
  reader versions, target layouts and ABIs, front-end pairs.
- **The legality spike** (§9.1) is a conformance corpus, not a design
  question: marker-bearing bitcode through every stock pass at O3, plus
  native code generation of fat objects, must preserve the dynamic
  sequence of marker calls on every path and must leave no handle use in
  host code. Freezing `bennett-dialect-spec` is gated on it passing, and
  on actual emission examples from clang, rustc and Julia.

### 3.3 Compilation model: link time, whole program, fat objects

Taint and controlled bodies depend on the calling context across the whole
program, and generating a controlled body needs the callee's IR. So:

- Front ends emit **bitcode** (clang `-flto`, rustc `--emit=llvm-bc` or
  `-Clinker-plugin-lto`, Julia through LLVM.jl). This is the one universal
  thing every LLVM front end does. No front end loads our plugin; pre-link
  per-TU optimisation sees markers only as unknown external calls, which
  is exactly the legality contract.
- **`bennett-driver`** merges the bitcode, runs LLVM's optimiser, loads the
  plugin at the LTO pipeline extension point (or runs it through `opt`),
  resolves taint over the whole call graph, and produces a **fat object**:
  native host code for the classical tier, ISA object(s) for the device
  tiers, and a certificate. clang's offload model (outlining, fat
  binaries, a launch runtime) is the **model**, not a reused mechanism: a
  middle-end pass cannot conjure clang's driver machinery, so we own ours.
- **Host-triple IR is what the device lowering accepts**: datalayout, ABI-
  lowered calls, target intrinsics and inline asm arrive as the host front
  end produced them. Target intrinsics and asm are classified *lowered /
  trapped / shimmed* in the coverage report. There is no `bennett` triple,
  because a plugin cannot add a clang target and we do not fork.
- **Stated coverage constraints:** a tainted call needs the callee's
  bitcode. Rust's distributed `std` normally carries embedded LLVM bitcode
  in its rlibs; the driver extracts it where present and compatible, and
  a rebuild (`-Zbuild-std`) is needed only where it is missing or from an
  incompatible LLVM major. The Julia runtime and precompiled native
  libraries need bitcode builds or shims (`bennett-runtimes`). Calls with
  no bitcode are coverage-report lines (*trapped*), never silent.
- **Per-front-end integration is named work**: clang needs only `-flto`
  and the driver; rustc goes through bitcode emission because its in-
  process plugin path is nightly-only; Julia goes through LLVM.jl and the
  same driver in-process. Bennett.jl is the Julia integration.
- A per-TU invocation remains available as a **fast path** for programs
  closed within one unit (the REPL case), with the same semantics.

## 4. The virtual ISA and the device

### 4.1 Why the VM is the revolution

The circuit model is to quantum programming what bare-metal machine code
was to classical programming before virtual machines, virtual memory and
portable ISAs: every program welded to one machine, every vendor with its
own toolchain, no dynamic allocation, no loops beyond what you unrolled by
hand, no portability, no way to ship one artefact to many machines. The
classical world escaped through abstraction layers *between* program and
hardware: virtual memory, the process, the JVM, LLVM, PTX.

Quantum programming has had abstract machines before: Knill's QRAM model
(1996), Quil's Quantum Abstract Machine, eQASM, and the circuit-plus-
classical-controller model every SDK ships. What none of them has is the
*rest* of the classical escape: virtual allocation with classes and
garbage as a resource, bounded coherent control over arbitrary programs
rather than hand-built circuits, separate compilation and linking, a
resource vector in the specification, and a program model that any LLVM
language targets without being rewritten. That combination is the layer
quantum programming lacks. The mistakes of the pre-VM era are listed so
the design never repeats them:

- **No program is written against a machine.** Programs target the virtual
  ISA; hardware implements the ISA through a target description.
- **Memory is virtual.** Qubits are allocated and released through the VM,
  never addressed physically. Clean, dirty and class are properties of an
  allocation request, not of a wire index.
- **Loops and recursion are instructions, not unrolling.** Budgets are
  values the VM enforces.
- **Resource accounting is part of the architecture**, in the ISA spec.
- **The spec is public and versioned.** Governance: PTX and the JVM each
  had a steward and a conformance regime; this ISA has a published spec, a
  conformance suite, and a steward who accepts target descriptions and
  revisions through a recorded process. A vendor implements it before an
  ecosystem exists for the reason vendors implemented PTX: the programs
  are written against it, not against them.

### 4.2 Execution semantics by tier

Two control disciplines, kept apart by name in the ISA:

- **Classical control** (host data, measurement results, run-time
  budgets): genuinely dynamic, an instruction pointer, data-dependent trip
  counts, real allocation. This is where run-time scheduling, history
  layers, checkpointing and pebbling policy live, and **every such
  decision may inspect only classical data**: an architectural invariant.
  Classical checkpointing never copies quantum state; a checkpoint of a
  coherent region is a point from which it is *recomputed*, which the
  scheduler may choose only where the region's own semantics permit.
- **Coherent control** (a decision that depends on a qubit): **predicated
  execution under a classical budget**, in both executors. The general
  construction, for an arbitrary and possibly irreducible post-O3 CFG, is
  a **predicated step machine**: a superposed block counter, stepped for
  the budget, every block executed under the predicate "the counter names
  me"; structured `pred { }` and `loop { }` blocks are optimisations of it
  that the specialiser applies where the CFG is structured. A branch on a
  qubit pays for both arms. An allocation whose size depends on a qubit is
  padded to its bound. The budget is classical and fixed before entry;
  run-time budgets come from the host or from measurement results, never
  from superposed data. **Nothing about the VM makes superposed trip
  counts observable or cheap; what it makes possible is choosing the
  budget at run time from classical data instead of at compile time.**

**Two region interfaces, kept apart by name.** Every coherent region is
one of:

- a **lifted classical oracle**: classical code that the plugin
  reversibilises. It computes one deterministic bounded result F_B(x),
  success or fault, with the interface and the XOR/involution properties
  below. Control is control of the XOR; adjoint is the same region.
- a **quantum action**: a region whose body contains non-permutation
  operations (rotations, Hadamards) or in-place bijections, acting as a
  unitary U on its **declared mutable wires**, with borrowed inputs
  preserved and workspace restored. Control means controlled-U, adjoint
  means U†. It need not be an involution and does not XOR; in-place
  bijections belong here, and because they are total bijections with
  bounded inverses (§3.1) a quantum action has no fault outcome of its
  own: any fallible computation it needs is a lifted oracle it calls,
  whose fault register it declares among its outputs. A quantum action
  whose body contains coherent internal control is, by definition, its
  bounded padded unitary under the declared bound, and that bound is
  part of the action's content identity and certificate entry (the same
  body under two bounds is two unitaries); the budget-fault guarantees
  of this section describe lifted oracles only.

Lifted oracles and quantum actions nest freely; the plugin classifies
each outlined region by its contents and the verifier checks the
declared interface. The step machine records, per step, which
predecessor it came from, which is what makes block-counter transitions
injective at control-flow joins; and at region exit it synchronises: all
branches pad to a common halt counter before control workspace is
restored (the Quantum Control Machine injectivity and synchronisation
conditions, §7).

**Totality of lifted oracles: F_B(x), success or fault.** The oracle's
interface is: inputs (preserved), a caller-supplied output target (any
value), a caller-supplied **fault register**, and workspace. The **budget
unit** is steps of the ISA formal-model interpreter on the materialised
outlined region (§3.2), so the fault set is a property of program plus
budget plus recorded LLVM version and pipeline, never of Bennett's own
lowering; compiled artefacts pad internally as needed and never fault
where the reference does not. On success, F_B(x) = (f(x), 0): the output
target is XORed with f(x) and the fault register is unchanged. On failure,
F_B(x) = (0, code): the output target is XORed with the **canonical zero
payload** (left unchanged) and the fault register is XORed with a distinct
code per cause (budget exhausted: steps, heap, recursion; immediate
undefined behaviour reached; unmodelled effect reached), the code chosen
by the reference semantics. Because both halves are XORs, the region is
an involution on its targets: repeated, controlled and adjoint invocation
compose by XOR accumulation, which is what Grover-style iteration needs.
Inputs are preserved, dirty registers are unchanged and clean workspace is
restored on *every* basis input, faulted or not, by the **prefix-reversal
invariant**: on a faulted branch the step machine continues to the budget
with the fault predicate off, and its recorded history is reversed exactly
as on a clean branch. Two implementations that return the same fault code
therefore return the same quantum state, not merely the same flag. The
fault register is part of the oracle's interface: algorithms test it,
resource estimates report it, and the acceptance tests of §8 require its
rate to be zero on their declared domains, because a nonzero fault code on
some basis inputs entangles the fault register with x and degrades the
interference an algorithm such as Grover relies on. Both executors
implement exactly this; the circuit specialiser is the VM's semantics
under a fixed budget, no more and no less.

**Coherent memory and the region interface.** Classical code acting on
quantum state that outlives a region has exactly these meanings (mirrored
in the dialect, §3.1): a read is a CNOT copy onto fresh workspace, the
source preserved; a write XORs into its target, so writing a known-clean
register is a copy and writing a register not known to be clean is a
compile-time error; region inputs are preserved and declared outputs are
XORed into caller-supplied targets, every other write being restored
workspace; an in-place update x ← g(x) requires a total bijection with a
bounded inverse (a declared `__bennett_inplace(@g, @ginv)` or a library
bijection, §3.1) and is lowered as compute-out-of-place, swap, uncompute-
with-g⁻¹, else it fails loud; a fallible computation is never in-place.
This is the rule that makes controlled modular arithmetic, and `when(q)
do x += a end`, compile from unmodified code.

**Uncomputation validity (the Silq `qfree`/`const` and Unqomp
condition).** Garbage is a cost choice inside a correctness envelope, not
free policy. Each garbage value records its dependency set and was
computed by a `qfree` (classical, permutation-tier) computation; both
halves of the Silq discipline apply. It may be uncomputed by reversal or
recomputation only while that set is unmodified since its computation,
and it **must** be cleaned before any non-permutation operation
(Hadamard, non-diagonal rotation, measurement) or in-place update acts on
a wire in its dependency set, and before the end of the enclosing unitary
region. Measurement-based uncomputation with phase fixup is the
sanctioned alternative where that window has closed, with the fixup
computed for the actual schedule: after an intervening U the correction
D becomes U D U†, and §5.1 part 2 verifies the fixup as scheduled, never
an assumed one.
Compile-time and run-time schedulers choose **only among schedules that
satisfy this invariant**; the handle→wire verifier rejects violations;
conformance exercises them with interference tests (§5.1 part 2). A
scheduler that deferred uncomputation past an interfering operation
would compute the wrong state while every ancilla still returned to zero,
which is exactly the class of bug the invariant exists to make
unrepresentable.

Effects by tier:

| Tier | Where | Effects | Undefined values |
|---|---|---|---|
| classical | host, native | real | real |
| reversible | device | recorded on the effect tape forwards, replayed backwards; the device models console, clock, entropy, block storage as reversible device models; entered through `__bennett_reversible` or a driver mode | refined by the materialised normalisation of §3.2; immediate UB is a fault, recorded |
| coherent | device | **closed and effect-free**: no external effect may occur inside a coherent region. Devices the program touches are virtualised as reversible state inside the device (an in-memory VFS, a console register, a device model) and become part of the oracle's state. Classical inputs are fixed before entry; outputs leave through measurement after exit. An effect the device cannot virtualise is a fault code on the executions that reach it. | refined by the materialised normalisation of §3.2; immediate UB is a fault code |

What the VM physically *is* at run time: a classical runtime that
schedules quantum operations. Coherent regions are lowered to predicated
blocks; the classical runtime decides when to run them, with what
resources, and how to uncompute their garbage, using only classical
information; at launch it lowers predicated ISA blocks to the target's
declared gate alphabet using `bennett-targets` capability declarations
(the specialiser does the same ahead of time). On a simulator target the
VM executes a **permutation segment** by **branch enumeration**: a
permutation applied to a state vector is a permutation of amplitudes, so
the segment is run once per basis configuration of the superposed inputs,
tracking the full configuration including garbage and virtualised device
state. Non-permutation gates between segments (rotations, Hadamards,
measurement-based fixups) are applied to amplitudes and may increase the
branch count. This is what makes small-instance end-to-end demos (§8)
checkable without a state vector the size of SQLite's memory.

### 4.3 Resources

- **The resource vector.** Qubit-time by qubit class is the base. Qubit
  classes are register classes: a target declares tiers with costs, and
  allocation chooses a class the way a register allocator does. Garbage
  carries an occupancy cost per qubit-second. Targets may add energy,
  routing, T, Clifford, measurement, or anything else; the ISA does not
  enumerate resources, the target description does. **Decision rule:** a
  target description supplies either a scalarisation (weights) or a
  lexicographic order over its resources; the scheduler optimises that
  objective and reports every component; conformance tests check the
  accounting of each declared resource against the target's own units.
- **Honest costs of superposition**: a coherent branch pays for both arms;
  a quantum-addressed memory access costs O(N) gates through QROM/QRAM
  circuits unless the target provides QRAM; coherent allocation is padded
  to its bound; dirty ancillae are cheaper to borrow and more expensive to
  use; a predicated step machine over an unstructured CFG costs the budget
  times the block count unless the specialiser recovers structure.
- **Allocation classes:** clean |0⟩ allocation, **dirty borrowing** (a
  first-class resource with no analogue in the current code), and release, with clean release and restored correlations as
  **semantic obligations** checked by simulation (§5.1), since they cannot
  be decided statically in general.

### 4.4 What the ISA spec owns

The ISA spec is one of the two contracts (§6.1). It owns, by name, every
format or interface two repositories exchange across the device boundary:

- the instruction set and its formal model (abstract semantics, the fault
  register, the round-trip theorem);
- the resource vector and the **target-description format**, including
  capability declarations (gate alphabet, QRAM, measurement) beyond costs;
- the **object format** for ISA programs and the **link format** for
  separate compilation, with a call/uncall convention and shared ancilla
  frames (the reversible ABI);
- the **host–device launch ABI**: how a host program starts, suspends,
  reverses, and reads back a device program, budgets and fault registers
  included;
- the **scheduling interface**: scheduling problem in (ISA program, target
  description, objective), schedule and certificate out, with the C ABI,
  objective semantics and versioning, so a competitor's scheduler is
  substitutable and a competitor's VM cannot invalidate compile-time
  schedules;
- the **certificate schema** that `bennett-circuits`, `bennett-arith`,
  `bennett-estimate` and `Bennett.jl` all consume, including the proof-
  versus-evidence labels of §5.1;
- the **coverage-report format** the driver emits;
- serialisation and versioning rules, and the conformance suite.

### 4.5 An illustrative sketch (non-normative)

Instruction classes, not encodings:

```
  region   budget={steps,heap,depth} outputs=… → outputs, fault   ; coherent region entry
  qalloc   class=<name> n=<classical>            → wires           ; clean
  qborrow  class=<name> n=<classical>            → wires           ; dirty
  qfree    wires                                                   ; verifier: clean / restored
  gate     op=<X|CX|CCX|MCX|RZ(θ)|…> wires       → wires           ; linear: consumes, produces
  qload    addr=<wires> mem=<region>             → wires           ; O(N) unless target QRAM
  qstore   addr=<wires> val=<wires> mem=<region>
  step     pc=<wires> blocks=…                                      ; predicated step machine
  pred     p=<wire> { … }                                           ; structured optimisation of step
  loop     bound=<classical> { … }                                  ; structured optimisation of step
  fault    code=<const>                                             ; sets the region's fault register
  measure  wires                                 → classical bits   ; outside unitary regions
  br / call / ret / alloc / load / store                            ; classical control, host data only
  effect   dev=<model> …                                            ; reversible tier only; taped
```

A target description names its qubit classes with costs, its native gate
alphabet, whether it provides QRAM, and its resource scalarisation:

```
  target: surface-code-d17-example
  classes: { logical: {qubit_second: 1.0}, dirty_pool: {qubit_second: 0.3} }
  gates:   { CX: {t: 0}, CCX: {t: 7, depth: 3}, RZ: {t: "synth(ε)"}, measure: {time: 1} }
  qram:    none
  objective: weighted { t: 1.0, qubit_second: 0.05 }
```

## 5. Scenes from the finished thing, and what "correct" means

**The REPL.** Define a Julia function. Do not compile it. Write
`when(q) do f(x) end` and it runs, in a simulator or on hardware, because
compilation is invisible, incremental, cached by world age, composable.
Quantum registers are REPL values with lexical lifetime. `@cost f(x)`
prints T-count, T-depth, logical qubits, and wall time on a named target,
the way `@time` prints allocations. Redefine `f` and everything downstream
recompiles. Hand a compiled function to another function as an ordinary
callee. The Lisp image, holding reversible objects with certificates.

**The toolchain.** `-flto` plus our driver beside clang. Point it at a
mature codebase: one fat object per link, a coverage report honest to the
instruction (lowered / trapped / shimmed), and a resource estimate. Partial
compilation is a region marker, and the toolchain is provably the identity
on everything outside the tainted call graph. The kernel compiles, boots on
the VM in the reversible tier with its devices modelled, writes a serial
console to the tape, and un-boots to the reset vector.

**The device.** The quantum VM of §4, as a device runtime the way a GPU
runtime is: host code at native speed, only device tiers pay for
reversibility.

**The compiler is optimal within what it claims.** Optimality is defined
against a target description and a declared search space. Optimal
reversible pebbling is PSPACE-complete, so: small kernels are exactly
synthesised, and *minimality* is claimed only with a checkable lower-bound
or exhaustive-search certificate (an exact-synthesis witness alone shows
attainability); large programs carry closed-form cost bounds and a
certificate of the gap between the schedule found and the best bound
known. The compiler chooses adders, pebbling, measurement-based versus
unitary uncomputation, QROM versus QRAM, under a space budget.

**The ecosystem.** A registry of reversible libraries with certificates:
libc, libm, zlib, crypto, SQLite, published as linkable ISA objects so
nobody compiles them twice. Arithmetic is library code too (§6).

### 5.1 Correctness

Ancilla-zero is not correctness: every historical S0 defect in this
project passed a reversibility check. Correctness is defined in three
parts, and every certificate labels each claim as **proof** (exhaustive
over a declared finite domain, or compositional/structural) or
**evidence** (sampled, with seeds and counts), never blurring the two.

1. **Permutation tier, by theorem.** Define the permutation tier *after
   decomposition into the gates actually emitted*: a circuit over
   {X, CX, CCX, exact MCX} is a permutation matrix. Relative-phase Toffoli
   decompositions and measurement-based fixups are **not** in this tier.
   A permutation is determined by its action on basis states. Therefore,
   for a region whose declared interface specifies an expected
   permutation P, over a declared finite domain D: if on every element
   of D the artefact's **entire final register tuple** equals P applied
   to that element, then its restriction to D is exactly P, with no
   relative phase and no residual entanglement. For a lifted oracle, D is
   every input x, every output-target value t, every fault-register value
   e, every value of every borrowed dirty ancilla d, clean ancillae in
   their declared state, and P is |x⟩|t⟩|e⟩|d⟩|0⟩ ↦ |x⟩|t ⊕
   payload(F_B(x))⟩|e ⊕ code(F_B(x))⟩|d⟩|0⟩, where F_B is the bounded
   reference result of §4.2 (native execution supplies f(x); the embedding
   specification supplies the rest). For an in-place bijection, P is
   |x⟩|0⟩ ↦ |g(x)⟩|0⟩ on the mutable wires with workspace clean, and the
   same check establishes g∘ginv = id. Input preservation is a
   hypothesis of the theorem and an acceptance check, not a consequence:
   an artefact that flipped an input bit after an otherwise correct oracle
   would pass every output-only check. **Exhaustive agreement on D is
   complete for D. Sampled differential testing above exhaustive widths is
   evidence, labelled as such.** Clean release and dirty restoration are
   checked by this simulation, not statically.
2. **Non-permutation lowerings, by channel comparison.** Measurement-based
   uncomputation is a channel (an instrument where outcomes are exposed),
   not a unitary on the data; rotations and synthesised gates are unitaries
   with an approximation budget ε. Every such lowering is verified against
   its reference by **process comparison at exhaustive small widths**: the
   induced channel (Choi-state comparison, including a reference system to
   catch lost correlations) for measurement-assisted implementations, and
   unitary equivalence plus **controlled-interference tests** (the artefact
   run controlled and inside an interferometer) for unitaries, with ε and
   its **composition rule** stated per artefact: the metric is the diamond
   norm for channels and a phase-sensitive operator-norm bound for
   unitaries under control, budgets add along a sequence, and the
   certificate carries the sum. Floating-point matrix agreement counts as
   proof only with a rigorous numerical error bound; otherwise it is
   evidence. This is proof for the widths tested and evidence above them.
3. **Algorithms, compositionally.** Grover, amplitude estimation and
   friends are verified by state-vector simulation at small instance size
   with the compiled oracle applied by branch enumeration over its
   permutation segments (§4.2), and resource estimates are produced from
   the oracle's certificate without materialising gates.

**Equivalence is "equals native, or is flagged".** On every element of a
rung's declared domain the artefact must return either the native result
or a fault code; the fault rate over the domain is reported and must be
zero on the rung's acceptance instances; inputs the instrumented
classifiers of §3.2 report as *undefined*, and executions the reference
interpreter classifies as *layout-dependent*, are excluded from native
comparison, validated against the reference interpreter, and counted
separately, with each rung reporting and bounding both excluded
fractions. One outcome table governs §3.2, §5.1 and §8: native-
comparable success, reference fault, layout-dependent reference
validation, classifier-flagged undefined. Domain D stays finite and tractable when large dirty pools
are borrowed by a structural lemma: borrowed wires are used only inside
verified compute–use–uncompute frames, so their restoration is proved per
frame; where that lemma does not apply, dirty restoration above small
widths is labelled evidence.

**What a certificate asserts:** the ISA object, the target, the objective,
the claimed resource vector, the tier and budget of each region, the
definedness assumption, the verification performed (parts 1–3, with
domains, widths, seeds and counts, each labelled proof or evidence), the
fault rate per declared domain, and for small kernels an exact-synthesis
witness and, where minimality is claimed, its lower-bound certificate. A
checker in `bennett-conformance` validates a certificate against the
object without trusting the compiler; replayable validation records are
not proofs and are labelled evidence.

## 6. The right language for each job

| Component | Language | Why (taste excluded) |
|---|---|---|
| Pass plugin (taint, outlining, body generation, lowering to the ISA) | **C++** | The only component of the compiler core that links LLVM (Bennett.jl, as a front end, uses LLVM.jl). `llvmGetPassPluginInfo` has C linkage, but registering a new-PM pass and every analysis the plugin needs (loop info, dominators, scalar evolution for bound refinement, alias analysis, MemorySSA, `CodeExtractor`) are C++ API only. v1 is the evidence of avoiding this: it reimplements loop analysis in `src/lowering/cfg.jl` and parses MemorySSA out of printed text in `src/memssa.jl`. Enzyme is C++ for the same reason. Built per LLVM major. Kept narrow: it does not contain the scheduler. |
| Scheduler and cost model (`bennett-sched`) | **Rust**, C ABI owned by the ISA spec | Linked by the plugin (compile time) and the VM (run time); it is what makes decision 6 literally true. No LLVM dependency. |
| ISA spec tooling, VM / device runtime, circuit specialiser, estimator | **Rust** | None touch LLVM: they consume the ISA's serialised form. Embeddable device library with no runtime; memory safety in a component that must never crash a host; usable without std near kernels; a JIT tier available without LLVM. Rust ownership is affine, not linear, so it models qubit ownership well with a leak check, not natively. |
| Driver | **Rust**, invoking LLVM tools (`opt`, `lld`) as external processes and the plugin through them | The driver orchestrates bitcode but does not link LLVM itself; that keeps the "C++ only where LLVM is linked" rule true. |
| **The Julia quantum language**, REPL, research laboratory | **Julia (Bennett.jl)** | Bennett is the family name: Bennett.jl *is* the Julia quantum language (`when`, oracles, in-place regions, certificates, `@cost`), the first front end built on the dialect, and the product's face. The former Sturm.jl is sunset; its surface constructs and its MCX kernel are absorbed here. Bennett.jl orchestrates the driver in-process through LLVM.jl while the LLVM tools themselves run out of process; new lowerings and arithmetic are prototyped here against the spec. |
| Arithmetic and runtime libraries (adders, multipliers, QROM, soft-float, allocator shims, libc, device models) | **Any** | Ordinary code compiled through the same pipeline and shipped as ISA objects with certificates. "Runtimes are libraries" applies to arithmetic too; the specialiser links them. |

Consequence: the centre of gravity leaves Julia. Bennett.jl is the front
door of Bennett, not the whole of it. The maintainer has stated this is
acceptable; the north star outranks language preference.

### 6.1 Many small repositories, two contracts, fully enumerated

**A monolith will grind to a halt** (maintainer, 2026-10-28). Independent
repositories, each developable, versioned, tested, and released on its
own, communicating only through **two published contracts**:

- **`bennett-dialect-spec`**: the marker-function ABI (names, signatures,
  the positive legality requirement), the portable handle convention, the
  outlining, budget and region well-formedness conventions, the legality
  conformance corpus, the driver's plugin-invocation interface,
  versioning.
- **`bennett-isa-spec`**: everything in §4.4: instruction set and formal
  model, resource vector and target-description format with capabilities,
  object and link format with the reversible ABI, host–device launch ABI
  (including how host code that interleaves genuine host effects with
  handle or measurement manipulation is split from the device's
  classical-control tier), scheduling interface, certificate schema,
  coverage-report format, serialisation, conformance suite. Its sub-
  artefacts (ISA, object format, launch ABI, certificate schema) are
  versioned independently.

Nothing shares code across a contract boundary; anything that needs to is
a sign the boundary is wrong. **One semantics comes from the ISA spec's
formal model and conformance suite, never from shared code.** The dialect
spec additionally carries a **reference semantics** from marker programs
to the ISA formal model (including the copy, store and in-place rules of
§4.2), so a competing plugin is conformance-tested at spec level and not
only by native differential. **Binary edges are versioned too:** a
`bennett-sched` built against ISA spec vN is replaceable without
rebuilding the plugin, and a plugin is replaceable without rebuilding the
driver; the substitutability test covers binary edges as well as document
edges.

| Repository | Owns | Depends on |
|---|---|---|
| `bennett-dialect-spec` | as above, plus the normalisation rules and residual-poison validator | ISA spec (its reference semantics targets the ISA formal model) |
| `bennett-isa-spec` | as above | nothing |
| `bennett-sched` | scheduler and cost model behind the ISA spec's scheduling interface | ISA spec |
| `bennett-plugin` | the C++ LLVM pass plugin; built per LLVM major | dialect spec, ISA spec, sched (binary) |
| `bennett-driver` | link-time driver: bitcode merge, plugin invocation, fat objects, launch, coverage reports; per-front-end integration | dialect spec, ISA spec, plugin (binary) |
| `bennett-vm` | the Rust device runtime: classical-control tier, history layers, effect tape, device models, branch-enumeration simulation, launch-time lowering to the target alphabet, JIT tier | ISA spec, sched |
| `bennett-circuits` | the bounded specialiser: hierarchical circuit IR, placement, proof-carrying output, exporters (OpenQASM 3, QIR, Quil) | ISA spec, sched |
| `bennett-estimate` | resource estimation from ISA objects, certificates and target descriptions, no gates materialised | ISA spec |
| `bennett-targets` | target descriptions per hardware model, contributed by vendors; importers for existing resource-model formats | ISA spec |
| `bennett-runtimes` | allocator, libc/musl shims, device models, Julia shim runtime, bitcode builds of language runtimes, as ordinary code compiled to ISA objects | dialect spec; driver (build tool) |
| `bennett-arith` | adders, multipliers, QROM, soft-float, as ISA library objects with certificates | dialect spec; driver (build tool) |
| `Bennett.jl` | the Julia quantum language: `when`, oracles, in-place regions, certificate kinds, simulators as VM targets, REPL, `@cost`, research lab | driver (binary), ISA spec |
| `bennett-conformance` | the demo ladder as executable gates, the certificate checker, the legality corpus runner, the differential harness with the instrumented classifiers of §3.2 | everything, as a consumer only |

The test of the split: every repository can be replaced by a competitor's
implementation of the same spec without the rest noticing.

## 7. Landscape: what is taken, what is rejected, what is new

| System | What Bennett takes | What it does differently |
|---|---|---|
| **Enzyme** | The delivery model: an LLVM plugin, marker calls, optimise–transform–optimise, LTO for cross-TU bodies, per-LLVM-major builds; activity analysis as the precedent for taint analysis. | Reversibilisation instead of differentiation; the output is a program for a second executor, not more LLVM IR. |
| **PTX / CUDA, OpenMP offload** | Virtual ISA with per-hardware target descriptions; host/device split; fat objects; a launch runtime. | We own the driver and launch runtime; nothing is reused from clang's offload machinery. |
| **Quil / QAM, eQASM, Knill's QRAM model** | The idea of a public abstract machine with a classical controller; Quil as an import/export format. | Those machines execute hand-built circuits with classical control; none has virtual allocation classes, garbage as a resource, bounded coherent control over arbitrary programs, linking, or a resource vector. |
| **QIR** (QIR Alliance) | LLVM as the carrier; profiles as a warning. Its adaptive profile and memory-management spec exist and are read on import. | Stated precisely: qubits are opaque pointers with no ownership discipline (they do participate in SSA dataflow); adjoint and controlled bodies are emitted by the front end as separate functions, so the IR carries no structural algebra over them; no uncomputation, garbage, resource model, or oracle abstraction; the profiles mix "program the host runs" with "circuit the device executes". Bennett keeps control and adjoint structural, keeps ownership explicit in the ISA, and puts resources in the spec. |
| **OpenQASM 3** | `ctrl@` / `inv@` modifiers and its dynamic classical control as the export target's expectations. | OpenQASM 3's dynamic control is classical control (§4.2); it is a circuit language, not a program model with memory, linking, or resources. Export only. |
| **CUDA-Q / Quake** | Quantum kernels as device code; `cudaq::control` / `cudaq::adjoint` at function granularity; the ref-vs-wire distinction, adopted as dialect-vs-ISA. | Not a new language or kernel annotation: taint is inferred over unmodified C, Rust, Julia. The carrier is LLVM bitcode, because that is what every front end emits; MLIR lowering paths are an import door. |
| **Catalyst, MLIR quantum dialects, Qrisp** | Import path for programs already in those dialects; precedent for a JIT tier; Qrisp's automatic uncomputation over Python-level programs. | Arbitrary LLVM programs, not a Python-hosted language. |
| **Q#** | Adj+Ctl specialisation from one body. | Specialisation in the plugin over any language's IR, not in one language's compiler. |
| **Quipper** | Oracle synthesis from classical code; `with_computed`. | Any LLVM language; a VM and ISA beneath. |
| **Silq, Unqomp, Reqomp, SQUARE** | Automatic and budgeted uncomputation; garbage as a resource with a budget; **the uncomputation-validity condition of §4.2 is Silq's `qfree`/`const` discipline and Unqomp's criterion, adopted as an ISA invariant.** | Uncomputation scheduled at run time by the VM as well as at compile time, under a target's resource vector, inside that invariant. |
| **Quantum Control Machine (Yuan, Villanyi, Carbin 2023)** | The injectivity and synchronisation analysis of quantum control flow, which the step machine of §4.2 must satisfy. | Bennett's embedding preserves classical inputs through the oracle interface and cleans control state at region exit, rather than lifting unrestricted quantum control flow. |
| **QCOR / XACC, Qiskit classical-function compiler, tweedledum / RevKit, ProjectQ Compute/Uncompute, REVS (Parent–Roetteler–Svore)** | C++ quantum kernels through a clang plugin with compute/action/uncompute and automatic ctrl/adjoint; oracle synthesis from classical functions; the compute/uncompute idiom. | Whole programs in any LLVM language rather than annotated kernels or small classical-function languages; a VM and ISA beneath. |
| **Tower, Spire** | Superposed pointers and classically bounded recursion as the right semantics for coherent data structures; Spire's accounting of the cost of padded coherent control. | The same semantics, for programs nobody rewrote; the step machine of §4.2 is the general case. |
| **Qualtran, Azure RE** | Symbolic, hierarchical resource counting without materialised gates; target models as data. | Certificates attached to linkable objects; the target-description format accepts imported models, converting units where they align with the target's declared resources and otherwise importing them as new named resources. |
| **QSSA, QIRO, HUGR / Guppy / tket2** | Linear SSA for quantum values; HUGR's hierarchical hybrid graph and Guppy's Python-embedded typed quantum language as the closest contemporary program-level IR. | Used in the ISA, not imposed on LLVM IR; HUGR is an import/export door. |
| **ReVerC** | Verified reversible compilation of a small language. | Correctness by theorem plus oracle (§5.1) for arbitrary LLVM input. |
| **Reversible pebbling (Bennett 89, Knill 95, PRS15, Chan et al.)** | The space-time trade-off theory and its hardness result. | Pebbling as run-time policy over a resource vector, not only a compile-time choice. |

**What is new**, claimed narrowly: (a) inferred-taint reversibilisation of
unmodified programs in any LLVM language, delivered as a link-time plugin,
with total coherent regions and a fault outcome; (b) a public virtual ISA
for quantum programs with virtual qubits, allocation classes, bounded
coherent control of arbitrary CFGs, garbage as a scheduled resource, a
resource vector, linking, and a host–device ABI; (c) one scheduler used at
compile time and run time behind a published interface; (d) correctness
defined by the permutation theorem plus channel-comparison oracles,
attached to linkable objects as certificates that separate proof from
evidence. Everything else is adopted from the systems above with
attribution.

## 8. Demo ladder (success criteria, each with its acceptance test)

| Rung | Demo | Acceptance test |
|---|---|---|
| 1 | Scalar C, Rust, Julia functions | Exhaustive at Int8 over the full domain D of §5.1 part 1, both executors equal to native; fault rate zero. |
| 2 | Pointers, structs, byte memory | A C hashtable (the existing 258-line corpus): forward result equal to native on every tested input (independent check), then reversed byte-exactly, both executors. |
| 3 | musl hello-world | Forward output equal to native; run in the reversible tier with a console device model; un-run to the reset state; tape replay deterministic. |
| 4 | **Grover over SQLite** | SQLite compiled unmodified to the coherent tier under a region budget, with an in-memory VFS over quantum-addressed memory. Database of N rows fixed classically before entry; the predicate is a real SQL query parameterised by a `rowid` bound from the superposed register; the oracle bit is the query's match for that row. (a) Oracle verified by §5.1 part 1 over all rows and all target values for N ≤ 2¹⁰, fault rate zero. (b) End-to-end Grover by state-vector simulation with branch enumeration at N ≤ 2⁸. (c) A resource estimate for N = 2²⁰ under a named target, reporting the budget and the padded cost. Nobody rewrote SQLite. |
| 5 | Julia on a shim runtime | `push!` and `Dict` work because the allocator works, with zero compiler awareness of either; forward results equal to native Julia; reversal exact. |
| 6 | xv6, then Linux `tinyconfig` | Serial console output equal to a native (QEMU) run of the same image (independent forward check); boots in the reversible tier with device models; un-boots to the reset vector; tape replay byte-identical. |
| 7 | **Quantum fuzzing of the kernel** | Kernel state snapshot fixed classically after boot; a step budget; syscall arguments as the superposed input over a declared small space; devices virtualised; the oracle bit is the panic flag. The contract is the optimised-IR reference semantics of §3.2 under a recorded definedness assumption; the kernel's own source UB is not detected after optimisation and is not claimed to be. (a) Oracle verified by §5.1 part 1 against native execution of the same snapshot per basis input, with classifier-flagged inputs reported, fault rate zero on the declared space. (b) Amplitude amplification by state-vector simulation at a toy argument space. (c) A resource estimate under a named target. The oracle is Linux. |
| 8 | **Amplitude estimation on a Monte Carlo in plain C** | Written by someone who has never heard of a Toffoli gate. The entropy device is replaced by a superposed register; everything else is fixed classically before entry. (a) Oracle by §5.1 part 1; (b) estimation by simulation at small precision; (c) resource estimate. |

Rungs 1–3 and 5–6 are the blueprint's; 4, 7, 8 define success for the
vision; nobody promises 6–8 on a schedule.

## 9. Open technical questions (deferred by the maintainer's rule: vision first)

In the order the next iteration should take them. Items the council
promoted from "detail" to "load-bearing" are now answered at vision level
above and appear here only for their mechanics.

1. **The legality spike** (§3.2): the marker corpus against every stock
   pass at O3 and through native codegen; emission examples from clang,
   rustc and Julia; gate on freezing the dialect spec.
2. **Handle → wire conversion**: the verifier, what it rejects (including
   the uncomputation-validity invariant and the copy/store/in-place rules
   of §4.2), the leak check.
3. **Compilation model mechanics** (§3.3): LTO extension point vs `opt`;
   fat-object layout; the launch ABI; host-triple intrinsic and asm
   classification tables; bitcode builds of language runtimes.
4. **Budget mechanics**: out-of-band budget tables; scalar-evolution
   refinement; how the specialiser recovers structure from the step
   machine; the exact fault-code set.
5. **Effect virtualisation**: which device models exist (VFS, console,
   clock, entropy, block device, network as a recorded peer), how they are
   expressed as reversible state, what is refused.
6. **Measurement-based uncomputation under control**: the v1
   `PermClean`-style certificate (inherited from the sunset Sturm.jl)
   cannot express it; the certificate kind with classical fixup and its
   controlled form, fixed in Bennett.jl's language before any gate record
   freezes.
7. **Reversible ABI and linking**: call/uncall convention, shared ancilla
   frames, structural symbol resolution, content-addressed objects.
8. **Run-time scheduling policy**: history layers, checkpoint interval,
   delta quality, recomputation of coherent regions, as resource policy
   under the vector of §4.3.
9. **ISA serialisation and versioning**; conformance suite; the formal
   model's scope.
10. **Per-LLVM-major builds**; Julia in-process invocation through LLVM.jl.
11. Concurrency (sequentialised with a recorded schedule; the single-
    thread assumption of §3.2 is the v1 contract), self-modifying code,
    signals, setjmp. Floating point is decided in §3.2 (deterministic
    soft-float in both builds) and is no longer open.
12. Repository hosting and release mechanics for §6.1.

## 10. Process

Vision first (this document), iterate with the council, then design, then
spikes, then code. The current Bennett.jl and BennettVM.jl are frozen as
the v1 reference and differential oracle. No reboot code is written on the
strength of this document. Worklog, beads, red-green, exhaustive
verification, no remote CI carry over unchanged.


# The document under review (round 2 snapshot)

# Bennett Virtual ISA — Specification, draft 0.2

**Date:** 2026-10-28. **Status:** second normative draft, for council
iteration (round 1 report: `docs/council/isa-2026-10-28/round-1/`; all
three members "revise"; the editor's response is in `round-1/response.md`).
This document is the founding text of the `bennett-isa-spec` repository
defined in `Bennett-NorthStar.md` §4.4 and §6.1; the north star governs
where this draft is silent. Nothing is implemented. MUST, MUST NOT, SHOULD
and MAY are normative. *(non-normative)* marks explanation; *(deferred)*
marks items this draft leaves open and asserts to be non-semantic.

**Versioning.** The ISA, the object format, the launch ABI, the scheduling
interface, the certificate schema and the coverage-report format are
versioned independently (semantic versioning); a conformant implementation
declares each. This draft is ISA 0.2, object 0.2, launch 0.2, sched 0.2,
cert 0.2, coverage 0.2.

---

## 1. Scope and conformance

### 1.1 What the ISA is

A program model for classical, reversible and coherent computation with a
single semantics, executed by the **virtual machine** (`bennett-vm`) and
the **circuit specialiser** (`bennett-circuits`), produced by the LLVM
plugin (`bennett-plugin`) through the dialect's reference semantics
(`bennett-dialect-spec`), scheduled through §11, and described for
hardware by target descriptions (§8). Nothing here refers to LLVM.

### 1.2 Conformance classes

| Class | Who | Obligation |
|---|---|---|
| **Executor** | VM, specialiser, hardware stacks | §3–§7 and §14 exactly; suites A–E, H (§15). |
| **Producer** | plugin, library compilers | well-formed objects (§9) and regions (§5, §6); suite F. |
| **Scheduler** | `bennett-sched` and competitors | §11; returns only schedules valid under §6; suite H. |
| **Checker** | `bennett-conformance` | validates certificates (§12) against objects without trusting producers. |
| **Target author** | hardware vendors | target descriptions conforming to §8; suite E. |

### 1.3 Deferred *(deferred, asserted non-semantic)*

Binary encodings (the canonical text of §16 is the normative interchange
form); mechanisation of §14; device models beyond the four of §7.3; the
gate-name registry process. **Fault-code values are not deferred** (§5.4):
they are quantum data and therefore semantic.

## 2. Terminology

- **Tier.** *classical-control* (CC), *reversible* (R), *coherent* (Q).
- **Wire.** One qubit. **Bundle** `wire[N]`: N wires with little-endian
  integer reading, wire 0 the least significant.
- **Register file.** In a lifted oracle, the named bundles that hold the
  lifted program's values (§3.7); they are *mutable locations*, not SSA
  values.
- **Region.** A Q-tier function with a declared interface: a **lifted
  oracle** (§5.2) or a **quantum action** (§5.3).
- **Budget.** The classical triple (steps, heap, depth) a lifted oracle
  runs under.
- **Fault register.** A caller-supplied bundle that receives the oracle's
  fault code by XOR at commit.
- **History frame.** Per machine step, the workspace that retains what
  the step displaced (§3.6).
- **Basis configuration.** An assignment of classical values to every
  wire of a region's interface and borrowed bundles.
- **Permutation gate.** `x cx ccx mcx swap`. **Diagonal gate.** `s sdg t
  tdg cz rz`. **Non-diagonal gate.** `h rx ry`.

## 3. Machine model

### 3.1 Tiers and the control invariant

```
  CC ──calls──▶ R functions (call / uncall)        CC ──calls──▶ Q regions (oracle_call / action_call)
  R  ──calls──▶ R functions and Q regions          Q  ──calls──▶ Q regions (§5.5)
```

CC code runs on the device's classical-control processor; the host reaches
the device only through §10. **No instruction in any tier makes a control
or scheduling decision that depends on the value of a wire** except
through predication (§3.5), which conditions on a wire without inspecting
it. Classical angle parameters of gates are constants fixed at region
entry; nothing superposed ever becomes classical except by `measure`.

### 3.2 State

| Component | Tier | Contents |
|---|---|---|
| classical registers | CC, R | SSA values of classical type |
| classical memory | CC, R | byte-addressed sparse map, little-endian, reads of unwritten bytes yield 0 |
| effect tape | R | append-only sequence of effect records (§7.3) |
| entropy tape | R | input sequence supplied at launch, consumed in order (§7.3) |
| R history | R | stack of history frames, one per executed R instruction (§7.4) |
| wire store | Q (CC via handles) | all live wires, each with a **role**: `input`, `target`, `fault`, `borrowed`, `mutable`, `workspace`, `register`, `memory` |
| quantum memory | Q | named regions of `wire[W]` cells (§7.2), including the oracle's `heap` and `stack` regions |
| register file | Q (oracle) | named bundles holding the lifted program's values (§3.7) |
| predicate stack | Q | stack of wires; the **active predicate** is their conjunction |
| step state | Q (oracle) | `pc : wire[P]`, `pc' : wire[P]`, internal `faulted : wire`, `code : wire[F]`, `heap_used : wire[H]`, `depth : wire[Dw]`, B history frames |
| budget | Q (oracle) | classical: steps B, heap limit, depth limit |

### 3.3 Types

```
  iN          classical integer, 1 ≤ N ≤ 128, two's complement          (CC, R)
  ptr         classical byte address; width = target.ptr_width          (CC, R)
  f64         classical binary64                                         (CC; gate angles in Q)
  wire        one qubit, linear (structured code and interfaces)
  wire[N]     bundle, linear as a unit
  reg[N]      a register-file location of width N (oracle bodies only; not linear, §3.7)
  token       classical opaque value (budgets)
```

**Linearity** applies to `wire`/`wire[N]` values in quantum actions and
at region interfaces: produced exactly once, consumed exactly once.
Register-file locations in oracle bodies are not linear; they are
mutable state re-executed every machine step (§3.6–§3.7). Operand modes
below: `in` (used, returned unchanged), `consume`, `produce`, `c`
(classical), `r` (register-file location, read), `w` (register-file
location, written by exchange).

### 3.4 Execution in CC and R

Sequential small-step execution with an instruction pointer, block
parameters instead of phi nodes, dynamic control flow, dynamic
allocation. In R every instruction has a **history rule** (§7.4) that
records exactly what it destroys, so the executor can run any finite R
trace backwards to its entry state (T4).

### 3.5 Predication in Q

Every Q instruction with unitary semantics executes controlled on the
active predicate p. `qpred w` pushes, `qunpred w` pops the same wire; the
stack is empty at region entry and exit. **Allocation, borrowing and
release are unconditional resource operations**: `qalloc`/`qborrow`/
`qfree` act for the region's static maximum regardless of predicate
values; only gates are controlled. A controlled wire-producing
instruction (`qcopy`, `qload`) allocates unconditionally and copies under
the predicate.

### 3.6 The predicated step machine *(the general construction for lifted oracles)*

A lifted oracle body is a list of instructions `I[0..n)`, each a *lifted
instruction* (§4.2) or a control instruction, with `HALT = n`. Choose P
with 2^P > n. The oracle allocates `pc`, `pc'`, `faulted`, `code`,
`heap_used`, `depth`, the register file, the `heap` and `stack` regions,
and **B history frames**, each of layout `(old_pc : wire[P], displaced :
wire[W_max], flag : wire)` where W_max is the widest register-file
location. All start clean; `pc` is XORed with the entry index 0.

One **machine step** t (1 ≤ t ≤ B), from an immutable snapshot of the
state at the start of the step:

1. **Dispatch.** For every k in 0..n inclusive compute `at_k = (pc == k)`
   into clean scratch (permutation computation from `pc`).
2. **Execute.** For every k < n, push `at_k`, execute `I[k]` (§4.2: its
   result is computed out of place into frame t's `displaced` slot, then
   `qexch`ed into the destination location, so the slot now holds the
   displaced old value; its optional comparison flag goes into frame t's
   `flag`), pop `at_k`. Exactly one `I[k]` has `at_k = 1` on any basis
   branch, so exactly one location changes per step per branch.
3. **Next pc.** For every k < n: under `at_k`, XOR the successor index
   into `pc'` (the fallthrough index `k+1` for non-control instructions;
   the selected target for `qjump`/`qbranch`/`qjumpr`; `HALT` for `ret`
   and `fault`). Under `at_HALT`, XOR `HALT` into `pc'` (**halted
   branches self-loop and change no state**).
4. **Commit pc.** `qexch pc pc'` then `qexch pc' frame_t.old_pc`: `pc`
   now holds the next index, `pc'` is clean, frame t holds the old pc.
5. **Clean dispatch.** Uncompute every `at_k` from `frame_t.old_pc`.
6. Decrement the classical step counter.

The step is a permutation of the state and its inverse is the same
sequence read backwards. Every executor MUST implement this transition
or a transformation of it that is extensionally identical on every basis
configuration (§5.7, T6). B = 0 is legal (the oracle commits `FAULT_
BUDGET_STEPS` on every input unless index 0 is HALT).

### 3.7 The register file and lifted values

A lifted oracle declares `regs: name : reg[N], …`, a result location
`result : reg[T]`, and the widths H, Dw of `heap_used`, `depth`. Every
lifted value of the source program occupies one location. Lifted
instructions read locations and write **exactly one** location by the
out-of-place-then-exchange rule of §3.6 step 2; the displaced old value
is retained in the step's history frame. Block parameters are lowered by
producers to `lift.mov` on edges (critical edges split), so no coherent
phi is needed. Locations are initialised clean at region entry;
interface inputs are copied into their locations at entry by `qcopy`
(inputs are never written).

*(non-normative)* The machine is Bennett's history construction at
instruction granularity over a register file. It costs B × (P + W_max + 1)
history wires; the specialiser recovers structure to reduce it (§5.7).

## 4. Instruction set

### 4.1 Classical control (CC, R)

| Instruction | Form | Semantics |
|---|---|---|
| `const` | `const c:iN → r` | |
| `add sub mul and or xor shl lshr ashr` | `op a b → r` | two's complement, wrap; shift by ≥ N yields 0 |
| `udiv urem sdiv srem` | `op a b → r` | divisor 0: CC traps, R records a fault record and halts (§7.4); `sdiv`/`srem` of INT_MIN by −1: CC traps, R fault record |
| `icmp` | `eq ne ult ule slt sle a b → r:i1` | |
| `select` | `select p a b → r` | |
| `zext sext trunc ptrtoint inttoptr` | | `ptr` width = `target.ptr_width` |
| `load` | `load.iN addr:ptr → r:iN` ; `load.iN.{s|z}` for sub-register widths | little-endian, unaligned permitted; CC: out-of-bounds traps; R: fault record |
| `store` | `store.iN addr:ptr v:iN` | R history rule: records the overwritten bytes |
| `alloc` / `free` | `alloc n:iN → p:ptr` ; `free p` | bump allocator; R: `free` validates and is reversed by rewinding the bump pointer |
| `br` | `br ^b(args)` / `br p ^b1(args) ^b2(args)` | block parameters |
| `call` / `uncall` / `ret` | `call @f args → results` ; `uncall @f` (R only, §9.3) ; `ret vals` | |
| `trap` | `trap` | CC traps; R fault record |
| `measure` | `measure w:consume wire[n] → r:iN` | CC only; computational-basis measurement with Born probabilities (§14.2); the little-endian integer |
| `effect` | `effect dev op args → results` | R only (§7.3) |

### 4.2 Lifted instructions (oracle bodies only; each is one budget step)

Operands are register-file locations (`r` read, `w` written). Each
computes its result out of place into the step's `displaced` slot by
permutation gates and exchanges it into `w` (§3.6).

| Instruction | Form | Semantics / fault |
|---|---|---|
| `lift.const` | `lift.const c → w` | |
| `lift.binop` | `lift.{add,sub,mul,and,or,xor,shl,lshr,ashr} a:r b:r → w` | as §4.1; shift by ≥ N yields 0 |
| `lift.div` | `lift.{udiv,urem,sdiv,srem} a:r b:r → w` | flag := (b == 0) ∨ (signed ∧ a == MIN ∧ b == −1); under flag: `fault FAULT_UB_DIV0` / `FAULT_UB_SDIV_OVERFLOW`; under ¬flag: result |
| `lift.icmp` | `lift.icmp.{pred} a:r b:r → w:reg[1]` | |
| `lift.select` | `lift.select p:r a:r b:r → w` | |
| `lift.cast` | `lift.{zext,sext,trunc} a:r → w` | |
| `lift.mov` | `lift.mov a:r → w` | copy (used for block parameters) |
| `lift.load` | `lift.load.W region a:r → w` | `qload` from the named quantum memory region at the little-endian address in `a`; the producer MUST precede it by an explicit range check (`lift.icmp` + `lift.faultif`) against the declared allocation, so out-of-range accesses fault with `FAULT_UB_MEMFAULT`; the raw `qload` is total (§4.6) |
| `lift.store` | `lift.store.W region a:r v:r` | copy `v` into the displaced slot, then `qexchm region a slot`: the cell takes `v`, the slot takes the old cell value; range check as for load |
| `lift.alloc` | `lift.alloc n:r → w:reg[ptr]` | flag := (heap_used + n > heap_limit); under flag: `fault FAULT_BUDGET_HEAP`; under ¬flag: `w := heap_base + heap_used` and `heap_used := heap_used + n` (two locations change: `heap_used`'s old value goes to the slot's upper half; frame layout accommodates this) |
| `lift.free` | `lift.free p:r` | validates only; bump allocation is rewound by the reversal |
| `lift.faultif` | `lift.faultif p:r code:c` | under `p`: `fault code` |
| `lift.call` | `lift.call k:c` | flag := (depth + 1 > depth_limit); under flag: `fault FAULT_BUDGET_DEPTH`; under ¬flag: push the return index onto the `stack` region at `sp`, `sp := sp + 1`, `depth := depth + 1`, next pc := k |
| `lift.ret` | `lift.ret` | pop: `sp := sp − 1`, `depth := depth − 1`, next pc := popped index (via the step's `qjumpr` behaviour) |
| `lift.retval` | `lift.retval v:r` | `result := v`; next pc := HALT |
| `lift.oracle_call` | `lift.oracle_call @o ins:r… tgt:w fr:w tk:token` | one outer step; runs the nested oracle (§5.5) under its own budget token; `fr` is a caller-allocated location that MUST be clean before the call |
| `lift.perm_call` | `lift.perm_call @a mut:w… ins:r…` | one outer step; calls a **permutation action** (§5.3) |

Control instructions of oracle bodies: `qjump k:c`, `qbranch p:r k1:c
k2:c`, `qjumpr a:r` (indirect, for `lift.ret`), `fault code:c` (§4.6).
Producers MUST inline non-recursive calls; recursive calls use
`lift.call`/`lift.ret`. **Budget steps:** every lifted or control
instruction executed on a basis branch is one step; callee instructions
count individually; `lift.oracle_call` and `lift.perm_call` count one.

**Reference binding.** The dialect's reference semantics maps each
materialised source instruction to exactly one lifted instruction (plus
edge `lift.mov`s for block parameters), and that mapping is versioned.
Hence the fault set of an oracle depends only on (program, budget,
dialect-mapping version, and the producer's materialisation inputs
recorded in the certificate), never on an executor's lowering.

### 4.3 Allocation

| Instruction | Form | Rules |
|---|---|---|
| `qalloc` | `qalloc class:c n:c → w:produce wire[n]` | n clean wires of class `class` (§8.2) or `any`. Unconditional (§3.5). |
| `qborrow` | `qborrow class:c n:c → w:produce wire[n]` | n wires in an unknown state, possibly entangled with external systems. The region MUST act as the identity on them (§5.6). |
| `qfree` | `qfree w:consume wire[n]` | release. Clean for `qalloc`ed wires; simulators MUST check, hardware MAY trust the certificate. |

### 4.4 Gates

Matrices in the computational basis, |0⟩ = (1,0)ᵀ, bundle ordering
little-endian (wire 0 is the least-significant tensor factor). θ is a
classical `f64` in radians, fixed at region entry.

```
  x    = [[0,1],[1,0]]             h   = (1/√2)[[1,1],[1,-1]]
  s    = diag(1, i)                sdg = diag(1, -i)
  t    = diag(1, e^{iπ/4})         tdg = diag(1, e^{-iπ/4})
  rx(θ) = exp(-iθX/2) = [[cos θ/2, -i sin θ/2], [-i sin θ/2, cos θ/2]]
  ry(θ) = exp(-iθY/2) = [[cos θ/2, -sin θ/2], [sin θ/2, cos θ/2]]
  rz(θ) = exp(-iθZ/2) = diag(e^{-iθ/2}, e^{iθ/2})
  cx, ccx, mcx(k): X on the target iff every control is |1⟩, identity otherwise (exact, no phase)
  cz   = diag(1,1,1,-1)            swap = exact exchange of two wires
```

Forms: `x a:in`, `cx c:in t:in`, `ccx c1 c2 t`, `mcx cs:in wire[k] t:in`,
`swap a b`, `h a`, `s a`, `sdg a`, `t a`, `tdg a`, `cz a b`, `rx θ a`,
`ry θ a`, `rz θ a`. All execute controlled on the active predicate.

**Decomposition legality.** A target realises a gate either natively or
through a declared decomposition (§8.3). A decomposition is conformant
only if its realised unitary **equals the specified unitary exactly,
including global phase** (because every gate may run under control,
where a global phase is observable), or lies within a stated ε of it in
**operator norm** (which is phase-sensitive and preserved under adding
controls). A relative-phase Toffoli is therefore not a conformant
realisation of `ccx` unless a certificate (§12) proves the phase cancels
in the specific context in which it is used.

### 4.5 Copy, XOR, exchange, in-place

| Instruction | Form | Semantics |
|---|---|---|
| `qcopy` | `qcopy s:in wire[n] → d:produce wire[n]` | allocate d clean (unconditional), then `cx s_i d_i` under the predicate. |
| `quncopy` | `quncopy s:in wire[n] d:consume wire[n]` | the inverse: `cx s_i d_i` under the predicate, then `qfree d` (d MUST be clean on every basis configuration; this is the explicit cleanup of a `qcopy`). |
| `qxor` | `qxor s:in wire[n] t:in wire[n]` | t_i ^= s_i |
| `qexch` | `qexch a:in wire[n] b:in wire[n]` | n `swap` |
| `qinplace` | `qinplace @g @ginv x:in wire[n] tk:token` | **WF:** `@g`, `@ginv` are **total permutation oracles** (§5.2) on the n-bit encoding: their certificates (§12) state that on every basis input of the encoding, under their declared budgets, the fault code is `FAULT_NONE` and `g∘ginv = ginv∘g = id`, checked exhaustively where the width makes that finite and otherwise carried as a library certificate. **Sem:** `t = qalloc n; f = qalloc F; lift-free: oracle_call @g (x) t f tk; qexch x t; oracle_call @ginv (x) t f tk; qfree t; qfree f`. After the second call `t` is clean because `ginv(g(x)) ⊕ g(x)`… precisely: `t` held g(x₀), is exchanged so x holds g(x₀) and t holds x₀, and `ginv(g(x₀)) = x₀` XORed into t clears it. `f` stays clean by the certificate. |

### 4.6 Quantum memory, predication, structure, faults

| Instruction | Form | Rules |
|---|---|---|
| `qregion` | `qregion name A:c W:c [image]` | declares a region of exactly 2^A cells of `wire[W]`; created at region entry from the object's **data image** for `name` (classical bytes, little-endian per cell, default all zero) by X gates; MUST be returned to its image at exit (the producer emits the inverse). |
| `qload` | `qload name a:in wire[A] → d:produce wire[W]` | d clean; for every cell i: under `a == i`, `qxor cell_i d`. Total: every address names a cell. |
| `qstore` | `qstore name a:in wire[A] v:in wire[W]` | for every i: under `a == i`, `qxor v cell_i`. |
| `qexchm` | `qexchm name a:in wire[A] v:in wire[W]` | for every i: under `a == i`, `qexch v cell_i`. |
| `qunload` | `qunload name a:in wire[A] d:consume wire[W]` | inverse of `qload` (XOR back, then `qfree d`). |
| `qpred` / `qunpred` | `qpred w:in` / `qunpred w:in` | §3.5; nested; `w` MUST NOT be modified between push and pop. |
| `qif` | `qif w:in { then } { else }` | `qpred w; then; qunpred w; x w; qpred w; else; qunpred w; x w`. Neither arm modifies `w`. |
| `qloop` | `qloop n:c { body }` ; `qloop n:c while c:in { body }` | body n times. With `while`: fresh flags c₁..cₙ are allocated; c₁ = c; c_{i+1} = c_i ∧ cond_i is computed out of place (`ccx`) after iteration i, where cond_i is a **permutation-provenance** wire (§6) of wires no iteration modifies; iteration i runs under `qpred c_i`; after the loop the flags are uncomputed in reverse order. Any other data-dependent exit in an action is ill-formed. |
| `fault` | `fault code:c` | oracle bodies only. Under the active predicate: XOR `code` into the internal `code` register, `x faulted`, next pc := HALT. Because the halted branch then self-loops, the first fault on a branch is the only fault on that branch; no zero test is needed and the operation is injective. |
| `budget` | `budget steps:c heap:c depth:c → tk:token` | classical. |

### 4.7 Region calls (structured code and CC)

| Instruction | Form |
|---|---|
| `oracle_call` | `oracle_call @o tk:token ins:in wire[*]… tgt:in wire[T] fr:in wire[F] args:c…` |
| `action_call` | `action_call @a mut:in wire[*]… ins:in wire[*]… args:c…` |
| `adj` | `adj action_call …` (§5.3); `adj oracle_call …` ≡ `oracle_call …` |
| `ctl` | `ctl w:in <call>` ≡ `qpred w; <call>; qunpred w` for calls; for a whole action the controlled unitary of §5.3 |

## 5. Regions

### 5.1 Common well-formedness

A region MUST NOT contain `measure`, `effect`, `br`, `call`, `uncall`,
`trap`, or classical memory instructions. Its predicate stack is empty at
entry and exit. Every `qalloc`ed wire is `qfree`d clean before exit by
**explicit cleanup instructions in the program text** (`quncopy`,
`qunload`, the adjoint of the computing sequence, or, in oracles, the
prefix reversal); the schedule (§11) chooses only the *realisation* of
each cleanup. Every `qborrow`ed bundle is returned to the identity (§5.6).
Every quantum memory region is returned to its image. **Action call
graphs MUST be acyclic**; oracles MAY be recursive only through
`lift.call` under the depth budget.

### 5.2 Lifted oracle

**Interface.** `oracle @o (ins: wire[*]…, tgt: wire[T], fr: wire[F], args: c…) regs {…} heap H stack S`.

**Body.** Lifted and control instructions only (§4.2), plus the implicit
machine of §3.6. **Permutation-only:** no gate other than the permutation
gates ever executes in an oracle body or in anything it calls; `lift.
perm_call` targets MUST be permutation actions (§5.3). Suite F rejects
anything else; a region that needs a non-permutation gate is an action.

**Contract.** On every basis configuration:

- `ins` final = `ins` initial (inputs are only read).
- `tgt` final = `tgt` initial ⊕ payload(F_B(x)).
- `fr` final = `fr` initial ⊕ code(F_B(x)).
- borrowed bundles: identity; all workspace, registers, memory regions
  and step state: clean / at image.

**F_B(x)** is defined by the reference interpreter (§14.1) run on the
body with budget B from basis input x: `(f(x), FAULT_NONE)` if it reaches
`lift.retval` within B steps without a fault, else `(0, code)` where
`code` is the first fault encountered in sequential order, or
`FAULT_BUDGET_STEPS` if it has not halted after B steps. Both halves are
XORs, so the oracle is an **involution** on `(ins, tgt, fr)`, equal to
its own adjoint, composing under control by XOR accumulation.

**Construction** (what an executor runs; T6 fixes every executor to it):

1. Allocate step state, register file, regions, B frames (all clean);
   `qcopy` each input into its location; apply the data images.
2. Run B machine steps (§3.6).
3. **Commit.** Compute `at_HALT = (pc == HALT)` into scratch. Under
   `at_HALT ∧ ¬faulted`: `qxor result tgt`. Under `faulted`: `qxor code
   fr`. Under `¬at_HALT`: XOR the constant `FAULT_BUDGET_STEPS` into `fr`
   (X gates controlled on `¬at_HALT`). The three cases are exclusive
   because `fault` jumps to HALT. Uncompute `at_HALT`.
4. **Prefix reversal.** Run the inverse of step 2 and step 1. The commit
   writes to `tgt` and `fr` are **not** reversed (they are outside the
   reversed prefix); everything else returns to clean.

**Domain D** (suite C): every value of each `ins`, of `tgt`, of `fr`, of
every borrowed bundle; `qalloc`ed wires at 0; regions at image.

### 5.3 Quantum action

**Interface.** `action @a (mut: wire[*]…, ins: wire[*]…, args: c…)`.

**Semantics.** The body denotes a unitary U_a on mut ⊗ ins ⊗ (borrowed)
that is **block-diagonal in the computational basis of `ins`** (the basis
value of every `ins` wire is unchanged; phases and entanglement between
`ins` and `mut` are part of U_a and are the action's declared behaviour),
acts as the **identity on borrowed systems** (§5.6), and returns all
workspace clean and unentangled. An action has no fault outcome of its
own; a fallible computation it needs is an `oracle_call` whose `fr` it
declares among its `mut` wires. An action whose body contains coherent
internal control (`qif`, `qloop while`) is, by definition, its padded
unitary under its declared bounds, and **those bounds are part of its
content identity** (§9.2).

**Body.** Structured: gates, `qcopy`/`quncopy`/`qxor`/`qexch`, `qload`/
`qunload`/`qstore`/`qexchm`, `qpred`/`qunpred`/`qif`/`qloop`,
`qinplace`, `oracle_call`, `action_call`, `qalloc`/`qborrow`/`qfree`.

**Permutation action.** An action whose body uses only permutation gates
(transitively). Its unitary is a permutation; it is the only kind of
action an oracle may call (`lift.perm_call`), and suite C verifies it by
the basis-tuple check over its declared permutation.

**Adjoint.** `adj @a` is the body in reverse order with each instruction
replaced by its adjoint per this table, and SSA names renamed
accordingly; the adjoint of a well-formed action is well-formed by
construction of the table:

```
  gate g(θ)        ↦ g(−θ) ; s↔sdg ; t↔tdg ; x,cx,ccx,mcx,swap,h,cz self-adjoint
  qalloc            ↦ qfree           qfree ↦ qalloc        qborrow ↦ qfree (restore ⇒ identity)
  qcopy             ↦ quncopy         quncopy ↦ qcopy       qload ↦ qunload      qunload ↦ qload
  qxor, qexch, qstore, qexchm           self-adjoint
  qinplace g ginv   ↦ qinplace ginv g
  oracle_call       ↦ oracle_call (involution)
  action_call @b    ↦ adj action_call @b
  qpred/qunpred     ↦ qunpred/qpred (the pair is reversed as a whole)
  qif w {A}{B}      ↦ qif w {adj A}{adj B}        qloop n {A} ↦ qloop n {adj A}
  qloop n while c   ↦ the flags are recomputed forward, the body adjointed under them, flags uncomputed
```

**Control.** `ctl w @a` is controlled-U_a: workspace is allocated
unconditionally, every gate of the body runs under `w` in addition to
the active predicate, cleanup runs under `w` too, so on `w = 0` the body
is the identity and all workspace is trivially clean.

### 5.4 Budgets and fault codes

Budget `(steps B, heap limit, depth limit)` is classical. B is enforced
by the machine running exactly B steps on every branch. Heap and depth
are **wire counters** `heap_used`, `depth` in the step state, updated by
`lift.alloc`/`lift.call`/`lift.ret`, compared against the classical
limits, raising faults. When two faults would trip on one instruction,
the order is: depth, then heap, then the instruction's own fault.

Fault codes (values **normative**; F ≥ 4):

```
  0 FAULT_NONE                 5 FAULT_UB_DIV0
  1 FAULT_BUDGET_STEPS         6 FAULT_UB_SDIV_OVERFLOW
  2 FAULT_BUDGET_HEAP          7 FAULT_UB_MEMFAULT
  3 FAULT_BUDGET_DEPTH         8 FAULT_EFFECT_UNMODELLED
  4 FAULT_UB_TRAP              9 FAULT_CALLEE
```

### 5.5 Nesting and nested faults

A `lift.oracle_call` inside an oracle supplies a **caller-allocated,
clean** location `fr'` for the nested fault register and a budget token
from the caller's classical args. There is **no automatic propagation**.
Fault handling is ordinary lifted code the producer emits: `lift.icmp.ne
fr' 0 → p; lift.faultif p FAULT_CALLEE`, after which `fr'` is either
retained as declared data or cleared by calling the nested oracle a
second time (involution). The nested call is one outer step; its own
steps are its own budget.

### 5.6 Borrowed systems, prefix reversal, exit synchronisation

**Borrowed systems.** A region's completed operation MUST equal its
declared operation ⊗ identity on every borrowed bundle **and on any
external system entangled with it**. Basis-value restoration is not
sufficient in general (an `s` on a borrowed wire preserves every basis
value and changes |+⟩). The discipline: borrowed wires may be acted on
**only by permutation gates**, as controls or targets, and MUST be
returned to their initial basis value on every basis configuration; by
T3 over the extended domain D this yields exactly identity on them. In
actions, borrowed wires additionally MUST NOT be controls of non-
permutation gates (that would entangle them). Legitimate correlations
among the region's own public inputs and outputs are not restricted.

**Prefix reversal** (oracles). Step 4 of §5.2 restores every non-interface
wire on every basis configuration, faulted or not, because the forward
prefix is a permutation and is inverted exactly.

**Exit synchronisation** (oracles). Every basis branch has executed
exactly B machine steps at commit; branches differ in `pc` and data until
the reversal, and the reversal returns all control workspace to clean.

### 5.7 Structure recovery

A specialiser MAY replace step-machine execution of an oracle body, or
part of it, by `qif`/`qloop` structures when it can prove the CFG
structured and the bounds static. The replacement MUST produce, on every
basis configuration in D, the same final interface tuple as §5.2's
construction (T6); suite C tests both forms against the reference
interpreter.

## 6. Uncomputation validity *(static discipline; Silq's `qfree`/`const`, Unqomp)*

Every workspace wire has a **provenance**: `perm` (computed from its
**dependency set** S, a set of wires, by permutation gates only, with S
used as controls or XOR sources) or `other`.

**Transfer rules** (computed statically over immutable value versions;
suite F checks them): `qcopy s → d`: perm, S = {s}. `qload r a → d`: perm,
S = {a} ∪ cells(r). `qxor s t`: t's provenance becomes `other` unless t
was perm with S ⊇ {s} ∪ S_t, in which case it stays perm with S ∪ S_s.
`qexch`: provenances swap. A permutation gate with controls C and target
t: t stays perm with S_t ∪ C ∪ ⋃S_c. A diagonal gate on a wire: unchanged
provenance. A non-diagonal gate on a wire: `other`. `measure`: n/a in
regions.

**Window.** A perm value g with dependency set S may be cleaned by
reversal (`quncopy`, `qunload`, the inverse sequence) or by recomputation
**only while**, since its computation: (a) every operation touching S has
used S only as controls, or been diagonal on S, or been a permutation of
S that was exactly undone again before the cleanup; and (b) g's own wires
have been used only as controls or by diagonal gates. Any other operation
on S or on g **closes the window**.

**Obligations.** Every perm value MUST be cleaned before its window would
close, and before the end of its region. A value whose window has closed
can be cleaned only by **measurement-based uncomputation with phase
fixup**, which is permitted **only** when the predicate stack is empty,
the target declares `mbu: true`, and the fixup is computed for the actual
schedule (after an intervening U the correction D becomes U D U†); it is
an executor-internal realisation verified by suite D, never an
instruction. Under any active predicate, unitary cleanup is mandatory
(the north star's fallback until a controlled-MBU certificate kind
exists). An `other` value is released only by the adjoint of the action
that produced it. A region in which some value has no valid cleanup is
ill-formed (suite F).

**Schedulers** choose only among realisations satisfying this section.

## 7. Memory and effects

### 7.1 Classical memory (CC, R)

Byte-addressed, little-endian, sparse; `alloc` is a bump allocator with
per-allocation bounds metadata used by CC traps and R fault records for
out-of-bounds access.

### 7.2 Quantum memory

`qregion name A W [image]` as §4.6; exactly 2^A cells; data image in the
object (§9.1). Lifted classical memory of an oracle is laid out by the
producer into regions (`heap` of size 2^H bytes for `lift.alloc`, `stack`
for return indices, and one region per source allocation class), recorded
in the object's `layout` section. Cost of an access is linear in the
region size unless the target declares `qram` (§8.3).

### 7.3 Effects and device models (R)

`effect dev op args → results`. Device models in this draft, each with
state, operations and inverse deltas:

| Device | State | Operations | Reversal |
|---|---|---|---|
| `console` | byte sequence | `write(bytes)` | pop the bytes |
| `clock` | counter `c` | `read() → c`; the counter advances by 1 per tape record | restore `c` |
| `entropy` | position in the **entropy tape** supplied at launch | `read(n) → bytes` consumed in order; exhaustion is an R fault record | rewind the position |
| `block` | sector map | `read(sector) → bytes`; `write(sector, bytes)` (records the overwritten bytes) | restore sectors |

A run of an R function is therefore a function of (program, initial
state, entropy tape). Each `effect` appends `(dev, op, args, results,
delta)` to the effect tape; reversal pops and applies the inverse delta.
Reversal restores device-model state; it does not and cannot retract an
external observation of the console, which is why the coherent tier
forbids effects.

### 7.4 R history rules

| Instruction | History frame records |
|---|---|
| `store` | address, width, overwritten bytes |
| lossy binops (`mul` with overflow, `and`, `or`, shifts, `udiv`…), `trunc`, `select` | the destroyed operand(s) |
| `br p …` | the taken edge |
| `alloc` / `free` | old bump pointer |
| `call` / `ret` | frame link |
| `effect` | pointer to the tape record |
| `load`, `const`, `add`, `sub`, `xor`, `icmp`, `zext`, `sext` | nothing (invertible from the result and the retained operands, which SSA keeps live) |
| fault record (`udiv` by 0, trap, out-of-bounds) | the fault cause and location; execution halts in a **terminal faulted state** that `uncall` reverses like any other prefix |

## 8. Resources and target descriptions

### 8.1 Resources and aggregation

A target declares resources, each with a **kind** that fixes how usage is
aggregated:

```
  kind count      : summed over instructions (e.g. t, cx, measurement)
  kind time       : the schedule makespan in seconds
  kind occupancy  : ∫ (live qubits of a class) dt, in qubit-seconds
  kind peak       : max over time (e.g. peak live qubits per class)
```

Every target MUST declare `qubit_second` (occupancy) per class, `time`,
and `peak_qubits` per class. **Timing model:** execution is sequential in
program order unless the schedule (§11) assigns start times; a gate
occupies its wires for its declared `time`; gates on disjoint wires MAY
overlap unless the target declares `max_parallel` or a topology; the
ISA-level machine is all-to-all over logical wires, with routing folded
into the target's decomposition costs. A wire's lifetime runs from
`qalloc`/`qborrow` to `qfree`; `qubit_second = Σ_wires lifetime × rate`,
borrowed wires charged **to the borrower at the class's `dirty_rate`,
replacing** the owner's charge for that interval. Dispatch, history,
reversal and cleanup are ordinary instructions in the lowered program and
are therefore counted like any other.

### 8.2 Qubit classes

```
  classes:
    <name>: { qubit_second: <rate>, dirty_rate: <rate>, capacity: <int | unbounded> }
```

`any` resolves to the class with the lowest `qubit_second` whose
`capacity` is not exhausted in the schedule. Two-wire gates across
classes are permitted; their cost is the declared `cross_class` cost if
present, else the costlier class's cost.

### 8.3 Gate alphabet, decompositions, capabilities

```
  ptr_width: <bits>
  gates:
    <gate>: { <resource>: <cost | fn(k) | fn(ε)>, ..., time: <seconds | fn(...)> }
  decompositions:
    <gate>: { sequence: [...native gates...], epsilon: <0 | bound in operator norm> }
  capabilities:
    qram: none | { load: <cost vector>, store: <cost vector>, exch: <cost vector> }
    measurement: { mid_circuit: bool, feedforward_latency: <seconds> }
    mbu: bool
    max_parallel: <int | unbounded>
    max_predicate_depth: <int | unbounded>
  cross_class: { <classA>,<classB>: <cost vector> }      # optional
```

`mcx` cost is a declared function of k; `rz`/`rx`/`ry` cost a declared
function of the synthesis ε the schedule assigns. A gate neither native
nor decomposable is a load-time error.

### 8.4 Objective and space budget

```
  objective: weighted { <resource>: <weight>, ... } | lexicographic [ <resource>, ... ]
```

The scheduler minimises the objective. The **space budget** passed to the
scheduler is a peak-capacity bound per class (`peak_qubits`), separate
from `qubit_second`.

### 8.5 Importing existing models

A target description MAY be generated from a Qualtran or Azure-RE model:
units aligning with a declared resource are converted; others become new
named resources of the appropriate kind.

## 9. Objects, linking, reversible ABI

### 9.1 Object sections (canonical text, §16)

```
  header      versions (isa, object, launch, sched, cert, coverage); producer id; target hint
  types       bundle widths; qregion declarations
  symbols     local index → (name, kind: cc|r|oracle|action|perm_action|data, signature, content_hash)
  imports     (name, signature, [pinned content_hash])
  functions   per local index: tier, interface, regs, body
  data        data images for qregions
  devices     device models referenced by R code
  layout      producer's mapping of lifted classical memory to qregions
  schedule    optional: a serialised §11 schedule bound to a target hash
  certificate §12
  coverage    §13
```

### 9.2 Identity and linking

**Content hash** is the sole global identity: SHA-256 over the canonical
bytes of a symbol's `signature` and `body` (for `data`, over the image;
for actions, including declared bounds), with references to other
symbols replaced by their content hashes; a strongly connected component
of mutually recursive symbols is hashed as one unit in canonical order.
Local indices are per-object aliases rewritten at link.

**Signature** = (tier, kind, wire-bundle widths in order, T, F, classical
argument types, ABI version). **Imports** resolve by name + signature,
with a link error on mismatch; a pinned hash additionally requires
equality; the resolved hash is recorded in the linked certificate. Two
definitions with equal hash deduplicate; unequal hashes under one name
are a link error; conflicting `types`/`devices`/`layout` entries are link
errors. Linking is resolution, validation, then composition of
certificates (§12), not a union of tables.

### 9.3 Reversible ABI

- **CC/R calls:** classical frame; the callee's R history frame is pushed
  on the caller's R history stack at `call` and popped by `uncall`, which
  consumes exactly that frame. `uncall @f` is well-formed only where the
  matching `call @f` is the most recent unreversed call on the current
  history stack.
- **Region calls:** the caller passes interface bundles in declared order
  and owns them; the callee owns its workspace and returns it clean. A
  callee MAY `qborrow` only from a caller-designated idle set, which it
  restores (§5.6).
- **Frame descriptors.** Every region's certificate carries a frame
  descriptor: typed interface slots, scratch requirement by class and
  cleanliness (clean / dirty-restorable), retained-history requirement
  (oracles: B × frame width), and ownership transitions. A caller MAY
  pass a **shared frame** of at least the descriptor's clean scratch only
  when the caller's own live values and history are disjoint from it for
  the duration of the call (suite F checks live ranges); reuse is never
  inferred from a peak count alone.
- **Controlled and adjoint variants** of a region use the same descriptor.

## 10. Launch ABI (host ↔ device)

**Model.** The launch entry point is a **device CC function**. The host
supplies classical arguments, budgets, and opaque register IDs naming
device-resident quantum state that persists between launches; it receives
classical results, fault codes and read-back measurements. Every
measurement whose result affects control runs in device CC. Host code
never holds a wire.

```c
  // launch 0.2 — C ABI; every function returns bennett_status (0 = ok, else an error code below)
  bennett_status bennett_load     (const uint8_t* object, size_t len, const char* target_id, bennett_program** out);
  bennett_status bennett_unload   (bennett_program*);
  bennett_status bennett_budget   (bennett_program*, const char* region, uint64_t steps, uint64_t heap, uint64_t depth, bennett_token* out);
  bennett_status bennett_qreg_new (bennett_program*, const char* cls, uint32_t n, bennett_qreg* out);   // clean |0…0⟩
  bennett_status bennett_qreg_prepare(bennett_program*, bennett_qreg, const uint8_t* bits);              // X gates on a clean register
  bennett_status bennett_qreg_free(bennett_program*, bennett_qreg);                                      // must be clean
  bennett_status bennett_run      (bennett_program*, const char* cc_entry, const bennett_arg* args, size_t nargs, bennett_run_id* out);
  bennett_status bennett_wait     (bennett_program*, bennett_run_id, bennett_result* out);                // classical results, fault codes, measurements
  bennett_status bennett_suspend  (bennett_program*, bennett_run_id);   // only at CC instruction boundaries, never inside a region
  bennett_status bennett_resume   (bennett_program*, bennett_run_id);
  bennett_status bennett_reverse  (bennett_program*, bennett_run_id);   // R: uncall to entry. Q action: U† with retained args. Q oracle: re-apply (involution).
  bennett_status bennett_tape     (bennett_program*, bennett_run_id, bennett_tape_iter* out);
  bennett_status bennett_estimate (bennett_program*, const char* region, bennett_token, const char* target_id, bennett_estimate_out* out); // no execution
  bennett_status bennett_coverage (bennett_program*, bennett_coverage_out* out);
  // errors: BENNETT_E_VERSION, _E_DEVICE_MISSING, _E_GATE_UNSUPPORTED, _E_TARGET, _E_BUDGET, _E_QREG_NOT_CLEAN, _E_INVALID_STATE, _E_SCHEDULE_INFEASIBLE
```

`bennett_run` returns an invocation id; `bennett_wait` yields results.
`bennett_reverse` on a run that invoked Q regions re-invokes them as
stated (oracles are involutions; actions run their adjoint with the
retained classical arguments and the same live registers); it is an
error (`_E_INVALID_STATE`) if those registers have been modified since.

## 11. Scheduling interface

```c
  // sched 0.2 — C ABI
  bennett_status bennett_sched_schedule(const bennett_sched_request* req, bennett_sched_response* out);
  // request: program content hash, region, target hash, objective, budget token, accuracy ε_total,
  //          capacity (peak per class), classical parameters, scheduler version
  // response: SCHEDULED | INFEASIBLE(reason) | UNSUPPORTED(feature); on SCHEDULED a serialised schedule + certificate (§12)
```

**Schedule** (serialised; may be stored in the object's `schedule`
section bound to the target hash): per cleanup, its realisation (reverse
| recompute | mbu); per allocation, its class; per gate, the decomposition
chosen and, for rotations, its ε share; start times where the schedule
parallelises; structure-recovery decisions; checkpoint and recomputation
points for R history.

**Obligations.** Every schedule MUST satisfy §6, MUST respect the capacity
bound, MUST report the full resource vector, MUST be reproducible from
the request plus scheduler version. A consumer (VM or specialiser) MUST
validate a stored schedule's bindings (program hash, target hash, budget,
ε) and either execute it **verbatim** or reject it and request a
replacement; it MUST NOT alter program semantics either way. The VM uses
the same interface at run time with the run-time budget in the request,
so its decisions depend only on classical data.

## 12. Certificate schema (machine-readable; JSON object; cert 0.2)

```
  versions:      { isa, object, launch, sched, cert, coverage }
  bindings:      { object_hash, reference_program_hash, dialect_mapping_version, target_hash, schedule_hash? }
  producer:      { name, version, materialisation: { llvm_version, pipeline, normaliser_version } }
  objective:     <as §8.4>
  regions: { <content_hash>: {
      kind:           oracle | action | perm_action
      signature:      <as §9.2>
      bounds:         { steps, heap, depth } | { action bounds }
      frame:          <frame descriptor, §9.3>
      resources:      { <resource>: <value> ... }                     # aggregated per §8.1
      gates_used:     { <gate>: { count, decomposition_hash?, epsilon? } }
      verification: {
        permutation:  { domain: <finite-domain encoding: widths and ranges per interface bundle>,
                        method: exhaustive | sampled, count, sampler: { algorithm, version, seed }, result: proof | evidence }
        channel:      { widths, metric: diamond | operator_norm, epsilon, numerical_bound: { method, bound }, result: proof | evidence }
        fault_rate:   { domain, faults: <count by code>, undefined_excluded, layout_dependent_excluded }
        inverse_pairs:[ { g, ginv, domain, method, result } ]
        borrowed:     { discipline_checked: bool, domain }
        minimality:   none | { lower_bound: { method, value }, witness_hash }
      }
      definedness_assumption: <structured: list of assumption ids from the dialect spec>
  } }
  composition:   { invocation_multiplicities: { <hash>: n }, epsilon_total: Σ n·ε, method }
```

A checker MUST validate every `proof` entry by re-execution at the stated
widths (permutation) or by re-computing the numerical bound (channel)
without trusting the producer; `evidence` entries are replayable from
`sampler`. Epsilons compose over **invocation multiplicities** (how many
times each region executes under the bounds), not over linked symbols.

## 13. Coverage report (coverage 0.2)

Per object, per function, per source construct: `{ location: <stable
reference-program location>, classification: lowered | trapped |
shimmed, reason, fault_code (trapped), shim: <bennett-runtimes symbol
hash> (shimmed), count }`.

## 14. Formal model

### 14.1 Reference interpreter *(normative)*

A sequential interpreter over oracle bodies executing **per basis
configuration**: register-file locations are bit-vectors, predication is
an `if`, lifted instructions are their classical functions, `fault`
records the code and stops, `lift.retval` stops with success, the step
counter counts executed instructions, `heap_used` and `depth` are
integers. It **defines** F_B and the budget unit. It rejects any non-
permutation gate (such a body is not an oracle).

### 14.2 Quantum state semantics *(normative)*

The state of a Q region is a vector in the Hilbert space ⊗ over live
wires in allocation order (bundles little-endian), together with the
classical budget counters. `qalloc` tensors |0⟩ factors; `qfree` of a
clean wire removes a |0⟩ factor; gates act by the matrices of §4.4,
controlled on the active predicate; `qborrow` introduces a factor in an
unknown state possibly entangled with a reference system R, and the
region's operation MUST be U ⊗ I_R with U acting as identity on the
borrowed factor (§5.6). `measure` (CC) applies the computational-basis
projective measurement with Born probabilities, yielding the little-
endian integer and consuming the wires.

### 14.3 Theorems (hypotheses explicit)

- **T1 (totality, determinism).** For every well-formed oracle, budget,
  and basis configuration x ∈ D, the reference interpreter terminates
  within B + 1 steps and F_B(x) is unique; `code` is the first fault in
  sequential order.
- **T2 (prefix reversal).** For every executor whose oracle realisation
  is a composition of permutation gates implementing §5.2 steps 1–4 (any
  decomposition whose realised unitary is exactly a permutation), on
  every x ∈ D every non-interface wire is clean after step 4 and every
  borrowed bundle holds its initial value. *(Proof sketch: steps 1–2 form
  a permutation Π; step 3 acts only on tgt and fr controlled on
  workspace; step 4 applies Π⁻¹; Π⁻¹Π = I on workspace.)*
- **T3 (permutation theorem).** If the realised unitary V of a region on
  span(D) is a permutation matrix (however decomposed), and for every x ∈
  D the final basis tuple equals P(x) for the declared permutation P
  (the oracle tuple of §5.2, or |g(x)⟩ with workspace clean for a
  permutation action), then V|span(D) = P: no relative phase, no residual
  entanglement, identity on borrowed systems.
- **T4 (round trip, R).** For every finite valid R trace with retained
  history and tape, `uncall` returns classical state, memory, device-
  model state and history to their entry values; observed external
  events are not retracted.
- **T5 (validity ⇒ cleanliness).** Under §6, a perm value cleaned within
  its window by reversal or recomputation returns exactly to |0⟩ and
  leaves the remaining state unchanged.
- **T6 (executor agreement).** Two executors conforming to §3–§7 on the
  same target with the same decompositions produce, on every x ∈ D, the
  same final tuple for every oracle (exact equality), and for every
  action unitaries within ε₁ + ε₂ in operator norm (channels: diamond
  norm) where ε_i are their certificates' totals composed over invocation
  multiplicities.

### 14.4 Mechanisation *(deferred)*

A machine-checked model of §3.6, §5.2, §5.3 (adjoint table) and §6 at
the abstract level (bits for oracles; matrices for actions at small
widths).

## 15. Conformance suites

| Suite | Class | Tests |
|---|---|---|
| A | Executor | classical ISA exhaustive at narrow widths, property-based above; R round trip (T4) with tape and entropy tape; R fault records |
| B | Executor | oracle totality and prefix reversal (T1, T2): bodies with every fault code, budget boundaries (B = 0, exact-boundary halt), nested oracle faults, borrowed restoration; faulted and non-faulted configurations |
| C | Executor, Producer | T3 over full D at exhaustive widths for oracles, permutation actions, `qinplace` pairs; T6 agreement among VM, specialiser, structure-recovered forms and the reference interpreter |
| D | Executor | channel comparison (Choi state with reference system) for non-permutation decompositions and MBU realisations; controlled-interference tests; ε accounting against the numerical bound method |
| E | Target author, Executor | resource aggregation per kind against declared units; timing model; objective evaluation; decomposition exactness or ε; cross-class costs |
| F | Producer | linearity in structured code; register-file write-once-per-step; predicate nesting; permutation-only oracle bodies; §6 transfer rules and schedulability; adjoint table; acyclic action graphs; object grammar; linking rules; frame-descriptor live-range checks |
| G | Launch | every §10 entry point; suspend/resume at CC boundaries only; reverse semantics per tier; error codes |
| H | Scheduler | returned schedules satisfy §6 and capacity; reproducibility; stored-schedule validation and verbatim execution |

## 16. Canonical textual form (normative grammar)

```
  object    := header section*
  header    := "bennett-object" version-list NEWLINE
  section   := "section" NAME NEWLINE line*
  function  := ("fn" TIER | "oracle" | "action" | "perm_action") NAME "(" params ")" attrs? NEWLINE block+
  params    := (param ("," param)*)?
  param     := NAME ":" type
  type      := "i" INT | "ptr" | "f64" | "wire" | "wire[" INT "]" | "reg[" INT "]" | "token"
  attrs     := "regs" "{" (NAME ":" type ("," NAME ":" type)*)? "}" ("heap" INT)? ("stack" INT)? ("bounds" "{" INT ("," INT)* "}")?
  block     := "^" NAME "(" params ")" ":" NEWLINE instr+
  instr     := (results "=")? OPCODE operand* ("{" NEWLINE instr+ "}" ("{" NEWLINE instr+ "}")?)? NEWLINE
  results   := NAME ("," NAME)*
  operand   := NAME | "@" NAME | "^" NAME ("(" (NAME ("," NAME)*)? ")")? | INT | FLOAT | STRING
  version-list := NAME "=" INT "." INT ("," NAME "=" INT "." INT)*
```

Whitespace: one instruction per line, single spaces between tokens, no
trailing spaces, LF line endings, UTF-8; integers decimal; floats in the
shortest round-trip representation; names `[A-Za-z_][A-Za-z0-9_.]*`.
These rules make the canonical bytes unique, so content hashes (§9.2)
are well-defined. A binary encoding *(deferred)* MUST round-trip through
this form. An executor MUST refuse an object whose ISA major differs
from its own and MAY accept a lower minor.

## 17. Open items *(deferred, asserted non-semantic)*

1. Binary encoding.
2. Gate-name registry process.
3. Device models beyond the four of §7.3.
4. Mechanisation of §14.
5. The exact bit layout of `bennett_arg`, `bennett_result`, `bennett_
   estimate_out`, `bennett_coverage_out` (their fields are those named in
   §10, §12, §13).
