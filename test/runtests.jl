using Test
using Bennett

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
include("test_ntuple_input.jl")
include("test_ancilla_reuse.jl")
include("test_dep_dag.jl")
include("test_pebbling.jl")
include("test_eager_bennett.jl")
include("test_switch.jl")
include("test_rev_memory.jl")
include("test_sat_pebbling.jl")
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
# Bennett-T5-P5a/P5b — multi-language ingest (`.ll` / `.bc`).
include("test_p5a_ll_ingest.jl")
include("test_p5a_equivalence.jl")
include("test_p5b_bc_ingest.jl")
include("test_p5_fail_loud.jl")

# T5 — persistent map protocol + harness self-test (T5-P3a, GREEN today).
include("test_persistent_interface.jl")
# T5-P3b — Okasaki RBT persistent map (insert + lookup; delete deferred).
include("test_persistent_okasaki.jl")
# T5-P3c — Bagwell HAMT + reversible popcount (Bennett-a7zy).
include("test_persistent_hamt.jl")
# T5-P3d — Conchon-Filliâtre semi-persistent (Bennett-6thy).
include("test_persistent_cf.jl")
# T5-P4 — Hash-cons compression layers (Bennett-gv8g + Bennett-7pgw).
include("test_persistent_hashcons.jl")

# T5 corpora — multi-language RED tests (T5-P2a/b/c).  All currently RED
# via @test_throws; safe to include unconditionally.  C and Rust corpora
# self-skip if clang/rustc not on PATH.  Set BENNETT_T5_TESTS=0 to skip all.
if get(ENV, "BENNETT_T5_TESTS", "1") != "0"
    include("test_t5_corpus_julia.jl")
    include("test_t5_corpus_c.jl")
    include("test_t5_corpus_rust.jl")
end
