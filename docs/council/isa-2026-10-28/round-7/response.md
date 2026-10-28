# Editor's response to ISA round 7

Verdicts: **codex accept, muse accept**, opus revise. Mean 4.12 (2.12 →
2.83 → 3.04 → 2.83 → 3.12 → 3.92 → 4.12). **Core consensus: every member
returns `verdict_core` = accept with no core blocker** — the first
milestone of the rubric. One contract blocker (opus B1; codex reports
the same defect as non-blocking). Status to the maintainer: **core
accepted**; contracts one line short of consensus.

## Error acknowledged

Draft 0.7's producer recipe for strictly feasible SDP witnesses was
wrong: `mu + δ·d` leaves `mu·I − Tr_out(Y)` unchanged because
Tr_out(δI_{d²}) = δ·d·I_d, so a tight witness is rejected by every
conformant checker. Draft 0.8 states `mu′ = mu + δ·(d + 1)` (any mu′ >
mu + δ·d), which makes all three matrices ⪰ δI. This is the only
normative change; the version string moves to 0.8 and the four example
hashes are recomputed.

## Not changed

Suggestions (S1 and nits) from all three members are carried to the
`bennett-isa-spec` repository's issue list once the document moves there
(north star §6.1); none affects what two implementers would build.
