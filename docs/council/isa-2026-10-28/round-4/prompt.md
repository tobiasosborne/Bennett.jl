# Council

You are a member of a three-model council grading the document below, the fourth normative draft (0.4) of the Bennett virtual ISA specification (the bennett-isa-spec contract named in the north-star document supplied as background). Grade it against the rubric on the absolute scale. Be exacting and skeptical: verify every technical premise against your own knowledge; name any that is false. Grade the vision for being the right vision, stated precisely; do not deduct for things that are not built yet. A blocking issue is one that would make the project build the wrong thing if uncorrected; everything else is a suggestion. Return `accept` only if the blocking list is empty.

Be constructive, not only critical: for every blocking issue the `fix` field must say concretely how to overcome it, at vision level (the sentence or semantics the document should state, or the decision it should take), not merely that it is wrong. Where you see two viable ways out, name both and say which you would take. In `path_to_accept`, state the minimal set of changes that would make you return `accept`; if you already accept, say what would raise the lowest-scoring criterion by one point.

You may read the repository you are running in (read-only) to check claims about the current code; its root contains Bennett-NorthStar.md (the document, identical to the snapshot below), Bennett-Reboot-Blueprint.md and Bennett-V2-PRD.md (the superseded plans), worklog/ (session logs; chunk 121 has the 2026-10-28 ground-truth survey), reviews/2026-09-26-astra/ (the last review campaign), and src/ (the deprecated v1). Reading is optional; the snapshot below is what you grade.

Answer only with JSON matching the schema.

# Previous round (3)

Verdicts: codex: revise, muse: revise, opus: revise

