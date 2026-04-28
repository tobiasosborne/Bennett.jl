# ---- Soft-float / memory callee registration (Bennett-19g6 extracted from Bennett.jl) ----
#
# Bennett-kmuj / U106: callees are grouped by domain into named tuples
# so the registration loop is one declarative pass instead of 45 ad-hoc
# `register_callee!` lines. Adding a new callee = append it to the
# matching group; the loop registers it on module load.

# Integer division / remainder (called by `lower_binop!` for udiv/sdiv/urem/srem).
# Per Bennett-salb / U119, the registered callees are the throw-free `_compile`
# variants — the public `soft_udiv` / `soft_urem` raise DivideError on b=0,
# which would emit an external @ijl_throw that lower_call! cannot extract.
const _CALLEES_INTEGER_DIV = (
    _soft_udiv_compile, _soft_urem_compile,
)

# IEEE 754 binary 64-bit arithmetic.
const _CALLEES_FP_BINARY = (
    soft_fadd, soft_fsub, soft_fmul, soft_fdiv, soft_fma,
)

# IEEE 754 unary / sqrt (sign flip + square root).
const _CALLEES_FP_UNARY = (
    soft_fneg, soft_fsqrt,
)

# IEEE 754 rounding to integral (no precision loss; result still binary64).
const _CALLEES_FP_ROUND = (
    soft_floor, soft_ceil, soft_trunc, soft_round,
)

# IEEE 754 comparison (returns i1). Bennett-d77b / U132: 6 new primitives
# (ord, uno, one, ueq, ult, ule) complete the LLVM fcmp predicate table.
# Combined with operand-swap dispatch in ir_extract.jl for ogt/oge/ugt/uge,
# every LLVM fcmp predicate routes to a callee.
const _CALLEES_FP_CMP = (
    soft_fcmp_olt, soft_fcmp_oeq, soft_fcmp_ole, soft_fcmp_une,
    soft_fcmp_ord, soft_fcmp_uno, soft_fcmp_one,
    soft_fcmp_ueq, soft_fcmp_ult, soft_fcmp_ule,
)

# IEEE 754 width / signedness conversions.
const _CALLEES_FP_CONV = (
    soft_fpext, soft_fptrunc, soft_fptosi, soft_fptoui, soft_sitofp,
)

# IEEE 754 transcendentals (musl-derived branchless + Julia-idiom variants).
const _CALLEES_FP_TRANS = (
    soft_exp, soft_exp2,
    soft_exp_fast, soft_exp2_fast,
    soft_exp_julia, soft_exp2_julia,
)

# Reversible mutable memory — MUX EXCH load/store (Bennett-cc0 M1, N·W ≤ 64).
# Hand-written (4,8)/(8,8) plus @eval-generated (2,8)/(2,16)/(4,16)/(2,32).
const _CALLEES_MUX_EXCH = (
    soft_mux_load_2x8,  soft_mux_store_2x8,
    soft_mux_load_4x8,  soft_mux_store_4x8,
    soft_mux_load_8x8,  soft_mux_store_8x8,
    soft_mux_load_2x16, soft_mux_store_2x16,
    soft_mux_load_4x16, soft_mux_store_4x16,
    soft_mux_load_2x32, soft_mux_store_2x32,
)

# Reversible mutable memory — path-predicate-guarded MUX stores
# (Bennett-cc0 M2d / bucket C3) for stores in non-entry blocks.
const _CALLEES_MUX_EXCH_GUARDED = (
    soft_mux_store_guarded_2x8,
    soft_mux_store_guarded_4x8,
    soft_mux_store_guarded_8x8,
    soft_mux_store_guarded_2x16,
    soft_mux_store_guarded_4x16,
    soft_mux_store_guarded_2x32,
)

# Single source of truth: every group above is registered exactly once.
const _CALLEE_GROUPS = (
    _CALLEES_INTEGER_DIV,
    _CALLEES_FP_BINARY, _CALLEES_FP_UNARY, _CALLEES_FP_ROUND,
    _CALLEES_FP_CMP, _CALLEES_FP_CONV, _CALLEES_FP_TRANS,
    _CALLEES_MUX_EXCH, _CALLEES_MUX_EXCH_GUARDED,
)

for group in _CALLEE_GROUPS, f in group
    register_callee!(f)
end
