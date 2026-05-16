# Bennett-land proposal — Proposer B

(Captured 2026-05-16 from Plan-Opus subagent under 3+1 protocol per CLAUDE.md §2.
Proposers A and B worked independently — neither saw the other's output.)

## Verification of pre-shared survey (skepticism)

| Claim | Verdict | Evidence |
|---|---|---|
| `_flatten_struct_to_bytes` rejects ptr fields | TRUE | module_walk.jl:333-338 |
| G5 fires with `Bennett-zxhg-ptrfield` | TRUE | instructions.jl:483-496 |
| ~25-31 instances of `<{ ptr, [N x i8] }>` | actual = **25** ptr-first + **3** vtable shapes; total 28 ptr-containing structs (NOT 31) |
| All ptr-first are Rust panic-Location ABI | TRUE | shape `<{ ptr @<str>, [16 or 24 x i8] }>` matches |
| t5_tr2:153 HashMap::new never loads ptr-bytes back as ptr | TRUE | read lines 145-161; 3 memcpys + 2 i64 stores into `%_2`, no `load ptr/i64, ptr %_3` |
| Simulator has no ptr semantics | TRUE | grep returns zero matches |
| No existing test compares LLVM ptr values | MOSTLY TRUE | `_ptr_addresses_equal` only at extraction time |
| `_ptr_identity` (Bennett-cc0) | TRUE | Reusable as synthetic-address key |

**Critical drift: existing tests will flip.** `test/test_zxhg_struct_global.jl` has 5 `@test_throws` on `Bennett-zxhg-ptrfield`:
- `zxhg_struct_ptr_field_reject.ll` (lines 145-163) — MUST FLIP
- `zxhg_struct_nested_struct_reject.ll` (lines 165-178) — MUST FLIP
- `zxhg_struct_float_field_reject.ll` (lines 180-193) — KEEP (float out of land scope)
- `zxhg_struct_too_wide_int_reject.ll` (lines 195-208) — KEEP (i128 out of land scope)
- `zxhg_t5_tr2_smoke.ll` (lines 212-230) — MUST FLIP (the acceptance fixture)

**Additional discovery — t5_tr2 has second-order risk.** `LocalKey::with` at lines 413-417 does `%_3 = alloca [24 x i8]; ...; %_4 = load i64, ptr %_3, align 8` — loads low 8 bytes of an sret return as i64. If those bytes originated from a synth-addr ptr, simulator would silently treat 0x1000... as a hash-state integer. Not in HashMap::new (the named acceptance) but dominant miscompile risk for the bead's class.

## Design

### Policy pick: OPTION 1 (symbolic-address), narrow MVP

Justification: P4 + smallest MVP. Option 2 requires walking use-chain across 3 memcpys (not in current `_handle_memcpy_global_src`). Option 3 too architectural.

**Scope restriction**: only ConstantStruct ptr fields whose operand resolves to `(:named, ref)` or `(:null, 0)` via `_ptr_identity`. **REJECT** `(:addr, K)` (inttoptr-of-const) and `nothing` — those have allocator-dependent address or unresolvable identity, both silent miscompile under symbolic-address.

**Out of scope (kept as rejects, separate follow-ups):** float fields, i128+ wider integer fields, vector fields (vtables), inttoptr-of-const (file `Bennett-land-inttoptr`).

### Address-assignment policy

`0x1000_0000_0000_0000 + counter` with per-module monotonic counter:

```julia
function _assign_synthetic_addr!(addr_assigned, addr_counter, gname)
    haskey(addr_assigned, gname) && return addr_assigned[gname]
    BASE = 0x1000_0000_0000_0000
    addr = BASE | addr_counter[]
    addr_counter[] += 1
    addr_assigned[gname] = addr
    return addr
end
```

**Why `0x1000_0000_0000_0000` base:**
- Bit 60 set → distinguishable from "legitimate" small constants
- Below canonical-address top half — no kernel/sign-extension sentinel collision
- Below `0x8000_0000_0000_0000` → no negative Int64 after reinterpret
- ~4096 distinct addresses (0x1000-0x1FFF prefix), 100× more than 28 t5 hits

**Alternative rejected: `hash(gname)`** — indistinguishable from real constant. Counter scheme has uniqueness by construction + visual distinctness.

**Stability**: `LLVM.globals(mod)` iterates in module-insertion order; same `.ll` produces same address assignment per re-extraction.

### Round-trip + Julia oracle

For `land_t5_tr2_acceptance.ll`:
1. `_flatten_struct_to_bytes` produces 32 bytes:
   - bytes 0-7: `0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x10` (LE-packed `0x1000_0000_0000_0000`)
   - bytes 8-31: zeros (`[24 x i8] zeroinitializer`)
2. Standard memcpy lowering emits 32 IRStore(iconst, 8).
3. Fixture body: `%p = getelementptr inbounds i8, ptr %_3, i64 7; %y = load i8, ptr %p; ret i8 %y`
4. Oracle: `@test simulate(circuit, Int8(0)) == Int8(0x10) == 16`

**Critical detail: load byte 7, not byte 0.** In LE, byte 7 holds the MSByte `0x10`; byte 0 holds `0x00` (indistinguishable from zeroinitializer). Distinctive oracle = load byte 7.

`verify_reversibility` passes by construction — synthetic-address bytes are compile-time constants, same as any ConstantDataArray byte.

### Failure modes / known miscompile risk

| Risk | Scenario | Status under MVP |
|---|---|---|
| R1 | `load ptr, ptr %_3` then deref | NOT in t5_tr2:153 acceptance; EXISTS at t5_tr2:413-417. Mitigation: **gate `Bennett-land-ptrload`** in `_handle_memcpy_global_src` post-emission or function-level pre-check. |
| R2 | `icmp eq ptr1, ptr2` after load | Bennett-cc0 already rejects at extraction; runtime `icmp` would compare synth against real → silent miscompile. Acceptable in MVP (not in t5_tr2:153). |
| R3 | Indirect call through loaded ptr (vtable) | Bennett has no indirect-call support — fails loud elsewhere. |
| R4 | `ptrtoint(loaded_ptr)` runtime | Check if supported; fails loud upstream if not. |
| R5 | Address-counter collision across modules | Each `extract_parsed_ir_from_ll` → fresh counter. Cross-module impossible. |
| R6 | Bit-60-set value matches real allocator addr | Synthetic range is non-canonical (canonical user addrs end at 0x0000_7FFF_FFFF_FFFF). ✓ |

**Mitigation gate (REQUIRED per §1):** add `_check_no_ptr_load_of_synthetic_alloca` to `_handle_memcpy_global_src`. If function body has `load <ptr>, ptr %x` where %x traces to alloca whose only writer is memcpy from struct-global with synth ptr fields → fail loud with `Bennett-land-ptrload`. **~40 LOC.**

### `_flatten_struct_to_bytes` extension

Split current `else return nothing` arm at line 333-338:

```julia
elseif field_ty isa LLVM.PointerType
    if field_val isa LLVM.ConstantPointerNull
        # 8 zero bytes — already zeroed, no counter bump
    elseif field_val isa LLVM.GlobalVariable || field_val isa LLVM.Function ||
           field_val isa LLVM.GlobalAlias
        ident = _ptr_identity(field_val.ref)
        ident === nothing && return nothing
        kind, payload = ident
        if kind === :null  # 8 zero bytes
        elseif kind === :named
            target_name = Symbol(LLVM.name(LLVM.Value(payload)))
            addr = _assign_synthetic_addr!(addr_assigned, addr_counter, target_name)
            ptr_size = Int(LLVM.pointersize(dl, 0))
            ptr_size == 8 || return nothing
            for k in 0:7
                bytes[field_off + k + 1] = UInt8((addr >> (8*k)) & 0xff)
            end
        else  # :addr inttoptr-of-const — REJECT for MVP
            return nothing
        end
    else
        return nothing
    end
else
    return nothing  # Float/Vector/opaque/Token
end
```

Signature change: 2 new params `addr_assigned::Dict{Symbol,UInt64}`, `addr_counter::Base.RefValue{UInt64}`.

### Downstream audit

| Site | Change? |
|---|---|
| `_handle_memcpy_global_src` G5 message | YES — drop `Bennett-zxhg-ptrfield`; mention `Bennett-land-ptrload` |
| G6/G7 dst_ew/multiples | NO |
| Emission loop | NO — synth bytes are just constants |
| `lower_var_gep!` | NO |
| `ir_types.jl::ParsedIR.globals` shape | NO |
| Q04a contract | NO — `_extract_const_globals` signature unchanged |
| 8kno static inspection | NO — new helper logic lives in `_flatten_struct_to_bytes` |
| **NEW R1 mitigation gate** | YES — ~40 LOC in `_handle_memcpy_global_src` or function pre-check |

### Test plan

**New positive fixtures (land flips these from reject):**
1. `land_struct_ptr_to_array.ll` — `<{ ptr, [16 x i8] }>`, load byte 7 → `0x10`
2. `land_struct_null_ptr.ll` — null ptr, load byte 7 → `0x00`
3. `land_struct_two_ptrs.ll` — two distinct ptrs, byte 7 = `0x10`, byte 15 = `0x11`
4. `land_struct_nested_ptr.ll` — recursive `_flatten_struct_to_bytes` through nested struct
5. **`land_t5_tr2_acceptance.ll`** — the bead's literal acceptance fixture

**New reject fixtures:**
6. `land_struct_inttoptr_reject.ll` — `Bennett-land-inttoptr`
7. `land_ptrload_reject.ll` — mirror t5_tr2:413-417's `load ptr, ptr %alloca` shape → `Bennett-land-ptrload`
8. `land_vtable_indirect_call_reject.ll` — vtable + indirect call (probably existing reject)

**Existing zxhg flips (3):**
- Line 145-163 (`ptr-field rejects` → positive). Rename `zxhg_struct_ptr_field_reject.ll` → `zxhg_struct_ptr_field.ll`.
- Line 165-178 (`nested struct rejects` → positive). Rename.
- Line 212-230 (`t5 smoke fails loud` → positive compile). Optional rename.

**Existing zxhg keeps (2):**
- Line 180-193 (float reject) — stays.
- Line 195-208 (i128 reject) — stays.

**Peer sweep:** doih (85), zxhg flipped (90+), 8kno (8), 37mt (86), 9nwt (87), ixiz (53), munq (69), lqif (12), q04a (9), gate-count (39).

**T5 end-to-end smoke:** compile actual `build/t5_tr2_hashmap.ll` HashMap::new. EITHER compiles OR fails loud with `Bennett-land-ptrload`. Both satisfy bead acceptance.

### Risk register + follow-ups

| ID | Risk | Mitigation |
|---|---|---|
| R1 | Loaded-as-ptr miscompile (LocalKey::with pattern) | Gate `Bennett-land-ptrload` |
| R2 | ptr-eq compare synth vs real | Bennett-cc0 upstream reject; file `Bennett-land-icmp` if gap exposed |
| R3 | Counter ordering depends on iter order | Add determinism regression test |
| R4 | Float/i128/vector fields | Out of MVP; file follow-ups |
| R5 | Ptr-size != 8 | Hard-reject; file `Bennett-land-ptrsize32` |
| R6 | GlobalAlias chains > 16 | Bounded by `_ptr_identity` |
| R7 | LLVM.jl version determinism | Pin byte-pattern regression test |

**Follow-ups to file at close:**
- `Bennett-land-ptrload` (P4) — proper handling of load-ptr-of-carried-bytes
- `Bennett-land-inttoptr` (P5) — materialize ptr inttoptr (i64 K to ptr)
- `Bennett-land-vtable` (P5) — vtable shapes with indirect calls
- `Bennett-land-ptrsize32` (P5) — wasm32/arm32 ptr-size 4

## Implementation sketch

1. **`module_walk.jl:253`** — 2 new params on `_flatten_struct_to_bytes`. PointerType arm at line 333-338 (~40 LOC).
2. **`module_walk.jl:368`** — `_extract_const_globals` allocates addr_assigned + addr_counter.
3. **`instructions.jl:483-496`** — G5 wording.
4. **`instructions.jl:559`+ NEW** — `_check_no_ptr_load_of_synthetic_alloca` gate (~40 LOC).
5. **`test_zxhg_struct_global.jl:145-178, 212-230`** — flip 3 testsets; rename 2 fixtures.
6. **`test_land_ptrfield_struct.jl`** (NEW, ~200 LOC).
7. **`runtests.jl`** — register after zxhg.
8. **`fixtures/ll/land_*.ll`** (8 NEW).

**Estimated footprint:** ~70 LOC src + ~30 LOC test edits + ~200 LOC new test + ~150 LOC fixtures.

**Sequencing (RED-GREEN):**
1. Write test + fixtures. RED: positives fail with current `Bennett-zxhg-ptrfield`.
2. Implement `_assign_synthetic_addr!` + PointerType arm. Positives lower; existing zxhg rejects fail.
3. Add R1 gate. R1 reject test green.
4. Rename + flip 3 zxhg testsets. zxhg green.
5. Update G5 wording.
6. Peer regression sweep.
7. T5 end-to-end smoke.

## Summary

Pick Option 1 (symbolic-address) scoped narrowly to named-global / null ptr operands. Justified by t5 corpus's 25/25 ptr-leading-struct globals being Rust panic-Location ABI carried byte-for-byte through memcpy chains, simulator's zero ptr semantics, and `_ptr_identity` (Bennett-cc0) already providing the identity tag. Address policy: `0x1000_0000_0000_0000 + per-module counter` for visual distinctness and non-canonical-address safety. Critical addition: R1 fail-loud gate `Bennett-land-ptrload` rejecting functions that load ptr from synthetic bytes — required per §1. Three existing zxhg reject tests flip to positive (mirrors ixiz/zxhg pattern); two stay rejects. Four follow-up beads filed.

## Blockers / assumptions

- **ASSUMPTION (synth-addr safe for t5_tr2:153):** verified — no `load ptr` of `%_3` locally. R1 gate handles transitive callee risk.
- **ASSUMPTION (`LLVM.globals(mod)` iteration stable):** standard LLVM contract; add determinism regression test.
- **ASSUMPTION (ptr size == 8):** hard-reject otherwise.
- **ASSUMPTION (3 zxhg flips acceptable):** they MUST flip — leaving as `@test_throws` after land lowers their fixtures would fail the suite.
- **NO HARD BLOCKERS:** all required APIs exist.
- **Open question:** include R1 gate in land or defer? Recommend INCLUDE per §1.
