# B-softfloat — independent verification (F1–F9)

Verifier: independent re-execution, 2026-09-26. Julia 1.12.3,
`julia --project --check-bounds=yes --startup-file=no --compiled-modules=existing`.
Probe scripts lived in the session scratchpad (not committed). No src/test/bd/git mutation.
Float comparisons are raw `reinterpret(UInt64, ·)` bit patterns. "ulps" = distance in the
sign-magnitude ordinal (a sign flip therefore reads as ~9e18).

## Summary

| F# | Verdict | Severity ok? | Dedup | Note |
|----|---------|--------------|-------|------|
| F1 | CONFIRMED | S0 yes | NEW (3mo introduced it; l5v8 only dispatch) | `fsin.jl:114` limb 12 `0xc7fe25ffff781660` ≠ BigFloat/`Base.Math.INV_2PI[12]` `0xc7fe25fff7816603` (other 18 limbs match). Garbage sin/cos/tan for |x| ∈ [2^682, 2^820) (~1.6e205–6.7e246), incl. sign flips; patched in memory → 0 failures (max 1 ulp). Tests cap at 1e22 ≈ 2^73. |
| F8 | CONFIRMED | S0 yes | ky5n (closed) noted it as "drive-by", worked around, never filed; no open bead → NEW bead | exp NaN for x ∈ [709.78000862, 709.78271289] (top half-cell below log(floatmax)); exp2 NaN for [1023.99609, 1024); expm1 same window; sinh/cosh NaN (not ±Inf) at |x| ∈ [1419.5600, 1419.5654]. `soft_exp_julia`/`exp2_julia` correct. Neither fnxg sweep nor a 0.25-step overflow sweep would catch it. |
| F5 | CONFIRMED | S0 yes (reach: `llvm.pow.f64` ingest + direct `soft_pow`; Julia `^` uses `soft_pow_julia`, which is correct) | NEW | `soft_pow(-1, y)` = +1 for y=1,3,−3,0.5,NaN; libm gives −1,−1,−1,NaN,NaN. `test_softfpow.jl:85–89` asserts the wrong answer. |
| F2 | CONFIRMED | S0 yes | NEW | `SoftFloat(0.0)==0.0` → `false` via Base `==(x,y)` fallback (`===`). `x==0.0 ? x+1.0 : x` compiles to a 66-gate identity (1 block), `simulate(c,bits(0.0))=0x0000…` vs native `0x3ff0…`; `verify_reversibility` true. |
| F3 | CONFIRMED | S0 by letter (bit contract per r84x/m63k); practical impact NaN-payload only — triager may downgrade | k2w6 closed (claims bit-exact) → NEW bead, cite k2w6 | `fmin.jl:47`/`:75` return canonical `0x7ff8…`; `reversible_compile(min,F64,F64)` maps (`0xfff8000000000123`, 1.0) → `0x7ff8000000000000` vs native `0xfff8000000000123`, reversible. |
| F9 | CONFIRMED | S0 by letter; same NaN-payload caveat as F3 | NEW (jexo/m63k closed) | `soft_pow_julia(0xfff8…0123, −0.5)` = `0x7ff8000000000000`, Base `0x7ff8000000000123`; sNaN `0xfff0…0123` → Base `0x7ff0000000000123`. Positive NaN base is equal. |
| F6 | CONFIRMED | S1 yes | NEW (5oyt is the fail-loud mechanism, not this) | Both `extract_parsed_ir(soft_pow_julia,…)` and `reversible_compile(^,Float64,Float64)` die on `call … @j__pj_pow_body_int_* — no registered callee`. The jexo-advertised public `^` path is uncompilable. |
| F4 | CONFIRMED | S1 yes | NEW (l5v8 fixed transcendental forwarders only; h6f is LLVM fma) | `x^2`, `fma(x,x,x)`, `ifelse(x<0.0,-x,x)` all → `VoidType reached _type_width`; host `SoftFloat` gives MethodError for `x^2`, fma, mixed `<`, isnan, isfinite, `min(x,1.0)`. |
| F7 | CONFIRMED | S1 yes | 777 closed (different fix) → NEW bead, cite 777 | `x->1.0`, `x->x==x`, `x->Int64(x)` all → `VoidType reached _type_width`; `.bits` applied unconditionally at `softfloat_dispatch.jl:136/142/148`. |

