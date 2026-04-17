// T5-TR1: Vec<i8> push×3 + iter sum
//
// This file is part of the Bennett.jl T5 multi-language test corpus (T5-P2c).
// It exercises the unbounded-vector pattern: Vec::new(), push() three times,
// then iter().fold() to sum the elements.
//
// Compile to LLVM IR (from this directory):
//   rustc --emit=llvm-ir -C opt-level=0 --crate-type lib --edition 2021 \
//         -o /tmp/t5_tr1_vec_push.ll t5_tr1_vec_push.rs
//
// The entry function is `vec_push_sum` (mangled in .ll as
// `_ZN...vec_push_sum...` or `vec_push_sum` depending on crate-type lib).
// T5-P5a (extract_parsed_ir_from_ll) is responsible for finding it by
// demangled name prefix matching.

#[no_mangle]
pub fn vec_push_sum(x: i8) -> i8 {
    let mut v: Vec<i8> = Vec::new();
    v.push(x);
    v.push(x.wrapping_add(1));
    v.push(x.wrapping_add(2));
    v.iter().fold(0i8, |a, b| a.wrapping_add(*b))
}
