; Bennett-t9rh: host-independent poison-lane fixtures for the cc0.7 vector
; scalariser (src/extract/vectors.jl). Each function reproduces an idiom the
; LLVM SLP / loop vectorisers emit, in which a vector lane is `poison` but is
; never OBSERVED (extracted / returned). The scalariser must propagate the
; poison lane (LLVM LangRef 18, "Poison Values") instead of emitting a scalar
; op over it, and must still fail loud when a poison lane IS observed.

declare <2 x i64> @llvm.umax.v2i64(<2 x i64>, <2 x i64>)
declare i64 @llvm.vector.reduce.add.v2i64(<2 x i64>)

; SLP horizontal-add idiom, verbatim shape from AVX-512 soft_fmul:
; lane0 = a + b, lane1 = b + poison (dead).
define i64 @hadd(i64 %a, i64 %b) {
top:
  %0 = insertelement <2 x i64> poison, i64 %a, i64 0
  %1 = insertelement <2 x i64> %0, i64 %b, i64 1
  %shift = shufflevector <2 x i64> %1, <2 x i64> poison, <2 x i32> <i32 1, i32 poison>
  %2 = add nsw <2 x i64> %1, %shift
  %3 = extractelement <2 x i64> %2, i64 0
  ret i64 %3
}

; Loop-vectoriser splat with poison mask lanes (AVX2 `k` array loop idiom):
; lanes 0 and 2 are poison; lanes 1 and 3 are x<<1 and x<<2. Result = 6x.
define i64 @splat_shl(i64 %x) {
top:
  %s0 = insertelement <4 x i64> poison, i64 %x, i64 0
  %s = shufflevector <4 x i64> %s0, <4 x i64> poison, <4 x i32> <i32 poison, i32 0, i32 poison, i32 0>
  %v = shl <4 x i64> %s, <i64 0, i64 1, i64 0, i64 2>
  %e1 = extractelement <4 x i64> %v, i64 1
  %e3 = extractelement <4 x i64> %v, i64 3
  %r = add i64 %e3, %e1
  ret i64 %r
}

; icmp + zext + select with poison lanes in the compare, the cast and one
; select arm. Lane 0 = (y > 3) ? zext(x < 10) : y.
define i8 @cmp_sel(i8 %x, i8 %y) {
top:
  %a0 = insertelement <2 x i8> poison, i8 %x, i64 0
  %c = icmp ult <2 x i8> %a0, <i8 10, i8 10>
  %z = zext <2 x i1> %c to <2 x i8>
  %b0 = insertelement <2 x i8> poison, i8 %y, i64 0
  %b1 = insertelement <2 x i8> %b0, i8 %x, i64 1
  %d = icmp ugt <2 x i8> %b1, <i8 3, i8 3>
  %sel = select <2 x i1> %d, <2 x i8> %z, <2 x i8> %b1
  %e = extractelement <2 x i8> %sel, i64 0
  ret i8 %e
}

; Poison lane threaded through add -> icmp -> zext -> lane-wise intrinsic
; (llvm.umax) -> select; only lane 0 is observed.
;   s = a + b; c = s <u a; z = zext c; m = umax(s, z); r = c ? z : m
define i64 @hsum(i64 %a, i64 %b) {
top:
  %0 = insertelement <2 x i64> poison, i64 %a, i64 0
  %1 = insertelement <2 x i64> %0, i64 %b, i64 1
  %sh = shufflevector <2 x i64> %1, <2 x i64> poison, <2 x i32> <i32 1, i32 poison>
  %s = add <2 x i64> %1, %sh
  %c = icmp ult <2 x i64> %s, %1
  %z = zext <2 x i1> %c to <2 x i64>
  %m = call <2 x i64> @llvm.umax.v2i64(<2 x i64> %s, <2 x i64> %z)
  %sel = select <2 x i1> %c, <2 x i64> %z, <2 x i64> %m
  %r = extractelement <2 x i64> %sel, i64 0
  ret i64 %r
}

; Select with a poison FALSE arm in the observed lane: LangRef permits
; refining `select c, a, poison` to `a` (InstSimplify: select ?, X, poison -> X).
define i64 @sel_poison_false(i64 %a, i64 %b) {
top:
  %av = insertelement <2 x i64> poison, i64 %a, i64 0
  %bv = insertelement <2 x i64> poison, i64 %b, i64 0
  %c = icmp ugt <2 x i64> %bv, <i64 100, i64 100>
  %sel = select <2 x i1> %c, <2 x i64> %av, <2 x i64> poison
  %r = extractelement <2 x i64> %sel, i64 0
  ret i64 %r
}

