# ---- Bit-width narrowing of ParsedIR (Bennett-19g6; soundness: Bennett-mrhg) --
#
# Used by `reversible_compile(f, T; bit_width=W)` to compile a function
# written for a source scalar width S (8 for Int8/UInt8) as if it operated on
# W-bit two's-complement integers.  All arithmetic wraps mod 2^W.
#
# Bennett-mrhg: this pass is an ALLOWLIST, and it was previously a blind
# rewrite of every width in the already-extracted ParsedIR.  The values and
# GUARDS that the Julia front end bakes into that IR are expressed at the
# SOURCE width, so re-typing the widths while leaving those values alone
# silently changed what the circuit computes (Astra 2026-09-26 B-lowering
# F3/F13):
#
#   * `Int8(1) << x` at W=4 returned [0,0,0,0,0] (optimize=false) and 1 for
#     x=4 (optimize=true) — the shift-amount guard compares the Int64-promoted
#     amount against the source constant 8, and the shift itself is a runtime
#     barrel shift;
#   * `x >> 1` at W=3/W=4 (optimize=false) died in `lower_ashr!` with
#     "constant shift k=7 out of [0, W]" — that k=7 is the sign-fill guard's
#     SOURCE bit index;
#   * at bit_width=8, where no data width changes at all, `Int8(1) << x`
#     returned 0 for x=1: the i64 `icmp sle typemin(Int64), sext(x)` undef
#     guard has its constant re-typed to `sle 0, x`, which fires for every
#     x >= 0;
#   * a 2-tuple return reached lowering as `_lower_store_via_shadow!: idx=2
#     out of range [0, 2)` (optimize=false) or `resolve!: ... length(wires)=8
#     but caller advertised width=4` (optimize=true) — the packed aggregate
#     layout and the uniform width rewrite disagree.
#
# The contract this file implements: EITHER the rewrite provably preserves
# W-bit two's-complement modular semantics, OR the compile throws an
# `ArgumentError` naming Bennett-mrhg.  Never a plausible-looking wrong
# circuit (CLAUDE.md §1).

# ---- the allowlist ----------------------------------------------------------

# Arithmetic / bitwise ops commute with truncation to W bits: the low W bits
# of the W-bit operation are the low W bits of the S-bit operation.
const _NARROW_ARITH_OPS = (:add, :sub, :mul, :and, :or, :xor)
# Shifts are W-bit shifts — but only with a CONSTANT amount in [0, W] (see
# `_narrow_inst(::IRBinOp, ...)`); a shift amount is a count, not data.
const _NARROW_SHIFT_OPS = (:shl, :lshr, :ashr)
const _NARROW_CAST_OPS  = (:trunc, :sext, :zext)
# Comparison predicates that read their operands as SIGNED values.  `eq`/`ne`
# and the unsigned predicates are re-typed only against constants whose value
# is the same in every reading; the constant each admits is in
# `_narrow_cmp_consts` (Bennett-6p8j, Bennett-koi8).
const _NARROW_SIGNED_PREDS = (:slt, :sle, :sgt, :sge)

_narrow_reject(why::AbstractString) = throw(ArgumentError(
    "reversible_compile(...; bit_width=W): refusing to narrow — $why. " *
    "bit-width narrowing re-types a function to W-bit two's-complement modular " *
    "semantics and is an allowlist: narrowable are add/sub/mul/and/or/xor, " *
    "constant-amount shifts with 0 <= k <= W, comparisons against a " *
    "constant that fits in W bits (signed orderings: a signed W-bit value; " *
    "unsigned orderings and eq/ne: 0..2^(W-1)-1; under optimize=true at " *
    "W < S no signed orderings, and only arguments and and/or/xor/select/phi " *
    "of them may be compared), selects, " *
    "trunc/sext/zext between the iS and i1 domains, and iS/i1 phis/branches " *
    "over those.  Compile without `bit_width`, or rewrite the function in " *
    "terms of them. (Bennett-mrhg)"))

# W-bit range bounds for a comparison constant.  Written without `1 << W` at
# W = 63/64 so no shift overflow is possible.
_narrow_smin(W::Int) = W >= 64 ? typemin(Int) : -(1 << (W - 1))
_narrow_smax(W::Int) = W >= 64 ? typemax(Int) : (1 << (W - 1)) - 1
_narrow_umax(W::Int) = W >= 64 ? typemax(Int) : (1 << W) - 1

# i1 (boolean) values — icmp results, short-circuit `&&`/`||`, branch
# conditions — are logical, not numeric: they keep width 1.
_narrow_w(width::Int, W::Int) = width > 1 ? W : 1

# The only SOURCE domains a narrowing rewrite may touch are the natural
# scalar width S and i1.  Anything else is a second data domain (an Int16
# user cast, the Int64 the front end promotes to, a 64-bit return), whose
# re-typed comparisons mean something else — the shape of every source-width
# guard this pass refuses.
function _narrow_domain(width::Int, S::Int, what::AbstractString)
    (width == S || width == 1) && return nothing
    return _narrow_reject(
        "$what lives in an i$(width) domain, but the source scalar width is " *
        "i$S: a widened (or narrowed) value is a second data domain whose " *
        "guards and limits are the SOURCE ones — re-typing it to W bits does " *
        "not re-type the test that reads it")
end

