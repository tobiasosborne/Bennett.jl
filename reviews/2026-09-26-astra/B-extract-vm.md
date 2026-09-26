# Astra review — B-extract-vm — 2026-09-26
Status: IN PROGRESS
Scope: src/extract/{dict_vm,vector_vm,vector_vm_walk,vector_vm_emit,vector_vm_cfg,vector_vm_term,heap,callgraph,julia_set}.jl; src/memssa.jl
Method: Read CLAUDE.md in full. Targeted source/ADR/test inspection and bounded Julia probes; no full suite. Only this report is written, per the review-specific instructions (which supersede worklog/beads/commit requirements).

## Executive summary
Pending completion.

## Findings

### F1 — [S0] Vector prelude collapse deletes an ordinary early return
- Where: src/extract/vector_vm_cfg.jl:112–156; src/extract/vector_vm_emit.jl:70–88.
- Evidence: VERIFIED-BY-EXECUTION, Julia 1.12.3, `julia --project --check-bounds=yes -e 'using Bennett; function probe(n::Int64); n == 2 && return Int8(99); v=Vector{Int8}(undef,n); s=Int8(0); for i in 1:n; v[i]=Int8(i%100); s+=v[i]; end; s; end; p=Bennett.extract_parsed_ir(probe,Tuple{Int64};optimize=false,mem=:vm); println(probe(2)); for b in p.blocks; println(b); end'`. Native output is `99`. Extraction succeeds; the synthetic entry contains only `IRAlloca(n)`, `icmp sle 1,n`, and its xor. The `n == 2` test and `ret 99` are absent. The only emitted return is the loop sum (1+2 = 3).
- Failure scenario: a valid Vector routine with a guard return before allocation loses that guard and executes the allocation/loop instead. `_vec_vm_prelude_blocks` marks **all** entry-reachable blocks before the chosen loop-bound block as prelude, including user return blocks. No check certifies those blocks as disposable machinery.
- Fix: preserve user CFG and move only positively certified allocation instructions; as an immediate safe fix reject any prelude with a user return, user branch, side effect, or surviving value definition outside the chosen exit block. Prove the chosen exit dominates the surviving body and validate SSA dominance after rewriting.
- Test: native-versus-VM execution and reversal for this function at n=0,1,2,3; also a scalar computation and a user side effect before allocation.
- Already tracked? no matching open bead.

## Unconfirmed suspicions

## What is sound (brief)

## Nits (S4)

## Coverage log
- Repository instructions read in full; source review starting.
