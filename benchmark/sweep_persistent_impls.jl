# ---- Parameterized persistent-DS impls for the max_n scaling sweep ----
#
# This file is NOT part of the main Bennett.jl module — it's loaded only by
# `benchmark/sweep_persistent_max_n.jl` (one cell per subprocess).  It
# generates impl variants at arbitrary max_n via @generated functions
# without touching the production impls in src/persistent/ (those stay
# locked at their tested max_n=4/8 baselines).
#
# Calibration phase: starts with `sweep_ls_*` (linear_scan).  CF, HAMT,
# Okasaki added once linear_scan validates the measurement methodology.

using Bennett

# ════════════════════════════════════════════════════════════════════════════
# LINEAR SCAN — parameterized at compile time via @generated
# ════════════════════════════════════════════════════════════════════════════

# State shape: NTuple{1 + 2*N, UInt64}
#   slot 1:       count of stored pairs
#   slot 2*i:     key   of pair i (i ∈ 1:N)
#   slot 2*i+1:   value of pair i

@inline _ls_pick(slot_index::Int, target::UInt64, new_val::UInt64,
                 old_val::UInt64)::UInt64 =
    ifelse(target == UInt64(slot_index), new_val, old_val)

@generated function sweep_ls_pmap_new(::Val{N}) where {N}
    NS = 1 + 2 * N
    return :(ntuple(_ -> UInt64(0), Val($NS)))
end

@generated function sweep_ls_pmap_set(s::NTuple{NS, UInt64}, k::Int8, v::Int8,
                                       ::Val{N}) where {NS, N}
    NS == 1 + 2*N || error("sweep_ls_pmap_set: NS=$NS != 1+2*N for N=$N")
    body = quote
        count = s[1]
        target = ifelse(count >= UInt64($N),
                        UInt64($(N - 1)),
                        count)
        new_count = ifelse(count >= UInt64($N),
                           UInt64($N),
                           count + UInt64(1))
        k_u = UInt64(reinterpret(UInt8, k))
        v_u = UInt64(reinterpret(UInt8, v))
    end
    # Build the new NTuple expression, manually unrolled per slot.
    elems = Any[:(new_count)]
    for i in 0:(N - 1)
        # key slot at 2i+2, val slot at 2i+3 (1-based)
        push!(elems, :(_ls_pick($i, target, k_u, s[$(2*i + 2)])))
        push!(elems, :(_ls_pick($i, target, v_u, s[$(2*i + 3)])))
    end
    push!(body.args, Expr(:tuple, elems...))
    return body
end

@generated function sweep_ls_pmap_get(s::NTuple{NS, UInt64}, k::Int8,
                                       ::Val{N}) where {NS, N}
    NS == 1 + 2*N || error("sweep_ls_pmap_get: NS=$NS != 1+2*N for N=$N")
    body = quote
        k_u = UInt64(reinterpret(UInt8, k))
        count = s[1]
        acc = UInt64(0)
    end
    for i in 0:(N - 1)
        push!(body.args, :(in_use = count > UInt64($i)))
        push!(body.args, :(match  = in_use & (s[$(2*i + 2)] == k_u)))
        push!(body.args, :(acc    = ifelse(match, s[$(2*i + 3)], acc)))
    end
    push!(body.args, :(return reinterpret(Int8, UInt8(acc & UInt64(0xff)))))
    return body
end

# Demo factory — builds a top-level (closure-free) demo function for a
# specific N, suitable for `reversible_compile`.  Bennett.jl's IR
# extractor needs concrete arg types, no Val{N} in the signature.
function make_ls_demo(::Val{N}) where {N}
    @eval function $(Symbol("ls_demo_max_n_", N))(k1::Int8, v1::Int8,
                                                    k2::Int8, v2::Int8,
                                                    k3::Int8, v3::Int8,
                                                    lookup::Int8)::Int8
        s = sweep_ls_pmap_new(Val($N))
        s = sweep_ls_pmap_set(s, k1, v1, Val($N))
        s = sweep_ls_pmap_set(s, k2, v2, Val($N))
        s = sweep_ls_pmap_set(s, k3, v3, Val($N))
        return sweep_ls_pmap_get(s, lookup, Val($N))
    end
    return getfield(@__MODULE__, Symbol("ls_demo_max_n_", N))
end