Blocking issues raised last round:
- [codex] B1 (§§3.6, 4.2, 5.2, 14.1–14.3): The step construction still does not consistently implement its table. Section 3.6 requires every write to use compute-and-exchange with displaced history, whereas oracle_call, perm_call, free, and several call/return updates specify direct reversible operations and different inverses. In particular, repeating lift.free cannot undo it: the forward operation clears live_i, so its repeated live-entry search no longer finds that allocation. Success is also inconsistent: qjump n is not prohibited, reaches HALT with faulted=0, and commits success without lift.retval; larger constant targets have no dispatch predicate. Fix proposed: Define each row as an atomic old-state transition with an explicit outcome and a complete reversible realization. Distinguish assignments that retain displaced values from direct permutations that do not; give both their complete scratch-cleaning inverses. For free, retain the selected allocation identity and undo the live-bit change without repeating the forward live-entry validation. Validate all direct and indirect targets, and require that only lift.retval produces a successful terminal outcome. Prohibit jumps to HALT, or introduce an explicit terminal-outcome field; I recommend prohibiting such jumps.
- [codex] B2 (§§3.2, 3.6–3.7, 4.2 lift.call/lift.ret/lift.alloc, 7.2): The procedure model lacks a defined mapping from separately serialized lprocs to the oracle's pc range, an exact activation-record layout/R_f, input-to-location initialization, and root-return behavior. Its counters also have a concrete representational contradiction: atop:wire[Ac] can never equal 2^Ac, and sp:wire[Sc] cannot hold the allowed full-stack endpoint 2^Sc. The full-width-comparison instruction does not prevent wrapping when those accepted values are stored. Fix proposed: Define canonical procedure/instruction addresses over the linked lifted closure, exact activation records, parameter/result bindings, initial fp/depth, and invalid-return behavior. Separate address-index widths from occupancy-counter widths: a capacity of 2^A needs an occupancy counter of at least A+1 bits, with additional widening for prospective increments. Validate all launch limits against actual region capacities before execution. Either reject lift.ret outside a procedure statically or give it a named underflow fault; I recommend static rejection where provable and a defined fault otherwise.
- [codex] B3 (§§4.2, 4.7, 5.1, 7.1–7.2): The memory model still admits different machines. Two zero-size allocations return the same base and remain live, contradicting free's unique-match rule. The classical initial bump address, initial live records for globals, and separation of globals from a heap starting at zero are unspecified. Heap limits are not explicitly bounded by the byte region. Finally, lifted accesses address only the implicit mem region, while lifted call forms provide no interface-memory arguments; adding mem parameters therefore does not define how a lifted oracle accesses caller-owned regions. Fix proposed: Specify initial memory, reserved ranges, allocator state, and allocation-table contents from the layout, including the classical bump base. Define zero-size allocation so free is unambiguous: reserve a distinct address for each allocation, or introduce allocation identities with a deterministic free rule; I recommend distinct reserved addresses. Require allocations and whole accesses to fit the physical region, and require each bounds check to match the access's address version and length. Define address-to-region translation or explicit region operands, and carry memory arguments through every applicable lifted call form.
- [codex] B4 (§§3.3, 4.1–4.2, 4.6–4.7, 5.1, 9.4): The instruction typing and ownership contract remains incomplete. Named regions have no specified consume-and-reproduce ownership/version rule comparable to bundles. Several classical forms and conversions are blank; operand-width compatibility and location aliasing are unstated. load.iN permits widths for which N/8 is not an integer, and measurement can produce an iN outside the declared 1–128-bit classical type range. Lifted call forms also omit classical and memory arguments supported by callee signatures. Fix proposed: Publish a typed operand/result schema for every opcode, including literal rules, permitted aliasing, conversion widths, memory widths, and measurement limits or chunking. Treat a region as one owned value with explicit implicit-version threading through accesses and calls, or define an equivalent exclusive-reference discipline; I recommend the same consume-and-reproduce convention used for bundles. Make all call forms carry the complete declared interface and require signature agreement.
- [codex] B5 (§§6.1–6.3; T5; suite F): The new transfer table still cannot justify T5. A predicated qexch does not simply swap provenance: its output is selected between the old operands and depends on the predicate. oracle_call omits dependencies on interface memory, and action-call rules omit mutable-memory effects. Consequently, a copied oracle result can retain an apparently open window after its actual memory dependency changes. Several initialization, control, and cleanup-transfer cases are also absent. Fix proposed: Define transfer functions over immutable value versions, active control context, and conservative memory read/write sets for every operation. Predicated exchange must include both possible operands and its predicate unless a stronger checked relation is available. Calls must expose memory and wire dependency/effect summaries. Bind each cleanup to the exact computing sequence and the versions needed by its inverse, rather than inferring safe cleanup from the perm label alone. Retain the corrected logical-amplitude interpretation of T5.
- [codex] B6 (§5.5; §6.1; suite F): The matched nested cleanup now permits a nonzero fault register, but its version rule is contradictory. The first call changes tgt, so a second call cannot both consume the current target and have the same target operand version as the first call. Requiring the two calls' operand versions to match also does not describe the corresponding returned fr version. Fix proposed: Define a matched cleanup invocation that consumes the first invocation's returned tgt/fr versions and requires its original input and memory values to remain available unchanged. The two calls share a dynamic invocation identity, token, and callee identity; their target versions are predecessor/successor-related, not identical. Alternatively remove explicit second-call cleanup and retain the result until prefix reversal. I recommend the explicit matched form.
- [codex] B7 (§§3.4, 7.3–7.4, 9.4; T4): The R model still does not define dynamic SSA instances in loops: the same static non-parameter definition executes repeatedly, but is declared immutable within one activation. It is unclear which instances survive or how reversal resolves them. LIFO call identity also does not establish the corresponding return state when intervening CC operations modify shared memory or quantum registers. Device operations introduce array types absent from the ISA, and ENTROPY_EXHAUSTED has no defined fault-code representation. Fix proposed: Define dynamic SSA environments explicitly, retaining each executed definition until reversal or specifying a checked recomputation scheme; I recommend retained dynamic instances as the reference model. Record complete invocation boundaries and require return-state dependency versions to match, or reverse the intervening suffix first. Specify fault-prefix reversal. Give device arguments/results an expressible representation, versioned operation signatures, fault encodings, and exact state-restoration rules, including allocation-table entry creation and block-sector presence.
- [codex] B8 (§8): The target format is not yet independently interpretable. The expression grammar gives no precedence or associativity, JSON encoding, table declaration/epsilon-decade convention, or behavior for eps=0. The gate schema does not encode the claimed general function of operand-class tuples, parameters, and control count. Named decomposition schemes have no normative definitions or resolution mechanism. Custom resource aggregation and validation of rates, durations, weights, and matching entries are also incomplete. Fix proposed: Use a closed JSON expression AST, or fully specify textual parsing and arithmetic; I recommend the AST. Define table indexing, exact-mode expressions, errors, and numeric evaluation. Give gate realizations explicit operand-class patterns, arity/control/parameter constraints, and deterministic matching rules. Resolve decompositions to specified templates or versioned definitions. Define aggregation for every resource kind, treatment of classical/effect time, and validation of nonnegative finite costs and objectives.
- [codex] B9 (§§9.1, 12–13, 16): The interchange grammar remains incomplete and inconsistent. Metadata field schemas are largely prose placeholders; jsonline requires an object although coverage is an array. Output syntax is not reconciled between §4, the optional assignment production, and the example's trailing destination operands. Section ordering, duplicates, nested instruction numbering, and several lexical choices remain undefined. The example hash is correct without a final LF, but the grammar includes that LF in the function's final instruction line. Exact large integers in domains and budgets also need an encoding compatible with JCS's binary64 number model. [RFC 8785 §3.1](https://www.rfc-editor.org/rfc/rfc8785#section-3.1) Fix proposed: Complete the instruction grammar and concrete schemas for every metadata section, with required fields, types, extension handling, canonical ordering, and duplicate rejection. Choose one destination syntax and one precise final-newline/hash convention. Encode integers beyond the exact supported JSON-number range as canonical decimal or hexadecimal strings. Update the complete example to satisfy the initialization/result rules and publish its exact object bytes and hashes.
- [codex] B10 (§§9.2–9.3, 11–12): Function-byte hashing still omits semantic inputs outside the function text, including ptr_width, ISA semantics, data images, and layout. Changing a local region's image can therefore change F_B without changing interface_hash or reference_program_hash. SCC member derivation does not specify raw-versus-hex hash representation or index encoding. schedule_hash and params_hash also lack exact definitions. Fix proposed: Hash a versioned semantic envelope containing the body, complete signature, relevant layout/images, semantic versions, and dependency identities. Retain separate relocatable and resolved identities, but bind executable certificates and caches to the resolved semantic closure. Define SCC substitution and member derivation byte-for-byte with domain tags and encoded indices. Define every remaining hash's exact input and serialization, excluding self-referential certificate fields.
- [codex] B11 (§10; §§7.4, 9.4): Launch reversal remains ambiguous and can duplicate inversions: R history records Q calls, while the run record retains every Q invocation, and reverse instructs both reversal of R segments and inversion of each Q invocation. Eligibility tracks quantum registers but not shared classical memory, devices, or intervening host services. There is no CC instruction that raises HOST_REQUEST, no response-to-result binding, and no complete close/handle-invalidation rules for measured or failed runs. Fix proposed: Define an invocation tree or another ownership rule under which every operation is reversed exactly once; I recommend R records owning their nested Q inversions. Track dependency versions for all shared state and define exclusive ownership during active runs. Specify the host-service request instruction, response types, suspension/resumption transitions, and reversal policy for such requests. Define close transitions for completed, failed, and reversed runs, plus measurement consumption and handle invalidation. Restrict reversal where required dependencies or reversible records are absent.
- [codex] B12 (§§10–11, 17): The promised versioned constructors/accessors are not present. A caller cannot construct an array of opaque bennett_arg objects, inspect results, construct a scheduler request, or release returned objects from the declarations given. Status/handle definitions and ownership lifetimes are absent. There is also a concrete C namespace collision: bennett_estimate and bennett_coverage are used as both unqualified type names and function names. Fix proposed: Publish a complete versioned C header with opaque-type declarations, argument/request builders, accessors, destruction functions, status values, handle types, buffer lengths, and ownership/lifetime rules. Use a builder handle or an array of pointers instead of requiring caller allocation of incomplete opaque elements. Rename the colliding types or functions. Opaque internal layouts may remain deferred.
- [codex] B13 (§§9.2, 9.4, 11): A stored schedule cannot yet be executed verbatim. A static block/instruction point does not distinguish loop iterations, nested invocations, prefix reversal, or the many dispatch/history/decomposition gates generated from one reference instruction. Entry fields have no per-kind semantics or completeness/default rules. Variant=controlled does not bind the number of inherited controls, although legality, cost, and scratch requirements depend on it; the same-descriptor assertion does not establish a valid common bound. Fix proposed: Define either identifiers for expanded execution occurrences or a hierarchical schedule language with normative expansion; I recommend the hierarchical form. Identify invocation, iteration, forward/reverse phase, and generated operations where choices differ. Specify every entry kind and validate dependency order, realizations, accuracy, and capacity. Bind schedules to the resolved closure, all classical parameters and bounds, and the complete control context. Parameterize frame requirements accordingly or prove a declared common upper bound.
- [codex] B14 (§§12, 14.3, 15): The certificate remains insufficient to implement the promised independent checker. Domain ranges do not encode all of D, particularly interface memory and borrowed systems; endpoints and product construction are unspecified. The sampler lacks seed expansion and domain-mapping rules. Structural claims lack executable proof payloads and subclaim references, while interval_arithmetic/rational_exact name method families rather than checkable witnesses. Error totals are untyped despite mixing operator and diamond bounds. Exact measurement-assisted realizations also need a channel claim, rather than being accepted solely through a permutation execution claim. Fix proposed: Define complete claim schemas and versioned checking rules: exact domains including memory/borrowed values, deterministic sampling, structural proof witnesses with explicit assumptions and subclaim identities, and rigorous numerical-bound witnesses. Type every local/inclusive error by metric and variant, apply operator-to-channel conversion once at the stated boundary, and derive multiplicities from the realized schedule. Require channel validation for measurement-assisted implementations and phase-sensitive operator validation for controlled unitary variants. Add witness formats for any supported minimality claims.
- [muse] B1 (3.6, 4.2, 5.2): Section 3.6 prescribes out-of-place compute into disp_j followed by qexch for every written location or cell. That does not implement lift.oracle_call, lift.perm_call, lift.retval, lift.free or fault, which are XOR or in-place operations. Conditional-fault rows also write faulted/code, but those writes are absent from their write sets and several inverses are given as '-' or only 'exch back', so the fault side effect has no specified reversal. lift.parmov can also fail on cycles if compute and exchange are interleaved per destination. Two executors can therefore build different step permutations and frame layouts. Fix proposed: Classify each row as either assignment (compute into disp, then exchange) or direct reversible update (executed directly under at_k, no disp). Add faulted/code to the write and inverse columns for every conditional-fault row: under flag, faulted ^= 1 and code ^= row code, reversed by the same controlled XOR using the retained flag. State that lift.parmov first computes all destinations into disp_1..disp_m and only then performs all exchanges.
- [muse] B2 (3.6, 3.7, 4.2, 16.2, 16.3): The index space of the step machine is undefined for multi-block bodies and multiple lprocs: no rule concatenates blocks and lproc bodies, assigns lproc entry indices, or orders fallthrough between blocks. lift.ret must obtain ret_index before it changes fp, but section 3.6 computes successors after execution. lift.ret also XORs into 'the caller's w of the matching call', although the record stores no destination identifier and no layout maps callee locations to record cells. Section 3.7 says inputs are copied into 'their locations', while the example reads x directly with lift.mov; no input-to-location mapping is declared. Fix proposed: State a flattening rule for blocks and lproc bodies into one instruction-index space. Define the record layout field by field, including location order, padding of narrower locations into stack cells, parameter locations, and a stored destination-location identifier. Add a frame successor field: lift.ret first copies ret_index into it before mutating fp, then XORs the saved result value into the destination by comparisons against the stored identifier. State whether interface names are read-only pseudo-locations in oracle bodies or add an explicit regs mapping from each input and lproc parameter to its location; remove the duplicate entry copy if bodies read inputs directly.
- [muse] B3 (4.2, 5.1, 7.1, 7.2): Globals have fixed bases and images in layout, but boundscheck searches only alloctab and no rule creates initial alloctab entries for globals, so global accesses always fault. Heap allocations start at heap_base=0 with no stated disjointness from globals, and heap_limit is not required to fit the 2^H-cell mem region. If H<ptr_width, conversion from a ptr to an H-bit cell index is unstated. lift.load.iN is defined over N/8 cells although iN allows N not divisible by 8. An oracle also cannot name an interface region in lift.load/lift.store, which always access the singular local mem, so caller-owned quantum memory is not usable as lifted memory. Fix proposed: Make lifted load/store/boundscheck name their region, e.g. lift.load.iN @db a -> w. Define one address partition per memory region: disjoint static/global ranges and heap range, with heap_base and heap_limit, and require the end of the heap range to be at most 2^H. Generate initial alloctab entries for globals in a stated layout order, or include the static ranges directly in the boundscheck predicate. Restrict N to multiples of 8 and state that address circuits use the low H bits, with boundscheck proving the remaining bits zero. State the same initial bump pointer and partition for CC/R.
- [muse] B4 (5.3, 6.1, 6.2): The transfer rules are unsound for memory-dependent calls. oracle_call and permutation action_call set S from ins, mut, tgt and fr but omit cells of interface mem read by the callee. A later qstore to such a cell therefore does not close the window, yet a second call used as cleanup computes a different result and leaves residual entanglement. The table also lacks provenance results for qalloc and for the wire and cell after qexchm, and gives no stored-cell provenance. Separately, section 5.3 declares actions block-diagonal on in wires, but no checkable operand-position rule prevents an action body from targeting an in wire with x or h. Fix proposed: For oracle_call and permutation action_call, include {(r,i,v_i) for every cell of every in or mut region the callee may read} in each resulting dependency set. Add rows: qalloc gives perm with S empty; qstore gives the destination cell the provenance of the XORed value combined with the old cell value and address; qexchm swaps wire and cell provenance conservatively, including address and all-cell dependencies. Add a syntactic in-use rule listing which operand positions may target an in wire; I recommend allowing in wires only as controls, diagonal targets, copy/XOR sources and call in arguments unless a permutation-frame certificate proves restoration.
- [muse] B5 (3.3, 4.1, 7.3, 10): Device operations use [u8] and [u8;512], types absent from the type system and from effect operand forms. Initial clock value, block contents and console state are not stated, and the launch ABI has no way to supply the entropy tape on which section 7.3 makes an R run depend. The HOST_REQUEST state also has no in-program cause: no CC instruction raises a host-service request or receives the bennett_reply payload, and service ids have no namespace. Fix proposed: Either add byte-array types to section 3.3 or, preferably, define every device operation over (ptr,len) classical-memory arguments with bounds and result writes. State initial device state (console empty, clock 0, block map from a named data image or empty). Add an entropy-tape field to the run inputs. Add a CC instruction hostcall service ptr len -> (len) with a stated reply-buffer rule, synchronous transition to HOST_REQUEST, and errors for use in R or Q. Publish the service-id namespace rule.
- [muse] B6 (7.4, 10): The run record is a flat list of Q invocations plus R history, but an R call can contain Q calls whose reversal is already performed by uncall under section 7.4. Reversing the flat Q list and the R segment reverses such a call twice. CC segments are reversed by 'restoring their recorded classical state', but no CC state recording is defined. bennett_qreg_prepare is annotated 'invalidates no run', while reverse eligibility requires that a touched register has not been prepared since the run. Fix proposed: Define the run record as a nesting tree whose leaves are CC segments, R calls and Q calls, and define reversal recursively so a Q call inside an R call is reversed exactly once, by the R history rule. State what CC reversal records: either a start-of-run snapshot of device classical memory and register allocation state, or a store/alloc history equivalent to section 7.4. Delete 'invalidates no run' or remove 'prepared' from the eligibility list; I recommend that preparing a touched register invalidates reversal.
- [muse] B7 (8.1, 8.2, 8.3): The cost-expression grammar has no precedence or associativity, no numeric evaluation type or precision, no declared place for 'table', and no rule for log2inv_eps at eps=0. Variables are only k and eps, so width-dependent costs for qload/qstore/qexchm and predicate-depth control costs cannot be expressed. Whether a gate entry's integer 'controls' is an exact count or a maximum is not stated, the QRAM cost objects have no schema, and decomposition 'scheme' is a free name whose gate sequence no competitor can execute. Fix proposed: Give the expression grammar precedence, associativity, numeric type (I recommend exact rationals, with JCS decimal inputs parsed exactly), division-by-zero and eps=0 rules, and a declared 'tables' field. Add variables a (address width), w (cell width) and c (total controls), and state what k means per gate and QRAM operation. Define 'controls' as an exact count, a maximum, or a range by renaming it. Either normatively define each decomposition scheme name in a scheme registry section or require schemes to carry a parametric gate-sequence template in the target document; a schedule may reference only defined schemes.
- [muse] B8 (1.3, 10, 11, 12.2): Sections 10-11 still do not declare the constructors and accessors for the opaque types, so a C caller cannot build a bennett_arg array, read a bennett_result, or build a scheduler request; section 1.3 incorrectly says those accessors are normative in sections 10-11. The schedule binds params_hash and certificates bind schedule_hash, but neither hash's input bytes are defined. Schedule entries give one realisation enum (reverse|recompute|mbu) for cleanup, alloc, gate, structure and start kinds, so most kinds have no legal value and a validator cannot tell which of class, scheme, params, epsilon_share and start_time are required. Fix proposed: List every constructor, accessor, mutator and destructor for bennett_arg, bennett_result, bennett_request, bennett_sched_request, bennett_sched_response, bennett_estimate, bennett_coverage and the tape iterator, with ownership and error rules. Define params_hash as SHA-256 of a stated JCS encoding of the classical parameters and schedule_hash as SHA-256 of the schedule JCS bytes. Make realisation kind-specific (cleanup: reverse|recompute|mbu; gate: native|scheme name; alloc: class; start: start_time) and state which fields are required per kind.
- [muse] B9 (9.1, 9.2, 16.1, 16.2): The grammar reduces symbols, imports, devices, layout, schedule, certificate and coverage to one unspecified JCS line, but no schema defines their fields except by example. OPCODE is 'any mnemonic of section 4', while several section 4 forms are schematic or blank and operand modes/types such as ':in', ':consume' and 'tk:c' have no canonical-text encoding. Hash inputs remain inexact: how a reference token is replaced by a hash, what bytes a 'canonical signature' has, how an SCC index is encoded after scc_hash, and what byte sequence object_hash covers are all unstated. Fix proposed: Publish a JSON schema (field names, types, required/optional, extra-field rule) for symbols, imports, devices, layout, schedule, certificate and coverage, and a per-opcode operand table giving arity, operand kinds, modes and result placement in canonical text. Define hash inputs byte-exactly: reference replacement replaces the '@name' token with the 64-character lowercase hex hash; canonical signature is the JCS encoding of the signature object; SCC index and member identity use the decimal index in ASCII; object_hash is SHA-256 of the canonical object text with the schedule, certificate and coverage sections deleted including their preceding separator. Pick these or other explicit rules, but state them.
- [muse] B10 (5.2, 12.1, 12.2): Certificate claims still cannot be checked independently. The exhaustive domain encodes only interface bundles, although D in section 5.2 includes borrowed bundles and every cell of in regions, and lo/hi inclusivity is unstated. A permutation expectation may be only a hash of P, from which a checker cannot obtain expected outputs. The sampled claim names xoshiro256** and a seed but not how outputs map to domain elements, so two checkers replay different samples. Structural claims rest on 'sub-claims' that have no identifiers. Fix proposed: Extend domain encoding to every component of D, including mem regions as per-cell ranges or a stated whole-region width 2^A x W with lo/hi, and state that lo/hi are inclusive. For permutation claims, carry P itself as a table (stated index order) or a program (a named oracle symbol whose interface hash is given), not only its hash. Define sampled replay exactly: xoshiro256** output order, how 64-bit outputs map to each range (I recommend rejection sampling with a stated bound), and the order in which bundles and cells consume outputs. Define sub-claim references by claim index within the region entry.
- [opus] B1 (§4.2 lift.free / lift.alloc; §3.7; §7.1–7.2): Lifted allocation is neither reversible nor representable as written. (a) lift.free matches 'the unique i with live_i ∧ base_i = p' and flips live_i 'with no displaced value'. The control of that controlled-X depends on its own target, so the match cannot be uncomputed. The listed inverse ('same op') also finds no live entry after the free, so it faults instead of restoring the entry. (b) n = 0 is a valid allocation that does not advance the bump pointer, so the next allocation shares its base. 'The unique i with base p' is then false, in both the lifted and the CC/R allocator. (c) §7.2 uses Ac and Sc as region-size exponents (2^Ac table entries, 2^Sc stack cells), while §3.2/§3.7 use them as counter widths that must represent every limit without wrap. With those widths, `atop = 2^Ac` and `sp+R_f > 2^Sc` cannot be represented. (d) Nothing bounds heap_base + heap_limit by 2^H, so an allocation can extend past the end of `mem`. That contradicts §7.2's claim that an access wrapping past 2^H is outside every allocation. Fix proposed: State: match_i = (i < atop) ∧ (base_i = p), computed without reference to live. flag = ¬∃i: match_i ∧ live_i. Then live_i ^= match_i ∧ ¬flag, and match_i is uncomputed. The inverse is that same controlled flip on live_i, recomputing match from base only. Alternatively, displace the index i into the frame and use exchange-back; I would take the base-only match. Require allocation bases to be pairwise distinct by allocating max(n, 1) bytes (zero-size allocations stay unaccessible because boundscheck uses size n), in both lifted and CC/R. Introduce separate exponents A_tab and S_cells for the table and stack sizes, and require Ac ≥ A_tab + 1 and Sc ≥ S_cells + 1. Require heap_base + heap_limit ≤ 2^H, checked at load.
- [opus] B2 (§7.2 layout; §4.2 lift.boundscheck; §5.1 interface regions; §7.1): The lifted address space contradicts itself and the north star. heap_base = 0, so the first successful allocation returns the null pointer, and C code testing `p == NULL` diverges from native. Globals have 'fixed base addresses' in the same `mem`, which overlaps the heap starting at 0. alloctab is written only by lift.alloc, so lift.boundscheck, which the dialect places before every access, raises FAULT_UB_MEMFAULT on every access to a global. Interface `mem` regions are allowed in oracle signatures, but a lifted ptr addresses only `mem`, so a lifted body cannot reach them. That leaves rung 4's database over quantum-addressed memory inexpressible except as a baked-in image. §7.1 does not give the CC/R allocator's initial bump pointer, but the north star requires heap placement identical to the native comparison build. Fix proposed: State that the object's `layout` fixes: a null region [0, null_size) that is never allocated; global bases; heap_base above them (equal to the comparison link's shim heap base); and, for each interface region of an oracle, a base address in the lifted address space. At oracle entry, alloctab is initialised with one live, non-freeable entry per global and per mapped interface region, counted against the table size. lift.free of such an entry faults FAULT_UB_MEMFAULT. lift.load and lift.store dispatch to `mem` or to the mapped interface region by address range, preserving the role (`in` regions MUST be unchanged at exit). The CC/R allocator starts at the same heap_base. The alternative is to forbid `mem` parameters on oracles and keep databases as data images. I would take the mapping, since the north star's rung 4 needs it.
- [opus] B3 (§5.6 structural borrow frames; §12.1 `borrow_frame_VWV`): The structural rule ('V; W; V⁻¹ with V permutation-only, W touching neither the borrowed wires nor any wire V reads') certifies restoration without checking it, and its meaning depends on an undefined word. If 'reads' includes V's targets, W is disjoint from V altogether and the frame is vacuous: it cannot express the standard dirty-ancilla pattern, where W uses the borrowed wire as a control. If 'reads' means controls only, the rule is unsound. Take V = `cx b y`, W = `cx y z`, V⁻¹ = `cx b y`. The borrowed wire b is restored on every basis value, but z ends as z ⊕ y ⊕ b, so the public output depends on b and entangles with it. A `structural` claim of kind `borrow_frame_VWV` would label this proof. Fix proposed: Replace the rule with the toggling lemma and state its side conditions. A frame V; W; V⁻¹; W is restoration-safe if all of the following hold. V only XORs into borrowed wires functions of wires X, where W writes no wire in X. W's targets lie outside X, outside the borrowed set and outside W's own controls. Every gate of W has at most one borrowed control, so W's effect is affine in b. The net effect is then b-independent and b is restored, which is the pattern used for dirty-ancilla MCX (Gidney; Häner–Roetteler–Svore). Say explicitly that 'touches' includes targets. Frames of any other shape require an exhaustive or library T3 claim. A minimal alternative is to delete the structural rule and rely only on exhaustive or library frame certificates. I would take the lemma, because the north star's finite-D argument for large dirty pools depends on it.
- [opus] B4 (§9.2 identity; §12.2 bindings; §16.2 instr): Content identity omits semantic inputs, and canonical bytes are not unique. The interface hash, and therefore reference_program_hash, covers only the function text. The data images of local qregions and globals, the `layout` section (H, global bases, and after B2 heap_base and region mappings), ptr_width and the ISA major are not hashed, yet all of them change F_B. Two oracles that differ only in a baked-in table share their hash. Their certificates validate against each other, and 'equal-hash duplicates deduplicate' at link silently substitutes one for the other. Separately, the grammar admits a destination prefix `r = op …`, the §4 forms write `→ w`, and the example writes the destination as a trailing operand (`lift.add rx one r`). Two producers can therefore emit different bytes, and different hashes, for one program, and a parser cannot tell destination from operand except by convention. Fix proposed: Define the hashed envelope of a symbol as: its canonical function bytes; the canonical bytes of every `data` and `layout` entry it reaches (by name, in sorted order); the header's ptr_width and ISA major; and the callee hashes, substituted as now. Interface hash and closure hash are both computed over this envelope, and certificates bind to it. Fix one destination spelling: I recommend `w = op a b` everywhere, with §4 forms rewritten to match. Recompute the example's hash under the new spelling.
- [opus] B5 (§3.6, §3.7, §4.2 (indices, terminators, lift.ret/lift.retval)): The index space I[0..n) is not defined, although index values are data. The text says an oracle body is 'a sequence … over the oracle's locations and its lprocs' locations'. But the grammar has named blocks and separate lproc functions, and lprocs may come from other linked objects. No rule fixes the order of blocks, the placement of lprocs, or what happens when a block does not end in a terminator. lift.call pushes k+1, entry indices are taken from this layout, and qjumpr takes a runtime integer, so a body that computes jump targets means different things under different flattenings. Also: the terminator list omits qbranch. lift.ret executed with no active record (depth 0, at oracle top level) is undefined. Whether lift.retval inside an lproc halts the oracle with success is unstated. Fix proposed: State: I is the oracle's blocks in text order, followed by the lproc closure in a canonical order (sorted by closure hash, with the SCC index for mutual recursion), each block contiguous. A block must end in a terminator (qbranch added); fallthrough is ill-formed. Branch and call targets are written as labels in the text. qjumpr operands MUST be produced by a `lift.label ^b → w` constant, so no producer writes raw indices and executors may re-index extensionally. lift.ret with depth = 0 faults FAULT_UB_TRAP. lift.retval inside an lproc is ill-formed (suite F).