# Every operand must be a plain SSA name or a literal.  The extractor-internal
# sentinels (ZeroAggSentinel, OpaquePtrSentinel, PoisonLaneSentinel, ...) mark
# aggregates, vectors and opaque pointers, none of which have a W-bit meaning.
function _narrow_operands(ops, what::AbstractString)
    for op in ops
        (op isa SSAOperand || op isa ConstOperand) && continue
        _narrow_reject("$what reads a `$(typeof(op))` operand, which stands " *
                       "for an aggregate, a vector lane or an opaque pointer " *
                       "— not a W-bit value")
    end
    return nothing
end

# ---- shape checks -----------------------------------------------------------

# One source width to re-type, from the argument list.
function _narrow_source_width(parsed::ParsedIR)
    isempty(parsed.args) && _narrow_reject(
        "the function takes no arguments, so there is no source scalar width " *
        "to re-type to W bits")
    widths = sort(unique(w for (_, w) in parsed.args))
    length(widths) == 1 || _narrow_reject(
        "the arguments have mixed source widths $widths: narrowing re-types " *
        "ONE source width, and a per-argument rewrite would not define a " *
        "single W-bit machine")
    S = widths[1]
    S >= 2 || _narrow_reject(
        "the source argument width is i$S: there is no scalar data domain to " *
        "re-type (i1 arguments are boolean controls, not data)")
    return S
end

# A single scalar return at the source width.  An aggregate (tuple return /
# sret struct) has a packed field layout, and a differing return width is a
# different type — neither is a uniform width rewrite (F13).
function _narrow_check_return(parsed::ParsedIR, S::Int)
    rets = parsed.ret_elem_widths
    isempty(rets) && _narrow_reject(
        "the function returns no value, so there is no scalar return width to " *
        "re-type to W bits")
    length(rets) == 1 || _narrow_reject(
        "the return value is an aggregate of $(length(rets)) elements (widths " *
        "$rets — a tuple return / packed struct): its field layout and the " *
        "byte offsets that address it are not wire widths, so re-typing the " *
        "element widths corrupts the layout (Bennett-mrhg, Astra F13)")
    rets[1] == S || _narrow_reject(
        "the return width is i$(rets[1]) but the source scalar width is i$S: " *
        "a returning function of a different width is a second data domain")
    return nothing
end

# Loops are unrolled at the SOURCE width by `lower_loop!`; the unrolled
# circuit is not the W-bit program.  Refuse any back edge rather than reason
# about unrolling soundness (Bennett-mrhg).
function _narrow_check_acyclic(parsed::ParsedIR)
    succ = Dict{Symbol, Vector{Symbol}}()
    for blk in parsed.blocks
        t = blk.terminator
        t isa IRBranch || continue
        succ[blk.label] = Symbol[l for l in (t.true_label, t.false_label)
                                 if l !== nothing]
    end
    # 0 = unseen, 1 = on the DFS stack, 2 = done.  Iterative to keep deep CFGs
    # off the Julia stack.
    colour = Dict{Symbol, Int}(l => 0 for l in keys(succ))
    for root in keys(succ)
        colour[root] == 0 || continue
        colour[root] = 1
        stack = Tuple{Symbol, Int}[(root, 1)]
        while !isempty(stack)
            node, i = pop!(stack)
            kids = get(succ, node, Symbol[])
            if i <= length(kids)
                push!(stack, (node, i + 1))
                kid = kids[i]
                kc = get(colour, kid, 2)
                kc == 2 && continue
                kc == 1 && _narrow_reject(
                    "the block graph has a cycle through `:$kid`: `lower_loop!` " *
                    "unrolls a loop at the SOURCE width, which is not the same " *
                    "computation as the W-bit one")
                colour[kid] = 1
                push!(stack, (kid, 1))
            else
                colour[node] = 2
            end
        end
    end
    return nothing
end

# ---- the pass ---------------------------------------------------------------

"""
    _narrow_ir(parsed::ParsedIR, W::Int) -> ParsedIR

Re-type a ParsedIR from its source scalar width S to W bits, so a function
written for Int8 computes in W-bit two's-complement modular arithmetic (all
arithmetic wraps mod 2^W).

Bennett-mrhg: this is an ALLOWLIST.  Every instruction, operand kind, width
and comparison constant is checked against the narrowable set above; anything
else — a widened domain, a source-width limit guard, a runtime shift amount, a
shift count outside [0, W], an aggregate return, memory, a call, a loop —
throws an `ArgumentError` naming the bead.  It never returns a circuit that
computes something other than W-bit modular semantics.

`optimized` (Bennett-koi8) says whether `parsed` came out of LLVM's optimizer
(`optimize=true`, the default and the conservative answer).  Optimized IR can
hold comparisons the optimizer FOLDED out of source orderings, so at W < S its
comparisons get the extra checks of `_narrow_check_folded_cmp`.
"""
function _narrow_ir(parsed::ParsedIR, W::Int; optimized::Bool=true)
    1 <= W <= 64 || _narrow_reject("bit_width=$W is outside [1, 64]")
    S = _narrow_source_width(parsed)
    _narrow_check_return(parsed, S)
    _narrow_check_acyclic(parsed)
    if optimized && W < S
        faithful = _narrow_faithful_values(parsed, S, W)
        for block in parsed.blocks, inst in block.instructions
            _narrow_check_folded_cmp(inst, S, W, faithful)
        end
    end
    # Bennett-sl4h (a): Julia's promotion idiom in UNOPTIMISED IR only (in
    # optimised IR the extended value can be folded arithmetic that the koi8
    # checks above, which read iS compares, would never see).
    promo = optimized ? Dict{Symbol, IRCast}() : _narrow_promotions(parsed, S, W)
    new_args = [(name, W) for (name, _) in parsed.args]
    new_blocks = IRBasicBlock[]
    for block in parsed.blocks
        new_insts = IRInst[]
        for inst in block.instructions
            # an admitted promotion disappears: every use is rewritten below
            inst isa IRCast && haskey(promo, inst.dest) && continue
            push!(new_insts, isempty(promo) ? _narrow_inst(inst, S, W) :
                             _narrow_promoted_use(inst, promo, S, W))
        end
        new_term = _narrow_inst(block.terminator, S, W)
        push!(new_blocks, IRBasicBlock(block.label, new_insts, new_term))
    end
    return _narrow_rebuild(parsed, W, new_args, new_blocks)
