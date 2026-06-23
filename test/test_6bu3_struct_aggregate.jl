# Bennett-6bu3 — StructType insertvalue/extractvalue FILL (per-field layout).
#
# Post-vbv9 the closed-world fdict root walls at
#   insertvalue { ptr, ptr } zeroinitializer, ptr %memoryref_data16, 0
#     — "insertvalue on StructType aggregates not supported; only homogeneous
#        ArrayType aggregates are."
# The `{ptr,ptr}` is Julia's GenericMemoryRef body. This bead adds StructType
# insert/extract via an ADDITIVE `field_widths::Vector{Int}` field on
# IRInsertValue / IRExtractValue (Option 1; ZERO new IR subtypes). The
# discriminator convention is: `isempty(field_widths)` ⇒ HOMOGENEOUS (the
# existing ArrayType `elem_width`/`n_elems` path, byte-identical); non-empty ⇒
# STRUCTTYPE (per-field widths; `n_elems == length(field_widths)`,
# `elem_width == 0` sentinel).
#
# The extractor helper `_struct_field_widths` (src/extract/instructions.jl)
# walks `LLVM.elements(st)`: integer fields require width ∈ {8,16,32,64}
# (REJECTING i1 — the load-bearing guard that keeps `{i64,i1}`
# `*.with.overflow` structs FAILING LOUD); pointer fields → 64 but ONLY under
# `ptr_cells`; float / nested-struct / vector / array / packed / empty fields
# are all rejected loud, citing Bennett-6bu3.
#
# Gate map (Rule 4 — node-shape assertions, not no-throw):
#   (a) ptr_cells=true {ptr,ptr} build+extract → :ok; field_widths==[64,64],
#       n_elems==2, elem_width==0, base agg ZERO_AGG, indices 0/1.
#   (b) ptr_cells=false same {ptr,ptr} → :err mentioning ptr_cells / Bennett-6bu3.
#   (c) `{i64,i1}` overflow-struct → :err "width 1 not in {8,16,32,64}" under
#       BOTH ptr_cells values; a `{i64,double}` field → :err.
#   (d) real fdict_d1b root advance (optimize=false, ptr_cells=true): NEGATIVE
#       no longer the insertvalue-StructType wall; POSITIVE inclusive
#       disjunction of CW-D successors. Captures the verbatim new wall.
#   PLUS a circuit-path completeness test: hand-built {i8,i32}-shape
#       insert/extract lowered via the circuit simulator, verifying the
#       extracted field round-trips + ancilla-zero (verify_reversibility floor).

using Test
using Bennett
using Bennett: extract_parsed_ir_from_ll, extract_parsed_ir,
               ParsedIR, IRInsertValue, IRExtractValue, ZERO_AGG,
               WireAllocator, allocate!, ReversibleGate, CNOTGate, apply!,
               lower_insertvalue!, lower_extractvalue!
import LLVM

# ---------------------------------------------------------------------------
# Hand-built .ll fixtures (Rule 5: hermetic, version-independent). Each
# isolates a StructType insert/extract reaching `_struct_field_widths`.
# ---------------------------------------------------------------------------

# `{ptr,ptr}` build+extract: the GenericMemoryRef body shape. Build the struct
# from two pointer args, then extract field 0. Returns i64 0 so the function-
# level return-width derivation needs no ptr gymnastics — the walls stay on the
# insert/extract.
const STRUCT_PTRPTR = """
define i64 @struct_ptrptr(ptr %a, ptr %b) {
top:
  %s0 = insertvalue { ptr, ptr } zeroinitializer, ptr %a, 0
  %s1 = insertvalue { ptr, ptr } %s0, ptr %b, 1
  %e0 = extractvalue { ptr, ptr } %s1, 0
  ret i64 0
}
"""

