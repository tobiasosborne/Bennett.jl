; T5-P5a hand-written .ll fixture
; Function: foo(i8) -> i8    (x + 3)

define i8 @foo(i8 %x) {
entry:
  %r = add i8 %x, 3
  ret i8 %r
}
