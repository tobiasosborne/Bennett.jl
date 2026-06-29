# Bennett-xrd6 — sret-convention / ptr-returning CALL to a registered callee
# whose result is CONSUMED locally (read back from an sret-out box), under the
# closed-world `ptr_cells` gate.
#
# CONTEXT. The closed-world fdict producer
#   fd(k::Int8,v::Int8) = (d = Dict{Int8,Int8}(); d[k] = v; d[k])
# routes through `setindex!(Dict{Int8,Int8},Int8,Int8)`, whose body holds TWO
# registered-callee calls the pre-xrd6 extractor could not convert under
# `ptr_cells=true`:
#   * `call swiftcc void @ht_keyindex2_shorthash!(sret({i64,i8}) %sret_box, ...)`
#     — an sret-convention call with a VOID LLVM return; the registered-callee
#     arm did `ret_w = _iwidth(inst)` → `_type_width(VoidType)` → the U81 wall
#     "VoidType reached _type_width".
#   * `%84 = call swiftcc ptr @rehash!(...)` — a Dict-returning call with a
#     POINTER LLVM return; `_iwidth` would crash next at the PointerType wall.
#
# FIX (Design 2). The registered-callee arm gains a `ptr_cells` branch using the
# closed-world cell ABI (shared `_cell_call_args` helper): pointer args (incl.
# the sret-out box ptr, carried as arg 1) become 64-bit VM cells so the box
# read-back loads resolve, and the void/ptr LLVM return → a 64-bit ret_width
# SENTINEL. Fail-loud sret-pointee validation (reusing the Bennett-dv1z
# `_sret_struct_fields` rules) rejects a non-{fixed-width integer bits-struct}
# sret shape before the read-back machinery trusts the box. NO change to
# ir_types.jl; the circuit path (`ptr_cells=false`) is byte-identical.
#
# SCOPING (Rule 1 honesty). xrd6 clears the CALL-conversion wall only.
#   * Under DEFAULT bounds checking, `setindex!` extracts FULLY (both walls gone).
#   * Under `--check-bounds=yes` (the Pkg.test mode, Bennett-2mj3/figa), Julia
#     codegen emits a `ptrtoint ptr %memory_data to i64` bounds-check artifact in
#     setindex!'s OWN body (block L8) that hits the PRE-EXISTING Bennett-iwo9
#     ptrtoint reject — a DEEPER, unrelated wall. So this test PROBES the bounds
#     mode (mirroring test_59zi's ht_keyindex2 testset) and asserts the full
#     extraction shape when it succeeds, or the iwo9 ptrtoint wall (NOT a void/
#     ptr/sret wall — proving xrd6 cleared them) when check-bounds=yes is active.

using Test
using Bennett
using Bennett: extract_parsed_ir, extract_parsed_ir_from_ll, register_callee!,
               ParsedIR, IRCall, IRAlloca, IRLoad, SSAOperand

# ---- scoped registry snapshot/restore (mirror test_lf14 / julia_set.jl) ----
# Registering setindex!/rehash!/ht_keyindex2 is required so the body walk emits
# Function-callee IRCalls instead of fail-louding at the U15 unregistered-call
# guard, but MUST NOT leak into later same-process suite files (Rule 7).
function _xrd6_with_registered(fn, callables)
    snap = lock(Bennett._known_callees_lock) do
        copy(Bennett._known_callees)
    end
    added = String[]
    try
        for c in callables
            register_callee!(c)
            push!(added, string(nameof(c)))
        end
        return fn()
    finally
        lock(Bennett._known_callees_lock) do
            for k in added
                if haskey(snap, k)
                    Bennett._known_callees[k] = snap[k]
                else
                    delete!(Bennett._known_callees, k)
                end
            end
        end
    end
end

# x86-64 SysV datalayout (matches Julia's) so _sret_struct_fields' offsetof/
# sizeof datalayout queries resolve on the synthetic .ll fixtures.
const _xrd6_dl = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"

function _xrd6_write_ll(body::String)
    path = tempname() * ".ll"
    open(path, "w") do io
        write(io, "target datalayout = \"$_xrd6_dl\"\n\n")
        write(io, body)
    end
    return path
end

# Assert .ll extraction of `name` rejects with a message containing `needle`.
function _xrd6_reject(name::String, body::String, needle::String; ptr_cells::Bool=true)
    path = _xrd6_write_ll(body)
    threw = false
    try
        extract_parsed_ir_from_ll(path; entry_function=name, ptr_cells=ptr_cells)
    catch e
        e isa InterruptException && rethrow()
        threw = true
        msg = sprint(showerror, e)
        if !occursin(needle, msg)
            @info "xrd6 reject message mismatch" name needle msg
        end
        @test occursin(needle, msg)
    end
    @test threw
end

# A dummy registered leaf so the .ll call `@xrd6_leaf` resolves to a Function and
# the registered-callee arm (not the C-call arm) handles the sret-pointee check.
xrd6_leaf(k::Int8) = (Int64(k) + 1, k ⊻ Int8(0x55))

