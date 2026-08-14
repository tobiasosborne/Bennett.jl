using Test
using Bennett

# Per-include progress tracking. The outer `@testset "Bennett"` (zy4u /
# U104) nests every file's testsets under one root, which means Julia's
# Test stdlib prints NOTHING until the whole suite finishes — a slow file
# is indistinguishable from a hang. `runfile` wraps `Base.include` to
# print a "▶ starting" marker before each file (flushed eagerly, so it
# appears the moment the file begins) and a "✓ done" line with per-file
# and cumulative elapsed time after. Files slower than 30s are coloured
# yellow so regressions stand out. Drop-in for `include` — call order is
# unchanged, so the zy4u nesting and gate-count baselines are untouched.
const _SUITE_T0 = time()
function runfile(path::AbstractString)
    printstyled(stderr, "▶  $path\n"; color = :light_black)
    flush(stderr)
    dt = @elapsed Base.include(@__MODULE__, path)
    printstyled(stderr,
                "   ✓ $path  $(round(dt; digits=1))s" *
                "  [$(round(time() - _SUITE_T0; digits=1))s total]\n";
                color = dt > 30 ? :yellow : :light_black)
    flush(stderr)
end

# Bennett-zy4u / U104: outer @testset wrapping. Gives a single
# `Test Summary: Bennett | Pass Total Time` aggregate at the end of
# Pkg.test instead of N flat per-include summaries, and ensures every
# `include`d test file's own @testsets nest under one named root.
# (Body is unindented to keep blame / merge churn minimal — Julia
# parses `begin ... end` blocks regardless of interior indentation.)
@testset "Bennett" begin

runfile("test_parse.jl")
runfile("test_increment.jl")
runfile("test_polynomial.jl")
runfile("test_bitwise.jl")
runfile("test_compare.jl")
runfile("test_two_args.jl")
runfile("test_controlled.jl")
runfile("test_branch.jl")
runfile("test_loop.jl")
runfile("test_combined.jl")
runfile("test_int16.jl")
runfile("test_int32.jl")
runfile("test_int64.jl")
runfile("test_mixed_width.jl")
runfile("test_loop_explicit.jl")
runfile("test_tuple.jl")
runfile("test_softfloat.jl")
runfile("test_softfmul.jl")
runfile("test_softfma.jl")
runfile("test_softfsub.jl")
runfile("test_softfcmp.jl")
runfile("test_softfdiv.jl")
runfile("test_softfsqrt.jl")
runfile("test_softfexp.jl")
runfile("test_softfexp_julia.jl")
runfile("test_softflog.jl")
runfile("test_softfpow.jl")
runfile("test_softfpow_julia.jl")
runfile("test_jexo_pow_accuracy_contract.jl")
runfile("test_softfsin.jl")
runfile("test_softftan.jl")
runfile("test_softfatan.jl")
runfile("test_softfatan2.jl")
runfile("test_softfasin.jl")
runfile("test_softfacos.jl")
# Bennett-m2bv: soft_tanh primitive (Tier C1.6 hyperbolic completion).
runfile("test_softftanh.jl")
# Bennett-ky5n: soft_sinh primitive (Tier C1.7 hyperbolic completion).
runfile("test_softfsinh.jl")
# Bennett-bybh: soft_cosh primitive (Tier C1.8 hyperbolic completion).
runfile("test_softfcosh.jl")
# Bennett-sfx9: soft_asinh primitive (Tier C1.9 hyperbolic completion).
runfile("test_softfasinh.jl")
# Bennett-eq9p: soft_acosh primitive (Tier C1.10 hyperbolic completion).
runfile("test_softfacosh.jl")
# Bennett-g82n: soft_atanh primitive (Tier C1.11 — FINAL hyperbolic, completes Tier C1 11/11).
runfile("test_softfatanh.jl")
# Bennett-0ulc: soft_log1p primitive (Tier C2.1 — high-leverage; simplifies asinh/acosh/atanh poly regimes).
runfile("test_softflog1p.jl")
# Bennett-o7cy: soft_expm1 primitive (Tier C2.2 — symmetric to log1p; future cleanup target for tanh/sinh/cosh).
runfile("test_softfexpm1.jl")
runfile("test_softfconv.jl")
runfile("test_float_circuit.jl")
runfile("test_float_poly.jl")
runfile("test_predicated_phi.jl")
runfile("test_extractvalue.jl")
runfile("test_general_call.jl")
runfile("test_division.jl")
runfile("test_salb_div_by_zero.jl")
# Bennett-sr8v: durable src-side memoisation of reversible_compile(::ParsedIR).
runfile("test_sr8v_compile_cache.jl")
# Bennett-uiaq: route reversible_compile(f, T) through _extract_parsed_ir_cached
# so back-to-back compiles auto-hit the sr8v cache.
runfile("test_uiaq_compile_cache_transparent.jl")
runfile("test_y986_loop_header_dispatch.jl")
runfile("test_gboa_dirty_bit_hygiene.jl")
runfile("test_d77b_fcmp_predicates.jl")
runfile("test_bjdg_constant_operand_errors.jl")
runfile("test_tpg0_normalize_zero_input.jl")
runfile("test_xiqt_subnormal_boundary.jl")
runfile("test_ys0d_exp_accuracy_contract.jl")
runfile("test_qmk6_dq8l_type_width_errors.jl")
runfile("test_cklf_resolve_width_assert.jl")
runfile("test_y56a_division_paths.jl")
runfile("test_yys3_uint128_compiler_rt.jl")
runfile("test_ntuple_input.jl")
runfile("test_ancilla_reuse.jl")
runfile("test_dep_dag.jl")
runfile("test_pebbling.jl")
runfile("test_eager_bennett.jl")
# Bennett-i2ca / U55: strategy dispatch parity tests.
runfile("test_bennett_strategy.jl")
# Bennett-kv7b / U65 (#05 F9): add × mul dispatcher kwarg cross-product.
runfile("test_add_mul_cross.jl")
runfile("test_switch.jl")
runfile("test_rev_memory.jl")
# Bennett-u2yp / U149: test_sat_pebbling.jl removed alongside src/pebble/sat_pebbling.jl
runfile("test_intrinsics.jl")
runfile("test_liveness.jl")
runfile("test_sha256.jl")
runfile("test_value_eager.jl")
runfile("test_pebbled_wire_reuse.jl")
runfile("test_constant_fold.jl")
runfile("test_var_gep.jl")
runfile("test_float_intrinsics.jl")

# --- Heavy tier: LLVM transcendental-dispatch tests --------------------
# Each of these 17 files compiles a soft-float transcendental (sqrt / exp
# / log / pow / sin / cos / tan / the inverse-trig + hyperbolic family)
# all the way down to a multi-million-gate reversible circuit and
# simulates it — collectively ~15 min of wall time, the bulk of the
# suite. Gated ON by default; set BENNETT_HEAVY_TESTS=0 to skip them when
# iterating on an unrelated code path (mirrors the BENNETT_T5_TESTS /
# BENNETT_RESEARCH_TESTS gates below). A full green-before-push run MUST
# leave the gate set — these exercise the core extract → lower → bennett
# pipeline, so almost any core change can perturb them.
# Body left unindented to keep blame / merge churn minimal — per the same
# rationale as the outer `@testset` (Bennett-zy4u / U104).
if get(ENV, "BENNETT_HEAVY_TESTS", "1") != "0"
# Bennett-1pb: direct llvm.sqrt / llvm.exp / llvm.exp2 dispatch.
runfile("test_1pb_llvm_transcendentals.jl")
# Bennett-582: direct llvm.log / llvm.log2 / llvm.log10 dispatch.
runfile("test_582_llvm_log_dispatch.jl")
# Bennett-emv: direct llvm.pow / llvm.powi dispatch.
runfile("test_emv_llvm_pow_dispatch.jl")
# Bennett-3mo: direct llvm.sin / llvm.cos dispatch.
runfile("test_3mo_llvm_sincos_dispatch.jl")
# Bennett-l5v8: Base.sin-on-SoftFloat sugar (transcendental dispatch
# overloads + the dq8l/U81 VoidType-wall extraction regression + one full
# reversible_compile(sin, Float64) E2E — the heavy part).
runfile("test_l5v8_softfloat_sugar_transcendentals.jl")
# Bennett-s1zl: direct llvm.tan dispatch (Tier C1 trig completion).
runfile("test_s1zl_llvm_tan_dispatch.jl")
# Bennett-qpke: direct llvm.atan dispatch (Tier C1.2 — atan, no rem_pio2).
runfile("test_qpke_llvm_atan_dispatch.jl")
runfile("test_ckvj_llvm_asin_dispatch.jl")
# Bennett-bd7f: direct llvm.acos dispatch (Tier C1.4 — reuses _asin_R from fasin.jl).
runfile("test_bd7f_llvm_acos_dispatch.jl")
# Bennett-7goc: direct llvm.atan2 + libm @atan2 dispatch (Tier C1.5).
runfile("test_7goc_llvm_atan2_dispatch.jl")
# Bennett-m2bv: direct llvm.tanh + libm @tanh dispatch (Tier C1.6 — first hyperbolic).
runfile("test_m2bv_llvm_tanh_dispatch.jl")
# Bennett-ky5n: direct llvm.sinh + libm @sinh dispatch (Tier C1.7 — second hyperbolic).
runfile("test_ky5n_llvm_sinh_dispatch.jl")
# Bennett-bybh: direct llvm.cosh + libm @cosh dispatch (Tier C1.8 — third hyperbolic).
runfile("test_bybh_llvm_cosh_dispatch.jl")
# Bennett-sfx9: direct llvm.asinh + libm @asinh dispatch (Tier C1.9 — fourth hyperbolic).
runfile("test_sfx9_llvm_asinh_dispatch.jl")
# Bennett-eq9p: direct llvm.acosh + libm @acosh dispatch (Tier C1.10 — fifth hyperbolic).
runfile("test_eq9p_llvm_acosh_dispatch.jl")
# Bennett-g82n: direct llvm.atanh + libm @atanh dispatch (Tier C1.11 — FINAL hyperbolic).
runfile("test_g82n_llvm_atanh_dispatch.jl")
# Bennett-0ulc: direct llvm.log1p + libm @log1p dispatch (Tier C2.1).
runfile("test_0ulc_llvm_log1p_dispatch.jl")
# Bennett-o7cy: direct llvm.expm1 + libm @expm1 dispatch (Tier C2.2).
runfile("test_o7cy_llvm_expm1_dispatch.jl")
end  # BENNETT_HEAVY_TESTS gate

