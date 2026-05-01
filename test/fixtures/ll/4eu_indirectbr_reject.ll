; Bennett-4eu fixture — indirectbr is a Bennett hard stop. Same
; philosophical category as atomicrmw / invoke / landingpad / fence:
; the LLVM semantics require runtime resolution that Bennett's static-
; CFG lowering can't model.

define i32 @julia_f_1(i32 %x) {
entry:
  %target = select i1 1, ptr blockaddress(@julia_f_1, %A),
                          ptr blockaddress(@julia_f_1, %B)
  indirectbr ptr %target, [label %A, label %B]
A:
  ret i32 1
B:
  ret i32 2
}