## Editor's response (what changed, what was declined and why)

# Editor's response to ISA round 3

Verdicts: all **revise**. Mean 3.04 (2.12 → 2.83 → 3.04). Twenty-nine
blockers (14 + 10 + 5). All accepted; draft 0.4 is a full pass. Status
reported to the maintainer: **no-go**.

## Accepted and changed

1. **Step table semantics** (codex B1, muse B1, opus B5). Rows are
   classified **assignment** (compute into `disp_j`, then exchange) or
   **direct** (in-place permutation); conditional-fault rows list
   `faulted ^= flag`, `code ^= flag·C` in their effects and inverse; the
   inverse of a step is spelled out (undo fault writes and direct
   permutations under the retained flag, exchange back, uncompute flag
   and succ, clean dispatch); `lift.parmov` computes all destinations
   before any exchange; a `succ` frame field holds data-dependent
   successors; **only `lift.retval` reaches HALT with success**, labels
   cannot name HALT, `qbranch` is a terminator, fallthrough is ill-formed.
2. **Index space and procedures** (opus B5, muse B2, codex B2). The
   flattening rule: oracle blocks in text order, then the lproc closure
   ordered by closure hash with SCC index, each block contiguous;
   `w = lift.label ^b` is the only source of index values; activation
   record layout field by field (`ret_index`, `prev_fp`, `dest`, all
   locations padded to one cell); `lift.ret` computes `succ` from the
   record before mutating `fp` and delivers the result by comparing the
   stored destination id; interface inputs are read-only pseudo-locations
   (the "copied at entry" duplication is gone); `lift.ret` at depth 0
   faults, `lift.retval` inside an lproc is ill-formed.
3. **Counters** (codex B2, opus B1). Size exponents (H, A_tab, S_cells)
   are separated from counter widths (Hc ≥ H+1, Ac ≥ A_tab+1, Sc ≥
   S_cells+1, Dc); `bennett_budget` validates limits against capacities.
4. **`lift.free` and allocation** (opus B1, codex B3). Match on base only,
   flag from `match ∧ live ∧ ¬pinned`, controlled flips on the live bits,
   match uncomputed; bases pairwise distinct via `max(n, 1)`; zero-size
   allocations inaccessible; `heap_base + heap_limit ≤ 2^H`.
5. **Address layout** (opus B2, muse B3, codex B3). A null region, globals
   at fixed bases with images, the heap above them with `heap_base` equal
   to the comparison link's shim base, interface regions (W = 8) mapped
   at base addresses, `alloctab` pre-entered with **pinned live** entries
   for globals and mapped regions, dispatch of lifted loads/stores by
   address range, `in` regions preserved, the same partition for CC/R.
   Lifted call forms carry the full callee interface (`mem`, `args`).
6. **Ownership and operand schema** (codex B4, muse B4). Regions threaded
   consume-and-reproduce like bundles; per-opcode operand schema with
   results on the lhs (`w = op a b` everywhere, §4 rewritten); width
   rules (N multiple of 8, measurement chunking, cast strictness);
   `in`-wire positional use rule in actions.
7. **Borrow frames** (opus B3). The `V; W; V⁻¹` rule is withdrawn with
   opus's counterexample; the **toggling lemma** `V; W; V⁻¹; W` with its
   four side conditions is the structural rule; "touches" includes
   targets; other shapes need a T3 claim.
8. **Validity** (codex B5, muse B4). Transfer rules now include predicate
   and inherited context in every set, both operands of predicated
   `qexch`, interface-region cells for calls, `qalloc`, `qstore`/`qexchm`
   cell provenance and version advance, lifted rows; cleanups are bound
   to their exact computing sequence and its versions; control context
   defined as a multiset with an inherited control count that keys
   schedules and cleanup entries.
9. **Matched cleanup** (codex B6). `lift.oracle_uncall` consumes the
   successor versions of `tgt`/`fr'` with unchanged `ins`/`mem`, sharing
   the call's dynamic invocation identity.
10. **R tier** (codex B7, muse B5/B6, opus B5). Retained **dynamic SSA
    instances** as the reference model; frames per instruction incl.
    `hostcall`; Q calls reversed exactly once by their R frame; device
    operations over `(ptr, len)`; initial device state; the entropy tape
    as a run input; `FAULT_ENTROPY_EXHAUSTED`; the **run record as a
    tree** with post-order reversal; preparing a touched register
    invalidates reversal; measurement invalidates its register id.
11. **Targets** (codex B8, muse B7). A closed **JSON expression AST**
    evaluated in exact rationals, variables `k eps a w c`, tables, eps = 0
    and division rules; gate entries as an ordered array with class
    patterns and inclusive control ranges and first-match semantics;
    parametric **scheme templates** declared in the target; QRAM cost
    schema; aggregation per kind including classical step time.
12. **Grammar, schemas, identity** (codex B9/B10, muse B8/B9, opus B4).
    Section order and uniqueness; JSON field schemas for every metadata
    section (coverage as an object); large integers as decimal strings;
    canonical function bytes without trailing LF; the **semantic
    envelope** (ISA major, `ptr_width`, JCS signature, function bytes,
    reached data and layout entries, referenced hashes) for both interface
    and closure hashes; byte-exact reference replacement, SCC encoding,
    `object_hash`, `params_hash`, `schedule_hash`; program-point ids with
    nested ordinals.
13. **Launch and scheduler** (codex B11/B12, muse B5/B8). A `hostcall` CC
    instruction with service ids; a complete C header with opaque types,
    builders, accessors, destructors, status enum and ownership; the
    `bennett_estimate`/`bennett_coverage` name collisions fixed; scheduler
    request builders and response accessors; a **hierarchical schedule
    document** with invocation path, iteration, phase and generated-op
    selectors, kind-specific required fields, defaults, and bindings
    including inherited control count.
14. **Certificate** (codex B14, muse B10). Domains over every component of
    D with inclusive bounds and enumeration order; expectations as a
    table or a program; exact sampler replay (xoshiro256**, consumption
    order, rejection sampling); structural witnesses with sub-claim
    indices; numerical interval witnesses; typed local/inclusive errors
    with a single ×2 conversion point; multiplicities from the realised
    schedule; channel claims required for measurement-assisted
    realisations.