; Mirror: poison TRUE arm, select c, poison, a -> a.
define i64 @sel_poison_true(i64 %a, i64 %b) {
top:
  %av = insertelement <2 x i64> poison, i64 %a, i64 0
  %bv = insertelement <2 x i64> poison, i64 %b, i64 0
  %c = icmp ugt <2 x i64> %bv, <i64 100, i64 100>
  %sel = select <2 x i1> %c, <2 x i64> poison, <2 x i64> %av
  %r = extractelement <2 x i64> %sel, i64 0
  ret i64 %r
}

; A vector op whose EVERY lane is poison and whose result is unused: must
; produce no IR at all (and so no gates) — `dead` compiles to the same
; circuit as `dead_ref`.
define i64 @dead(i64 %x) {
top:
  %p = add <2 x i64> poison, <i64 1, i64 1>
  %q = icmp eq <2 x i64> %p, <i64 0, i64 0>
  %z = zext <2 x i1> %q to <2 x i64>
  %r = add i64 %x, 5
  ret i64 %r
}

define i64 @dead_ref(i64 %x) {
top:
  %r = add i64 %x, 5
  ret i64 %r
}

; ---- observation points: must still FAIL LOUD ----

; Extracting the propagated poison lane (lane 1 of the horizontal add).
define i64 @hadd_lane1(i64 %a, i64 %b) {
top:
  %0 = insertelement <2 x i64> poison, i64 %a, i64 0
  %1 = insertelement <2 x i64> %0, i64 %b, i64 1
  %shift = shufflevector <2 x i64> %1, <2 x i64> poison, <2 x i32> <i32 1, i32 poison>
  %2 = add nsw <2 x i64> %1, %shift
  %3 = extractelement <2 x i64> %2, i64 1
  ret i64 %3
}

; Horizontal reduction over a vector with a propagated poison lane.
define i64 @reduce_poison(i64 %a, i64 %b) {
top:
  %0 = insertelement <2 x i64> poison, i64 %a, i64 0
  %1 = insertelement <2 x i64> %0, i64 %b, i64 1
  %shift = shufflevector <2 x i64> %1, <2 x i64> poison, <2 x i32> <i32 1, i32 poison>
  %2 = add <2 x i64> %1, %shift
  %3 = call i64 @llvm.vector.reduce.add.v2i64(<2 x i64> %2)
  ret i64 %3
}

; <2 x i1> -> i2 bitcast of a mask with a propagated poison lane.
define i8 @bitcast_poison(i64 %a) {
top:
  %0 = insertelement <2 x i64> poison, i64 %a, i64 0
  %c = icmp ugt <2 x i64> %0, <i64 7, i64 7>
  %m = bitcast <2 x i1> %c to i2
  %r = zext i2 %m to i8
  ret i8 %r
}

; ---- undef is NOT poison ----

; Legacy undef-placeholder splat: undef lanes flow only through plumbing
; (insertelement base, shufflevector) and are never read — must compile.
; Result = (x + 1) + (x + 2).
define i64 @undef_splat(i64 %x) {
top:
  %i = insertelement <2 x i64> undef, i64 %x, i64 0
  %s = shufflevector <2 x i64> %i, <2 x i64> undef, <2 x i32> zeroinitializer
  %v = add <2 x i64> %s, <i64 1, i64 2>
  %e0 = extractelement <2 x i64> %v, i64 0
  %e1 = extractelement <2 x i64> %v, i64 1
  %r = add i64 %e0, %e1
  ret i64 %r
}

; `or undef, -1` is exactly -1 (LangRef), NOT poison. Were undef lanes
; conflated with poison, lane 1 of %o would "propagate" as poison, lane 0 of
; %sh would be poison, and the select refinement would silently return %a for
; every input — a miscompile for a <= 10 (correct result: -1). Must fail loud.
define i64 @undef_or_sel(i64 %a) {
top:
  %u = insertelement <2 x i64> undef, i64 %a, i64 0
  %o = or <2 x i64> %u, <i64 -1, i64 -1>
  %sh = shufflevector <2 x i64> %o, <2 x i64> poison, <2 x i32> <i32 1, i32 poison>
  %av = insertelement <2 x i64> poison, i64 %a, i64 0
  %c = icmp ugt <2 x i64> %av, <i64 10, i64 10>
  %sel = select <2 x i1> %c, <2 x i64> %av, <2 x i64> %sh
  %r = extractelement <2 x i64> %sel, i64 0
  ret i64 %r
}
