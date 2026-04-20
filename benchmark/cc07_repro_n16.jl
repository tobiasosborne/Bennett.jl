# AUTO-GENERATED for cc0.7 RED test — N=16 linear_scan only

@inline function sweep_ls_16_pmap_new()::NTuple{33, UInt64}
    return ntuple(_ -> UInt64(0), Val(33))
end

@inline function sweep_ls_16_pmap_set(s::NTuple{33, UInt64}, k::Int8, v::Int8)::NTuple{33, UInt64}
    count = s[1]
    target = ifelse(count >= UInt64(16), UInt64(15), count)
    new_count = ifelse(count >= UInt64(16), UInt64(16), count + UInt64(1))
    k_u = UInt64(reinterpret(UInt8, k))
    v_u = UInt64(reinterpret(UInt8, v))
    return (
        new_count,
        ifelse(target == UInt64(0), k_u, s[2]),
        ifelse(target == UInt64(0), v_u, s[3]),
        ifelse(target == UInt64(1), k_u, s[4]),
        ifelse(target == UInt64(1), v_u, s[5]),
        ifelse(target == UInt64(2), k_u, s[6]),
        ifelse(target == UInt64(2), v_u, s[7]),
        ifelse(target == UInt64(3), k_u, s[8]),
        ifelse(target == UInt64(3), v_u, s[9]),
        ifelse(target == UInt64(4), k_u, s[10]),
        ifelse(target == UInt64(4), v_u, s[11]),
        ifelse(target == UInt64(5), k_u, s[12]),
        ifelse(target == UInt64(5), v_u, s[13]),
        ifelse(target == UInt64(6), k_u, s[14]),
        ifelse(target == UInt64(6), v_u, s[15]),
        ifelse(target == UInt64(7), k_u, s[16]),
        ifelse(target == UInt64(7), v_u, s[17]),
        ifelse(target == UInt64(8), k_u, s[18]),
        ifelse(target == UInt64(8), v_u, s[19]),
        ifelse(target == UInt64(9), k_u, s[20]),
        ifelse(target == UInt64(9), v_u, s[21]),
        ifelse(target == UInt64(10), k_u, s[22]),
        ifelse(target == UInt64(10), v_u, s[23]),
        ifelse(target == UInt64(11), k_u, s[24]),
        ifelse(target == UInt64(11), v_u, s[25]),
        ifelse(target == UInt64(12), k_u, s[26]),
        ifelse(target == UInt64(12), v_u, s[27]),
        ifelse(target == UInt64(13), k_u, s[28]),
        ifelse(target == UInt64(13), v_u, s[29]),
        ifelse(target == UInt64(14), k_u, s[30]),
        ifelse(target == UInt64(14), v_u, s[31]),
        ifelse(target == UInt64(15), k_u, s[32]),
        ifelse(target == UInt64(15), v_u, s[33])
    )
end

@inline function sweep_ls_16_pmap_get(s::NTuple{33, UInt64}, k::Int8)::Int8
    k_u = UInt64(reinterpret(UInt8, k))
    count = s[1]
    acc = UInt64(0)
    acc = ifelse((count > UInt64(0)) & (s[2] == k_u), s[3], acc)
    acc = ifelse((count > UInt64(1)) & (s[4] == k_u), s[5], acc)
    acc = ifelse((count > UInt64(2)) & (s[6] == k_u), s[7], acc)
    acc = ifelse((count > UInt64(3)) & (s[8] == k_u), s[9], acc)
    acc = ifelse((count > UInt64(4)) & (s[10] == k_u), s[11], acc)
    acc = ifelse((count > UInt64(5)) & (s[12] == k_u), s[13], acc)
    acc = ifelse((count > UInt64(6)) & (s[14] == k_u), s[15], acc)
    acc = ifelse((count > UInt64(7)) & (s[16] == k_u), s[17], acc)
    acc = ifelse((count > UInt64(8)) & (s[18] == k_u), s[19], acc)
    acc = ifelse((count > UInt64(9)) & (s[20] == k_u), s[21], acc)
    acc = ifelse((count > UInt64(10)) & (s[22] == k_u), s[23], acc)
    acc = ifelse((count > UInt64(11)) & (s[24] == k_u), s[25], acc)
    acc = ifelse((count > UInt64(12)) & (s[26] == k_u), s[27], acc)
    acc = ifelse((count > UInt64(13)) & (s[28] == k_u), s[29], acc)
    acc = ifelse((count > UInt64(14)) & (s[30] == k_u), s[31], acc)
    acc = ifelse((count > UInt64(15)) & (s[32] == k_u), s[33], acc)
    return reinterpret(Int8, UInt8(acc & UInt64(0xff)))
end

function ls_demo_16(seed::Int8, lookup::Int8)::Int8
    s = sweep_ls_16_pmap_new()
    s = sweep_ls_16_pmap_set(s, seed + Int8(0), seed + Int8(1))
    s = sweep_ls_16_pmap_set(s, seed + Int8(2), seed + Int8(3))
    s = sweep_ls_16_pmap_set(s, seed + Int8(4), seed + Int8(5))
    s = sweep_ls_16_pmap_set(s, seed + Int8(6), seed + Int8(7))
    s = sweep_ls_16_pmap_set(s, seed + Int8(8), seed + Int8(9))
    s = sweep_ls_16_pmap_set(s, seed + Int8(10), seed + Int8(11))
    s = sweep_ls_16_pmap_set(s, seed + Int8(12), seed + Int8(13))
    s = sweep_ls_16_pmap_set(s, seed + Int8(14), seed + Int8(15))
    s = sweep_ls_16_pmap_set(s, seed + Int8(16), seed + Int8(17))
    s = sweep_ls_16_pmap_set(s, seed + Int8(18), seed + Int8(19))
    s = sweep_ls_16_pmap_set(s, seed + Int8(20), seed + Int8(21))
    s = sweep_ls_16_pmap_set(s, seed + Int8(22), seed + Int8(23))
    s = sweep_ls_16_pmap_set(s, seed + Int8(24), seed + Int8(25))
    s = sweep_ls_16_pmap_set(s, seed + Int8(26), seed + Int8(27))
    s = sweep_ls_16_pmap_set(s, seed + Int8(28), seed + Int8(29))
    s = sweep_ls_16_pmap_set(s, seed + Int8(30), seed + Int8(31))
    return sweep_ls_16_pmap_get(s, lookup)
end

