// T5-TR3: Box<Node> singly-linked list (3 nodes)
//
// This file is part of the Bennett.jl T5 multi-language test corpus (T5-P2c).
// It exercises the Box heap-allocation pattern with a mutable recursive type.
// Three nodes are chained: n1 -> n2 -> n3.  The function returns n1.val
// (i.e., `x`), which forces rustc to actually construct all three nodes and
// keep them live until the return.
//
// Compile to LLVM IR (from this directory):
//   rustc --emit=llvm-ir -C opt-level=0 --crate-type lib --edition 2021 \
//         -o /tmp/t5_tr3_box_list.ll t5_tr3_box_list.rs
//
// The entry function is `box_list` (appears as `@box_list` in the .ll due to
// #[no_mangle]).

#[allow(dead_code)]
struct Node {
    val: i8,
    next: Option<Box<Node>>,
}

#[no_mangle]
pub fn box_list(x: i8) -> i8 {
    let n = Box::new(Node {
        val: x,
        next: Some(Box::new(Node {
            val: x.wrapping_add(1),
            next: Some(Box::new(Node {
                val: x.wrapping_add(2),
                next: None,
            })),
        })),
    });
    n.val
}
