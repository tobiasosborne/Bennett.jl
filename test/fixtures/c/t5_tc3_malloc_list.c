#include <stdint.h>
#include <stdlib.h>

/* TC3: malloc-based singly-linked list
 *
 * T5 test corpus (T5-P2b) — Bennett.jl
 * Pattern: malloc + pointer-chained recursive type (mutable linked list).
 * Reference: malloc_list(x) == x + (x+1) + (x+2) = 3x + 3 (mod 256)
 *
 * Compiled with:
 *   clang -O0 -emit-llvm -S -o t5_tc3_malloc_list.ll t5_tc3_malloc_list.c
 */
typedef struct Node { int8_t val; struct Node* next; } Node;

int8_t malloc_list(int8_t x) {
    Node* a = (Node*)malloc(sizeof(Node));
    Node* b = (Node*)malloc(sizeof(Node));
    Node* c = (Node*)malloc(sizeof(Node));
    a->val = x;     a->next = b;
    b->val = x + 1; b->next = c;
    c->val = x + 2; c->next = (Node*)0;
    int8_t r = a->val + b->val + c->val;
    free(c); free(b); free(a);
    return r;
}
