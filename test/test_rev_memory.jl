using Test, Bennett
@testset "Reversible memory operations" begin

    @testset "MUX array_get: 4 elements" begin
        function mux_get4(a0::Int8, a1::Int8, a2::Int8, a3::Int8, idx::Int8)::Int8
            lo = (idx & Int8(1)) == Int8(0) ? a0 : a1
            hi = (idx & Int8(1)) == Int8(0) ? a2 : a3
            return (idx & Int8(2)) == Int8(0) ? lo : hi
        end

        c = reversible_compile(mux_get4, Int8, Int8, Int8, Int8, Int8)
        for i in Int8(0):Int8(3)
            expected = [Int8(10), Int8(20), Int8(30), Int8(40)][i+1]
            @test Int8(simulate(c, (Int8(10), Int8(20), Int8(30), Int8(40), i))) == expected
        end
        @test verify_reversibility(c)
        println("  mux_get4: $(gate_count(c).total) gates, $(c.n_wires) wires")
    end

    @testset "Reversible EXCH: write + return old value" begin
        # Reversible write at index 0: returns (new_a0, a1, a2, a3, old_a0)
        # Separate args in, tuple out — works with optimize=true
        function exch_at0(a0::Int8, a1::Int8, a2::Int8, a3::Int8, val::Int8)
            return (val, a1, a2, a3, a0)
        end

        c = reversible_compile(exch_at0, Int8, Int8, Int8, Int8, Int8)
        result = simulate(c, (Int8(10), Int8(20), Int8(30), Int8(40), Int8(99)))
        @test result == (Int8(99), Int8(20), Int8(30), Int8(40), Int8(10))
        @test verify_reversibility(c)
        println("  exch_at0: $(gate_count(c).total) gates, $(c.n_wires) wires")
    end

    @testset "Reversible EXCH: dynamic index" begin
        # MUX-based dynamic EXCH: swap arr[idx] with val
        # Returns (new_a0, new_a1, new_a2, new_a3, old_val)
        function mux_exch4(a0::Int8, a1::Int8, a2::Int8, a3::Int8, idx::Int8, val::Int8)
            # Read old value
            lo = (idx & Int8(1)) == Int8(0) ? a0 : a1
            hi = (idx & Int8(1)) == Int8(0) ? a2 : a3
            old = (idx & Int8(2)) == Int8(0) ? lo : hi

            # Write new value: conditional replacement
            new0 = idx == Int8(0) ? val : a0
            new1 = idx == Int8(1) ? val : a1
            new2 = idx == Int8(2) ? val : a2
            new3 = idx == Int8(3) ? val : a3

            return (new0, new1, new2, new3, old)
        end

        c = reversible_compile(mux_exch4, Int8, Int8, Int8, Int8, Int8, Int8)

        # Test: swap arr[1] with 99
        result = simulate(c, (Int8(10), Int8(20), Int8(30), Int8(40), Int8(1), Int8(99)))
        @test result == (Int8(10), Int8(99), Int8(30), Int8(40), Int8(20))

        # Test: swap arr[0] with 77
        result2 = simulate(c, (Int8(10), Int8(20), Int8(30), Int8(40), Int8(0), Int8(77)))
        @test result2 == (Int8(77), Int8(20), Int8(30), Int8(40), Int8(10))

        # Test: swap arr[3] with 55
        result3 = simulate(c, (Int8(10), Int8(20), Int8(30), Int8(40), Int8(3), Int8(55)))
        @test result3 == (Int8(10), Int8(20), Int8(30), Int8(55), Int8(40))

        @test verify_reversibility(c)
        gc = gate_count(c)
        println("  mux_exch4: $(gc.total) gates (NOT=$(gc.NOT), CNOT=$(gc.CNOT), Toff=$(gc.Toffoli)), $(c.n_wires) wires")
    end

    @testset "Okasaki RB tree insert (3-node, UInt64-packed)" begin
        function rb_insert(tree::UInt64, key::UInt64)::UInt64
            root = (tree >> 48) & UInt64(7)
            next_free = (tree >> 51) & UInt64(7)
            if root == UInt64(0)
                node = UInt64(1) | (key << 8)
                return node | (UInt64(1) << 48) | (UInt64(2) << 51)
            end
            root_node = root == UInt64(1) ? (tree & UInt64(0xFFFF)) : (root == UInt64(2) ? ((tree >> 16) & UInt64(0xFFFF)) : ((tree >> 32) & UInt64(0xFFFF)))
            rk = (root_node >> 8) & UInt64(0xFF)
            rl = (root_node >> 1) & UInt64(7)
            rr = (root_node >> 4) & UInt64(7)
            if key == rk; return tree; end
            go_left = key < rk ? UInt64(1) : UInt64(0)
            child_idx = go_left == UInt64(1) ? rl : rr
            if child_idx == UInt64(0)
                new_node = UInt64(0) | (key << 8)
                slot = next_free
                new_rl = go_left == UInt64(1) ? slot : rl
                new_rr = go_left == UInt64(0) ? slot : rr
                updated_root = UInt64(1) | (new_rl << 1) | (new_rr << 4) | (rk << 8)
                n1 = root == UInt64(1) ? updated_root : (tree & UInt64(0xFFFF))
                n2 = root == UInt64(2) ? updated_root : ((tree >> 16) & UInt64(0xFFFF))
                n3 = root == UInt64(3) ? updated_root : ((tree >> 32) & UInt64(0xFFFF))
                n1 = slot == UInt64(1) ? new_node : n1
                n2 = slot == UInt64(2) ? new_node : n2
                n3 = slot == UInt64(3) ? new_node : n3
                new_next = next_free + UInt64(1)
                return n1 | (n2 << 16) | (n3 << 32) | (root << 48) | (new_next << 51)
            end
            child_node = child_idx == UInt64(1) ? (tree & UInt64(0xFFFF)) : (child_idx == UInt64(2) ? ((tree >> 16) & UInt64(0xFFFF)) : ((tree >> 32) & UInt64(0xFFFF)))
            ck = (child_node >> 8) & UInt64(0xFF)
            cl = (child_node >> 1) & UInt64(7)
            cr = (child_node >> 4) & UInt64(7)
            child_color = child_node & UInt64(1)
            if key == ck; return tree; end
            go_left2 = key < ck ? UInt64(1) : UInt64(0)
            slot = next_free
            gc_node = UInt64(0) | (key << 8)
            new_cl = go_left2 == UInt64(1) ? slot : cl
            new_cr = go_left2 == UInt64(0) ? slot : cr
            updated_child = child_color | (new_cl << 1) | (new_cr << 4) | (ck << 8)
            needs_balance = child_color == UInt64(0) ? UInt64(1) : UInt64(0)
            if needs_balance == UInt64(1)
                min_k = rk < ck ? (rk < key ? rk : key) : (ck < key ? ck : key)
                max_k = rk > ck ? (rk > key ? rk : key) : (ck > key ? ck : key)
                mid_k = (rk + ck + key) - min_k - max_k
                balanced_root = UInt64(1) | (child_idx << 1) | (slot << 4) | (mid_k << 8)
                balanced_left = UInt64(1) | (min_k << 8)
                balanced_right = UInt64(1) | (max_k << 8)
                n1 = root == UInt64(1) ? balanced_root : (child_idx == UInt64(1) ? balanced_left : (slot == UInt64(1) ? balanced_right : (tree & UInt64(0xFFFF))))
                n2 = root == UInt64(2) ? balanced_root : (child_idx == UInt64(2) ? balanced_left : (slot == UInt64(2) ? balanced_right : ((tree >> 16) & UInt64(0xFFFF))))
                n3 = root == UInt64(3) ? balanced_root : (child_idx == UInt64(3) ? balanced_left : (slot == UInt64(3) ? balanced_right : ((tree >> 32) & UInt64(0xFFFF))))
                new_next = next_free + UInt64(1)
                return n1 | (n2 << 16) | (n3 << 32) | (root << 48) | (new_next << 51)
            else
                n1 = tree & UInt64(0xFFFF)
                n2 = (tree >> 16) & UInt64(0xFFFF)
                n3 = (tree >> 32) & UInt64(0xFFFF)
                n1 = child_idx == UInt64(1) ? updated_child : n1
                n2 = child_idx == UInt64(2) ? updated_child : n2
                n3 = child_idx == UInt64(3) ? updated_child : n3
                n1 = slot == UInt64(1) ? gc_node : n1
                n2 = slot == UInt64(2) ? gc_node : n2
                n3 = slot == UInt64(3) ? gc_node : n3
                root_n = root == UInt64(1) ? n1 : (root == UInt64(2) ? n2 : n3)
                root_n_black = root_n | UInt64(1)
                n1 = root == UInt64(1) ? root_n_black : n1
                n2 = root == UInt64(2) ? root_n_black : n2
                n3 = root == UInt64(3) ? root_n_black : n3
                new_next = next_free + UInt64(1)
                return n1 | (n2 << 16) | (n3 << 32) | (root << 48) | (new_next << 51)
            end
        end

        c = reversible_compile(rb_insert, UInt64, UInt64)
        gc = gate_count(c)
        println("  rb_insert: $(gc.total) gates, $(c.n_wires) wires, $(ancilla_count(c)) ancillae")

        # Test 1: insert into empty
        t1 = simulate(c, (UInt64(0), UInt64(5)))
        @test (t1 >> 8) & 0xFF == 5  # root key = 5

        # Test 2: insert second key
        t2 = simulate(c, (t1, UInt64(3)))
        @test ((t2 >> 8) & 0xFF == 5)   # root key still 5
        @test ((t2 >> 24) & 0xFF == 3)  # child key = 3

        # Test 3: insert third key triggering balance (5,3,1 → balanced to 3,1,5)
        t3 = simulate(c, (t2, UInt64(1)))
        root3 = (t3 >> 48) & 7
        rn = root3 == 1 ? t3 & 0xFFFF : (root3 == 2 ? (t3>>16) & 0xFFFF : (t3>>32) & 0xFFFF)
        @test (rn >> 8) & 0xFF == 3  # root key = 3 after balance

        # Test 4: insert without balance (5,3,7 → root=5, left=3, right=7)
        t2b = simulate(c, (t1, UInt64(3)))
        t3b = simulate(c, (t2b, UInt64(7)))
        @test ((t3b >> 8) & 0xFF == 5)  # root key still 5

        # Test 5: duplicate key returns unchanged tree
        t_dup = simulate(c, (t1, UInt64(5)))
        @test t_dup == t1

        @test verify_reversibility(c)
    end

    @testset "AG13 reversible heap: cons/car/cdr/decons" begin
        # 3-cell heap packed in UInt64. Cell = [in_use:1][left:4][right:4] = 9 bits.
        # Cells at bits [0:8], [9:17], [18:26]. Free_ptr at bits [27:29].

        function rev_cons(heap::UInt64, a::UInt64, b::UInt64)::UInt64
            fp = (heap >> 27) & UInt64(7)
            cell = UInt64(1) | ((a & UInt64(15)) << 1) | ((b & UInt64(15)) << 5)
            shift = (fp - UInt64(1)) * UInt64(9)
            mask = ~(UInt64(0x1FF) << shift)
            new_heap = (heap & mask) | (cell << shift)
            new_fp = fp + UInt64(1)
            return (new_heap & ~(UInt64(7) << 27)) | (new_fp << 27)
        end

        function rev_car(heap::UInt64, idx::UInt64)::UInt64
            shift = (idx - UInt64(1)) * UInt64(9)
            cell = (heap >> shift) & UInt64(0x1FF)
            return (cell >> 1) & UInt64(15)
        end

        function rev_cdr(heap::UInt64, idx::UInt64)::UInt64
            shift = (idx - UInt64(1)) * UInt64(9)
            cell = (heap >> shift) & UInt64(0x1FF)
            return (cell >> 5) & UInt64(15)
        end

        function rev_decons(heap::UInt64, idx::UInt64)::UInt64
            shift = (idx - UInt64(1)) * UInt64(9)
            mask = ~(UInt64(0x1FF) << shift)
            new_heap = heap & mask
            return (new_heap & ~(UInt64(7) << 27)) | (idx << 27)
        end

        c_cons = reversible_compile(rev_cons, UInt64, UInt64, UInt64)
        c_car  = reversible_compile(rev_car, UInt64, UInt64)
        c_cdr  = reversible_compile(rev_cdr, UInt64, UInt64)
        c_decons = reversible_compile(rev_decons, UInt64, UInt64)

        gc = gate_count(c_cons)
        println("  rev_cons: $(gc.total) gates, rev_car: $(gate_count(c_car).total), rev_cdr: $(gate_count(c_cdr).total), rev_decons: $(gate_count(c_decons).total)")

        # Build heap: cons(5,10) then cons(3,7)
        h0 = UInt64(1) << 27  # empty, free_ptr=1
        h1 = simulate(c_cons, (h0, UInt64(5), UInt64(10)))
        h2 = simulate(c_cons, (h1, UInt64(3), UInt64(7)))

        # car/cdr
        @test simulate(c_car, (h2, UInt64(1))) == 5
        @test simulate(c_cdr, (h2, UInt64(1))) == 10
        @test simulate(c_car, (h2, UInt64(2))) == 3
        @test simulate(c_cdr, (h2, UInt64(2))) == 7

        # decons cell2 → free_ptr back to 2
        h3 = simulate(c_decons, (h2, UInt64(2)))
        @test (h3 >> 27) & 7 == 2  # free_ptr = 2

        # cell1 still intact after decons of cell2
        @test simulate(c_car, (h3, UInt64(1))) == 5
        @test simulate(c_cdr, (h3, UInt64(1))) == 10

        @test verify_reversibility(c_cons)
        @test verify_reversibility(c_car)
        @test verify_reversibility(c_cdr)
        @test verify_reversibility(c_decons)
    end
end
