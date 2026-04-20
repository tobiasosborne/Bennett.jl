# ---- Code generator for parameterized persistent-DS impls ----
#
# Writes a Julia source file with CONCRETE, manually-unrolled functions for
# each (impl, max_n) cell in the sweep.  No @generated, no @eval — the
# resulting file is plain Julia that Bennett.jl can extract LLVM IR from
# cleanly (avoiding the cc0.3 LLVMGlobalAlias + cc0.5 TLS-alloca gaps that
# @eval-generated functions triggered).
#
# Run as:  julia --project=. benchmark/codegen_sweep_impls.jl
# Output:  benchmark/sweep_persistent_impls_gen.jl
#
# Edit the MAX_N_LIST below to control which cells get generated.

const MAX_N_LIST = [4, 16, 64, 256, 1000]   # full sweep

const OUT_PATH = joinpath(@__DIR__, "sweep_persistent_impls_gen.jl")

# ────────────────────────────────────────────────────────────────────────────
# Linear scan code generator
# ────────────────────────────────────────────────────────────────────────────

function gen_ls_new(io::IO, N::Int)
    ns = 1 + 2*N
    println(io, "@inline function sweep_ls_$(N)_pmap_new()::NTuple{$ns, UInt64}")
    println(io, "    return ntuple(_ -> UInt64(0), Val($ns))")
    println(io, "end")
    println(io)
end

function gen_ls_set(io::IO, N::Int)
    ns = 1 + 2*N
    println(io, "@inline function sweep_ls_$(N)_pmap_set(s::NTuple{$ns, UInt64}, k::Int8, v::Int8)::NTuple{$ns, UInt64}")
    println(io, "    count = s[1]")
    println(io, "    target = ifelse(count >= UInt64($N), UInt64($(N-1)), count)")
    println(io, "    new_count = ifelse(count >= UInt64($N), UInt64($N), count + UInt64(1))")
    println(io, "    k_u = UInt64(reinterpret(UInt8, k))")
    println(io, "    v_u = UInt64(reinterpret(UInt8, v))")
    # Build the new tuple explicitly
    println(io, "    return (")
    print(io,   "        new_count,")
    for i in 0:(N-1)
        key_slot = 2*i + 2
        val_slot = 2*i + 3
        println(io)
        print(io, "        ifelse(target == UInt64($i), k_u, s[$key_slot]),")
        println(io)
        print(io, "        ifelse(target == UInt64($i), v_u, s[$val_slot])")
        if i != N-1
            print(io, ",")
        end
    end
    println(io)
    println(io, "    )")
    println(io, "end")
    println(io)
end

function gen_ls_get(io::IO, N::Int)
    ns = 1 + 2*N
    println(io, "@inline function sweep_ls_$(N)_pmap_get(s::NTuple{$ns, UInt64}, k::Int8)::Int8")
    println(io, "    k_u = UInt64(reinterpret(UInt8, k))")
    println(io, "    count = s[1]")
    println(io, "    acc = UInt64(0)")
    for i in 0:(N-1)
        key_slot = 2*i + 2
        val_slot = 2*i + 3
        println(io, "    acc = ifelse((count > UInt64($i)) & (s[$key_slot] == k_u), s[$val_slot], acc)")
    end
    println(io, "    return reinterpret(Int8, UInt8(acc & UInt64(0xff)))")
    println(io, "end")
    println(io)
end

# ────────────────────────────────────────────────────────────────────────────
# CF semi-persistent code generator
# ────────────────────────────────────────────────────────────────────────────
#
# State layout (parameterized at max_n = N):
#   slot 1:                    diff_depth
#   slot 2:                    arr_count
#   slots 3..2+2N:             N (key, val) Arr pairs
#                                 arr_key[i] at slot 3 + 2*i
#                                 arr_val[i] at slot 4 + 2*i
#   slots 3+2N..2+5N:          N (slot_idx, old_key, old_val) Diff entries
#                                 diff_idx[d]  at slot 3 + 2N + 3*d
#                                 diff_key[d]  at slot 4 + 2N + 3*d
#                                 diff_val[d]  at slot 5 + 2N + 3*d
#
# Total state: NTuple{2 + 5N, UInt64}.

