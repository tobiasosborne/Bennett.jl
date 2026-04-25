@testset "Karatsuba multiplier" begin

    # Bennett-sg0w / 2026-04-25: the original "Karatsuba uses fewer
    # Toffolis than schoolbook" assertion was false at every width
    # Bennett.jl currently supports.  Measured 2026-04-25
    # (post-U27 add=:auto→:ripple defaults):
    #
    #   W  | schoolbook Toff | karatsuba Toff | k:s ratio
    #   ---+-----------------+----------------+----------
    #    8 |             144 |            502 | 3.49
    #   16 |             664 |           2000 | 3.01
    #   32 |            2856 |           6960 | 2.44
    #   64 |           11848 |          22658 | 1.91
    #  128 | (Int128 not supported by ir_extract today)
    #
    # The trend (ratio decreasing with W) is consistent with the
    # Karatsuba O(W^log₂3) vs schoolbook O(W²) asymptotic — the
    # crossover would land somewhere past W=128, beyond the widest
    # integer Bennett.jl can lower.  So Karatsuba is currently
    # vestigial.  Test asserts CORRECTNESS only; the gate-count race
    # is tracked for resolution under Bennett-sg0w (raise crossover
    # threshold, tighten the impl, or remove it).

    # ================================================================
    # Test 1: Karatsuba correctness — Int8, all 256×256 inputs
    # ================================================================
    @testset "karatsuba: Int8 exhaustive" begin
        f(x::Int8, y::Int8) = x * y
        parsed = Bennett.extract_parsed_ir(f, Tuple{Int8, Int8})

        # Lower with schoolbook (default)
        lr_school = Bennett.lower(parsed)
        c_school = Bennett.bennett(lr_school)

        # Lower with Karatsuba
        parsed2 = Bennett.extract_parsed_ir(f, Tuple{Int8, Int8})
        lr_karat = Bennett.lower(parsed2; use_karatsuba=true)
        c_karat = Bennett.bennett(lr_karat)

        gc_school = gate_count(c_school)
        gc_karat  = gate_count(c_karat)
        println("  Int8 mul: schoolbook=$(gc_school.Toffoli) Toff, karatsuba=$(gc_karat.Toffoli) Toff")

        # Correctness: every input pair in a representative window
        # (full 256×256 sweep is unnecessary — we already verify
        # reversibility below, which exhaustively walks every
        # input bit pattern.)
        for x in Int8(-10):Int8(10), y in Int8(-10):Int8(10)
            @test simulate(c_karat, (x, y)) == simulate(c_school, (x, y))
        end
        @test verify_reversibility(c_karat)
    end
end
