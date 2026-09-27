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
# are bit-pattern compares, and the unsigned predicates read the W-bit
# pattern, so all three admit any constant in [0, 2^W - 1].
const _NARROW_SIGNED_PREDS = (:slt, :sle, :sgt, :sge)

_narrow_reject(why::AbstractString) = throw(ArgumentError(
    "reversible_compile(...; bit_width=W): refusing to narrow — $why. " *
    "bit-width narrowing re-types a function to W-bit two's-complement modular " *
    "semantics and is an allowlist: narrowable are add/sub/mul/and/or/xor, " *
    "constant-amount shifts with 0 <= k <= W, comparisons (in either " *
    "signedness) against a constant that still fits in W bits, selects, " *
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
"""
function _narrow_ir(parsed::ParsedIR, W::Int)
    1 <= W <= 64 || _narrow_reject("bit_width=$W is outside [1, 64]")
    S = _narrow_source_width(parsed)
    _narrow_check_return(parsed, S)
    _narrow_check_acyclic(parsed)
    new_args = [(name, W) for (name, _) in parsed.args]
    new_blocks = IRBasicBlock[]
    for block in parsed.blocks
        new_insts = IRInst[_narrow_inst(inst, S, W) for inst in block.instructions]
        new_term = _narrow_inst(block.terminator, S, W)
        push!(new_blocks, IRBasicBlock(block.label, new_insts, new_term))
    end
    return ParsedIR(W, new_args, new_blocks, [W])
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
    _narrow_cmp_consts(inst, W)
    return IRICmp(inst.dest, inst.predicate, inst.op1, inst.op2,
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
function _narrow_cmp_consts(inst::IRICmp, W::Int)
    lo, hi = inst.predicate in _NARROW_SIGNED_PREDS ?
             (_narrow_smin(W), _narrow_smax(W)) : (0, _narrow_umax(W))
    for (op, side) in ((inst.op1, "op1"), (inst.op2, "op2"))
        op isa ConstOperand || continue
        lo <= op.value <= hi && continue
        _narrow_reject(
            "comparison `$(inst.dest)` (:$(inst.predicate)) tests $side against " *
            "the constant $(op.value), which does not fit in W=$W bits " *
            "(allowed $lo..$hi for this predicate's signedness): re-typing " *
            "the constant changes what the test MEANS — a source-width limit " *
            "guard (typemin/typemax/width-1 of the source type) lands here")
    end
    return nothing
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
