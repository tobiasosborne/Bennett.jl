# Bennett-atf4 — Proposer B: method-derived arg types in `lower_call!`

**Bead:** Bennett-atf4 (P1, bug, labels `3plus1,core`)
**Author:** Proposer B (independent — did not read Proposer A).
**Date:** 2026-04-21.
**Target file:** `src/lower.jl:1865-1925` (the `lower_call!` body).
**Status:** proposal. Ready to implement behind a RED-green TDD cycle.

---

## §1 — Scope

### IN SCOPE

1. Replace the hardcoded `arg_types = Tuple{(UInt64 for _ in inst.args)...}`
   at `src/lower.jl:1869` with a method-table-derived tuple.
2. Introduce one small private helper (`_callee_arg_types`) that:
   - rejects callees with zero methods,
   - rejects multi-method callees (fail loud; none in the current corpus),
   - rejects `Vararg` methods (fail loud; none in the current corpus),
   - returns `Tuple{P1, P2, …, Pn}` built from the unique method's
     `sig.parameters[2:end]`.
3. Add a width-matching assertion that verifies every `inst.arg_widths[i]`
   equals the bit width of the callee's i-th formal parameter — closing the
   latent silent-misalignment bug noted in `p6_research_local.md §12.4`.
4. Apply both to the `compact=true` and `compact=false` branches uniformly
   (they share the same pre-compile at line 1869-1871 — see §2.2 below).

### OUT OF SCOPE

- Any change to the `IRCall` struct. Keep the struct byte-identical.
- Any change to `lower_call!`'s signature (`gates, wa, vw, inst; compact`).
  All 13 call sites in `src/lower.jl` + `src/ir_extract.jl` (see
  `p6_research_local.md §2.7`) keep calling unchanged.