15. **Second worked example** (muse's path to accept): `sum_db`, an oracle
    reading an interface region through lifted memory with a recursive
    lproc and a global, plus the hash computation of both examples by the
    envelope rule (executed by a script, which is the first evidence the
    rule is implementable).

## Declined

- Codex's alternative of displacing the allocation index into the frame
  for `lift.free`: the base-only match (opus) is taken; both are sound,
  the chosen one needs no frame slot.
- Muse's "name the region in lifted loads" (`lift.load @db a`): address-
  range dispatch is taken instead, because unmodified C addresses memory
  by pointer value, not by region name.


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


# The document under review (round 4 snapshot)

# Bennett Virtual ISA — Specification, draft 0.4

**Date:** 2026-10-28. **Status:** fourth normative draft, for council
iteration (reports: `docs/council/isa-2026-10-28/round-{1,2,3}/`;
editor's responses in `round-*/response.md`). Founding text of
`bennett-isa-spec` (`Bennett-NorthStar.md` §4.4, §6.1); the north star
governs where this draft is silent. Nothing is implemented. MUST, MUST
NOT, SHOULD, MAY are normative; *(non-normative)* explains; *(deferred)*
names items left open and asserted non-semantic.

**Versioning.** ISA 0.4, object 0.4, launch 0.4, sched 0.4, cert 0.4,
coverage 0.4, target 0.4.

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
| Producer | plugin, library compilers | well-formed objects (§9, §16) and regions (§5, §6); suite F |
| Scheduler | `bennett-sched` and competitors | §11; only schedules valid under §6; suite H |
| Checker | `bennett-conformance` | validates certificates (§12) without trusting producers |
| Target author | vendors | target descriptions (§8); suite E |

### 1.3 Deferred *(asserted non-semantic)*

Binary encodings (§16 text is the interchange form); mechanisation of
§14; device models beyond §7.3; the gate-name registry process; the
**memory layout** of the opaque C objects of §10–§11 (their constructors,
accessors and destructors are normative and listed).

## 2. Terminology

- **Tier.** CC, R, Q. **Wire**, **bundle** `wire[N]` (little-endian).
- **Location** `reg[N]`: a named mutable cell of an oracle or lproc
  register file. **Pseudo-location**: an oracle interface input, readable
  in lifted code, never written.
- **Region**: a Q function with a declared interface: **lifted oracle**
  (§5.2) or **quantum action** (§5.3); **permutation action** (§5.3).
- **lproc**: a lifted procedure with its own locations (§3.7).
- **Budget**: classical (B, heap_limit, stack_limit, depth_limit).
- **Frame**: per machine step, retained displaced values, flag, succ.
- **Basis configuration**: classical values on every component of a
  region's domain D (§5.2).
- **Gate classes.** Permutation: `x cx ccx mcx swap`. Diagonal: `s sdg t
  tdg cz rz`. Non-diagonal: `h rx ry`.
- **Control context** of an invocation: the multiset of control wires
  inherited transitively from every enclosing predicate stack and `ctl`;
  its size is the **inherited control count** (§6.4).

## 3. Machine model

### 3.1 Tiers and the control invariant

```
  CC ──calls──▶ R functions (call/uncall)       CC ──calls──▶ Q regions
  R  ──calls──▶ R functions, Q regions          Q  ──calls──▶ Q regions (§5.5); oracle bodies call lprocs
```

CC runs on the device's classical-control processor; the host reaches
the device only through §10. **No instruction in any tier makes a
control or scheduling decision that depends on the value of a wire**
except through predication (§3.5). Gate angles are finite `f64` literals
or classical arguments fixed at region entry.

### 3.2 State

| Component | Tier | Contents |
|---|---|---|
| classical environment | CC, R | dynamic SSA instances (§7.4), block parameters, activation stack |
| classical memory | CC, R | byte-addressed, little-endian, sparse; allocation table (§7.1) |
| effect tape, entropy tape | R | §7.3 |
| run history | CC, R | one frame per executed instruction (§7.4) |
| wire store | Q (CC via register ids) | live wires with roles `input target fault borrowed mutable workspace location cell` |
| quantum memory | Q | regions of `wire[W]` cells: local (§4.6) or interface (§5.1) |
| register file | Q | locations of the active oracle and its lproc closure (§3.7) |
| predicate stack | Q | wires; the active predicate is their conjunction |
| oracle step state | Q | `pc, pc' : wire[P]`; `faulted : wire`; `code : wire[F]`; counters (§3.7); B frames |
| budget | Q | classical: B, heap_limit, stack_limit, depth_limit |

### 3.3 Types, ownership, operand schema

```
  iN (1 ≤ N ≤ 128)   ptr (width ptr_width, an object header constant)   f64   token
  wire   wire[N]      linear values in structured code and interfaces
  reg[N]              a location (oracle bodies, lprocs); not linear
  region[A,W]         an interface quantum memory region (2^A cells of wire[W])
```

**Linear SSA with implicit versioning** (structured code and CC region
calls): a `wire`/`wire[N]` value is produced once and consumed once. Mode
`in` consumes and re-produces a successor of the **same name**;
`consume` consumes; `produce` creates. A name is not used after
`consume`. **Regions are threaded the same way**: a region name used by
an instruction or call is consumed and re-produced (its cells' versions
advance as §6.1 states). **Indexed operand** `w[i]` (literal i) borrows
wire i for one instruction. **Disjointness**: the wire operands of one
instruction are pairwise distinct; a region's interface bundles and
regions are pairwise disjoint; a location is never both read and written
by one assignment row except through the displaced slot.

**Per-opcode operand schema.** Every opcode has a fixed arity and operand
kinds; the canonical text (§16) writes results first (`w = op a b`), then
operands in the order of the form in §4; modes are fixed by the opcode
and never written. Width rules: `binop`/`icmp` operands have equal width;
`select` arms equal width; `zext`/`sext` to a strictly wider type,
`trunc` to a strictly narrower one; `load.iN`/`store.iN`/`lift.load.iN`/
`lift.store.iN` require N ∈ {8, 16, …, 128}; `measure` of `wire[n]` with
n ≤ 128 yields `in`, wider registers are measured in chunks of ≤ 128;
signed division truncates toward zero; literals are decimal integers,
finite floats, or labels.

### 3.4 Execution in CC and R

Sequential small-step execution with an instruction pointer, block
parameters instead of phi nodes, dynamic control flow and allocation.
Every executed instruction pushes a run-history frame (§7.4); `uncall`
pops frames in LIFO order (T4).

### 3.5 Predication

Every Q instruction with unitary semantics executes controlled on the
active predicate. `qpred w` pushes, `qunpred w` pops the same wire; the
stack is empty at region entry and exit. Allocation, borrowing, release,
region creation and image gates are **unconditional**; only gates
(including those inside copy/XOR/exchange/memory instructions) are
controlled.

### 3.6 The predicated step machine

**Index space.** An oracle's instruction list `I[0..n)` is: the oracle's
blocks in text order, each contiguous; then the blocks of every lproc in
its **lproc closure** (every lproc reachable through `lift.call`,
including linked ones), lprocs ordered by closure hash (§9.2) with SCC
members in SCC index order, each lproc's blocks in text order. `HALT =
n`; 2^P > n. Branch and call targets are **labels**; executors assign
indices; `w = lift.label ^b` is the only way a location obtains an
index, so no producer writes raw indices and executors MAY re-index
extensionally. **Terminators**: `qjump qbranch qjumpr lift.ret lift.
retval fault`; every block ends in one; fallthrough is ill-formed; no
label names HALT; **only `lift.retval` reaches HALT with success**.

**Row classes.** Each §4.2 row is an **assignment** (its written
locations/cells receive values computed out of place into the frame's
`disp_j` slots, then exchanged in, so `disp_j` retains the displaced old
value) or a **direct** row (a controlled permutation executed in place,
no displaced value). Rows with a **flag** compute it into `frame.flag`
from the old state first, then perform their effects controlled on `flag`
or `¬flag`; conditional-fault rows additionally perform `faulted ^= flag`
and `code ^= flag · C` (direct). Rows with a data-dependent successor
compute it into `frame.succ`.

**Frame layout** (fixed per oracle): `(old_pc : wire[P], disp_1..disp_
{k_max}, flag : wire, succ : wire[P])`, `k_max` and the widths `W_j` from
the widest write sets used.

**Machine step** t (1 ≤ t ≤ B), reads referring to the state at the
start of the step:

1. **Dispatch.** `at_k = (pc == k)` for k = 0..n into clean scratch.
2. **Execute.** For each k < n: push `at_k`; run `I[k]`'s row: compute
   `flag` (if any) into `frame_t.flag`; compute `succ` (if data-
   dependent) into `frame_t.succ`; for assignment rows compute every
   written value into its `disp_j`, **all of them before any exchange**
   (so `lift.parmov` cycles are correct), then exchange each `disp_j`
   with its destination; for direct rows apply the permutation; apply
   the fault writes; pop `at_k`.
3. **Successor.** For each k < n, under `at_k`: XOR the row's successor
   into `pc'` (constant label index under `flag`/`¬flag` as the row
   states, or `frame_t.succ`). Under `at_HALT`: XOR `HALT` into `pc'`
   (**halted branches self-loop**).
4. **Commit pc.** `qexch pc pc'`; `qexch pc' frame_t.old_pc`.
5. **Clean dispatch.** Uncompute every `at_k` from `frame_t.old_pc`.
6. Decrement the classical step counter.

**Inverse of a step** (used by prefix reversal): recompute `at_k` from
`frame_t.old_pc`; undo step 4; for each row under `at_k`: undo the fault
writes and direct permutations (the same controlled operations, since
the retained `flag` still selects them), exchange every `disp_j` back,
then uncompute `flag` and `succ` from the restored old state; clean
`at_k`. The step is a permutation; executors implement it or an
extensionally identical transformation (§5.7, T6). B = 0 is legal.

### 3.7 Register files, procedures, counters, stack

An oracle declares `regs { name : reg[N], … }` and `result : reg[T]`;
each lproc declares `params`, `result`, `regs`. Interface inputs are
pseudo-locations readable by any read operand of lifted rows (never
written). All locations are clean at entry.

**Counters and sizes.** Region sizes are exponents: `mem` has 2^H byte
cells, `alloctab` 2^A_tab entries, the stack 2^S_cells cells. Counter
widths are **separate and wider**: `heap_used : wire[Hc]` with Hc ≥ H + 1,
`atop : wire[Ac]` with Ac ≥ A_tab + 1, `sp, fp : wire[Sc]` with Sc ≥
S_cells + 1, `depth : wire[Dc]` with Dc ≥ ⌈log₂(depth_limit+2)⌉; every
budget comparison is computed at counter width with no wrap; `bennett_
budget` (§10) rejects limits exceeding the region's capacities
(`heap_base + heap_limit ≤ 2^H`, `stack_limit ≤ 2^S_cells`, `depth_limit
< 2^Dc`).

**Activation records.** `lift.call @f (args) → w` pushes onto the stack
(cells of width `W_cell = max(P, Sc, Did, W_max)`) the record `(ret_index
: P, prev_fp : Sc, dest : Did, L_f[0], …, L_f[m−1])`, where `dest` is the
constant identifier of the destination location `w` (locations of the
oracle and its closure are numbered in index-space order; Did bits) and
`L_f` are **all** locations of `@f` in declaration order, each padded to
one cell, moved into the record by exchange (so `@f` starts clean, which
makes recursion correct). `R_f = 3 + m` cells. The stack is **monotonic**:
records are never popped; `sp` only grows; `fp` links records. Callee
instructions are charged to the caller's budget individually; `lift.call`
and `lift.ret` are one step each. Executors MAY inline extensionally.

## 4. Instruction set

### 4.1 Classical control (CC, R)

| Instruction | Form | Semantics |
|---|---|---|
| `const` | `r = const c` | |
| `add sub mul and or xor shl lshr ashr` | `r = op a b` | wrap; shift ≥ N → 0 |
| `udiv urem sdiv srem` | `r = op a b` | divisor 0, or signed MIN/−1: CC trap; R fault record (§7.4) |
| `icmp` | `r = icmp.{eq,ne,ult,ule,slt,sle} a b` | |
| `select` | `r = select p a b` | |
| `zext sext trunc ptrtoint inttoptr` | `r = op a` | |
| `load` | `r = load.iN addr` | N/8 consecutive bytes, little-endian, unaligned allowed; outside every live allocation: CC trap / R fault record |
| `store` | `store.iN addr v` | |
| `alloc` / `free` | `p = alloc n` ; `free p` | §7.1 |
| `br` | `br ^b(args)` / `br p ^b1(args) ^b2(args)` | parallel block-parameter assignment |
| `call` / `uncall` / `ret` | `results = call @f args` ; `uncall` ; `ret vals` | §9.4 |
| `trap` | `trap` | CC trap; R fault record |
| `measure` | `r = measure w` | CC only; Born rule (§14.2); w consumed |
| `effect` | `results = effect dev.op args` | R only (§7.3) |
| `hostcall` | `rlen = hostcall service ptr len` | CC only (§10): raises HOST_REQUEST synchronously with the `len` bytes at `ptr` as payload; the host's reply (≤ `len` bytes) is written at `ptr`; `rlen` is its length; the run resumes after `bennett_reply`. In R or Q: ill-formed |

### 4.2 Lifted rows (oracle bodies and lprocs)

Columns: **Class** (A = assignment, D = direct), **Reads**, **Writes**
(assignment rows: displaced values in order `disp_1..`; direct rows: the
permutation), **Flag/fault**, **Succ**. Every row is one budget step;
`k` is the row's own index. Conditional-fault rows also perform `faulted
^= flag`, `code ^= flag·C` (direct) with C the named code.

| Row | Form | Class | Reads | Writes | Flag / fault | Succ |
|---|---|---|---|---|---|---|
| `lift.const` | `w = lift.const c` | A | – | w | – | k+1 |
| `lift.binop` | `w = lift.{add,…,ashr} a b` | A | a, b | w | – | k+1 |
| `lift.div` | `w = lift.{udiv,urem,sdiv,srem} a b` | A | a, b | w (under ¬flag) | flag = (b=0) ∨ (signed ∧ a=MIN ∧ b=−1); C = `FAULT_UB_DIV0` or `FAULT_UB_SDIV_OVERFLOW` | ¬flag: k+1; flag: HALT |
| `lift.icmp` | `w = lift.icmp.{pred} a b` | A | a, b | w:reg[1] | – | k+1 |
| `lift.select` | `w = lift.select p a b` | A | p, a, b | w | – | k+1 |
| `lift.cast` | `w = lift.{zext,sext,trunc} a` | A | a | w | – | k+1 |
| `lift.mov` | `w = lift.mov a` | A | a | w | – | k+1 |
| `lift.parmov` | `(w_1..w_m) = lift.parmov (a_1..a_m)` | A | a_i | w_1..w_m (all computed, then all exchanged) | – | k+1 |
| `lift.label` | `w = lift.label ^b` | A | – | w (the index of ^b) | – | k+1 |
| `lift.boundscheck` | `lift.boundscheck p n` | D | p, alloctab | – | flag = ¬∃ i < atop: live_i ∧ base_i ≤ p ∧ p + n ≤ base_i + size_i (no wrap); C = `FAULT_UB_MEMFAULT` | ¬flag: k+1; flag: HALT |
| `lift.load` | `w = lift.load.iN a` | A | the N/8 byte cells at a..a+N/8−1 (§7.2 dispatch) | w | – | k+1 |
| `lift.store` | `lift.store.iN a v` | A | v | the N/8 byte cells at a.. (displaced: their old N bits) | – | k+1 |
| `lift.alloc` | `w = lift.alloc n` | A | n, heap_used, atop | under ¬flag: w ← heap_base + heap_used; heap_used ← heap_used + max(n,1); atop ← atop + 1; alloctab[atop] ← (base = heap_base + heap_used, size = n, live = 1, pinned = 0) (4 displaced) | flag = (heap_used + max(n,1) > heap_limit) ∨ (atop ≥ 2^A_tab); C = `FAULT_BUDGET_HEAP` | ¬flag: k+1; flag: HALT |
| `lift.free` | `lift.free p` | D | p, alloctab | match_i = (i < atop) ∧ (base_i = p) (computed from base only, into scratch); under ¬flag: live_i ^= match_i for all i; match_i uncomputed | flag = ¬∃ i: match_i ∧ live_i ∧ ¬pinned_i; C = `FAULT_UB_MEMFAULT` | ¬flag: k+1; flag: HALT |
| `lift.faultif` | `lift.faultif p code` | D | p | – | flag = p; C = code | ¬flag: k+1; flag: HALT |
| `lift.call` | `w = lift.call @f (a_1..a_m)` | A+D | a_i, sp, fp, depth, L_f | under ¬flag: record cells ← (k+1, fp, id(w), L_f) by exchange (direct; the cells are clean); fp ← sp; sp ← sp + R_f; depth ← depth + 1 (3 displaced); params of @f ^= copies of a_i (direct) | flag = (depth + 1 > depth_limit) ∨ (sp + R_f > stack_limit); C = `FAULT_BUDGET_DEPTH` | ¬flag: entry label of @f; flag: HALT |
| `lift.ret` | `lift.ret v` | A+D | v, fp, record at fp, depth | under ¬flag: succ ← record.ret_index; exchange record's L_f cells ↔ @f's locations (direct); for every location ℓ of the closure: ℓ ^= record.v under (record.dest = id(ℓ)) (direct); fp ← record.prev_fp; depth ← depth − 1 (2 displaced) | flag = (depth = 0); C = `FAULT_UB_TRAP` | ¬flag: `succ`; flag: HALT |
| `lift.retval` | `lift.retval v` | D | v | result ^= v | – | HALT |
| `lift.oracle_call` | `lift.oracle_call @o tk (ins..) tgt fr (mem..) (args..)` | D | ins, tgt, fr, mem | tgt ^= payload; fr ^= code (callee contract); mem `in` regions unchanged | – | k+1 |
| `lift.oracle_uncall` | `lift.oracle_uncall @o tk (ins..) tgt fr (mem..) (args..)` | D | as above | the matched inverse (§5.5): identical permutation | – | k+1 |
| `lift.perm_call` | `lift.perm_call @a (mut..) (ins..) (mem..) (args..)` | D | ins, mut, mem | mut ← P(mut, ins, mem) in place | – | k+1 |
| `qjump` | `qjump ^b` | D | – | – | – | ^b |
| `qbranch` | `qbranch p ^b1 ^b2` | D | p | – | – | p: ^b1; ¬p: ^b2 |
| `qjumpr` | `qjumpr a` | D | a | succ ← a | flag = (a ≥ n); C = `FAULT_UB_TRAP` | ¬flag: `succ`; flag: HALT |
| `fault` | `fault C` | D | – | code ^= C; faulted ^= 1 | – | HALT |

Rules: `lift.retval` is ill-formed inside an lproc; `lift.ret` is ill-
formed in an oracle body outside lprocs (static), and faults at depth 0
(dynamic, when reached through `qjumpr`). `lift.oracle_call`/`uncall`
and `lift.perm_call` carry the complete callee interface: `mem` operands
name the caller's mapped interface regions (§7.2) and `args` are
classical literals or the oracle's classical arguments. `tk` is a
classical argument of the calling oracle, so a nested budget is part of
the caller's F_B.

**Reference body and binding.** Every oracle carries its **reference
body**: the stream the dialect's versioned mapping produced from the
materialised source (a fixed, versioned sequence of rows per source
instruction, `lift.boundscheck` before every access and `lift.parmov` on
every edge included), hashed into `interface_hash` (§9.2). **F_B and the
budget unit are defined solely by the reference interpreter (§14.1) on
the reference body**; the object holds only the reference body; every
executor optimisation is a transformation extensionally equal to it on D
(T6). The fault set depends only on (reference body with its envelope,
budget, dialect-mapping version).

### 4.3 Allocation

| Instruction | Form | Rules |
|---|---|---|
| `qalloc` | `w = qalloc cls n` | n clean wires of class `cls` or `any`; unconditional |
| `qborrow` | `w = qborrow cls n` | n wires in unknown state; usable only inside a borrow frame (§5.6) |
| `qfree` | `qfree w` | release a `qalloc`ed bundle clean on every basis configuration |
| `qreturn` | `qreturn w` | matched inverse of `qborrow` after its frame |

### 4.4 Gates

Matrices (computational basis, |0⟩ = (1,0)ᵀ, bundles little-endian):

```
  x = [[0,1],[1,0]]   h = (1/√2)[[1,1],[1,-1]]   s = diag(1,i)   sdg = diag(1,-i)
  t = diag(1,e^{iπ/4})  tdg = diag(1,e^{-iπ/4})   cz = diag(1,1,1,-1)
  rx(θ) = exp(-iθX/2)   ry(θ) = exp(-iθY/2)   rz(θ) = exp(-iθZ/2) = diag(e^{-iθ/2}, e^{iθ/2})
  cx, ccx, mcx(k): X on the target iff all controls are |1⟩ (exact, no phase)    swap: exact exchange
```

Forms: `x a`, `cx c t`, `ccx c1 c2 t`, `mcx (c_1..c_k) t`, `swap a b`,
`h a`, `s a`, `sdg a`, `t a`, `tdg a`, `cz a b`, `rx θ a`, `ry θ a`, `rz θ
a`; operands `in`, pairwise distinct; all controlled on the active
predicate. **Realisation**: permutation status is a property of the
realised unitary at the gate boundary (an exact Clifford+T `ccx` is a
permutation gate); conformant iff equal to the specified unitary exactly
including global phase (ε = 0) or within declared ε in operator norm.
**Oracles and permutation actions require ε = 0** for every gate they
execute; actions MAY use ε > 0, accounted per §12. A relative-phase
Toffoli is never a conformant `ccx`.

### 4.5 Copy, XOR, exchange, in-place

| Instruction | Form | Semantics |
|---|---|---|
| `qcopy` | `d = qcopy s` | d allocated clean (unconditional); `cx s[i] d[i]` under the predicate |
| `quncopy` | `quncopy s d` | `cx s[i] d[i]` under the predicate; `qfree d` |
| `qxor` | `qxor s t` | `cx s[i] t[i]` |
| `qexch` | `qexch a b` | `swap a[i] b[i]` |
| `qinplace` | `qinplace @g @ginv tk x` | `@g`, `@ginv` total permutation oracles on the n-bit encoding with certificates that under `tk` the fault code is `FAULT_NONE` on every input and `g∘ginv = ginv∘g = id`. Sem: `t = qalloc any n; f = qalloc any F; oracle_call @g tk (x) t f; qexch x t; oracle_call @ginv tk (x) t f; qfree t; qfree f` |

### 4.6 Quantum memory, predication, structure

| Instruction | Form | Rules |
|---|---|---|
| `qregion` | `qregion name A W [image]` | function-local region of 2^A cells of `wire[W]`, created at function entry (unconditional allocation, X gates from the object's data image, default zero), MUST be back at its image before exit where the image gates are reversed and cells released clean; scope is the function; the adjoint reverses creation and release |
| `qload` | `d = qload name a` | d clean; for each cell i: under `a == i`, `qxor cell_i d` (comparators computed and uncomputed inside) |
| `qunload` | `qunload name a d` | inverse |
| `qstore` | `qstore name a v` | for each i: under `a == i`, `qxor v cell_i` |
| `qexchm` | `qexchm name a v` | for each i: under `a == i`, `qexch v cell_i` |
| `qpred`/`qunpred` | | §3.5 |
| `qif` | `qif w { then } { else }` | `qpred w; then; qunpred w; x w; qpred w; else; qunpred w; x w` |
| `qloop` | `qloop n { body }` | body n times |
| `qloop … while` | `qloop n while cond { body }` | `cond : wire[n]` of permutation-provenance wires computed before the loop from wires the body does not modify; flags `c_1..c_n` allocated clean; `cx cond[0] c_1`; iteration i runs under `qpred c_i`; after iteration i < n, `ccx c_i cond[i] c_{i+1}`; flags uncomputed in reverse order and freed |

Interface regions (§5.1) are accessed by name with the same instructions.

### 4.7 Region calls (structured code and CC)

`oracle_call @o tk (ins..) tgt fr (mem..) (args..)`; `action_call @a
(mut..) (ins..) (mem..) (args..)`; `adj action_call …`; `adj oracle_call
…` ≡ `oracle_call …`; `ctl w <call>` ≡ the call under `qpred w` (for a
whole action, the controlled unitary of §5.3).

## 5. Regions

### 5.1 Interfaces and common well-formedness

Signatures list roles: `oracle @o (in a: wire[8]) (tgt t: wire[8]) (fault
f: wire[4]) (mem db: region[10,8] in) (args n: i64)`. **Interface
regions** are caller-owned, passed by name, role `in` (returned to their
entry contents on every basis configuration) or `mut` (actions only). A
region MUST NOT contain `measure effect br call uncall trap hostcall` or
classical memory instructions, nor lifted rows outside oracle bodies.
Predicate stack empty at entry and exit. Every `qalloc` matched by a
`qfree` of a clean bundle, every `qborrow` by a `qreturn` after its
frame, every local `qregion` restored, by **explicit cleanup instructions
in the text**; the schedule chooses only realisations. **`in` wires in
actions** appear only as controls, as targets of diagonal gates, as
`qcopy`/`qxor` sources, or as `in` arguments of calls (suite F). Action
call graphs are acyclic; recursion exists only through `lift.call`.

### 5.2 Lifted oracle

**Body**: lifted and control rows over its locations and lproc closure;
**exact-permutation only** (every gate executed by the body, lprocs,
`lift.perm_call` targets and nested oracles has ε = 0).

**Contract** on every x ∈ D: `ins` unchanged; `tgt` final = initial ⊕
payload(F_B(x)); `fr` final = initial ⊕ code(F_B(x)); `in` regions
unchanged; borrowed bundles returned (§5.6); workspace, locations, local
regions, step state clean / at image. **F_B(x)** = `(f(x), 0)` if the
reference interpreter reaches `lift.retval` within B steps without a
fault, else `(0, code)` with `code` the first fault in sequential order,
or `FAULT_BUDGET_STEPS` if not halted after B steps. The oracle is an
**involution** on `(ins, tgt, fr)` and its own adjoint.

**Construction** (normative; executors are extensionally fixed to it):
(1) allocate step state, locations, local regions (image gates),
`alloctab` with its pre-entries (§7.2), B frames; (2) run B steps; (3)
**commit**: `at_HALT = (pc == HALT)`; under `at_HALT ∧ ¬faulted`: `qxor
result tgt`; under `faulted`: `qxor code fr`; under `¬at_HALT`: XOR the
constant `FAULT_BUDGET_STEPS` into `fr`; uncompute `at_HALT`; (4)
**prefix reversal**: invert (2) then (1); the commit writes persist.

**Domain D**: every value of each `ins`, of `tgt`, of `fr`, of every cell
of every `in` region, of every borrowed bundle; `qalloc`ed wires at 0;
local regions at image.

### 5.3 Quantum action

**Semantics.** The body denotes a unitary U on mut ⊗ ins ⊗ mem_mut ⊗
(borrowed), block-diagonal in the computational basis of `ins` and of
`in`-region cells, identity on borrowed and external reference systems
(§5.6), workspace returned clean. No fault outcome of its own. An action
with coherent internal control is its padded unitary under its declared
bounds, which are part of its identity. **Permutation action**: realised
unitary a permutation matrix (ε = 0, permutation gates only,
transitively); the only kind of action an oracle may call.

**Body**: gates; `qcopy quncopy qxor qexch qinplace`; `qload qunload
qstore qexchm`; `qpred qunpred qif qloop`; `oracle_call action_call`;
`qalloc qborrow qfree qreturn`; `qregion`.

**Adjoint table** (reverse order, each instruction replaced, versions
renumbered; well-formed by construction):

```
  rx/ry/rz(θ) ↦ (−θ)   s ↔ sdg   t ↔ tdg   x cx ccx mcx swap h cz: self-adjoint
  qalloc ↔ qfree   qborrow ↔ qreturn   qregion creation ↔ release   qcopy ↔ quncopy   qload ↔ qunload
  qxor qexch qstore qexchm: self-adjoint   qinplace @g @ginv ↦ qinplace @ginv @g   oracle_call ↦ oracle_call
  action_call @b ↦ adj action_call @b   qpred/qunpred pairs reversed as a whole
  qif w {A}{B} ↦ qif w {adj A}{adj B}   qloop n {A} ↦ qloop n {adj A}
  qloop n while cond {A} ↦ flags computed forward as §4.6; adj A for i = n..1 under c_i; flags uncomputed
```

**Control.** `ctl w @a` is controlled-U: workspace, regions and flags
allocated unconditionally; every gate of the body and of its cleanup
runs under `w` in addition to the active predicate.

### 5.4 Budgets and fault codes

Budget = (B, heap_limit, stack_limit, depth_limit), classical, validated
at `bennett_budget` against the region's capacities (§3.7). B is
enforced by running exactly B steps; heap, stack and depth are wire
counters compared at full width. Fault precedence within a row is the
row's flag definition.

```
  0 FAULT_NONE            4 FAULT_UB_TRAP            8 FAULT_EFFECT_UNMODELLED
  1 FAULT_BUDGET_STEPS    5 FAULT_UB_DIV0            9 FAULT_CALLEE
  2 FAULT_BUDGET_HEAP     6 FAULT_UB_SDIV_OVERFLOW  10 FAULT_ENTROPY_EXHAUSTED (R only)
  3 FAULT_BUDGET_DEPTH    7 FAULT_UB_MEMFAULT
```

F ≥ 4. R-tier fault records carry these same codes (§7.4).

### 5.5 Nesting and matched cleanup

A `lift.oracle_call` supplies a caller location `fr'`, clean when
computing a fresh outcome. **No automatic propagation**: the dialect
emits `p = lift.icmp.ne fr' 0; lift.faultif p FAULT_CALLEE` where the
source requires it. To clear `fr'`, the producer emits `lift.oracle_
uncall @o` with the **same token, same callee, the same `ins` and `mem`
values** (unchanged since the call: suite F checks that no row between
the two wrote those locations or cells) **and the successor versions of
`tgt` and `fr'`** produced by the call; the two rows share a dynamic
invocation identity (the pair is matched statically). Alternatively
`fr'` is retained until the prefix reversal.

### 5.6 Borrowed systems and borrow frames

**Requirement.** A region's completed operation equals its declared
operation ⊗ identity on every borrowed bundle and on any external system
entangled with it. Basis restoration alone is insufficient (`cx b a; s a;
cx b a` applies `s` to borrowed b).

**Rule (suite F).** Borrowed wires are **touched** (as control or target)
only inside **borrow frames**: maximal contiguous permutation-only
subcircuits from the first to the last instruction touching the frame's
borrowed wires. The frame's realised permutation P_F on its wires (the
borrowed wires and every wire any frame instruction touches) MUST factor
as `P_F = P' ⊗ I_borrowed`. This is established either by a T3 claim over
the frame's full domain (exhaustive, or a library certificate, §12
`borrow_frames`), or **structurally by the toggling lemma**: the frame
has the form `V; W; V⁻¹; W` where (i) V consists of permutation gates
that XOR into borrowed wires only functions of a wire set X, and W
writes no wire of X; (ii) W's targets lie outside X, outside the borrowed
set, and outside W's own controls; (iii) every gate of W has at most one
borrowed control, so W's effect is affine in the borrowed values; (iv)
V⁻¹ is the exact inverse sequence of V. Then the net effect is
independent of the borrowed values and restores them (the dirty-ancilla
MCX pattern of Gidney and Häner–Roetteler–Svore). The earlier `V; W; V⁻¹`
rule is withdrawn (`cx b y; cx y z; cx b y` leaves z ⊕= y ⊕ b). Oracles
are one frame verified by their own T3 claim over D.