cf_state_len(N::Int) = 2 + 5*N
cf_arr_key(N::Int, i::Int) = 3 + 2*i
cf_arr_val(N::Int, i::Int) = 4 + 2*i
cf_diff_idx(N::Int, d::Int) = 3 + 2*N + 3*d
cf_diff_key(N::Int, d::Int) = 4 + 2*N + 3*d
cf_diff_val(N::Int, d::Int) = 5 + 2*N + 3*d

function gen_cf_new(io::IO, N::Int)
    ns = cf_state_len(N)
    println(io, "@inline function sweep_cf_$(N)_pmap_new()::NTuple{$ns, UInt64}")
    println(io, "    return ntuple(_ -> UInt64(0), Val($ns))")
    println(io, "end")
    println(io)
end

function gen_cf_set(io::IO, N::Int)
    ns = cf_state_len(N)
    println(io, "@inline function sweep_cf_$(N)_pmap_set(s::NTuple{$ns, UInt64}, k::Int8, v::Int8)::NTuple{$ns, UInt64}")
    println(io, "    k_u = UInt64(reinterpret(UInt8, k))")
    println(io, "    v_u = UInt64(reinterpret(UInt8, v))")
    println(io, "    count = s[2]")
    println(io, "    depth = s[1]")
    println(io)
    # Read all Arr keys
    println(io, "    # Match scan over all $N Arr keys")
    for i in 0:(N-1)
        println(io, "    ku$i = s[$(cf_arr_key(N, i))]")
    end
    println(io)
    # Compute match flags
    for i in 0:(N-1)
        println(io, "    m$i = (count > UInt64($i)) & (ku$i == k_u)")
    end
    println(io)
    # any_match
    print(io, "    any_match = ")
    for i in 0:(N-1)
        if i > 0; print(io, " | "); end
        print(io, "m$i")
    end
    println(io)
    println(io)
    # First-match index (priority encoding) — generate as nested ifelse
    # first_match = m0 ? 0 : m1 ? 1 : ... : N-1
    print(io, "    first_match_idx = ")
    for i in 0:(N-2)
        print(io, "ifelse(m$i, UInt64($i), ")
    end
    print(io, "UInt64($(N-1))")
    print(io, ")"^(N-1))
    println(io)
    # New slot
    println(io, "    new_slot_idx = ifelse(count >= UInt64($N), UInt64($(N-1)), count)")
    println(io, "    target_slot  = ifelse(any_match, first_match_idx, new_slot_idx)")
    println(io)
    # Read old k, v at target_slot via nested ifelse
    print(io, "    old_k = ")
    for i in 0:(N-2)
        print(io, "ifelse(target_slot == UInt64($i), ku$i, ")
    end
    print(io, "ku$(N-1)")
    print(io, ")"^(N-1))
    println(io)
    print(io, "    old_v = ")
    for i in 0:(N-2)
        print(io, "ifelse(target_slot == UInt64($i), s[$(cf_arr_val(N, i))], ")
    end
    print(io, "s[$(cf_arr_val(N, N-1))]")
    print(io, ")"^(N-1))
    println(io)
    println(io)
    # Compute safe_depth
    println(io, "    safe_depth = ifelse(depth >= UInt64($N), UInt64($(N-1)), depth)")
    println(io)
    # Build new state. Update Arr slot (target_slot ← (k_u, v_u)),
    # update Diff slot at safe_depth ← (target_slot, old_k, old_v).
    # Also update count + depth.
    println(io, "    new_count = ifelse(any_match | (count >= UInt64($N)), count, count + UInt64(1))")
    println(io, "    new_depth = ifelse(depth >= UInt64($N), UInt64($N), depth + UInt64(1))")
    println(io)
    # Build new state tuple
    println(io, "    return (")
    println(io, "        new_depth,")
    println(io, "        new_count,")
    # Arr keys + vals
    for i in 0:(N-1)
        println(io, "        ifelse(target_slot == UInt64($i), k_u, ku$i),")
        println(io, "        ifelse(target_slot == UInt64($i), v_u, s[$(cf_arr_val(N, i))]),")
    end
    # Diff entries
    for d in 0:(N-1)
        println(io, "        ifelse(safe_depth == UInt64($d), target_slot, s[$(cf_diff_idx(N, d))]),")
        println(io, "        ifelse(safe_depth == UInt64($d), old_k,       s[$(cf_diff_key(N, d))]),")
        last = (d == N-1)
        println(io, "        ifelse(safe_depth == UInt64($d), old_v,       s[$(cf_diff_val(N, d))])$(last ? "" : ",")")
    end
    println(io, "    )")
    println(io, "end")
    println(io)
