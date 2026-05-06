# ---- Bennett-iwv5 / U90: pure-integer IEEE 754 binary64 primitives ----
#
# Wrapped in `module SoftFloatLib` so the ~75 internal helpers
# (_add128, _sub128, _shiftRightJam128, _sf_round_and_pack, _EXP_TAB, …)
# and bit-pattern constants (EXP_MASK, FRAC_MASK, IMPLICIT, INDEF, QNAN,
# QUIET_BIT, INF_BITS) do NOT leak into Bennett's top-level namespace.
#
# Module name is `SoftFloatLib` rather than `SoftFloat` to avoid a clash
# with the user-facing wrapper struct `SoftFloat` defined in
# src/softfloat_dispatch.jl. Bennett.jl re-exports the public surface
# below via `using .SoftFloatLib`.

module SoftFloatLib

include("softfloat_common.jl")
include("fneg.jl")
include("fadd.jl")
include("fsub.jl")
include("fmul.jl")
include("fma.jl")
include("fcmp.jl")
include("fdiv.jl")
include("fsqrt.jl")
include("fexp.jl")
include("fexp_julia.jl")
include("flog.jl")
include("fpow.jl")
include("fpow_julia.jl")
include("fsin.jl")
include("ftan.jl")
include("fatan.jl")
include("fatan2.jl")
include("fasin.jl")
include("facos.jl")
include("ftanh.jl")
include("fsinh.jl")
include("fcosh.jl")
include("fasinh.jl")
include("facosh.jl")
include("fpconv.jl")
include("fptosi.jl")
include("fptoui.jl")
include("sitofp.jl")
include("fround.jl")

# Public surface: 32 IEEE-754 primitives. Internal helpers and bit-pattern
# constants are module-private (no `export`) — leak-free under
# `using .SoftFloatLib`.
export soft_fadd, soft_fsub, soft_fmul, soft_fma, soft_fdiv, soft_fsqrt,
       soft_fneg,
       soft_fcmp_oeq, soft_fcmp_olt, soft_fcmp_ole, soft_fcmp_one,
       soft_fcmp_ord, soft_fcmp_ueq, soft_fcmp_ult, soft_fcmp_ule,
       soft_fcmp_une, soft_fcmp_uno,
       soft_fpext, soft_fptrunc, soft_fptosi, soft_fptoui, soft_sitofp,
       soft_round, soft_floor, soft_ceil, soft_trunc,
       soft_exp, soft_exp2, soft_exp_fast, soft_exp2_fast,
       soft_exp_julia, soft_exp2_julia,
       soft_log, soft_log2, soft_log10,
       soft_pow, soft_powi, soft_pow_julia,
       soft_sin, soft_cos, soft_tan,
       soft_atan, soft_atan2, soft_asin, soft_acos,
       soft_tanh, soft_sinh, soft_cosh, soft_asinh, soft_acosh

end # module SoftFloatLib
