# Bennett-land proposal — Proposer A

(Captured 2026-05-16 from Plan-Opus subagent under 3+1 protocol per CLAUDE.md §2.
Proposers A and B worked independently — neither saw the other's output.)

## Verification of pre-shared survey (skepticism)

- **Simulator has no ptr wire semantics**: CONFIRMED. `src/simulator.jl` operates on `Vector{Bool}`. Pointer identity is resolved at extraction time (Bennett-cc0 `_ptr_identity` in `src/extract/constexpr.jl:122`) and folded into integer constants OR rejected at `_fold_constexpr_operand` — never silently miscompiled.
- **t5_tr2:153 HashMap::new never loads ptr bytes back as ptr**: CONFIRMED — 32 bytes go `@anon → %_3 → %_2 → %_0` (sret) bit-for-bit.
- **31 instances of `<{ ptr, [N x i8] }>` across t5**: actual count is **25** (tr1=5, tr2=15, tr3=5), plus 3 vtable shapes.
- **No existing tests expose synthetic-address miscompile**: confirmed — `_ptr_identity` machinery handles all current icmp/ptr cases at extraction time.

**Additional finding**: existing `_ptr_identity` infrastructure (Bennett-cc0) provides `(:named, ref)` / `(:addr, K::UInt64)` / `(:null, 0)` tags. We can REUSE this as the synthetic-address key.

## Design

### Policy pick: OPTION 1 (symbolic-address), narrowed to named-global ptr fields

Reasoning: smallest MVP. Option 2 (lazy pointee inlining) is larger code for same acceptance because t5_tr2:153 carries bytes through 3 memcpys with no single load site. Option 3 (first-class ptr wires) is v0.6-class architectural change.

### Address-assignment policy

```julia
SYNTH_ADDR_BASE = UInt64(0x1000_0000_0000_0000)
synth_addr(gname, addr_map) = get!(addr_map, gname) do
    SYNTH_ADDR_BASE | (UInt64(length(addr_map)) << 32) |
    (UInt64(hash(gname)) & 0x0000_0000_FFFF_FFFF)
end
```

Properties: stable per-module, unique, MSB-nibble distinguishable from real constants, no Julia JIT address collision.

### Round-trip + Julia oracle

Simulator round-trips bit-level constants trivially. Oracle = `_synth_addr_bytes(:gname, addr_map)` exposed for tests. If policy changes, test fails LOUD with byte mismatch.

### Failure modes / known miscompile risk

**Risk class A — load-bytes-then-icmp/arith.** A function that loads 8 bytes back as ptr then compares against another ptr — synthetic address won't match unless both sides came from same source. **Mitigation: load-bearing fail-loud escape guard.** Records `(gname, field_off, 8)` in `synth_ptr_provenance::Set`. Load lowering checks: if load source is an alloca that received a memcpy from a global with provenance overlap, AND the loaded SSA is consumed by anything other than another memcpy, FAIL LOUD with `Bennett-land-ptrescape`. **Crude-but-correct version is ~30 LOC**: tag the alloca during memcpy lowering; check the bit during load lowering.

**Risk class B — inttoptr/ptrtoint round-trip arithmetic.** Same mitigation as A.

**Risk class C — pointee dereference (`load ptr` then `load i64, ptr`).** Today Bennett doesn't lower `load ptr` to anything useful — already fails downstream.

### `_flatten_struct_to_bytes` extension

New PointerType arm before the `else return nothing`:
- `addrspace(field_ty) == 0` || return nothing (non-zero addrspace deferred)
- `LLVM.pointersize(dl, 0) * 8 == 64` || return nothing (32-bit deferred)
- if ConstantPointerNull → addr = 0
- else `_ptr_identity(field_val.ref)`:
  - `:named` → `_synth_addr_for_global(ident[2], addr_map)`
  - `:null` → 0
  - `:addr` → use the concrete inttoptr K
  - nothing → return nothing
- LSB-first byte pack into `bytes[field_off+1:field_off+8]`
- record `(gname, field_off, 8)` in `synth_ptr_provenance`

Threading: `addr_map` and `synth_ptr_provenance` passed to `_flatten_struct_to_bytes`; `synth_ptr_provenance` returned from `_extract_const_globals` alongside globals dict and stored on `ParsedIR` as new field.

### Downstream audit

- **`_handle_memcpy_global_src` G5 message**: drop `Bennett-zxhg-ptrfield` enumeration; reference `Bennett-land` guards.
- **`_handle_memcpy_global_src` lowering**: NO logic change. Synthetic bytes round-trip as constants.
- **`lower_var_gep!`**: no change (same-width check still works).
- **Simulator**: no change.
- **`_handle_load`** (NEW): add escape guard. If load source alloca received a memcpy from struct-global with provenance overlap AND result is not consumed solely by memcpy, fail loud. **~30-80 LOC** (crude vs precise version).

### Test plan

**Positive (5):**
1. `land_ptr_field_named.ll` — `<{ ptr @target, [24 x i8] zeroinitializer }>` (mirror t5_tr2:153)
2. `land_ptr_field_null.ll` — ConstantPointerNull
3. `land_ptr_field_carry_through.ll` — 3-hop memcpy chain (HashMap::new shape)
4. `land_ptr_field_vtable_shape.ll` — `<{ [24 x i8], ptr @fn1, ptr @fn2 }>` (vtable-like, ptr not at offset 0)
5. `land_two_ptr_fields.ll` — two distinct ptrs, addr_map allocates unique

**Reject (5):**
6. `land_ptr_field_addrspace_reject.ll` — non-zero addrspace
7. `land_ptr_field_inttoptr_reject.ll` — actually POSITIVE via `:addr` arm
8. `land_ptr_field_undef_reject.ll` — undef ptr
9. `land_ptr_escape_load_reject.ll` — load ptr from struct-memcpy dst → `Bennett-land-ptrescape`
10. `land_ptr_escape_icmp_reject.ll` — load i64 + icmp → fail loud

**T5 acceptance (1):** `test/test_land_t5_acceptance.jl` — compile actual HashMap::new from t5_tr2:145-161 end-to-end. FIRST t5 corpus Rust function compiled through a previously-rejected codepath.

**Doih/zxhg flips required.**

### Risk register + follow-up beads

- R1: Silent miscompile via synthetic addr (mitigated by escape guard — load-bearing in MVP)
- R2: Address-policy stability (file `Bennett-land-stable-addr` if cross-rerun byte-identical needed)
- R3: Cross-module address collision (flag in worklog; per-module addr_map)
- R4: addrspace assumption (file `Bennett-land-addrspace`)
- R5: Pointee-walked-as-data case (file `Bennett-land-inline-pointee`)
- R6: `_ptr_identity` chain-depth (safe; bounded at 16)
- R7: Future agent confuses `:addr` tag with synthetic addrs (document)
- R8: Escape guard misses transitive plumbing (file `Bennett-land-transitive-escape`)
- R9: G2 `_alloca_is_fresh` interaction with HashMap::new's `%_2` (out of scope per strict acceptance)

**Follow-ups filed:**
- `Bennett-land-precise-escape` (P4) — byte-precise overlap analysis
- `Bennett-land-inline-pointee` (P4) — Option 2 lazy inlining
- `Bennett-land-addrspace` (P4) — non-zero addrspace
- Maybe `Bennett-land-transitive-escape` (P4)

## Implementation sketch

1. `src/extract/module_walk.jl` — extend `_flatten_struct_to_bytes` (~40 LOC arm + threading), new `_synth_addr_for_global` helper (~10 LOC), `_extract_const_globals` allocates addr_map + synth_ptr_provenance and returns alongside globals.
2. `src/ir_types.jl` — `ParsedIR` gains `synth_ptr_provenance::Set{Tuple{Symbol,Int,Int}}` field (additive, no signature break).
3. `src/extract/instructions.jl` — G5 wording update; record dst alloca → src global provenance in `_handle_memcpy_global_src`; add escape guard in `_handle_load`.
4. ~10 new `land_*.ll` fixtures.
5. `test_land_ptrfield_global.jl` (NEW, ~200 LOC).
6. `test_land_t5_acceptance.jl` (NEW, ~80 LOC milestone).
7. Flip zxhg testsets.
8. `runtests.jl` registration.

**Estimated footprint:** ~80 LOC src + ~10 LOC ir_types + ~280 LOC tests + ~150 LOC fixtures.

## Summary

Bennett-land MVP picks Option 1 (compile-time symbolic-address) because t5's 25/25 ptr-leading-struct globals are Rust panic-Location ABI carried byte-for-byte through memcpy chains with no ptr-load type-pun, the simulator has zero pointer dereference semantics, and Options 2/3 are larger architectural changes. Synthetic addresses are deterministic per-module (`0x1000_0000_0000_0000 | (counter<<32) | (hash(name) & 0xFFFFFFFF)`), distinguishable from real constants. The load-bearing safety mechanism is a fail-loud escape guard in `_handle_load`. Footprint: ~80 LOC src, ~430 LOC tests/fixtures.

## Blockers / assumptions

- **ASSUMPTION (load escape guard is load-bearing):** include in MVP. Crude version (~30 LOC) sufficient.
- **ASSUMPTION (addrspace 0 only, ptr width = 64 bits):** hard-rejected otherwise.
- **ASSUMPTION (`_ptr_identity` covers all real shapes):** verified.
- **Open question for orchestrator:** include escape guard in land or defer? Recommend INCLUDE per §1.
