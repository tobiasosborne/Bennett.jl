# Bennett-atf4 Consensus — `lower_call!` derives arg types from `methods()`

**Bead**: Bennett-atf4. Labels: `3plus1,core`.
**Date**: 2026-04-21.
**Inputs**: `docs/design/alpha_proposer_A.md` (975 lines), `docs/design/alpha_proposer_B.md` (~500 lines).
**R8 instrumentation**: verified empirically — zero mismatches across representative compilations. Assertion is safe to ship.

---

## 1. Chosen design — tight convergence, minor picks

A and B converged on essentially identical designs. Picks:

| Question | Choice | Rationale |
|---|---|---|
| Helper signature | `_callee_arg_types(inst::IRCall)` (B's style) — not `(callee, n_caller_args)` (A's style) | B's API is cleaner: one argument, all validation internal. Arity is implicit from `length(inst.args)`. |
| Width derivation | `sizeof(T) * 8` directly on the Julia param type (A's approach) — not recursive tuple-element sum (B's `_bit_width_of`) | `sizeof(NTuple{9,UInt64}) == 72` → 576 bits matches LLVM's `dereferenceable(72)` view. Padded heterogeneous tuples (e.g. `Tuple{Int8, Int64}` = 16 bytes with padding) also match LLVM's view via `sizeof`. Recursive sum would diverge on padded tuples. Keep it simple. |
| Helper placement | In `src/lower.jl`, just above `lower_call!` (both agree) | IRCall is a lowering concept, belongs here. |
| Multi-method reject | Fail loud, enumerate signatures (both agree) | No current callee has >1 method. Extension is a design change, not silent. |
| Vararg reject | Use `Base.isvarargtype(params[end])` (both agree) | No current callee is vararg. |
| Zero-method reject | Fail loud (both agree) | Sanity for non-Function registration. |
| Arity mismatch reject | Fail loud (both agree) | Caller-side miswiring canary. |
| Abstract param type | Let `sizeof` error with its native message (both agree) | Right fail-loud behaviour; we can't compile through abstract types anyway. |

### R8 resolution (empirical)

Proposer A flagged R8 (medium risk): IRCall emitters in `ir_extract.jl` at 1447/1455/1472/1479/1520 might pass non-64 widths against UInt64 callees, tripping the new assertion on existing tests. I ran the probe across a representative compilation suite:

```
reversible_compile(x -> x + Int8(1), Int8)
reversible_compile((x, y) -> x * y, Int8, Int8)
reversible_compile((x, y) -> div(x, y), UInt64, UInt64)
reversible_compile((x, y) -> rem(x, y), UInt64, UInt64)
reversible_compile((x) -> soft_fadd(x, x), UInt64)
reversible_compile((x, y) -> soft_fma(x, y, y), UInt64, UInt64)
reversible_compile((a, b) -> soft_fcmp_olt(a, b), UInt64, UInt64)
```

**Zero mismatches.** Every IRCall emitter passes `arg_widths=[64,...]` against UInt64 callees. Assertion is safe to ship in the same commit as the helpers.

---

## 2. Code — final consensus

### `src/lower.jl` — two helpers + 2-line patch

Place the helpers immediately above `lower_call!` (currently at `src/lower.jl:1865`).

