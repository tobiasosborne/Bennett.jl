# Bennett-cs2f / U42 — ported from the legacy `parse_ir` regex parser
# (deleted 2026-04-25) to `extract_parsed_ir` (LLVM.jl C-API walker, the
# canonical extractor since v0.2).  The diagnostic `extract_ir` text
# extraction is kept for the println; assertions now check `parsed`
# directly via the modern path.

@testset "ParsedIR shape — extract_parsed_ir" begin
    @testset "Parse increment" begin
        f(x::Int8) = x + Int8(3)
        ir = extract_ir(f, Tuple{Int8})
        parsed = extract_parsed_ir(f, Tuple{Int8})
        @test length(parsed.args) == 1
        @test parsed.ret_width == 8
        @test any(i -> i isa Bennett.IRBinOp && i.op == :add, Iterators.flatten((blk.instructions..., blk.terminator) for blk in parsed.blocks))
        @test any(i -> i isa Bennett.IRRet, Iterators.flatten((blk.instructions..., blk.terminator) for blk in parsed.blocks))
        println("  IR for x+3:\n", ir)
    end

    @testset "Parse polynomial" begin
        g(x::Int8) = x * x + Int8(3) * x + Int8(1)
        ir = extract_ir(g, Tuple{Int8})
        parsed = extract_parsed_ir(g, Tuple{Int8})
        @test length(parsed.args) == 1
        @test parsed.ret_width == 8
        @test any(i -> i isa Bennett.IRBinOp && i.op == :mul, Iterators.flatten((blk.instructions..., blk.terminator) for blk in parsed.blocks))
        println("  IR for x^2+3x+1:\n", ir)
    end

    @testset "Parse bitwise" begin
        h(x::Int8) = (x & Int8(0x0f)) | (x >> 2)
        ir = extract_ir(h, Tuple{Int8})
        parsed = extract_parsed_ir(h, Tuple{Int8})
        @test any(i -> i isa Bennett.IRBinOp && i.op == :and, Iterators.flatten((blk.instructions..., blk.terminator) for blk in parsed.blocks))
        @test any(i -> i isa Bennett.IRBinOp && i.op == :or, Iterators.flatten((blk.instructions..., blk.terminator) for blk in parsed.blocks))
        println("  IR for bitwise:\n", ir)
    end

    @testset "Parse compare+select" begin
        k(x::Int8) = x > Int8(10) ? x + Int8(1) : x + Int8(2)
        ir = extract_ir(k, Tuple{Int8})
        parsed = extract_parsed_ir(k, Tuple{Int8})
        @test any(i -> i isa Bennett.IRICmp, Iterators.flatten((blk.instructions..., blk.terminator) for blk in parsed.blocks))
        @test any(i -> i isa Bennett.IRSelect, Iterators.flatten((blk.instructions..., blk.terminator) for blk in parsed.blocks))
        println("  IR for compare+select:\n", ir)
    end

    @testset "Parse two-arg" begin
        m(x::Int8, y::Int8) = x * y + x - y
        ir = extract_ir(m, Tuple{Int8, Int8})
        parsed = extract_parsed_ir(m, Tuple{Int8, Int8})
        @test length(parsed.args) == 2
        println("  IR for two-arg:\n", ir)
    end
end