### 5.7 Executor transformations

Inlining, structure recovery, re-indexing of labels and any
simplification MUST produce on every x ∈ D the same final interface tuple
as §5.2's construction on the reference body (T6).

## 6. Uncomputation validity (static discipline)

### 6.1 Provenance, dependency sets, transfer

Every workspace bundle version, location version and cell version has
provenance `perm` (computed by permutation gates from its **dependency
set** S of versions) or `other`. Cell versions `(region, i, v)` advance on
every write to the cell. Π denotes the active predicate stack plus the
inherited control context. Transfer rules (suite F):

| Instruction | Effect |
|---|---|
| `qalloc` | perm, S = ∅ |
| `d = qcopy s` | d: perm, S = {s} ∪ Π |
| `d = qload r a` | d: perm, S = {a} ∪ cells(r) ∪ Π |
| `qxor s t` | t: perm with S_t ∪ S_s ∪ Π if both perm, else other |
| `qexch a b` (predicated) | each output: perm with S_a ∪ S_b ∪ Π if both perm, else other (the output is selected by the predicate) |
| `qstore r a v` | cell versions of r advance: each cell (r,i): perm with S_cell ∪ S_v ∪ {a} ∪ Π if both perm, else other |
| `qexchm r a v` | v and every cell: perm with S_v ∪ ⋃S_cells ∪ {a} ∪ Π if all perm, else other; cell versions advance |
| permutation gate, controls C, target t | t: perm with S_t ∪ C ∪ ⋃S_c ∪ Π iff t was perm, else other |
| diagonal gate on u | unchanged |
| non-diagonal gate on u | u: other; closes the window of every value whose S contains u |
| `oracle_call @o (ins) tgt fr (mem)` | tgt, fr: perm with S = ins ∪ {tgt, fr} ∪ cells(every `in`/`mut` region passed) ∪ Π; `in` regions unchanged |
| `lift.perm_call` / permutation `action_call` | each mut: perm with S = mut ∪ ins ∪ cells(regions passed) ∪ Π; `mut` region cells advance with the same S |
| non-permutation `action_call` | every mut and every `mut`-region cell: other |
| `qinplace @g @ginv x` | x: perm with S_x ∪ Π |
| lifted rows | each written location/cell: perm with the union of its read operands' sets ∪ Π; written cells' versions advance |