```julia
# ---- Bennett-atf4: method-derived callee arg types ----

"""
    _callee_arg_types(inst::IRCall) -> Type{<:Tuple}

Derive the callee's concrete Julia argument Tuple type from its method table.

Replaces the old `Tuple{(UInt64 for _ in inst.args)...}` hardcode that only
worked for scalar-UInt64 callees (all 44 registered today). This path
handles any concrete signature — scalar integers, NTuples, heterogeneous
mixes — as long as the callee has exactly one concrete method.

Fail-loud rejects:
  - zero-method callee (non-Function registered, or method redefined away)
  - multi-method callee (MVP scope)
  - Vararg method (MVP scope)
  - arity mismatch vs `length(inst.args)` (caller-side miswiring)

See docs/design/alpha_consensus.md + docs/design/p6_research_local.md §2.
"""
function _callee_arg_types(inst::IRCall)::Type{<:Tuple}
    ms = methods(inst.callee)
    fname = nameof(inst.callee)
    if isempty(ms)
        error("lower_call!: callee `$(fname)` has no methods (cannot derive " *
              "arg types). Ensure the callee is a Julia Function registered " *
              "via register_callee!. (Bennett-atf4)")
    end
    if length(ms) != 1
        sigs = join(["  $(m.sig)" for m in ms], "\n")
        error("lower_call!: callee `$(fname)` has $(length(ms)) methods; " *
              "gate-level inlining requires exactly one concrete method " *
              "(Bennett-atf4 MVP). Candidates:\n$sigs")
    end
    m = first(ms)
    params = m.sig.parameters  # (typeof(callee), arg1, arg2, ...)
    if !isempty(params) && Base.isvarargtype(params[end])
        error("lower_call!: callee `$(fname)` has a Vararg method signature " *
              "$(m.sig); gate-level inlining requires fixed arity " *
              "(Bennett-atf4 MVP).")
    end
    arity = length(params) - 1
    if arity != length(inst.args)
        error("lower_call!: callee `$(fname)` method arity = $arity but " *
              "IRCall supplies $(length(inst.args)) arg(s). " *
              "Method signature: $(m.sig). This is caller-side miswiring " *
              "— check the IRCall emitter. (Bennett-atf4)")
    end
    return Tuple{params[2:end]...}
end

"""
    _assert_arg_widths_match(inst::IRCall, arg_types::Type{<:Tuple}) -> Nothing

Cross-check that each `inst.arg_widths[i]` equals `sizeof(T_i) * 8` where
`T_i` is the i-th callee method param type. Closes the latent
silent-misalignment bug noted in docs/design/p6_research_local.md §12.4:
if caller widths disagree with callee storage widths, the CNOT-copy loop
at src/lower.jl:1882-1913 silently overflows/truncates.

Empirically a no-op for every currently-registered callee (all UInt64 scalar
args, all IRCall emitters pass `arg_widths=[64,...]` — verified via R8
instrumentation probe 2026-04-21). The assertion unblocks NTuple-aggregate
callees cleanly and catches future emitter bugs at source.
"""
function _assert_arg_widths_match(inst::IRCall, arg_types::Type{<:Tuple})::Nothing
    fname = nameof(inst.callee)
    params = arg_types.parameters
    length(params) == length(inst.arg_widths) || error(
        "lower_call!: arg_widths length mismatch for callee `$(fname)`: " *
        "method has $(length(params)) params, IRCall supplies " *
        "$(length(inst.arg_widths)) width(s). (Bennett-atf4)")
    for (i, T) in enumerate(params)
        # sizeof(T)*8 matches LLVM's dereferenceable(N) attribute for
        # aggregate types (inc. NTuples), and matches the scalar integer
        # widths Julia reports. Abstract types fail loud via sizeof itself.
        expected = sizeof(T) * 8
        actual = inst.arg_widths[i]
        expected == actual || error(
            "lower_call!: arg width mismatch for callee `$(fname)` " *
            "arg #$i (type $T): expected $expected bits (from method " *
            "signature), got $actual bits (from IRCall.arg_widths). " *
            "This is an IRCall-emitter bug — the caller computed widths " *
            "inconsistent with the callee's Julia method signature. " *
            "(Bennett-atf4)")
    end
    return nothing
end
```

### Patch to `lower_call!` body

At `src/lower.jl:1868–1870`, replace:

```julia
    # Pre-compile the callee function
    arg_types = Tuple{(UInt64 for _ in inst.args)...}
    callee_parsed = extract_parsed_ir(inst.callee, arg_types)
```

with:

