# Triage — B-softfloat — 2026-09-26

Orchestrator triage of `B-softfloat.md` after independent re-execution of F1–F9 (`B-softfloat.verification.md`:
9/9 CONFIRMED, severities agreed; F3/F9 are S0 only because NaN payload bits are contractual per r84x/m63k).
All eleven findings are NEW (no overlap with other reports or open beads).

| Finding | Sev | Bead |
|---|---|---|
| F1 fsin.jl INV_2PI limb 12 transcription slip; sin/cos/tan garbage for |x| in [2^682,2^820) | S0 | Bennett-6gxm (P1) |
| F8 exp/exp2/expm1 NaN in the top of the last reduction cell; sinh/cosh NaN not ±Inf near 1419.56 | S0 | Bennett-uwv2 (P1) |
| F5 soft_pow(-1,y) returns +1; test pins the wrong value (llvm.pow ingest path) | S0 | Bennett-iys2 (P2) |
| F2 mixed SoftFloat/Float64 == falls to Base → branch folded away, silent miscompile | S0 | Bennett-g6u9 (P1) |
| F3 soft_fmin/fmax drop NaN sign+payload; contradicts closed k2w6 | S0 (payload) | Bennett-4qgq (P2) |
| F9 soft_pow_julia loses negative-NaN payload/sign | S0 (payload) | Bennett-ke9x (P3) |
| F6 Float64 ^ cannot compile: j__pj_pow_body_int_* unregistered | S1 | Bennett-bie9 (P2) |
| F4 missing SoftFloat dispatch: x^2, fma, mixed <, isnan, isfinite, mixed min | S1 | Bennett-8aes (P2) |
| F7 Float64 overload rejects constant / Bool / Integer results (always .bits) | S1 | Bennett-lgwa (P2) |
| F10 soft_pow tests skip subnormal-output binades | S2 | Bennett-cpxk (P3) |
| F11 soft_pow accuracy claim vs 14-ulp discrepancy | S2 | Bennett-5mt5 (P3) |

All beads carry label `astra-2026-09-26` and `discovered-from:Bennett-yjd5`.