end

# ---- rebuilding the narrowed ParsedIR (Bennett-g7d6) ------------------------
#
# Every ParsedIR field and what narrowing does with it.  `:retyped` fields are
# rewritten by `_narrow_ir` above.  `:dead_metadata` fields are side tables
# that only memory / pointer / call nodes read (`globals`: the load and GEP
# lowerings; `memssa`, `synth_ptr_provenance`: extraction only).  They describe
# SOURCE-width data and layouts, so they cannot be carried into a W-bit IR;
# they are reset to their defaults, which is exact ONLY while the narrowed IR
# has no node that could read them — `_narrow_rebuild` enforces that.  The
# pre-g7d6 code called the 4-argument back-compat constructor, which reset
# them with no such check.  A new ParsedIR field must get a decision here: the
# load-time check below (and test_g7d6) compares this list to `fieldnames`.
const _NARROW_PARSEDIR_FIELDS = (
    :ret_width            => :retyped,
    :args                 => :retyped,
    :blocks               => :retyped,
    :ret_elem_widths      => :retyped,
    :globals              => :dead_metadata,
    :memssa               => :dead_metadata,
    :synth_ptr_provenance => :dead_metadata,
)
# "Is this dead-metadata field at its default?" — one predicate per field.
const _NARROW_METADATA_IS_DEFAULT = (
    globals              = isempty,
    memssa               = isnothing,
    synth_ptr_provenance = isempty,
)
Tuple(first.(_NARROW_PARSEDIR_FIELDS)) == fieldnames(ParsedIR) &&
    Set(f for (f, k) in _NARROW_PARSEDIR_FIELDS if k === :dead_metadata) ==
        Set(keys(_NARROW_METADATA_IS_DEFAULT)) ||
    error("src/narrow.jl: _NARROW_PARSEDIR_FIELDS is out of sync with " *
          "fieldnames(ParsedIR) = $(fieldnames(ParsedIR)); decide how bit-width " *
          "narrowing treats the new field (Bennett-g7d6)")

# The scalar node types the allowlist admits; none of them reads a
# dead-metadata field.  Any other node in a narrowed IR is a potential reader.
const _NARROW_SCALAR_NODES =
    Union{IRBinOp, IRICmp, IRSelect, IRCast, IRPhi, IRRet, IRBranch}

function _narrow_rebuild(parsed::ParsedIR, W::Int,
                         new_args::Vector{Tuple{Symbol, Int}},
                         new_blocks::Vector{IRBasicBlock})
    reader = nothing
    for blk in new_blocks, inst in Iterators.flatten((blk.instructions,
                                                      (blk.terminator,)))
        inst isa _NARROW_SCALAR_NODES && continue
        reader = inst
        break
    end
    if reader !== nothing
        for (name, kind) in _NARROW_PARSEDIR_FIELDS
            kind === :dead_metadata || continue
            getfield(_NARROW_METADATA_IS_DEFAULT, name)(getfield(parsed, name)) &&
                continue
            throw(ArgumentError(
                "reversible_compile(...; bit_width=W): refusing to narrow — the " *
                "IR carries a non-default `$name` and the narrowed IR contains " *
                "a `$(typeof(reader))` node that may read it: `$name` describes " *
                "SOURCE-width data / layout that narrowing cannot re-type, and " *
                "dropping it would silently change what that node computes " *
                "(Bennett-g7d6)"))
        end
    end
    return ParsedIR(W, new_args, new_blocks, [W],
                    Dict{Symbol, Tuple{Vector{UInt64}, Int}}(),   # globals
                    nothing,                                     # memssa
                    Set{Tuple{Symbol, Int, Int}}())              # synth_ptr_provenance
end

# ---- per-node narrowing (validate, then rewrite) ----------------------------