@testset "Bennett-xrd6 sret-convention consumed call → cell ABI" begin

    # =====================================================================
    # (a) setindex! consumed-call extraction (bounds-mode-aware probe).
    # =====================================================================
    @testset "setindex! consumed sret/ptr calls extract under ptr_cells" begin
        before = lock(Bennett._known_callees_lock) do
            copy(Bennett._known_callees)
        end

        _xrd6_with_registered([setindex!, Base.rehash!,
                               Base.ht_keyindex2_shorthash!]) do
            at = Tuple{Dict{Int8,Int8},Int8,Int8}

            local pir = nothing
            local threw = nothing
            try
                pir = extract_parsed_ir(setindex!, at; optimize=false, ptr_cells=true)
            catch e
                e isa InterruptException && rethrow()
                threw = e
            end

            if pir !== nothing
                # ---- DEFAULT bounds mode: full extraction. Structural invariants
                # only (Rule 5 — no block/gate counts). ----
                allinsts = [i for b in pir.blocks for i in b.instructions]
                calls = filter(i -> i isa IRCall, allinsts)
                allocas = filter(i -> i isa IRAlloca, allinsts)
                loads = filter(i -> i isa IRLoad, allinsts)

                # The sret-convention call: ht_keyindex2_shorthash!, void → 64
                # sentinel, sret-out box carried as arg 1.
                kx = filter(c -> c.callee isa Function &&
                                 nameof(c.callee) === :ht_keyindex2_shorthash!, calls)
                @test length(kx) == 1
                @test kx[1].ret_width == 64
                @test !isempty(kx[1].args)
                @test kx[1].args[1] isa SSAOperand
                # arg 1 ties the call to the sret box alloca (read-back anchor).
                box_name = kx[1].args[1].name
                @test any(a -> a.dest === box_name, allocas)

                # The ptr-returning call: rehash!, ptr → 64 sentinel.
                rh = filter(c -> c.callee isa Function &&
                                 nameof(c.callee) === :rehash!, calls)
                @test length(rh) == 1
                @test rh[1].ret_width == 64

                # The sret box alloca + ≥1 read-back (loads of the box / fields).
                @test !isempty(allocas)
                @test !isempty(loads)
            else
                # ---- --check-bounds=yes mode: the xrd6 walls (void + ptr) are
                # CLEARED; extraction now reaches the DEEPER, unrelated Bennett-iwo9
                # `ptrtoint ptr %memory_data to i64` reject in setindex!'s own body.
                # Assert that, and that it is NOT a void/ptr/sret wall (which would
                # mean xrd6 is incomplete). The deeper wall is a separate bead. ----
                msg = sprint(showerror, threw)
                lc = lowercase(msg)
                @test occursin("ptrtoint", lc)
                @test occursin("iwo9", lc) || occursin("type-tag", lc)
                # xrd6's two walls are gone:
                @test !occursin("VoidType reached", msg)        # void sret wall cleared
                @test !(occursin("unsupported LLVM type", msg) &&
                        occursin("PointerType", msg))           # ptr-return wall cleared
            end
        end

        after = lock(Bennett._known_callees_lock) do
            copy(Bennett._known_callees)
        end
        @test after == before                                   # no registry leak
    end

    # =====================================================================
    # (b) fail-loud sret-pointee validation (synthetic .ll fixtures).
    #     The callee `@xrd6_leaf` is registered so the registered-callee arm
    #     (with the xrd6 sret-pointee check) fires — not the C-call arm.
    # =====================================================================
    @testset "fail-loud: bad sret pointee shapes reject under ptr_cells" begin
        before = lock(Bennett._known_callees_lock) do
            copy(Bennett._known_callees)
        end

        _xrd6_with_registered([xrd6_leaf]) do
            # R: non-integer struct field (float) → Bennett-dv1z field reject.
            _xrd6_reject("c_float_field", """
            declare void @xrd6_leaf(ptr sret({i64,float}), i8)
            define void @c_float_field(ptr %box, i8 signext %k) {
            top:
              call void @xrd6_leaf(ptr sret({i64,float}) %box, i8 signext %k)
              ret void
            }
            """, "Bennett-dv1z")

            # R: bad-width integer field (i7 ∉ {8,16,32,64}) → Bennett-dv1z reject.
            _xrd6_reject("c_i7_field", """
            declare void @xrd6_leaf(ptr sret({i7}), i8)
            define void @c_i7_field(ptr %box, i8 signext %k) {
            top:
              call void @xrd6_leaf(ptr sret({i7}) %box, i8 signext %k)
              ret void
            }
            """, "Bennett-dv1z")

            # R: leading non-integer field (half) → Bennett-dv1z reject.
            _xrd6_reject("c_half_field", """
            declare void @xrd6_leaf(ptr sret({half,i8}), i8)
            define void @c_half_field(ptr %box, i8 signext %k) {
            top:
              call void @xrd6_leaf(ptr sret({half,i8}) %box, i8 signext %k)
              ret void
            }
            """, "Bennett-dv1z")

            # R: non-StructType sret pointee (bare i64) → Bennett-xrd6 reject.
            _xrd6_reject("c_scalar_pointee", """
            declare void @xrd6_leaf(ptr sret(i64), i8)
            define void @c_scalar_pointee(ptr %box, i8 signext %k) {
            top:
              call void @xrd6_leaf(ptr sret(i64) %box, i8 signext %k)
              ret void
            }
            """, "Bennett-xrd6")

            # GATE: a VALID sret shape ({i64,i8}) extracted with ptr_cells=FALSE
            # falls to the gate-inlining arm → the raw VoidType _type_width wall.
            # Pins "cell model required": the cell ABI (and thus the sret handling)
            # is gated on ptr_cells; without it the void sret call still crashes.
            _xrd6_reject("c_cells_off", """
            declare void @xrd6_leaf(ptr sret({i64,i8}), i8)
            define void @c_cells_off(ptr %box, i8 signext %k) {
            top:
              call void @xrd6_leaf(ptr sret({i64,i8}) %box, i8 signext %k)
              ret void
            }
            """, "VoidType reached"; ptr_cells=false)
        end

        after = lock(Bennett._known_callees_lock) do
            copy(Bennett._known_callees)
        end
        @test after == before                                   # no registry leak
    end
end