# Bennett-lqif (Bennett-hao Phase 0): llvm.memcpy / memmove fail-loud
# residue (post-37mt: alloca-i64 + memmove). Per-shape green-path
# coverage is in test_37mt_memcpy_const_aligned.jl.
runfile("test_lqif_memcpy_memmove_reject.jl")
# Bennett-37mt (Bennett-hao Phase 1): const-size memcpy lowering for
# alloca-i8-backed pointers (byte-granular IRPtrOffset+IRLoad+IRStore).
runfile("test_37mt_memcpy_const_aligned.jl")
# Bennett-9nwt (Bennett-hao Phase 2): const-c const-N memset lowering
# for alloca-i8-backed dst (byte-granular IRStore-of-ConstOperand).
# Replaces benign-allowlist silent-drop with explicit case discrimination.
runfile("test_9nwt_memset_const.jl")
# Bennett-8su4: relocate the memset volatile-value check to AFTER the
# c==0/N==0 drop, so Julia's volatile c=0 GC-frame zero-init memset
# (`llvm.memset(... i8 0 ... i1 true)`) passes through as a no-op.
# Volatile c!=0 still rejects.
runfile("test_8su4_volatile_c0_memset.jl")
# Bennett-munq (Bennett-8bys sub-bead 1): extract `[N x i8]` ArrayType
# allocas as IRAlloca(elem_w=8, n_elems=N). Unblocks t5_tr2_hashmap.ll
# corpus for the existing 37mt/9nwt paths.
runfile("test_munq_arr_i8_alloca.jl")
# Bennett-ixiz: wider-element alloca support (lifts ew==8 gates in
# extract/instructions.jl alloca handler + _alloca_elem_width_bits helper,
# memcpy predicate 8, memset predicate 12, and aggregate.jl
# lower_ptr_offset! ptr-provenance propagation). Accepts arbitrary
# integer ew (8/16/32/64); same-width firewall in lowering/memory.jl
# unchanged.
runfile("test_ixiz_wider_alloca.jl")
# Bennett-doih (Bennett-8bys sub-bead under Bennett-hao Phase 3, 2026-05-16):
# global-pointer src memcpy. Splits predicate 5 in _handle_memcpy_arm into
# 5a (DST-as-global still rejects) and 5b (SRC-as-global dispatches to new
# _handle_memcpy_global_src arm). Threads ParsedIR.globals dict through
# _module_to_parsed_ir_on_func → _convert_instruction (kwarg) → _handle_intrinsic
# → _handle_memcpy_arm → _handle_memcpy_global_src.
runfile("test_doih_memcpy_global_src.jl")
# Bennett-zxhg (Bennett-doih follow-up, 2026-05-16): ConstantStruct global
# extraction. Adds ConstantStruct + ConstantAggregateZero(StructType) arms
# to _extract_const_globals; pure-integer structs (incl. nested + non-packed)
# flatten to a byte stream at elem_width=8 via LLVM.offsetof/abi_size. Any
# non-integer field (ptr/float/vector/i128) hard-rejects → silently skipped
# in the dict → G5 in _handle_memcpy_global_src fires the precise
# `Bennett-zxhg-ptrfield` breadcrumb (the t5_tr2_hashmap.ll:153 case).
runfile("test_zxhg_struct_global.jl")
# Bennett-land (Bennett-zxhg follow-up, 2026-05-16): ptr-typed ConstantStruct
# field materialisation via synthetic 64-bit LE addresses. `_ptr_identity` →
# `(:named, ref)` / `(:null, 0)` lower to `0x1000_0000_0000_0000 | counter`;
# `(:addr, K)` and `nothing` still reject. New load-escape guard at
# `_handle_load` fails loud (`Bennett-land-ptrload`) when synth-tagged
# alloca bytes are consumed by anything other than another `llvm.memcpy.*`.
runfile("test_land_ptrfield_struct.jl")
# Bennett-h6f: direct llvm.fma / llvm.fmuladd dispatch.
runfile("test_h6f_llvm_fma_dispatch.jl")
# Bennett-4eu: indirectbr fail-loud hard stop.
runfile("test_4eu_indirectbr_reject.jl")
# Bennett-nj6c (Bennett-dnh phase 1a): runtime-idx MUX-EXCH on extended shapes.
runfile("test_nj6c_extended_mux_shapes.jl")
# Bennett-cb9y (Bennett-dnh phase 1b): multi-origin ptr × runtime idx.
runfile("test_cb9y_multi_origin_runtime_idx.jl")
runfile("test_gate_count_regression.jl")
runfile("test_negative.jl")
runfile("test_soft_sitofp.jl")
runfile("test_sret.jl")
runfile("test_dv1z_hetero_sret.jl")
runfile("test_jghk_multireturn_sret.jl")
runfile("test_59zi_sret_call_memcpy.jl")
runfile("test_xrd6_sret_consumed_call.jl")
runfile("test_416r17_sret_forward_cell_args.jl")
runfile("test_416r16_consumed_sret_reconcile.jl")
runfile("test_416r13_jlglobal_singleton.jl")
runfile("test_klgz_determinism_guard.jl")
runfile("test_sha256_full.jl")
runfile("test_constant_wire_count.jl")
runfile("test_pebbled_space.jl")
runfile("test_wire_allocator.jl")
runfile("test_soft_fround.jl")
runfile("test_callee_bennett.jl")
runfile("test_cuccaro_safety.jl")
runfile("test_narrow.jl")
runfile("test_preprocessing.jl")
runfile("test_t0_preprocessing.jl")
runfile("test_ir_memory_types.jl")
runfile("test_store_alloca_extract.jl")
runfile("test_soft_mux_mem.jl")
runfile("test_soft_mux_mem_circuit.jl")
runfile("test_soft_mux_mem_guarded.jl")
runfile("test_lower_store_alloca.jl")
runfile("test_mutable_array.jl")
runfile("test_soft_mux_scaling.jl")
runfile("test_qrom.jl")
runfile("test_qrom_dispatch.jl")
runfile("test_memssa.jl")
runfile("test_memssa_integration.jl")
runfile("test_feistel.jl")
runfile("test_shadow_memory.jl")
runfile("test_universal_dispatch.jl")
runfile("test_memory_corpus.jl")
runfile("test_toffoli_depth.jl")
runfile("test_fast_copy.jl")
runfile("test_partial_products.jl")
runfile("test_qcla.jl")
runfile("test_add_dispatcher.jl")
runfile("test_parallel_adder_tree.jl")
runfile("test_mul_qcla_tree.jl")
runfile("test_mul_qcla_tree_paper_match.jl")
runfile("test_self_reversing.jl")
runfile("test_rjk7_self_reversing_all_strategies.jl")
runfile("test_mul_dispatcher.jl")
runfile("test_softfdiv_subnormal.jl")
runfile("test_tabulate.jl")
# Bennett-cc0.7 — SLP-vectorised IR (insertelement/extractelement/
# shufflevector + vector arithmetic/icmp/select/cast).
runfile("test_cc07_repro.jl")
runfile("test_vector_ir.jl")
# Bennett-ao66 — vector-form LLVM intrinsic calls scalarised lane-wise.
runfile("test_ao66_vector_intrinsic_rescalarise.jl")
# Bennett-pg5 — llvm.vector.reduce.{add,mul,and,or,xor,smax,smin,umax,umin}
# integer reductions (vector → scalar via linear left-to-right fold chain).
runfile("test_pg5_vector_reductions.jl")
# Bennett-lx5h — llvm.vector.reduce.{fadd,fmul,fmin,fmax,fminimum,fmaximum,
# fminimumnum,fmaximumnum} float reductions (fold via IRCall over the
# matching soft_* primitive; fadd/fmul carry a scalar START arg).
runfile("test_lx5h_float_vector_reductions.jl")
# Bennett-cc0.4 — constant-pointer icmp eq (ConstantExpr operand folding).
runfile("test_cc04_repro.jl")
# Bennett-cc0.6 — standardized ir_extract error-message format.
runfile("test_cc06_error_context.jl")
# Bennett-atf4 — lower_call! derives callee arg types from methods() instead of
# hardcoded UInt64; unblocks NTuple-aggregate callees (Bennett-z2dj prereq).
runfile("test_atf4_lower_call_nontrivial_args.jl")
# Bennett-0c8o — vector-lane sret stores + vector loads (SLP-vectorised
# NTuple{N,UInt64} returns); unblocks Bennett-z2dj.
runfile("test_0c8o_vector_sret.jl")
# Bennett-uyf9 — memcpy-form sret under optimize=false (auto-SROA canonicalisation).
runfile("test_uyf9_memcpy_sret.jl")
# Bennett-asw2 / U01 — verify_reversibility now checks Bennett invariants
# (ancilla-zero + input-preservation) instead of the tautological round-trip.
runfile("test_asw2_verify_reversibility.jl")
# Bennett-rggq / U02 — value_eager_bennett falls back to bennett(lr) on any
# CFG containing __pred_* groups (branching), avoiding Kahn-topo ordering bug.
runfile("test_rggq_value_eager_branching.jl")
# Bennett-egu6 / U03 — bennett() runtime-validates self_reversing=true
# primitives via a 4-probe battery checking ancilla-zero + input-preservation.
runfile("test_egu6_self_reversing_check.jl")
# Bennett-h0ai — auto self_reversing detection via producer-tag (GateGroup.is_self_reversing)
# + structural aggregator (_infer_self_reversing) + U03 runtime probe with
# `trusted_dirty_wires` allowlist for the entry-block predicate. Conservative
# under the current arith.jl:218 dispatch (no producer ever fires today; the
# infrastructure is wired and tested via direct mechanism-level construction).
runfile("test_h0ai_auto_self_reversing.jl")
# Bennett-xy4j / U06 — soft_fmul now pre-normalises subnormal operands via
# _sf_normalize_to_bit52 before the 53×53 multiply (mirrors fdiv/fma).
runfile("test_xy4j_fmul_subnormal.jl")
# Bennett-prtp / U04 — pebbled_bennett / pebbled_group_bennett /
# checkpoint_bennett now fall back to bennett(lr) on any CFG with __pred_*
# groups (branching), avoiding "Unmapped wire N" crashes.
runfile("test_prtp_pebbled_branching.jl")
# Bennett-httg / U05 — lower_loop! routes body instructions through the
# canonical _lower_inst! dispatcher AND walks body blocks outside the
# header. Linear multi-block bodies work; diamond-in-body deferred.
runfile("test_httg_loop_multiblock.jl")
# Bennett-s0tn — fail-loud loop-overflow detection: lower_loop! emits a
# convergence wire copied out parallel to Bennett's output copy-out;
# simulate errors loud when an input needs more than max_loop_iterations.
runfile("test_s0tn_loop_overflow.jl")
# Bennett-k286 / U07 — soft_fpext force-quiets signalling-NaN inputs per
# IEEE 754-2019 §5.4.1 (bit 51 of the Float64 result).
runfile("test_k286_fpext_snan_quiet.jl")
# Bennett-r84x / U08 — soft-float NaN payload/sign preservation, x86 INDEF
# for invalid ops, sNaN quieting in trunc/floor/ceil, fptosi saturation
# to INT_MIN. All bit-exact against Julia native / LLVM cvttsd2si.
runfile("test_r84x_nan_bit_exact.jl")
# Bennett-l9cl / U09 — ir_extract fails loud on ConstantInt width > 64.
# LLVM.jl's `convert(Int, ::ConstantInt)` silently truncates; IROperand.value
# is Int64, so i128+ constants cannot round-trip without data loss.
runfile("test_l9cl_i128_constantint.jl")
# Bennett-tu6i / U10 — extractvalue/insertvalue on StructType aggregates
# now fail loud (prev: raw UndefRefError deep in LLVM.jl).
runfile("test_tu6i_struct_extractvalue.jl")
# Bennett-u21m / U11 — switch phi patching runs globally and emits one
# incoming per unique synthetic predecessor (duplicate targets no longer
# collapse; later successor blocks no longer missed).
runfile("test_u21m_switch_phi_patching.jl")
# Bennett-vz5n / U12 — constant-index GEP scales the raw index by the
# source element's byte stride (was raw_idx; now raw_idx * bytes).
runfile("test_vz5n_gep_offset_bytes.jl")
# Bennett-plb7 / U13 — variable-index GEP fails loud on non-integer source
# element types (was: silent default to elem_width = 8).
runfile("test_plb7_irvargep_elem_width.jl")
# Bennett-4mmt / U14 — atomic/volatile load/store reject loud instead of
# silently producing a plain non-atomic IRLoad/IRStore.
runfile("test_4mmt_atomic_volatile_load_store.jl")
# Bennett-ares / CW-D2 lever 1 — VM-gated U14 atomic relaxation. Under
# ptr_cells=true the relaxable ordering band {NotAtomic,Unordered,Monotonic,
# Acquire,Release} falls through to the existing IRLoad/IRStore lowering;
# strong orderings + volatile stay fail-loud; circuit path is byte-identical.
runfile("test_ares_atomic_vm_relax.jl")
# Bennett-5oyt / U15 — unregistered/inline-asm calls reject loud (was
# silent drop, leaving dest SSA undefined). Benign-intrinsic allowlist
# keeps llvm.lifetime/trap/etc. correctness-neutral. (memset graduated
# out of the allowlist via Bennett-9nwt — handled explicitly now.)
runfile("test_5oyt_unregistered_callee.jl")
# Bennett-qal5 / U16 — multi-index GEPs and GEPs on unsupported bases
# reject loud (was silent drop, leaving dest SSA undefined). Full
# type-walking byte-offset accumulation deferred.
runfile("test_qal5_multi_index_gep.jl")
# Bennett-8b2f / U17 — `_get_deref_bytes` IR-string fallback regex now
# anchored to the specific param name (was: function-wide first-match).
runfile("test_8b2f_deref_bytes_per_param.jl")
# Bennett-k3ej / BVM ADR 0020 (CW-C2 chunk A) — IRCall.callee widened to
# Union{Function,Symbol} (D1) + C deref-absent ptr param → opaque Int64
# cell-address arg (D2). Also covers the `_get_deref_bytes` actual-define-line
# fallback fix (clang `; Function Attrs:` comment line was read as the define).
runfile("test_k3ej_ircall_symbol_c_ptr_param.jl")
# Bennett-haiy / BVM ADR 0020 (CW-C2 chunk B) — C ptr instruction surface
# under the `ptr_cells` gate: store/load ptr → 64-bit cell IRStore/IRLoad +
# ptr return → ret_width 64 (D3); two-index struct GEP → IRPtrOffset(elem_width
# 64) via LLVM.offsetof (D4). Default (gate-off) keeps every Julia-path
# fail-loud (U114/U16/U81) byte-identical. void-return left for chunk C.
runfile("test_haiy_ptr_cells_store_load_gep.jl")
# bennettvm-9n3y (CW-D4) — the Julia GenericMemory HEADER struct GEP (the
# LITERAL `{ i64, ptr }` shape) is stamped BYTE-granular (elem_width 8) under
# ptr_cells, unifying the word-shaped element path with the byte-shaped
# fill!/memset `.ptr_ptr` path AND the 416r.13 singleton headers on ONE cell
# (+8). A NAMED C `%struct.T {i64,ptr}` keeps elem_width 64 (C tier
# byte-identical). Includes the programmatic fdict memory_data_ptr sweep.
runfile("test_9n3y_memheader_gep.jl")
# Bennett-nd45 / BVM ADR 0020 (CW-C2 chunk C) — C call emission under the
# `ptr_cells` gate: libc + in-module call → Symbol-callee IRCall (D5a); void
# call (sentinel dest) + void return (IRRet() void form, ret_width 0) (D5b);
# alloca ptr → IRAlloca(_,64,1) (D5c); multi-function producer
# extract_parsed_ir_set_from_ll → Vector{Pair{Symbol,ParsedIR}} (D6). Default
# (gate-off) keeps every Julia-path fail-loud (U15/U114/U81) byte-identical.
runfile("test_nd45_ptr_cells_call_emission_multifn.jl")
# Bennett-CW-D1a / bennettvm-416r.11 chunk a — transitive_callees typed
# call-graph walker (src/extract/callgraph.jl). Walks Julia inference's
# optimized typed code from a root (f, argtypes), harvests :invoke edges, and
# transitively closes the callee set (root excluded, edges@optimize=true per the
# corrected ADR-0021 Decision-1). The path to SC9 Case B (reversible Dict).
runfile("test_d1a_transitive_callees.jl")
# Bennett-CW-D1b / bennettvm-416r.11 chunk b — extract_parsed_ir_set_from_julia
# closed-world Julia multi-IR producer (src/extract/julia_set.jl). Walks
# transitive_callees, extracts root+helper bodies, keys by drift-free canonical
# Symbols, fails loud on any IRCall escaping the closed world. fdict_d1b is an
# HONEST tripwire (Gate E): bodies hit the U81/U14/dv1z walls (the accepted
# closed-world runway, cleared by CW-D2), so >=4 is @test_broken not faked green.
runfile("test_d1b_julia_set.jl")
# Bennett-40ys — INSTANCE-LESS callee keys (closures + functors) in the
# closed-world walker. `transitive_callees` keys a callee by its specTypes head;
# for a plain function that head is a singleton `typeof(g)` with a `.instance`,
# but Julia 1.12 outlines `_growend!`'s slow path into a CLOSURE, so every
# `push!`-bearing function yielded a fields-bearing callable type whose
# `.instance` is undefined — a bare `UndefRefError` from the registration loop,
# outside any try/catch. Fix: a TOTAL `_callee_key_kind` classifier (no key
# shape can reach `.instance` unless it is a singleton) plus by-SIGNATURE IR
# emission (src/extract/sig_llvm.jl), since Julia's own codegen never needed the
# value — only `signature_type(f, t)`, which the call graph already holds.
# Also: the canonical key now digests the FULL specTypes (a closure's argtypes
# are `Tuple{}` for ALL closures, so an argtypes-only digest collided distinct
# bodies), and instance-less call sites bind to the BARE name so BennettVM can
# resolve them. `push!` still walls — since Bennett-7wsz at the unrecognised
# JIT global `@jl_diverror_exception` (bennettvm-416r.13), NAMED.
runfile("test_40ys_instanceless_callees.jl")
# Bennett-7wsz — ptr-TYPED sret struct FIELDS under `ptr_cells=true`: a pointer
# sret field is one 64-bit VM cell (ADR 0018 §A), admitted in BOTH
# `_sret_struct_fields` (the field-layout predicate, reached from the callee
# `_detect_sret`, the caller 416r.16 recognizer, and `_emit_cell_call`) AND
# `_try_handle_sret_scalar_store!` (`store ptr` into a field — what Julia emits
# post-auto-SROA). Gated: `ptr_cells=false` stays byte-identical, because on the
# circuit path pointer args are DROPPED from `ParsedIR.args` and an ungated
# admission silently miscompiles. `return_roots` is modelled VERBATIM as an
# ordinary out-pointer, `i64 -1` sentinel and all — testset (E) pins the
# UNFUSED shape on purpose.
runfile("test_7wsz_ptr_sret_fields.jl")
# Bennett-CW-D2 / bennettvm-416r.12 — close the fdict closed-world set: the 4th
# classifier bucket (_D1B_MODELED_HEAP_INTRINSICS, mirrors BVM _HEAP_DISPATCH)
# tolerates modeled heap/runtime intrinsics (gc_alloc_obj, memset,
# jl_alloc_genericmemory_unchecked) + julia.write_barrier is dropped at
# extraction. fdict_d1b now closes to a 4-body set under ptr_cells=true.
runfile("test_416r12_closed_world_heap.jl")
# Bennett-lf14 — ptr_cells gate on the Julia-function entry path
# (src/extract/entry.jl + julia_set.jl). The .ll/.bc entries already exposed
# ptr_cells (Bennett-haiy/nd45); lf14 closes the only entry that omitted it and
# threads it through extract_parsed_ir_set_from_julia. Clears the ptr-RETURN
# "unsupported LLVM type/PointerType" wall for setindex!/rehash! (which return
# the Dict as a nonnull ptr): wall-advance proof (cells-OFF still the ptr-RETURN
# wall; cells-ON advances to the U14 atomic-load / U81 void wall), plus a
# default-off byte-identity pin (ptr-free fn extracts identically, gate_count 39).
runfile("test_lf14_ptr_return_cells.jl")
# Bennett-zf5v / CW-D2 — drop the GC-rooting intrinsics
# llvm.julia.gc_preserve_begin (token return) / gc_preserve_end (void) in the
# ptr_cells C-call arm (src/extract/instructions.jl), and allowlist
# julia.get_pgcstack in _D1B_BENIGN_INTRINSIC_PREFIXES (src/extract/julia_set.jl)
# so the modeled get_pgcstack cell IRCall survives the closed-world check. At
# optimize=false the real fdict_d1b root walled at the gc_preserve_begin
# TokenType reject; this advances it to a `ptrtoint ... unsupported LLVM opcode`
# wall (the next CW-D lever). ptr_cells-gated: circuit path byte-identical.
runfile("test_zf5v_gc_preserve.jl")
# Bennett-3ptu / CW-D2 — DROP LLVM `fence` under the ptr_cells closed-world VM
# gate (src/extract/instructions.jl). A `fence` is a pure memory-ordering
# barrier with no data effect → a genuine no-op in the single-threaded,
# deterministic, history-reversible BennettVM (no state change, trivially
# reversible). Every Julia closed-world callee emits 2 such fences (GC safepoint
# / write-barrier), so the drop unblocks setindex!/rehash!/ht_keyindex2 body
# extraction. ptr_cells-gated and exact-opcode-scoped: gate-off the fence stays
# fail-loud at the existing "unsupported LLVM opcode" wall (circuit path
# byte-identical). Mirrors the gc_preserve drop (zf5v) and atomic relax (ares).
runfile("test_3ptu_fence_drop.jl")
# Bennett-iwo9 / CW-D3 Lever 1 — recognise Julia type-tag globals
# (@"+Type#N") BY NAME and model the closed-world cluster
# `load @"+Type#N" → ptrtoint → inttoptr` under the ptr_cells VM gate
# (src/extract/{constexpr,module_walk,instructions}.jl). The tag load lowers to
# a deterministic name-derived dense id (NEVER the JIT address); the
# ptrtoint/inttoptr round-trip is admitted ONLY when its source carries tag
# provenance, else fail-loud (a genuine arena-pointer↔int cast is rejected).
# `#N`-invariant + deterministic interning. ptr_cells-gated: gate-off the SAME
# fixture walls at the pre-existing "unsupported LLVM opcode" ptrtoint fail-loud
# (circuit path byte-identical). Advances the fdict root to the gc_alloc_obj
# wall (Lever 2, separate bead). Does NOT touch gc_alloc_obj or BennettVM.
runfile("test_iwo9_typetag.jl")
# Bennett-r92o / CW-D3 Lever 2 — julia.gc_alloc_obj un-drop under the closed-world
# `ptr_cells=true` gate: a Symbol-callee IRCall(:gc_alloc_obj, [size,tag], [64,64], 64)
# with the task arg dropped, fail-loud on wrong arity. Gate-off byte-identical
# (broad julia.gc_ benign drop intact). Does NOT touch BennettVM (Lever 3).
runfile("test_r92o_gc_alloc_obj.jl")
# Bennett-beaw / CW-D — model `ptr null` (ConstantPointerNull) as a zero 64-bit
# VM cell under the closed-world `ptr_cells=true` gate (null = address 0, one
# Int64 cell; ADR 0018 §A). On the circuit path (ptr_cells=false) it stays
# FAIL-LOUD (Bennett-bjdg / U80 byte-identical). The fdict-root successor wall
# past iwo9/r92o (the `store ptr null` field-inits in inlined setindex!).
runfile("test_beaw_null_ptr.jl")
# Bennett-vbv9 — CW-D: global-src memcpy into a `julia.gc_alloc_obj`-backed
# ARENA cell under ptr_cells. Captures scalar ConstantInt globals (Part 1) and
# generalises the doih G3 dst-root from alloca-only to gc_alloc'd arena (Part
# 2). The fdict-root successor wall past beaw (the field-init memcpys from
# scalar const-globals into gc_alloc'd Dict cells).
runfile("test_vbv9_arena_memcpy.jl")
# Bennett-6bu3 — CW-D: StructType insertvalue/extractvalue (per-field layout).
# Adds an additive `field_widths::Vector{Int}` to IRInsertValue/IRExtractValue
# so the `{ptr,ptr}` GenericMemoryRef body (and fixed-width integer tuples)
# lower; keeps {i64,i1} (i1) and float/nested-struct fields fail-loud. The
# fdict-root successor wall past vbv9.
runfile("test_6bu3_struct_aggregate.jl")
# Bennett-qmv7 — CW-D: `setindex!` heap-Memory value-store memcpy whose DST is a
# RUNTIME-INDEXED `julia.gc_loaded` heap-Memory cell, under ptr_cells (the dual
# of vbv9's const-offset gc_alloc arena dst). Recovers the RAW element index
# (eln6-safe `mul %off, STRIDE` split) and emits IRVarGEP+IRLoad+IRStore at the
# VALUE width. Clears the last setindex! extraction wall on the fdict root.
runfile("test_qmv7_gc_loaded_memcpy.jl")
# Bennett-u2kk — CW-D: global-src memcpy whose DST is a const-offset GEP off a
# function POINTER-PARAMETER cell (the Dict struct-by-ref param), under
# ptr_cells. Adds `_param_ptr_root_ref` as a THIRD doih-G3 dst-root (after
# alloca / gc_alloc arena); KEEPS G6 cross-width, SKIPS G9 freshness (destructive
# live-field overwrite reversed by BVM's history tape, not by freshness). The
# rehash! root successor wall past xrd6 (clears all 4 param-field-init memcpys;
# next wall: ConstantPointerNull ICmp operand, Bennett-bjdg / U80).
runfile("test_u2kk_param_memcpy.jl")
# Bennett-8g7m — CW-D: pointer-typed `icmp` under the closed-world `ptr_cells`
# gate. Threads ptr_cells to `_operand` (so a `ptr null` operand lowers to the
# zero cell, not the U80 fail-loud) and uses cell width 64 (not the PointerType
# scalar-width wall). Admits ONLY :eq/:ne over pointer cells; the 8 ordering
# predicates FAIL LOUD (address-magnitude compare is BVM-layout-dependent / UB).
# Integer icmp (non-pointer, or ptr_cells=false) is byte-identical. Advances the
# rehash! root PAST the `icmp ne ptr %4, null` U80 wall (u2kk's successor) to the
# `phi i64 [ undef, ... ]` UndefValue / U80 wall.
runfile("test_8g7m_ptr_icmp_cells.jl")
# Bennett-yd4f / U80 — CW-D (ADR 0017): under `ptr_cells` ONLY, an INTEGER
# `undef` in phi-INCOMING position lowers to iconst(0) (dynamically-dead
# don't-care edge; BennettVM resolves phis by the taken predecessor). Every
# other operand position, poison anywhere, non-integer undef, and the circuit
# path (ptr_cells=false) stay byte-identically fail-loud. Advances the rehash!
# root PAST the `phi i64 [ undef, ... ]` U80 wall (8g7m's successor) to the
# `j_AssertionError [1 x ptr]` unsupported-return-type wall (default mode) /
# the `ptrtoint %memory_data` iwo9 wall (suite mode --check-bounds=yes).
runfile("test_yd4f_undef_phi_cells.jl")
# Bennett-583s — CW-D: admit `ptrtoint ptr %memory_data to i64` (the Julia
# GenericMemory `.data` base pointer) as a width-64 cell identity — BUT ONLY
# when confined to a same-Memory base-cancelling bounds check
# (`sub(ptrtoint(P_elem), ptrtoint(P_base))`, both operands tracing to the SAME
# Memory `.data` root). `sub(ptrtoint(base+off), ptrtoint(base)) = off` is
# base-INDEPENDENT → matches the native oracle; any escaping / base-DEPENDENT
# use (inttoptr-deref, store-of-int, hash, cross-allocation diff, width≠64)
# stays FAIL-LOUD. Advances `setindex!`/`ht_keyindex2!`/`rehash!`/`fdict` PAST
# the memory_data ptrtoint wall (suite mode --check-bounds=yes) — the beaw/59zi
# suite disjunctions were updated to the new successor (U114 struct-store /
# AssertionError [1 x ptr] return-type). ptr_cells-gated: circuit path
# byte-identical.
runfile("test_583s_memdata_bounds.jl")
# Bennett-foz5 — CW-D (ADR 0017 §4a, the CONFINED-VALUE contract; xkl frontier
# wall 7). The `_growend!` %idxend41 @boundscheck cluster differences the two
# halves of a SPLIT closure-captured `MemoryRef` — `.ptr_or_offset` inline in
# the closure env, `.mem` hoisted into the GC-roots array — so the two operands
# descend from DIFFERENT function Arguments and 583s's base-cancellation proof
# (which IS syntactic root equality) can never apply. Rather than widen
# `_memdata_root` (measured to STEAL jbko's %L84 witness and regress the chain),
# the 583s arm gains a second USE-SHAPED disjunct: a ptrtoint is admitted as the
# SAME `:or` cell identity when its source is a certified materialised cell and
# its ENTIRE influence is sub(ptrtoint,ptrtoint) → icmp → i1-and/or/xor → a
# conditional br with a utzc-pruned `:__unreachable__` successor. GUARANTEE:
# for every input on which native RETURNS, the extraction returns the same value
# or HALTS LOUDLY. NOT guaranteed (and stated in the ADR, not hidden): the
# native-throws column — the throw may be missed, the halt may be spurious.
# 583s keeps FIRST REFUSAL, `_memdata_root` is untouched, no fall-through is
# introduced (so jbko's pin stays redundant), and NOTHING is fabricated — the
# guard bit is still computed from real in-model cells, which is what
# distinguishes this from the Bennett-lbot placeholder-0 UNSOUND ruling.
# ptr_cells-gated ⇒ circuit path byte-identical. push! now advances to wall 8
# (Bennett-bvmd: the ROOT body's gc_alloc_obj BYTE-granular store target).
runfile("test_foz5_confined_bounds.jl")
# Bennett-utzc / CW-D (ADR 0017 §4) — the keep-branch dead-block pruner. Under
# the closed-world `ptr_cells` gate, a block whose LLVM terminator is
# `unreachable` (a provably-dead Julia throw arm) has its BODY dropped, its own
# label KEPT, and the reserved `IRBranch(nothing, :__unreachable__, nothing)`
# emitted; the predecessor's conditional branch into it is PRESERVED (keep-
# branch → BennettVM's `:__unreachable__` halt sink). This clears the `setindex!`
# U114 `store {ptr,ptr}` (suite mode) and `rehash!` `[1 x ptr] @j_AssertionError`
# (default mode) dead-block extraction walls in one recognizer — advancing the
# fdict set PAST them to the CW-D2 `llvm.smul.with.overflow` / `gc_alloc_obj`
# frontier (bennettvm-416r.12). Two Rule-1 guards: no-live-escape + throw-skeleton
# surprise guard. ptr_cells-gated: default path byte-identical.
runfile("test_utzc_dead_block_pruner.jl")
# Bennett-3vf2 / CW-D — the DEAD-USE DROP, the dual of the utzc pruner above.
# Julia hoists `load ptr, ptr @jl_diverror_exception` into the LIVE predecessor
# of a divisor-validity guard diamond, so the load SURVIVES the pruner even
# though its sole consumer (`ijl_throw` in the `unreachable` arm) does not, and
# hit the bennettvm-416r.13 unrecognised-JIT-global reject. Under `ptr_cells`, a
# non-volatile / non-atomic `load ptr, ptr @GlobalVariable` with >= 1 use, ALL of
# whose uses sit in `dead_blocks`, is now DROPPED (no IRInst, no `.globals`
# entry, no SSA alias; the `names` entry is deleted so a surviving reference
# fails loud in `_operand`). Name-AGNOSTIC by design — soundness is a theorem
# about the pruner, not a Julia naming convention. Advanced the `push!` closure
# frontier to `llvm.memmove` (Bennett-8bys / 37mt), since routed by Bennett-vau9.
runfile("test_3vf2_dead_use_global_load.jl")
# Bennett-lbot / CW-D (ADR 0017) — overflow-arith intrinsics
# (`llvm.{smul,umul,sadd,uadd}.with.overflow.iN`, result `{iN,i1}`) under the
# closed-world `ptr_cells` gate. The `{iN,i1}` aggregate is NEVER modeled (its i1
# field trips the 6bu3 reject); the intrinsic call + its two extractvalues are
# FUSED into scalar IRInsts — extractvalue-0 (product/sum) → IRBinOp, extractvalue-1
# (overflow bit) → iconst(0) ONLY when provably no-overflow (MUL const ∈ {0,1},
# ADD const == 0), else FAIL LOUD. Unblocks fdict `rehash!` (the GenericMemory
# alloc-size check `smul(newsz,1)`). ptr_cells-gated: circuit path byte-identical.
runfile("test_lbot_overflow_intrinsic.jl")
# Bennett-a70z / CW-D (ADR 0017) — EXACT constant-operand overflow bit, the
# successor to lbot's provably-zero-only fuse. When one operand of
# `llvm.{s,u}{mul,add}.with.overflow.iN` is a compile-time ConstantInt `c`, the
# overflow bit is COMPUTED (not walled) as the constant-folded admissible-
# interval membership test `bit = (x < L) | (x > U)` on the dynamic operand —
# ≤ 2 IRICmp + 1 IRBinOp(:or, w=1), bounds from cld/fld in Int128. Both operands
# constant folds to a literal bit; both dynamic still FAILS LOUD. This clears
# the `smul(%value_phi, 8)` elsize-8 wall in `rehash!` and closes extraction of
# the whole `Dict{Int64,Int64}` closed-world set. ptr_cells-gated: circuit path
# byte-identical.
runfile("test_a70z_overflow_const_bit.jl")
# Bennett-8bys / CW-D (ADR 0017) — VARIABLE-size `llvm.memset.p0.i64` under the
# closed-world `ptr_cells` gate. Predicate 5 (non-const N) routes to a bare
# IRCall(:memset,[dst_cell,byte,nbytes],[64,8,64],64) → BVM's reversible
# IntrinsicMemset, instead of the const-N unroll's fail-loud reject. The byte is
# passed RAW (BVM does its own cell-broadcast). Const-N keeps the unroll;
# ptr_cells=false keeps the reject; a VOLATILE variable-N memset still fails loud.
# Unblocks fdict `rehash!` zeroing the fresh Dict.slots Memory (variable length).
# ptr_cells-gated: circuit path byte-identical.
runfile("test_8bys_variable_memset.jl")
# Bennett-vau9 / CW-D (ADR 0017) — the memmove SIBLING of 8bys. Under the
# closed-world `ptr_cells` gate an `llvm.memmove.p0.p0.i64` routes to a bare
# IRCall(:memmove,[dst_cell,src_cell,nbytes],[64,64,64],64) → BVM's overlap-safe
# IntrinsicMemmove (src snapshotted before the dest write; L2 dest-range delta
# reverses it), instead of the unconditional "not yet lowered" reject. Unlike
# memset there is NO legacy const-N unroll, so the WHOLE arm is gated and const-N
# routes too; ptr_cells=false keeps the legacy reject. Volatile / non-p0 /
# malformed-arity / non-SSA-pointer all still fail loud. Unblocks the `_growend!`
# grow-copy (xkl wall 4); the push! set now advances to the iwo9 ptrtoint wall.
runfile("test_vau9_variable_memmove.jl")
# Bennett-jbko / CW-D (ADR 0017) — the `MemoryRef` concurrent-mutation guard
# (`_growend!` %L84, xkl frontier wall 5). Under `ptr_cells` a
# `ptrtoint ptr %p to i64` is admitted as the width-64 cell identity
# IRBinOp(dest,:or,src,iconst(0),64) iff the SOURCE is a certified cell-valued
# pointer SSA (extractvalue of a StructType ptr field / load ptr, addrspace 0,
# 64->64) and EVERY use is an `icmp eq`/`ne` against an in-model value or the
# zero cell. The use gate is what preserves Bennett-8g7m (whose ordering reject
# is TYPE-based, hence launderable through a coercion); the source whitelist is
# what excludes the Bennett-cc0 M2b width-0 `phi`/`select` sentinel. 583s-rooted
# sources stay on the 583s arm. ptr_cells=false ⇒ no arm ⇒ circuit path
# byte-identical. push! advanced to the U114/lgzx `store {ptr,ptr}` wall, which
# Bennett-p06b (below) has since cleared.
runfile("test_jbko_ptr_identity_icmp.jl")
# Bennett-p06b / CW-D (ADR 0017) — the `MemoryRef` write-back whole-aggregate
# store (`_growend!` %L93, xkl frontier wall 6). Under `ptr_cells` a
# `store <S> %agg, ptr %p` with S an unpacked StructType of N 64-bit fields
# decomposes into, per field k, IRExtractValue + IRPtrOffset(offsetof(S,k), 64)
# + IRStore(_, _, 64) — EXACTLY the field-wise spelling the 6bu3 extractvalue
# arm, the ADR 0020 D4 struct-GEP arm and the ares/beaw `store ptr` arm already
# admit, so cell agreement with the read side is a syntactic identity. EIGHT
# predicates fail loud: the LITERAL {i64,ptr} GenericMemory header (byte-granular
# under CW-D4/9n3y); the reused 6bu3 field surface; sub-cell/padded layouts; an
# unregistered target (p06b-named, NOT the lgzx text — the wall markers use that
# bead as a load-bearing negative); a target that is not a CERTIFIED,
# non-SUPPRESSED cell pointer (registration is NOT enough — `alloca {ptr,ptr}`
# emits no IRAlloca, and `julia.gc_alloc_obj` is BYTE-granular in BVM); a target
# without a CERTIFIED >= N-cell reservation; a target with a
# CONFLICTING-granularity use, scanned across sibling re-loads under a canonical
# slot key; and a value whose `insertvalue` CHAIN ROOT is not a constant
# aggregate (BVM's `agg_dests` contract). Residual, disclosed not closed:
# `:load` targets have no static capacity proof (Bennett-khb2).
# ptr_cells=false ⇒ no arm ⇒ the lgzx/U114 reject byte-identical. push! then
# advanced to the %idxend41 Bennett-583s ptrtoint wall (wall 7), which
# Bennett-foz5 (above) has since cleared; the wall is now in the ROOT body
# (wall 8, Bennett-bvmd) — which is why this file's own marker gate no longer
# expects `_growend!` in the message.
runfile("test_p06b_aggregate_store.jl")
# Bennett-bvmd (xkl frontier wall 8): ROOT-SCALE COHERENCE (SC) — the
# bytes-per-cell ratio BennettVM's `_alloc_cells` already fixes per allocator,
# read (never invented) by the extractor and enforced BOTH by a shared stamp at
# the sites that choose an `elem_width` and by a stream check over every emitted
# IRPtrOffset/IRVarGEP. Clears wall 8 (byte-stamped `julia.gc_alloc_obj`
# aggregate stores), closes the CW-D4 class-D split, `Bennett-z2ia` (static
# case, by use-directed byte-normalisation) and `Bennett-4y0d`.
runfile("test_bvmd_root_scale.jl")
# Bennett-sy29 (xkl frontier wall 9): a `julia.gc_alloc_obj` ARENA root on
# EITHER SIDE of a const-size, cell-aligned `llvm.memcpy` under `ptr_cells`.
# The mirror of the vbv9 arena-dst arm, carrying the Bennett-4y0d address/value
# stamp split PER SIDE (byte-tier src stamped 8, word-tier dst stamped 64, value
# width 64 on both). Generalises Predicate 7 from "same alloca" to "same root"
# — route R1 never emits an `IntrinsicMemcpy`, so that guard REPLACES BVM's
# runtime overlap check. Clears wall 9; the set walls at wall 10 (the
# `%memory_data3` ptrtoint whose difference escapes via `udiv exact`).
runfile("test_sy29_arena_src_memcpy.jl")
# Bennett-57hd (ADR 0017 §4b) — the VALUE-IDENTITY contract, the THIRD
# admission contract and the STRONGEST of the three: the two coerced pointers
# are PROVED to be copies of one value, so the difference is identically 0
# under ANY address representation and may escape freely (into a live branch,
# an allocation size, a memmove length). Clears wall 10; the set walls at wall
# 11 (the `.mem` memcpy SRC, Bennett-37mt / Bennett-8bys).
runfile("test_57hd_value_identity.jl")
# Bennett-jfw6: mem=:vm Case A Vector/GenericMemory extraction recognizer (shape + fail-loud matrix).
runfile("test_jfw6_vec_vm_extract.jl")
# Bennett-g27k / U18 — cc0.3 catch narrowed: exception type + message
# + non-Bennett-authored guard (was: bare substring match that could
# swallow unrelated Bennett fail-loud errors).
runfile("test_g27k_cc03_catch_narrow.jl")
# Bennett-6fg9 / U19 — simulate arity + per-input bit-width guard (was:
# silent drop of extra tuple elements, silent wrap of over-wide values).
runfile("test_6fg9_simulate_arity.jl")
# Bennett-hmn0 / U20 — HAMT 9th-distinct-hash-slot overflow guard.
# Gated behind BENNETT_RESEARCH_TESTS as of U54 cycle 4 (HAMT relocated).
# include("test_hmn0_hamt_overflow.jl")  # → moved into research gate below
# Bennett-n3z4 / U21 — cf_reroot was-allocated flag fix.  Gated behind
# BENNETT_RESEARCH_TESTS as of U54 cycle 2 (CF relocated to research/).
# include("test_n3z4_cf_reroot_key_zero.jl")  # → moved into research gate below
# Bennett-sqtd / U22 — soft_feistel_int8 is NOT a bijection (was claimed
# to be); docstring + comment corrected, exact image size (207/256)
# pinned as a regression baseline.
runfile("test_sqtd_feistel_not_bijection.jl")
# Bennett-swee / U24 — WireAllocator rejects negative n and double-free.
runfile("test_swee_wire_allocator_negative.jl")
# Bennett-k0bg / U25 — reversible_compile validates bit_width,
# max_loop_iterations, and arg_types up-front.
runfile("test_k0bg_compile_validation.jl")
# Bennett-7stg / U26 — register_callee! / _lookup_callee wrapped in a
# ReentrantLock for safe concurrent use.
runfile("test_7stg_register_callee_locking.jl")
# Bennett-epwy / U28 — fold_constants default flipped to true; strictly
# safe pass, strictly cheaper circuit.
runfile("test_epwy_fold_constants_default.jl")
# Bennett-b1vp / U31 — soft_fptoui + LLVMFPToUI dispatch (was previously
# silently routed through the signed soft_fptosi).
runfile("test_b1vp_fptoui.jl")
# Bennett-xlsz / U29 — unify reversible_compile kwargs across the three
# overloads; unknown kwargs raise ArgumentError with the supported set.
runfile("test_xlsz_kwargs_unified.jl")
# Bennett-4fri / U30 — mul dispatcher `target=:depth` promotes `:auto`
# to `qcla_tree` (O(log² n) Toffoli-depth).
runfile("test_4fri_mul_target.jl")
# Bennett-spa8 / U27 — add dispatcher `:auto` → `:ripple` (Cuccaro
# is strictly worse post-Bennett copy-out at every measured width).
runfile("test_spa8_add_auto_ripple.jl")
# Bennett-6azb / U58 — simulator verifies input-preservation
# invariant; ReversibleCircuit asserts input/output/ancilla partition.
runfile("test_6azb_input_preservation.jl")
# Bennett-mlny / U63 — `depth` was exported + documented but never tested.
# Pins the basic shapes (empty=0, sequential=N, parallel=1, mixed) +
# regression-anchors the depth=19 number documented in the diagnostics
# docstring for `x -> x + Int8(1)` on Int8.
runfile("test_mlny_depth.jl")
# Bennett-6l2h / U67 + Bennett-xmdx / U66 — branching-callee coverage:
# `lower_call!` compact=true and `controlled(circuit)` were both untested
# on callees with internal branching.  Exhaustive Int8 sweep (abs +
# piecewise) under compact_calls=true and under controlled wrapping with
# ctrl=0/1.  Closes both beads as gap fills.
runfile("test_6l2h_branching_callee.jl")
# Bennett-T5-P5a/P5b — multi-language ingest (`.ll` / `.bc`).
runfile("test_p5a_ll_ingest.jl")
runfile("test_p5a_equivalence.jl")
runfile("test_p5b_bc_ingest.jl")
runfile("test_p5_fail_loud.jl")