function _narrow_inst(inst::IRBinOp, S::Int, W::Int)
    what = "binary op `$(inst.dest)` (:$(inst.op))"
    _narrow_domain(inst.width, S, what)
    _narrow_operands((inst.op1, inst.op2), what)
    if inst.op in _NARROW_ARITH_OPS
        return IRBinOp(inst.dest, inst.op, inst.op1, inst.op2,
                       _narrow_w(inst.width, W))
    end
    inst.op in _NARROW_SHIFT_OPS || _narrow_reject(
        "$what is neither a width-commuting operation " *
        "$(collect(_NARROW_ARITH_OPS)) nor a constant shift " *
        "$(collect(_NARROW_SHIFT_OPS)): division, remainder and any other " *
        "width-dependent op has no W-bit meaning here")
    # Bennett-mrhg F3: Julia bakes the shift-amount guard into the IR.  A
    # runtime amount cannot be narrowed because the barrel shifter lowers it
    # to `amount mod 2^ceil(log2 W)`, which is NOT Julia's saturating W-bit
    # `<<`; the constant form is fine, but the amount is a COUNT, so it is
    # only reinterpretable while 0 <= k <= W.
    inst.op2 isa ConstOperand || _narrow_reject(
        "$what shifts by a RUNTIME amount: Julia's `<<`/`>>` saturate to 0 for " *
        "amounts >= W, but a runtime amount is lowered as a barrel shifter " *
        "over the low ceil(log2 W) bits, which is not W-bit shift semantics")
    k = (inst.op2::ConstOperand).value
    0 <= k <= W || _narrow_reject(
        "$what shifts by the constant k=$k, outside [0, W=$W]: a shift amount " *
        "is a COUNT, not data, so re-typing it to W bits changes its meaning " *
        "(this is the shape of the front end's own guards — a sign-fill " *
        "`ashr x, 7` for an 8-bit type, or a range check against 8)")
    return IRBinOp(inst.dest, inst.op, inst.op1, inst.op2,
                   _narrow_w(inst.width, W))
end

function _narrow_inst(inst::IRICmp, S::Int, W::Int)
    what = "comparison `$(inst.dest)` (:$(inst.predicate))"
    _narrow_domain(inst.width, S, what)
    _narrow_operands((inst.op1, inst.op2), what)
    op1, op2 = _narrow_cmp_consts(inst, W)
    return IRICmp(inst.dest, inst.predicate, op1, op2,
                  _narrow_w(inst.width, W))
end

# A comparison constant keeps its meaning under re-typing only while it still
# fits in W bits *in the operands' signedness* — then the W-bit comparison of
# the wrapped constant is the same test.  This is what catches the front end's
# source-width limit guards, whose constants are typemin/typemax/width-1 of
# their (often widened) domain and whose re-typed form tests something else
# entirely: `icmp sle typemin(Int64), sext(x)` re-typed to 8 bits is
# `sle 0, x` (true for every x >= 0), and `icmp slt x, typemin(Int8)` re-typed
# to 3 bits is `slt x, 0` — the opposite test.
#
# Bennett-6p8j: the constant is read at the comparison's OWN width w (S, or 1
# for an i1 compare).  LLVM constants arrive sign-extended, so the i8 pattern
# 0xff is `-1` whether the source wrote `Int8(-1)` or `0xff` — the IR does not
# record which.  With cs the signed i$w value of the constant:
#   * a comparison `_narrow_w` leaves at width w (W == S, or an i1 compare) is
#     not re-typed at all, so every i$w constant keeps its exact meaning;
#   * a signed ordering reads its constant as cs, which must fit in min(W, w)
#     signed bits (and is rewritten to cs, so a hand-written unsigned spelling
#     such as 255 for i8 -1 lowers as -1);
#   * an unsigned ordering needs 0 <= cs <= 2^(min(W, w)-1) - 1: the optimizer
#     rewrites signed range checks into unsigned ones (`0 <= x < 10` ->
#     `icmp ult x, 10`, `x < 0 || x > 12` -> `icmp ugt x, 12`), which agree
#     with the source on every W-bit input only below 2^(W-1);
#   * eq/ne, when W < w, needs 0 <= cs <= 2^(W-1)-1 (Bennett-koi8).  The
#     IR cannot tell an equality the source wrote from an ORDERING the
#     optimizer folded into one: `x >= 0xff` -> `x == -1`, `x > 126` ->
#     `x == 127`, and a singleton range `(x >= 248) & (x <= 248)` ->
#     `x == -8`, which the earlier "sign- or zero-extends from its low W bits"
#     rule accepted and read as the 4-bit pattern 8 (true at x = 8, while no
#     4-bit UInt8 value reaches 248).  Proof sketch: whatever source predicate
#     P folded into `v == c`, P agrees with `v == c` on every i$w value, in
#     particular on e(p) for each W-bit input p, where e is the embedding of
#     the source's reading of p (sext for a signed source, zext for an
#     unsigned one — the IR does not say which).  The narrowed test is
#     `p == c mod 2^W`.  For 0 <= c <= 2^(W-1)-1, sext(p) == c and
#     zext(p) == c both hold iff p == c, so the two agree under EITHER
#     reading — including a signed source whose folded ordering was signed
#     (Int8 `(x >= 3) & (x <= 3)` -> `x == 3`: a negative W-bit x is a
#     negative i8 value, never 3).  For c >= 2^W (unsigned) or c < -2^(W-1)
#     no e(p) equals c, yet one pattern does; c in 2^(W-1)..2^W-1 equals
#     zext(p) but not sext(p), and c in -2^(W-1)..-1 the reverse — each is
#     wrong under one of the readings, so it is refused.  (This also reads a
#     hand-written `x == 5` at W = 3 as the number 5, which no 3-bit signed
#     input equals, rather than as the pattern 101.)  When W > w the sign-
#     and zero-extended readings of a negative cs are two different W-bit
#     patterns, so cs >= 0, and smax(w) (127) stays excluded as above;
#   * the argument above, and the ordering bounds, assume the compared value
#     v is the embedding of its W-bit value and that the predicate's
#     signedness is the source's.  Both hold for unoptimised IR; for
#     optimised IR `_narrow_check_folded_cmp` refuses what breaks them.
function _narrow_cmp_consts(inst::IRICmp, W::Int)
    w = inst.width
    retyped = _narrow_w(w, W) != w
    m = min(W, w)
    pred = inst.predicate
    narrow_op(op, side) = begin
        op isa ConstOperand || return op
        c = op.value
        _narrow_smin(w) <= c <= _narrow_umax(w) || _narrow_reject(
            "comparison `$(inst.dest)` (:$pred) tests $side against the " *
            "constant $c, which is not an i$w value at all")
        retyped || return op
        # The signed i$w reading of the constant (`c > smax` only when w < 64).
        cs = c > _narrow_smax(w) ? c - (1 << w) : c
        ok, allowed = if pred in _NARROW_SIGNED_PREDS
            _narrow_smin(m) <= cs <= _narrow_smax(m), "$(_narrow_smin(m))..$(_narrow_smax(m))"
        elseif pred in (:eq, :ne)
            W < w ? (0 <= cs <= _narrow_smax(W), "0..$(_narrow_smax(W))") :
                    (cs >= 0 && cs != _narrow_smax(w),
                     ">= 0, except the type maximum $(_narrow_smax(w))")
        else
            0 <= cs <= _narrow_smax(m), "0..$(_narrow_smax(m))"
        end
        ok || _narrow_reject(
            "comparison `$(inst.dest)` (:$pred) tests $side against the " *
            "constant $c (signed i$w value $cs), which is not allowed at W=$W " *
            "(allowed: $allowed): re-typing it changes what the test MEANS — " *
            "a source-width limit guard (typemin/typemax/width-1 of the " *
            "source type) or an ordering the optimizer folded into this " *
            "compare lands here (Bennett-6p8j)")
        return cs == c ? op : ConstOperand(cs)
    end
    return narrow_op(inst.op1, "op1"), narrow_op(inst.op2, "op2")
