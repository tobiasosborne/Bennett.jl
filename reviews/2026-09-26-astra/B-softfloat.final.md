**11 confirmed findings: six S0, three S1, two S2; all verified by execution.**

A mistyped table limb corrupts large-argument sin/cos/tan. Missing overflow reconstruction propagates NaNs into expm1/sinh/cosh. Other silent errors affect powers, mixed equality, and NaN payloads.

Core arithmetic passed 1.8 million raw-bit comparisons. All 60 primitive IRs contained no native floating arithmetic; QROM passed exhaustive lookup checks. Existing exp/trig/pow tests remain green despite the defects.

- **F1 [S0]** Large arguments produce wrong sin/cos/tan.
- **F8 [S0]** exp/exp2 overflow handling produces NaNs.
- **F5 [S0]** `soft_pow` returns +1 for every exponent of −1.
- **F2 [S0]** Mixed SoftFloat equality silently miscompiles branches.
- **F3 [S0]** Public min/max discard NaN sign and payload.
- **F9 [S0]** Julia power loses negative-NaN payloads.
- **F6 [S1]** Julia power cannot compile: helper unregistered.
- **F4 [S1]** Common Float64 expressions lack dispatch methods.
- **F7 [S1]** Float64 compilation rejects constant Float64 returns.
- **F10 [S2]** Power tests skip most subnormal-output binades.
- **F11 [S2]** Power’s accuracy claim contradicts a verified 14-ULP discrepancy.