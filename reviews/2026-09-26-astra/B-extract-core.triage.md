# Triage — B-extract-core — 2026-09-26

Orchestrator triage of `B-extract-core.md` after independent re-execution of all 26 findings
(`B-extract-core.verification-A.md`: F1–F12 12/12 CONFIRMED; `-B.md`: F13–F26 14/14 CONFIRMED, F21 partially).
Reachability column matters here: several S0s are from_ll-only (still bugs, lower priority);
Julia-reachable silent miscompiles: F1, F6, F7, F12, F13 (+F11 dup).

| Finding | Sev | Disposition |
|---|---|---|
| F1 bare-name callee registry substitutes another module's body (Julia, public API) | S0 | Bennett-p9a0 (P1) |
| F2 zero-fill memset deleted over live data (from_ll; overlaps zmry) | S0 | Bennett-ni9i (P2) |
| F3 sret funnel deletion drops live stores (contradicts closed jghk) | S0 | Bennett-t5u1 (P1) |
| F4 fshl/fshr expansion wrong at shift 0 (from_ll) | S0 | Bennett-ytpe (P2) |
| F5 packed <N x i1> loads read bit 0 (from_ll) | S0 | Bennett-2glq (P2) |
| F7 uitofp i64 → signed conversion; Float64(x::UInt64) wrong for x ≥ 2^63 (Julia) | S0 | Bennett-s6d6 (P1) |
| F8 ParsedIR name conflation (global/param, auto-name) | S0 | Bennett-xzsb (P1) |
| F9 tuple via insertelement/shufflevector into sret → AssertionError; x->(x,x,x,x) (Julia) | S1 | Bennett-q3fa (P2) |
| F10 nested ConstantArray segfault in the LLVM C API | S1 | Bennett-fpa0 (P2) |
| F12 heap.jl drops memset/atomicrmw on element data; fill! on Memory miscompiles (Julia) | S0 | Bennett-7v22 (P1) |
| F13 GEP stride from bit width not allocation size; unsafe_load(Ptr{U24},2) (Julia; overlaps 0ucg) | S0 | Bennett-edt9 (P1) |
| F18 unnamed blocks all Symbol("") (loud) | S1 | Bennett-7o4d (P3) |
| F19 type-tag id 0 collides with null (ptr_cells/VM) | S0 | Bennett-pdwn (P1) |
| F20 vector bitcast ignores big-endian datalayout (from_ll) | S0 latent | Bennett-c3ft (P3) |
| F21 ConstantExpr ptr-compare folds extern_weak vs null to 0 (partially verified) | S1 | Bennett-0juv (P3) |
| F24 inttoptr fold sign-extends narrow addresses (from_ll) | S0 latent | Bennett-ewjv (P3) |
| F25 llvm.{floor,ceil,trunc,rint}.f64 rejected despite claimed dispatch (Julia) | S2 | Bennett-1qws (P2) |
| F26 memssa merges per-function node ids (overlaps extract-vm F8/F13) | S2 | Bennett-7nez (P3) |
| F6 fptosi f32 lowered as bit-preserving IRCast; Julia-reachable | S0 | DUPLICATE → Bennett-3wk7 (note; reachability text corrected; P3→P1) |
| F11 stale circuit after method redefinition | S0 | DUPLICATE → Bennett-4ddk (note) |
| F14 volatile/atomic guard bypassed by vector + sret dispatch | S1 | OVERLAPS closed Bennett-4mmt (note: reopen/follow-up) |
| F15 MemorySSA stderr pipe deadlock (opt-in use_memory_ssa) | S2 | DUPLICATE → extract-vm F12 (triage pending) |
| F16 recursive callgraph walk duplicates root | S2 | DUPLICATE → extract-vm F9 (triage pending) |
| F17 store through non-jl_global alias erased | S0 | DUPLICATE → Bennett-n4di (note; consider P1) |
| F22 array alloca outer count dropped | S1 | DUPLICATE → Bennett-uiqq (note) |
| F23 closed-world validation accepts ambiguous specialisation calls (Julia functor) | S1 | DUPLICATE → Bennett-zuk5 (note; framing too weak) |

All new beads carry label `astra-2026-09-26` and `discovered-from:Bennett-yjd5`.