end

# ---- Julia's integer promotion in unoptimised IR (Bennett-sl4h (a)) ---------
#
# Comparing an iS value against an UNTYPED literal (`x == 5`, `x > 2`) makes
# Julia promote x to Int64: `%e = sext/zext iS %x to iN` then `icmp pred %e, c`
# at iN.  The W-bit model of that program extends the W-bit p instead:
# ext_W->N(p) (sext for sext, zext for zext — the extension names the reading;
# in the W-bit model every iS type is its W-bit counterpart).  An extension is
# ADMITTED when from_width == S, W < N <= 64, its operand is an SSA iS value,
# and EVERY use of it is
#   (1) an iN `icmp` against a constant, or against another admitted extension
#       of the same kind from iS, or
#   (2) a `trunc` back to iS: trunc_N->W(ext_W->N(p)) = p, so it becomes a
#       same-width copy of p.
# Any other use (iN arithmetic, an iN phi, a store, a call, a return) leaves
# the extension in place, where `_narrow_inst(::IRCast)` refuses it.  The
# admitted extension is dropped and its compares are rewritten as below.
#
# Case table.  p a W-bit pattern; image I = the values ext_W->N(p) takes, in
# signed iN readings: sext -> smin(W)..smax(W), zext -> 0..umax(W) (N > W, so
# zext values are non-negative); cs = the constant's signed iN reading;
# m = min(W, S).  "6p8j" = the bound `_narrow_cmp_consts` gives a TYPED iS
# literal (it is applied to the iS compare built here, so an untyped literal
# is admitted exactly where the typed one is):
#   kind  pred      cs                         narrowed            why exact
#   sext  eq/ne     in I, 6p8j (0..smax(W))    eq/ne p, cs         sext injective
#   sext  signed    in I, 6p8j (smin..smax(m)) spred p, cs         sext keeps signed order
#   sext  unsigned  in I, 6p8j (0..smax(m))    upred p, cs         sext is monotone from
#                                                                  W-unsigned to N-unsigned
#                                                                  order, and cs = sext(cs)
#   zext  eq/ne     in I, 6p8j                 eq/ne p, cs         zext injective
#   zext  unsigned  in I, 6p8j (0..smax(m))    upred p, cs         zext keeps unsigned order
#   zext  signed    in I, 6p8j (0..smax(m))    UNSIGNED pred p, cs zext(p) >= 0 at N > W: the
#                                                                  iN signed order is the
#                                                                  W-bit unsigned order
#   any   any       in I, outside 6p8j         REFUSED             (as the typed literal)
#   any   any       in I, outside iS's image   REFUSED             (only at W > S)
#   sext/zext any   NOT in I, I on one side    constant: `uge p,0` the iN compare has the
#                   of cs in pred's order      (true) / `ult p,0`  same truth value on every
#                                              (false)             element of I
#   sext  unsigned  NOT in I                   REFUSED             I straddles cs in the
#                                                                  unsigned order (not constant)
#   ext/ext same kind, any pred                pred p, q (zext +   as the constant rows
#                                              signed -> unsigned)
#   sext/zext mixed pair, or a non-ext iN operand: not admitted (refused).

