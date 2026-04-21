# Bennett-atf4 — Proposer A design: derive `lower_call!` arg types from `methods()`

**Bead**: Bennett-atf4. Labels: `3plus1,core`. Proposer: A (independent).
**Date**: 2026-04-21.
**Scope**: narrow fix for the hardcoded `Tuple{(UInt64 for _ in inst.args)...}`
at `src/lower.jl:1869`.

This document is written without sight of `alpha_proposer_B.md`.

---

## §1 — Scope

### IN scope

- Replace the body of `lower_call!` at `src/lower.jl:1869` so that `arg_types`
  is derived from the Julia method table of `inst.callee`, not synthesised
  from arg count alone.
- Add a helper (`_callee_arg_types`) in `src/lower.jl` that does the method
  lookup, validates the result, and returns the `Tuple{...}` type.
- Add a fail-loud width-matching assertion (`_assert_arg_widths_match`) that
  cross-checks `inst.arg_widths[i]` against the method parameter's bit width
  and errors with full context on mismatch.
- RED test file `test/test_atf4_lower_call_nontrivial_args.jl` that drives
  the fix.
- Wire the new test file into `test/runtests.jl`.

### OUT of scope

- Changes to the `IRCall` struct. The narrow fix does not require an
  `arg_types::Type{<:Tuple}` field: every IRCall construction site today
  gives us the `callee::Function`, and `methods(callee)` is sufficient. If a
  future PRD needs caller-specified arg types (e.g. multi-method dispatch,
  external-IR callees per `ir_extract_from_ll/bc`), add the field then.
- Changes to `lower_call!`'s signature. Existing 13 call sites continue to
  pass `(gates, wa, vw, inst; compact)` unchanged.
- Changes to `LoweringCtx`. The fix sits entirely inside `lower_call!`.
- Memoisation of `extract_parsed_ir` across repeated IRCalls
  (p6_research_local.md §12.4 latent; out of scope here).
- Any change to `_lookup_callee` / `register_callee!` in `ir_extract.jl`.
- Any behavioural change on the `compact=true` branch vs the `compact=false`
  branch — both continue to call the same `extract_parsed_ir`.
- ir_extract sret-side changes (that is Bennett-0c8o territory per the
  brief). Our RED test intentionally probes only `lower_call!` up to line
  1870; the error past that belongs to a different bug.

---

## §2 — Fix body: exact Julia code

### 2.1 Before / after diff (conceptual)

**Before** (`src/lower.jl:1865-1871`):

```julia
function lower_call!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                     vw::Dict{Symbol,Vector{Int}}, inst::IRCall;
                     compact::Bool=false)
    # Pre-compile the callee function
    arg_types = Tuple{(UInt64 for _ in inst.args)...}
    callee_parsed = extract_parsed_ir(inst.callee, arg_types)
    callee_lr = lower(callee_parsed; max_loop_iterations=64)
    ...
```

**After**:

