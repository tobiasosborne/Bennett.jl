# Council

You are a member of a three-model council grading the document below, the third normative draft (0.3) of the Bennett virtual ISA specification (the bennett-isa-spec contract named in the north-star document supplied as background). Grade it against the rubric on the absolute scale. Be exacting and skeptical: verify every technical premise against your own knowledge; name any that is false. Grade the vision for being the right vision, stated precisely; do not deduct for things that are not built yet. A blocking issue is one that would make the project build the wrong thing if uncorrected; everything else is a suggestion. Return `accept` only if the blocking list is empty.

Be constructive, not only critical: for every blocking issue the `fix` field must say concretely how to overcome it, at vision level (the sentence or semantics the document should state, or the decision it should take), not merely that it is wrong. Where you see two viable ways out, name both and say which you would take. In `path_to_accept`, state the minimal set of changes that would make you return `accept`; if you already accept, say what would raise the lowest-scoring criterion by one point.

You may read the repository you are running in (read-only) to check claims about the current code; its root contains Bennett-NorthStar.md (the document, identical to the snapshot below), Bennett-Reboot-Blueprint.md and Bennett-V2-PRD.md (the superseded plans), worklog/ (session logs; chunk 121 has the 2026-10-28 ground-truth survey), reviews/2026-09-26-astra/ (the last review campaign), and src/ (the deprecated v1). Reading is optional; the snapshot below is what you grade.

Answer only with JSON matching the schema.

# Previous round (2)

Verdicts: codex: revise, muse: revise, opus: revise