_narrow_unsigned_pred(p::Symbol) =
    p === :slt ? :ult : p === :sle ? :ule : p === :sgt ? :ugt : p === :sge ? :uge : p

function _narrow_promotions(parsed::ParsedIR, S::Int, W::Int)
    promo = Dict{Symbol, IRCast}()
    insts = IRInst[i for b in parsed.blocks
                   for i in Iterators.flatten((b.instructions, (b.terminator,)))]
    # A non-scalar node refuses the whole narrowing anyway; do not reason
    # about which names it reads.
    all(i -> i isa _NARROW_SCALAR_NODES, insts) || return promo
    for i in insts
        i isa IRCast && i.op in (:sext, :zext) && i.from_width == S &&
            W < i.to_width <= 64 && i.operand isa SSAOperand &&
            (promo[i.dest] = i)
    end
    isempty(promo) && return promo
    admitted(i, name) = begin
        e = promo[name]
        N = e.to_width
        if i isa IRICmp
            i.width == N || return false
            other = i.op1 isa SSAOperand && i.op1.name === name ? i.op2 : i.op1
            other isa ConstOperand && return true
            other isa SSAOperand && haskey(promo, other.name) || return false
            o = promo[other.name]
            return o.op === e.op && o.from_width == e.from_width && o.to_width == N
        end
        return i isa IRCast && i.op === :trunc && i.from_width == N &&
               i.to_width == S && (i.operand::SSAOperand).name === name
    end
    changed = true
    while changed      # dropping one extension can strand its ext/ext partner
        changed = false
        for i in insts, name in _ssa_operands(i)
            haskey(promo, name) && !admitted(i, name) || continue
            delete!(promo, name)
            changed = true
        end
    end
    return promo
end

# Narrow `inst` when it may read an admitted promotion.
function _narrow_promoted_use(inst::IRInst, promo, S::Int, W::Int)
    if inst isa IRCast && inst.operand isa SSAOperand && haskey(promo, inst.operand.name)
        return IRCast(inst.dest, :trunc, promo[inst.operand.name].operand, W, W)
    end
    inst isa IRICmp || return _narrow_inst(inst, S, W)
    is_p(op) = op isa SSAOperand && haskey(promo, op.name)
    (is_p(inst.op1) || is_p(inst.op2)) || return _narrow_inst(inst, S, W)
    e = promo[(is_p(inst.op1) ? inst.op1 : inst.op2).name]
    N = e.to_width
    x = e.operand
    pred = inst.predicate
    kind = e.op
    what = "comparison `$(inst.dest)` (:$pred) of the i$N $kind of `$(x.name)`"
    signed = pred in _NARROW_SIGNED_PREDS
    newpred = kind === :zext && signed ? _narrow_unsigned_pred(pred) : pred
    if is_p(inst.op1) && is_p(inst.op2)          # ext/ext of the same kind
        return _narrow_inst(IRICmp(inst.dest, newpred, promo[inst.op1.name].operand,
                                   promo[inst.op2.name].operand, S), S, W)
    end
    c = (is_p(inst.op1) ? inst.op2 : inst.op1)::ConstOperand
    _narrow_smin(N) <= c.value <= _narrow_umax(N) || _narrow_reject(
        "$what tests the constant $(c.value), which is not an i$N value")
    cs = Int128(_narrow_sval(c.value, N))
    lo, hi = kind === :sext ? (_narrow_smin(W), _narrow_smax(W)) : (0, _narrow_umax(W))
    if lo <= cs <= hi
        # In the image: the iS compare a typed literal gives, then the 6p8j
        # bounds of `_narrow_inst(::IRICmp)` — rows 1-6 of the table.
        slo, shi = kind === :sext ? (_narrow_smin(S), _narrow_smax(S)) : (0, _narrow_umax(S))
        slo <= cs <= shi || _narrow_reject(
            "$what tests the constant $cs, which no i$S value $(kind)s to: at " *
            "W=$W > S=$S an untyped literal outside the source type has no " *
            "typed-literal meaning")
        k = ConstOperand(_narrow_sval(Int(cs), S))
        op1, op2 = is_p(inst.op1) ? (x, k) : (k, x)
        return _narrow_inst(IRICmp(inst.dest, newpred, op1, op2, S), S, W)
    end
    # Not in the image: constant iff the image lies on one side of the
    # constant in the predicate's order.
    kind === :sext && pred in (:ult, :ule, :ugt, :uge) && _narrow_reject(
        "$what tests the constant $cs, outside the W=$W image of the " *
        "sign extension: in the unsigned order that image is two runs around " *
        "the constant, so the comparison is not constant and has no " *
        "W-bit-constant form")
    # Every image element is on the same side of the constant (eq/ne: never
    # equal), so the predicate evaluated at `lo` is its value on all of them.
    # Keys in the predicate's order: the image values are their own keys in
    # both orders (sext+unsigned was refused; zext values are non-negative);
    # the constant's unsigned key is cs + 2^N when cs < 0.
    ck = pred in (:ult, :ule, :ugt, :uge) && cs < 0 ? cs + (Int128(1) << N) : cs
    a, b = is_p(inst.op1) ? (Int128(lo), ck) : (ck, Int128(lo))
    truth = pred === :eq ? a == b : pred === :ne ? a != b :
            pred in (:slt, :ult) ? a < b : pred in (:sle, :ule) ? a <= b :
            pred in (:sgt, :ugt) ? a > b : pred in (:sge, :uge) ? a >= b :
            _narrow_reject("$what has the unknown predicate :$pred")
    # a W-bit compare with that constant truth value on every input
    return IRICmp(inst.dest, truth ? :uge : :ult, x, ConstOperand(0), W)