All report-named beads exist and match their cited content: l5v8, ky5n, wigl, k2w6, r84x,
jexo, m63k, 5oyt, dq8l, 777, h6f, fnxg, ys0d — all **closed**. No open bead in
`.beads/issues.jsonl` covers any of F1–F9 (keyword search: Payne/_RP_INV_2PI/soft_sin/cos/tan,
exp overflow, pow −1, SoftFloat ==, fminimum, NaN payload, pow_body_int, literal_pow, expm1,
sinh, cosh; only hit is Bennett-eis4, an unrelated soft_sin profiling spike). No overlap with
the other Astra reports/triages (B-arith, B-circuit-core, B-lowering, B-extract-core, B-tests-api,
B-extract-vm contain no SoftFloat-dispatch or soft_* numeric finding).

## F1 — Payne–Hanek table limb typo (CONFIRMED, S0)

- Constant: `src/softfloat/fsin.jl:114`, `_RP_INV_2PI[12] = UInt64(0xc7fe25ffff781660)` with
  comment "NB: musl/openlibm value; cross-checked vs Julia table" (false).
- Independent value: 1/(2π) at BigFloat precision 4096, 19 × 64-bit limbs by repeated
  `×2^64, floor`. Limb 12 = `0xc7fe25fff7816603`; `Base.Math.INV_2PI[12]` is identical and all 19
  Base limbs match BigFloat. The other 18 source limbs match. XOR = `0x8f97063`. Shape of the error
  is a one-nibble transcription slip (`…fff7816603` → `…ffff781660`: extra `f`, dropped trailing `3`).
  Present since the introducing commit `e273d10` (Bennett-3mo, 2026-05-03).
- Report witnesses reproduced exactly:
  - `soft_sin(0x6dfd3af758367500)` (x=6.60e221) = `0xbfd65997f31adcad` (−0.3492) vs Base
    `0x3f3672d0d39a6e33` (3.43e-4).
  - `soft_cos(0x7096a3fc1ff6c559)` (x=2.25e234) = `0x3f31a151f3a4fff6` (2.69e-4) vs `0xbfefa47c72347349` (−0.9888).
  - `soft_tan(0x72e7a7b800919a08)` (x=3.23e245) = `0x3f6391785d15165c` (0.00239) vs `0xc07a2a3324e0624b` (−418.6).
  All three are sign flips (ordinal distance ≈ 9.15e18–9.21e18 ulps) — outputs are unrelated values.
- Affected window (12 random significands × both signs per unbiased exponent 0..1023):
  sin bad exponents 684..819, cos 682..819, tan 682..818; outside it 0 failures. Sample of 400 at
  exactly 2^700: 400/400 wrong, max 5.99e6 ulps; at 2^800: 400/400 wrong (sign flips). Min bad
  distance in window = 3 ulps (edge of window), so the whole band is effectively garbage.
- Fix validated in memory (no file change): `Core.eval(SoftFloatLib, :(const _RP_INV_2PI = …))`
  with limb 12 corrected → the three witnesses become 0 ulp; the same 12,288-sample all-exponent
  sweep gives 0 cases >2 ulp (max sin 0, cos 1, tan 1).
- Why the tests missed it: `test_softfsin.jl` / `test_softftan.jl` fixed points stop at `1e22`
  (lines 37 / 35), random sweeps use buckets up to `(rand()-0.5)*1e22` (fsin.jl test :132, ftan
  test :140) ≈ 2^73, and the binade lattices (fsin :98, ftan :108) sweep `2.0^binade` over
  **negative** binades only. Dispatch tests (`test_3mo…`, `test_s1zl…`) top out at 1e10. Limb 12
  is only consumed for exponents ≈ 682–819, so no test ever indexes it. No test checks the table
  against an independent high-precision value.

## F8 — exp/exp2 top-cell overflow NaN (CONFIRMED, S0)

Witnesses (all reproduced exactly):

| call | soft | reference |
|---|---|---|
| `soft_exp(0x40862e4189374bc7)` 709.782 | `0xfff8000000000000` | `0x7feffa297cab7a93` |
| `soft_exp(0x40862e42fefa39ef)` = log(floatmax) | `0xfff8000000000000` | `0x7fefffffffffff2a` |
| `soft_exp2(0x408ffff9db22d0e5)` 1023.997 | `0xfff8000000000000` | `0x7fefeefba041287f` |
| `soft_exp2(0x408fffffffffffff)` prevfloat(1024) | `0xfff8000000000000` | `0x7feffffffffffd3a` |
| `soft_expm1(0x40862e4189374bc7)` | `0xfff8000000000000` | `0x7feffa297cab7a93` |
| `soft_sinh(±1419.564)` | `0xfff8000000000000` | `0x7ff0…` / `0xfff0…` |
| `soft_cosh(1419.564)` | `0xfff8000000000000` | `0x7ff0000000000000` |

