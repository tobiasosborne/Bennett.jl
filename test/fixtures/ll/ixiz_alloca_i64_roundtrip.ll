; Bennett-ixiz fixture (T1) — wider-element alloca round-trip.
;
; A single `alloca i64`, store-then-load round-trip. Pre-ixiz, this
; bailed at the extract layer (memcpy/memset gates were the canonical
; ew=64 blockers; for plain store/load on `alloca i64` the lowering
; already accepted but only when no memcpy/memset path was attempted).
;
; Post-ixiz, the same pattern still works (no IR shape change) — this
; fixture pins the round-trip for the regression base.

define i64 @alloca_i64_rt(i64 %x) {
entry:
  %p = alloca i64, align 8
  store i64 %x, ptr %p, align 8
  %y = load i64, ptr %p, align 8
  ret i64 %y
}
