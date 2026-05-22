; Bennett-bd5f / M4 — C/Rust heap-allocator reject fixture.
;
; A minimal hand-written module modelling a C function that heap-allocates via
; `@malloc` (NOT the Julia GC allocator `@ijl_gc_small_alloc`). Under
; `mem=:heap` the M4 scope guard must reject this with a precise C/Rust
; heap-allocator message — the heap-memory recogniser models ONLY the Julia GC
; allocator. There is intentionally NO `@ijl_gc_small_alloc` in this module.
;
; Idiom mirrors the heap_m3_*.ll fixtures: parsed via LLVM.Context()+parse and
; driven through _module_to_parsed_ir(mod; mem=:heap).

target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

declare ptr @malloc(i64)
declare void @free(ptr)

; A C-style `f(x) { p = malloc(8); *p = x; r = *p; free(p); return r; }`.
define i8 @julia_cmalloc_1(i8 signext %x) #0 {
top:
  %p = call ptr @malloc(i64 8)
  store i8 %x, ptr %p, align 1
  %r = load i8, ptr %p, align 1
  call void @free(ptr %p)
  ret i8 %r
}

attributes #0 = { "probe-stack"="inline-asm" }
