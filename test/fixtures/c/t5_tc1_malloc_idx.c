#include <stdint.h>
#include <stdlib.h>

/* TC1: dynamic-index heap array
 *
 * T5 test corpus (T5-P2b) — Bennett.jl
 * Pattern: malloc + dynamic (runtime) index.
 * Reference: malloc_idx_inc(x, i) == x + (i & 7)
 *
 * Compiled with:
 *   clang -O0 -emit-llvm -S -o t5_tc1_malloc_idx.ll t5_tc1_malloc_idx.c
 */
int8_t malloc_idx_inc(int8_t x, int8_t i) {
    int8_t* v = (int8_t*)malloc(8 * sizeof(int8_t));
    v[0] = x;     v[1] = x+1; v[2] = x+2; v[3] = x+3;
    v[4] = x+4;   v[5] = x+5; v[6] = x+6; v[7] = x+7;
    int8_t r = v[i & 7];  /* dynamic index — the pattern that triggers T5 */
    free(v);
    return r;
}