# T5 — persistent map protocol + harness self-test (T5-P3a, GREEN today).
runfile("test_persistent_interface.jl")
# Bennett-uoem / U54 — relocation invariants for src/persistent/research/.
# Runs unconditionally; research-tier impls themselves are gated below.
runfile("test_uoem_research_relocation.jl")
# Bennett-ve3m / U165 — peak_live_wires line in print_circuit summary.
runfile("test_ve3m_show_peak_live_wires.jl")
# Bennett-ivoa / U121 + Bennett-e89s / U120 — harness persistence/key=0
# invariants and absent-vs-stored-zero collision contract pin.
runfile("test_ivoa_harness_invariants.jl")
# Bennett-m63k / U60 — strict-bits NaN coverage replacing isnan()-only
# checks (post-U08).  Caught a real bug in soft_fsub's NaN-RHS sign
# propagation; fix shipped in src/softfloat/fsub.jl in the same commit.
runfile("test_m63k_softfloat_strict_bits.jl")
# Bennett-9x75 / U61 — raw-bits fuzz across the full UInt64 input space
# for fadd/fsub/fmul/fdiv/fma/fsqrt (5000 each, ~30k strict-bit asserts).
runfile("test_9x75_softfloat_raw_bits_sweep.jl")
# Bennett-0zsk / U46 — pin the load-bearing error() paths in lower.jl
# and ir_extract.jl with @test_throws (12 testsets / 15 asserts).
runfile("test_0zsk_core_error_paths.jl")
# Bennett-ej4n / U48 — module-scoped ParsedIR cache so a circuit with N
# references to the same callee pays the ~21ms extract_parsed_ir cost once.
runfile("test_ej4n_callee_ir_cache.jl")
# Bennett-tfo8 / U113 — single-source-of-truth alloca-MUX strategy tables;
# pins consistency between _MUX_EXCH_STRATEGY and the load/store dispatch
# dicts so a future shape addition can't silently route to :unsupported.
runfile("test_tfo8_alloca_strategy_tables.jl")
# Bennett-2jny / U101 — ReversibleCircuit collection protocols
# (length / iterate / eltype / getindex / first/lastindex).
runfile("test_2jny_circuit_collection_api.jl")
# Bennett-kmuj / U106 — register_callee! registry grouped into per-domain
# tuples; pins disjointness + every grouped callee really gets registered.
runfile("test_kmuj_callee_groups.jl")
# Bennett-uinn / U93 — every defensive try/catch in src/ir_extract.jl
# narrows on InterruptException so Ctrl-C during compilation propagates.
runfile("test_uinn_catch_narrowing.jl")
# Bennett-069e / U143 — named DP sentinels in pebbling.jl
# (_PEBBLE_INF / _PEBBLE_FINITE_BOUND) replacing typemax(Int)÷2 magic;
# pins the no-overflow + init-sentinel-fails-gate invariants.
runfile("test_069e_pebble_sentinels.jl")
# Bennett-k7al / U99 — IR struct inner constructors validate op symbols
# (_IR_BINOP_OPS / _IR_ICMP_PREDS / _IR_CAST_OPS / _IR_OPERAND_KINDS),
# require width >= 1, and check IRCall arity / IRPhi non-empty incoming.
runfile("test_k7al_ir_constructor_asserts.jl")
# Bennett-pksz / U98 — `controlled(c)` asserts every inner gate uses
# wires in 1:c.n_wires before allocating ctrl_wire at n_wires+1.
runfile("test_pksz_controlled_contiguous_wires.jl")
# Bennett-zyjn / U94 — _get_deref_bytes errors loudly on caller-side
# bugs (param not in func, malformed defline) instead of silently
# returning 0; only the legitimate "no deref attr" case returns 0.
runfile("test_zyjn_deref_bytes_distinct_failures.jl")
# Bennett-8kno / U95 — _extract_const_globals narrows the LLVM.initializer
# catch to LLVM.jl's "Unknown value kind" / "LLVMGlobalAlias" errors only;
# OOM and other unexpected exceptions propagate.
runfile("test_8kno_extract_const_globals_narrowing.jl")
# Bennett-f6qa / U97 — every error("...") in lower.jl starts with a
# recognised function-or-helper prefix; pebbling/pebbled_groups budget
# wording unified to "insufficient pebbles — need at least N".
runfile("test_f6qa_error_message_prefixes.jl")
# Bennett-srsy / U103 — multi-language fixture toolchain guards: the
# rust/c/p5b corpora hard-fail under BENNETT_CI=1 (vs silent skip
# locally) when rustc / clang / llvm-as are missing.
runfile("test_srsy_ci_toolchain_guard.jl")
# Bennett-8p0g / U147 — hand-built ParsedIR seam test that exercises
# lower → bennett → simulate directly, bypassing LLVM extraction.
# Covers IRBinOp (add, xor), IRICmp, IRCast (zext), IRRet on minimal
# fixtures so lowering can be unit-tested independent of LLVM IR shape.
runfile("test_8p0g_parsed_ir_seam.jl")
# Bennett-wlf6 / U145 — public API docstrings carry ```jldoctest fences
# (executable doctests once Documenter.jl is wired). Static-inspection
# test that asserts the fences haven't reverted + smoke-checks that
# every doctest's expected value still holds in the canonical baseline.
runfile("test_wlf6_jldoctest_fences.jl")
# Bennett-doh6 / U158 — docs/make.jl scaffold present + executable
# doctest wiring for the wlf6 jldoctest fences. Static-inspection only;
# the actual doctest execution lives in `julia --project=docs docs/make.jl`
# per CLAUDE.md §14 (no GitHub CI).
runfile("test_doh6_docs_makejl.jl")
# Bennett-5qrn / U57 — trivial-identity peepholes (x+0, x*1, x|0, x⊕0,
# x-0, x*0, x&0, x&allones, x|allones, x⊕allones and commutative duals).
# Catches at the lower_binop! dispatcher BEFORE resolve! materialises the
# constant operand into ancilla wires. Reduces x*Int8(1) from 692 → 26
# gates (26.6× reduction at fold_constants=false). Pinned formulas:
# copy-out 3W+2, zero-result W+2.
runfile("test_5qrn_identity_peepholes.jl")
# Bennett-heup / U127 — _fold_constants contract pin (default-true at every
# entry point, per-arm dispatch witnesses, self_reversing short-circuit,
# reduction baselines). Investigated → doc-only: bead claims "off-by-default"
# and "mixes three concerns" both stale post-epwy / U28.
runfile("test_heup_fold_constants_contract.jl")
# Bennett-4bcp / U102 — actionable error for NTuple-typed arg ambiguity.
# `reversible_compile(f, NTuple{2,Int8})` interprets NTuple as 2-arg
# tuple; if f takes a single tuple arg, point at the `Tuple{NTuple}` wrap.
runfile("test_4bcp_ntuple_input_error.jl")
# Bennett-fehu / U105 — simulate!(buffer, circuit, inputs) in-place variant.
# Hot-loop callers preallocate a Vector{Bool} once and reuse it across
# many simulate calls.
runfile("test_fehu_simulate_inplace.jl")
# Bennett-2hhx / U136 — soft_round (IEEE 754 roundToIntegralTiesToEven).
# Bit-exact vs Base.round(::Float64): ties-to-even, subnormals, ±Inf, NaN
# (with quiet-bit), boundary at 2^52, plus 5,000-sample raw-bits sweep.
runfile("test_2hhx_soft_round.jl")
# Bennett-is5s / U131 — diagnose_nonzero(circuit, inputs) helper for
# bisecting Bennett-invariant violations (returns all violations
# without throwing). Subset of is5s; --dump-ir / verbose deferred.
runfile("test_is5s_diagnose_nonzero.jl")
# Bennett-jc0y / 59jj-cut — ReversibleCircuit.gates storage contract pin.
# Investigated → doc-only: bead claims "type-unstable apply! per gate" stale
# (Julia union-splits NOT/CNOT/Toffoli inside _simulate's hot loop); memory
# savings real but ~26% with 24+ site blast radius. Refactor deferred until
# a real workload OOMs; this file pins empirical baselines.
runfile("test_jc0y_gate_storage_contract.jl")
# Bennett-q04a / 59jj-cut — _convert_instruction Union-return contract.
# Investigated → doc-only: 18-arm Union return is real, but extraction
# is one-shot per compile (~5% of extract cost) — refactor blast radius
# (function body + caller dispatch) out of proportion. Pin IRInst
# subtype count, Union arm bound, caller dispatch shape, extraction
# allocation linearity.
runfile("test_q04a_convert_instruction_contract.jl")
# Bennett-cvnb / Sturm.jl-ao1 — bennett_direct convenience wrapper that
# asserts self_reversing=true and errors loud otherwise. Surfaces the
# existing fast path (bennett_transform.jl:101-105) for downstream
# library authors. README "Pre-reversed primitives" callout updated.
runfile("test_cvnb_bennett_direct.jl")
# Bennett-qcso / U59 — compose(c1, c2) pipeline composition. Implements
# c1.gates ++ renumbered(c2.gates) ++ reverse(c1.gates) with c2's input
# wires positionally aliased onto c1's output wires. Self-reversing
# inputs rejected (MVP). Unblocks Sturm `when(q) do f(x) end` (review
# F49/F50 — composition was UNCOVERED).
runfile("test_qcso_compose.jl")
# Bennett-zmw3 / U111 — robustness bounds: resolve!() mask at W=64 no
# longer relies on Julia shift saturation; constant-shift path now
# rejects k < 0 and k > W with a clear error; variable-shift mod-W
# semantics documented (Julia frontend OK; raw LLVM input gets mod-W
# instead of poison).
runfile("test_zmw3_shift_bounds.jl")
# Bennett-6u9q / U146 — end-to-end integration test for the stated
# vision: `controlled ∘ reversible_compile` is a unitary on a 2^N
# statevector. Compiles a tiny Bool→Bool function, controls it, applies
# the resulting circuit to (a) basis states, (b) a random superposition
# (norm preserved), and (c) the canonical |0⟩+|1⟩ superposition that
# Sturm's `when(qubit) do f(x) end` would lower into.
runfile("test_6u9q_quantum_vision_integration.jl")
# Bennett-5kio / U109 — sizehint! before push! loops in adder.jl,
# multiplier.jl, qcla.jl avoids O(log₂N) intermediate-vector
# reallocations on multi-thousand-gate paths. Pin the static presence
# of the hints + the canonical gate-count baselines (no behavioural
# drift).
runfile("test_5kio_sizehint_arithmetic.jl")
# Bennett-op6a / U140 — pin the actual lower_add_cuccaro! gate counts
# (Toffoli=2W−2, CNOT=4W−2, NOT=0) at W∈{2,3,4,8,16,32,64}; the docstring
# now matches the implementation (was advertising the carry-out
# variant's 2n/5n/2n).
runfile("test_op6a_cuccaro_gate_count.jl")
# Bennett-b2fs / U148 — `_unpack_args` in tabulate.jl returns a Tuple
# (stack-allocated, concretely-typed) instead of the previous
# Vector{Any} (per-row heap allocation + boxed elements). Pins the
# return type + end-to-end tabulate correctness.
runfile("test_b2fs_tabulate_tuple_unpack.jl")
# Bennett-ardf / U138 — soft_floor / soft_ceil / soft_trunc bit-exact
# NaN propagation against Base.floor/ceil/trunc; soft_fdiv's dead
# `_overflow_result` binding replaced with `_`.
runfile("test_ardf_floor_ceil_nan.jl")
# Bennett-jepw / U05-followup — diamond-in-body phi resolution
# (per-iteration LOCAL block_pred / branch_info / preds dicts inside
# lower_loop! + top-level loop_body_labels skip).
runfile("test_jepw_diamond_in_body.jl")
# Bennett-59jj / U47 (cut) — typed `simulate(c, ::Type{T}, inputs)::T`
# overload eliminates the 9-arm Union return type for hot loops.
runfile("test_59jj_typed_simulate.jl")
# Bennett-p94b / U110 — defensive asserts in `_compute_block_pred!`
# (distinct predecessors + width-1 block_pred) and `_edge_predicate!`
# (width-1 block_pred). Catches the false-path-sensitisation precondition.
runfile("test_p94b_predicate_asserts.jl")
# Bennett-fq8n / U84 — lower_phi! validates that every incoming SSA
# wire-vector has length == phi.width. resolve! doesn't enforce this.
runfile("test_fq8n_phi_mixed_widths.jl")
# Bennett-lgzx / U114 — `_convert_instruction` no longer silently drops
# stores of non-integer types or stores whose target pointer isn't a
# registered SSA name. Errors loudly per CLAUDE.md §1.
runfile("test_lgzx_store_fail_loud.jl")
# Bennett-ibz5 / U96 — `resolve!` trip-wires the OPAQUE_PTR_SENTINEL
# by name so the value=0 placeholder for unresolvable pointers does
# not silently materialise as the integer 0.
runfile("test_ibz5_opaque_ptr_sentinel.jl")
# Bennett-t3j0 / U83 — `_expand_switches` rejects input blocks whose
# labels collide with the reserved synthetic-block prefix `_sw_*` or
# the `:__unreachable__` unreachable-target sentinel.
runfile("test_t3j0_switch_label_collision.jl")
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
runfile("test_hashcons_feistel.jl")
# Bennett-z2dj — T5-P6 `:persistent_tree` dispatcher arm. RED test (Step 1):
# every testset is expected to FAIL until Steps 2-9 of `docs/design/p6_consensus.md`
# §5 land. Safe to include unconditionally — `@test_throws` / `@test` failures
# are the explicit RED contract.
runfile("test_t5_p6_persistent_dispatch.jl")
# Bennett-6883 — :okasaki persistent_impl dispatcher arm (2026-05-18).
# Mirrors test_t5_p6_persistent_dispatch.jl testset 2 (3-key roundtrip)
# but routes through Bennett.okasaki_pmap_* and persistent_impl=:okasaki.
runfile("test_6883_okasaki_dispatch.jl")
# Bennett-d746 — :hamt persistent_impl dispatcher arm (2026-05-20).
# Byte-template duplicate of test_6883_okasaki_dispatch.jl; routes
# through Bennett.hamt_pmap_* and persistent_impl=:hamt.
runfile("test_6883_hamt_dispatch.jl")
# Bennett-qi6c — :cf persistent_impl dispatcher arm (2026-05-20).
# Byte-template duplicate of test_6883_okasaki_dispatch.jl; routes
# through Bennett.cf_pmap_* and persistent_impl=:cf. Last of the four
# persistent_impl candidates to be wired.
runfile("test_6883_cf_dispatch.jl")

