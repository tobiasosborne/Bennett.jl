using Test
using Bennett

# Bennett-zy4u / U104: outer @testset wrapping. Gives a single
# `Test Summary: Bennett | Pass Total Time` aggregate at the end of
# Pkg.test instead of N flat per-include summaries, and ensures every
# `include`d test file's own @testsets nest under one named root.
# (Body is unindented to keep blame / merge churn minimal — Julia
# parses `begin ... end` blocks regardless of interior indentation.)
@testset "Bennett" begin

include("test_parse.jl")
include("test_increment.jl")
include("test_polynomial.jl")
include("test_bitwise.jl")
include("test_compare.jl")
include("test_two_args.jl")
include("test_controlled.jl")
include("test_branch.jl")
include("test_loop.jl")
include("test_combined.jl")
include("test_int16.jl")
include("test_int32.jl")
include("test_int64.jl")
include("test_mixed_width.jl")
include("test_loop_explicit.jl")
include("test_tuple.jl")
include("test_softfloat.jl")
include("test_softfmul.jl")
include("test_softfma.jl")
include("test_softfsub.jl")
include("test_softfcmp.jl")
include("test_softfdiv.jl")
include("test_softfsqrt.jl")
include("test_softfexp.jl")
include("test_softfexp_julia.jl")
include("test_softfconv.jl")
include("test_float_circuit.jl")
include("test_float_poly.jl")
include("test_predicated_phi.jl")
include("test_extractvalue.jl")
include("test_general_call.jl")
include("test_division.jl")
include("test_salb_div_by_zero.jl")
include("test_y986_loop_header_dispatch.jl")
include("test_gboa_dirty_bit_hygiene.jl")
include("test_d77b_fcmp_predicates.jl")
include("test_bjdg_constant_operand_errors.jl")
include("test_tpg0_normalize_zero_input.jl")
include("test_xiqt_subnormal_boundary.jl")
include("test_ys0d_exp_accuracy_contract.jl")
include("test_qmk6_dq8l_type_width_errors.jl")
include("test_cklf_resolve_width_assert.jl")
include("test_y56a_division_paths.jl")
include("test_yys3_uint128_compiler_rt.jl")
include("test_ntuple_input.jl")
include("test_ancilla_reuse.jl")
include("test_dep_dag.jl")
include("test_pebbling.jl")
include("test_eager_bennett.jl")
# Bennett-i2ca / U55: strategy dispatch parity tests.
include("test_bennett_strategy.jl")
include("test_switch.jl")
include("test_rev_memory.jl")
# Bennett-u2yp / U149: test_sat_pebbling.jl removed alongside src/pebble/sat_pebbling.jl
include("test_intrinsics.jl")
include("test_liveness.jl")
include("test_sha256.jl")
include("test_value_eager.jl")
include("test_pebbled_wire_reuse.jl")
include("test_constant_fold.jl")
include("test_var_gep.jl")
include("test_float_intrinsics.jl")
include("test_gate_count_regression.jl")
include("test_negative.jl")
include("test_soft_sitofp.jl")
include("test_sret.jl")
include("test_sha256_full.jl")
include("test_constant_wire_count.jl")
include("test_pebbled_space.jl")
include("test_wire_allocator.jl")
include("test_soft_fround.jl")
include("test_callee_bennett.jl")
include("test_cuccaro_safety.jl")
include("test_narrow.jl")
include("test_preprocessing.jl")
include("test_t0_preprocessing.jl")
include("test_ir_memory_types.jl")
include("test_store_alloca_extract.jl")
include("test_soft_mux_mem.jl")
include("test_soft_mux_mem_circuit.jl")
include("test_soft_mux_mem_guarded.jl")
include("test_lower_store_alloca.jl")
include("test_mutable_array.jl")
include("test_soft_mux_scaling.jl")
include("test_qrom.jl")
include("test_qrom_dispatch.jl")
include("test_memssa.jl")
include("test_memssa_integration.jl")
include("test_feistel.jl")
include("test_shadow_memory.jl")
include("test_universal_dispatch.jl")
include("test_memory_corpus.jl")
include("test_toffoli_depth.jl")
include("test_fast_copy.jl")
include("test_partial_products.jl")
include("test_qcla.jl")
include("test_add_dispatcher.jl")
include("test_parallel_adder_tree.jl")
include("test_mul_qcla_tree.jl")
include("test_mul_qcla_tree_paper_match.jl")
include("test_self_reversing.jl")
include("test_mul_dispatcher.jl")
include("test_softfdiv_subnormal.jl")
include("test_tabulate.jl")
# Bennett-cc0.7 — SLP-vectorised IR (insertelement/extractelement/
# shufflevector + vector arithmetic/icmp/select/cast).
include("test_cc07_repro.jl")
include("test_vector_ir.jl")
# Bennett-cc0.4 — constant-pointer icmp eq (ConstantExpr operand folding).
include("test_cc04_repro.jl")
# Bennett-cc0.6 — standardized ir_extract error-message format.
include("test_cc06_error_context.jl")
# Bennett-atf4 — lower_call! derives callee arg types from methods() instead of
# hardcoded UInt64; unblocks NTuple-aggregate callees (Bennett-z2dj prereq).
include("test_atf4_lower_call_nontrivial_args.jl")
# Bennett-0c8o — vector-lane sret stores + vector loads (SLP-vectorised
# NTuple{N,UInt64} returns); unblocks Bennett-z2dj.
include("test_0c8o_vector_sret.jl")
# Bennett-uyf9 — memcpy-form sret under optimize=false (auto-SROA canonicalisation).
include("test_uyf9_memcpy_sret.jl")
# Bennett-asw2 / U01 — verify_reversibility now checks Bennett invariants
# (ancilla-zero + input-preservation) instead of the tautological round-trip.
include("test_asw2_verify_reversibility.jl")
# Bennett-rggq / U02 — value_eager_bennett falls back to bennett(lr) on any
# CFG containing __pred_* groups (branching), avoiding Kahn-topo ordering bug.
include("test_rggq_value_eager_branching.jl")
# Bennett-egu6 / U03 — bennett() runtime-validates self_reversing=true
# primitives via a 4-probe battery checking ancilla-zero + input-preservation.
include("test_egu6_self_reversing_check.jl")
# Bennett-xy4j / U06 — soft_fmul now pre-normalises subnormal operands via
# _sf_normalize_to_bit52 before the 53×53 multiply (mirrors fdiv/fma).
include("test_xy4j_fmul_subnormal.jl")
# Bennett-prtp / U04 — pebbled_bennett / pebbled_group_bennett /
# checkpoint_bennett now fall back to bennett(lr) on any CFG with __pred_*
# groups (branching), avoiding "Unmapped wire N" crashes.
include("test_prtp_pebbled_branching.jl")
# Bennett-httg / U05 — lower_loop! routes body instructions through the
# canonical _lower_inst! dispatcher AND walks body blocks outside the
# header. Linear multi-block bodies work; diamond-in-body deferred.
include("test_httg_loop_multiblock.jl")
# Bennett-k286 / U07 — soft_fpext force-quiets signalling-NaN inputs per
# IEEE 754-2019 §5.4.1 (bit 51 of the Float64 result).
include("test_k286_fpext_snan_quiet.jl")
# Bennett-r84x / U08 — soft-float NaN payload/sign preservation, x86 INDEF
# for invalid ops, sNaN quieting in trunc/floor/ceil, fptosi saturation
# to INT_MIN. All bit-exact against Julia native / LLVM cvttsd2si.
include("test_r84x_nan_bit_exact.jl")
# Bennett-l9cl / U09 — ir_extract fails loud on ConstantInt width > 64.
# LLVM.jl's `convert(Int, ::ConstantInt)` silently truncates; IROperand.value
# is Int64, so i128+ constants cannot round-trip without data loss.
include("test_l9cl_i128_constantint.jl")
# Bennett-tu6i / U10 — extractvalue/insertvalue on StructType aggregates
# now fail loud (prev: raw UndefRefError deep in LLVM.jl).
include("test_tu6i_struct_extractvalue.jl")
# Bennett-u21m / U11 — switch phi patching runs globally and emits one
# incoming per unique synthetic predecessor (duplicate targets no longer
# collapse; later successor blocks no longer missed).
include("test_u21m_switch_phi_patching.jl")
# Bennett-vz5n / U12 — constant-index GEP scales the raw index by the
# source element's byte stride (was raw_idx; now raw_idx * bytes).
include("test_vz5n_gep_offset_bytes.jl")
# Bennett-plb7 / U13 — variable-index GEP fails loud on non-integer source
# element types (was: silent default to elem_width = 8).
include("test_plb7_irvargep_elem_width.jl")
# Bennett-4mmt / U14 — atomic/volatile load/store reject loud instead of
# silently producing a plain non-atomic IRLoad/IRStore.
include("test_4mmt_atomic_volatile_load_store.jl")
# Bennett-5oyt / U15 — unregistered/inline-asm calls reject loud (was
# silent drop, leaving dest SSA undefined). Benign-intrinsic allowlist
# keeps llvm.lifetime/trap/memset/etc. correctness-neutral.
include("test_5oyt_unregistered_callee.jl")
# Bennett-qal5 / U16 — multi-index GEPs and GEPs on unsupported bases
# reject loud (was silent drop, leaving dest SSA undefined). Full
# type-walking byte-offset accumulation deferred.
include("test_qal5_multi_index_gep.jl")
# Bennett-8b2f / U17 — `_get_deref_bytes` IR-string fallback regex now
# anchored to the specific param name (was: function-wide first-match).
include("test_8b2f_deref_bytes_per_param.jl")
# Bennett-g27k / U18 — cc0.3 catch narrowed: exception type + message
# + non-Bennett-authored guard (was: bare substring match that could
# swallow unrelated Bennett fail-loud errors).
include("test_g27k_cc03_catch_narrow.jl")
# Bennett-6fg9 / U19 — simulate arity + per-input bit-width guard (was:
# silent drop of extra tuple elements, silent wrap of over-wide values).
include("test_6fg9_simulate_arity.jl")
# Bennett-hmn0 / U20 — HAMT 9th-distinct-hash-slot overflow guard.
# Gated behind BENNETT_RESEARCH_TESTS as of U54 cycle 4 (HAMT relocated).
# include("test_hmn0_hamt_overflow.jl")  # → moved into research gate below
# Bennett-n3z4 / U21 — cf_reroot was-allocated flag fix.  Gated behind
# BENNETT_RESEARCH_TESTS as of U54 cycle 2 (CF relocated to research/).
# include("test_n3z4_cf_reroot_key_zero.jl")  # → moved into research gate below
# Bennett-sqtd / U22 — soft_feistel_int8 is NOT a bijection (was claimed
# to be); docstring + comment corrected, exact image size (207/256)
# pinned as a regression baseline.
include("test_sqtd_feistel_not_bijection.jl")
# Bennett-swee / U24 — WireAllocator rejects negative n and double-free.
include("test_swee_wire_allocator_negative.jl")
# Bennett-k0bg / U25 — reversible_compile validates bit_width,
# max_loop_iterations, and arg_types up-front.
include("test_k0bg_compile_validation.jl")
# Bennett-7stg / U26 — register_callee! / _lookup_callee wrapped in a
# ReentrantLock for safe concurrent use.
include("test_7stg_register_callee_locking.jl")
# Bennett-epwy / U28 — fold_constants default flipped to true; strictly
# safe pass, strictly cheaper circuit.
include("test_epwy_fold_constants_default.jl")
# Bennett-b1vp / U31 — soft_fptoui + LLVMFPToUI dispatch (was previously
# silently routed through the signed soft_fptosi).
include("test_b1vp_fptoui.jl")
# Bennett-xlsz / U29 — unify reversible_compile kwargs across the three
# overloads; unknown kwargs raise ArgumentError with the supported set.
include("test_xlsz_kwargs_unified.jl")
# Bennett-4fri / U30 — mul dispatcher `target=:depth` promotes `:auto`
# to `qcla_tree` (O(log² n) Toffoli-depth).
include("test_4fri_mul_target.jl")
# Bennett-spa8 / U27 — add dispatcher `:auto` → `:ripple` (Cuccaro
# is strictly worse post-Bennett copy-out at every measured width).
include("test_spa8_add_auto_ripple.jl")
# Bennett-6azb / U58 — simulator verifies input-preservation
# invariant; ReversibleCircuit asserts input/output/ancilla partition.
include("test_6azb_input_preservation.jl")
# Bennett-mlny / U63 — `depth` was exported + documented but never tested.
# Pins the basic shapes (empty=0, sequential=N, parallel=1, mixed) +
# regression-anchors the depth=19 number documented in the diagnostics
# docstring for `x -> x + Int8(1)` on Int8.
include("test_mlny_depth.jl")
# Bennett-6l2h / U67 + Bennett-xmdx / U66 — branching-callee coverage:
# `lower_call!` compact=true and `controlled(circuit)` were both untested
# on callees with internal branching.  Exhaustive Int8 sweep (abs +
# piecewise) under compact_calls=true and under controlled wrapping with
# ctrl=0/1.  Closes both beads as gap fills.
include("test_6l2h_branching_callee.jl")
# Bennett-T5-P5a/P5b — multi-language ingest (`.ll` / `.bc`).
include("test_p5a_ll_ingest.jl")
include("test_p5a_equivalence.jl")
include("test_p5b_bc_ingest.jl")
include("test_p5_fail_loud.jl")