### 6.2 Window and obligations

A perm value g with set S is **in its window** from its computation until
the first of: a non-diagonal gate on a wire in S or in g; a version
advance of a cell in S; a non-permutation action call touching a wire in
S; a permutation change to a wire in S not undone before g's cleanup.
Each cleanup is **bound to the exact computing sequence** (`quncopy` to
its `qcopy`, `qunload` to its `qload`, an adjoint sequence to its
sequence, `lift.oracle_uncall` to its call) and requires the versions
that sequence read to be current. Every perm value MUST be cleaned
within its window and before its region exits; a region in which some
value cannot be is **ill-formed** (closed-window measurement-based
cleanup is not admitted in this draft). `other` values are released only
by the adjoint of the sequence that produced them.

### 6.3 T5 restated

Cleaning g within its window returns g's wires to |0⟩ and factorises
them from the remaining state; diagonal uses of g or of its dependencies
have applied the corresponding diagonal phases to the remainder, which
is part of the program's declared semantics.

### 6.4 Control context and measurement-based realisation

The inherited control count of an invocation is the number of wires in
its control context. A **measurement-based realisation** of an in-window
cleanup is legal only in a schedule whose bindings state an inherited
control count of 0 and whose target declares `mbu: true`; the fixup is
computed for the actual schedule and verified by suite D (channel
claim). Schedules and certificate cleanup entries are keyed by `(region
hash, variant, inherited control count)`; a region reachable under a
non-empty control context MUST have a unitary-cleanup schedule for that
key.

## 7. Memory and effects

### 7.1 Classical memory (CC, R)

Byte-addressed, little-endian, sparse. The address space is partitioned
by the object's `layout`: a **null region** `[0, null_size)` never
allocated (null_size ≥ 1); globals at fixed bases with images; the heap
`[heap_base, heap_base + heap_limit)` above the globals. `p = alloc n`
returns the bump pointer, records `(base, size = n, live = 1, pinned =
0)` and advances the pointer by `max(n, 1)`, so bases are pairwise
distinct and zero-size allocations have no accessible byte. Globals have
pre-entered pinned live entries. An access is valid iff its whole byte
range lies in one live entry. `free p` marks the unique entry with base
p dead; pinned entries cannot be freed; storage is never reclaimed.

### 7.2 Lifted memory of an oracle