# T5 corpora — multi-language RED tests (T5-P2a/b/c).  All currently RED
# via @test_throws; safe to include unconditionally.  C and Rust corpora
# self-skip if clang/rustc not on PATH.  Set BENNETT_T5_TESTS=0 to skip all.
if get(ENV, "BENNETT_T5_TESTS", "1") != "0"
    runfile("test_t5_corpus_julia.jl")
    runfile("test_t5_corpus_c.jl")
    runfile("test_t5_corpus_rust.jl")
end

# Bennett-uoem / U54 — preserved-but-deprecated persistent-map impls
# (CF, Okasaki, HAMT+popcount, Jenkins) live under src/persistent/research/
# and are not loaded by `using Bennett`.  Their tests are opt-in via
# BENNETT_RESEARCH_TESTS=1 (default off — research code, not on hot path).
# See src/persistent/research/README.md for the literate deprecation
# rationale and thaw conditions.
if get(ENV, "BENNETT_RESEARCH_TESTS", "0") != "0"
    # T5-P3b — Okasaki RBT persistent map (relocated 2026-04-25 / U54).
    runfile("test_persistent_okasaki.jl")
    # T5-P3d — Conchon-Filliâtre semi-persistent (relocated 2026-04-25 / U54).
    runfile("test_persistent_cf.jl")
    # Bennett-n3z4 / U21 — CF reroot key=0 regression (rides with CF).
    runfile("test_n3z4_cf_reroot_key_zero.jl")
    # T5-P3c — Bagwell HAMT + popcount (relocated 2026-04-25 / U54).
    runfile("test_persistent_hamt.jl")
    # Bennett-hmn0 / U20 — HAMT 9th-distinct-hash overflow regression.
    runfile("test_hmn0_hamt_overflow.jl")
    # T5-P4 — Hash-cons layered demos.  Cycle 5 will split the Feistel-only
    # standalone coverage back to the default path; for now the whole file
    # rides under the research gate because 6/6 layered demos and the
    # Jenkins standalone test all touch research-tier impls.
    runfile("test_persistent_hashcons.jl")