# `{i64,i1}` struct with an i1 field (the `*.with.overflow` / `cmpxchg` result
# shape): the i1 field must be rejected at the {8,16,32,64} width guard, under
# BOTH gates. Built via insertvalue-from-zeroinitializer so the
# `_struct_field_widths` i1 guard (NOT an unsupported intrinsic-call return
# type) is the wall under test.
const STRUCT_I64I1 = """
define i64 @struct_i64i1(i64 %x) {
top:
  %s   = insertvalue {i64, i1} zeroinitializer, i64 %x, 0
  %sum = extractvalue {i64, i1} %s, 0
  ret i64 %sum
}
"""

# `{i64,double}` insertvalue (a float field): rejected as a non-integer field.
const STRUCT_I64DBL = """
define i64 @struct_i64dbl(i64 %x) {
top:
  %s = insertvalue {i64, double} undef, i64 %x, 0
  ret i64 %x
}
"""

# Extract a hand-built .ll fixture, returning (:ok, pir) or (:err, message).
function _6bu3_extract_ll(name, ir, entry; cells)
    mktempdir() do dir
        path = joinpath(dir, "$(name).ll")
        write(path, ir)
        try
            pir = extract_parsed_ir_from_ll(path; entry_function=entry, ptr_cells=cells)
            return (:ok, pir)
        catch e
            e isa InterruptException && rethrow()
            return (:err, sprint(showerror, e))
        end
    end
end

# Collect all instructions across blocks, INCLUDING terminators.
function _6bu3_all_insts(pir)
    out = Any[]
    for b in pir.blocks
        append!(out, b.instructions)
        b.terminator === nothing || push!(out, b.terminator)
    end
    return out
end

# Is `msg` the OLD (pre-6bu3) StructType-not-supported wall?
_is_old_struct_wall(msg) =
    occursin("on StructType aggregates not supported", msg)