Window scans (200k evenly bit-spaced samples per interval; count = NaN samples):
- exp on [709.0, log(floatmax)]: 692 NaN, first 709.7800086180843, last 709.7827128911231 —
  i.e. the upper half of the last ln2/128 reduction cell (width ≈ 0.0027).
- exp2 on [1023, prevfloat(1024)]: 782 NaN, [1023.99609…, 1023.99999…] (width 1/256).
- expm1: same window as exp. sinh/cosh on [1418, 1420]: NaN in [1419.5600, 1419.5654] (= 2×exp
  window, via the huge-arm `exp(|x|/2)`); sinh on [709, 1418]: 0 NaN.
- `soft_exp_julia(709.782)` = `0x7feffa297cab7a93` and `soft_exp2_julia(prevfloat(1024))` =
  `0x7feffffffffffd3a` (correct) — the bug is confined to the musl-port kernels + their consumers.

Dedup: Bennett-ky5n close reason says verbatim "Drive-by finding: soft_exp_fast has small
NaN-producing bug for inputs in (~709.78, ~709.79); worked around by setting … threshold
conservatively at 709.0". Not filed as a bead. The workaround comment (`fsinh.jl:110–120`,
`fcosh.jl:46–50`) also claims the huge arm "stays finite up to |x| ≈ 1419 where true sinh
transitions to ±Inf" — wrong (sinh/cosh overflow at ≈710.476; 1419.56 is exactly where the
halved argument re-enters the bad exp cell). Also: `test_softfexp.jl:308–313` "BIT-EXACT overflow
boundary" records that an earlier NaN at 709.79 was "fixed" by tightening the threshold — that
fix only moved the cutoff to log(floatmax); the NaN half-cell just below it remains.

Would the conventions have caught it?
- **fnxg (rule 13) subnormal-output sweep: no.** It targets the underflow side (x ≈ −708…−745);
  the defect is at the overflow side.
- **A 0.25/0.5-step overflow sweep: no.** Grid points 709.5/709.75/710.0 and 1023.75/1024.0 all lie
  outside the 0.0027-wide (exp) / 0.0039-wide (exp2) windows. Existing overflow probes straddle
  it by accident: `709.78` (test_softfexp.jl:318) is 8.6e-6 *below* the window,
  `709.7827128933841` (:311) is just *above* log(floatmax); `test_softfexpm1.jl:58` uses 709.8.
  Only a sweep of the final reduction cell at ≤~1e-4 spacing (or bit-stepping from
  prevfloat(log(floatmax)) downward) — the "top-cell overflow sweep" the report proposes — would
  catch it. Recommend the fix bead add that as an overflow analogue of the fnxg convention.

## F5 — soft_pow(−1, y) (CONFIRMED, S0)

`soft_pow(bits(-1.0), bits(y))` vs libm `pow` vs Base `^` vs `soft_pow_julia`:
y=1 → `0x3ff0…` vs `0xbff0…`/`0xbff0…`/`0xbff0…`; y=3, −3 same pattern; y=0.5 → `0x3ff0…` vs libm
`0xfff8000000000000`, Base DomainError, julia-port `0x7ff8…`; y=NaN → `0x3ff0…` vs `0x7ff8…`.
y ∈ {2, ±Inf, 0} agree (+1). The docstring (`fpow.jl:~695` "pow(±1, y) = 1.0 (always)") and
`test_softfpow.jl:85–89` encode the wrong rule (C99 only gives +1 for **+1** base, or −1 with
±Inf exponent). Reach: `llvm.pow.*` extraction (`extract/instructions.jl:5330`) → `soft_pow`, i.e.
C/Rust/.ll ingest; Julia `^(::SoftFloat,::SoftFloat)` routes to `soft_pow_julia` (correct here).
S0 stands for the ingest path.

## F2 — mixed SoftFloat equality (CONFIRMED, S0)

`Bennett.SoftFloat(0.0) == 0.0` → false, `0.0 == SoftFloat(0.0)` → false; `SoftFloat isa Number`
→ false; `which(==, (SoftFloat, Float64))` = `==(x, y) @ Base Base_compiler.jl:298` (identity
fallback). Only `==(::SoftFloat,::SoftFloat)` is defined (`softfloat_dispatch.jl:31`).
Branch witnesses through `reversible_compile(f, Float64)`:
- `f(x)=ifelse(x==0.0,-x,x)`: 66 gates; `simulate(c, 0x0)` = `0x0000000000000000`, native
  `0x8000000000000000`; `simulate(c, bits(2.0))` = `0x4000…` (ok); `verify_reversibility(c; n_tests=10)` = true.
