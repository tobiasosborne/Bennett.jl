# Per-source-file test index

Bennett-8403 / U159 — when a regression touches `src/X.jl`, this file
points at where the corresponding test lives. The catalogue calls for
"per-source-file unit tests" — exhaustive 1:1 coverage of all 70+
src files would explode the test/ namespace; this index is the
pragmatic compromise.

**Convention (from this point forward):** new regressions for
`src/X.jl` go in `test/test_X.jl`. If `test/test_X.jl` doesn't exist
yet, create it (use `test/test_bennett.jl` / `test/test_lower.jl` /
`test/test_ir_extract.jl` as templates).

## Top-level src files

| Source                            | Direct test file                      | Notes |
|-----------------------------------|---------------------------------------|---|
| `src/Bennett.jl`                  | `test/test_bennett.jl`                | Module entrypoint, kwarg validation, CompileOptions |
| `src/adder.jl`                    | `test/test_two_args.jl`               | Cuccaro / ripple lowering covered by add-dispatcher tests |
| `src/bennett_transform.jl`        | `test/test_egu6_*.jl`, `test/test_cvnb_*.jl` | bennett(lr) + self_reversing |
| `src/bennett_strategies.jl`       | `test/test_bennett_strategy.jl`       | Bennett-i2ca / U55 — `BennettStrategy` dispatch parity |
| `src/callees.jl`                  | (every test using soft_*)             | Registration loop — exercised universally |
| `src/compose.jl`                  | `test/test_compose.jl`                | (create as needed) |
| `src/controlled.jl`               | `test/test_controlled.jl`             | ✓ exists |
| `src/dep_dag.jl`                  | `test/test_dep_dag.jl`                | ✓ exists |
| `src/diagnostics.jl`              | `test/test_*_count.jl` etc.           | gate_count / depth / verify_reversibility |
| `src/divider.jl`                  | `test/test_division.jl`               | soft_udiv / soft_urem |
| `src/fast_copy.jl`                | `test/test_fast_copy.jl`              | ✓ exists |
| `src/feistel.jl`                  | `test/test_feistel.jl`                | ✓ exists |
| `src/gates.jl`                    | `test/test_k7al_ir_constructor_asserts.jl` | Constructor assertions |
| `src/ir_extract.jl`               | `test/test_ir_extract.jl`             | Module-loader; per-arm in test/test_*_*.jl |
| `src/ir_types.jl`                 | `test/test_k7al_ir_constructor_asserts.jl` | All IR* constructor validation |
| `src/lower.jl`                    | `test/test_lower.jl`                  | Module-loader; per-arm in test/test_*_*.jl |
| `src/memssa.jl`                   | `test/test_memssa.jl`                 | ✓ exists |
| `src/mul_qcla_tree.jl`            | `test/test_mul_qcla_tree.jl`          | ✓ exists |
| `src/multiplier.jl`               | `test/test_two_args.jl`, `test/test_mul_dispatcher.jl` | shift_add / qcla_tree paths |
| `src/narrow.jl`                   | `test/test_narrow.jl`                 | ✓ exists |
| `src/parallel_adder_tree.jl`      | `test/test_parallel_adder_tree.jl`    | ✓ exists |
| `src/partial_products.jl`         | `test/test_partial_products.jl`       | ✓ exists |
| `src/precompile.jl`               | (not directly tested)                 | PrecompileTools.@compile_workload |
| `src/qcla.jl`                     | `test/test_qcla.jl`                   | ✓ exists |
| `src/qrom.jl`                     | `test/test_qrom.jl`                   | ✓ exists |
| `src/shadow_memory.jl`            | `test/test_shadow_memory.jl`          | ✓ exists |
| `src/simulator.jl`                | (every test calling `simulate`)       | Universal |
| `src/softfloat_dispatch.jl`       | `test/test_float_circuit.jl`          | Float64 wrapper struct + dispatch |
| `src/softmem.jl`                  | `test/test_rev_memory.jl`             | soft_mux_load_*/soft_mux_store_* |
| `src/tabulate.jl`                 | `test/test_tabulate.jl`               | ✓ exists |
| `src/wire_allocator.jl`           | `test/test_wire_allocator.jl`         | ✓ exists |

## Subdirectory mappings

`src/extract/*.jl` (post-x3jc, 9 files) — per-arm tests live in
`test/test_<topic>.jl` (e.g. `test_vector_ir.jl`, `test_t3j0_*` for
switch label collisions, `test_atf4_*` for call-handling). The shared
entry point is covered by `test/test_ir_extract.jl`.

`src/lowering/*.jl` (post-vdlg, 9 files) — per-arm tests live across
the feature-oriented suites. The shared driver is covered by
`test/test_lower.jl`. Phi-resolution tests are in `test_p94b_*`,
`test_fq8n_*`, `test_jepw_*`, `test_y986_*`.

`src/pebble/*.jl` (5 files: pebbling, eager, value_eager,
pebbled_groups, pebbled_bennett) — `test/test_eager_bennett.jl`,
`test/test_value_eager.jl`, `test/test_pebbled_*.jl`,
`test/test_pebbled_wire_reuse.jl`.

`src/softfloat/*.jl` (17 files) — per-primitive tests in
`test/test_softf*.jl` (test_softfadd.jl, test_softfsub.jl, ...);
NaN/Inf corner cases in `test_r84x_*`, `test_xy4j_*`, `test_m63k_*`,
`test_xiqt_*`, `test_tpg0_*`, `test_yys3_*`.

`src/persistent/*.jl` (4 files + research/ subdir) —
`test/test_persistent_hashcons.jl`, `test/test_ivoa_*` for harness
invariants.

## Notes

- Per-source files don't need to be exhaustive — they're a NAVIGATION
  AID, not a coverage gate. Feature-oriented tests remain the primary
  correctness gate.
- When splitting / renaming a src file, check this index for stale
  pointers. Re-run `for src in src/*.jl; do ls test/test_$(basename
  $src .jl).jl 2>/dev/null && echo MATCH; done` to spot drift.
