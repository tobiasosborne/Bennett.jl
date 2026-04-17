#include <stdint.h>
#include <stdlib.h>

/* TC2: growing buffer via realloc
 *
 * T5 test corpus (T5-P2b) — Bennett.jl
 * Pattern: malloc + realloc (resize semantics).
 * Reference: realloc_buf(x) == x + (x+1) + (x+2) + (x+3) = 4x + 6 (mod 256)
 *
 * Compiled with:
 *   clang -O0 -emit-llvm -S -o t5_tc2_realloc.ll t5_tc2_realloc.c
 */
int8_t realloc_buf(int8_t x) {
    int8_t* v = (int8_t*)malloc(2 * sizeof(int8_t));
    v[0] = x; v[1] = x+1;
    v = (int8_t*)realloc(v, 4 * sizeof(int8_t));
    v[2] = x+2; v[3] = x+3;
    int8_t r = v[0] + v[1] + v[2] + v[3];
    free(v);
    return r;
}
