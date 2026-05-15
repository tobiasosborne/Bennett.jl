## Session log — 2026-05-15 — Bennett-kh6n / U_ trailing-`.` prefix-discipline codemod for scalar `llvm.*` intrinsics

**Shipped:** see git log around the kh6n commit; 32 untightened
`startswith(cname, "llvm.<x>")` sites in `src/extract/instructions.jl`
extended with trailing `.`, mirroring the discipline that
`src/extract/vectors.jl:_validate_vector_intrinsic_lane` already
enforces. Plus three explicit fail-loud rejects for sibling intrinsics
that the un-tightened arms used to silently swallow:

- `llvm.minimumnum.*` / `llvm.maximumnum.*` (LLVM 19+, IEEE 754-2019
  `minimumNumber`/`maximumNumber`) — pre-fix swallowed by the
  `llvm.minimum` / `llvm.maximum` arm (which itself uses an integer
  signed-compare on the operand bit pattern, so the silent dispatch
  produced wrong gates with the wrong NaN propagation contract).
- `llvm.roundeven.*` (banker's rounding / round-half-to-even) —
  pre-fix swallowed by the `llvm.round` arm and dispatched to
  `soft_round` (round-half-AWAY-from-zero), which produces the wrong
  answer at every half-integer tie. Native `soft_roundeven` is filed
  as future work.

Plus a float-operand rejection on the scalar `llvm.minnum.` /
`llvm.minimum.` / `llvm.maxnum.` / `llvm.maximum.` arms, mirroring
the existing vector handler. The scalar arm uses `IRICmp(:slt)` on
the operand bit pattern, which mishandles `+0.0`/`-0.0` (signed-int
compare treats them as unequal), NaN propagation (NaN bit patterns
compare like `+Inf`), and signed-int negative-float ordering. Native
`soft_fmin`/`soft_fmax` is future work; until then, fail loud.

Drive-by: `src/extract/sret.jl:147` had the same untightened
`startswith(cname, "llvm.memcpy")` — tightened to `llvm.memcpy.`.

**Why:** worklog chunks 063 (`g82n` / Tier C1 complete) and 064
(`ao66` follow-up tidy) called out an explicit project-wide rule:
"every `startswith(cname, "llvm.<name>")` MUST include trailing `.`
from the moment of insertion." This rule was born from two same-day
silent miscompiles —

  - Bennett-7goc: untightened `llvm.atan` matched `llvm.atan2.f64`
    and dispatched to `soft_atan(y)` dropping `x`; `atan2(3, 4)`
    returned `1.249` instead of `0.6435`.
  - Bennett-o7cy: untightened `llvm.exp` matched `llvm.expm1.f64`
    and dispatched to `soft_exp` minus the `-1`; `expm1(small)`
    lost ~16 bits of precision near zero.

Both bugs survived initial test sweeps because the random fuzz didn't
exercise the prefix collision — and both were detected late in the
transcendental grind only when the second sibling intrinsic landed.
The rule is "tighten on insertion, not on second-sibling discovery"
because the latter has already cost a half-day of bisecting twice.

The instructions.jl shard had 32 sites that pre-dated the rule. They
were latent — not yet collided with a real LLVM sibling — but each is
a future-bisect waiting to happen as LLVM grows new sibling
intrinsics: `minimumnum`/`maximumnum` (LLVM 19+), `roundeven` (LLVM
11+), and several speculative future families.

**Gotchas / Lessons:**

- The `llvm.round` arm is INTENTIONALLY a no-op block — the comment
  is "Falling through to the next `if` keeps the original semantics"
  because the registered-callee path in `_convert_instruction` picks
  up `soft_floor`/`soft_ceil`/`soft_trunc`/`soft_round` via
  `Base.floor(::SoftFloat)` etc. dispatch. So tightening from
  `llvm.round` to `llvm.round.` doesn't affect the happy path —
  but it DOES stop `llvm.roundeven.f64` from no-op-falling-through to
  a callee registry that has `soft_round` (wrong rounding mode)
  registered for it. Without the tightening + explicit reject,
  `roundeven(2.5)` quietly returned `3.0` instead of `2.0`.

- `LLVM.value_type(ops[1]) isa LLVM.FloatingPointType` is the right
  predicate for the float-operand reject. `_iwidth` returns 64 for
  both `i64` and `double` (per
  `src/extract/helpers.jl:_type_width(LLVMDouble)`), so width alone
  cannot distinguish. The vector handler uses
  `_vector_element_is_float(inst)`; the scalar equivalent is the
  direct `isa LLVM.FloatingPointType` check on the first operand.

- The source-property regex needs to filter by first-arg shape:
  `startswith\(\s*[A-Za-z_][A-Za-z0-9_]*\s*,\s*\"llvm\."` — i.e.
  identifier as the first arg, not a string literal. Otherwise the
  test flags doc-comment lines like
  `# `startswith("llvm.cos.", "llvm.cosh.f64")` from matching` (which
  illustrate the OLD bad behavior). Caught this on the first run with
  the bare-comma regex — flagged exactly one false positive at
  `instructions.jl:1096`.

- The bead's "(or implement soft_roundeven)" wording is honest scope
  creep. Implementing soft_roundeven is a real C2-ish primitive
  (banker's rounding has no native LLVM op below the round
  instruction), and this codemod is a defensive bug-prevention pass
  not a feature delivery. Filed soft_roundeven as future work via
  the explicit reject error message pointing at it.

**Rejected alternatives:**

- 3+1 protocol per CLAUDE.md §2: skipped per the same exception used
  by Bennett-bybh (worklog chunk 061) and the more recent
  prefix-discipline drive-bys in chunks 063-064. The change is a
  mechanical codemod following an existing pattern from
  `vectors.jl`; the design space is not contested. Documenting the
  exception here for the next 3+1 audit.

- Implementing `soft_minimumnum` / `soft_maximumnum` / `soft_fmin` /
  `soft_fmax` / `soft_roundeven` inline as part of this fix.
  Rejected: each is a separate primitive worth its own bead with
  full subnormal-output sweep per CLAUDE.md §13. Filing them via
  the explicit reject error messages instead. The fail-loud reject
  is correct under §1; producing wrong gates silently is not.

- Tightening prefixes WITHOUT the explicit `roundeven` /
  `minimumnum` / `maximumnum` rejects. Rejected: tightening alone
  would make these intrinsics fall through to the
  benign-allowlist-or-error path, which DOES error loud — but the
  error message would say "no callee registered" rather than naming
  the actual semantic mismatch. The explicit reject names the
  primitive and the design-time decision (e.g. "soft_roundeven is
  future work"), which is far more actionable for the bisecting
  agent.

**Validation:** RED-GREEN TDD per CLAUDE.md §3.

- RED: 5 reject testsets in `test/test_kh6n_prefix_discipline.jl`
  (one each for `llvm.minimumnum.f64`, `llvm.maximumnum.f64`,
  `llvm.roundeven.f64`, `llvm.minimum.f64`, `llvm.minnum.f64`) plus
  a source-property test that asserts every
  `startswith(<identifier>, "llvm.<x>")` ends with trailing `.`
  (with `llvm.assume` / `llvm.experimental.noalias.scope.decl` /
  `llvm.invariant.start` / `llvm.invariant.end` / `llvm.sideeffect`
  in an explicit allowlist as complete intrinsic names). Initial
  run: 2 pass, 5 fail, 6 errored. Source-property test reported 32
  untightened prefixes.

- GREEN: 13 pass, 0 fail. Source-property `bad` list empty.

- Regression sample (20 tests, 6981+ assertions): all green.
  - `test_ao66_vector_intrinsic_rescalarise`: 41/41
  - `test_g82n_llvm_atanh_dispatch`: 33/33
  - `test_eq9p_llvm_acosh_dispatch`: 27/27
  - `test_lqif_memcpy_memmove_reject`: 8/8
  - `test_37mt_memcpy_const_aligned`: 80/80
  - `test_9nwt_memset_const`: 82/82
  - `test_3mo_llvm_sincos_dispatch`: 31/31
  - `test_o7cy_llvm_expm1_dispatch`: 36/36
  - `test_0ulc_llvm_log1p_dispatch`: 34/34
  - `test_intrinsics` (LLVM intrinsics coverage): 1280/1280
  - `test_float_intrinsics`: 27/27
  - `test_1pb_llvm_transcendentals`: 44/44
  - `test_h6f_llvm_fma_dispatch`: 14/14
  - `test_emv_llvm_pow_dispatch`: 31/31
  - `test_2hhx_soft_round`: 5091/5091
  - `test_s1zl_llvm_tan_dispatch`: 18/18
  - `test_qpke_llvm_atan_dispatch`: 19/19
  - `test_ckvj_llvm_asin_dispatch`: 26/26
  - `test_bd7f_llvm_acos_dispatch`: 27/27
  - `test_7goc_llvm_atan2_dispatch`: 32/32
  - `test_kh6n_prefix_discipline` (this fix): 13/13

Full `Pkg.test()` not run (~27 min; per
`feedback_no_pre_push_hook.md` and `feedback_pkg_test_capture.md`
this is left to the user / next session if they want a full-suite
green claim). The 6981-assertion sample covers every intrinsic-arm
and dispatch path touched by the fix.

**Next agent starts here:** soft-`fmin`/`fmax` (native float min/max
respecting IEEE +0/-0/NaN), soft-`minimumnum`/`maximumnum` (IEEE
754-2019 numerics with quiet-NaN tie-break), and soft-`roundeven`
(banker's rounding) are all future-work primitives now flagged by
the explicit fail-loud reject error messages. Each is its own bead
and warrants the standard subnormal-output sweep per CLAUDE.md §13.