Blocking issues raised last round:
- [codex] B1 (§§3.6–3.7, 4.2, 5.2, 14.1): The prescribed transition does not implement its instruction set. A frame has only W_max displaced bits, yet lift.alloc explicitly needs an additional old heap counter; calls, returns and nested calls modify several locations. The next-pc table also does not consistently cover lift.call, lift.ret, lift.retval and conditional faults. Finally, falling off the instruction list reaches HALT and commits success, whereas F_B defines success through lift.retval. An empty body has the same mismatch, and an out-of-range qjumpr reaches a pc for which no dispatch predicate is true. Fix proposed: Define each instruction as a transition producing a write set, successor and outcome from the old state. Give history enough typed slots for every displaced value, or explicitly implement particular updates reversibly without saving them; I recommend opcode-specific frames padded to a declared maximum. Make fault and return successors authoritative. Either prohibit fallthrough to HALT and empty bodies, or define their result explicitly in both interpreters. Validate indirect targets and specify their fault behavior.
- [codex] B2 (§§3.2, 3.7, 4.2 lift.call/lift.ret/lift.alloc, 5.4): The recursive execution model is incomplete. sp is used but absent from the declared state, and the stack saves only return indices. Recursive invocations reuse the same register-file locations without a rule restoring caller locals during forward return; eventual prefix reversal does not solve that problem. Counter widths are also unconstrained: an H-bit heap_used cannot represent full occupancy of the declared 2^H-byte heap, and wrapped addition can disagree with the reference interpreter's integer comparison. Fix proposed: Specify activation records, argument/result placement, saved caller values, sp, entry depth, return behavior and stack underflow/overflow. Either provide activation-local register banks or mandate an explicit spill/restore convention; I would use a defined activation-frame convention. Require counter widths and widened comparisons sufficient for every allowed limit and prospective increment, with no modular wrap before a budget check.
- [codex] B3 (§4.2 reference binding; §3.7 block parameters; §14.1): The one-to-one reference-binding claim is not established by the rules given. A load requires additional range-check instructions, block parameters require edge moves, and mandatory inlining changes the instruction sequence. These operations are all charged as steps. Moreover, ordinary sequential moves do not implement parallel block-parameter assignment in cycles: assigning (a,b) := (b,a) requires preserved old values. Different expansion choices can therefore change both results and budget faults. Fix proposed: Freeze a canonical reference program and accounting version before executable transformations. Either make checked accesses and parallel edge assignments atomic reference instructions, or define a canonical expansion with explicit accounting for every helper instruction. I recommend atomic reference operations with separately accounted implementation microsteps. Specify call/inlining charges and require every lowering to preserve the resulting bounded F_B.
- [codex] B4 (§§4.1–4.2, 7.1–7.2, 8.3): The memory model still leaves observable behavior undecided. lift.free 'validates only', without defining removal from the live-allocation set, so use-after-free checks have no specified state to consult. The byte heap and lift.load.W/store.W forms do not explain multi-byte accesses through fixed-width qregion cells, address-to-region translation or accesses crossing allocation boundaries. Allocation bases, alignment, zero-size allocation, invalid free and pointer overflow are also unspecified. Taking pointer width from the hardware target can change the meaning of an object compiled from a fixed source layout. Fix proposed: Define allocation metadata and its reversible updates, byte-range validity for the entire access, pointer translation, alignment, initialization and free behavior. State whether freed storage is reclaimed or merely marked dead; monotonic allocation with explicit dead-allocation metadata is a viable initial choice. Define multi-byte accesses over byte cells. Put the semantic pointer width and address layout in the object/reference contract, and require targets to implement that layout.
- [codex] B5 (§§3.3, 4.1, 4.4–4.7, 5.1, 9.2): Structured instructions still lack a consistent ownership and typing contract. The mode 'in' means returned unchanged, but x, qxor and qexch change those operands; their forms do not produce the successor SSA values required by linearity. Named quantum memory has no equivalent ownership-threading rule. Interface aliasing is not explicitly prohibited, although aliasing an oracle input with its XOR target can make the specified map non-injective. Several operand-width rules, signed division/remainder conventions and measurement result-width constraints remain implicit. Fix proposed: Choose actual linear SSA with explicit successor wire versions, or a reference-based ownership model; I recommend retaining SSA and spelling out consume-and-reproduce operands. Define equivalent ownership for memory and calls, disjointness requirements for interfaces and gate operands, and complete the remaining numeric typing rules. Include interface roles and their partition in function signatures.
- [codex] B6 (§4.6 qloop; §5.3 adjoint table; §§9.3, 14.2): The adjoint table is not complete enough to justify 'well-formed by construction'. Reversing release of a borrowed system into qalloc replaces unknown borrowed state with clean allocation; it is not the inverse ownership transition. The formal qfree rule only removes a clean factor. The while-loop syntax also never binds cond_i, allocates c_1 through c_n while describing c_{i+1} after iteration i, and does not precisely specify inverse iteration order or n=0. Fix proposed: Distinguish clean release from borrowed return and give each a matched inverse resource operation, preserving borrowed-system identity and ownership. Define while-loop condition operands or a condition-producing subregion, the exact flag range, zero-iteration behavior and cleanup. The adjoint must recompute the same immutable predicates, execute iteration adjoints in reverse order, then erase the flags. Validate frame descriptors for these derived forms.
- [codex] B7 (§5.6 borrowed systems; §6; §12 borrowed verification): The asserted sufficient discipline for borrowed systems is false. With borrowed b and clean a, CX(b,a); S(a); CX(b,a) returns a clean and preserves every computational-basis value of b. The borrowed wire participates only in permutation gates and never directly controls a non-permutation gate, yet the operation applies S to b. For b=|+>, its restoration fidelity is 1/2. Even a wholly permutation computation can preserve b's value while making public outputs depend on b. Fix proposed: Retain the correct completed-operation requirement V_public tensor I_borrowed, but stop deriving it from the stated local discipline. Require a checked whole-frame independence and phase-restoration proof, including arbitrary reference systems. A conservative alternative is transitive borrowed-dependence tracking that forbids dependent non-permutation operations until restoration; I would support certified restoration frames and use that conservative rule elsewhere.
- [codex] B8 (§6; T5; suites D and F): The validity rules remain incomplete and internally inconsistent. A predicated qcopy depends on its predicate as well as its source, but its transfer rule records only the source. Calls, memory writes and aliases lack complete transfer rules. The unconditional MUST-clean-before-window-close rule still conflicts with the subsequent MBU exception. T5's claim that cleanup leaves the remaining state unchanged is also literally false: erasing the copy from a Bell pair changes the source's reduced density matrix from mixed to pure. Fix proposed: Track immutable value versions, active predicates, memory versions and call summaries, and state cleanup preconditions over those versions. Restate T5 as coherent erasure of a known encoding with preservation of the corresponding logical amplitudes and intended phases. Either prohibit closed-window MBU in this draft, or define an explicit certified frame rewrite with a reference channel/instrument, outcome semantics and realizable correction. I recommend the prohibition until that exchange contract is specified.
- [codex] B9 (§4.2 lift.oracle_call; §5.5): The proposed nested-fault cleanup cannot satisfy its own well-formedness rule. Every lift.oracle_call requires a clean fr location, but after a nested fault fr is nonzero, so calling the oracle a second time to clear it is forbidden. The text also does not state the input and target-version correspondence required for such cleanup. Fix proposed: Require a clean local fault register only when computing a fresh fault outcome, and define an explicit matched inverse/cleanup invocation that accepts the resulting nonzero register with the original inputs and corresponding targets. Alternatively retain the nested result until the outer prefix reversal and remove the second-call prescription. I recommend an explicit matched cleanup form for reusable local registers.
- [codex] B10 (§§4.4, 5.2–5.3, 8.3, 12; T6): Exact permutation semantics and target approximation are not reconciled. The literal prohibition on any non-permutation gate ever executing in an oracle excludes exact Clifford+T implementations of permutation gates, while the general decomposition rule permits epsilon-approximate realizations that cannot support exact oracle equality. Angle operands also admit non-finite f64 values without a unitary interpretation. Finally, operator-norm and diamond-norm error totals need distinct accounting: an operator bound epsilon generally gives a channel bound at most 2 epsilon, not epsilon. Fix proposed: Define permutation status by the realized operation at the relevant logical boundary, allowing exact phase-correct decompositions with non-permutation intermediate gates. Require exact permutation realizations for the exact oracle contract, or explicitly introduce a separate approximate contract; I recommend retaining exact oracles. Require finite angles. Define accepted accuracy constraints and typed error composition, including operator-to-channel conversion and invocation multiplicities.
- [codex] B11 (§§3.4, 7.3–7.4, 9.3; T4): R execution is still not independently reproducible. The device table lacks typed/versioned operation contracts, block-sector size and missing-sector behavior, precise clock tick ordering and entropy-exhaustion fault semantics. History rules do not fully cover allocation metadata or Q calls. Matching the most recent call name is insufficient to establish that uncall is at the corresponding return state when intervening instructions have changed dependencies. Fix proposed: Specify typed device operations and deterministic state transitions, including all failure cases and the launch-supplied environmental trace. Complete the abstract history/inverse rules, including Q adjoints and oracle reinvocation. Bind uncall to a dynamic invocation and require its return-state dependencies to be restored, or explicitly reverse the intervening history suffix first. State T4 over those conditions.
- [codex] B12 (§§8.1–8.5, 11): The resource aggregation rules are improved, but target descriptions still cannot price or validate the actual execution unambiguously. 'The costlier class's cost' has no definition for a resource vector, and the gate schema does not provide the corresponding per-class costs. Predication introduces controlled gates whose legality and costs are not covered by mcx's k parameter alone. Cost-function syntax, public-register lifetimes and the unit-conversion rule for imported models remain unspecified. Fix proposed: Define gate legality and cost as functions of opcode, operand classes, arity, control count, parameters and accuracy, with a serializable expression/table format. Specify occupancy intervals for all public and internal wires. Replace the costlier-class fallback with an explicit uniform-cost rule or class-indexed table; I recommend the table. Validate rates, durations and objective weights, and publish versioned unit mappings for supported imports.
- [codex] B13 (§16 and the metadata formats in §§8–13): The canonical grammar does not define an interchange language. object reaches section and then an undefined line production; function is never connected to that grammar. Section payloads, metadata collections, string escaping and several lexical productions are absent. Single-space formatting and shortest-round-trip floats do not establish canonical ordering or unique serialization of the unspecified structures. Fix proposed: Complete the grammar for every normative section and define canonical ordering, escaping, numeric spelling and duplicate-field handling. Alternatively adopt a fully specified canonical structured format for metadata and a complete instruction grammar for bodies. Supply at least one complete object whose bytes and expected hashes follow solely from those rules.
- [codex] B14 (§§9.1–9.3, 12): Content identity still omits or leaves ambiguous semantic inputs such as register declarations, memory layout/images and semantic versions. Hashing an SCC 'as one unit in canonical order' does not define internal references or distinct member identities. It is also unclear when unresolved imports acquire resolved hashes, and whether object_hash includes the certificate containing object_hash. Signatures omit an explicit mut/ins role partition. Fix proposed: Define a semantic hashing envelope containing all execution-relevant declarations and resolved dependencies, excluding self-referential certificates and schedules. For SCCs, encode internal references by canonical member indices and derive member identities from the SCC hash plus index. Distinguish relocatable identity from resolved executable identity and rebind certificates after linking. Include complete role, layout and ABI information in signatures.
- [codex] B15 (§10; §3.1; suite G): The launch state machine remains undefined despite the new entry points. Every run starts a CC function, but reverse is described by R/Q cases without specifying how a mixed CC trace is inverted, the order of multiple Q inverses, or which traces are eligible. Measurement and consumed handles require explicit invalidation rules. The required split for native host effects interleaved with device CC also has no yield/request/resume protocol. Fix proposed: Define invocation states, handle ownership/versioning, suspension completion and reverse eligibility. Either restrict reversible launches to recorded reversible entry wrappers, or expose region-invocation identities within CC runs; I recommend explicit invocation identities and reverse-order inversion of eligible traces. Reject reversal across measurements or missing dependencies. Specify that readback occurs through declared measurements and add a classical host-service handoff/resume protocol.
- [codex] B16 (§§10–11, 17.5): The C declarations do not yet provide substitutable binary interfaces. Callers must construct or allocate argument, result, request and response objects whose types, fields, ownership and lifetime are not defined, and no opaque-object constructors/accessors substitute for them. The scheduler receives hashes without a content-resolution contract. Its serializable schedule is still a prose list, and validation omits bindings such as classical parameters, action bounds and control variants. Fix proposed: Provide complete versioned public types and ownership rules, or opaque request/result objects with constructors/accessors and fully specified serialized payloads; either preserves deferred object encodings. Define how schedulers obtain program/target contents, and give schedules stable operation/iteration identifiers and exact realization records. Bind applicability to all semantic parameters, budgets, controls, accuracy and capacity constraints, with explicit validation and failure results.
- [codex] B17 (§§12–13, 15): The certificate is still a schema sketch, particularly where the document relies on compositional proofs. Permutation verification offers only exhaustive or sampled execution, yet qinplace and borrowed restoration rely on library/structural certificates. Domain ranges, sampler algorithms, numerical-bound methods and proof payloads lack normative encodings and checker semantics. Coverage locations likewise have no defined stable identifier format. Error composition does not distinguish local error from already-composed region totals. Fix proposed: Define executable schemas for exhaustive, sampled, structural and rigorous numerical claims, each with a versioned checker and bound assumptions. Specify finite domains and sampling exactly, and define channel-bound validation rather than treating arbitrary numerical agreement as proof. Separate local and inclusive error totals to prevent double counting. Bind coverage entries to stable reference instruction identities and typed shim/fault provenance.
- [muse] B1 (§3.6, §3.7, §4.2, §5.2): The claimed construction does not cover its own instruction set. Several lifted instructions write more than the one location §3.6/§3.7 allows and do not have assignment semantics: lift.alloc writes w and heap_used, lift.call writes a stack cell, sp and depth, lift.ret writes sp and depth, lift.oracle_call XORs two locations, lift.perm_call transforms many mut locations in place. A frame with one displaced slot of width W_max (widest register) cannot retain all displaced values, cannot hold a memory cell or oracle target wider than W_max, and exch-back cannot invert an oracle_call or perm_call. §3.6 step 3 also gives no successor function for conditionally faulting lift.div/alloc/call/faultif, for lift.call, lift.ret or lift.retval, and sp is used in §4.2 but never declared in the step state. The sentence 'exactly one location changes per step' is false, so two executors must invent different realisations and frame layouts. Fix proposed: Replace the universal rule with a per-instruction step table giving, for every lifted/control instruction: locations and memory cells read, locations/cells written, classical successor function of registers/flag (including conditional fault to HALT, lift.call target, lift.ret popped index, lift.retval HALT), frame fields occupied, and the inverse operation used in a reversed step (exchange back for assignments/stores, re-call for oracle_call, adjoint for perm_call, decrement/reverse bookkeeping for alloc/call/ret). Size the frame as the maximum total displaced width over all instructions, including memory-cell and oracle tgt/fr widths, and declare sp with width and bounds.
- [muse] B2 (§4.1, §4.2, §7.1, §7.2): No rule translates a lifted address into a quantum-memory access, and classical allocation is nondeterministic. lift.load/lift.store take address a in a reg[ptr], but qload takes a cell index wire[A]; heap_base is used in lift.alloc and never defined, H serves both as heap-region size exponent (§7.2, 2^H bytes) and heap_used counter width (§3.7, so heap_used=2^H wraps to 0), byte-versus-cell units and unaligned/multi-cell accesses are unstated, and the required range check 'against the declared allocation' has no per-branch allocation metadata to check against for bump allocation. lift.free 'validates only' without a predicate or fault. In CC/R the bump allocator's base address is unspecified, so ptrtoint observes different values in different executors, and free of a non-most-recent allocation has no semantics. Fix proposed: Define lifted addresses completely: heap_base value, units of heap_used and n (bytes), counter widths (heap_used must represent heap_limit without wrap), the map from a ptr value to (region, cell index, byte offset) for every region in layout, behaviour for unaligned and multi-cell accesses, and the allocation-bounds test as a function of state the machine actually has (e.g. per-branch allocation metadata recorded in quantum memory, or restrict the defined test to region bounds and say the object-bounds model of the north star is producer-enforced differently). State lift.free's validation predicate and fault. For CC/R state the initial bump pointer and that free of a non-top allocation is a trap/fault or a defined no-op; pick one.
- [muse] B3 (§4.6, §5.2, §5.3, §9.1): A qregion's scope, lifetime and ownership are undefined, and its exit condition contradicts itself. §4.6 says a region is created at region entry and 'MUST be returned to its image at exit', §5.2 requires memory 'clean / at image' and its construction reverses step 1 (including image creation) so cells end clean, not at image; qfree can only release clean wires. Regions are declared in the object types section but appear in no function signature, so it is unstated whether a name is function-local or object-global, who owns it across nested calls, whether two calls share one region, what controlled creation does on the 0-branch, or what the adjoint of region creation is (absent from the §5.3 table). Memory still has no linear token or equivalent ownership rule. Fix proposed: State scope and lifetime: a qregion is either (a) function-local, created by image gates at entry, required to be back at its image before the creation gates are reversed to clean at exit, with name resolution local to the function and an adjoint rule (image gates reversed), or (b) an interface/object-level region passed in the signature with a linear memory token consumed and reproduced by qload/qstore/qexchm. Take (a) for heap/stack and add (b) only if persistent quantum memory (the SQLite database) is in scope, distinguishing them syntactically. Define nested/controlled creation (image gates under the active predicate, cells start clean and are freed clean, not at image, on the predicate-0 branch).
- [muse] B4 (§5.6, §12): The stated sufficient discipline for borrowed wires is mathematically insufficient in actions. §5.6 requires identity on borrowed systems (correct), but then claims permutation-gates-only plus basis restoration yields it 'by T3'. T3 needs the realised unitary to be a permutation matrix; in a general action it is not. Counterexample: prepare a data wire in |-⟩, cx with the borrowed wire as control, unprepare: the borrowed wire receives a Z (phase kickback), its basis value is restored on every configuration, only permutation gates touched it, yet |+⟩ maps to |-⟩. §12 records only borrowed.discipline_checked, so a conformant certificate can assert restoration on exactly this insufficient basis. Fix proposed: State the discipline correctly: in an action, borrowed wires may be used only inside subcircuits whose realised unitary on borrowed-plus-every-wire-they-touch is a permutation matrix (equivalently, borrowed wires never interact, as control or target, with any wire that is in a non-basis state at that point), OR keep the identity MUST but label the gate restriction necessary-not-sufficient and require a channel/permutation certificate over the borrowed-extended domain for every borrowing region. Take the first form as the well-formedness rule and keep the certificate for library frames; change §12 borrowed from discipline_checked to the domain and method by which identity was verified.
- [muse] B5 (§6, §14.3 T5): Provenance is still not a checkable static discipline and T5 is false as stated. The qxor transfer rule is self-referential ('unless t was perm with S ⊇ {s} ∪ S_t'); there are no transfer rules for oracle_call, action_call, qinplace, or qstore/qexchm (which mutate cells named in other values' dependency sets, with no versioning rule for cells); and T5 claims a cleaned value 'leaves the remaining state unchanged', but allowed uses change it: a diagonal gate on g, or g as control into a phase-eigenstate target, applies a nontrivial diagonal phase as a function of S to the remainder after cleanup. Cleanliness/disentanglement is what validity gives, not unchanged remainder. Fix proposed: Complete the transfer table for every instruction that can appear in an action body (oracle_call: tgt/fr become perm with S = ins ∪ {tgt} if the callee is permutation, else not allowed as dependencies; action_call to a permutation action similarly; qinplace; qstore/qexchm to a cell kill all dependency sets naming that cell; qregion cells versioned by store count). Rewrite the qxor rule coherently. Restate T5 as: g returns to |0⟩ and factorises from the remaining state; diagonal/controlled uses may have applied the corresponding diagonal phase to the remainder, which is part of the program's semantics.
- [muse] B6 (§7.3, §7.4, §14.3 T4): The 'nothing recorded' rows confuse static SSA with dynamic execution. In a loop, a block parameter or SSA operand takes a new value every iteration; icmp's result does not determine its operands and add's result determines an operand only if the other operand's value from that iteration survives, which next iterations overwrite. §7.4 records nothing for add/sub/xor/icmp/zext/sext on the ground that 'SSA keeps operands live', so a finite trace through a loop cannot in general be reversed from the specified history and T4's hypothesis cannot be met by the specified frames. The table also has no rows for oracle_call/action_call from R (§3.1 allows R to call Q regions), and clock read does not state whether it returns the counter before or after its own tape record advances it. Fix proposed: Give the R machine a dynamic value-history rule that works under loops: each executed instruction records every operand value that the inverse needs and that is not provably still live with the same dynamic value at reversal time; conservatively, lossy and comparison instructions record both operands, add/sub/xor record whichever operand is not retained live. Add history rules for oracle_call/action_call (inverse is re-call/adjoint with recorded classical args) and state clock read returns c before its own record increments it (or after; pick one).
- [muse] B7 (§9.2, §11, §12, §16): The one normative interchange form and all hashes built on it remain undefined. §16's grammar has section := 'section' NAME line* with 'line' never defined, the function production is unreachable from section, and there are no productions for symbols, imports, data, devices, layout, schedule, certificate or coverage sections, no opcode enumeration, no negative literals. §9.2 says references are replaced by their content hashes and an SCC is hashed 'as one unit in canonical order' without saying what replaces intra-SCC references (their hashes are what is being computed) or what the order is. object_hash, target_hash, schedule_hash and reference_program_hash (§11, §12) have no defined inputs, and bindings.object_hash sits inside the certificate section of the very object it would hash. §11's serialised schedule has no encoding and no way to name the cleanup/gate an entry refers to. Fix proposed: Complete §16 to a full grammar: define line and one production per section kind (symbols, imports, data images as hex, devices, layout, schedule, certificate and coverage or an explicit embedded-JSON rule with canonicalisation), the opcode set with typed operands, negative integers, and finite-float lexical form. Define each hash's exact input bytes: SCC hashing by replacing internal references with the member's local name sorted lexicographically and hashing the concatenation in that order (or another stated algorithm); object_hash over all sections except certificate; target_hash and schedule_hash over their canonical serialisations, which must be defined in §8 and §11. Give schedule entries stable referents (function hash plus instruction index in canonical order).
- [muse] B8 (§8.2, §8.3, §8.5): A vendor cannot write a target description another implementation parses identically. The format is pseudo-YAML with no named syntax or canonicalisation; gate costs may be 'fn(k)' or 'fn(ε)' with no expression language, so mcx and rotation costs cannot actually be written down; decompositions are fixed gate sequences, which cannot express a parametric mcx(k) decomposition; §8.2's cross-class fallback ('the costlier class's cost') refers to per-class gate costs that §8.3 never declares (classes carry only qubit_second rates), and whether cross_class replaces or adds to the gate cost is unstated. §8.5's import rule still says only that aligning units 'are converted', with no conversion table. Fix proposed: Give the target file a concrete syntax (state it is the §16-style canonical text, YAML subset, or JSON with stated canonicalisation). Define cost functions in a small closed expression language (e.g. constants, k, epsilon, log2(1/epsilon), arithmetic and piecewise tables) or require tabular values per k/epsilon decade. Define gate costs per class or delete the costlier-class fallback and state cross_class replaces/adds the gate cost. Allow decompositions to be parametric (a named scheme with parameters) for mcx(k). Replace §8.5 with a conversion table: named Qualtran/Azure quantities to named resources with factors; anything unlisted imports as a new resource, full stop.
- [muse] B9 (§10, §17): The launch ABI's data path and reversal validity are undefined. bennett_arg and bennett_result fields are deferred in §17 to 'those named in §10, §12, §13', but §10 never names them, so how classical arguments, qreg ids and budget tokens are passed to a CC entry, and what wait returns beyond prose, is left to each implementer. bennett_reverse is specified for pure tier runs, but a run is a CC entry that may invoke R functions, several Q regions and measure (in device CC); reversal after a measurement is physically impossible, no validity condition excludes it, invocation order for multiple Q regions and retention lifetime of run records are unstated, and 'modified since' has no defined detection mechanism. Fix proposed: Name the fields normatively even if bit layout is deferred: bennett_arg as a tagged union (integer width+value, f64, qreg id, token id) matched in order to the entry signature; bennett_result as (classical results, fault code, measurements array, tape length). Restrict bennett_reverse: it is an error (BENNETT_E_INVALID_STATE) if the run performed any measure, or if any qreg the run touched has been prepared, freed, or used by a later run; state that run records (history, classical args of Q regions) are retained until an explicit bennett_run_close (add it) and that reverse of a mixed run reverses region invocations in reverse invocation order. State suspend/resume/reverse behaviour on completed or unknown run_ids.
- [opus] B1 (§4.2 Reference binding; §5.2 F_B; §14.1; §12 bindings): F_B and the budget unit are defined by running the reference interpreter on the object's oracle body. But north star §3.2 and §4.2 define the unit as steps of the materialised region *before* the curated region pipeline, and say artefacts 'pad internally as needed'. Whatever optimised body the plugin emits after the curated pipeline therefore changes which inputs return FAULT_BUDGET_STEPS. That changes the quantum state, so Bennett's lowering decides the fault set. The claim that each source instruction maps to 'exactly one' lifted instruction is also false within the draft itself: lift.load and lift.store require a preceding lift.icmp + lift.faultif, and intrinsics such as ctpop or soft-float calls expand to many instructions. Two producers can therefore emit bodies with different step counts and both claim conformance. Fix proposed: State: 'Each oracle carries a reference body, the dialect-mapped materialised stream whose hash is reference_program_hash. F_B is defined solely by the §14.1 interpreter on that body. Each source instruction maps to a fixed, versioned sequence of lifted instructions, range checks included, so step weight is a property of the mapping.' Drop 'exactly one'. Two ways to let optimisation happen: (a) the object holds only the reference body, and every optimisation (structure recovery, curated simplification, pebbling) is an executor transformation that must be extensionally equal on D (§5.7/T6); (b) the object may also carry an optimised executable body with per-block reference-step weights and an equivalence certificate labelled proof or evidence. Take (a): it keeps F_B independent of every lowering, as the north star requires, and §5.7 already licenses executor transforms.
- [opus] B2 (§3.6 step 2/3, §3.7, §4.2 lift.call/lift.ret/lift.alloc/lift.oracle_call): The lifted sublanguage has no procedure model. lift.call pushes only a return index, so a recursive callee overwrites its caller's fixed register-file locations and recursion computes the wrong function. 'Producers MUST inline non-recursive calls' makes code size the number of call-graph paths, which can be exponential for SQLite or Linux. It also leaves no way for an oracle to call a lifted function in another linked object while sharing the caller's budget, which defeats the north star's linkable reversible libraries; lift.oracle_call gets its own budget and so changes F_B. Finally, the 'exactly one location per step' invariant and the fixed frame layout are contradicted by lift.alloc (two locations), lift.call (stack cell, sp, depth), and lift.oracle_call (tgt and fr'). Step 3 also gives faulting lifted instructions the fallthrough k+1 instead of HALT. Fix proposed: Add lifted procedures. A `lproc @f (params) regs {…}` symbol has its own locations, entered by `lift.call @f args → w` and left by `lift.ret v`. Each call pushes an activation record (return index plus every location of @f that is live across a recursive call) onto the `stack` region by qexchm, and ret pops it. Calls charge the *caller's* budget per callee instruction, and executors MAY inline extensionally. Give every lifted instruction a normative write set and successor set, with the faulting branch → HALT. Fix the frame layout as `(old_pc, displaced[k_max × W_max], flag)`, where k_max is the largest write set. Add `sp` to the §3.2 state. Define lift.ret on empty stack as FAULT_UB_TRAP.
- [opus] B3 (§3.5, §4.7 ctl, §5.3 Control, §6 Obligations, §11): The rule that MBU is permitted 'only when the predicate stack is empty' tests the callee's own stack, which §3.5 makes empty at every region entry. An action invoked inside a caller's qif, under `ctl w`, or under a caller's active predicate therefore sees an empty stack and may legally be scheduled with measurement-based uncomputation while it is actually coherently controlled. That is exactly the case the north star says must fall back to unitary uncomputation. Schedules are per region, and 'controlled and adjoint variants use the same descriptor', so nothing separates the two. Fix proposed: Define the **control context** of an invocation as the conjunction of the caller's active predicate stack, any `ctl` wires, and the caller's own control context, inherited transitively. State: 'An MBU realisation is legal only in a schedule for an invocation whose control context is empty and whose target declares mbu: true.' Key schedules (and certificate entries for cleanup realisations) by (region hash, variant ∈ {plain, controlled, adjoint}). A region reachable under a nonempty control context MUST have a unitary-cleanup schedule for that variant.
- [opus] B4 (§5.6 Borrowed systems; §14.2): The borrowed-wire discipline (permutation gates only, never the control of a non-permutation gate, 'returned to initial basis value') does not imply U ⊗ I on borrowed systems inside an action. Counterexample: `cx m d; h m; cx m d` with d borrowed obeys every stated rule. Yet from |0⟩|d⟩ it yields (|0⟩|d⟩+|1⟩|d⊕1⟩)/√2, entangling d. Once other gates create superposition, 'returned to its basis value on every basis configuration' is not even well defined. T3 does not apply, because the action's unitary is not a permutation. Fix proposed: Adopt the north star's frame lemma as the rule. In an action, borrowed wires may be touched only inside a **borrow frame** V; W; V⁻¹ (or the standard toggling pattern V W V⁻¹ W⁻¹). The frame consists only of permutation gates. Every wire that controls a gate targeting a borrowed wire stays within its §6 window between V and V⁻¹, i.e. it is used only as a control or by diagonal gates. The frame's restriction to its wires is verified by T3 over all borrowed values. State that this implies U ⊗ I_borrowed ⊗ I_R. Borrowed use outside such frames is ill-formed (suite F). For oracles the existing T3 argument suffices.
- [opus] B5 (§3.4, §7.4 R history rules, §14.3 T4): The R history table does not record what the R machine destroys, so T4 is false as stated. An unconditional `br ^b(args)` on a loop back-edge overwrites b's block parameters, yet only conditional br records anything, and that is only the edge. `ret` records only the frame link, so the callee's register values at return are lost and uncall cannot step back into the callee. The table also says operands are kept live by SSA while recording 'destroyed operands' of mul/and/udiv, which is contradictory. R→Q region calls (§3.1) have no history entry, so reversal cannot know to re-invoke the oracle or the adjoint action. Fix proposed: Fix the R register model: within an activation, SSA values are immutable except block parameters. Each `br` records the predecessor block and the prior values of the target block's parameters. `ret` pushes the callee's entire activation (its live values) onto the history. Delete the 'lossy binop' row, since operands stay live. A Q region call records (region hash, variant, classical args, register ids) and is reversed by oracle re-application or adjoint action. With these rules, state T4 for finite traces.
- [opus] B6 (§4.2 lift.load/lift.store/lift.alloc, §4.6 qregion, §7.2): Lifted memory is not implementable without guessing. §7.2 makes `heap` a region of 2^H *bytes*, but `lift.load.W region a` is defined by a `qload` of one W-wide cell, so the semantics of an i32 access at an arbitrary (unaligned) byte address in a byte region is unspecified. The 'range check against the declared allocation' has no allocation metadata to check against, because a superposed pointer's allocation is not static; two producers will emit different checks and get different fault sets. Separately, a qregion is local to a region and initialised only from a classical image. A quantum-addressed load or store into caller-owned quantum data, a north-star dialect operation, is therefore inexpressible. Fix proposed: (1) State: lifted classical memory regions have 8-bit cells; `lift.load.iN` and `lift.store.iN` access N/8 consecutive cells at addresses a … a+N/8−1, little-endian, with each byte address range-checked and wrap-around a fault. (2) Add an allocation table to the oracle's quantum memory, written by lift.alloc and lift.free (base, size, live bit). Define `lift.boundscheck p n → flag`, which raises FAULT_UB_MEMFAULT unless [p, p+n) lies inside a live allocation. The dialect mapping emits it before every access, which makes the north star's object-bounds model an ISA instruction. (3) Add a `mem: qregion[A,W]` interface parameter kind for actions and oracles: the caller passes a region it owns, and it is linear as a unit.
- [opus] B7 (§3.3, §4.4–§4.6, §16): Bundles are linear 'as a unit', and there is no instruction or operand syntax for a single wire of a bundle, nor for splitting or concatenating bundles. Yet the spec's own semantics use `cx s_i d_i`, and every arithmetic action needs per-bit gates. `qloop n while c {body}` defines c₁..cₙ through cond_i but gives cond_i no operand. Implementers will invent incompatible syntax and semantics, and the canonical text cannot express either. Fix proposed: Add `qsplit w:consume wire[N] → (w0:wire, …, w_{N−1}:wire)` and `qjoin`, both cost-free and linear, or alternatively indexed operands `w[i]` that borrow one wire of a bundle for one instruction; take indexed operands, which keep listings short. Extend §16 with the operand syntax. Change qloop to `qloop n while c:in cond:in wire[n] {body}`, where cond_i is cond[i], computed before the loop with permutation provenance from wires the body does not modify.
- [opus] B8 (§9.2 Identity; §11 Schedule; §12 bindings): A symbol's content hash replaces references by the referenced symbols' hashes, but an unpinned import has no hash until link. A library object's hashes, and every certificate bound to them, are therefore undefined at compile time, or else change at link. Stored schedules assign realisations 'per cleanup, per allocation, per gate' with no stable identity for those program points, so a competitor's VM cannot validate or execute a stored schedule verbatim. That is the substitutability guarantee of north star §4.4. Fix proposed: Define two hashes. The **interface hash** hashes a symbol with each unresolved import replaced by H(name, signature); it is computed at compile time and certificates bind to it. The **closure hash** is computed at link, with resolved hashes substituted, and is recorded in the linked certificate. Give every instruction a stable program-point id (symbol interface hash, block name, instruction index in canonical text), and define the schedule section's grammar as a list of `point-id → realisation | class | decomposition-hash, ε share | start time` entries. A consumer validates that every point-id exists and that the realisations satisfy §6, and otherwise rejects the schedule.