# T5 — persistent map protocol + harness self-test (T5-P3a, GREEN today).
include("test_persistent_interface.jl")
# Bennett-uoem / U54 — relocation invariants for src/persistent/research/.
# Runs unconditionally; research-tier impls themselves are gated below.
include("test_uoem_research_relocation.jl")
# Bennett-ve3m / U165 — peak_live_wires line in print_circuit summary.
include("test_ve3m_show_peak_live_wires.jl")
# Bennett-ivoa / U121 + Bennett-e89s / U120 — harness persistence/key=0
# invariants and absent-vs-stored-zero collision contract pin.
include("test_ivoa_harness_invariants.jl")
# Bennett-m63k / U60 — strict-bits NaN coverage replacing isnan()-only
# checks (post-U08).  Caught a real bug in soft_fsub's NaN-RHS sign
# propagation; fix shipped in src/softfloat/fsub.jl in the same commit.
include("test_m63k_softfloat_strict_bits.jl")
# Bennett-9x75 / U61 — raw-bits fuzz across the full UInt64 input space
# for fadd/fsub/fmul/fdiv/fma/fsqrt (5000 each, ~30k strict-bit asserts).
include("test_9x75_softfloat_raw_bits_sweep.jl")
# Bennett-0zsk / U46 — pin the load-bearing error() paths in lower.jl
# and ir_extract.jl with @test_throws (12 testsets / 15 asserts).
include("test_0zsk_core_error_paths.jl")
# Bennett-ej4n / U48 — module-scoped ParsedIR cache so a circuit with N
# references to the same callee pays the ~21ms extract_parsed_ir cost once.
include("test_ej4n_callee_ir_cache.jl")
# Bennett-tfo8 / U113 — single-source-of-truth alloca-MUX strategy tables;
# pins consistency between _MUX_EXCH_STRATEGY and the load/store dispatch
# dicts so a future shape addition can't silently route to :unsupported.
include("test_tfo8_alloca_strategy_tables.jl")
# Bennett-2jny / U101 — ReversibleCircuit collection protocols
# (length / iterate / eltype / getindex / first/lastindex).
include("test_2jny_circuit_collection_api.jl")
# Bennett-kmuj / U106 — register_callee! registry grouped into per-domain
# tuples; pins disjointness + every grouped callee really gets registered.
include("test_kmuj_callee_groups.jl")
# Bennett-uinn / U93 — every defensive try/catch in src/ir_extract.jl
# narrows on InterruptException so Ctrl-C during compilation propagates.
include("test_uinn_catch_narrowing.jl")
# Bennett-069e / U143 — named DP sentinels in pebbling.jl
# (_PEBBLE_INF / _PEBBLE_FINITE_BOUND) replacing typemax(Int)÷2 magic;
# pins the no-overflow + init-sentinel-fails-gate invariants.
include("test_069e_pebble_sentinels.jl")
# Bennett-k7al / U99 — IR struct inner constructors validate op symbols
# (_IR_BINOP_OPS / _IR_ICMP_PREDS / _IR_CAST_OPS / _IR_OPERAND_KINDS),
# require width >= 1, and check IRCall arity / IRPhi non-empty incoming.
include("test_k7al_ir_constructor_asserts.jl")
# Bennett-pksz / U98 — `controlled(c)` asserts every inner gate uses
# wires in 1:c.n_wires before allocating ctrl_wire at n_wires+1.
include("test_pksz_controlled_contiguous_wires.jl")
# Bennett-zyjn / U94 — _get_deref_bytes errors loudly on caller-side
# bugs (param not in func, malformed defline) instead of silently
# returning 0; only the legitimate "no deref attr" case returns 0.
include("test_zyjn_deref_bytes_distinct_failures.jl")
# Bennett-8kno / U95 — _extract_const_globals narrows the LLVM.initializer
# catch to LLVM.jl's "Unknown value kind" / "LLVMGlobalAlias" errors only;
# OOM and other unexpected exceptions propagate.
include("test_8kno_extract_const_globals_narrowing.jl")
# Bennett-f6qa / U97 — every error("...") in lower.jl starts with a
# recognised function-or-helper prefix; pebbling/pebbled_groups budget
# wording unified to "insufficient pebbles — need at least N".
include("test_f6qa_error_message_prefixes.jl")
# Bennett-srsy / U103 — multi-language fixture toolchain guards: the
# rust/c/p5b corpora hard-fail under BENNETT_CI=1 (vs silent skip
# locally) when rustc / clang / llvm-as are missing.
include("test_srsy_ci_toolchain_guard.jl")
# Bennett-8p0g / U147 — hand-built ParsedIR seam test that exercises
# lower → bennett → simulate directly, bypassing LLVM extraction.
# Covers IRBinOp (add, xor), IRICmp, IRCast (zext), IRRet on minimal
# fixtures so lowering can be unit-tested independent of LLVM IR shape.
include("test_8p0g_parsed_ir_seam.jl")
# Bennett-wlf6 / U145 — public API docstrings carry ```jldoctest fences
# (executable doctests once Documenter.jl is wired). Static-inspection
# test that asserts the fences haven't reverted + smoke-checks that
# every doctest's expected value still holds in the canonical baseline.
include("test_wlf6_jldoctest_fences.jl")
# Bennett-doh6 / U158 — docs/make.jl scaffold present + executable
# doctest wiring for the wlf6 jldoctest fences. Static-inspection only;
# the actual doctest execution lives in `julia --project=docs docs/make.jl`
# per CLAUDE.md §14 (no GitHub CI).
include("test_doh6_docs_makejl.jl")
# Bennett-5qrn / U57 — trivial-identity peepholes (x+0, x*1, x|0, x⊕0,
# x-0, x*0, x&0, x&allones, x|allones, x⊕allones and commutative duals).
# Catches at the lower_binop! dispatcher BEFORE resolve! materialises the
# constant operand into ancilla wires. Reduces x*Int8(1) from 692 → 26
# gates (26.6× reduction at fold_constants=false). Pinned formulas:
# copy-out 3W+2, zero-result W+2.
include("test_5qrn_identity_peepholes.jl")
# Bennett-heup / U127 — _fold_constants contract pin (default-true at every
# entry point, per-arm dispatch witnesses, self_reversing short-circuit,
# reduction baselines). Investigated → doc-only: bead claims "off-by-default"
# and "mixes three concerns" both stale post-epwy / U28.
include("test_heup_fold_constants_contract.jl")
# Bennett-4bcp / U102 — actionable error for NTuple-typed arg ambiguity.
# `reversible_compile(f, NTuple{2,Int8})` interprets NTuple as 2-arg
# tuple; if f takes a single tuple arg, point at the `Tuple{NTuple}` wrap.
include("test_4bcp_ntuple_input_error.jl")
# Bennett-fehu / U105 — simulate!(buffer, circuit, inputs) in-place variant.
# Hot-loop callers preallocate a Vector{Bool} once and reuse it across
# many simulate calls.
include("test_fehu_simulate_inplace.jl")
# Bennett-2hhx / U136 — soft_round (IEEE 754 roundToIntegralTiesToEven).
# Bit-exact vs Base.round(::Float64): ties-to-even, subnormals, ±Inf, NaN
# (with quiet-bit), boundary at 2^52, plus 5,000-sample raw-bits sweep.
include("test_2hhx_soft_round.jl")
# Bennett-is5s / U131 — diagnose_nonzero(circuit, inputs) helper for
# bisecting Bennett-invariant violations (returns all violations
# without throwing). Subset of is5s; --dump-ir / verbose deferred.
include("test_is5s_diagnose_nonzero.jl")
# Bennett-jc0y / 59jj-cut — ReversibleCircuit.gates storage contract pin.
# Investigated → doc-only: bead claims "type-unstable apply! per gate" stale
# (Julia union-splits NOT/CNOT/Toffoli inside _simulate's hot loop); memory
# savings real but ~26% with 24+ site blast radius. Refactor deferred until
# a real workload OOMs; this file pins empirical baselines.
include("test_jc0y_gate_storage_contract.jl")
# Bennett-q04a / 59jj-cut — _convert_instruction Union-return contract.
# Investigated → doc-only: 18-arm Union return is real, but extraction
# is one-shot per compile (~5% of extract cost) — refactor blast radius
# (function body + caller dispatch) out of proportion. Pin IRInst
# subtype count, Union arm bound, caller dispatch shape, extraction
# allocation linearity.
include("test_q04a_convert_instruction_contract.jl")
# Bennett-cvnb / Sturm.jl-ao1 — bennett_direct convenience wrapper that
# asserts self_reversing=true and errors loud otherwise. Surfaces the
# existing fast path (bennett_transform.jl:101-105) for downstream
# library authors. README "Pre-reversed primitives" callout updated.
include("test_cvnb_bennett_direct.jl")
# Bennett-qcso / U59 — compose(c1, c2) pipeline composition. Implements
# c1.gates ++ renumbered(c2.gates) ++ reverse(c1.gates) with c2's input
# wires positionally aliased onto c1's output wires. Self-reversing
# inputs rejected (MVP). Unblocks Sturm `when(q) do f(x) end` (review
# F49/F50 — composition was UNCOVERED).
include("test_qcso_compose.jl")
# Bennett-zmw3 / U111 — robustness bounds: resolve!() mask at W=64 no
# longer relies on Julia shift saturation; constant-shift path now
# rejects k < 0 and k > W with a clear error; variable-shift mod-W
# semantics documented (Julia frontend OK; raw LLVM input gets mod-W
# instead of poison).
include("test_zmw3_shift_bounds.jl")
# Bennett-6u9q / U146 — end-to-end integration test for the stated
# vision: `controlled ∘ reversible_compile` is a unitary on a 2^N
# statevector. Compiles a tiny Bool→Bool function, controls it, applies
# the resulting circuit to (a) basis states, (b) a random superposition
# (norm preserved), and (c) the canonical |0⟩+|1⟩ superposition that
# Sturm's `when(qubit) do f(x) end` would lower into.
include("test_6u9q_quantum_vision_integration.jl")
# Bennett-5kio / U109 — sizehint! before push! loops in adder.jl,
# multiplier.jl, qcla.jl avoids O(log₂N) intermediate-vector
# reallocations on multi-thousand-gate paths. Pin the static presence
# of the hints + the canonical gate-count baselines (no behavioural
# drift).
include("test_5kio_sizehint_arithmetic.jl")
# Bennett-op6a / U140 — pin the actual lower_add_cuccaro! gate counts
# (Toffoli=2W−2, CNOT=4W−2, NOT=0) at W∈{2,3,4,8,16,32,64}; the docstring
# now matches the implementation (was advertising the carry-out
# variant's 2n/5n/2n).
include("test_op6a_cuccaro_gate_count.jl")
# Bennett-b2fs / U148 — `_unpack_args` in tabulate.jl returns a Tuple
# (stack-allocated, concretely-typed) instead of the previous
# Vector{Any} (per-row heap allocation + boxed elements). Pins the
# return type + end-to-end tabulate correctness.
include("test_b2fs_tabulate_tuple_unpack.jl")
# Bennett-ardf / U138 — soft_floor / soft_ceil / soft_trunc bit-exact
# NaN propagation against Base.floor/ceil/trunc; soft_fdiv's dead
# `_overflow_result` binding replaced with `_`.
include("test_ardf_floor_ceil_nan.jl")
# Bennett-jepw / U05-followup — diamond-in-body phi resolution
# (per-iteration LOCAL block_pred / branch_info / preds dicts inside
# lower_loop! + top-level loop_body_labels skip).
include("test_jepw_diamond_in_body.jl")
# Bennett-59jj / U47 (cut) — typed `simulate(c, ::Type{T}, inputs)::T`
# overload eliminates the 9-arm Union return type for hot loops.
include("test_59jj_typed_simulate.jl")
# Bennett-p94b / U110 — defensive asserts in `_compute_block_pred!`
# (distinct predecessors + width-1 block_pred) and `_edge_predicate!`
# (width-1 block_pred). Catches the false-path-sensitisation precondition.
include("test_p94b_predicate_asserts.jl")
# Bennett-fq8n / U84 — lower_phi! validates that every incoming SSA
# wire-vector has length == phi.width. resolve! doesn't enforce this.
include("test_fq8n_phi_mixed_widths.jl")
# Bennett-lgzx / U114 — `_convert_instruction` no longer silently drops
# stores of non-integer types or stores whose target pointer isn't a
# registered SSA name. Errors loudly per CLAUDE.md §1.
include("test_lgzx_store_fail_loud.jl")
# Bennett-ibz5 / U96 — `resolve!` trip-wires the OPAQUE_PTR_SENTINEL
# by name so the value=0 placeholder for unresolvable pointers does
# not silently materialise as the integer 0.
include("test_ibz5_opaque_ptr_sentinel.jl")
# Bennett-t3j0 / U83 — `_expand_switches` rejects input blocks whose
# labels collide with the reserved synthetic-block prefix `_sw_*` or
# the `:__unreachable__` unreachable-target sentinel.
include("test_t3j0_switch_label_collision.jl")
# T5-P3c — Bagwell HAMT + reversible popcount (Bennett-a7zy).
# Gated behind BENNETT_RESEARCH_TESTS as of U54 cycle 4 (HAMT + popcount
# relocated to research/).
# include("test_persistent_hamt.jl")  # → moved into research gate below
# T5-P3d — Conchon-Filliâtre semi-persistent (Bennett-6thy).
# Gated behind BENNETT_RESEARCH_TESTS as of U54 cycle 2.
# include("test_persistent_cf.jl")  # → moved into research gate below
# T5-P4b — soft_feistel32 standalone (winner-side, extracted from
# test_persistent_hashcons.jl during U54 cycle 5).  The remainder of
# the hashcons coverage rides under BENNETT_RESEARCH_TESTS below.
include("test_hashcons_feistel.jl")

