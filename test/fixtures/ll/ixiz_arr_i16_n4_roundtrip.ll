; Bennett-ixiz fixture (T2) — `[4 x i16]` ArrayType alloca round-trip.
;
; Pre-ixiz, the alloca handler in src/extract/instructions.jl bailed at
; `LLVM.width(inner) == 8 || return nothing` (line 1975), silently
; dropping the IRAlloca. Post-ixiz, the gate is lifted to accept any
; integer inner width, emitting `IRAlloca(_, 16, iconst(4))`.

define i16 @arr_i16_n4_rt(i16 %x) {
entry:
  %p = alloca [4 x i16], align 8
  store i16 %x, ptr %p
  %y = load i16, ptr %p
  ret i16 %y
}