## Editor's response (what changed, what was declined and why)

# Editor's response to ISA round 2

Verdicts: codex, muse, opus all **revise**. Mean 2.83 (from 2.12).
Thirty-four blockers (17 + 9 + 8), converging on ten themes. All
accepted; draft 0.3 is a further rewrite. Status reported to the
maintainer: **no-go**.

## Accepted and changed

1. **Per-instruction step table** (codex B1, muse B1, opus B2). §4.2 is
   now a table: for every lifted and control row its reads, its write set
   (the displaced values in order), its flag and fault, its successor
   (including fault → HALT, call → entry index, ret → popped index,
   retval → HALT) and its inverse. The frame layout is derived from the
   widest write set (`k_max` slots of widths `W_j`). Falling off the end
   is ill-formed (terminator rule), empty bodies are ill-formed,
   out-of-range `qjumpr` faults `FAULT_UB_TRAP`.
2. **Procedure model** (codex B2, opus B2). `lproc` symbols with their own
   locations; `lift.call`/`lift.ret` push **activation records on a
   monotonic stack** (return index, caller `fp`, all of the callee's
   locations exchanged out so recursion starts clean); `sp`, `fp`,
   `depth` in the state; stack and depth limits with widened comparisons;
   callee instructions charged to the caller's budget; inlining at the
   executor's option. Mandatory inlining is gone.
3. **Reference body and binding** (codex B3, opus B1). Each oracle carries
   its reference body (the dialect's versioned *sequence* per source
   instruction, bounds checks and parallel moves included); F_B is
   defined solely by the reference interpreter on it; the object holds
   only the reference body; all executor optimisation is extensionally
   equal on D. "Exactly one" is dropped. `lift.parmov` is an atomic
   parallel move (the cycle problem).
4. **Memory model** (codex B4, muse B2, opus B6). Byte cells; `lift.load.
   iN`/`store.iN` over N/8 consecutive cells, little-endian; an
   allocation table in quantum memory with live bits; `lift.boundscheck`
   as the ISA instruction behind the object-bounds model; monotonic
   allocation with dead marking; zero-size allocation; `ptr_width` as an
   object-level constant that targets must support. Interface regions
   (`mem … in | mut`) for persistent quantum memory such as a database.
5. **Local regions** (muse B3). Function-local `qregion` with image gates
   at entry, restoration before exit, release to clean; interface regions
   as above.
6. **Borrowed systems** (codex B7, muse B4, opus B4). The old discipline is
   withdrawn with both counterexamples quoted. New rule: borrowed wires
   are touched only inside **borrow frames**, permutation-only
   subcircuits whose realised permutation must factor as P' ⊗ I_borrowed,
   verified by T3 over the frame's full domain or structurally for
   `V; W; V⁻¹` with W disjoint from V's reads and the borrowed wires;
   `qreturn` is the matched inverse of `qborrow`.
