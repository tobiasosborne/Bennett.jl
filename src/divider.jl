"""
    _soft_udiv_compile(a::UInt64, b::UInt64) -> UInt64

Branchless restoring-division kernel used as the registered callee for
`udiv` / `sdiv` lowering (`lower_divrem!` in `lower.jl`). Only operations
the gate pipeline already supports (add, sub, shift, compare, ifelse).

# Bennett-salb / U119 — divide-by-zero contract

This kernel is the **callee inlined into compiled circuits**. It cannot
throw, because adding a `throw(DivideError())` would emit `@ijl_throw`
in the LLVM IR — an external runtime call with no source for `lower_call!`
to extract.

Instead the kernel is documented LLVM-poison-equivalent on `b == 0`:
deterministic but unspecified. With the current restoring-division loop,
`_soft_udiv_compile(a, 0) == typemax(UInt64)` for every `a` (the trial
subtract `r >= 0` always succeeds, so every quotient bit is set).

The public `soft_udiv` wraps this with a `DivideError` check for direct
Julia callers.
"""
function _soft_udiv_compile(a::UInt64, b::UInt64)::UInt64
    q = UInt64(0)
    r = UInt64(0)
    for i in 63:-1:0
        # Shift remainder left, bring in bit i of a
        r = (r << 1) | ((a >> i) & UInt64(1))
        # Trial: can we subtract b?
        fits = r >= b
        r = ifelse(fits, r - b, r)
        q = ifelse(fits, q | (UInt64(1) << i), q)
    end
    return q
end

"""
    _soft_urem_compile(a::UInt64, b::UInt64) -> UInt64

Branchless restoring-remainder kernel; companion to `_soft_udiv_compile`.

# Bennett-salb / U119 — divide-by-zero contract

LLVM-poison-equivalent on `b == 0`: with the current loop, every trial
subtract is a no-op, so the bit-by-bit accumulation yields
`_soft_urem_compile(a, 0) == a`.

The public `soft_urem` wraps this with a `DivideError` check.
"""
function _soft_urem_compile(a::UInt64, b::UInt64)::UInt64
    r = UInt64(0)
    for i in 63:-1:0
        r = (r << 1) | ((a >> i) & UInt64(1))
        fits = r >= b
        r = ifelse(fits, r - b, r)
    end
    return r
end

"""
    soft_udiv(a::UInt64, b::UInt64) -> UInt64

Unsigned integer division `a ÷ b`. Throws `DivideError` on `b == 0`,
matching `Base.div` semantics.

For the gate-inlined branchless kernel (used inside compiled circuits)
see `_soft_udiv_compile`. This wrapper exists so that direct Julia
callers of `soft_udiv` get the loud failure required by Bennett-salb /
CLAUDE.md §1; the compiled-circuit path goes via `_soft_udiv_compile`
because its IR cannot contain a throw (would emit `@ijl_throw` external
call that `lower_call!` cannot extract).
"""
function soft_udiv(a::UInt64, b::UInt64)::UInt64
    iszero(b) && throw(DivideError())
    return _soft_udiv_compile(a, b)
end

"""
    soft_urem(a::UInt64, b::UInt64) -> UInt64

Unsigned integer remainder `a % b`. Throws `DivideError` on `b == 0`,
matching `Base.rem` semantics. See `soft_udiv` for the dual-function
rationale.
"""
function soft_urem(a::UInt64, b::UInt64)::UInt64
    iszero(b) && throw(DivideError())
    return _soft_urem_compile(a, b)
end