```julia
    # Pre-compile the callee function. Bennett-atf4: arg types derived from
    # methods(), not hardcoded UInt64 — unblocks aggregate callees like
    # linear_scan_pmap_set(::NTuple{9,UInt64}, ::Int8, ::Int8).
    arg_types = _callee_arg_types(inst)
    _assert_arg_widths_match(inst, arg_types)
    callee_parsed = extract_parsed_ir(inst.callee, arg_types)
```

Three lines added, one removed. Covers both `compact=true` and `compact=false`
branches uniformly.

---

## 3. RED test — `test/test_atf4_lower_call_nontrivial_args.jl`

Seven testsets. T2 tolerates the downstream Bennett-0c8o sret error (expected
behaviour until β lands).

```julia
using Test
using Bennett
using Bennett: IRCall, IROperand, ssa, iconst, lower_call!, WireAllocator,
               ReversibleGate, allocate!, register_callee!
using Bennett: _callee_arg_types, _assert_arg_widths_match

@testset "Bennett-atf4 lower_call! non-trivial arg types" begin

    # T1: Int8 scalar arg — hardcoded UInt64 assumption broken
    @testset "T1: Int8 scalar callee compiles" begin
        int8_identity(x::Int8)::Int8 = x
        register_callee!(int8_identity)

        inst = IRCall(:res, int8_identity, [ssa(:x)], [8], 8)
        gates = ReversibleGate[]
        wa = WireAllocator()
        vw = Dict{Symbol, Vector{Int}}()
        vw[:x] = allocate!(wa, 8)

        @test_nowarn lower_call!(gates, wa, vw, inst)
        @test haskey(vw, :res)
        @test length(vw[:res]) == 8
    end

    # T2: NTuple aggregate arg (linear_scan_pmap_set) — the bead's live repro
    @testset "T2: NTuple{9,UInt64} arg gets past line 1870" begin
        inst = IRCall(:res, Bennett.linear_scan_pmap_set,
                      [ssa(:state), ssa(:k), ssa(:v)],
                      [576, 8, 8], 576)

        # Sub-assert: helper derives the right type.
        T = _callee_arg_types(inst)
        @test T === Tuple{NTuple{9,UInt64}, Int8, Int8}

        # Sub-assert: width-match assertion passes.
        @test _assert_arg_widths_match(inst, T) === nothing

        # Full call — must not MethodError-at-1870. Downstream sret error
        # is Bennett-0c8o/uyf9 territory; we accept it here.
        gates = ReversibleGate[]
        wa = WireAllocator()
        vw = Dict{Symbol, Vector{Int}}()
        vw[:state] = allocate!(wa, 576)
        vw[:k]     = allocate!(wa, 8)
        vw[:v]     = allocate!(wa, 8)

        err_msg = try
            lower_call!(gates, wa, vw, inst)
            ""
        catch e
            sprint(showerror, e)
        end
        @test !occursin("no unique matching method found", err_msg)
        if !isempty(err_msg)
            @test occursin("sret", err_msg) ||
                  occursin("VectorType", err_msg) ||
                  occursin("memcpy", err_msg)
        end
    end

    # T3: width-matching assertion fires with clear context
    @testset "T3: arg-width mismatch fires loud" begin
        # soft_fma takes (UInt64, UInt64, UInt64); we send bogus 32 in slot 2.
        inst = IRCall(:res, Bennett.soft_fma,
                      [ssa(:a), ssa(:b), ssa(:c)],
                      [64, 32, 64],   # bogus 32
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
        @test occursin("arg width mismatch", msg)
        @test occursin("#2", msg)
        @test occursin("32", msg)
        @test occursin("UInt64", msg)
        @test occursin("soft_fma", msg)
    end

    # T4: vararg callee rejected
    @testset "T4: vararg callee rejected" begin
        vararg_stub(a::UInt64, rest::UInt64...) = a
        @test Base.isvarargtype(first(methods(vararg_stub)).sig.parameters[end])

        inst = IRCall(:res, vararg_stub, [ssa(:a), ssa(:b)], [64, 64], 64)
        e = try
            _callee_arg_types(inst)
            nothing
        catch ex
            ex
        end
        @test e isa ErrorException
        @test occursin("Vararg", sprint(showerror, e))
    end

    # T5: multi-method callee rejected
    @testset "T5: multi-method callee rejected" begin
        multimethod_stub(x::UInt64) = x
        multimethod_stub(x::UInt64, y::UInt64) = x + y
        @test length(methods(multimethod_stub)) == 2

        inst = IRCall(:res, multimethod_stub, [ssa(:x)], [64], 64)
        e = try
            _callee_arg_types(inst)
            nothing
        catch ex
            ex
        end
        @test e isa ErrorException
        msg = sprint(showerror, e)
        @test occursin("2 methods", msg)
    end

    # R1: regression — soft_fma still derives Tuple{UInt64, UInt64, UInt64}
    @testset "R1: soft_fma derivation unchanged" begin
        inst = IRCall(:res, Bennett.soft_fma,
                      [ssa(:a), ssa(:b), ssa(:c)], [64, 64, 64], 64)
        T = _callee_arg_types(inst)
        @test T === Tuple{UInt64, UInt64, UInt64}
    end

    # R2: arity mismatch rejected
    @testset "R2: arity mismatch rejected" begin
        inst = IRCall(:res, Bennett.soft_fma, [ssa(:a), ssa(:b)], [64, 64], 64)
        e = try
            _callee_arg_types(inst)
            nothing
        catch ex
            ex
        end
        @test e isa ErrorException
        msg = sprint(showerror, e)
        @test occursin("arity", msg)
        @test occursin("3", msg)
        @test occursin("2", msg)
    end
end
```