7. **Validity** (codex B8, muse B5, opus B3). Complete transfer table over
   versions, including predicate dependence, calls, `qinplace`, and cell
   versioning (a store to a cell closes windows that depend on an older
   version); the `qxor` rule rewritten; the **control context** inherited
   transitively, MBU legal only with an empty control context and `mbu:
   true`, schedules keyed by variant; **closed-window MBU prohibited** in
   this draft (codex's recommendation), removing the contradiction; T5
   restated.
8. **Nested faults** (codex B9). A clean `fr'` is required only for a
   fresh outcome; clearing is a matched second call with identical
   operand versions (checked by suite F) or retention until reversal.
9. **Exactness vs decomposition** (codex B10). Permutation status is a
   property of the realised unitary at the gate boundary (exact
   Clifford+T Toffoli allowed); oracles and permutation actions require
   ε = 0 realisations; finite angles required; operator-norm to diamond
   conversion (×2) and local vs inclusive ε in the certificate.
10. **Ownership in structured code** (codex B5, opus B7). Linear SSA with
    implicit versioning stated; indexed operands `w[i]`; pairwise
    disjointness of instruction operands and of interface bundles and
    regions; roles in signatures; signed division convention; measurement
    width.
11. **R tier** (codex B11, muse B6, opus B5). SSA immutable except block
    parameters; `br` records predecessor and prior parameter values;
    `ret` records the whole activation; the lossy-binop row deleted; Q
    calls from R recorded and reversed by re-application/adjoint; LIFO
    `uncall`; typed device operations with failure cases; clock read-then-
    increment; sector size and missing-sector rule; entropy exhaustion.
12. **Targets** (codex B12, muse B8, opus B9). JSON in RFC 8785 canonical
    form with `target_hash`; a closed cost-expression language; legality
    and cost as functions of total control count (predicate depth
    included), classes, arity, parameters and ε; parametric decomposition
    schemes; interface-wire occupancy charged to the caller; versioned
    import maps; `ptr_widths_supported`.
13. **Grammar and identity** (codex B13/B14, muse B7, opus B8). A complete
    grammar with lexical rules, metadata sections as JCS JSON lines,
    data as hex, an opcode rule; interface hash vs closure hash; SCC rule
    with `$index` references; `object_hash` excluding certificate,
    schedule and coverage; program-point ids; a **complete example
    object** with its hash computed from the stated rules.
14. **Launch and scheduler** (codex B15/B16, muse B9). An invocation state
    machine; normative fields for `bennett_arg`/`bennett_result`/
    `bennett_request` behind opaque types; `bennett_wait` returning
    HOST_REQUEST with `bennett_reply`; `bennett_run_close`; reverse
    eligibility (no measurement, registers untouched since) and reverse
    order over the run record; the scheduler request carries object and
    target bytes; the schedule is a JCS document of program-point
    entries with bindings; verbatim execution or rejection.
15. **Certificate and coverage** (codex B17). Claim kinds (`exhaustive`,
    `sampled`, `structural`, `numerical`) with normative payloads and
    checker obligations; domain range encodings; sampler algorithm/
    version/seed/count; local vs inclusive ε; composition over
    multiplicities; coverage bound to program-point ids.

## Declined

- Codex's suggestion to allow a separate approximate oracle contract:
  declined; oracles stay exact and approximation lives in actions.
- Opus's option (b) for reference binding (keeping an optimised body in
  the object alongside the reference body): declined for option (a),
  since (a) keeps one body and one F_B per object.


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


# The document under review (round 3 snapshot)

# Bennett Virtual ISA — Specification, draft 0.3

**Date:** 2026-10-28. **Status:** third normative draft, for council
iteration (reports: `docs/council/isa-2026-10-28/round-{1,2}/`; editor's
responses in `round-*/response.md`). Founding text of `bennett-isa-spec`
(`Bennett-NorthStar.md` §4.4, §6.1); the north star governs where this
draft is silent. Nothing is implemented. MUST, MUST NOT, SHOULD, MAY are
normative; *(non-normative)* explains; *(deferred)* names items left open
and asserted non-semantic.

**Versioning.** ISA 0.3, object 0.3, launch 0.3, sched 0.3, cert 0.3,
coverage 0.3, target 0.3, each semantically versioned and declared by
every conformant implementation.

---

## 1. Scope and conformance

### 1.1 What the ISA is

A program model for classical, reversible and coherent computation with
one semantics, executed by the VM (`bennett-vm`) and the circuit
specialiser (`bennett-circuits`), produced by the plugin
(`bennett-plugin`) through the dialect's reference semantics, scheduled
through §11, described for hardware by target descriptions (§8). Nothing
here refers to LLVM.

### 1.2 Conformance classes

| Class | Who | Obligation |
|---|---|---|
| Executor | VM, specialiser, hardware stacks | §3–§7, §14 exactly; suites A–E, H |
| Producer | plugin, library compilers | well-formed objects (§9) and regions (§5, §6); suite F |
| Scheduler | `bennett-sched` and competitors | §11; only schedules valid under §6; suite H |
| Checker | `bennett-conformance` | validates certificates (§12) without trusting producers |
| Target author | vendors | target descriptions (§8); suite E |

### 1.3 Deferred *(asserted non-semantic)*

Binary encodings (the canonical text of §16 is the interchange form);
mechanisation of §14; device models beyond §7.3; the gate-name registry
process; the bit layout of the opaque launch/scheduler objects (their
accessors are normative, §10–§11).

## 2. Terminology

- **Tier.** CC (classical-control), R (reversible), Q (coherent).
- **Wire**, **bundle** `wire[N]` (little-endian, wire 0 least significant).
- **Location** `reg[N]`: a named mutable register-file cell of an oracle
  or lifted procedure (§3.7).
- **Region**: a Q function with a declared interface: **lifted oracle**
  (§5.2) or **quantum action** (§5.3). **Permutation action**: an action
  whose realised unitary is a permutation matrix (§5.3).
- **Lifted procedure** (`lproc`): a lifted sub-program with its own
  locations, callable from oracle bodies (§4.2).
- **Budget**: classical (steps B, heap limit, stack limit, depth limit).
- **Frame**: per machine step, the workspace retaining displaced values.
- **Basis configuration**: classical values on every wire of a region's
  interface, interface memory and borrowed bundles.
- **Gate classes.** Permutation gates: `x cx ccx mcx swap`. Diagonal
  gates: `s sdg t tdg cz rz`. Non-diagonal gates: `h rx ry`.
- **Control context** of an invocation: the conjunction of the caller's
  active predicate stack, every enclosing `ctl` wire, and the caller's
  own control context, transitively (§6.4).

## 3. Machine model

### 3.1 Tiers and the control invariant

```
  CC ──calls──▶ R functions (call/uncall)      CC ──calls──▶ Q regions (oracle_call / action_call)
  R  ──calls──▶ R functions, Q regions         Q  ──calls──▶ Q regions (§5.5), lprocs (oracle bodies only)
```

CC runs on the device's classical-control processor; the host reaches
the device only through §10. **No instruction in any tier makes a
control or scheduling decision that depends on the value of a wire**
except through predication (§3.5). Gate angles are finite classical
`f64` fixed at region entry; non-finite angles are ill-formed.

### 3.2 State

| Component | Tier | Contents |
|---|---|---|
| classical registers | CC, R | SSA values; within an activation immutable except block parameters |
| classical memory | CC, R | byte-addressed, little-endian, sparse; allocation metadata (§7.1) |
| effect tape, entropy tape | R | §7.3 |
| R history | R | stack of frames, one per executed R instruction (§7.4) |
| wire store | Q (CC via register ids) | live wires, each with a role: `input`, `target`, `fault`, `borrowed`, `mutable`, `workspace`, `location`, `cell` |
| quantum memory | Q | regions of `wire[W]` cells: function-local (§4.6) or interface (§5.1) |
| register file | Q | the locations of the active oracle and its lprocs (§3.7) |
| predicate stack | Q | wires; the active predicate is their conjunction |
| oracle step state | Q | `pc, pc' : wire[P]`; `faulted : wire`; `code : wire[F]`; counters `heap_used : wire[Hc]`, `sp : wire[Sc]`, `fp : wire[Sc]`, `depth : wire[Dc]`, `atop : wire[Ac]`; B frames |
| budget | Q | classical: B, heap_limit, stack_limit, depth_limit |

### 3.3 Types and ownership

```
  iN (1 ≤ N ≤ 128)   ptr (width = object.ptr_width)   f64   token        classical
  wire   wire[N]      linear values in structured code and interfaces
  reg[N]              a location (oracle bodies and lprocs); not linear
  region[A,W]         a quantum memory region of 2^A cells of wire[W] (interface parameter type)
```

**Linear SSA with implicit versioning.** In structured code (actions and
CC region calls) every `wire`/`wire[N]` value is produced once and
consumed once. An operand in mode `in` is consumed and a successor value
of the **same name** is produced by the instruction (the name always
denotes its latest version); `consume` consumes without a successor;
`produce` creates. A name MUST NOT be used after a `consume`. **Indexed
operand** `w[i]` (0 ≤ i < N, i a literal) borrows wire i of bundle `w` for
one instruction and reproduces `w`. **Disjointness:** the operands of one
instruction are pairwise disjoint wires; the interface bundles and
interface regions of a region are pairwise disjoint. Signed division
truncates toward zero. `measure` of `wire[n]` yields `in`.

### 3.4 Execution in CC and R

Sequential small-step execution with an instruction pointer, block
parameters instead of phi nodes, dynamic control flow and allocation. In
R every executed instruction pushes a history frame per §7.4; `uncall`
pops frames in LIFO order (T4).

### 3.5 Predication

Every Q instruction with unitary semantics executes controlled on the
active predicate. `qpred w` pushes, `qunpred w` pops the same wire; the
stack is empty at region entry and exit. **Allocation, borrowing,
release, region creation and image gates are unconditional resource
operations**; only gates (including the gates inside copy/XOR/exchange/
memory instructions) are controlled.

### 3.6 The predicated step machine

An oracle body is a sequence `I[0..n)`, n ≥ 1, of lifted and control
instructions (§4.2) over the oracle's locations and its lprocs' locations;
`HALT = n`; P satisfies 2^P > n. **Well-formedness:** the last instruction
of the body and of every lproc is a terminator (`lift.retval`, `lift.
ret`, `qjump`, `qjumpr`, `fault`); falling off the end is ill-formed.