`mem` is one byte region of 2^H cells (H ≤ ptr_width); `alloctab` has
2^A_tab entries `(base, size, live, pinned)`; the stack has 2^S_cells
cells. The `layout` fixes `null_size`, each global's base and image,
`heap_base` (equal to the comparison link's shim heap base), and for
each **interface region** of the oracle (W = 8 required) a base address
in the lifted address space, all ranges disjoint and within `[0, 2^H)`.
At oracle entry `alloctab` is initialised with one **pinned live** entry
per global and per mapped interface region (counted against 2^A_tab).
`lift.load`/`lift.store` dispatch by address range to `mem` or to the
mapped interface region (which preserves roles: `in` regions are
unchanged at exit by the construction). A ptr holds `ptr_width` bits; the
address circuits use the low H bits and `lift.boundscheck` guarantees
the range lies in a live entry, hence within `[0, 2^H)`.

### 7.3 Device models and tapes (R)

Device operations take classical-memory arguments `(ptr, len)` with the
same bounds rules as `load`/`store`; results are written to memory.

| Device | State (initial) | Operations | Failure | Reversal |
|---|---|---|---|---|
| `console` | byte sequence (empty) | `write(ptr, len)` | – | pop `len` bytes |
| `clock` | `c: u64` (0) | `read() → u64`: returns c, then c += 1 | – | c −= 1 |
| `entropy` | position `p` (0) into the **entropy tape** supplied at launch (§10) | `read(ptr, len)`: copies tape[p..p+len) to ptr; p += len | p + len > length: R fault `FAULT_ENTROPY_EXHAUSTED` | p −= len |
| `block` | sector map (from the object's `block` data image, else empty); 512-byte sectors; missing sectors read as zero | `read(sector, ptr)`; `write(sector, ptr)` (history records the overwritten sector) | – | restore the sector |

Each `effect` appends `(dev, op, args, results)` to the effect tape;
reversal pops and applies the inverse delta. Reversal restores device
state; it cannot retract an observation of the console.

### 7.4 Run history (CC and R) and the dynamic SSA model

The classical environment holds **dynamic instances**: every executed
defining instruction creates a new instance retained in the run history
until reversal; a name denotes its most recent instance. Each executed
instruction pushes one frame:

| Instruction | Frame |
|---|---|
| any defining instruction | its defined instance |
| `br` | predecessor block, prior block-parameter instances |
| `store` | address, width, overwritten bytes |
| `alloc` / `free` | the table entry written / its old live bit |
| `call` | invocation boundary (callee, args) |
| `ret` | the callee's entire activation and the frame link |
| `effect` | tape index |
| `hostcall` (CC) | payload bytes and the reply bytes |
| `oracle_call` / `action_call` | (region hash, variant, inherited control count, classical args, register ids) — reversed by re-application / adjoint, **exactly once, by this frame** |
| fault record | cause (§5.4 code), location; terminal faulted state, reversed like any prefix |

`uncall` reverses the most recent unreversed `call` whose frames are the
top of the history (LIFO). T4 is stated over these frames.

## 8. Target descriptions (target 0.4)

### 8.1 Format and expressions

A target is a **JSON document in RFC 8785 canonical form**; `target_hash`
= SHA-256 of those bytes. Numbers are parsed as **exact rationals** from
their decimal text. Cost expressions are a closed **JSON AST**:

```
  expr := number | {"var": "k" | "eps" | "a" | "w" | "c"} | {"op": "+"|"-"|"*"|"/"|"max"|"min"|"ceil"|"log2inv_eps", "args": [expr, ...]}
        | {"table": "<name>", "index": "k" | "eps_decade"}
```

Variables: `k` the gate's own control/parameter count, `eps` the
assigned synthesis ε, `a` the address width and `w` the cell width of a
memory operation, `c` the total control count (own controls + predicate
depth + inherited). `log2inv_eps` at eps = 0 is a load-time error unless
the entry's `epsilon` is 0. Division by zero is a load-time error. Tables
are declared under `"tables"` as arrays indexed by exact k or by ε decade
(⌊log₁₀(1/ε)⌋). Costs MUST be nonnegative and finite.

### 8.2 Resources, aggregation, timing

```
  "resources": { "<name>": { "kind": "count"|"time"|"occupancy"|"peak", "unit": "<string>" } }
```

Mandatory: `qubit_second` (occupancy, per class), `time`, `peak_qubits`
(peak, per class). `count` sums; `time` is the schedule makespan;
`occupancy` integrates live qubits per class over scheduled time; `peak`
takes the maximum. Classical instructions and effects take the declared
`"classical_step_time"` each. **Timing model**: sequential in program
order unless the schedule assigns start times; a gate occupies its wires
for its `time`; gates on disjoint wires MAY overlap unless `max_parallel`
or a topology is declared; all-to-all over logical wires. A wire's
interval runs from `qalloc`/`qborrow` to `qfree`/`qreturn`; interface
wires are charged to the caller for the call's duration; borrowed wires
are charged to the borrower at `dirty_rate`, replacing the owner's charge.

### 8.3 Classes, gates, schemes, capabilities

```
  "ptr_widths_supported": [32, 64],
  "classes": { "<cls>": { "qubit_second": n, "dirty_rate": n, "capacity": n | "unbounded" } },
  "gates": [ { "op": "<gate>", "classes": ["<cls>"|"*", ...], "controls": {"min": n, "max": n | "unbounded"},
               "params": ["theta"]?, "epsilon": expr, "cost": { "<resource>": expr, "time": expr } }, ... ],
  "schemes": { "<name>": { "params": ["k"], "template": [ { "gate": "<op>", "wires": ["c0", "t"], "repeat": {"var": "i", "from": expr, "to": expr}? }, ... ],
                           "epsilon": expr, "cost": { ... } } },
  "qram": null | { "load": { "cost": {...} }, "store": { "cost": {...} }, "exch": { "cost": {...} } },
  "capabilities": { "measurement": {"mid_circuit": bool, "feedforward_latency": n}, "mbu": bool,
                    "max_parallel": n | "unbounded", "max_predicate_depth": n | "unbounded", "classical_step_time": n },
  "objective": { "weighted": { "<resource>": n } } | { "lexicographic": [ "<resource>", ... ] },
  "tables": { "<name>": [ n, ... ] },
  "imports": { "<model>": { "version": "...", "map": { "<quantity>": ["<resource>", factor] } } }
```

**Matching.** An executed gate with opcode o, operand classes, total
control count c and parameters matches the **first** `gates` entry in
array order whose `op`, class pattern (`*` matches any) and `controls`
range cover it; otherwise the first `schemes` entry whose template
(expanded with its parameters) realises it; otherwise load-time error.
`controls.min/max` are inclusive bounds on the total control count. A
scheme's `template` is a parametric gate sequence over symbolic wire
names with `repeat` ranges; a schedule MAY reference only schemes
declared in the target.

### 8.4 Space budget

The scheduler's capacity constraint is peak live qubits per class,
separate from `qubit_second`.

## 9. Objects, identity, linking, reversible ABI (object 0.4)

### 9.1 Sections and schemas

Order is fixed: `symbols imports functions data devices layout schedule
certificate coverage`; each at most once; unknown sections are errors;
unknown fields in metadata objects are errors. Metadata sections are one
JCS line each, an **object** with these fields:

```
  symbols:  { "<local index>": { "name", "kind": "cc"|"r"|"oracle"|"action"|"perm_action"|"lproc"|"data",
                                 "signature": <sig>, "interface_hash" } }
  imports:  { "<name>": { "signature": <sig>, "pinned_closure_hash"?: hex } }
  devices:  { "<dev>": { "version": "0.4" } }      services: inside devices as { "services": { "<reverse-dns id>": { "version" } } }
  layout:   { "ptr_width", "H", "A_tab", "S_cells", "null_size", "heap_base", "heap_limit_max",
              "globals": { "<name>": { "base", "size", "image": "<data name>" } },
              "interface_regions": { "<oracle>": { "<region>": { "base" } } }, "block_image"?: "<data name>" }
  schedule: §11      certificate: §12      coverage: { "entries": [ §13 ] }
  <sig> = { "tier", "kind", "in": [widths], "tgt": w, "fault": F, "mut": [widths], "mem": [ { "A", "W", "role" } ],
            "args": [types], "bounds"?: [...], "abi": "0.4" }
```

Integers that may exceed 2^53 are encoded as **decimal strings** in
JSON. `data` lines are `NAME SP HEX`.

### 9.2 Identity

**Canonical function bytes**: the function's text from its header line
through its last instruction line, lines joined by LF, **no trailing
LF**. **Semantic envelope** of a symbol = the concatenation, each part
followed by LF: (1) `"isa=" MAJOR`; (2) `"ptr_width=" INT`; (3) its JCS
signature; (4) its canonical function bytes; (5) for every `data` entry
and every `layout` sub-entry it reaches (its local regions' images, the
globals and interface-region mappings it addresses, the oracle's H,
A_tab, S_cells, null_size, heap_base), sorted by name, the JCS line of
that entry (data: `NAME SP HEX`); (6) for every referenced symbol, in
order of first reference, its hash (64 lowercase hex) — the **interface
hash** uses interface hashes of defined symbols and `SHA-256(name ‖ 0x00
‖ JCS signature)` for unresolved imports; the **closure hash** uses
closure hashes. In parts (4)–(5) every `@name` reference token is
replaced in place by `@` followed by the referenced symbol's 64-hex hash.
**SCCs**: members ordered by name; intra-SCC references replaced by
`@$<decimal index>`; `scc_hash` = SHA-256 over the concatenated member
envelopes in that order; member identity = SHA-256(`scc_hash` hex ‖ `:` ‖
decimal index). **object_hash** = SHA-256 of the canonical object text
with the `schedule`, `certificate` and `coverage` sections deleted
together with the blank line preceding each. `reference_program_hash` of
an oracle = its interface hash. `params_hash` = SHA-256 of the JCS array
of classical parameter values; `schedule_hash` = SHA-256 of the
schedule's JCS bytes. **Program-point id** = `(symbol interface hash,
block name, instruction ordinal within the block counting nested
instruction lines in text order)`.

### 9.3 Linking

Imports resolve by name + signature (mismatch: link error; pinned hash:
equality required); resolved closure hashes are recorded in the linked
certificate. Equal-closure-hash duplicates deduplicate; unequal under one
name, or conflicting `devices`/`layout`/`data` entries: link error.
Linking = resolution, validation, certificate composition (§12.3),
rebinding to closure hashes.

### 9.4 Reversible ABI

- CC/R calls: classical frame; callee frames follow the call boundary on
  the run history; `uncall` reverses LIFO (§7.4).
- Region calls: interface bundles and regions passed in declared order,
  caller-owned; callee owns its workspace, returns it clean, local regions
  at image, borrowed bundles returned.
- **Frame descriptor** (certificate): interface slots (role, width,
  class), scratch by class and cleanliness, retained history (oracles: B ×
  frame width), borrow requirement, **parameterised by inherited control
  count** (scratch for controlled variants is stated as a function of c or
  as a declared bound with its proof). Shared frames only with disjoint
  live ranges (suite F); callees `qborrow` only from the caller's
  designated idle set.

## 10. Launch ABI (launch 0.4)

**Model.** A run executes a device CC entry. The host passes classical
arguments, budgets, register ids and the entropy tape; receives classical
results, fault codes and declared measurements; host services are
reached by `hostcall` (§4.1) with reverse-DNS service ids declared in the
object's `devices.services`. Host code never holds a wire.

**Invocation tree.** A run record is a tree whose leaves are CC
segments, R calls and Q calls; an R call's subtree is owned by its R
history (§7.4), so a Q call inside an R call is reversed exactly once, by
that history. `bennett_reverse` reverses the tree post-order: CC segments
by their run history (stores, allocs, register operations, `hostcall`
replies), R calls by `uncall`, top-level Q calls by re-application /
adjoint with recorded arguments and register ids.

**States.** `CREATED → RUNNING → (SUSPENDED ⇄ RUNNING) → (HOST_REQUEST ⇄
RUNNING) → COMPLETED | FAILED`; `COMPLETED → REVERSED`; any of
`COMPLETED/FAILED/REVERSED → CLOSED`. A run owns the registers and
memory it touches exclusively while not CLOSED. **Reverse eligibility**:
`COMPLETED` only; no `measure` executed; no register it touched has been
prepared, freed or used by another run since (preparing a touched
register invalidates reversal); otherwise `E_NOT_REVERSIBLE`.
Measurement consumes its wires; the register id is invalidated.

```c
/* launch 0.4 — all objects opaque; every *_new/_get returning an object transfers ownership to the caller,
   released with the matching *_free. Status: 0 = BENNETT_OK, else one of the enum values below. */
typedef enum { BENNETT_OK=0, BENNETT_E_VERSION, BENNETT_E_PTR_WIDTH, BENNETT_E_DEVICE_MISSING, BENNETT_E_GATE_UNSUPPORTED,
  BENNETT_E_TARGET, BENNETT_E_BUDGET, BENNETT_E_QREG_NOT_CLEAN, BENNETT_E_INVALID_STATE, BENNETT_E_NOT_REVERSIBLE,
  BENNETT_E_SCHEDULE_INFEASIBLE, BENNETT_E_ARG, BENNETT_E_NOMEM } bennett_status;
typedef struct bennett_program_t bennett_program_t;   typedef struct bennett_args_t bennett_args_t;
typedef struct bennett_result_t bennett_result_t;     typedef struct bennett_request_t bennett_request_t;
typedef struct bennett_estimate_t bennett_estimate_t; typedef struct bennett_coverage_t bennett_coverage_t;
typedef struct bennett_tape_iter_t bennett_tape_iter_t;
typedef uint64_t bennett_qreg; typedef uint64_t bennett_token; typedef uint64_t bennett_run_id;
typedef enum { BENNETT_ARG_INT, BENNETT_ARG_F64, BENNETT_ARG_QREG, BENNETT_ARG_TOKEN } bennett_arg_kind;

bennett_status bennett_load(const uint8_t* object, size_t len, const uint8_t* target_jcs, size_t tlen, bennett_program_t** out);
void           bennett_unload(bennett_program_t*);
bennett_status bennett_budget(bennett_program_t*, const char* region, uint64_t steps, uint64_t heap, uint64_t stack, uint64_t depth, bennett_token* out);
bennett_status bennett_qreg_new(bennett_program_t*, const char* cls, uint32_t n, bennett_qreg* out);
bennett_status bennett_qreg_prepare(bennett_program_t*, bennett_qreg, const uint8_t* bits, size_t nbits);
bennett_status bennett_qreg_free(bennett_program_t*, bennett_qreg);
bennett_status bennett_args_new(size_t n, bennett_args_t** out);
bennett_status bennett_args_set_int(bennett_args_t*, size_t i, uint32_t width, const uint8_t* le_bytes);
bennett_status bennett_args_set_f64(bennett_args_t*, size_t i, double);
bennett_status bennett_args_set_qreg(bennett_args_t*, size_t i, bennett_qreg);
bennett_status bennett_args_set_token(bennett_args_t*, size_t i, bennett_token);
void           bennett_args_free(bennett_args_t*);
bennett_status bennett_run(bennett_program_t*, const char* cc_entry, const bennett_args_t*, const uint8_t* entropy, size_t entropy_len, bennett_run_id* out);
bennett_status bennett_wait(bennett_program_t*, bennett_run_id, bennett_result_t** result_out, bennett_request_t** request_out); /* COMPLETED, FAILED or HOST_REQUEST */
bennett_status bennett_reply(bennett_program_t*, bennett_run_id, const uint8_t* payload, size_t len);
bennett_status bennett_suspend(bennett_program_t*, bennett_run_id);   /* takes effect at the next CC boundary outside any region */
bennett_status bennett_resume(bennett_program_t*, bennett_run_id);
bennett_status bennett_reverse(bennett_program_t*, bennett_run_id);
bennett_status bennett_run_close(bennett_program_t*, bennett_run_id);
size_t         bennett_result_nvalues(const bennett_result_t*);
bennett_status bennett_result_get(const bennett_result_t*, size_t i, bennett_arg_kind* kind, uint32_t* width, uint8_t* le_bytes_out, size_t cap);
size_t         bennett_result_nfaults(const bennett_result_t*);   uint64_t bennett_result_fault(const bennett_result_t*, size_t i);
size_t         bennett_result_nmeasurements(const bennett_result_t*);
bennett_status bennett_result_measurement(const bennett_result_t*, size_t i, bennett_qreg* reg, uint8_t* bits_out, size_t cap, size_t* nbits);
uint64_t       bennett_result_tape_length(const bennett_result_t*);   void bennett_result_free(bennett_result_t*);
const char*    bennett_request_service(const bennett_request_t*);
const uint8_t* bennett_request_payload(const bennett_request_t*, size_t* len);   void bennett_request_free(bennett_request_t*);
bennett_status bennett_tape_open(bennett_program_t*, bennett_run_id, bennett_tape_iter_t** out);
bennett_status bennett_tape_next(bennett_tape_iter_t*, const char** dev, const char** op, const uint8_t** args, size_t* alen, const uint8_t** results, size_t* rlen); /* E_INVALID_STATE at end */
void           bennett_tape_free(bennett_tape_iter_t*);
bennett_status bennett_estimate_run(bennett_program_t*, const char* region, bennett_token, bennett_estimate_t** out);
size_t         bennett_estimate_nresources(const bennett_estimate_t*);
bennett_status bennett_estimate_get(const bennett_estimate_t*, size_t i, const char** name, const char** value_decimal);
const uint8_t* bennett_estimate_certificate(const bennett_estimate_t*, size_t* len);   void bennett_estimate_free(bennett_estimate_t*);
bennett_status bennett_coverage_get(bennett_program_t*, bennett_coverage_t** out);
const uint8_t* bennett_coverage_jcs(const bennett_coverage_t*, size_t* len);   void bennett_coverage_free(bennett_coverage_t*);
```

## 11. Scheduling interface (sched 0.4)

```c
bennett_status bennett_sched_request_new(bennett_sched_request_t** out);
bennett_status bennett_sched_request_set_object(bennett_sched_request_t*, const uint8_t*, size_t);
bennett_status bennett_sched_request_set_target(bennett_sched_request_t*, const uint8_t* jcs, size_t);
bennett_status bennett_sched_request_set_region(bennett_sched_request_t*, const char* interface_hash_hex, const char* variant, uint32_t inherited_controls);
bennett_status bennett_sched_request_set_budget(bennett_sched_request_t*, uint64_t steps, uint64_t heap, uint64_t stack, uint64_t depth);
bennett_status bennett_sched_request_set_params(bennett_sched_request_t*, const uint8_t* params_jcs, size_t);
bennett_status bennett_sched_request_set_accuracy(bennett_sched_request_t*, const char* epsilon_decimal);
bennett_status bennett_sched_request_set_capacity(bennett_sched_request_t*, const char* cls, uint64_t peak_qubits);
void           bennett_sched_request_free(bennett_sched_request_t*);
bennett_status bennett_sched_schedule(const bennett_sched_request_t*, bennett_sched_response_t** out);
typedef enum { BENNETT_SCHED_OK, BENNETT_SCHED_INFEASIBLE, BENNETT_SCHED_UNSUPPORTED } bennett_sched_outcome;
bennett_sched_outcome bennett_sched_response_outcome(const bennett_sched_response_t*);
const char*    bennett_sched_response_reason(const bennett_sched_response_t*);
const uint8_t* bennett_sched_response_schedule(const bennett_sched_response_t*, size_t* len);     /* JCS */
const uint8_t* bennett_sched_response_certificate(const bennett_sched_response_t*, size_t* len);  /* JCS */
void           bennett_sched_response_free(bennett_sched_response_t*);
```

**Schedule document** (JCS; the object's `schedule` section):

```
  { "bindings": { "closure_hash", "target_hash", "region", "variant", "inherited_controls", "budget": [B,heap,stack,depth],
                  "params_hash", "epsilon", "scheduler": { "name", "version" } },
    "entries": [ { "path": [ { "symbol": hex, "point": "<block>:<ordinal>" }, ... ],   /* invocation path from the region's entry */
                   "iteration": n | "*", "phase": "fwd" | "rev" | "*",
                   "generated": "dispatch" | "history" | "gate" | "cleanup" | "comparator" | "*",
                   "kind": "cleanup" | "gate" | "alloc" | "start",
                   /* kind-specific, required: */
                   "cleanup": { "realisation": "reverse" | "recompute" | "mbu" },
                   "gate":    { "realisation": "native" | "<scheme name>", "epsilon_share": decimal },
                   "alloc":   { "class": "<cls>" },
                   "start":   { "time": decimal } } ] }
```

Entries are hierarchical: an entry applies to every generated operation
matching its `path`, `iteration`, `phase` and `generated` selectors;
more specific entries override less specific ones; a schedule MUST cover
every cleanup and every ε > 0 gate of the region under its bindings
(defaults: `reverse`, `native`, `any`, sequential). **Obligations**:
satisfy §6; respect capacity; report every declared resource; be
reproducible from the request plus scheduler version. A consumer
validates every binding (closure hash, target, variant, inherited
controls, budget, params, ε) and every path against the object, then
executes the schedule **verbatim** or rejects it and requests a
replacement; it never alters program semantics. The VM uses this
interface at run time.

## 12. Certificate (cert 0.4; JCS)

### 12.1 Claims

| kind | payload | checker obligation |
|---|---|---|
| `exhaustive` | `domain` (§12.2); `expected`: `"oracle"` \| `{ "table": [outputs in domain enumeration order] }` \| `{ "program": interface_hash }` | re-execute every domain element on the reference interpreter / the expected program and compare full tuples |
| `sampled` | `domain`; `sampler`: `{ "algorithm": "xoshiro256**", "seed": [4 × u64 as decimal strings], "count": n }`; each 64-bit output is consumed in domain-component order (bundles, then borrowed, then region cells, each in declared order, cells by index), mapped to `[lo, hi]` by rejection sampling on `output mod 2^⌈log₂(hi−lo+1)⌉` | replay; **evidence** |
| `structural` | `{ "rule": "toggling_lemma" \| "inverse_pair_library" \| "adjoint_table", "subclaims": [claim indices within this entry], "witness": { rule-specific fields: for `toggling_lemma`: the wire sets V, W, X and the frame's point range } }` | check the rule's side conditions syntactically against the object and the subclaims' results |
| `numerical` | `{ "widths", "metric": "operator_norm" \| "diamond", "bound": decimal, "method": "interval_arithmetic", "precision_bits": n, "witness": { "intervals": [...] } }` | recompute the stated intervals at the stated precision; a claim without a witness is **evidence** |

### 12.2 Domains

`"domain": { "bundles": [ { "name", "width", "lo": decimal, "hi": decimal } ], "borrowed": [ same ], "regions": [ { "name", "cells": "all" | [ { "index", "lo", "hi" } ] } ] }`,
all bounds inclusive; enumeration order is the listed order, last
component fastest. The checker verifies the domain equals D (§5.2) for a
`proof` label, else the claim is labelled `evidence` with the fraction
covered.

### 12.3 Schema and composition

```
  versions; bindings { object_hash, interface_hash, closure_hash?, reference_program_hash, dialect_mapping_version, target_hash, schedule_hash? }
  producer { name, version, materialisation { llvm_version, pipeline, normaliser_version } }
  regions { <interface_hash>: { kind, signature, bounds, frame (§9.4), resources { name: decimal }, gates_used { gate: { count, scheme?, epsilon? } },
            claims: [ <claim> ... ],  verification: { oracle: i, borrow_frames: [i], inverse_pairs: [ { g, ginv, claim: i } ], channel: [i],
                                                      fault_rate: { domain, faults_by_code, undefined_excluded, layout_dependent_excluded } },
            cleanup: { "<variant>:<inherited_controls>": [ { path, realisation } ] },
            error: { local: { metric, value }, inclusive: { metric, value } },  definedness_assumptions: [ids] } }
  composition { multiplicities: { <hash>: n (derived from the realised schedule) }, epsilon_total: { metric: "diamond", value }, method: "sum_over_multiplicities" }
```

`inclusive(R) = local(R) + Σ_callees n_c × inclusive(c)`; an operator-
norm value converts to diamond by ×2 **once**, at the point where it is
first combined with a diamond value. A measurement-assisted realisation
requires a `channel` claim; a controlled unitary variant requires an
`operator_norm` claim. Linking recomputes `composition`.

## 13. Coverage (coverage 0.4)

`{ "entries": [ { "point": <program-point id>, "source": "<dialect-spec stable id>", "classification": "lowered" | "trapped" | "shimmed", "reason", "fault_code"?, "shim_hash"?, "count" } ] }`.

## 14. Formal model

### 14.1 Reference interpreter *(normative)*

Executes an oracle's reference body per basis configuration: locations
and cells are bit-vectors, pseudo-locations are read-only, predication
is `if`, each §4.2 row is its classical function (assignment rows
assign; the stack and `alloctab` are arrays), `fault` records the code
and halts, `lift.retval` halts with success, the step counter counts
executed rows, counters are unbounded integers compared exactly. It
**defines** F_B and the budget unit and rejects any body that executes a
non-permutation gate.

### 14.2 Quantum state semantics

The state of a Q region is a vector in ⊗ over live wires in allocation
order (bundles little-endian). `qalloc` tensors |0⟩; `qfree` removes
clean factors; `qborrow` introduces a factor in unknown state, possibly
entangled with a reference system R, and the region's operation must be
U ⊗ I on it (§5.6); gates act by §4.4 under the active predicate;
`measure` (CC) is the projective computational-basis measurement with
Born probabilities, consuming the wires.

### 14.3 Theorems

- **T1 (totality).** For every well-formed oracle, budget and x ∈ D the
  reference interpreter halts within B + 1 rows and F_B(x) is unique.
- **T2 (prefix reversal).** For every executor whose realisation is a
  composition of ε = 0 permutation gates implementing §5.2 steps 1–4, on
  every x ∈ D every non-interface wire is clean after step 4 and borrowed
  bundles hold their initial values. *(Steps 1–2 are a permutation Π;
  step 3 acts on tgt, fr controlled on workspace; step 4 applies Π⁻¹.)*
- **T3 (permutation theorem).** If the realised unitary V of a circuit on
  span(D) is a permutation matrix and the final basis tuple equals P(x)
  for every x ∈ D, then V|span(D) = P. Applied to oracles, permutation
  actions and borrow frames (P = P' ⊗ I).
- **T4 (round trip).** For every finite valid CC/R trace with retained
  run history and tapes, LIFO reversal restores the classical
  environment, memory, allocation table, device-model state and history
  to entry values; observed external events are not retracted.
- **T5.** As §6.3.
- **T6 (executor agreement).** Two executors conforming to §3–§7 on one
  target with the same schedule produce on every x ∈ D the same final
  tuple for every oracle (exact) and, for every action, unitaries within
  `inclusive₁ + inclusive₂` in operator norm (channels: diamond, after the
  single ×2 conversion).

### 14.4 Mechanisation *(deferred)*

## 15. Conformance suites

| Suite | Class | Tests |
|---|---|---|
| A | Executor | classical ISA; run history and LIFO reversal with loops, recursion, effects, hostcall, fault records (T4) |
| B | Executor | oracle totality and prefix reversal: every fault code; B = 0; boundary halts; recursion via `lift.call`; matched `lift.oracle_uncall`; interface regions restored; pre-entered allocations; `lift.free` on pinned entries |
| C | Executor, Producer | T3 over full D at exhaustive widths for oracles, permutation actions, `qinplace` pairs, borrow frames; T6 agreement among VM, specialiser, re-indexed/inlined/structure-recovered forms and the reference interpreter |
| D | Executor | channel and unitary comparison (Choi state with reference system) for ε > 0 realisations and measurement-based cleanups; controlled-interference tests; numerical witnesses |
| E | Target author, Executor | JCS parsing; AST evaluation in exact rationals; matching rules; scheme expansion; aggregation per kind; timing model; import maps |
| F | Producer | versioning and disjointness; operand schema; row classes, write sets and frame sizing; index-space flattening; terminators; permutation-only oracles; §6 transfer and windows; adjoint table; borrow-frame rule and toggling-lemma side conditions; `in`-wire use; acyclic action graphs; grammar; schemas; hashes; linking; frame-descriptor live ranges |
| G | Launch | every §10 entry point and state transition; HOST_REQUEST/reply; suspend at CC boundaries; reverse eligibility and tree order; ownership |
| H | Scheduler | §6 validity; capacity; reproducibility; hierarchical schedule validation and verbatim execution; INFEASIBLE/UNSUPPORTED |

## 16. Canonical textual form (normative)

### 16.1 Lexical

UTF-8; LF line endings; one instruction per line; tokens separated by
exactly one space; no trailing spaces; exactly one blank line before
each `section` line and none elsewhere. `NAME := [A-Za-z_][A-Za-z0-9_.]*`;
`INT := -?(0|[1-9][0-9]*)`; `FLOAT :=` shortest round-trip decimal with
`.` or exponent, finite; `STRING := "…"` with escapes `\"`, `\\`, `\n`
only; `HEX := ([0-9a-f]{2})*`. Metadata lines are RFC 8785 canonical
JSON objects.

### 16.2 Grammar

```
  object    := header NL section*
  header    := "bennett-object" SP "isa=" VER SP "object=" VER SP "launch=" VER SP "sched=" VER SP "cert=" VER SP "coverage=" VER SP "target=" VER SP "ptr_width=" INT
  section   := NL "section" SP SECTNAME NL body
  SECTNAME  := "symbols" | "imports" | "functions" | "data" | "devices" | "layout" | "schedule" | "certificate" | "coverage"
  body      := jsonline | dataline* | function*        (jsonline for all metadata sections; dataline* for data; function* for functions)
  jsonline  := JCS-canonical JSON object NL
  dataline  := NAME SP HEX NL
  function  := fhead NL regs? block+
  fhead     := ("fn" SP ("cc"|"r") | "oracle" | "action" | "perm_action" | "lproc") SP "@" NAME SP "(" plist ")" SP "(" plist ")" SP "(" plist ")" SP "(" plist ")" SP "(" plist ")"
               -- oracle: (in..) (tgt) (fault) (mem..) (args..) ; action: (mut..) (in..) (mem..) (args..) () ; lproc: (params..) (result) () () () ; fn: (params..) (results..) () () ()
  plist     := (param ("," SP param)*)?
  param     := NAME ":" type (SP ("in"|"mut"))?
  type      := "i" INT | "ptr" | "f64" | "token" | "wire" | "wire[" INT "]" | "reg[" INT "]" | "region[" INT "," INT "]"
  regs      := "regs" SP "{" SP (NAME ":" type ("," SP NAME ":" type)*)? SP "}" (SP "result" SP NAME)? (SP "bounds" SP "{" INT ("," SP INT)* "}")? NL
  block     := "^" NAME "(" plist "):" NL instr+
  instr     := (lhs SP "=" SP)? OPCODE (SP operand)* (SP "{" NL instr+ "}" (SP "{" NL instr+ "}")?)? NL
  lhs       := NAME | "(" NAME ("," SP NAME)* ")"
  operand   := NAME | NAME "[" INT "]" | "@" NAME | "^" NAME ("(" (NAME ("," SP NAME)*)? ")")? | INT | FLOAT | STRING | "(" (NAME ("," SP NAME)*)? ")"
  OPCODE    := a mnemonic of §4 with its dotted suffix; its operand count and kinds are fixed by §4's form (results on the lhs)
  VER       := INT "." INT
```

### 16.3 Example objects

**Example 1** (`inc8`): one oracle, no lprocs, no memory.

```
bennett-object isa=0.4 object=0.4 launch=0.4 sched=0.4 cert=0.4 coverage=0.4 target=0.4 ptr_width=32

section symbols
{"0":{"interface_hash":"05a871bb58aeccd0d4f107ff2f6e6f25af6647bc50ccd3f0688a662dfe8e8ad9","kind":"oracle","name":"inc8","signature":{"abi":"0.4","args":[],"fault":4,"in":[8],"kind":"oracle","mem":[],"mut":[],"tgt":8,"tier":"q"}}}

section functions
oracle @inc8 (x:wire[8] in) (t:wire[8]) (f:wire[4]) () ()
regs { one:reg[8], r:reg[8] } result r
^entry():
one = lift.const 1
r = lift.add x one
lift.retval r
```

Its envelope (§9.2) is `isa=0` LF `ptr_width=32` LF the JCS signature LF
the four function lines joined by LF (no reference tokens, no data or
layout reached), and its interface hash is `05a871bb58aeccd0d4f107ff2f6e6f25af6647bc50ccd3f0688a662dfe8e8ad9`. With B ≥ 3 every x
yields `(x + 1 mod 256, 0)`; with B = 2 every x yields `(0, FAULT_BUDGET_
STEPS)`.

**Example 2** (`sum_db`): an oracle reading an interface region through
lifted memory, with a recursive lproc and a global.

```
bennett-object isa=0.4 object=0.4 launch=0.4 sched=0.4 cert=0.4 coverage=0.4 target=0.4 ptr_width=32

section symbols
{"0":{"interface_hash":"f059b9fde993afa37b3a519df2fecb928245071fee652bde04fc3c3e3c12a535","kind":"oracle","name":"sum_db","signature":{"abi":"0.4","args":[],"fault":4,"in":[8],"kind":"oracle","mem":[{"A":4,"W":8,"role":"in"}],"mut":[],"tgt":8,"tier":"q"}},"1":{"interface_hash":"5ced2c33438316a5f9c0da90312795c1e3ca9872977c74ed4af6dfdd6f72c6e2","kind":"lproc","name":"sum","signature":{"abi":"0.4","args":[],"in":[8,8],"kind":"lproc","tgt":8,"tier":"q"}}}

section functions
oracle @sum_db (n:wire[8] in) (t:wire[8]) (f:wire[4]) (db:region[4,8] in) ()
regs { base:reg[32], acc:reg[8], r:reg[8] } result r
^entry():
base = lift.const 4096
acc = lift.const 0
r = lift.call @sum (n, acc)
lift.retval r
lproc @sum (n:reg[8], acc:reg[8]) (r:reg[8]) () () ()
regs { z:reg[1], p:reg[32], idx:reg[32], one:reg[8], v:reg[8], acc2:reg[8], n2:reg[8] } result r
^entry():
z = lift.icmp.eq n zero
qbranch z ^done ^more
^more():
one = lift.const 1
n2 = lift.sub n one
idx = lift.zext n2
p = lift.add base idx
lift.boundscheck p 1
v = lift.load.i8 p
acc2 = lift.add acc v
r = lift.call @sum (n2, acc2)
lift.ret r
^done():
lift.ret acc

section data
zero 00

section layout
{"A_tab":4,"H":13,"S_cells":8,"globals":{"zero":{"base":16,"image":"zero","size":1}},"heap_base":32,"heap_limit_max":8160,"interface_regions":{"sum_db":{"db":{"base":4096}}},"null_size":16,"ptr_width":32}
```

Here `zero` is a 1-byte global at address 16 read by name as a pseudo-
location in `@sum` (a global's name denotes a lifted load of its image
width at its base; the dialect emits the `lift.boundscheck` for it, and
`@sum`'s `base` reference resolves to the oracle's location since lprocs
read the enclosing oracle's locations as pseudo-locations). The interface
region `db` is mapped at 4096; `alloctab` starts with pinned entries for
`zero` (16, 1) and `db` (4096, 16). With sufficient budget F_B(n) = (Σ_{i<n}
db[i] mod 256, 0) for n ≤ 16; for n > 16 the bounds check faults with
`FAULT_UB_MEMFAULT` at i = 16; with a small B the result is `FAULT_
BUDGET_STEPS`; with `depth_limit < n` it is `FAULT_BUDGET_DEPTH`. `5ced2c33438316a5f9c0da90312795c1e3ca9872977c74ed4af6dfdd6f72c6e2`
is `@sum`'s interface hash (its envelope reaches the `zero` data and
layout entries); `f059b9fde993afa37b3a519df2fecb928245071fee652bde04fc3c3e3c12a535` is `@sum_db`'s, with the `@sum` reference token
replaced by `@` + 5ced2c33438316a5f9c0da90312795c1e3ca9872977c74ed4af6dfdd6f72c6e2. `@sum` references itself, so it is an SCC of one member: its
intra-SCC reference is written `@$0`, its envelope is hashed to `scc_hash`
and 5ced2c33438316a5f9c0da90312795c1e3ca9872977c74ed4af6dfdd6f72c6e2 = SHA-256(`scc_hash` ‖ `:0`). The layout sub-entries an lproc or
oracle reaches are written one per line as `<dotted name> SP <JCS or INT>`
(here `A_tab`, `H`, `S_cells`, `globals.zero`, `heap_base`, `null_size`, and
for the oracle also `interface_regions.sum_db.db`), sorted by name. The
hashes below are computed by that rule:

```
05a871bb58aeccd0d4f107ff2f6e6f25af6647bc50ccd3f0688a662dfe8e8ad9 = 05a871bb58aeccd0d4f107ff2f6e6f25af6647bc50ccd3f0688a662dfe8e8ad9
5ced2c33438316a5f9c0da90312795c1e3ca9872977c74ed4af6dfdd6f72c6e2 = 5ced2c33438316a5f9c0da90312795c1e3ca9872977c74ed4af6dfdd6f72c6e2
f059b9fde993afa37b3a519df2fecb928245071fee652bde04fc3c3e3c12a535 = f059b9fde993afa37b3a519df2fecb928245071fee652bde04fc3c3e3c12a535
```

## 17. Open items *(deferred, asserted non-semantic)*

1. Binary encoding. 2. Gate-name registry. 3. Further device models.
4. Mechanisation. 5. Memory layout of the opaque C objects.