---

## 4. Regression plan

Every existing callee is UInt64-only, so old and new derivation produce
**identical** `Tuple{UInt64, ...}`. Byte-identical guaranteed by
construction for: i8 x+1=100/28T, i16=204, i32=412, i64=828, soft_fma,
soft_exp_julia, soft_exp2_julia, `_ls_demo=436/90T`, all test_softfloat
tests, all MUX EXCH + shadow + shadow_checkpoint paths, BENCHMARKS.md rows.

Width-matching assertion is a no-op on every existing IRCall path (R8
empirically verified).

---

## 5. Implementation sequence (6 steps)

1. **Add** helpers `_callee_arg_types` + `_assert_arg_widths_match` just above
   `lower_call!` in `src/lower.jl`. Export them internally for the test file.
2. **Write** RED test at `test/test_atf4_lower_call_nontrivial_args.jl`; add
   `include` line to `test/runtests.jl`. Run: expect all testsets RED
   (T1/T2/T3 still MethodError at line 1869).
3. **Patch** `src/lower.jl:1869–1870` per §2. Run RED test: expect GREEN.
4. **Run full `Pkg.test()`.** Every existing test GREEN. Any unexpected
   failure → STOP, diff, investigate.
5. **Spot-check** gate counts: i8 x+1 == 100/28T, `_ls_demo` == 436/90T.
6. **Commit** as one atomic commit; close Bennett-atf4.

---

## 6. Risks (consensus summary)

1. **R8 (resolved)**: IRCall emitters passing non-64 widths against UInt64 callees. **Zero mismatches** confirmed empirically 2026-04-21. Assertion ships safely.
2. **Phi-merged callees**: not emitted by any code path today (every IRCall
   emitter picks a concrete callee at compile time). Low risk.
3. **External-IR callees** (from_ll/from_bc): gated by `_lookup_callee` regex
   to `julia_`/`j_` names; never reach `lower_call!` today. Low risk.
4. **`methods()` non-determinism**: we require exactly one method, so
   ordering is irrelevant. Zero risk.
5. **Abstract param types**: `sizeof` errors clearly with native message.
   Low risk; desired behaviour.
6. **`compact=true` + NTuple callee**: untested combo. Both branches read
   the same `arg_types`, so the fix applies uniformly. Low risk; flag as
   follow-up test coverage once Bennett-0c8o/uyf9 land.

---

End of consensus. Implementer proceeds with §5.