end

# ---- folded comparisons in optimised IR (Bennett-koi8) ----------------------
#
# The constant bounds above are sound when the comparison is the source's own:
# its signedness is the source's reading of the value, and the value is a
# W-bit source value.  Optimised IR breaks both, and the IR records neither:
#   * InstCombine rewrites UNSIGNED source orderings into signed ones: the
#     sign-bit test UInt8 `x < 0x80` -> `icmp sgt x, -1`, and a union such as
#     `(x < 2) | (x >= 0x80)` -> `icmp slt x, 2`.  An unsigned source reads a
#     W-bit input as zext(p) >= 0, so every signed ordering against a W-bit
#     constant other than smin(W) disagrees with it on the negative patterns.
#     A signed ordering at W < S is therefore refused outright.
#   * It introduces arithmetic computed at S bits: the range check
#     `9 <= x <= 12` -> `icmp ult (add x, -9), 4`, which at W = 4 is true for
#     the signed inputs -7..-4.  So both operands of a re-typed comparison
#     must be FAITHFUL: values v with v_S = e(v_W) under both embeddings e
#     (sext and zext) of every W-bit input — the arguments, and/or/xor of
#     faithful values (sext and zext commute with bitwise ops), an `and` with
#     a constant in smin(W)..smax(W) (a sign-extended mask keeps zext's zero
#     high bits zero) or an or/xor with one in 0..smax(W) (the constants that
#     are themselves faithful), and selects/phis of faithful values.  For a
#     faithful v the unsigned and eq/ne bounds above give the same answer at W
#     bits as the source-width test on e(p), for either e, so the narrowed
#     comparison computes what the optimised program computes on the input,
#     which is what the source computes.
#   * It turns a sign test into a shift by S-1 (Int8 `x < 0` used as an
#     integer -> `lshr x, 7`).  `k <= W` admits that shift only at W = S-1,
#     where a 7-bit `lshr x, 7` is 0, not the sign: refused.
# Unoptimised IR is the source program (Julia emits the source's own icmp,
# signedness and operands), so none of this applies to it.  RESIDUAL HOLE
# (Bennett-sl4h): a fold that relies on S-bit facts of the source's own
# ARITHMETIC (an overflow the W-bit program has and the S-bit one lacks) is
# invisible to any local rule; narrowing unoptimised IR has no such hole.
_narrow_sval(c::Integer, S::Int) = c > _narrow_smax(S) ? c - (1 << S) : c

function _narrow_faithful_values(parsed::ParsedIR, S::Int, W::Int)
    faithful = Set{Symbol}(name for (name, w) in parsed.args if w == S)
    ok(op, lo) = op isa SSAOperand ? op.name in faithful :
        op isa ConstOperand && lo <= _narrow_sval(op.value, S) <= _narrow_smax(W)
    changed = true
    while changed       # phis may name values of later-listed blocks
        changed = false
        for block in parsed.blocks, inst in block.instructions
            hasproperty(inst, :dest) && hasproperty(inst, :width) || continue
            (inst.width == S && !(inst.dest in faithful)) || continue
            is_f = if inst isa IRBinOp && inst.op in (:and, :or, :xor)
                lo = inst.op === :and ? _narrow_smin(W) : 0
                ok(inst.op1, lo) && ok(inst.op2, lo)
            elseif inst isa IRSelect
                ok(inst.op1, 0) && ok(inst.op2, 0)
            elseif inst isa IRPhi
                all(ok(op, 0) for (op, _) in inst.incoming)
            else
                false
            end
            is_f && (push!(faithful, inst.dest); changed = true)
        end
    end
    return faithful
end

_narrow_check_folded_cmp(::IRInst, S::Int, W::Int, faithful) = nothing

function _narrow_check_folded_cmp(inst::IRICmp, S::Int, W::Int, faithful)
    inst.width == S || return nothing         # i1 compares are not re-typed
    what = "comparison `$(inst.dest)` (:$(inst.predicate))"
    inst.predicate in _NARROW_SIGNED_PREDS && _narrow_reject(
        "$what is a SIGNED ordering in optimised IR: the optimizer rewrites " *
        "unsigned source orderings into signed ones (UInt8 `x < 0x80` -> " *
        "`icmp sgt x, -1`), and the IR does not record which the source " *
        "wrote; compile with optimize=false to narrow the source's own " *
        "comparison (Bennett-koi8)")
    for op in (inst.op1, inst.op2)
        (op isa SSAOperand && !(op.name in faithful)) || continue
        _narrow_reject(
            "$what in optimised IR compares `$(op.name)`, which is computed " *
            "(add/sub/mul/shift/cast, or a mask/merge constant outside " *
            "0..2^(W-1)-1) rather than an argument or a bitwise/select/phi of " *
            "arguments: the optimizer writes folded range checks this way " *
            "(`9 <= x <= 12` -> `icmp ult (add x, -9), 4`), and that S-bit " *
            "arithmetic has no W-bit meaning; compile with optimize=false " *
            "(Bennett-koi8)")
    end
    return nothing
