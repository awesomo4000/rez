/// Derivative computation over minterms.
/// δ_m(R) strips one character matching minterm m from regex R.
/// Results are interned so rewrite rules fire automatically.
const std = @import("std");
const node_mod = @import("node.zig");
const Node = node_mod.Node;
const NodeId = node_mod.NodeId;
const NOTHING = node_mod.NOTHING;
const EPSILON = node_mod.EPSILON;
const interner_mod = @import("interner.zig");
const Interner = interner_mod.Interner;
const nullability = @import("nullability.zig");

/// Compute the derivative of a regex node with respect to a minterm.
/// The minterm is identified by its index (0..num_minterms-1).
/// Context flags `at_start` and `at_end` control anchor resolution.
pub fn derivative(interner: *Interner, id: NodeId, minterm: u8, at_start: bool, at_end: bool) !NodeId {
    const n = interner.get(id);

    switch (n) {
        .nothing => return NOTHING,
        .epsilon => return NOTHING,
        .anchor_start => return NOTHING,
        .anchor_end => return NOTHING,
        .predicate => |pred| {
            // Check if this predicate matches the given minterm
            const bit: u64 = @as(u64, 1) << @intCast(minterm);
            if ((pred.bitvec & bit) != 0) {
                return EPSILON;
            } else {
                return NOTHING;
            }
        },
        .concat => |cat| {
            // δ_m(R·S) = δ_m(R)·S | ν(R)·δ_m(S)
            // where ν(R) uses context-aware nullability for anchors
            const dr = try derivative(interner, cat.left, minterm, at_start, at_end);
            const dr_s = try interner.intern(.{ .concat = .{ .left = dr, .right = cat.right } });

            if (nullability.isNullableAt(interner, cat.left, at_start, at_end)) {
                const ds = try derivative(interner, cat.right, minterm, at_start, at_end);
                if (dr_s == NOTHING) return ds;
                if (ds == NOTHING) return dr_s;
                const children = try interner.allocChildren(&.{ dr_s, ds });
                return interner.intern(.{ .alternation = .{ .children = children } });
            }

            return dr_s;
        },
        .alternation => |alt| {
            // δ_m(R|S) = δ_m(R) | δ_m(S)
            var result_children: std.ArrayList(NodeId) = .empty;
            defer result_children.deinit(interner.allocator);

            for (alt.children) |child| {
                const d = try derivative(interner, child, minterm, at_start, at_end);
                if (d != NOTHING) {
                    try result_children.append(interner.allocator, d);
                }
            }

            if (result_children.items.len == 0) return NOTHING;
            if (result_children.items.len == 1) return result_children.items[0];

            const children = try interner.allocChildren(result_children.items);
            return interner.intern(.{ .alternation = .{ .children = children } });
        },
        .loop => |lp| {
            // δ_m(R{min,max}) = δ_m(R) · R{min-1, max-1}
            // (with min-1 clamped to 0, max-1 handled for overflow)
            const dr = try derivative(interner, lp.child, minterm, at_start, at_end);
            if (dr == NOTHING) return NOTHING;

            const new_min = if (lp.min > 0) lp.min - 1 else 0;
            const new_max = if (lp.max == Node.UNBOUNDED) Node.UNBOUNDED else lp.max - 1;

            const rest = try interner.intern(.{ .loop = .{
                .child = lp.child,
                .min = new_min,
                .max = new_max,
            } });

            return interner.intern(.{ .concat = .{ .left = dr, .right = rest } });
        },
    }
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;
const parser_mod = @import("parser.zig");
const minterm_mod = @import("minterm.zig");

/// Helper: parse, lower, compute minterms, return (interner, root_id, table)
fn setupForDerivative(pattern: []const u8) !struct { interner: Interner, root_id: NodeId, table: minterm_mod.MintermTable } {
    var interner = try Interner.init(testing.allocator);
    errdefer interner.deinit();

    const expr = try parser_mod.parse(testing.allocator, pattern);
    defer {
        expr.deinit(testing.allocator);
        testing.allocator.destroy(expr);
    }
    const root_id = try interner.lower(expr);
    const table = try minterm_mod.computeMinterms(testing.allocator, &interner, root_id);

    return .{ .interner = interner, .root_id = root_id, .table = table };
}

test "predicate match → EPSILON" {
    var s = try setupForDerivative("a");
    defer s.interner.deinit();

    const mt_a = s.table.getMintermForChar('a');
    const d = try derivative(&s.interner, s.root_id, mt_a, false, false);
    try testing.expectEqual(EPSILON, d);
}

test "predicate miss → NOTHING" {
    var s = try setupForDerivative("a");
    defer s.interner.deinit();

    const mt_b = s.table.getMintermForChar('b');
    const d = try derivative(&s.interner, s.root_id, mt_b, false, false);
    try testing.expectEqual(NOTHING, d);
}

test "EPSILON derivative → NOTHING" {
    var s = try setupForDerivative("a");
    defer s.interner.deinit();

    const mt_a = s.table.getMintermForChar('a');
    const d = try derivative(&s.interner, EPSILON, mt_a, false, false);
    try testing.expectEqual(NOTHING, d);
}

test "NOTHING derivative → NOTHING" {
    var s = try setupForDerivative("a");
    defer s.interner.deinit();

    const mt_a = s.table.getMintermForChar('a');
    const d = try derivative(&s.interner, NOTHING, mt_a, false, false);
    try testing.expectEqual(NOTHING, d);
}

test "concat derivative: abc through a → bc" {
    var s = try setupForDerivative("abc");
    defer s.interner.deinit();

    const mt_a = s.table.getMintermForChar('a');
    const d1 = try derivative(&s.interner, s.root_id, mt_a, false, false);

    // d1 should represent "bc"
    // Take derivative through 'b'
    const mt_b = s.table.getMintermForChar('b');
    const d2 = try derivative(&s.interner, d1, mt_b, false, false);

    // d2 should represent "c"
    const mt_c = s.table.getMintermForChar('c');
    const d3 = try derivative(&s.interner, d2, mt_c, false, false);

    // d3 should be EPSILON
    try testing.expectEqual(EPSILON, d3);
}

test "abc: wrong first char → NOTHING" {
    var s = try setupForDerivative("abc");
    defer s.interner.deinit();

    const mt_b = s.table.getMintermForChar('b');
    const d = try derivative(&s.interner, s.root_id, mt_b, false, false);
    try testing.expectEqual(NOTHING, d);
}

test "alt derivative: a|b through a → ε" {
    var s = try setupForDerivative("a|b");
    defer s.interner.deinit();

    const mt_a = s.table.getMintermForChar('a');
    const d = try derivative(&s.interner, s.root_id, mt_a, false, false);
    try testing.expectEqual(EPSILON, d);
}

test "alt derivative: a|b through b → ε" {
    var s = try setupForDerivative("a|b");
    defer s.interner.deinit();

    const mt_b = s.table.getMintermForChar('b');
    const d = try derivative(&s.interner, s.root_id, mt_b, false, false);
    try testing.expectEqual(EPSILON, d);
}

test "loop derivative: a* through a → a* (structural sharing)" {
    var s = try setupForDerivative("a*");
    defer s.interner.deinit();

    const mt_a = s.table.getMintermForChar('a');
    const d = try derivative(&s.interner, s.root_id, mt_a, false, false);

    // δ_a(a*) should be ε·a* = a* (via concat(ε,R)→R rewrite)
    try testing.expectEqual(s.root_id, d);
}

test "loop derivative: a* through b → NOTHING" {
    var s = try setupForDerivative("a*");
    defer s.interner.deinit();

    const mt_b = s.table.getMintermForChar('b');
    const d = try derivative(&s.interner, s.root_id, mt_b, false, false);
    try testing.expectEqual(NOTHING, d);
}

test "dead state propagation: NOTHING stays dead" {
    var s = try setupForDerivative("a");
    defer s.interner.deinit();

    const mt_a = s.table.getMintermForChar('a');
    const mt_b = s.table.getMintermForChar('b');

    // First, get to dead state
    const dead = try derivative(&s.interner, s.root_id, mt_b, false, false);
    try testing.expectEqual(NOTHING, dead);

    // Dead state stays dead regardless of input
    const still_dead = try derivative(&s.interner, dead, mt_a, false, false);
    try testing.expectEqual(NOTHING, still_dead);
}

test "sequence: a+ through aaa → nullable at each step" {
    var s = try setupForDerivative("a+");
    defer s.interner.deinit();

    const mt_a = s.table.getMintermForChar('a');

    // a+ through 'a' should be nullable (matched at least one)
    const d1 = try derivative(&s.interner, s.root_id, mt_a, false, false);
    try testing.expect(nullability.isNullable(&s.interner, d1));

    // Through another 'a' should still be nullable
    const d2 = try derivative(&s.interner, d1, mt_a, false, false);
    try testing.expect(nullability.isNullable(&s.interner, d2));
}

test "[a-z]+ through Hello → tracks correctly" {
    var s = try setupForDerivative("[a-z]+");
    defer s.interner.deinit();

    // 'H' is not in [a-z], should be NOTHING
    const mt_h = s.table.getMintermForChar('H');
    const d = try derivative(&s.interner, s.root_id, mt_h, false, false);
    try testing.expectEqual(NOTHING, d);

    // 'e' is in [a-z], should be nullable (one match done)
    const mt_e = s.table.getMintermForChar('e');
    const d2 = try derivative(&s.interner, s.root_id, mt_e, false, false);
    try testing.expect(nullability.isNullable(&s.interner, d2));
}
