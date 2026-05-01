# Bennett-i2ca / U55: pin that the new `bennett(lr; strategy=...)` API
# reaches every existing variant and produces byte-identical gate
# sequences vs the legacy `*_bennett` aliases. The aliases are kept as
# thin forwarders for backward compat (no `@deprecate`).

# Top-level so `struct` is legal (testset bodies use `let`).
struct _I2caBogusStrategy <: Bennett.BennettStrategy end

@testset "Bennett-i2ca / U55 — strategy dispatch" begin

# ---- fixtures ----------------------------------------------------------------

# Straight-line: incrementer. Hits every strategy without any branching
# fallbacks (none of `_has_branching` or in-place / no-groups paths).
_lr_straight() = Bennett.lower(Bennett.extract_parsed_ir(x -> x + Int8(3), Tuple{Int8}))

# Branching: ternary. Triggers fallbacks-to-default in value_eager /
# pebbled / pebbled_group / checkpoint paths.
_lr_branchy() = Bennett.lower(Bennett.extract_parsed_ir(
    x -> x > Int8(0) ? x + Int8(1) : x - Int8(1),
    Tuple{Int8}))

# ---- parity: straight-line ---------------------------------------------------

@testset "DefaultStrategy parity" begin
    lr = _lr_straight()
    c1 = Bennett.bennett(lr)
    c2 = Bennett.bennett(lr; strategy=Bennett.DefaultStrategy())
    c3 = Bennett.bennett(lr, Bennett.DefaultStrategy())
    @test gate_count(c1) == gate_count(c2) == gate_count(c3)
    @test c1.gates == c2.gates == c3.gates
    @test c1.n_wires == c2.n_wires == c3.n_wires
    @test verify_reversibility(c1)
end

@testset "EagerStrategy parity" begin
    lr = _lr_straight()
    c_alias = eager_bennett(lr)
    c_kw    = Bennett.bennett(lr; strategy=Bennett.EagerStrategy())
    c_pos   = Bennett.bennett(lr, Bennett.EagerStrategy())
    @test gate_count(c_alias) == gate_count(c_kw) == gate_count(c_pos)
    @test c_alias.gates == c_kw.gates == c_pos.gates
    @test verify_reversibility(c_kw)
end

@testset "ValueEagerStrategy parity" begin
    lr = _lr_straight()
    c_alias = value_eager_bennett(lr)
    c_kw    = Bennett.bennett(lr; strategy=Bennett.ValueEagerStrategy())
    @test gate_count(c_alias) == gate_count(c_kw)
    @test c_alias.gates == c_kw.gates
end

@testset "CheckpointStrategy parity" begin
    lr = _lr_straight()
    c_alias = checkpoint_bennett(lr)
    c_kw    = Bennett.bennett(lr; strategy=Bennett.CheckpointStrategy())
    @test gate_count(c_alias) == gate_count(c_kw)
    @test c_alias.gates == c_kw.gates
end

@testset "PebbledStrategy parity (max_pebbles on the struct)" begin
    lr = _lr_straight()
    # max_pebbles=0 → falls back to default; explicit large value falls back
    # similarly. Pick the alias's own default to exercise the fallback path.
    c_alias = pebbled_bennett(lr; max_pebbles=0)
    c_kw    = Bennett.bennett(lr; strategy=Bennett.PebbledStrategy(0))
    c_pos   = Bennett.bennett(lr, Bennett.PebbledStrategy())
    @test gate_count(c_alias) == gate_count(c_kw) == gate_count(c_pos)
    @test c_alias.gates == c_kw.gates == c_pos.gates
end

@testset "PebbledGroupStrategy parity" begin
    lr = _lr_straight()
    c_alias = pebbled_group_bennett(lr; max_pebbles=0)
    c_kw    = Bennett.bennett(lr; strategy=Bennett.PebbledGroupStrategy(0))
    c_pos   = Bennett.bennett(lr, Bennett.PebbledGroupStrategy())
    @test gate_count(c_alias) == gate_count(c_kw) == gate_count(c_pos)
    @test c_alias.gates == c_kw.gates == c_pos.gates
end

# ---- branching fallback path: critical regression catch ----------------------

# Bennett-prtp / U04 + Bennett-rggq / U02 fallback paths: branching CFGs
# trigger `_has_branching(lr)` which returns `bennett(lr)` from inside the
# variant. After this refactor, that internal call must STILL route to
# `DefaultStrategy` (the canonical Bennett wrap) — NOT recursively re-enter
# the active strategy. Pin both forms agree.

@testset "branching fallback routes to default" begin
    lr = _lr_branchy()
    @test gate_count(value_eager_bennett(lr)) ==
          gate_count(Bennett.bennett(lr; strategy=Bennett.ValueEagerStrategy()))
    @test gate_count(pebbled_bennett(lr)) ==
          gate_count(Bennett.bennett(lr; strategy=Bennett.PebbledStrategy()))
    @test gate_count(pebbled_group_bennett(lr)) ==
          gate_count(Bennett.bennett(lr; strategy=Bennett.PebbledGroupStrategy()))
    @test gate_count(checkpoint_bennett(lr)) ==
          gate_count(Bennett.bennett(lr; strategy=Bennett.CheckpointStrategy()))
end

# ---- type hierarchy ---------------------------------------------------------

@testset "abstract type and subtypes" begin
    @test Bennett.DefaultStrategy       <: Bennett.BennettStrategy
    @test Bennett.EagerStrategy         <: Bennett.BennettStrategy
    @test Bennett.ValueEagerStrategy    <: Bennett.BennettStrategy
    @test Bennett.CheckpointStrategy    <: Bennett.BennettStrategy
    @test Bennett.PebbledStrategy       <: Bennett.BennettStrategy
    @test Bennett.PebbledGroupStrategy  <: Bennett.BennettStrategy

    # parameterised constructors
    @test Bennett.PebbledStrategy().max_pebbles == 0
    @test Bennett.PebbledStrategy(7).max_pebbles == 7
    @test Bennett.PebbledGroupStrategy(13).max_pebbles == 13
end

# ---- fail-fast on unknown strategy (CLAUDE.md §1) ---------------------------

@testset "unknown strategy raises" begin
    lr = _lr_straight()
    @test_throws MethodError Bennett.bennett(lr, _I2caBogusStrategy())
end

end  # @testset "Bennett-i2ca / U55"