end

function _narrow_check_folded_cmp(inst::IRBinOp, S::Int, W::Int, faithful)
    (inst.width == S && inst.op in (:lshr, :ashr) && inst.op2 isa ConstOperand &&
     (inst.op2::ConstOperand).value == S - 1) || return nothing
    return _narrow_reject(
        "binary op `$(inst.dest)` (:$(inst.op)) in optimised IR shifts by " *
        "S-1 = $(S - 1), the sign-bit extraction the optimizer folds a sign " *
        "test into (Int8 `x < 0` -> `lshr x, 7`); at W = $W it is not the " *
        "sign; compile with optimize=false (Bennett-koi8)")
end

function _narrow_inst(inst::IRSelect, S::Int, W::Int)
    what = "select `$(inst.dest)`"
    inst.width == 0 && _narrow_reject(
        "$what is a POINTER select (width=0): pointer and aggregate routing " *
        "is a layout, not a wire width")
    _narrow_domain(inst.width, S, what)
    _narrow_operands((inst.cond, inst.op1, inst.op2), what)
    return IRSelect(inst.dest, inst.cond, inst.op1, inst.op2,
                    _narrow_w(inst.width, W))
end

function _narrow_inst(inst::IRCast, S::Int, W::Int)
    what = "$(inst.op) cast `$(inst.dest)` (i$(inst.from_width) -> " *
           "i$(inst.to_width))"
    inst.op in _NARROW_CAST_OPS || _narrow_reject("$what is not a cast")
    # Both ends must be in an allowed domain, so a cast between two distinct
    # SCALAR widths (i8 -> i16, i8 -> i64) is refused: the widened side is a
    # second data domain (Bennett-mrhg).  i1 <-> iS is the Bool <-> integer
    # conversion and commutes with truncation.
    _narrow_domain(inst.from_width, S, what)
    _narrow_domain(inst.to_width, S, what)
    _narrow_operands((inst.operand,), what)
    return IRCast(inst.dest, inst.op, inst.operand,
                  _narrow_w(inst.from_width, W), _narrow_w(inst.to_width, W))
end

function _narrow_inst(inst::IRPhi, S::Int, W::Int)
    what = "phi `$(inst.dest)`"
    inst.width == 0 && _narrow_reject(
        "$what is a POINTER phi (width=0): pointer routing is a layout, not " *
        "a wire width")
    _narrow_domain(inst.width, S, what)
    for (op, _) in inst.incoming
        _narrow_operands((op,), what)
    end
    return IRPhi(inst.dest, _narrow_w(inst.width, W), inst.incoming)
end

function _narrow_inst(inst::IRRet, S::Int, W::Int)
    inst.op === nothing && _narrow_reject(
        "the function returns no value, so there is no scalar return width to " *
        "re-type to W bits")
    _narrow_domain(inst.width, S, "the returned value")
    # A return narrower than S is a boolean return, not scalar data: the
    # output register is W bits wide, so there is no W-bit layout to give it.
    inst.width == S || _narrow_reject(
        "the returned value is i$(inst.width) wide while the source scalar " *
        "width is i$S: a boolean return is not scalar data and has no W-bit " *
        "return layout")
    _narrow_operands((inst.op,), "the returned value")
    return IRRet(inst.op, _narrow_w(inst.width, W))
end

function _narrow_inst(inst::IRBranch, S::Int, W::Int)
    inst.cond === nothing && return inst
    _narrow_operands((inst.cond,), "a branch condition")
    return inst
end

# Memory, aggregates and calls.  These carry a LAYOUT — element widths, byte
# offsets, field indices, callee signatures — that a uniform width rewrite
# corrupts while leaving the layout alone.  That is exactly how the F13 tuple
# return used to reach lowering as `_lower_store_via_shadow!: idx=2 out of
# range [0, 2)` / `resolve!: ... length(wires)=8 but caller advertised
# width=4`.  (Bennett-6bu3 / Bennett-2unc previously repaired these handlers
# to round-trip totals; under the Bennett-mrhg contract they refuse instead.)
for T in (:IRAlloca, :IRStore, :IRLoad, :IRVarGEP, :IRPtrOffset,
          :IRInsertValue, :IRInsertBits, :IRExtractValue, :IRCall, :IRSwitch,
          :IRMapInsert, :IRMapGet, :IRMapDelete)
    @eval function _narrow_inst(inst::$T, S::Int, W::Int)
        _narrow_reject(
            "the function contains a `$(string($T))` node — memory, an " *
            "aggregate field layout, a switch, or a call: its element widths, " *
            "byte offsets / field indices and callee signature are a LAYOUT " *
            "that a uniform re-typing to W bits corrupts")
    end
end

# Bennett-2unc / U85 kept the "no handler" case loud; under the Bennett-mrhg
# contract an uncovered node type is a refusal, not an internal error.
function _narrow_inst(inst::IRInst, S::Int, W::Int)
    _narrow_reject("the function contains a `$(typeof(inst))` node, which the " *
                   "narrowing allowlist does not cover")
end