end

# Bennett-8403 / U159: per-source-file unit test homes for the catalogue-
# named files (Bennett.jl / lower.jl / ir_extract.jl). Other src/X.jl ↔
# test/test_X.jl mappings are documented in test/PER_SOURCE_INDEX.md.
runfile("test_bennett.jl")
runfile("test_lower.jl")
runfile("test_ir_extract.jl")

# Bennett-gps7 / M1: Julia heap-memory support — GC/heap-skeleton recogniser.
runfile("test_gps7_heap_m1.jl")

# Bennett-kuza / M2: Julia heap-memory support — Array{T}(undef,N) re-rooting.
runfile("test_kuza_heap_m2.jl")

# Bennett-5ikt / M3: Julia heap-memory support — push!-built Vector, static count.
runfile("test_5ikt_heap_m3.jl")

# Bennett-bd5f / M4: Julia heap-memory support — fail-loud scope hardening.
runfile("test_bd5f_heap_m4.jl")

# Bennett-fidj / U217: liveness × :auto add dispatcher coverage.
runfile("test_fidj_liveness_auto_dispatcher.jl")

# Bennett-33zr / BennettVM ADR 0003: target=:reversible_vm dispatch arm.
runfile("test_reversible_vm_dispatch.jl")

# Bennett-gk1h / U210: package hygiene gates (Aqua.jl + JET.jl).
runfile("test_hygiene_aqua_jet.jl")

end  # @testset "Bennett"  (Bennett-zy4u / U104)