end

function gen_cf_get(io::IO, N::Int)
    ns = cf_state_len(N)
    println(io, "@inline function sweep_cf_$(N)_pmap_get(s::NTuple{$ns, UInt64}, k::Int8)::Int8")
    println(io, "    k_u = UInt64(reinterpret(UInt8, k))")
    println(io, "    count = s[2]")
    println(io, "    acc = UInt64(0)")
    for i in 0:(N-1)
        println(io, "    acc = ifelse((count > UInt64($i)) & (s[$(cf_arr_key(N, i))] == k_u), s[$(cf_arr_val(N, i))], acc)")
    end
    println(io, "    return reinterpret(Int8, UInt8(acc & UInt64(0xff)))")
    println(io, "end")
    println(io)
end

function gen_cf_demo(io::IO, N::Int)
    println(io, "function cf_demo_$(N)(seed::Int8, lookup::Int8)::Int8")
    println(io, "    s = sweep_cf_$(N)_pmap_new()")
    for i in 0:(N-1)
        ki = (2*i) % 256
        ki_str = ki < 128 ? "Int8($ki)" : "Int8($(ki - 256))"
        vi = (2*i + 1) % 256
        vi_str = vi < 128 ? "Int8($vi)" : "Int8($(vi - 256))"
        println(io, "    s = sweep_cf_$(N)_pmap_set(s, seed + $ki_str, seed + $vi_str)")
    end
    println(io, "    return sweep_cf_$(N)_pmap_get(s, lookup)")
    println(io, "end")
    println(io)
end

function gen_ls_demo(io::IO, N::Int)
    # Demo: insert K=N (key, value) pairs derived from a single seed, then
    # look up one key.  This populates the full capacity so the optimizer
    # can't dead-code-eliminate unused slots.  Keys generated as
    # `seed + 2i`, values as `seed + 2i + 1` (mod 256 via Int8 wrap).
    # The seed comes from the function arg so the optimizer can't fold
    # them at compile time.
    println(io, "function ls_demo_$(N)(seed::Int8, lookup::Int8)::Int8")
    println(io, "    s = sweep_ls_$(N)_pmap_new()")
    for i in 0:(N-1)
        ki = (2*i) % 256
        # Use Int8 arithmetic explicitly so wrap is correct
        if ki < 128
            ki_str = "Int8($ki)"
        else
            ki_str = "Int8($(ki - 256))"
        end
        vi = (2*i + 1) % 256
        if vi < 128
            vi_str = "Int8($vi)"
        else
            vi_str = "Int8($(vi - 256))"
        end
        println(io, "    s = sweep_ls_$(N)_pmap_set(s, seed + $ki_str, seed + $vi_str)")
    end
    println(io, "    return sweep_ls_$(N)_pmap_get(s, lookup)")
    println(io, "end")
    println(io)
end

# ────────────────────────────────────────────────────────────────────────────
# Main emitter
# ────────────────────────────────────────────────────────────────────────────

open(OUT_PATH, "w") do io
    println(io, "# AUTO-GENERATED by benchmark/codegen_sweep_impls.jl")
    println(io, "# Do not edit directly — re-run the codegen script to update.")
    println(io)
    println(io, "# Concrete per-max_n impls for the persistent-DS scaling sweep.")
    println(io)

    for N in MAX_N_LIST
        println(io, "# ─── max_n = $N ─────────────────────────────────────────")
        println(io)
        println(io, "# ---- linear_scan ----")
        gen_ls_new(io, N)
        gen_ls_set(io, N)
        gen_ls_get(io, N)
        gen_ls_demo(io, N)
        println(io)
        println(io, "# ---- cf_semi_persistent ----")
        gen_cf_new(io, N)
        gen_cf_set(io, N)
        gen_cf_get(io, N)
        gen_cf_demo(io, N)
        println(io)
    end
end

println("Generated $OUT_PATH")
println("Cells covered: linear_scan × {$(join(MAX_N_LIST, ", "))}")
# Approximate output size
println("Output size: ", stat(OUT_PATH).size, " bytes")