**Frame layout** (fixed per oracle, derived from §4.2's write sets):
`(old_pc : wire[P], disp_1 … disp_{k_max}, flag : wire)` where `k_max` is
the maximum number of displaced values of any instruction and each
`disp_j` has the maximum width of the j-th displaced value over all
instructions (`W_j`).

**Machine step** t (1 ≤ t ≤ B), from the state at the start of the step
(all reads refer to it):

1. **Dispatch.** Compute `at_k = (pc == k)` for k = 0..n into clean scratch.
2. **Execute.** For each k < n: push `at_k`; execute `I[k]` per its row in
   §4.2: each written location or cell receives its new value by **out-
   of-place compute into `disp_j`, then `qexch disp_j, destination`**, so
   `disp_j` retains the displaced old value; the row's `flag` (if any) is
   computed into `frame_t.flag`; pop `at_k`. Exactly one `at_k` is 1 on
   any basis branch.
3. **Successor.** For each k < n, under `at_k` XOR the successor index
   given by the row (and by `flag` for conditional rows) into `pc'`.
   Under `at_HALT` XOR `HALT` into `pc'` (**halted branches self-loop and
   change no state**).
4. **Commit pc.** `qexch pc pc'`; `qexch pc' frame_t.old_pc`.
5. **Clean dispatch.** Uncompute every `at_k` from `frame_t.old_pc`.
6. Decrement the classical step counter.

The step is a permutation; its inverse is the same sequence backwards
with each row's inverse (§4.2). An executor MUST implement this
transition or a transformation extensionally identical on every basis
configuration (§5.7, T6). B = 0 is legal: commit yields `FAULT_BUDGET_
STEPS` on every input.

### 3.7 Register files, procedures, the stack

An oracle declares `regs { name : reg[N], … }` and `result : reg[T]`; each
`lproc @f` declares its own `regs` and `params`/`result`. Locations are
clean at entry; interface inputs are `qcopy`ed into their locations at
entry (inputs are never written). Block parameters are lowered by the
dialect to `lift.parmov` on edges.

**Procedures.** `lift.call @f (args) → w` and `lift.ret v` implement calls
with **activation records on a monotonic stack** (§4.2 rows): the record
holds the return index, the caller's `fp`, and *all* locations of `@f`
exchanged out (so `@f` starts clean, which makes recursion correct); the
stack is never popped (records are history; `sp` only grows), `fp` links
records. Callee instructions are charged to the **caller's budget**
individually; `lift.call` and `lift.ret` are one step each. Executors MAY
inline extensionally (§5.7). Counter widths: `Hc ≥ ptr_width + 1`, `Sc`,
`Dc`, `Ac` large enough that every limit and every single increment are
representable without wrap; budget comparisons are over the full width.

## 4. Instruction set

### 4.1 Classical control (CC, R)

| Instruction | Form | Semantics |
|---|---|---|
| `const` | `const c:iN → r` | |
| `add sub mul and or xor shl lshr ashr` | `op a b → r` | wrap; shift ≥ N → 0 |
| `udiv urem sdiv srem` | `op a b → r` | divisor 0, or signed MIN/−1: CC traps; R fault record (§7.4) |
| `icmp` | `eq ne ult ule slt sle a b → r:i1` | |
| `select` | `select p a b → r` | |
| `zext sext trunc ptrtoint inttoptr` | | |
| `load` | `load.iN addr → r` ; `load.iN.{s,z}` sub-width | N/8 consecutive bytes, little-endian, unaligned allowed; out of any live allocation: CC trap / R fault record |
| `store` | `store.iN addr v` | |
| `alloc` / `free` | `alloc n → p` ; `free p` | monotonic bump allocator with metadata (§7.1); invalid free: trap / fault record |
| `br` | `br ^b(args)` / `br p ^b1(args) ^b2(args)` | block parameters assigned in parallel |
| `call` / `uncall` / `ret` | `call @f args → results` ; `uncall` (R, §9.3) ; `ret vals` | |
| `trap` | | CC traps; R fault record |
| `measure` | `measure w:consume wire[n] → r:in` | CC only; Born rule (§14.2) |
| `effect` | `effect dev.op args → results` | R only (§7.3) |

### 4.2 Lifted instructions and control (oracle bodies and lprocs)

Notation: `r` read location/cell, `w` written location/cell, `c`
classical literal. **Write set** lists the displaced values in order
(`disp_1 …`). **Succ** is the successor index (k = own index). **Inverse**
is what a reversed step does for this row. Every row is one budget step.

| Row | Form | Reads | Writes (displaced) | Flag / fault | Succ | Inverse |
|---|---|---|---|---|---|---|
| `lift.const` | `lift.const c → w` | – | w | – | k+1 | exch back |
| `lift.binop` | `lift.{add,sub,mul,and,or,xor,shl,lshr,ashr} a b → w` | a, b | w | – | k+1 | exch back |
| `lift.div` | `lift.{udiv,urem,sdiv,srem} a b → w` | a, b | w (under ¬flag) | flag = (b=0) ∨ (signed ∧ a=MIN ∧ b=−1); under flag: fault `FAULT_UB_DIV0` / `FAULT_UB_SDIV_OVERFLOW` | ¬flag: k+1; flag: HALT | exch back |
| `lift.icmp` | `lift.icmp.{pred} a b → w:reg[1]` | a, b | w | – | k+1 | exch back |
| `lift.select` | `lift.select p a b → w` | p, a, b | w | – | k+1 | exch back |
| `lift.cast` | `lift.{zext,sext,trunc} a → w` | a | w | – | k+1 | exch back |
| `lift.mov` | `lift.mov a → w` | a | w | – | k+1 | exch back |
| `lift.parmov` | `lift.parmov (w_1..w_m) ← (a_1..a_m)` | a_i | w_1..w_m (atomic, parallel) | – | k+1 | exch back |
| `lift.boundscheck` | `lift.boundscheck p n:c` | p, alloctab | – | flag = ¬∃ i < atop: live_i ∧ base_i ≤ p ∧ p+n ≤ base_i+size_i (no wrap); under flag: fault `FAULT_UB_MEMFAULT` | ¬flag: k+1; flag: HALT | – |
| `lift.load` | `lift.load.iN a → w` | bytes a..a+N/8−1 of `mem` | w | – | k+1 | exch back |
| `lift.store` | `lift.store.iN a v` | v | bytes a..a+N/8−1 (displaced: the N old bits) | – | k+1 | exch back |
| `lift.alloc` | `lift.alloc n → w` | n, heap_used, atop | w, heap_used, atop, alloctab[atop] (base,size,live) (under ¬flag) | flag = (heap_used+n > heap_limit) ∨ (atop = 2^Ac) (widened); under flag: fault `FAULT_BUDGET_HEAP` | ¬flag: k+1; flag: HALT | exch back |
| `lift.free` | `lift.free p` | p, alloctab | live_i ^= 1 for the unique i with live_i ∧ base_i = p (controlled-X, no displaced value) | flag = no such i; under flag: fault `FAULT_UB_MEMFAULT` | ¬flag: k+1; flag: HALT | same op |
| `lift.faultif` | `lift.faultif p code:c` | p | – | flag = p; under flag: fault `code` | ¬flag: k+1; flag: HALT | – |
| `lift.call` | `lift.call @f (a_1..a_m) → w` | a_i, sp, fp, depth, all locations L_f of @f | stack[sp..sp+R_f) ← (k+1, fp, L_f) by exchange (displaced: the old cell contents, clean); fp ← sp; sp ← sp+R_f; depth ← depth+1; params of @f ← copies of a_i | flag = (depth+1 > depth_limit) ∨ (sp+R_f > 2^Sc ∨ sp+R_f > stack_limit); under flag: fault `FAULT_BUDGET_DEPTH` | ¬flag: entry index of @f; flag: HALT | all exch back, copies un-XORed |
| `lift.ret` | `lift.ret v` | v, fp, record at fp | exchange record's L_f cells with @f's locations (restores the caller's view of them; the record now holds @f's final locations, including v); caller's `w` of the matching call ^= record's v; fp ← record.prev_fp; depth ← depth−1 | – | record.ret_index (read from the record before the exchange) | reverse of each sub-step |
| `lift.retval` | `lift.retval v` | v | result ^= v | – | HALT | un-XOR |
| `lift.oracle_call` | `lift.oracle_call @o tk:c (ins..) tgt fr` | ins, tgt, fr | tgt ^= payload, fr ^= code (callee contract) | – | k+1 | re-call (involution) |
| `lift.perm_call` | `lift.perm_call @a (mut..) (ins..)` | ins, mut | mut ← P(mut, ins) in place (callee is a permutation action) | – | k+1 | adjoint call |
| `qjump` | `qjump k':c` | – | – | – | k' | – |
| `qbranch` | `qbranch p k1:c k2:c` | p | – | – | p: k1; ¬p: k2 | – |
| `qjumpr` | `qjumpr a` | a | – | flag = (a ≥ n); under flag: fault `FAULT_UB_TRAP` | ¬flag: a; flag: HALT | – |
| `fault` | `fault code:c` | – | code ^= code; faulted ^= 1 | – | HALT | un-XOR |

`mem` is the oracle's byte region (§7.2); `alloctab` and the stack are
oracle regions declared by the producer with `Ac`, `Sc`. `k_max` and the
`W_j` of §3.6 are derived from the widest write set actually used
(`lift.call` and `lift.alloc` typically determine them). Nested
`lift.oracle_call` runs the callee under the token `tk`, a classical
argument of the calling oracle, so its budget is part of the caller's
F_B definition; the call is one step.

**Reference body and binding.** Every oracle in an object carries its
**reference body**: the instruction stream the dialect's versioned
mapping produced from the materialised source (a fixed, versioned
*sequence* of lifted instructions per source instruction, including the
`lift.boundscheck` before every memory access and the `lift.parmov` on
every edge), hashed as `reference_program_hash`. **F_B and the budget
unit are defined solely by the reference interpreter (§14.1) on the
reference body.** The object holds only the reference body; every
executor optimisation (structure recovery, inlining, simplification,
pebbling) is a transformation that MUST be extensionally equal to it on
D (T6). The fault set therefore depends only on (reference body, budget,
dialect-mapping version).

### 4.3 Allocation

| Instruction | Form | Rules |
|---|---|---|
| `qalloc` | `qalloc cls:c n:c → w:produce wire[n]` | n clean wires of class `cls` or `any`; unconditional |
| `qborrow` | `qborrow cls:c n:c → w:produce wire[n]` | n wires in unknown state, possibly entangled with an external system; usable only inside a borrow frame (§5.6) |
| `qfree` | `qfree w:consume wire[n]` | release a `qalloc`ed bundle that is clean on every basis configuration |
| `qreturn` | `qreturn w:consume wire[n]` | return a `qborrow`ed bundle after its borrow frame (the matched inverse of `qborrow`; the borrowed state is preserved by §5.6) |

### 4.4 Gates

Matrices, computational basis, |0⟩ = (1,0)ᵀ, bundles little-endian:

```
  x = [[0,1],[1,0]]    h = (1/√2)[[1,1],[1,-1]]    s = diag(1,i)   sdg = diag(1,-i)
  t = diag(1,e^{iπ/4})   tdg = diag(1,e^{-iπ/4})     cz = diag(1,1,1,-1)
  rx(θ) = exp(-iθX/2)    ry(θ) = exp(-iθY/2)          rz(θ) = exp(-iθZ/2) = diag(e^{-iθ/2}, e^{iθ/2})
  cx, ccx, mcx(k): X on the target iff all controls are |1⟩; identity otherwise (exact, no phase)
  swap: exact exchange
```

Forms: `x a`, `cx c t`, `ccx c1 c2 t`, `mcx (c_1..c_k) t`, `swap a b`,
`h a`, `s a`, `sdg a`, `t a`, `tdg a`, `cz a b`, `rx θ a`, `ry θ a`,
`rz θ a`; all operands `in`, pairwise distinct wires; all execute
controlled on the active predicate.

**Realisation and legality.** A target realises a gate natively or by a
declared decomposition (§8.3). *Permutation status is a property of the
realised unitary at the gate boundary*: an exact Clifford+T realisation
of `ccx` is a permutation gate even though its interior contains `h` and
`t`. A realisation is conformant if its unitary equals the specified
unitary **exactly, including global phase** (`epsilon = 0`), or within a
declared ε in operator norm. **Oracles and permutation actions require
ε = 0 realisations** for every gate they execute (their contract is
exact equality); actions MAY use ε > 0 realisations, accounted per §12. A
relative-phase Toffoli is never a conformant `ccx`.

### 4.5 Copy, XOR, exchange, in-place

| Instruction | Form | Semantics |
|---|---|---|
| `qcopy` | `qcopy s:in wire[n] → d:produce wire[n]` | d allocated clean (unconditional); `cx s[i] d[i]` for all i under the predicate |
| `quncopy` | `quncopy s:in d:consume` | `cx s[i] d[i]` under the predicate; `qfree d` |
| `qxor` | `qxor s:in t:in` | `cx s[i] t[i]` |
| `qexch` | `qexch a:in b:in` | `swap a[i] b[i]` |
| `qinplace` | `qinplace @g @ginv tk:c x:in wire[n]` | `@g`, `@ginv` are **total permutation oracles** on the n-bit encoding with certificates (§12) that under budget `tk` the fault code is `FAULT_NONE` on every basis input and `g∘ginv = ginv∘g = id`. Sem: `t = qalloc any n; f = qalloc any F; oracle_call @g tk (x) t f; qexch x t; oracle_call @ginv tk (x) t f; qfree t; qfree f`. (After the exchange x holds g(x₀) and t holds x₀; ginv(g(x₀)) = x₀ XORed into t clears it; f stays clean by the certificate.) |

### 4.6 Quantum memory, predication, structure

| Instruction | Form | Rules |
|---|---|---|
| `qregion` | `qregion name A:c W:c [image]` | **function-local** region of exactly 2^A cells of `wire[W]`; created at function entry by unconditional allocation and X gates from the object's data image for `(function, name)` (default all zero); MUST be back at its image before exit, where the image gates are reversed and the cells released clean; name scope is the function; nested calls do not see it; the adjoint reverses creation and release |
| `qload` | `qload name a:in wire[A] → d:produce wire[W]` | d clean; for each cell i: under `a == i`, `qxor cell_i d` (address comparators are computed and uncomputed inside the instruction) |
| `qunload` | `qunload name a:in d:consume` | inverse of `qload` |
| `qstore` | `qstore name a:in v:in` | for each i: under `a == i`, `qxor v cell_i` |
| `qexchm` | `qexchm name a:in v:in` | for each i: under `a == i`, `qexch v cell_i` |
| `qpred` / `qunpred` | | §3.5; nested; the wire is not modified in between |
| `qif` | `qif w:in { then } { else }` | `qpred w; then; qunpred w; x w; qpred w; else; qunpred w; x w` |
| `qloop` | `qloop n:c { body }` | body n times (n ≥ 0) |
| `qloop … while` | `qloop n:c while cond:in wire[n] { body }` | `cond` is a bundle of permutation-provenance wires (§6) computed before the loop from wires the body does not modify. Flags `c_1..c_n` are allocated clean; `c_1 ^= cond[0]`; iteration i (1..n) runs the body under `qpred c_i`; after iteration i < n, `ccx c_i cond[i] c_{i+1}`; after the loop the flags are uncomputed in reverse order (`ccx` then `cx`) and freed; n = 0 is the empty loop |

Interface regions (§5.1) are accessed with the same instructions by name.

### 4.7 Region calls (structured code and CC)

| Instruction | Form |
|---|---|
| `oracle_call` | `oracle_call @o tk:c (ins:in..) tgt:in fr:in (mem:in..) args:c..` |
| `action_call` | `action_call @a (mut:in..) (ins:in..) (mem:in..) args:c..` |
| `adj` | `adj action_call …` (§5.3); `adj oracle_call …` ≡ `oracle_call …` |
| `ctl` | `ctl w:in <call>`: the call under `qpred w` (for a whole action: the controlled unitary of §5.3) |

## 5. Regions

### 5.1 Interfaces and common well-formedness

Signatures list roles explicitly: `oracle @o (in a: wire[8], in b:
wire[8]) (tgt t: wire[8]) (fault f: wire[4]) (mem db: region[10,8] in)
(args n: i64)`. **Interface regions** (`mem`) are caller-owned quantum
memory regions passed by name: role `in` (returned to its entry contents
on every basis configuration; legal in oracles and actions) or `mut`
(transformed in place; actions only). A region MUST NOT contain
`measure`, `effect`, `br`, `call`, `uncall`, `trap`, classical memory
instructions, or (outside oracle bodies) lifted instructions. Predicate
stack empty at entry and exit. Every `qalloc` is matched by a `qfree` of a
clean bundle, every `qborrow` by a `qreturn` after its borrow frame, every
local `qregion` restored to its image, by **explicit cleanup instructions
in the program text**; the schedule chooses only realisations (§11).
Action call graphs MUST be acyclic; recursion exists only through
`lift.call` under the depth and stack budgets.

### 5.2 Lifted oracle

**Body.** Lifted and control instructions (§4.2) over its locations and
lprocs; **exact-permutation only**: every gate executed by the body, its
lprocs, every `lift.perm_call` target and every nested oracle is realised
with ε = 0 (§4.4). Suite F rejects anything else.

**Contract** on every basis configuration x ∈ D: `ins` unchanged; `tgt`
final = initial ⊕ payload(F_B(x)); `fr` final = initial ⊕ code(F_B(x));
interface regions of role `in` unchanged; borrowed bundles returned
(§5.6); workspace, locations, local regions, step state clean / at
image. **F_B(x)** = `(f(x), 0)` if the reference interpreter on the
reference body reaches `lift.retval` within B steps without a fault,
else `(0, code)` with `code` the first fault in sequential order, or
`FAULT_BUDGET_STEPS` if not halted after B steps. The oracle is an
**involution** on `(ins, tgt, fr)` and its own adjoint.

**Construction** (normative; T6 fixes every executor to it extensionally):

1. Allocate step state, locations, local regions (image gates), the B
   frames; `qcopy` each input into its location.
2. Run B machine steps (§3.6).
3. **Commit.** `at_HALT = (pc == HALT)` into scratch; under `at_HALT ∧
   ¬faulted`: `qxor result tgt`; under `faulted`: `qxor code fr`; under
   `¬at_HALT`: XOR the constant `FAULT_BUDGET_STEPS` into `fr`. The cases
   are exclusive (`fault` jumps to HALT). Uncompute `at_HALT`.
4. **Prefix reversal.** Invert step 2 then step 1. The commit writes are
   outside the reversed prefix and persist.

**Domain D**: every value of each `ins`, of `tgt`, of `fr`, of every cell
of every `in` region, of every borrowed bundle; `qalloc`ed wires at 0;
local regions at image.

### 5.3 Quantum action

**Semantics.** The body denotes a unitary U on mut ⊗ ins ⊗ mem_mut ⊗ (borrowed)
that is **block-diagonal in the computational basis of `ins` and of
`mem in` cells** (their basis values are unchanged; phases and
entanglement with `mut` are U's declared behaviour), is the identity on
borrowed systems and any external reference system (§5.6), and returns
all workspace clean and unentangled. An action has no fault outcome; a
fallible computation is an `oracle_call` whose `fr` it declares among
its `mut` wires. An action with coherent internal control (`qif`, `qloop
… while`) is, by definition, its padded unitary under its declared
bounds, which are part of its identity (§9.2). **Permutation action**:
an action whose realised unitary is a permutation matrix (all gates ε =
0 and permutation gates only, transitively); it is the only kind of
action an oracle may call.

**Body.** Gates; `qcopy quncopy qxor qexch qinplace`; `qload qunload
qstore qexchm`; `qpred qunpred qif qloop`; `oracle_call action_call`;
`qalloc qborrow qfree qreturn`; `qregion`.

**Adjoint table.** `adj @a` is the body in reverse order with each
instruction replaced per the table and the implicit versions renumbered
accordingly; the result is well-formed by construction:

```
  rx/ry/rz(θ) ↦ (−θ)      s ↔ sdg      t ↔ tdg      x cx ccx mcx swap h cz: self-adjoint
  qalloc ↔ qfree          qborrow ↔ qreturn          qregion creation ↔ its release
  qcopy ↔ quncopy         qload ↔ qunload            qxor qexch qstore qexchm: self-adjoint
  qinplace @g @ginv ↦ qinplace @ginv @g              oracle_call ↦ oracle_call
  action_call @b ↦ adj action_call @b                qpred/qunpred pairs reversed as a whole
  qif w {A}{B} ↦ qif w {adj A}{adj B}                qloop n {A} ↦ qloop n {adj A}
  qloop n while cond {A} ↦ allocate and compute the flags forward exactly as in §4.6, run
                           adj A for i = n..1 under c_i, uncompute the flags
```

**Control.** `ctl w @a` is controlled-U: workspace, regions and flags are
allocated unconditionally; every gate of the body, including those inside
copy/memory instructions and cleanup, runs under `w` in addition to the
active predicate; on `w = 0` the body is the identity and all workspace
is trivially clean.

### 5.4 Budgets and fault codes

Budget = (B, heap_limit, stack_limit, depth_limit), classical. B is
enforced by running exactly B steps. Heap, stack and depth are **wire
counters** compared at full width against the classical limits (§4.2
rows). Precedence when one instruction could raise two faults: the row's
flag definition is authoritative (`lift.call`: depth before stack;
`lift.alloc`: heap before table).

Fault codes (normative values; F ≥ 4):

```
  0 FAULT_NONE               4 FAULT_UB_TRAP            8 FAULT_EFFECT_UNMODELLED
  1 FAULT_BUDGET_STEPS       5 FAULT_UB_DIV0            9 FAULT_CALLEE
  2 FAULT_BUDGET_HEAP        6 FAULT_UB_SDIV_OVERFLOW
  3 FAULT_BUDGET_DEPTH       7 FAULT_UB_MEMFAULT
```

### 5.5 Nesting and nested faults

A `lift.oracle_call` supplies a caller location `fr'` for the nested fault
register. **No automatic propagation.** The dialect emits `lift.icmp.ne
fr' 0 → p; lift.faultif p FAULT_CALLEE` where the source semantics
requires it. `fr'` MUST be clean when the call computes a fresh outcome;
to clear a nonzero `fr'` the producer emits a second `lift.oracle_call
@o` with the same `tk`, `ins` versions and `tgt` version (the oracle is
an involution, so the second call XORs the same payload and code back);
suite F checks that the two calls' operand versions match. Alternatively
`fr'` is retained as data until the prefix reversal clears it.

### 5.6 Borrowed systems and borrow frames

**Requirement.** A region's completed operation MUST equal its declared
operation ⊗ identity on every borrowed bundle and on any external system
entangled with it. Basis-value restoration alone is **not** sufficient
(`cx b a; s a; cx b a` with b borrowed restores every basis value of b
and applies `s` to b).

**Rule (well-formedness, suite F).** Borrowed wires are touched only
inside **borrow frames**. A borrow frame is a maximal contiguous
subcircuit, within one region, consisting of **permutation gates only**
(including permutation-gate copy/XOR/exchange/memory instructions and
`lift.perm_call`s), that begins with the first and ends with the last
instruction touching the frame's borrowed wires. The frame's realised
permutation P_F on its wires (borrowed ∪ every wire a frame instruction
touches) MUST factor as `P_F = P' ⊗ I_borrowed`, i.e. P_F(x, b) = (P'(x),
b) for every basis value of every frame wire. This is verified by T3 over
the frame's full domain (exhaustively where finite, else by a library
certificate, §12 `borrow_frames`), or **structurally** when the frame has
the form `V; W; V⁻¹` with V permutation-only, W touching neither the
borrowed wires nor any wire V reads, and V⁻¹ the exact inverse sequence
of V. Inside a frame no wire of the frame is acted on by a non-permutation
gate (the frame is permutation-only by definition), so T3 applies.
Oracles are a single frame. Since P' does not depend on b, no public
output can depend on a borrowed value.

**Exit synchronisation** (oracles). Every basis branch has executed
exactly B machine steps at commit; branches differ in `pc` and data
until the reversal, which returns all control workspace to clean.

### 5.7 Executor transformations

Inlining of lprocs, structure recovery (`qif`/`qloop` for provably
structured CFG parts with static bounds), and any simplification MUST
produce, on every basis configuration in D, the same final interface
tuple as §5.2's construction on the reference body (T6); suite C tests
each executor against the reference interpreter.

## 6. Uncomputation validity (static discipline)

### 6.1 Provenance and dependency sets

Every workspace bundle version has provenance `perm` (computed by
permutation gates from its **dependency set** S) or `other`. S is a set of
*versions*: wire versions, location versions (oracle bodies), and cell
versions `(region, cell, v)` where v counts the stores/exchanges to that
cell so far; a cell's version advances on every `qstore`/`qexchm`/
`lift.store`/`lift.alloc` touching it.

**Transfer rules** (checked statically by suite F):

| Instruction | Effect on provenance |
|---|---|
| `qcopy s → d` under predicate stack Π | d: perm, S = {s} ∪ Π |
| `qload r a → d` under Π | d: perm, S = {a} ∪ {(r, i, v_i) for all cells} ∪ Π |
| `qxor s t` | if s and t are perm: t stays perm with S_t ∪ S_s ∪ Π; else t: other |
| `qexch a b` | provenances and sets swap |
| permutation gate, controls C, target t | t: perm iff t was perm, with S_t ∪ C ∪ Π ∪ ⋃_{c∈C} S_c; else other |
| diagonal gate on wire u | unchanged |
| non-diagonal gate on wire u | u: other; **and closes the window of every value whose S contains u** |
| `qstore`/`qexchm` to cell (r,i) | the cell's version advances; every value whose S names an older version of (r,i) has its window **closed** |
| `oracle_call @o (ins) tgt fr` | tgt, fr: perm with S = ins ∪ {tgt} ∪ {fr} ∪ Π (callee exact permutation); `in` regions unchanged |
| `lift.perm_call` / permutation `action_call` | each mut: perm with S = all mut ∪ ins ∪ Π |
| non-permutation `action_call` | every mut: other |
| `qinplace @g @ginv x` | x: perm with S = S_x ∪ Π |

### 6.2 Window and obligations

A perm value g with dependency set S is **in its window** from its
computation until the first of: a non-diagonal gate on any wire in S or
in g; a version advance of any cell in S; a non-permutation action call
touching a wire in S; or a permutation change to a wire in S that is not
undone again before g's cleanup. While in its window, g MAY be cleaned by
the inverse of its computing sequence (`quncopy`, `qunload`, adjoint
sequence) or by recomputation. **Every perm value MUST be cleaned within
its window and before its region exits.** A region containing a perm
value whose window closes before its cleanup is **ill-formed** in this
draft (closed-window measurement-based cleanup is not admitted until its
certificate contract exists). `other` values are released only by the
adjoint of the sequence that produced them.

### 6.3 Restated T5

Cleaning g within its window returns g's wires to |0⟩ and factorises
them from the remaining state; any diagonal gate on g, or use of g as a
control into a phase-eigenstate target, has applied the corresponding
diagonal phase (a function of S) to the remainder, and that phase is part
of the program's declared semantics, not a defect.

### 6.4 Control context and MBU

The **control context** of an invocation is inherited transitively (§2).
A **measurement-based realisation** of an in-window cleanup (Gidney-style
measure-and-fix) is legal **only** in a schedule for an invocation whose
control context is empty and whose target declares `mbu: true`; the fixup
is computed for the actual schedule (after an intervening U the
correction D becomes U D U†) and verified by suite D. Schedules and
certificate cleanup entries are keyed by `(region hash, variant ∈ {plain,
controlled, adjoint, controlled-adjoint})`; a region reachable under a
non-empty control context MUST have a unitary-cleanup schedule for that
variant. Schedulers choose only among realisations satisfying this
section.

## 7. Memory and effects

### 7.1 Classical memory (CC, R)

Byte-addressed, little-endian, sparse. `alloc n` returns the current bump
pointer, records `(base, size, live=1)` in the allocation table and
advances the pointer by n (n = 0 is a valid zero-size allocation that no
byte access may touch). Accesses are valid iff the whole byte range lies
in one live allocation. `free p` marks the unique live allocation with
base p dead; storage is never reclaimed (monotonic). Alignment is not
required.

### 7.2 Quantum memory of lifted code

An oracle's lifted classical memory is one byte region `mem` of 2^H
8-bit cells (`H ≤ ptr_width`), the allocation table `alloctab` (2^Ac
entries of `(base: ptr_width, size: ptr_width, live: 1)`), and the stack
region of 2^Sc cells of width `max(P, Sc, W_max)`. A `ptr` value is a byte
address into `mem`; `lift.load.iN`/`lift.store.iN` access N/8 consecutive
cells little-endian; an access whose range wraps past 2^H is out of every
allocation and faults through the preceding `lift.boundscheck`. `heap_
base = 0`; `lift.alloc` and `lift.free` maintain `alloctab` as §4.2. The
object's `layout` section records H, Ac, Sc and, for source globals, their
fixed base addresses and data images. `ptr_width` is an **object-level**
constant recorded in the header; a target MUST support the object's
`ptr_width` or refuse the object at load.

### 7.3 Device models and tapes (R)

| Device | State | Operations (typed) | Failure | Reversal |
|---|---|---|---|---|
| `console` | byte sequence | `write(bytes: [u8]) → ()` | – | pop the bytes |
| `clock` | counter `c: u64` | `read() → u64` returns `c`, then `c += 1` | – | `c −= 1` |
| `entropy` | position `p` into the **entropy tape** `[u8]` supplied at launch | `read(n: u64) → [u8]` returns tape[p..p+n), `p += n` | `p + n >` tape length: R fault record `ENTROPY_EXHAUSTED` | `p −= n` |
| `block` | sector map, 512-byte sectors; missing sectors read as zero | `read(s: u64) → [u8;512]` ; `write(s: u64, d: [u8;512]) → ()` (history records the overwritten sector) | – | restore the sector |

A run of an R function is a function of (program, initial state, entropy
tape). Each `effect` appends `(dev, op, args, results)` to the effect
tape; reversal pops and applies the inverse. Reversal restores device-
model state; it cannot retract an observation of the console, which is
why the coherent tier forbids effects.

### 7.4 R register model and history rules

Within an activation, SSA values are immutable except **block
parameters**, which `br` assigns in parallel. Each executed instruction
pushes one history frame:

| Instruction | Frame records |
|---|---|
| `br` (both forms) | predecessor block id; the prior values of the target block's parameters |
| `store` | address, width, overwritten bytes |
| `alloc` / `free` | the old bump pointer / the table entry's old live bit |
| `call` | nothing (the callee's frames follow) |
| `ret` | the callee's entire activation (all live SSA values) and the frame link |
| `effect` | index of the tape record |
| `oracle_call` / `action_call` from R | (region hash, variant, classical args, register ids); reversed by re-application / adjoint |
| all other instructions | nothing: their operands are immutable live SSA values in the current activation and their results are recomputable |
| fault record (`udiv` by 0, MIN/−1, trap, out-of-bounds, invalid free, entropy exhausted) | cause and location; execution enters a **terminal faulted state**; `uncall` reverses the prefix like any other |

`uncall` is valid only for the most recent unreversed `call` whose
activation is the top of the history stack (strict LIFO); reversal pops
frames in order. T4 is stated over these frames.

## 8. Resources and target descriptions (target 0.3)

### 8.1 Format

A target description is a **JSON document in RFC 8785 canonical form**
(JCS); `target_hash` = SHA-256 of those bytes. Cost expressions use the
closed language

```
  expr := number | "k" | "eps" | "log2inv_eps" | expr ("+"|"-"|"*"|"/") expr | "max(" expr "," expr ")" | "ceil(" expr ")" | "table[" (k | eps) "]"
```

with `table` a declared array indexed by k (exact) or by ε decade.

### 8.2 Resources and aggregation

```
  "resources": { "<name>": { "kind": "count" | "time" | "occupancy" | "peak", "unit": "<string>" } }
```

Mandatory: `qubit_second` (occupancy, per class), `time` (time, the
schedule makespan in seconds), `peak_qubits` (peak, per class). **Timing
model:** execution is sequential in program order unless the schedule
assigns start times; a gate occupies its wires for its declared `time`;
gates on disjoint wires MAY overlap unless `max_parallel` or a topology
is declared; the ISA machine is all-to-all over logical wires. A wire's
occupancy interval runs from `qalloc`/`qborrow` to `qfree`/`qreturn`;
**interface wires are charged to the caller** for the call's duration;
`qubit_second = Σ_wires interval × rate`, borrowed wires at the class's
`dirty_rate` charged to the borrower and replacing the owner's charge for
that interval. Dispatch, history, reversal and cleanup are instructions
of the lowered program and are counted like any other.

### 8.3 Classes, gates, decompositions, capabilities

```
  "ptr_widths_supported": [32, 64],
  "classes": { "<cls>": { "qubit_second": rate, "dirty_rate": rate, "capacity": int | "unbounded" } },
  "gates": { "<gate>": { "classes": ["<cls>" | "*"], "controls": int | "any",
                         "cost": { "<resource>": expr, ... , "time": expr } } },
  "decompositions": { "<gate>": { "scheme": "<name>", "params": ["k"], "epsilon": expr, "cost": {...} } },
  "capabilities": { "qram": null | {"load": {...}, "store": {...}, "exch": {...}},
                    "measurement": {"mid_circuit": bool, "feedforward_latency": seconds},
                    "mbu": bool, "max_parallel": int | "unbounded", "max_predicate_depth": int | "unbounded" },
  "objective": { "weighted": { "<resource>": weight } } | { "lexicographic": ["<resource>", ...] },
  "imports": { "<model>": { "version": "...", "map": { "<their quantity>": ["<resource>", factor] } } }
```

**Legality and cost of an executed gate** are functions of (opcode,
operand classes, arity, **total control count** = declared controls +
predicate depth, parameters, ε): a gate executed under predicate depth p
is the (p + its own controls)-controlled gate, legal iff some `gates` or
`decompositions` entry covers that control count and those classes, with
that entry's cost. `any` class resolves to the lowest `qubit_second`
class with remaining capacity. A gate with no covering entry is a load-
time error. Imports (§8.5 of 0.2) are the versioned `imports` map.

### 8.4 Space budget

The scheduler's capacity constraint is peak live qubits per class
(`peak_qubits`), separate from `qubit_second`.

## 9. Objects, identity, linking, reversible ABI (object 0.3)

### 9.1 Sections (canonical text, §16)

```
  header      versions; producer id; ptr_width; target hint
  symbols     local index → (name, kind, signature, interface_hash)
  imports     (name, signature, pinned closure_hash?)
  functions   bodies (fn <tier> | oracle | action | perm_action | lproc)
  data        data images (hex) for local regions and globals
  devices     device models used by R code
  layout      H, Ac, Sc, global bases, images
  schedule    optional serialised §11 schedule (JCS JSON) bound to a target_hash
  certificate §12 (JCS JSON)
  coverage    §13 (JCS JSON)
```

Metadata sections are single-line **JCS-canonical JSON** values (§16).

### 9.2 Identity

**Signature** = (tier, kind, interface roles and bundle widths in order,
interface region types and roles, T, F, classical argument types, action
bounds, ABI version). **Canonical bytes of a symbol** = the bytes of its
`functions` entry from its header line through its last body line
inclusive (grammar §16), with every reference to another symbol replaced
as below. **Interface hash** (compile time) = SHA-256 over the canonical
bytes with each reference to a defined symbol replaced by that symbol's
interface hash (hex) and each reference to an unresolved import replaced
by `SHA-256(name ‖ 0x00 ‖ canonical signature)`. **Closure hash** (link
time) = the same with resolved closure hashes substituted. **SCCs** of
mutually referencing symbols: order members lexicographically by name,
replace intra-SCC references by `$<index>`, hash the concatenation of the
members' canonical bytes in that order (`scc_hash`); member identity =
SHA-256(`scc_hash` ‖ index). **object_hash** = SHA-256 over all sections
except `schedule`, `certificate` and `coverage`. `reference_program_hash`
of an oracle = its interface hash. **Program-point id** = `(symbol
interface hash, block name, instruction index within the block)`.

### 9.3 Linking

Imports resolve by name + signature (link error on mismatch; a pinned
hash additionally requires equality); the resolved closure hash is
recorded in the linked certificate. Equal-hash duplicates deduplicate;
unequal hashes under one name, and conflicting `devices`/`layout`/
`data` entries, are link errors. Linking = resolution, validation,
composition of certificates (§12.3), rebinding of certificates to
closure hashes.

### 9.4 Reversible ABI

- **CC/R calls**: classical frame; the callee's R history frames follow
  the call frame on the caller's history stack; `uncall` reverses the
  most recent unreversed call (LIFO, §7.4).
- **Region calls**: interface bundles and regions are passed in declared
  order and owned by the caller; the callee owns its workspace and
  returns it clean, local regions at image, borrowed bundles returned.
- **Frame descriptor** (in every region's certificate): interface slots
  (role, width, class requirement), scratch requirement by class and
  cleanliness, retained-history requirement (oracles: B × frame width),
  borrow requirement (bundles it `qborrow`s). A caller MAY pass a
  **shared frame** satisfying the descriptor only when the caller's live
  values and history are disjoint from it for the call's duration (suite
  F checks live ranges); a callee `qborrow`s only from the caller's
  designated idle set.
- Variants (controlled, adjoint, controlled-adjoint) use the same
  descriptor.

## 10. Launch ABI (launch 0.3)

**Model.** A run executes a **device CC entry function**. The host passes
classical arguments, budgets and opaque **register ids** naming device-
resident quantum state that persists between runs, and receives
classical results, fault codes and declared read-back measurements.
Host code never holds a wire. Measurements whose results affect control
run in device CC.

**Invocation state machine.** `CREATED → RUNNING → (SUSPENDED ⇄ RUNNING) → COMPLETED | HOST_REQUEST ⇄ RUNNING | FAILED`; `COMPLETED → REVERSED`
(via `bennett_reverse`) `→ CLOSED` (via `bennett_run_close`). Run records
(history, classical args and register ids of every Q invocation in
order) are retained until `bennett_run_close`.

**Types** are opaque with versioned constructors/accessors; the fields
are normative:

```
  bennett_arg      : tagged union { INT(width, value) | F64 | QREG(id) | TOKEN(id) }  matched in order to the entry signature
  bennett_result   : { classical results [bennett_arg], fault_codes [u64], measurements [(qreg id, bits)], tape_length }
  bennett_request  : { service id, payload bytes }    # a host-service request raised by device CC
```

```c
  bennett_status bennett_load      (const uint8_t* object, size_t len, const uint8_t* target_jcs, size_t tlen, bennett_program** out);
  bennett_status bennett_unload    (bennett_program*);
  bennett_status bennett_budget    (bennett_program*, const char* region, uint64_t steps, uint64_t heap, uint64_t stack, uint64_t depth, bennett_token* out);
  bennett_status bennett_qreg_new  (bennett_program*, const char* cls, uint32_t n, bennett_qreg* out);      // clean
  bennett_status bennett_qreg_prepare(bennett_program*, bennett_qreg, const uint8_t* bits, size_t nbits);  // X gates on a clean register; invalidates no run
  bennett_status bennett_qreg_free (bennett_program*, bennett_qreg);                                        // must be clean
  bennett_status bennett_run       (bennett_program*, const char* cc_entry, const bennett_arg* args, size_t n, bennett_run_id* out);
  bennett_status bennett_wait      (bennett_program*, bennett_run_id, bennett_result** out, bennett_request** req_out); // returns in COMPLETED, FAILED or HOST_REQUEST
  bennett_status bennett_reply     (bennett_program*, bennett_run_id, const uint8_t* payload, size_t len);  // answers a HOST_REQUEST, run resumes
  bennett_status bennett_suspend   (bennett_program*, bennett_run_id);   // takes effect at the next CC instruction boundary outside any region
  bennett_status bennett_resume    (bennett_program*, bennett_run_id);
  bennett_status bennett_reverse   (bennett_program*, bennett_run_id);   // see eligibility
  bennett_status bennett_run_close (bennett_program*, bennett_run_id);
  bennett_status bennett_tape      (bennett_program*, bennett_run_id, bennett_tape_iter** out);
  bennett_status bennett_estimate  (bennett_program*, const char* region, bennett_token, bennett_estimate** out);   // no execution
  bennett_status bennett_coverage  (bennett_program*, bennett_coverage** out);
  // errors: E_VERSION E_PTR_WIDTH E_DEVICE_MISSING E_GATE_UNSUPPORTED E_TARGET E_BUDGET E_QREG_NOT_CLEAN E_INVALID_STATE E_NOT_REVERSIBLE E_SCHEDULE_INFEASIBLE
```

**Reverse eligibility.** `bennett_reverse` is valid only in `COMPLETED`,
and only if the run performed no `measure` and every register it touched
has not been prepared, freed or used by a later run (`E_NOT_REVERSIBLE`
otherwise). It reverses the run's record in reverse order: R segments by
`uncall`, each Q invocation by re-application (oracle) or adjoint
(action) with the recorded classical args and register ids, CC segments
by restoring their recorded classical state.

## 11. Scheduling interface (sched 0.3)

```c
  bennett_status bennett_sched_schedule(const bennett_sched_request*, bennett_sched_response**);
  // request (opaque, accessors): object bytes, target JCS bytes, region interface hash, variant,
  //          objective, budget (B, heap, stack, depth), classical parameters, ε_total, capacity per class,
  //          scheduler version requested
  // response: SCHEDULED(schedule bytes, certificate bytes) | INFEASIBLE(reason) | UNSUPPORTED(feature)
```

**Schedule** (JCS JSON; the object's `schedule` section): `{ bindings: {
object_hash, target_hash, region, variant, budget, params_hash, epsilon
}, entries: [ { point: <program-point id>, kind: cleanup | alloc | gate |
structure | start, realisation: reverse | recompute | mbu, class, scheme,
params, epsilon_share, start_time } ] }`. **Obligations:** satisfy §6;
respect capacity; report every declared resource; be reproducible from
the request plus scheduler version. A consumer validates every binding
and every point id against the object, then executes the schedule
**verbatim** or rejects it (`E_SCHEDULE_INFEASIBLE`) and requests a
replacement; it never alters program semantics. The VM uses this
interface at run time with the run-time budget in the request.

## 12. Certificate (cert 0.3; JCS JSON)

### 12.1 Claims

Each verification claim has a **kind** with a normative payload and a
versioned checker:

| kind | payload | checker obligation |
|---|---|---|
| `exhaustive` | domain: per interface bundle `{width, lo, hi}` ranges; expected: `oracle` \| `permutation(<hash of P as a table or program>)` | re-execute every element against the reference interpreter |
| `sampled` | domain; `sampler: {algorithm: "xoshiro256**", version, seed, count}` | replay the sample; **evidence** |
| `structural` | the rule invoked (`borrow_frame_VWV`, `inverse_pair_library`, `adjoint_table`) and the sub-claims it rests on | check the rule's side conditions syntactically |
| `numerical` | `{widths, metric: "operator_norm" \| "diamond", bound, method: "interval_arithmetic" \| "rational_exact", precision}` | recompute the bound by the named method; agreement without a bound method is **evidence** |

### 12.2 Schema

```
  versions, bindings: { object_hash, interface_hash, closure_hash?, reference_program_hash, dialect_mapping_version, target_hash, schedule_hash? }
  producer: { name, version, materialisation: { llvm_version, pipeline, normaliser_version } }
  regions: { <interface_hash>: {
      kind, signature, bounds, frame (§9.4), resources { <name>: value }, gates_used { <gate>: { count, scheme?, epsilon? } },
      verification: { oracle: <claim>, borrow_frames: [<claim>], inverse_pairs: [{g, ginv, <claim>}], channel: [<claim>],
                      fault_rate: { domain, faults_by_code, undefined_excluded, layout_dependent_excluded } },
      cleanup: { <variant>: [ { point, realisation } ] },
      error: { local_epsilon, inclusive_epsilon },
      definedness_assumptions: [ <assumption id from the dialect spec> ] } }
  composition: { multiplicities: { <interface_hash>: n }, epsilon_total, method: "sum_over_multiplicities" }
```

### 12.3 Composition

`inclusive_epsilon(R) = local_epsilon(R) + Σ_callees n_c × inclusive_epsilon(c)`;
operator-norm bounds on unitaries convert to diamond-norm bounds on
channels by the factor 2 before summation with channel bounds. Linking
recomputes `composition` over the closure.

## 13. Coverage (coverage 0.3; JCS JSON)

`[ { point: <program-point id of the reference body>, source_location: <dialect-spec stable id>, classification: "lowered" | "trapped" | "shimmed", reason, fault_code?, shim_hash?, count } ]`.

## 14. Formal model

### 14.1 Reference interpreter *(normative)*

Executes an oracle's **reference body** per basis configuration:
locations and cells are bit-vectors, predication is `if`, each §4.2 row is
its classical function, `fault` records the code and halts, `lift.retval`
halts with success, the step counter counts executed rows, counters are
integers compared without wrap. It **defines** F_B and the budget unit
and rejects any body containing a non-permutation gate.

### 14.2 Quantum state semantics

The state of a Q region is a vector in ⊗ over live wires in allocation
order (bundles little-endian). `qalloc` tensors |0⟩ factors; `qfree`
removes clean factors; `qborrow` introduces a factor in unknown state
possibly entangled with a reference system R, and the region's operation
is required to be U ⊗ I on it (§5.6); gates act by §4.4's matrices under
the active predicate; `measure` (CC) is the projective computational-
basis measurement with Born probabilities, consuming the wires.

### 14.3 Theorems

- **T1 (totality).** For every well-formed oracle, budget and x ∈ D, the
  reference interpreter halts within B + 1 rows and F_B(x) is unique.
- **T2 (prefix reversal).** For every executor whose oracle realisation
  is a composition of ε = 0 permutation gates implementing §5.2 steps 1–4,
  on every x ∈ D every non-interface wire is clean after step 4 and
  borrowed bundles hold their initial values. *(Steps 1–2 are a
  permutation Π on workspace ⊗ interface; step 3 acts on tgt, fr
  controlled on workspace; step 4 applies Π⁻¹.)*
- **T3 (permutation theorem).** If the realised unitary V of a circuit on
  span(D) is a permutation matrix and for every x ∈ D the final basis
  tuple equals P(x), then V|span(D) = P: no relative phase, no residual
  entanglement. Applied to oracles (P the §5.2 tuple), permutation
  actions (P = |g(x)⟩, workspace clean) and borrow frames (P = P' ⊗ I).
- **T4 (round trip, R).** For every finite valid R trace with retained
  history and tapes, `uncall` in LIFO order restores classical state,
  memory, allocation metadata, device-model state and history to their
  entry values; observed external events are not retracted.
- **T5.** As §6.3.
- **T6 (executor agreement).** Two executors conforming to §3–§7 on one
  target with the same decompositions produce, on every x ∈ D, the same
  final tuple for every oracle (exact) and, for every action, unitaries
  within `inclusive_epsilon₁ + inclusive_epsilon₂` in operator norm
  (channels: diamond norm, after the ×2 conversion).

### 14.4 Mechanisation *(deferred)*

## 15. Conformance suites

| Suite | Class | Tests |
|---|---|---|
| A | Executor | classical ISA; R round trip with history, tapes, loops, recursion, fault records (T4) |
| B | Executor | oracle totality and prefix reversal (T1, T2): every fault code; B = 0; boundary halts; `lift.call`/`lift.ret` recursion; nested oracle faults and matched re-calls; interface regions restored |
| C | Executor, Producer | T3 over full D at exhaustive widths for oracles, permutation actions, `qinplace` pairs, borrow frames; T6 agreement among VM, specialiser, inlined/structure-recovered forms and the reference interpreter |
| D | Executor | channel and unitary comparison (Choi state with reference system) for ε > 0 realisations and MBU cleanups; controlled-interference tests; numerical-bound methods |
| E | Target author, Executor | JCS parsing; cost-expression evaluation; aggregation per kind; timing model; control-count legality; import maps |
| F | Producer | linearity and versioning; disjointness; write sets and frame sizing; terminators; permutation-only oracles; §6 transfer rules and windows; adjoint table; borrow-frame rule; acyclic action graphs; grammar; hashes; linking; frame-descriptor live ranges |
| G | Launch | every §10 entry point and state transition; suspend at CC boundaries only; HOST_REQUEST/reply; reverse eligibility and order |
| H | Scheduler | §6 validity; capacity; reproducibility; stored-schedule validation and verbatim execution; INFEASIBLE/UNSUPPORTED |

## 16. Canonical textual form (normative)

### 16.1 Lexical

UTF-8, LF line endings, one instruction per line, tokens separated by
exactly one space, no trailing spaces, no blank lines except one between
sections. `NAME := [A-Za-z_][A-Za-z0-9_.]*`; `INT := -?[0-9]+` (no leading
zeros except `0`); `FLOAT :=` shortest round-trip decimal with a `.` or
exponent, finite only; `STRING := "..."` with escapes `\" \\ \n` only;
`HEX := [0-9a-f]*` even length. Metadata JSON is RFC 8785 canonical on one
line.

### 16.2 Grammar

```
  object     := header NL section*
  header     := "bennett-object" SP "isa=" VER SP "object=" VER SP "launch=" VER SP "sched=" VER SP "cert=" VER SP "coverage=" VER SP "target=" VER SP "ptr_width=" INT
  section    := NL "section" SP SECTNAME NL body
  SECTNAME   := "symbols" | "imports" | "functions" | "data" | "devices" | "layout" | "schedule" | "certificate" | "coverage"
  body       := jsonline              (symbols, imports, devices, layout, schedule, certificate, coverage)
              | dataline*             (data)
              | function*             (functions)
  jsonline   := JCS-canonical JSON object NL
  dataline   := NAME SP HEX NL
  function   := fhead NL regs? block+
  fhead      := ("fn" SP TIER | "oracle" | "action" | "perm_action" | "lproc") SP "@" NAME SP iface
  TIER       := "cc" | "r"
  iface      := "(" plist ")" SP "(" plist ")" SP "(" plist ")" SP "(" plist ")" SP "(" plist ")"
                 -- oracle: (in..) (tgt) (fault) (mem..) (args..); action: (mut..) (in..) (mem..) (args..) ()
                 -- lproc: (params..) (result) () () (); fn: (params..) (results..) () () ()
  plist      := (param ("," SP param)*)?
  param      := NAME ":" type (SP ROLE)?
  type       := "i" INT | "ptr" | "f64" | "token" | "wire" | "wire[" INT "]" | "reg[" INT "]" | "region[" INT "," INT "]"
  ROLE       := "in" | "mut"
  regs       := "regs" SP "{" SP (NAME ":" type ("," SP NAME ":" type)*)? SP "}" (SP "heap" SP INT)? (SP "alloctab" SP INT)? (SP "stack" SP INT)? (SP "bounds" SP "{" INT ("," SP INT)* "}")? NL
  block      := "^" NAME "(" plist "):" NL instr+
  instr      := (NAME ("," SP NAME)* SP "=" SP)? OPCODE (SP operand)* (SP "{" NL instr+ "}" (SP "{" NL instr+ "}")?)? NL
  operand    := NAME | NAME "[" INT "]" | "@" NAME | "^" NAME ("(" (NAME ("," SP NAME)*)? ")")? | INT | FLOAT | STRING | "(" (NAME ("," SP NAME)*)? ")"
  OPCODE     := any mnemonic of §4 (with its dotted suffix), e.g. "lift.add", "lift.icmp.ult", "lift.load.i32", "mcx", "oracle_call"
  VER        := INT "." INT
```

The canonical bytes of a function are its text from `fhead` through its
last `instr` line inclusive. A binary encoding *(deferred)* MUST round-
trip through this form. An executor refuses an object whose ISA major
differs from its own and MAY accept a lower minor.

### 16.3 A complete example object

```
bennett-object isa=0.3 object=0.3 launch=0.3 sched=0.3 cert=0.3 coverage=0.3 target=0.3 ptr_width=32

section symbols
{"0":{"interface_hash":"c9303119bc1bb381323f77d8ab6a3c24f15b7f19c4d740670312afb91c2d6188","kind":"oracle","name":"inc8","signature":{"abi":"0.3","args":[],"fault":4,"in":[8],"kind":"oracle","mem":[],"tgt":8,"tier":"q"}}}

section functions
oracle @inc8 (x:wire[8] in) (t:wire[8]) (f:wire[4]) () ()
regs { rx:reg[8], one:reg[8], r:reg[8] }
^entry():
lift.mov x rx
lift.const 1 one
lift.add rx one r
lift.retval r
```

`H_inc8` is the SHA-256 (hex) of the function's canonical bytes (the
seven lines from `oracle @inc8 …` through `lift.retval r`, joined by LF
with no trailing LF): `c9303119bc1bb381323f77d8ab6a3c24f15b7f19c4d740670312afb91c2d6188`.
The object has no imports, so its closure hash equals its interface
hash. With B ≥ 4 and any budget, F_B(x) = (x + 1 mod 256, 0) for every x;
with B = 3, F_B(x) = (0, FAULT_BUDGET_STEPS) for every x.

## 17. Open items *(deferred, asserted non-semantic)*

1. Binary encoding. 2. Gate-name registry. 3. Further device models.
4. Mechanisation. 5. Bit layout of the opaque launch/scheduler objects.