```julia
function lower_call!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                     vw::Dict{Symbol,Vector{Int}}, inst::IRCall;
                     compact::Bool=false)
    # Pre-compile the callee function.
    #
    # Bennett-atf4: derive the real callee argument Tuple{...} from Julia's
    # method table instead of hardcoding UInt64. Every callee registered via
    # register_callee!() today has all-UInt64 scalar args, so this is
    # byte-identical for the existing corpus; the new derivation is what
    # unblocks NTuple-aggregate callees like `linear_scan_pmap_set(::NTuple{9,UInt64},
    # ::Int8, ::Int8)`.
    arg_types = _callee_arg_types(inst.callee, length(inst.args))
    _assert_arg_widths_match(inst, arg_types)
    callee_parsed = extract_parsed_ir(inst.callee, arg_types)
    callee_lr = lower(callee_parsed; max_loop_iterations=64)
    ...
```

Only lines 1869 change and one assertion line is inserted. The rest of
`lower_call!` (lines 1871-1925) is untouched.

### 2.2 Helper: `_callee_arg_types`

Placed immediately above `lower_call!` in `src/lower.jl`:

```julia
# Bennett-atf4: derive the Julia argument Tuple type of a callee registered
# via `register_callee!`.  Uses `methods(callee)` directly — NOT
# `Base.return_types` (which is fragile per docs/design/p6_proposer_A.md
# §R4) and NOT `which(...)` (requires concrete arg types we don't have).
#
# Contract:
#   - callee must have ≥1 method (fail loud).
#   - If >1 method: fail loud with an enumeration.  Every currently
#     registered callee has exactly one method (verified via
#     docs/design/p6_research_local.md §6); a multi-method callee is a
#     design change, not a silent extension.
#   - Vararg methods are rejected in MVP.  None of today's callees is
#     vararg.
#   - Method param count must match `n_caller_args`: a caller emitting
#     N args against a callee of arity M is a symptom of earlier miswiring.
#
# Returns a concrete Tuple type suitable for passing to
# `extract_parsed_ir(callee, arg_types)`.
function _callee_arg_types(callee::Function, n_caller_args::Int)::Type{<:Tuple}
    ms = methods(callee)
    if length(ms) == 0
        error("lower.jl: lower_call!: callee ", callee,
              " has no methods; cannot derive argument types. ",
              "This usually means a non-Function was registered via ",
              "register_callee! or the callee was redefined away.")
    elseif length(ms) > 1
        sigs = join(("  - " * string(m.sig) for m in ms), "\n")
        error("lower.jl: lower_call!: callee ", callee,
              " has ", length(ms), " methods; ambiguous. ",
              "Bennett-atf4 MVP requires exactly one method per registered callee.\n",
              "Methods:\n", sigs)
    end

    m = first(ms)
    # m.sig.parameters is a Core.SimpleVector:
    #   [1] = typeof(callee)      (e.g. typeof(soft_fma))
    #   [2:end] = the argument types
    params = m.sig.parameters
    n_method_args = length(params) - 1

    # Reject Vararg methods in MVP.  Base.isvarargtype identifies the
    # `Vararg{T, N}` wrapper Julia uses in method signatures.
    if n_method_args >= 1 && Base.isvarargtype(params[end])
        error("lower.jl: lower_call!: callee ", callee,
              " has a vararg method ", m.sig,
              "; Bennett-atf4 MVP rejects vararg callees.")
    end

    if n_method_args != n_caller_args
        error("lower.jl: lower_call!: callee ", callee,
              " has method arity ", n_method_args,
              " but the IRCall supplies ", n_caller_args, " argument(s). ",
              "Method signature: ", m.sig, ". ",
              "This is a caller-side miswiring — check the IRCall emitter.")
    end

    # Build `Tuple{params[2], params[3], ..., params[end]}` as a concrete Type.
    return Tuple{params[2:end]...}
end
```

### 2.3 Helper: `_assert_arg_widths_match`

Also placed above `lower_call!` in `src/lower.jl`. This closes the latent
bug flagged in `p6_research_local.md` §12.4 (silent arg width misalignment):

```julia
# Bennett-atf4: validate that each caller-supplied `inst.arg_widths[i]`
# matches the bit width of the i-th callee method parameter.  This is a
# cross-check of two independently computed quantities:
#   - `inst.arg_widths[i]`: computed by the caller (ir_extract.jl's IRCall
#     emitter) from LLVM param widths at the call site.
#   - `sizeof(param_type) * 8`: the Julia-level storage size of the method's
#     declared parameter type, via `sizeof`.
#
# If the two disagree, bits silently overflow or truncate in the
# CNOT-copy loop at src/lower.jl:1882-1913 (wiring line 1885:
# `callee_start = sum(callee_parsed.args[j][2] for j in 1:(i-1); init=0)`
# would offset using the callee's true widths while the copy-loop reads
# `inst.arg_widths[i]` bits off the caller).  This assertion fails loud
# at the source of the mismatch rather than letting the circuit silently
# compute the wrong function.
#
# Invariant for today's corpus (verified in the regression plan §6):
# every registered callee has all-UInt64 args, and every IRCall emitter
# passes arg_widths = [64, 64, ...] — the assertion is a no-op for every
# path in the existing test suite.
function _assert_arg_widths_match(inst::IRCall, arg_types::Type{<:Tuple})
    param_types = arg_types.parameters
    n = length(param_types)
    # Arity was already validated by _callee_arg_types; double-check here
    # as a defensive invariant so this helper is callable standalone.
    length(inst.arg_widths) == n || error(
        "lower.jl: lower_call!: internal — arg_widths length (",
        length(inst.arg_widths), ") != arg_types arity (", n, ").")

    for i in 1:n
        pt = param_types[i]
        # `sizeof(pt) * 8` is the total bit width of the (concrete) param
        # type — for `NTuple{9,UInt64}` it is 576; for `Int8` it is 8;
        # for `UInt64` it is 64.  If `pt` is abstract, `sizeof` errors
        # with "Abstract type X does not have a definite size" — which is
        # the right fail-loud behaviour (we cannot compile a call to an
        # abstractly-typed callee parameter anyway).
        param_bits = sizeof(pt) * 8
        got = inst.arg_widths[i]
        param_bits == got || error(
            "lower.jl: lower_call!: argument width mismatch for callee ",
            inst.callee, " arg #", i, " (", inst.args[i], "): ",
            "IRCall.arg_widths[", i, "] = ", got, " but method param type is ",
            pt, " (", param_bits, " bits). ",
            "Full arg_widths=", inst.arg_widths,
            ", full method arg_types=", arg_types, ". ",
            "This indicates the IRCall emitter computed widths inconsistent ",
            "with the callee's Julia method signature.")
    end
    return nothing
end
```

### 2.4 Full patched region

Concretely, the patch to `src/lower.jl` inserts the two helpers above the
existing `lower_call!` definition and modifies three lines inside the
function body (the arg_types line, plus the added assertion, plus a
comment). Net: +~80 lines of helper code, +1 line of assertion inside the
function, 1 line replaced. No field additions. No signature changes.

---

## §3 — Width-matching assertion placement

The assertion **must fire before** `extract_parsed_ir` in order to give the
right error. If we run extraction first, any width mismatch between
`inst.arg_widths` and the real callee signature will manifest as a confusing
downstream wiring bug (wrong `callee_start` offset) or, more likely, as a
silent miscompilation (bits truncated / overflowed).

Placement order, in `lower_call!` post-fix:

```julia
arg_types = _callee_arg_types(inst.callee, length(inst.args))  # line A
_assert_arg_widths_match(inst, arg_types)                       # line B
callee_parsed = extract_parsed_ir(inst.callee, arg_types)       # line C
callee_lr = lower(callee_parsed; max_loop_iterations=64)        # line D
```

Rationale:

- Line A derives the true types; line B validates caller widths against
  those types. If B fires, we never call `extract_parsed_ir` with
  mismatched expectations.
- Additionally, once `callee_parsed` exists, we *could* cross-check
  `callee_parsed.args[j][2] == inst.arg_widths[j]`. That is a strictly
  weaker check (post-extraction widths are already derived from the same
  `arg_types` we built). Placing the check at B is both cheaper and fires
  on cases where extraction itself would already have crashed with a less
  actionable error.

Error message example (for the Bennett-atf4 reproduction case with
hypothetical bad widths):

```
lower.jl: lower_call!: argument width mismatch for callee linear_scan_pmap_set
arg #1 (IROperand(:ssa, :state, 0)): IRCall.arg_widths[1] = 320 but method
param type is NTuple{9, UInt64} (576 bits). Full arg_widths=[320, 8, 8],
full method arg_types=Tuple{NTuple{9, UInt64}, Int8, Int8}. This indicates
the IRCall emitter computed widths inconsistent with the callee's Julia
method signature.
```

---

## §4 — Multi-method / vararg handling

### 4.1 Multi-method: reject

Every callee registered today in `src/Bennett.jl:163-209` has exactly one
method (verified live via `methods(...)`). A multi-method callee is a
design change that would need to either:

- Pick the unique method matching `inst.arg_widths`, or
- Extend `IRCall` with an `arg_types` field so the caller can specify.

Neither is in scope for MVP. `_callee_arg_types` fails loud:

```
lower.jl: lower_call!: callee SomeFunction has 2 methods; ambiguous.
Bennett-atf4 MVP requires exactly one method per registered callee.
Methods:
  - Tuple{typeof(SomeFunction), UInt64}
  - Tuple{typeof(SomeFunction), UInt64, UInt64}
```

### 4.2 Vararg: reject

`Base.isvarargtype(params[end])` detects `Vararg{T,N}` at the last position.
Rejected because:

- No current callee is vararg.
- The `inst.arg_widths` vector doesn't carry enough information to infer
  N at the call site.
- Silent wiring is worse than a clean reject.

Error message:

```
lower.jl: lower_call!: callee f has a vararg method
Tuple{typeof(f), UInt64, Vararg{UInt64}}; Bennett-atf4 MVP rejects
vararg callees.
```

### 4.3 Zero methods: reject

The only way this can happen is if a user registered a non-Function, or a
Method was redefined to remove it. Error message:

```
lower.jl: lower_call!: callee f has no methods; cannot derive argument
types. This usually means a non-Function was registered via register_callee!
or the callee was redefined away.
```

### 4.4 Arity mismatch: reject

If `inst.arg_widths` has N entries but the method has M != N parameters,
this is upstream IRCall emitter mis-wiring. Error message:

```
lower.jl: lower_call!: callee linear_scan_pmap_set has method arity 3 but
the IRCall supplies 2 argument(s). Method signature: Tuple{typeof(...),
NTuple{9, UInt64}, Int8, Int8}. This is a caller-side miswiring — check
the IRCall emitter.
```

---

## §5 — RED test

File: `test/test_atf4_lower_call_nontrivial_args.jl`. Content is below in
full.

The test exercises four cases:

1. **Non-UInt64 scalar arg** (Int8): must fail today (`MethodError`), must
   pass post-fix.
2. **NTuple aggregate arg** (`linear_scan_pmap_set`): must get past line
   1870 post-fix. We expect extraction to still fail downstream (sret is
   Bennett-0c8o). We assert failure happens *after* our new code with the
   distinctive sret error text, confirming Bennett-atf4's piece is done.
3. **Width-matching assertion**: construct an `IRCall` with deliberately
   mismatched `arg_widths` and assert the new error.
4. **Vararg rejection**: register a stub callee with a vararg method,
   confirm we error cleanly.

Additionally, a regression sanity check: the existing `soft_fma` call path
still derives `Tuple{UInt64, UInt64, UInt64}` identically.

### 5.1 Test file — complete contents

```julia
# test/test_atf4_lower_call_nontrivial_args.jl
#
# Bennett-atf4 — lower_call!: derive callee arg types from methods() instead
# of hardcoding UInt64.
#
# RED cases (all failing on the unfixed code at src/lower.jl:1869,
# all passing once `_callee_arg_types` + `_assert_arg_widths_match` land):
#
#   T1. Int8 scalar arg     — fails today with "no unique matching method
#       found for the specified argument types"
#   T2. NTuple aggregate arg — fails today with the same MethodError.
#                             After the fix, must get past line 1870; we
#                             tolerate the downstream sret error
#                             (Bennett-0c8o scope).
#   T3. Width-matching      — new assertion must fire with clear context.
#   T4. Vararg rejection    — new helper must fail loud.
#
# Regression:
#   R1. soft_fma still derives Tuple{UInt64, UInt64, UInt64}.

using Test
using Bennett
using Bennett: IRCall, IROperand, ssa, iconst, lower_call!, WireAllocator,
               ReversibleGate, allocate!, register_callee!, _known_callees
# The following two helpers are introduced by Bennett-atf4. The tests
# import them by name so that TDD is crisp: if the helpers don't exist,
# the `using Bennett: ...` line itself fails the testset.
using Bennett: _callee_arg_types, _assert_arg_widths_match

@testset "Bennett-atf4 lower_call! non-trivial arg types" begin

    # ---- T1: Int8 scalar callee --------------------------------------
    @testset "T1: Int8 scalar arg — hardcoded UInt64 assumption broken" begin
        # A minimal callee with an Int8 param.  If lower_call! still
        # hardcodes UInt64, the call chain `extract_parsed_ir(callee,
        # Tuple{UInt64})` hits `no unique matching method found ...`.
        int8_identity(x::Int8)::Int8 = x

        # Register so any future IRCall emitter paths can resolve it by
        # name; also keep symmetrical with the real corpus.  We clean up
        # the registration at end of testset.
        register_callee!(int8_identity)
        try
            inst = IRCall(:res, int8_identity, [ssa(:x)], [8], 8)
            gates = ReversibleGate[]
            wa = WireAllocator()
            vw = Dict{Symbol, Vector{Int}}()
            vw[:x] = allocate!(wa, 8)

            # Must not throw.  It should successfully lower.
            @test_nowarn lower_call!(gates, wa, vw, inst)

            # Post-condition: :res was bound, width 8 (Int8 return).
            @test haskey(vw, :res)
            @test length(vw[:res]) == 8
        finally
            delete!(_known_callees, string(nameof(int8_identity)))
        end
    end

    # ---- T2: NTuple aggregate arg — the bead's live repro ------------
    @testset "T2: NTuple{9,UInt64} arg path (linear_scan_pmap_set)" begin
        # Full-signature live reproduction from p6_research_local.md §2.6.
        # We expect:
        #   - _callee_arg_types(...) returns Tuple{NTuple{9,UInt64}, Int8, Int8}
        #   - _assert_arg_widths_match(inst, arg_types) passes (widths match)
        #   - extract_parsed_ir(...) is what fails, with the sret vector-store
        #     error (Bennett-0c8o scope).  We accept that and assert it.
        inst = IRCall(:res, Bennett.linear_scan_pmap_set,
                      [ssa(:state), ssa(:k), ssa(:v)],
                      [576, 8, 8], 576)
        gates = ReversibleGate[]
        wa = WireAllocator()
        vw = Dict{Symbol, Vector{Int}}()
        vw[:state] = allocate!(wa, 576)
        vw[:k]     = allocate!(wa, 8)
        vw[:v]     = allocate!(wa, 8)

        # Sub-assert: our helper derives the right type for this callee.
        T = _callee_arg_types(Bennett.linear_scan_pmap_set, 3)
        @test T === Tuple{NTuple{9,UInt64}, Int8, Int8}

        # Sub-assert: our assertion passes for the matching widths.
        @test _assert_arg_widths_match(inst, T) === nothing

        # Now invoke lower_call!.  It must no longer fail at line 1869
        # with "no unique matching method found".  It must reach
        # extract_parsed_ir, which today fails at the sret vector-store
        # rejection.  We accept any error whose message contains the
        # distinctive sret-path phrase and reject the old hardcoded-UInt64
        # MethodError phrase.
        err_msg = try
            lower_call!(gates, wa, vw, inst)
            ""
        catch e
            sprint(showerror, e)
        end
        @test !occursin("no unique matching method found", err_msg)
        # Either it succeeded (great — but we don't expect that until
        # Bennett-0c8o lands), or it hit the sret path with a recognizable
        # error (typical: "sret store at byte offset ... has non-integer
        # value type LLVM.VectorType" under optimize=true; or "sret with
        # llvm.memcpy form is not supported" under optimize=false).
        if !isempty(err_msg)
            @test occursin("sret", err_msg) || occursin("VectorType", err_msg) ||
                  occursin("memcpy", err_msg)
        end
    end

    # ---- T3: width-matching assertion --------------------------------
    @testset "T3: arg-width mismatch fires with clear context" begin
        # soft_fma(::UInt64, ::UInt64, ::UInt64)::UInt64 — but we'll
        # deliberately set arg_widths[2] = 32 to trigger the assertion.
        inst = IRCall(:res, Bennett.soft_fma,
                      [ssa(:a), ssa(:b), ssa(:c)],
                      [64, 32, 64],    # bogus 32 in slot 2
                      64)
        gates = ReversibleGate[]
        wa = WireAllocator()
        vw = Dict{Symbol, Vector{Int}}()
        vw[:a] = allocate!(wa, 64)
        vw[:b] = allocate!(wa, 32)
        vw[:c] = allocate!(wa, 64)

        e = try
            lower_call!(gates, wa, vw, inst)
            nothing
        catch ex
            ex
        end
        @test e isa ErrorException
        msg = sprint(showerror, e)
        @test occursin("argument width mismatch", msg)
        @test occursin("arg #2", msg)
        @test occursin("32", msg)
        @test occursin("UInt64", msg)
        @test occursin("soft_fma", msg)
    end

    # ---- T4: vararg rejection ----------------------------------------
    @testset "T4: vararg callee is rejected cleanly" begin
        # Define a vararg method.  Registration is not strictly needed
        # — _callee_arg_types takes the Function directly.
        vararg_stub(a::UInt64, rest::UInt64...) = a
        # Sanity: the method is indeed vararg.
        @test Base.isvarargtype(first(methods(vararg_stub)).sig.parameters[end])

        e = try
            _callee_arg_types(vararg_stub, 2)
            nothing
        catch ex
            ex
        end
        @test e isa ErrorException
        msg = sprint(showerror, e)
        @test occursin("vararg", msg)
        @test occursin("MVP rejects", msg)
    end

    # ---- T5: multi-method callee is rejected cleanly -----------------
    @testset "T5: multi-method callee is rejected cleanly" begin
        multimethod_stub(x::UInt64) = x
        multimethod_stub(x::UInt64, y::UInt64) = x + y
        @test length(methods(multimethod_stub)) == 2

        e = try
            _callee_arg_types(multimethod_stub, 1)
            nothing
        catch ex
            ex
        end
        @test e isa ErrorException
        msg = sprint(showerror, e)
        @test occursin("has 2 methods", msg)
        @test occursin("ambiguous", msg) || occursin("MVP requires", msg)
    end

    # ---- T6: zero-method callee is rejected cleanly ------------------
    # Skipping: hard to construct a zero-method Function in a test without
    # hacking Base internals.  The error branch is still covered by hand
    # inspection.

    # ---- R1: soft_fma still derives Tuple{UInt64, UInt64, UInt64} ----
    @testset "R1: regression — soft_fma derivation unchanged" begin
        T = _callee_arg_types(Bennett.soft_fma, 3)
        @test T === Tuple{UInt64, UInt64, UInt64}
    end

    # ---- R2: arity mismatch is a fail-loud caller bug ----------------
    @testset "R2: arity mismatch fires with clear context" begin
        e = try
            _callee_arg_types(Bennett.soft_fma, 2)   # real arity is 3
            nothing
        catch ex
            ex
        end
        @test e isa ErrorException
        msg = sprint(showerror, e)
        @test occursin("arity 3", msg)
        @test occursin("supplies 2", msg)
    end
end
```

### 5.2 Wiring into runtests.jl

Add one line to `test/runtests.jl` in the same block as the other
`test_*.jl` includes:

```julia
include("test_atf4_lower_call_nontrivial_args.jl")
```

Placed near `include("test_general_call.jl")` for topical grouping.

### 5.3 Expected TDD sequence

1. Commit the test file with the `using Bennett: _callee_arg_types,
   _assert_arg_widths_match` line. **RED** — `using` fails because symbols
   don't exist.
2. Add the two helpers to `src/lower.jl` (no other changes). **Still RED**
   — T1/T2 fail because `lower_call!` hasn't been rewired.
3. Rewire `lower_call!` line 1869. **GREEN** — T1, T3, T4, T5, R1, R2
   pass; T2 passes at the `_callee_arg_types`/`_assert_arg_widths_match`
   sub-asserts and at the MethodError-is-gone assertion.

---

## §6 — Regression plan

### 6.1 Byte-identical invariant

Every currently-registered callee (`src/Bennett.jl:163-209`) has method
signature `(UInt64, UInt64, ...)::UInt64` — **verified** by inspecting
`methods(...)` for every entry (see `p6_research_local.md` §6). Therefore:

- Old: `Tuple{(UInt64 for _ in inst.args)...}` — for N args, builds
  `Tuple{UInt64, UInt64, ..., UInt64}` (N UInt64s).
- New: `Tuple{params[2:end]...}` where `params[2:end] == (UInt64, UInt64,
  ..., UInt64)` (N UInt64s).

The two expressions produce the **same concrete Tuple type**, so
`extract_parsed_ir(callee, T)` produces the same `ParsedIR`, `lower(...)`
produces the same `LoweringResult`, and ultimately `bennett(...)` produces
the same `ReversibleCircuit` — every gate, every wire index, byte-identical.

The width-matching assertion is a read-only cross-check: `sizeof(UInt64)*8
== 64` for every arg, and every IRCall emitter today passes
`arg_widths=[64, 64, ...]` (verified by the site enumeration in
p6_research_local.md §2.7 — all widths are `64`). Assertion is a no-op.

### 6.2 Concrete regression spot-checks

Ordered by decreasing confidence the test existed pre-fix:

| # | Test file / invariant | Pre-fix value | Post-fix expectation |
|---|-----------------------|---------------|----------------------|
| 1 | `test/test_increment.jl` — `f(x)=x+Int8(1)` → `gate_count.total` | 100 (4/68/28) — matches BENCHMARKS.md row "x+1 i8" | Unchanged (no IRCall on this path) |
| 2 | `test/test_increment.jl` — `f(x)=x+Int8(1)` T-count | 196 | Unchanged |
| 3 | `test/test_general_call.jl` — `quad(double(x))` | present total | Unchanged (callees are `double` with `(UInt8,)` — still all-scalar, new derivation returns `Tuple{UInt8}` where old returned `Tuple{UInt64}`. See §6.3 for the one careful note.) |
| 4 | `test/test_softfloat.jl` — 1037 soft-float tests | all pass | all pass (every `soft_*` callee is UInt64) |
| 5 | `test/test_float_circuit.jl` — circuits using soft_fadd/fmul/fma | passes | passes |
| 6 | `test/test_persistent_interface.jl` — `_ls_demo(k1,v1,...,lookup)::Int8` — expected 436 gates / 90 Toffoli | matches brief | Unchanged — `_ls_demo` is fully inlined by Julia (p6_research_local.md §4.5), **no IRCall emitted**, so `lower_call!` is never invoked on this path |
| 7 | Full `Pkg.test()` suite | green | green |
| 8 | BENCHMARKS.md entries (`x+1` i8/i16/i32/i64 = 100/204/412/828, `x²+3x+1` i8 = 872, `x*y` i8×i8 = 690, soft_fadd = 95046, soft_fmul = 257822) | listed | Unchanged |
| 9 | Brief's quoted `soft_fma = 447728` | (not in BENCHMARKS.md currently) | Unchanged if it is measurable post-fix via a benchmark harness |

### 6.3 Subtle regression note — `test_general_call.jl` `quad(double(x))`

`double(x::UInt8) = x + x` is called via an IRCall generated by
`ir_extract.jl:1351`. Pre-fix: `arg_types = Tuple{UInt64}`. Post-fix:
`arg_types = Tuple{UInt8}`. These **are different Julia types**, so
`extract_parsed_ir(double, Tuple{UInt8})` and
`extract_parsed_ir(double, Tuple{UInt64})` could conceivably produce
different LLVM IR (the UInt8 version has an 8-bit param, the UInt64 version
has a 64-bit param).

**Impact analysis:**

- Under the old code, `extract_parsed_ir(double, Tuple{UInt64})` would
  presumably fail the MethodError lookup (no `double(::UInt64)` method
  exists). **But the test passes today**, so one of the following must
  be true:
  1. `_ir_extract.jl` never actually emits an IRCall for `double` (it gets
     inlined by Julia before reaching our walker), OR
  2. `double` has been implicitly typed to dispatch on UInt64 somehow.

  The most likely explanation is (1) — Julia inlines small `@inline` / by
  default-inlinable functions straight through, so the LLVM IR of `quad`
  contains no `call` instruction to `double`.

- Either way: if a call *were* to be emitted post-fix, `arg_types =
  Tuple{UInt8}` is the **correct** derivation and `double(x::UInt8)` would
  successfully extract. Pre-fix it would have MethodError'd. So the fix is
  strictly an improvement here.

- **Spot-check action:** run the test suite and compare `gate_count` for
  `quad` pre- and post-fix. Expect byte-identical because no IRCall is
  emitted (as confirmed by the brief's "every existing callee has all-UInt64
  args" assumption — which is about what flows through `lower_call!`, not
  what Julia-level signature the callees have).

### 6.4 Regression command list (for the implementer)

```bash
# Full suite — must stay green.
julia --project -e 'using Pkg; Pkg.test()'

# Fast smoke — single tests:
julia --project test/test_increment.jl
julia --project test/test_general_call.jl
julia --project test/test_softfloat.jl
julia --project test/test_persistent_interface.jl

# Gate-count sanity spot-check:
julia --project -e '
using Bennett
c = reversible_compile(x -> x + Int8(1), Int8)
@assert gate_count(c).total == 100  ("x+1 i8 total regression: ", gate_count(c))
@assert gate_count(c).toffoli == 28 ("x+1 i8 Toffoli regression: ", gate_count(c))
println("OK: x+1 i8 = 100 gates, 28 T")
'
```

---

## §7 — Risk analysis

### R1 — Phi-merged callees

Do any paths produce an IRCall whose `inst.callee` was merged across CFG
branches (i.e. a phi on a Function value)? Answer: **no**. Looking at every
`IRCall(...)` construction:

- `src/lower.jl:1469, 1765-1767, 1790-1792, 2408-2417, 2443-2452, 2494-2535`:
  all bake `inst.callee` as a concrete registered function chosen at
  compile-time based on the caller's instruction pattern.
- `src/ir_extract.jl:1351, 1447, 1455, 1472, 1479, 1520`: all dispatch on a
  specific `_lookup_callee(llvm_name)` hit, not a phi. `llvm_name` is a
  `String` read from the LLVM call's callee operand — never a phi node.

LLVM itself supports indirect calls through a phi'd function pointer. Our
IR extractor would not recognise those as IRCalls today (the lookup only
fires on direct-named calls), so the phi-merged-callee case is
unreachable. **Low risk.**

### R2 — External-IR callees (`extract_parsed_ir_from_ll`/`_from_bc`)

Per p6_research_local.md §5.4: external-IR callees are gated by the
`_lookup_callee` regex (matches `julia_<name>_<NNN>` or `j_<name>_<NNN>`).
An external IR file with a callee named e.g. `my_custom_fn` would not match
the regex and therefore **never emit an IRCall** today. So our fix's
dependency on `methods(inst.callee)` never applies to external-IR callees
— those don't reach `lower_call!`.

If a future PR broadens `_lookup_callee` to match arbitrary names, the
invariant `methods(inst.callee) != []` must still hold — which it does, by
virtue of `_known_callees` being keyed on Julia `Function` objects.
**Low risk.**

### R3 — Assertion false positive

Could `_assert_arg_widths_match` fire on a case that is semantically fine
but width-rounded? Candidates:

- **i1 widening**: some IR emitters widen an i1 condition to i8 when passing
  it to a callee. Today, no registered callee takes an i1 arg. Our check
  uses `sizeof(Bool)*8 = 8` for Bool params (Julia stores Bool as one byte),
  which matches the i8 widening convention. No false positive.
- **Pointer-typed args**: a callee with a `::Ptr{T}` param has
  `sizeof(Ptr{T})*8 = 64` on x86_64 — matches the LLVM `ptr` width. But
  no registered callee takes a pointer. If added in the future, our check
  stays sound because the caller-side width would be 64 too.
- **Float params**: no registered callee takes a `Float32`/`Float64` (all
  soft-float callees take `UInt64` and *interpret* them as float bits).
  Hypothetically, a `f(x::Float32)` callee would have `sizeof(Float32)*8 =
  32`; the IRCall emitter would have computed `arg_widths[1]` from the
  LLVM param width = 32. Match. Sound.

The assertion is conservative: it trips *only* when caller widths actually
disagree with callee storage widths. That's exactly the silent-corruption
condition we want to catch. **Low risk of false positive.**

### R4 — `methods()` non-determinism across Julia versions

`methods(f)` returns a `MethodList`. Iteration order is documented in
`Base.MethodList` but has historically shifted between Julia versions.
Mitigation: we require **exactly one** method (rejecting length >1), so
iteration order is irrelevant. **Zero risk.**

### R5 — Redefinition in REPL

If a user redefines a registered callee in the REPL, `methods(f)` may show
the new method's signature. That is actually the *correct* behaviour —
the new signature is what Julia will compile. **No risk; desired behaviour.**

### R6 — Using `sizeof` on non-concrete types

`sizeof(Any)` throws `ErrorException("Abstract type Any does not have a
definite size.")`. If a callee has an abstractly-typed parameter (`::Any`,
`::Real`, `::Integer`), our assertion will crash with this message. That
is the right fail-loud behaviour — we cannot compile a call through an
abstract param anyway. **Low risk.**

One refinement for error ergonomics: catch the `sizeof` ErrorException and
re-raise with more context. Not strictly necessary for MVP; the raw
`sizeof` error is already informative.

### R7 — `compact=true` vs `compact=false` branches

Both branches call `extract_parsed_ir(inst.callee, arg_types)` at the
top of the function — the fix applies uniformly. No branch-specific
handling needed. **Zero risk.**

### R8 — IRCall emitters in `ir_extract.jl` that pass non-64 widths

Per p6_research_local.md §2.7, IRCall emitters at `ir_extract.jl:1447,
1455, 1472, 1479` for `soft_fptosi` and `soft_sitofp` compute
`[src_w] → dst_w` widths from LLVM. Today `src_w` is typically 64 but
could be any integer width. Since every such callee has a `UInt64` method
param, the assertion WOULD fire for `src_w=32` cases.

**Mitigation check**: inspect those emitters. If any of them emit
`arg_widths=[32]` for a `UInt64` callee, the assertion exposes an
inconsistency — and that's a **latent bug we should want to find**. But
it would fail a currently-passing test, so before flipping the switch the
implementer should:

1. Instrument `lower_call!` to log `(inst.callee, inst.arg_widths)` over
   the whole test suite.
2. Confirm every IRCall has `inst.arg_widths == [64, 64, ...]`.
3. If any differ, those are their own bugs — file issues, don't ship
   the assertion until resolved.

If all widths are 64 (as expected from the research), this risk evaporates.
**Medium risk — mitigated by the instrumentation step in the implementation
sequence.**

### R9 — Method introspection cost

`methods(f)` allocates a `MethodList`. `lower_call!` is called
`O(#IRCalls)` times per compilation. For a large circuit with thousands of
IRCalls (e.g. nested soft-float ops), this adds method-lookup overhead.

Empirically: `methods(soft_fadd)` returns in microseconds. Even 10k
IRCalls is <100ms. **Low risk; no caching needed for MVP.**

If future profiling flags it, memoise `_callee_arg_types` on `callee::Function`
— still narrower than adding a field to `IRCall`.

---

## §8 — Implementation sequence

RED → GREEN → REGRESS. Eight steps, strict ordering.

### Step 1 — Instrument to confirm R8 baseline (research, no commit)

```bash
julia --project -e '
using Bennett
# Patch lower_call! in a dev session to log (callee, arg_widths)
# for every invocation across the test suite.
# Alternatively: grep every IRCall emission site in ir_extract.jl/lower.jl
# and verify arg_widths are all-64.
' 
```

Expected outcome: every IRCall in the suite passes `arg_widths=[64, 64,
...]`. If any don't, stop — file a separate issue and resolve before
ATF4 lands.

### Step 2 — Write the test file (RED)

Create `test/test_atf4_lower_call_nontrivial_args.jl` with the full content
from §5.1. Add the `include(...)` line to `test/runtests.jl`.

Run: `julia --project test/test_atf4_lower_call_nontrivial_args.jl`

Expected: `using Bennett: _callee_arg_types, _assert_arg_widths_match`
line errors — symbols don't exist. **RED confirmed.**

### Step 3 — Add `_callee_arg_types` helper (still RED)

Insert `_callee_arg_types` at the top of the `lower_call!` region in
`src/lower.jl` (immediately before the `function lower_call!(...)` line at
`src/lower.jl:1865`).

Re-run the test: `using` now succeeds, but T1-T5 still fail because
`lower_call!` isn't rewired yet.

### Step 4 — Add `_assert_arg_widths_match` helper (still RED)

Insert `_assert_arg_widths_match` right after `_callee_arg_types`.

Re-run the test: T4 (vararg reject), T5 (multi-method reject), R1
(soft_fma derivation), R2 (arity) should now pass — these call the
helpers directly. T1, T2, T3 still fail (lower_call! not rewired).

### Step 5 — Rewire `lower_call!` (GREEN)

Replace line 1869 in `src/lower.jl`:

```julia
# Old:
arg_types = Tuple{(UInt64 for _ in inst.args)...}
# New:
arg_types = _callee_arg_types(inst.callee, length(inst.args))
_assert_arg_widths_match(inst, arg_types)
```

Re-run the test: expected all of T1-T5, R1, R2 pass. **GREEN confirmed.**

### Step 6 — Run the full suite

```bash
julia --project -e 'using Pkg; Pkg.test()'
```

Expected: all tests pass, including the new file. If any test fails that
didn't before, investigate — likely a case in R8 territory.

### Step 7 — Spot-check gate-count baselines

```bash
julia --project -e '
using Bennett
c1 = reversible_compile(x -> x + Int8(1), Int8)
@assert gate_count(c1).total == 100
@assert gate_count(c1).toffoli == 28
println("OK x+1 i8 = 100 / 28T")
' 
```

### Step 8 — Commit

One commit, per CLAUDE.md §3 and the commit convention:

```
Fix Bennett-atf4: derive lower_call! arg types from methods() not hardcoded UInt64

- src/lower.jl: _callee_arg_types() + _assert_arg_widths_match() helpers;
  lower_call! uses them instead of Tuple{(UInt64 for _ in inst.args)...}.
- test/test_atf4_lower_call_nontrivial_args.jl: RED tests for Int8 scalar
  arg, NTuple aggregate arg (linear_scan_pmap_set, partial — downstream
  sret error is Bennett-0c8o), width-matching assertion, vararg reject,
  multi-method reject, arity reject, soft_fma regression.
- test/runtests.jl: include new file.

Byte-identical output for every existing callee (all have UInt64-only
method sigs, so new derivation == old derivation).

Width-matching assertion closes p6_research_local.md §12.4 latent bug
(silent arg-width misalignment) fail-loud at source.
```

Then `bd close Bennett-atf4` (or push to resolve status per CLAUDE.md
Session Completion).

---

## §9 — Uncertainties explicitly flagged

Per CLAUDE.md §9 "research steps are explicit" and §10 "skepticism":

**U1.** I have not empirically run the full test suite in this design
session — the regression plan in §6 is based on static analysis plus the
research doc. The implementer must confirm in Step 6.

**U2.** The brief cites `soft_fma = 447728` as a BENCHMARKS.md row; my
inspection of `BENCHMARKS.md` shows no `soft_fma` entry. The brief's
number may come from a separate benchmark harness not captured in the
public baselines file. This doesn't affect the fix (soft_fma path is
byte-identical) but the implementer should confirm the number's source
before using it as a regression assertion.