- `f(x)= x==0.0 ? x+1.0 : x`: 66 gates; `simulate(c, 0x0)` = `0x0000000000000000`, native
  `0x3ff0000000000000`. `extract_parsed_ir` of the wrapped function has **1 block** — the `then`
  branch (and its soft_fadd) was folded away by Julia before extraction; the circuit is the
  identity copy. Silent semantic miscompile, invisible to the ancilla check.

## F3 — min/max NaN canonicalisation (CONFIRMED, S0-by-letter)

`soft_fminimum(0x7ffdb067bde7cfb5, 0x65c861318a293c31)` = `0x7ff8000000000000`, Base.min
`0x7ffdb067bde7cfb5`. `soft_fmaximum(0xee7f52a0153989e7, 0xfff370da26cf0889)` = `0x7ff8…`, Base.max
`0xfff370da26cf0889`. Host `min(SoftFloat(-qNaN.123), SoftFloat(1.0)).bits` = `0x7ff8…`.
Circuit: `reversible_compile(min, Float64, Float64)` (8,226 gates) maps
(`0xfff8000000000123`, `0x3ff0…`) → `0x7ff8000000000000` vs native `0xfff8000000000123`;
`verify_reversibility` true. Source: `fmin.jl:47` and `:75`
`ifelse(either_nan, UInt64(0x7FF8000000000000), base)`. Contradicts the k2w6 close claim
("bit-exact vs Julia Base.min/Base.max"). Seed-0xb528 186/200k counts not re-run.

## F9 — soft_pow_julia negative-NaN base (CONFIRMED, S0-by-letter)

| a | soft_pow_julia(a, −0.5) | Base `^` |
|---|---|---|
| `0xfff8000000000123` | `0x7ff8000000000000` | `0x7ff8000000000123` |
| `0xfff0000000000123` (sNaN) | `0x7ff8000000000000` | `0x7ff0000000000123` |
| `0x7ff8000000000123` | `0x7ff8000000000123` | equal |

Cause matches report: `fpow_julia.jl:~489–495` negative-sign rule `yisint || return _PJ_POW_NAN`
fires before NaN-base classification. Payload-only divergence; same severity caveat as F3.

## F6 — `^` Float64 overload uncompilable (CONFIRMED, S1)

`extract_parsed_ir(soft_pow_julia, Tuple{UInt64,UInt64})` → `ErrorException: ir_extract.jl: call
in @julia_soft_pow_julia_…: %86 = call i64 @j__pj_pow_body_int_…(i64 zeroext %"a::UInt64", i64
signext %22) — call to 'j__pj_pow_body_…' … no registered callee`. `reversible_compile(^, Float64,
Float64)` fails identically. Valid two-Float64 input rejected → S1 correct. Bennett-5oyt is the
fail-loud mechanism producing this (working as intended), not a tracker for it.

## F4 — missing dispatch methods (CONFIRMED, S1)

`reversible_compile(x->x^2 | x->fma(x,x,x) | x->ifelse(x<0.0,-x,x), Float64)` → all
`ErrorException: ir_extract.jl: VoidType reached _type_width …`. Host-level `f(SoftFloat(0.0))`
→ MethodError for `x^2`, `fma`, `x<0.0`, `isnan`, `isfinite`, `min(x,1.0)`. Same root-cause
class as Bennett-l5v8 (MethodError body → void return + unreachable), for operations l5v8 did
not cover. Misleading diagnostic compounds it. Note F2 and F4 share the mixed-type-operator gap
(`==` silently wrong because Base has a generic fallback; `<` loud because it does not) — a single
bead covering mixed operators may be appropriate, but keep F2 flagged S0.

## F7 — non-SoftFloat return (CONFIRMED, S1)

`reversible_compile(x->1.0 | x->x==x | x->Int64(x), Float64)` → all
`VoidType reached _type_width`. The wrappers at `softfloat_dispatch.jl:136/142/148` unconditionally
take `.bits` of the result. Bennett-777 (closed "soft_fptosi routes Float64→Int … 30/30 audit
functions compile") did not fix this overload path.

## Not re-verified (outside F1–F9 scope)
F10/F11 (S2), nits, `_rp_fromfraction` suspicion, and the report's large random-sweep counts
(9,615/9,578/9,667; 186/200k) — only the witnesses and my own sweeps above were executed.
