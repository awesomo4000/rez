/// Nullability checks on interned regex nodes.
/// A node is nullable if it can match the empty string.
const std = @import("std");
const node_mod = @import("node.zig");
const Node = node_mod.Node;
const NodeId = node_mod.NodeId;
const NOTHING = node_mod.NOTHING;
const EPSILON = node_mod.EPSILON;
const interner_mod = @import("interner.zig");
const Interner = interner_mod.Interner;

/// Context-free nullability check.
/// Anchors are considered non-nullable (they need context to evaluate).
pub fn isNullable(interner: *const Interner, id: NodeId) bool {
    return isNullableAt(interner, id, false, false);
}

/// Context-aware nullability check.
/// `at_start`: true if we are at the beginning of input.
/// `at_end`: true if we are at the end of input.
pub fn isNullableAt(interner: *const Interner, id: NodeId, at_start: bool, at_end: bool) bool {
    const n = interner.get(id);
    switch (n) {
        .nothing => return false,
        .epsilon => return true,
        .predicate => return false,
        .anchor_start => return at_start,
        .anchor_end => return at_end,
        .concat => |cat| {
            return isNullableAt(interner, cat.left, at_start, at_end) and
                isNullableAt(interner, cat.right, at_start, at_end);
        },
        .alternation => |alt| {
            for (alt.children) |child| {
                if (isNullableAt(interner, child, at_start, at_end)) return true;
            }
            return false;
        },
        .loop => |lp| {
            if (lp.min == 0) return true;
            return isNullableAt(interner, lp.child, at_start, at_end);
        },
    }
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "NOTHING is not nullable" {
    var interner = try Interner.init(testing.allocator);
    defer interner.deinit();
    try testing.expect(!isNullable(&interner, NOTHING));
}

test "EPSILON is nullable" {
    var interner = try Interner.init(testing.allocator);
    defer interner.deinit();
    try testing.expect(isNullable(&interner, EPSILON));
}

test "predicate is not nullable" {
    var interner = try Interner.init(testing.allocator);
    defer interner.deinit();

    const ranges = try interner.allocRanges(&.{.{ .lo = 'a', .hi = 'a' }});
    const id = try interner.intern(.{ .predicate = .{ .ranges = ranges } });
    try testing.expect(!isNullable(&interner, id));
}

test "loop(R, 0, _) is nullable" {
    var interner = try Interner.init(testing.allocator);
    defer interner.deinit();

    const ranges = try interner.allocRanges(&.{.{ .lo = 'a', .hi = 'a' }});
    const r = try interner.intern(.{ .predicate = .{ .ranges = ranges } });
    const id = try interner.intern(.{ .loop = .{ .child = r, .min = 0, .max = 5 } });
    try testing.expect(isNullable(&interner, id));
}

test "loop(R, 1, _) is not nullable when R is not nullable" {
    var interner = try Interner.init(testing.allocator);
    defer interner.deinit();

    const ranges = try interner.allocRanges(&.{.{ .lo = 'a', .hi = 'a' }});
    const r = try interner.intern(.{ .predicate = .{ .ranges = ranges } });
    const id = try interner.intern(.{ .loop = .{ .child = r, .min = 1, .max = 5 } });
    try testing.expect(!isNullable(&interner, id));
}

test "alt with nullable child is nullable" {
    var interner = try Interner.init(testing.allocator);
    defer interner.deinit();

    const ranges = try interner.allocRanges(&.{.{ .lo = 'a', .hi = 'a' }});
    const r = try interner.intern(.{ .predicate = .{ .ranges = ranges } });
    const children = try interner.allocChildren(&.{ r, EPSILON });
    const id = try interner.intern(.{ .alternation = .{ .children = children } });
    try testing.expect(isNullable(&interner, id));
}

test "alt with no nullable children is not nullable" {
    var interner = try Interner.init(testing.allocator);
    defer interner.deinit();

    const ranges_a = try interner.allocRanges(&.{.{ .lo = 'a', .hi = 'a' }});
    const a = try interner.intern(.{ .predicate = .{ .ranges = ranges_a } });
    const ranges_b = try interner.allocRanges(&.{.{ .lo = 'b', .hi = 'b' }});
    const b = try interner.intern(.{ .predicate = .{ .ranges = ranges_b } });
    const children = try interner.allocChildren(&.{ a, b });
    const id = try interner.intern(.{ .alternation = .{ .children = children } });
    try testing.expect(!isNullable(&interner, id));
}

test "concat both nullable is nullable" {
    var interner = try Interner.init(testing.allocator);
    defer interner.deinit();

    // concat(ε, ε) should simplify to ε via rewrite, but let's test the concept
    // Use a nullable loop instead
    const ranges = try interner.allocRanges(&.{.{ .lo = 'a', .hi = 'a' }});
    const r = try interner.intern(.{ .predicate = .{ .ranges = ranges } });
    const loop1 = try interner.intern(.{ .loop = .{ .child = r, .min = 0, .max = 5 } });
    const loop2 = try interner.intern(.{ .loop = .{ .child = r, .min = 0, .max = 3 } });
    const id = try interner.intern(.{ .concat = .{ .left = loop1, .right = loop2 } });
    try testing.expect(isNullable(&interner, id));
}

test "concat one non-nullable is not nullable" {
    var interner = try Interner.init(testing.allocator);
    defer interner.deinit();

    const ranges = try interner.allocRanges(&.{.{ .lo = 'a', .hi = 'a' }});
    const r = try interner.intern(.{ .predicate = .{ .ranges = ranges } });
    const loop_id = try interner.intern(.{ .loop = .{ .child = r, .min = 0, .max = 5 } });
    const id = try interner.intern(.{ .concat = .{ .left = loop_id, .right = r } });
    try testing.expect(!isNullable(&interner, id));
}

test "anchor_start: context-free is false" {
    var interner = try Interner.init(testing.allocator);
    defer interner.deinit();

    const id = try interner.intern(.anchor_start);
    try testing.expect(!isNullable(&interner, id));
}

test "anchor_start: at_start=true is true" {
    var interner = try Interner.init(testing.allocator);
    defer interner.deinit();

    const id = try interner.intern(.anchor_start);
    try testing.expect(isNullableAt(&interner, id, true, false));
}

test "anchor_end: context-free is false" {
    var interner = try Interner.init(testing.allocator);
    defer interner.deinit();

    const id = try interner.intern(.anchor_end);
    try testing.expect(!isNullable(&interner, id));
}

test "anchor_end: at_end=true is true" {
    var interner = try Interner.init(testing.allocator);
    defer interner.deinit();

    const id = try interner.intern(.anchor_end);
    try testing.expect(isNullableAt(&interner, id, false, true));
}

test "DOTSTAR is nullable" {
    var interner = try Interner.init(testing.allocator);
    defer interner.deinit();

    try testing.expect(isNullable(&interner, node_mod.DOTSTAR));
}

test "ANYSTAR is nullable" {
    var interner = try Interner.init(testing.allocator);
    defer interner.deinit();

    try testing.expect(isNullable(&interner, node_mod.ANYSTAR));
}