**U3.** Step 1 (instrumentation) assumes `arg_widths == [64, 64, ...]`
universally. If the instrumentation reveals an emitter with non-64 widths
that happens to work today (e.g. `soft_fptosi` with `arg_widths=[32]`
pointing at a `soft_fptosi(::UInt64)` method), the width-matching
assertion would fire and we have a choice:

- Relax the assertion to only fire when the mismatch is semantic
  (e.g. `got > param_bits`).
- Fix the emitter to pad widths to the callee's param width.

Without instrumentation data, I can't pick the right answer. Flag to
implementer: if Step 1 reveals mismatches, file a follow-up bead and
**do not ship the assertion** in the same commit. Ship `_callee_arg_types`
alone first, then resolve the width story separately.

**U4.** `compact=true` with a non-UInt64 callee path is untested. The
fix at line 1869 is the same for both branches, so in principle it works,
but neither the existing test suite nor our new RED test T2 exercises
`compact=true` on a non-UInt64 callee. Follow-up bead: test coverage
for `reversible_compile(..., compact_calls=true)` with aggregate-typed
callees, once Bennett-0c8o lands and aggregate callees actually work
end-to-end.

**U5.** I did not empirically re-run the bead's repro with the proposed
helpers. `_callee_arg_types(linear_scan_pmap_set, 3) === Tuple{NTuple{9,
UInt64}, Int8, Int8}` was verified via a single `julia --project` probe
outside the build; the implementer must confirm in Step 5.

---

## §10 — Summary of changes

| File | Lines added | Lines changed | Lines removed |
|------|-------------|---------------|---------------|
| `src/lower.jl` | ~80 (two helpers + comments) | 1 (line 1869) + 1 (assertion call insert) | 0 |
| `test/test_atf4_lower_call_nontrivial_args.jl` | ~150 (new file) | 0 | 0 |
| `test/runtests.jl` | 1 (include line) | 0 | 0 |

Total: ~230 new lines of code + tests; 1 line of production code changed.

The fix is **minimal**, **byte-identical for existing callees**, and
**unblocks** Bennett's downstream work on aggregate-typed callees
(Bennett-0c8o, `:persistent_tree` arm).
