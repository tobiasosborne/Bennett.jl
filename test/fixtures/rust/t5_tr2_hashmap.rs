// T5-TR2: HashMap<i8,i8> insert + get roundtrip
//
// This file is part of the Bennett.jl T5 multi-language test corpus (T5-P2c).
// It exercises the hashing + dynamic-allocation pattern via
// std::collections::HashMap.
//
// The PRD (Bennett-Memory-T5-PRD.md §7.3) notes: "If rustc's HashMap produces
// too much LLVM (>10k lines), TR2 falls back to a hand-rolled hash table."
// Measured line count: 6,113 lines (rustc 1.95.0, opt-level=0) — under threshold.
// No fallback was needed.
//
// Compile to LLVM IR (from this directory):
//   rustc --emit=llvm-ir -C opt-level=0 --crate-type lib --edition 2021 \
//         -o /tmp/t5_tr2_hashmap.ll t5_tr2_hashmap.rs
//
// The entry function is `hashmap_roundtrip` (appears as `@hashmap_roundtrip`
// in the .ll due to #[no_mangle]).

#[no_mangle]
pub fn hashmap_roundtrip(k: i8, v: i8) -> i8 {
    let mut m = std::collections::HashMap::new();
    m.insert(k, v);
    *m.get(&k).unwrap_or(&0)
}