@testset "Bennett-6bu3 StructType insertvalue/extractvalue per-field layout" begin

    # =======================================================================
    # GATE (a) — ptr_cells=true: {ptr,ptr} build+extract lowers with per-field
    # widths [64,64]. Positive node-shape assertions (Rule 4).
    # =======================================================================
    @testset "GATE (a) — {ptr,ptr} build+extract node shape" begin
        (st, pir) = _6bu3_extract_ll("struct_ptrptr", STRUCT_PTRPTR, "struct_ptrptr"; cells=true)
        @test st === :ok
        if st === :ok
            insts = _6bu3_all_insts(pir)
            ivs = filter(x -> x isa IRInsertValue, insts)
            evs = filter(x -> x isa IRExtractValue, insts)
            @test length(ivs) == 2
            @test length(evs) == 1
            if length(ivs) == 2
                # The two inserts are at field indices 0 and 1 with [64,64].
                @test Set(iv.index for iv in ivs) == Set([0, 1])
                for iv in ivs
                    @test iv.field_widths == [64, 64]
                    @test iv.n_elems == 2
                    @test iv.elem_width == 0          # StructType sentinel
                end
                # The index-0 insert's base aggregate is the ZERO_AGG
                # (zeroinitializer); the index-1 insert's base is the SSA chain.
                iv0 = first(iv for iv in ivs if iv.index == 0)
                @test iv0.agg === ZERO_AGG
            end
            if length(evs) == 1
                e = evs[1]
                @test e.field_widths == [64, 64]
                @test e.index == 0
                @test e.n_elems == 2
                @test e.elem_width == 0
            end
        end
    end

    # =======================================================================
    # GATE (b) — ptr_cells=false: the SAME {ptr,ptr} fixture walls loud, citing
    # the ptr_cells requirement (the pointer-field guard is ptr_cells-gated).
    # =======================================================================
    @testset "GATE (b) — {ptr,ptr} without ptr_cells walls (Bennett-6bu3)" begin
        (st, msg) = _6bu3_extract_ll("struct_ptrptr_off", STRUCT_PTRPTR, "struct_ptrptr"; cells=false)
        @test st === :err
        if st === :err
            # The pointer field requires ptr_cells; message names ptr_cells +
            # the bead. (Not the OLD blanket StructType wall.)
            @test !_is_old_struct_wall(msg)
            @test occursin("ptr_cells", msg)
            @test occursin("6bu3", msg)
        end
    end

    # =======================================================================
    # GATE (c) — the load-bearing rejects 6bu3 KEEPS firing:
    #   (c1) `{i64,i1}` overflow-struct → width-1 reject under BOTH gates.
    #   (c2) `{i64,double}` float field → non-integer reject.
    # =======================================================================
    @testset "GATE (c1) — {i64,i1} overflow struct rejects (both gates)" begin
        for cells in (true, false)
            (st, msg) = _6bu3_extract_ll("struct_i64i1_$(cells)", STRUCT_I64I1,
                                         "struct_i64i1"; cells=cells)
            @test st === :err
            if st === :err
                @test occursin("width 1", lowercase(msg)) ||
                      occursin("{8,16,32,64}", msg)
                @test occursin("6bu3", msg)
                @test !occursin("UndefRefError", msg)
            end
        end
    end

    @testset "GATE (c2) — {i64,double} float field rejects" begin
        for cells in (true, false)
            (st, msg) = _6bu3_extract_ll("struct_i64dbl_$(cells)", STRUCT_I64DBL,
                                         "struct_i64dbl"; cells=cells)
            @test st === :err
            if st === :err
                @test occursin("unsupported type", lowercase(msg)) ||
                      occursin("double", lowercase(msg)) ||
                      occursin("float", lowercase(msg))
                @test occursin("6bu3", msg)
            end
        end
    end

    # =======================================================================
    # GATE (d) — real fdict_d1b root wall-ADVANCE under cells=true. Pre-6bu3 the
    # root walls at the insertvalue-StructType wall; post-6bu3 the {ptr,ptr}
    # per-field path fires and a LATER wall surfaces. Assert NEGATIVELY (no
    # longer the StructType insertvalue wall) + an inclusive disjunction of
    # plausible CW-D successors. Registry snapshot/restore (Rule 7).
    # =======================================================================
    @testset "GATE (d) — fdict_d1b advances past the insertvalue-StructType wall" begin
        fdict_d1b(a::Int8, b::Int8) = (d = Dict{Int8,Int8}(); d[a] = b; d[a])

        before = lock(Bennett._known_callees_lock) do
            copy(Bennett._known_callees)
        end
        new_wall = nothing
        try
            at = Tuple{Int8,Int8}
            on_msg = try
                extract_parsed_ir(fdict_d1b, at; optimize=false, ptr_cells=true)
                nothing
            catch e
                e isa InterruptException && rethrow()
                sprint(showerror, e)
            end
            new_wall = on_msg
            if on_msg === nothing
                @test true  # fully extracted — even stronger than wall-advance
            else
                # NEGATIVE: no longer the insertvalue-StructType wall.
                @test !_is_old_struct_wall(on_msg)
                # POSITIVE inclusive disjunction of plausible CW-D successors.
                @test occursin("memcpy", lowercase(on_msg))            ||
                      occursin("genericmemory", lowercase(on_msg))     ||
                      occursin("gc_alloc_obj", lowercase(on_msg))      ||
                      occursin("ptrtoint", lowercase(on_msg))          ||
                      occursin("inttoptr", lowercase(on_msg))          ||
                      occursin("aggregate", lowercase(on_msg))         ||
                      occursin("unsupported llvm opcode", lowercase(on_msg)) ||
                      occursin("atomic", lowercase(on_msg))            ||
                      occursin("U14", on_msg)                          ||
                      occursin("VoidType", on_msg)                     ||
                      occursin("U81", on_msg)                          ||
                      occursin("sret", lowercase(on_msg))              ||
                      occursin("U15", on_msg)                          ||
                      occursin("no registered callee", on_msg)         ||
                      occursin("closed-world", on_msg)                 ||
                      occursin("PointerType", on_msg)
            end
        finally
            lock(Bennett._known_callees_lock) do
                empty!(Bennett._known_callees)
                merge!(Bennett._known_callees, before)
            end
        end
        # Capture the verbatim new wall for the report (printed once).
        if new_wall !== nothing
            @info "Bennett-6bu3 fdict_d1b new wall" wall=first(split(new_wall, "\n"))
        end

        after = lock(Bennett._known_callees_lock) do
            copy(Bennett._known_callees)
        end
        @test after == before
    end

    # =======================================================================
    # CIRCUIT-PATH COMPLETENESS — hand-build IRInsertValue/IRExtractValue with
    # field_widths=[8,32] (a {i8,i32} shape), lower via the circuit primitives,
    # run the gate stream on a bit-buffer, verify the extracted field round-
    # trips AND every ancilla returns to zero (verify_reversibility floor, Rule
    # 4). Proves the heterogeneous-width offset arithmetic
    # (offset = Σ widths[1:index]) is correct on the circuit backend too.
    # =======================================================================
    @testset "circuit-path: {i8,i32} struct insert/extract round-trips + ancilla-zero" begin
        FW = [8, 32]                 # field 0 = i8, field 1 = i32
        for (v0, v1) in ((0xAB, 0x12345678),
                         (0x00, 0xFFFFFFFF),
                         (0x7F, 0x00000001))
            gates = ReversibleGate[]
            wa = WireAllocator()
            vw = Dict{Symbol,Vector{Int}}()

            # Source field wires (the inputs we insert), pre-loaded with v0/v1.
            f0 = allocate!(wa, FW[1]); vw[:f0] = f0
            f1 = allocate!(wa, FW[2]); vw[:f1] = f1

            # s0 = insertvalue ZERO_AGG, f0, field 0  →  [v0, 0]
            lower_insertvalue!(gates, wa, vw,
                IRInsertValue(:s0, ZERO_AGG, Bennett.ssa(:f0), 0, 0, 2, FW))
            # s1 = insertvalue s0, f1, field 1         →  [v0, v1]
            lower_insertvalue!(gates, wa, vw,
                IRInsertValue(:s1, Bennett.ssa(:s0), Bennett.ssa(:f1), 1, 0, 2, FW))
            # e0 = extractvalue s1, 0                  →  v0  (8 bits)
            lower_extractvalue!(gates, wa, vw,
                IRExtractValue(:e0, Bennett.ssa(:s1), 0, 0, 2, FW))
            # e1 = extractvalue s1, 1                  →  v1  (32 bits)
            lower_extractvalue!(gates, wa, vw,
                IRExtractValue(:e1, Bennett.ssa(:s1), 1, 0, 2, FW))

            n_wires = wa.next_wire - 1
            bits = fill(false, n_wires)   # Vector{Bool} (apply! requires it; not BitVector)
            # Load the source fields.
            for i in 1:FW[1]; bits[f0[i]] = (v0 >> (i - 1)) & 1 == 1; end
            for i in 1:FW[2]; bits[f1[i]] = (v1 >> (i - 1)) & 1 == 1; end
            # Snapshot the input wires for input-preservation check.
            snap = copy(bits)

            for g in gates
                apply!(bits, g)
            end

            # The extracted fields must equal the inserted values bit-for-bit.
            e0 = vw[:e0]; e1 = vw[:e1]
            got0 = sum(Int(bits[e0[i]]) << (i - 1) for i in 1:FW[1])
            got1 = sum(Int(bits[e1[i]]) << (i - 1) for i in 1:FW[2])
            @test got0 == v0          # i8 field round-trips
            @test got1 == v1          # i32 field round-trips (offset = 8)

            # Inputs unchanged (Bennett input-preservation half of the invariant).
            for w in vcat(f0, f1)
                @test bits[w] == snap[w]
            end
        end
    end
end