# T5 corpora — multi-language RED tests (T5-P2a/b/c).  All currently RED
# via @test_throws; safe to include unconditionally.  C and Rust corpora
# self-skip if clang/rustc not on PATH.  Set BENNETT_T5_TESTS=0 to skip all.
if get(ENV, "BENNETT_T5_TESTS", "1") != "0"
    include("test_t5_corpus_julia.jl")
    include("test_t5_corpus_c.jl")
    include("test_t5_corpus_rust.jl")
end

# Bennett-uoem / U54 — preserved-but-deprecated persistent-map impls
# (CF, Okasaki, HAMT+popcount, Jenkins) live under src/persistent/research/
# and are not loaded by `using Bennett`.  Their tests are opt-in via
# BENNETT_RESEARCH_TESTS=1 (default off — research code, not on hot path).
# See src/persistent/research/README.md for the literate deprecation
# rationale and thaw conditions.
if get(ENV, "BENNETT_RESEARCH_TESTS", "0") != "0"
    # T5-P3b — Okasaki RBT persistent map (relocated 2026-04-25 / U54).
    include("test_persistent_okasaki.jl")
    # T5-P3d — Conchon-Filliâtre semi-persistent (relocated 2026-04-25 / U54).
    include("test_persistent_cf.jl")
    # Bennett-n3z4 / U21 — CF reroot key=0 regression (rides with CF).
    include("test_n3z4_cf_reroot_key_zero.jl")
    # T5-P3c — Bagwell HAMT + popcount (relocated 2026-04-25 / U54).
    include("test_persistent_hamt.jl")
    # Bennett-hmn0 / U20 — HAMT 9th-distinct-hash overflow regression.
    include("test_hmn0_hamt_overflow.jl")
    # T5-P4 — Hash-cons layered demos.  Cycle 5 will split the Feistel-only
    # standalone coverage back to the default path; for now the whole file
    # rides under the research gate because 6/6 layered demos and the
    # Jenkins standalone test all touch research-tier impls.
    include("test_persistent_hashcons.jl")
end

# Bennett-8403 / U159: per-source-file unit test homes for the catalogue-
# named files (Bennett.jl / lower.jl / ir_extract.jl). Other src/X.jl ↔
# test/test_X.jl mappings are documented in test/PER_SOURCE_INDEX.md.
include("test_bennett.jl")
include("test_lower.jl")
include("test_ir_extract.jl")

# Bennett-fidj / U217: liveness × :auto add dispatcher coverage.
include("test_fidj_liveness_auto_dispatcher.jl")

# Bennett-gk1h / U210: package hygiene gates (Aqua.jl + JET.jl).
include("test_hygiene_aqua_jet.jl")

end  # @testset "Bennett"  (Bennett-zy4u / U104)