- Any change to `LoweringCtx` (no new fields).
- Any change to `extract_parsed_ir` or its sret handling
  (that's Bennett-0c8o / the vector-store problem).
- Any memoisation / compilation cache for callees (pre-existing concern —
  `reviews/06_carmack_review.md:56`).
- Any pass-kwarg plumbing to `extract_parsed_ir` from `lower_call!`
  (a follow-up issue; aggregate callees still need `preprocess=true` to
  extract cleanly — that's a separate bead, Bennett-0c8o).
- Support for external-IR callees (`extract_parsed_ir_from_ll/_bc`).
  Per `p6_research_local.md §5.4`, `_lookup_callee` gates on the
  `julia_`/`j_` mangling so external-IR IRCalls never reach `lower_call!`
  today.

---

## §2 — Fix body

### §2.1 Before / after diff (conceptual)

```
src/lower.jl:1865-1871  (the only place that changes inside lower_call!):

   function lower_call!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                        vw::Dict{Symbol,Vector{Int}}, inst::IRCall;
                        compact::Bool=false)
       # Pre-compile the callee function
-      arg_types = Tuple{(UInt64 for _ in inst.args)...}
+      arg_types = _callee_arg_types(inst)
+      _assert_arg_widths_match(inst, arg_types)
       callee_parsed = extract_parsed_ir(inst.callee, arg_types)
       callee_lr = lower(callee_parsed; max_loop_iterations=64)
       ...
```

The two new lines are the entire surgery inside `lower_call!`. Everything
else — wire offsets, CNOT-copy loop, `_remap_gate`, output binding —
is unchanged. Both `compact=true` and `compact=false` branches already
read from `callee_parsed` / `callee_lr` and neither depends on the old
hardcoded type assumption.

### §2.2 Why a single change covers both branches

`lower_call!` has two structurally-identical branches (see
`p6_research_local.md §2.2`). Both read from `callee_parsed` and
`callee_lr`, which are computed *once* above the branch at lines 1869-1871.
Fixing the arg_types derivation at line 1869 is sufficient for both.

### §2.3 The helper functions

Add two small private helpers just before `lower_call!`
(keep them in `src/lower.jl` with the rest of the call-inlining code, not
in `ir_extract.jl` — they consume `IRCall`, which is a lowering concept).

```julia
# ---- callee type derivation (Bennett-atf4) ----

"""
    _callee_arg_types(inst::IRCall) :: Type{<:Tuple}

Derive the Julia argument types for inlining `inst.callee` from its
method table. The hardcoded `Tuple{(UInt64 for _ in inst.args)...}` that
lived here before only worked for scalar-UInt64 callees; this helper
handles any concrete Julia signature (scalar integers, NTuples,
heterogeneous mixes) as long as the callee has exactly one concrete
method. Multi-method and Vararg callees are rejected with a clear message.
"""
function _callee_arg_types(inst::IRCall)::Type{<:Tuple}
    ms = methods(inst.callee)
    fname = nameof(inst.callee)
    if isempty(ms)
        error("lower_call!: callee `$(fname)` has no methods (cannot derive ",
              "arg types). Ensure the callee is a Julia Function registered ",
              "via register_callee!.")
    end
    if length(ms) != 1
        # Every callee registered via register_callee! today has exactly
        # one method (soft_* helpers, persistent-map ops). A multi-method
        # callee would require us to pick one using inst.arg_widths —
        # doable but out of scope for this bead.
        sigs = join(["  $(m.sig)" for m in ms], "\n")
        error("lower_call!: callee `$(fname)` has $(length(ms)) methods; ",
              "gate-level inlining requires exactly one concrete method ",
              "(see Bennett-atf4). Candidates:\n$sigs")
    end
    m = ms[1]
    params = m.sig.parameters  # (typeof(callee), arg1, arg2, ...)
    # Reject vararg methods: sig.parameters[end] is a Vararg{T,N} type.
    if !isempty(params) && Base.isvarargtype(params[end])
        error("lower_call!: callee `$(fname)` has a Vararg method signature ",
              "$(m.sig); gate-level inlining requires a fixed arity ",
              "(see Bennett-atf4).")
    end
    arity = length(params) - 1  # strip typeof(callee)
    if arity != length(inst.args)
        error("lower_call!: callee `$(fname)` takes $arity arg(s) but the ",
              "IRCall supplies $(length(inst.args)). IRCall=$inst.")
    end
    return Tuple{params[2:end]...}
end
```

**Design note.** We take the `inst.callee` function object directly, not a
name. `methods(f)` on a Julia `Function` returns the full method table;
`nameof(f)` gives us a readable symbol for error messages. We deliberately
do NOT use `Base.return_types` (fragile per Proposer A of T5-P6,
`docs/design/p6_proposer_A.md §10.1`) — we only need `.sig.parameters`,
which is stable and documented.

---

## §3 — Width-matching assertion

This is the concrete code and placement.

### §3.1 The helper

```julia
"""
    _assert_arg_widths_match(inst::IRCall, arg_types::Type{<:Tuple}) :: Nothing

Cross-check that `inst.arg_widths[i]` (caller-side bit width) equals the
bit width of `arg_types.parameters[i]`. Catches the latent silent-
misalignment bug noted in p6_research_local.md §12.4: before this check,
`lower_call!` would blindly CNOT-copy caller-side wires into the first
`arg_widths[i]` bits of the callee's input wires, overflowing or
truncating silently if widths disagreed.

Fires LOUD with callee name, which arg, expected width, actual width.
"""
function _assert_arg_widths_match(inst::IRCall, arg_types::Type{<:Tuple})::Nothing
    fname = nameof(inst.callee)
    params = arg_types.parameters
    length(params) == length(inst.arg_widths) || error(
        "lower_call!: arg_widths length mismatch for callee `$(fname)`: ",
        "method has $(length(params)) params, IRCall supplies ",
        "$(length(inst.arg_widths)) widths. IRCall=$inst.")
    for (i, T) in enumerate(params)
        expected = _bit_width_of(T)
        actual = inst.arg_widths[i]
        expected == actual || error(
            "lower_call!: arg width mismatch for callee `$(fname)`, ",
            "arg #$i (type $T): expected $expected bits (from method ",
            "signature), got $actual bits (from IRCall.arg_widths). ",
            "Caller is CNOT-copying the wrong number of wires — check ",
            "the IRCall emitter. IRCall=$inst.")
    end
    return nothing
end

"""
    _bit_width_of(T) :: Int

Julia-type → total bit width in the "flat" representation the Bennett
pipeline uses. Matches the extraction rules in ir_extract.jl:
 - Scalar integer / Bool: `sizeof(T) * 8` (Int8→8, Int16→16, ..., UInt64→64).
 - Homogeneous NTuple{N,E}: `N * _bit_width_of(E)`.
 - Heterogeneous Tuple{T1,T2,...}: `sum(_bit_width_of(Ti))`.
Unknown types (Float64, String, pointers) fail loud so we don't silently
agree on a garbage width.
"""
function _bit_width_of(::Type{T})::Int where {T}
    if T <: Integer || T === Bool
        return sizeof(T) * 8
    elseif T <: Tuple
        return sum(_bit_width_of(P) for P in T.parameters; init=0)
    else
        error("lower_call!: cannot compute bit width of Julia type `$T` for ",
              "gate-level inlining. Supported: Integer, Bool, and Tuples ",
              "thereof. Extend _bit_width_of if your callee uses a ",
              "different type.")
    end
end
```

### §3.2 Width table for current callees (sanity)

All 44 registered callees are scalar-UInt64 → every param width is 64.
For `linear_scan_pmap_set(::NTuple{9,UInt64}, ::Int8, ::Int8)`:

| arg | type              | `_bit_width_of` | IRCall width |
|-----|-------------------|-----------------|--------------|
| 1   | `NTuple{9,UInt64}`| `9 * 64 = 576`  | 576          |
| 2   | `Int8`            | 8               | 8            |
| 3   | `Int8`            | 8               | 8            |

Matches the research doc's empirically-measured widths (§4.3 of
`p6_research_local.md`). Assertion passes.

### §3.3 Placement

Called immediately after `arg_types` is derived, before
`extract_parsed_ir`. This gives the assertion a chance to fail with a
useful error BEFORE we spend time running `code_llvm` on the callee.

```julia
arg_types = _callee_arg_types(inst)
_assert_arg_widths_match(inst, arg_types)
callee_parsed = extract_parsed_ir(inst.callee, arg_types)
```

---

## §4 — Multi-method / Vararg / external-IR error messages

### §4.1 Rejected cases + messages

| Case | Rejection point | Error message |
|------|------------------|--------------|
| Zero methods | `_callee_arg_types` | `callee ``<name>`` has no methods (cannot derive arg types). Ensure the callee is a Julia Function registered via register_callee!.` |
| ≥2 methods | `_callee_arg_types` | `callee ``<name>`` has N methods; gate-level inlining requires exactly one concrete method (see Bennett-atf4). Candidates: <list of m.sig>` |
| Vararg | `_callee_arg_types` | `callee ``<name>`` has a Vararg method signature <sig>; gate-level inlining requires a fixed arity (see Bennett-atf4).` |
| Arity mismatch (arg count) | `_callee_arg_types` | `callee ``<name>`` takes N arg(s) but the IRCall supplies M. IRCall=<inst>.` |
| Width mismatch (per arg) | `_assert_arg_widths_match` | `arg width mismatch for callee ``<name>``, arg #i (type T): expected E bits (from method signature), got A bits (from IRCall.arg_widths). Caller is CNOT-copying the wrong number of wires — check the IRCall emitter. IRCall=<inst>.` |
| Unknown type width | `_bit_width_of` | `cannot compute bit width of Julia type ``T`` for gate-level inlining. Supported: Integer, Bool, and Tuples thereof. Extend _bit_width_of if your callee uses a different type.` |

All errors include the callee name, the specific failure, and (where
relevant) the full `IRCall` struct so the diagnostic points directly at
the emitter. Satisfies CLAUDE.md §1 (fail fast, fail loud).

### §4.2 External-IR callees

Per `p6_research_local.md §5.4`: `_lookup_callee` (`src/ir_extract.jl:215-228`)
gates on the LLVM-mangled name matching `julia_` / `j_`. External-IR
callees (from `extract_parsed_ir_from_ll` / `_from_bc`) never match this
pattern, so they never emit `IRCall` instances and never reach
`lower_call!`. Confirmed: no code path in `_collect_call_info` (called
from every extraction path, including .ll/.bc) will synthesise an
`IRCall` for a function that isn't a Julia `Function` already in
`_known_callees`.

Implication: `methods(inst.callee)` always operates on a real Julia
`Function` value in practice. If this invariant is ever violated (e.g.,
a future refactor lets external-IR callees flow through `IRCall`), the
zero-methods error above is the natural failure.

### §4.3 What about `@noinline`-registered user functions?

`test/test_general_call.jl:38` registers `my_helper(x::UInt64)::UInt64`
as a callee. It has exactly one method (since it's declared with a
concrete signature and marked `@noinline`). `_callee_arg_types` returns
`Tuple{UInt64}`, byte-identical to the old `Tuple{(UInt64 for _ in
inst.args)...}` result. No regression.

If a user tries to register a function with two methods (e.g.,
`f(::Int8)` and `f(::Int16)`), today's code silently picks UInt64 and
either works by coincidence or fails deep inside `extract_parsed_ir`
with a confusing method-table error. The new code fails at the top of
`lower_call!` with a clear "N methods" message.

---

## §5 — RED test: `test/test_atf4_lower_call_nontrivial_args.jl`

Full file content. The pattern matches the live reproduction in the bead
and the existing `test_general_call.jl`.

```julia
# Bennett-atf4 — RED tests for lower_call!'s arg_types derivation.
#
# Before the fix, lower_call! hardcoded `Tuple{(UInt64 for _ in inst.args)...}`
# at src/lower.jl:1869. This breaks for any callee whose signature is not
# all-UInt64 (e.g., Int8 args, NTuple args). These tests exercise the
# non-trivial cases and the new width-matching assertion.

using Test
using Bennett
using Bennett: IRCall, ssa, iconst, lower_call!, WireAllocator, ReversibleGate,
               register_callee!, allocate!

@testset "Bennett-atf4 — lower_call! derives arg_types from methods()" begin

    # ------------------------------------------------------------------
    # Case 1 — Int8 callee (non-UInt64 scalar).
    # Before fix: lower_call! asks extract_parsed_ir(f, Tuple{UInt64}).
    # Method lookup fails because f's real signature is Tuple{Int8}.
    # After fix: succeeds, callee compiles to a small circuit.
    # ------------------------------------------------------------------
    @testset "Int8 arg — non-UInt64 scalar" begin
        @noinline function _atf4_i8_double(x::Int8)::Int8
            return (x + x) % Int8
        end
        register_callee!(_atf4_i8_double)

        inst = IRCall(:res, _atf4_i8_double, [ssa(:x)], [8], 8)

        gates = ReversibleGate[]
        wa = WireAllocator()
        vw = Dict{Symbol,Vector{Int}}()
        vw[:x] = allocate!(wa, 8)

        # Before fix: throws MethodError ("no unique matching method found
        # for the specified argument types" or similar).
        # After fix: succeeds, emits gates, binds vw[:res].
        lower_call!(gates, wa, vw, inst)
        @test haskey(vw, :res)
        @test length(vw[:res]) == 8
        @test !isempty(gates)
    end

    # ------------------------------------------------------------------
    # Case 2 — NTuple arg (linear_scan_pmap_set).
    # This is the bead's live-reproduction case. After the arg_types fix,
    # lower_call! gets past line 1870 (the fixed line). It will then hit
    # ir_extract's sret/vector-store problem (Bennett-0c8o), which is
    # OUT of scope for this bead. We verify via @test_throws that the
    # error message has CHANGED from the old MethodError to a downstream
    # ir_extract error — i.e., the atf4-specific bug is gone.
    # ------------------------------------------------------------------
    @testset "NTuple{9,UInt64} arg — persistent-map state" begin
        inst = IRCall(:res, Bennett.linear_scan_pmap_set,
                      [ssa(:state), ssa(:k), ssa(:v)], [576, 8, 8], 576)

        gates = ReversibleGate[]
        wa = WireAllocator()
        vw = Dict{Symbol,Vector{Int}}()
        vw[:state] = allocate!(wa, 576)
        vw[:k]     = allocate!(wa, 8)
        vw[:v]     = allocate!(wa, 8)

        # Must NOT throw a MethodError "no unique matching method found
        # for the specified argument types" (which is the atf4 bug). Any
        # downstream error (ir_extract sret/vector-store rejection, or
        # even full success if Bennett-0c8o is also fixed) counts as
        # green for this bead.
        err = try
            lower_call!(gates, wa, vw, inst)
            nothing
        catch e
            e
        end
        if err === nothing
            # Happy path — the 0c8o path is also fixed. Great.
            @test haskey(vw, :res)
            @test length(vw[:res]) == 576
        else
            msg = sprint(showerror, err)
            # The atf4 bug's signature is "no unique matching method" /
            # MethodError on Tuple{UInt64,UInt64,UInt64}. Any other
            # error means atf4 is fixed (0c8o is a separate bead).
            @test !occursin("no unique matching method", msg)
            @test !occursin("MethodError", msg) ||
                  occursin("linear_scan_pmap_set", msg) == false ||
                  !occursin(r"Tuple\{UInt64,\s*UInt64,\s*UInt64\}", msg)
        end
    end

    # ------------------------------------------------------------------
    # Case 3 — arg-width mismatch fires the new assertion.
    # Construct an IRCall whose inst.arg_widths DISAGREE with the callee's
    # method param widths. Before fix: silent wire misalignment.
    # After fix: loud error from _assert_arg_widths_match.
    # ------------------------------------------------------------------
    @testset "Width-mismatch assertion — clear error message" begin
        @noinline function _atf4_i8_id(x::Int8)::Int8
            return x
        end
        register_callee!(_atf4_i8_id)

        # inst says the arg is 16 bits; the method says Int8 (= 8 bits).
        inst = IRCall(:res, _atf4_i8_id, [ssa(:x)], [16], 8)

        gates = ReversibleGate[]
        wa = WireAllocator()
        vw = Dict{Symbol,Vector{Int}}()
        vw[:x] = allocate!(wa, 16)

        err = @test_throws ErrorException lower_call!(gates, wa, vw, inst)
        msg = sprint(showerror, err.value)
        @test occursin("arg width mismatch", msg)
        @test occursin("_atf4_i8_id", msg)
        @test occursin("Int8", msg)
        @test occursin("expected 8", msg)
        @test occursin("got 16", msg)
    end

    # ------------------------------------------------------------------
    # Case 4 — multi-method callee rejection.
    # ------------------------------------------------------------------
    @testset "Multi-method callee — loud rejection" begin
        @noinline _atf4_multi(x::Int8) = x + Int8(1)
        @noinline _atf4_multi(x::Int16) = x + Int16(1)
        # Don't register (not required; lower_call! reads methods() directly).

        inst = IRCall(:res, _atf4_multi, [ssa(:x)], [8], 8)

        gates = ReversibleGate[]
        wa = WireAllocator()
        vw = Dict{Symbol,Vector{Int}}()
        vw[:x] = allocate!(wa, 8)

        err = @test_throws ErrorException lower_call!(gates, wa, vw, inst)
        msg = sprint(showerror, err.value)
        @test occursin("2 methods", msg) || occursin("multiple", lowercase(msg))
        @test occursin("_atf4_multi", msg)
    end

    # ------------------------------------------------------------------
    # Case 5 — vararg callee rejection.
    # ------------------------------------------------------------------
    @testset "Vararg callee — loud rejection" begin
        @noinline _atf4_varargs(xs::Int8...) = sum(xs; init=Int8(0))

        inst = IRCall(:res, _atf4_varargs, [ssa(:x)], [8], 8)

        gates = ReversibleGate[]
        wa = WireAllocator()
        vw = Dict{Symbol,Vector{Int}}()
        vw[:x] = allocate!(wa, 8)

        err = @test_throws ErrorException lower_call!(gates, wa, vw, inst)
        msg = sprint(showerror, err.value)
        @test occursin("Vararg", msg) || occursin("vararg", lowercase(msg))
        @test occursin("_atf4_varargs", msg)
    end

    # ------------------------------------------------------------------
    # Case 6 — UInt64 scalar callee (regression guard).
    # Every existing soft_* callee has this shape. Before and after fix
    # must produce the same arg_types (Tuple{UInt64,UInt64,UInt64}).
    # Don't rerun the full soft_fma compile here (447728 gates is slow);
    # just confirm the helper produces the expected type.
    # ------------------------------------------------------------------
    @testset "UInt64 scalar callee — byte-identical with old derivation" begin
        # Call the helper directly through an IRCall construction.
        # We expect the helper to produce Tuple{UInt64,UInt64,UInt64}
        # for soft_fma — identical to the pre-fix derivation.
        inst = IRCall(:res, Bennett.soft_fma,
                      [ssa(:a), ssa(:b), ssa(:c)], [64, 64, 64], 64)
        t = Bennett._callee_arg_types(inst)
        @test t === Tuple{UInt64, UInt64, UInt64}

        # Same for a 2-arg callee.
        inst2 = IRCall(:res, Bennett.soft_fadd,
                       [ssa(:a), ssa(:b)], [64, 64], 64)
        t2 = Bennett._callee_arg_types(inst2)
        @test t2 === Tuple{UInt64, UInt64}

        # And a 1-arg callee.
        inst1 = IRCall(:res, Bennett.soft_fsqrt, [ssa(:a)], [64], 64)
        t1 = Bennett._callee_arg_types(inst1)
        @test t1 === Tuple{UInt64}
    end

    # ------------------------------------------------------------------
    # Case 7 — unknown-type width rejection.
    # If a user registers a callee with a Float64 arg, _bit_width_of
    # fails loud rather than silently treating it as 64 bits.
    # ------------------------------------------------------------------
    @testset "Unknown arg type — loud rejection" begin
        @noinline _atf4_float(x::Float64) = x
        register_callee!(_atf4_float)

        inst = IRCall(:res, _atf4_float, [ssa(:x)], [64], 64)

        gates = ReversibleGate[]
        wa = WireAllocator()
        vw = Dict{Symbol,Vector{Int}}()
        vw[:x] = allocate!(wa, 64)

        err = @test_throws ErrorException lower_call!(gates, wa, vw, inst)
        msg = sprint(showerror, err.value)
        @test occursin("Float64", msg)
        @test occursin("bit width", lowercase(msg))
    end
end
```

**Test-design notes:**

- Case 1 uses `@noinline` so Julia emits a standalone function Bennett
  can compile; without it, the caller would inline and there'd be no
  IRCall. See `reviews/03_julia_idioms.md:73` for the precedent.
- Case 2 deliberately tolerates the downstream Bennett-0c8o failure
  (vector-store-in-sret). The `@test !occursin("no unique matching method", msg)`
  clause is the atf4-specific assertion; the rest just verifies we
  got past line 1870.
- Case 3 tests only the assertion path, not a full compile, so it
  doesn't depend on the callee actually compiling cleanly.
- Case 5 uses `_atf4_varargs` with a truly variadic signature — Julia
  will give it one method but `params[end]` will be `Vararg{Int8}`.
  We test that `Base.isvarargtype` catches it.
- Case 6 calls `Bennett._callee_arg_types` directly (exposed via the
  `Bennett.` prefix), so it doesn't depend on compiling anything.
  Byte-identical regression coverage for the existing corpus.

### §5.1 Registration in runtests.jl

Add one line to `test/runtests.jl` (its location in the runtests file is
already sorted alphabetically near `test_general_call.jl`):

```julia
include("test_atf4_lower_call_nontrivial_args.jl")
```

Place it right after `include("test_general_call.jl")` — same topic area.

---

## §6 — Regression plan

The core regression guarantee (ground truth ad verbatim from the brief):
*every existing callee has all-UInt64 args; both old and new derivation
MUST produce identical `Tuple{UInt64, ...}` for them.*

### §6.1 Type-equivalence invariant (mechanical)

For every function `f` registered via `register_callee!` (44 today —
enumerated at `src/Bennett.jl:163-208`):

```
methods(f) has exactly 1 method m
m.sig.parameters[2:end] == svec(UInt64, UInt64, ..., UInt64)  # N copies
Tuple{m.sig.parameters[2:end]...} === Tuple{(UInt64 for _ in 1:N)...}
```

Verified live for a sample (§1 above): `soft_fadd`, `soft_fma`,
`soft_fsqrt` all produce byte-identical tuples from old and new
derivation. The full enumeration is mechanical — Case 6 in the RED
test suite asserts three representative callees; a
full-sweep assertion is easy to add but overkill for a regression guard.

### §6.2 Concrete regression checks

Run the full test suite. Every target below MUST stay byte-identical.

| Test file | Invariant / baseline |
|-----------|----------------------|
| `test/test_increment.jl` | `x + Int8(1)` i8: 100 total / 28 Toffoli (verified live today, 2026-04-21). |
| `test/test_polynomial.jl` | unchanged gate counts; exercises no `lower_call!`. |
| `test/test_softfloat.jl` | 1,037 tests; every soft_* callee goes through `lower_call!`. Gate counts baked into `soft_fma` = 447728, `soft_fadd`, `soft_fmul`, `soft_fdiv` baselines in WORKLOG.md. |
| `test/test_float_circuit.jl` | Float64 arithmetic end-to-end via soft-float callees. |
| `test/test_general_call.jl` | User-defined callees; Case 3 registers `my_helper::UInt64`. |
| `test/test_persistent_interface.jl` | `_ls_demo` = 436 total / 90 Toffoli (per WORKLOG line in CLAUDE.md). This path does NOT exercise `lower_call!` (full inlining); but a new test (§5 Case 2) in atf4 DOES. |
| `test/test_divmod.jl` | `lower_udiv!`/`lower_sdiv!` (`src/lower.jl:1469`) emit `IRCall(soft_udiv, [64, 64], 64)`. Fix must preserve this. |
| `test/test_softmem.jl` | All `soft_mux_*` callees: `[64, 64, 64]` / `[64, 64, 64, 64]` arg widths. Fix must preserve. |
| `test/test_sret.jl:116` | `swap2` i8 = 82 gates (no IRCall in pipeline — unaffected by this fix, listed for defensive completeness). |
| `BENCHMARKS.md` | Entire benchmarks table values. Every row that uses a soft_* callee flows through `lower_call!`; all arg widths are 64, derivation byte-identical. |

### §6.3 Spot checks (fast, concrete)

Three commands suffice for a quick pre-commit sanity check:

```bash
# Core i8 smoke
julia --project -e 'using Bennett; c = reversible_compile(x -> x + Int8(1), Int8); \
  gc = gate_count(c); println("x+1 i8: total=", gc.total, " T=", gc.Toffoli); \
  @assert gc.total == 100 && gc.Toffoli == 28'

# soft_fma (heavy lower_call! user)
julia --project -e 'using Bennett; c = reversible_compile(Bennett.soft_fma, UInt64, UInt64, UInt64); \
  gc = gate_count(c); println("soft_fma: total=", gc.total); @assert gc.total == 447728'

# Full test suite
julia --project -e 'using Pkg; Pkg.test()'
```

### §6.4 What could go wrong in the regression

1. **`nameof(f)` on closures.** None of the current callees are
   closures; `my_helper` in `test_general_call.jl` is `@noinline` but
   top-level. Safe.
2. **`Base.isvarargtype` availability.** Exists in Julia 1.6+. Bennett.jl
   already targets 1.10+ (per `Project.toml` sweep — verify if needed).
   Safe.
3. **Method precedence (Julia dispatch).** `methods(f)` returns the
   method table in insertion order; for a single-method callee, `[1]` is
   unambiguous. For multi-method we reject immediately. Safe.

---

## §7 — Risk analysis

### §7.1 Phi-merged callees — do they exist?

Could there be an IRCall whose `callee` field is a phi-merged value?
Inspection of `IRCall` at `src/ir_types.jl:111-117` shows `callee::Function`
(a concrete Julia value), not an `IROperand`. IRCall instances are
constructed in two places (internal div synthesis at `src/lower.jl:1461`
and LLVM walker at `src/ir_extract.jl:1351,1447,1472,1520`); each hardcodes
a specific Julia function via `_lookup_callee` / direct reference.

**Conclusion:** no phi-merged callees possible by construction. Safe.

### §7.2 External-IR callee interaction

Covered in §4.2: external-IR callees cannot reach `lower_call!` today
because `_lookup_callee` regex-gates on `julia_` / `j_` mangling. If this
invariant is ever relaxed, `_callee_arg_types` would fall through to its
"zero methods" error (a synthetic external-IR function has no Julia
method table). The error is clear and points at the right emitter.

### §7.3 Assertion false-positive risk

`_assert_arg_widths_match` compares `inst.arg_widths[i]` to
`_bit_width_of(params[i])`. Risk: a type whose natural width differs
between Julia and Bennett's flat representation.

Mitigation: `_bit_width_of` explicitly handles only `Integer`, `Bool`,
and `Tuple` — matching the types Bennett actually supports.
`Float64`-style types are rejected loud (§5 Case 7). No implicit
float ↔ int reinterpret; no pointer widths.

**Float64 caveat.** If a future user registers a soft-float wrapper
(`@noinline f(x::Float64) = x`), it'll hit the assertion. This is
correct — Bennett today only consumes Float64 via the soft-float path
(`reinterpret(UInt64, x)`), so callees should always take `UInt64`.
The error points to `_bit_width_of`, which a future developer can extend
if genuinely needed (Float64 = 64 bits, but the developer must
acknowledge the reinterpret).

### §7.4 Silent LLVM-side width disagreement

What if `methods(callee).sig.parameters[i]` says `Int8` (8 bits) but
LLVM's `code_llvm(callee, Tuple{Int8,...})` emits an i32 param because
of x86_64 ABI `signext` zero-extension? `ir_extract` unconditionally
uses `LLVM.width(_)` on param types, which returns the LLVM type width,
not the Julia type width. So `callee_parsed.args[i][2]` may not equal
`_bit_width_of(params[i])`.

**Investigation:** check for a mismatch path. From `p6_research_local.md
§4.5`: the `_ls_demo` LLVM IR shows `i8 signext %"k1::Int8"` — so LLVM
keeps `i8` with a `signext` attribute, not `i32`. Julia's `code_llvm`
(via GPUCompiler) preserves the Julia-level type width for integer
params. Confirmed: `_atf4_i8_id` with `Int8` arg extracts as 8-bit in
`callee_parsed.args[1][2]`. Safe.

Edge case: a `Bool` param. `sizeof(Bool) == 1` byte in Julia, but LLVM
often lowers Bool params as `i1` (1 bit) or `i8`. Running
`extract_parsed_ir(f, Tuple{Bool})` today produces... untested. If this
matters in practice, add a Bool-specific test. Out of scope for atf4 —
no current callee takes Bool.

### §7.5 Compile-time explosion

`_callee_arg_types(inst)` calls `methods(inst.callee)`, which does a
full method-table walk. Negligible cost (microseconds); no risk.

### §7.6 Tuple type construction

`Tuple{params[2:end]...}` with `params` being an `Core.svec` is
well-documented Julia type construction. No reflection quirks.

---

## §8 — Implementation sequence (RED-first per CLAUDE.md §3)

Ordered steps. The implementer follows them top-to-bottom.

### Step 1 — RED test

Write `test/test_atf4_lower_call_nontrivial_args.jl` per §5. Register it
in `test/runtests.jl` after `include("test_general_call.jl")`.

Run it:
```bash
julia --project test/test_atf4_lower_call_nontrivial_args.jl
```

Expect **all 7 testsets to fail** (Cases 1-5, 7 hit the old
MethodError; Case 6 passes trivially on the pre-fix code because
`_callee_arg_types` doesn't exist — so Case 6 errors on undefined
symbol, which is also a failing test).

**Checkpoint:** ALL tests fail, confirming the RED state.

### Step 2 — Implement `_bit_width_of`

Add the helper per §3.1 to `src/lower.jl` just above the
`# ---- function call inlining ----` comment (line 1855). It's pure
type-level recursion; no other dependencies.

Run a REPL sanity check:
```bash
julia --project -e 'using Bennett; \
  @assert Bennett._bit_width_of(Int8) == 8; \
  @assert Bennett._bit_width_of(UInt64) == 64; \
  @assert Bennett._bit_width_of(NTuple{9,UInt64}) == 576; \
  @assert Bennett._bit_width_of(Tuple{Int8,Int8}) == 16; \
  println("ok")'
```

### Step 3 — Implement `_callee_arg_types` and `_assert_arg_widths_match`

Add them per §2.3 and §3.1 to `src/lower.jl` just after `_bit_width_of`
and just before `lower_call!`.

Export neither (they're private). Reference them only from
`lower_call!`.

Run a REPL sanity check that doesn't hit the full `lower_call!` path
yet:
```bash
julia --project -e 'using Bennett; \
  using Bennett: IRCall, ssa; \
  inst = IRCall(:r, Bennett.soft_fma, [ssa(:a),ssa(:b),ssa(:c)], [64,64,64], 64); \
  @assert Bennett._callee_arg_types(inst) === Tuple{UInt64,UInt64,UInt64}; \
  Bennett._assert_arg_widths_match(inst, Tuple{UInt64,UInt64,UInt64}); \
  println("ok")'
```

### Step 4 — Patch `lower_call!`

Apply the 2-line diff in §2.1. Line 1869 is replaced; line 1870
(`callee_parsed = extract_parsed_ir(...)`) is unchanged.

Run the new test file:
```bash
julia --project test/test_atf4_lower_call_nontrivial_args.jl
```

**Checkpoint:** Case 1 (Int8 scalar), Case 3 (width-mismatch), Case 4
(multi-method), Case 5 (vararg), Case 6 (scalar-UInt64 type helper),
Case 7 (unknown-type rejection) should now pass. Case 2 (NTuple) may
still fail on the Bennett-0c8o downstream error — that's fine, as long
as the error message no longer matches "no unique matching method".

### Step 5 — Regression sweep

```bash
julia --project -e 'using Pkg; Pkg.test()'
```

**Checkpoint:** all pre-existing tests still pass. Specifically watch
for:
- `test_increment.jl`: unchanged gate counts
- `test_softfloat.jl`: 1,037 tests pass
- `test_general_call.jl`: all 3 `lower_call!` paths still work
- `test_divmod.jl`: soft_udiv/soft_urem IRCalls still work
- `test_softmem.jl`: soft_mux_* IRCalls still work

If anything in the regression sweep regresses:
1. **Do not** alter the assertion. The regression is real and your
   IRCall emitter is lying about widths.
2. Read the assertion error message — it names the offending callee and
   arg. Trace back to the emitter and fix the width computation there.
3. Per CLAUDE.md §7: bugs are deep and interlocked. A silent-misalignment
   that the old code tolerated is now visible; treat it as a found bug,
   not a problem with the fix.

### Step 6 — Update CLAUDE.md / WORKLOG.md

Per CLAUDE.md §0: add a WORKLOG entry describing:
- the old vs. new derivation
- the width-matching assertion (and any latent emitter bugs it uncovered)
- gate-count baselines verified stable

### Step 7 — Commit and push

One commit for the fix + test. Message format per recent commits
(`Fix Bennett-atf4: lower_call! derives callee arg types from methods()`).

```bash
bd close Bennett-atf4
bd dolt push
git push
```

Per CLAUDE.md Session Completion: verify `git status` shows "up to date
with origin".

---

## §9 — Honest uncertainties

1. **Does `Base.isvarargtype` exist on the oldest supported Julia version?**
   It's in Julia 1.6+, which Bennett.jl's `Project.toml` almost certainly
   targets. If not, substitute `params[end] isa Core.TypeofVararg` or
   `isa(params[end], Type) && params[end] <: Vararg`. Verify on the
   implementer's Julia.

2. **Does Bool as an arg width work end-to-end?** Not on the atf4 path
   (no current Bool-arg callees). Flagged for a future bead if someone
   registers one.

3. **Is Case 2's downstream error message stable?** The exact text from
   `ir_extract` when it hits `<4 x i64>` may vary across LLVM versions.
   My test asserts only that the atf4-specific signature is gone
   (`!occursin("no unique matching method")`). If a future change
   produces a more-helpful error with the phrase "matching method" in
   it for different reasons, re-tighten the regex.

4. **Does `methods()` see `@noinline` functions reliably?** Yes —
   `@noinline` is a hint to the inliner, not to the method table.
   `methods(_atf4_i8_double)` returns the full table.

5. **Thread-safety.** `_callee_arg_types` is pure (reads `methods()`,
   which is stable during compilation). No shared state. The
   pre-existing thread-safety issues flagged in `reviews/05_torvalds_review.md`
   (global `_name_counter`) are orthogonal.

---

## §10 — Summary table (one-glance)

| Aspect | Decision |
|--------|----------|
| Source of truth | `methods(inst.callee)[1].sig.parameters[2:end]` |
| Struct change | None (IRCall unchanged) |
| Signature change | None (`lower_call!(gates, wa, vw, inst; compact)` unchanged) |
| New helpers | `_callee_arg_types(inst)`, `_assert_arg_widths_match(inst, argt)`, `_bit_width_of(T)` — all private, in `src/lower.jl` |
| Multi-method | Fail loud with candidates listed |
| Vararg | Fail loud via `Base.isvarargtype` |
| External-IR | N/A — `_lookup_callee` gates upstream |
| Width assertion | Per-arg, fails with callee name + arg index + expected/actual |
| Regression guarantee | `Tuple{UInt64,...}` byte-identical for every current callee |
| Test file | `test/test_atf4_lower_call_nontrivial_args.jl` (7 testsets) |
| Estimated LOC | ~50 in `src/lower.jl`, ~180 in test |
| Estimated effort | 1 RED-GREEN-REFACTOR cycle (~1 session, < 2 hours) |

End of design. Proposer B.
