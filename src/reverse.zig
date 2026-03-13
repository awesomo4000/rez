/// Reverse a regex node through the interner.
///
/// reverse(Concat(A, B)) = Concat(reverse(B), reverse(A))
/// reverse(Alt(children))  = Alt(reverse(each child))
/// reverse(Loop(child, min, max)) = Loop(reverse(child), min, max)
/// reverse(Predicate)      = Predicate  (unchanged)
/// reverse(Epsilon)         = Epsilon
/// reverse(Nothing)         = Nothing
/// reverse(anchor_start)    = anchor_end
/// reverse(anchor_end)      = anchor_start
///
/// Uses a cache to avoid redundant work on shared sub-expressions.
const std = @import("std");
const node_mod = @import("node.zig");
const Node = node_mod.Node;
const NodeId = node_mod.NodeId;
const NOTHING = node_mod.NOTHING;
const EPSILON = node_mod.EPSILON;
const interner_mod = @import("interner.zig");
const Interner = interner_mod.Interner;

/// Reverse the regex rooted at `id`, returning the NodeId of the reversed tree.
/// The result is interned (hash-consed) so rewrite rules fire automatically.
pub fn reverseNode(interner: *Interner, id: NodeId) !NodeId {
    var cache: std.AutoHashMapUnmanaged(NodeId, NodeId) = .empty;
    defer cache.deinit(interner.allocator);
    return reverseNodeCached(interner, id, &cache);
}

const ReverseError = std.mem.Allocator.Error;

fn reverseNodeCached(
    interner: *Interner,
    id: NodeId,
    cache: *std.AutoHashMapUnmanaged(NodeId, NodeId),
) ReverseError!NodeId {
    // Check cache
    if (cache.get(id)) |cached| return cached;

    const n = interner.get(id);

    const result: NodeId = switch (n) {
        .nothing => NOTHING,
        .epsilon => EPSILON,
        .predicate => id, // character predicates are direction-independent

        .anchor_start => try interner.intern(.anchor_end),
        .anchor_end => try interner.intern(.anchor_start),

        .concat => |cat| blk: {
            // reverse(A · B) = reverse(B) · reverse(A)
            const rev_left = try reverseNodeCached(interner, cat.left, cache);
            const rev_right = try reverseNodeCached(interner, cat.right, cache);
            break :blk try interner.intern(.{ .concat = .{ .left = rev_right, .right = rev_left } });
        },

        .alternation => |alt| blk: {
            // reverse(A | B | ...) = reverse(A) | reverse(B) | ...
            var rev_children: std.ArrayList(NodeId) = .empty;
            defer rev_children.deinit(interner.allocator);

            for (alt.children) |child| {
                const rev = try reverseNodeCached(interner, child, cache);
                try rev_children.append(interner.allocator, rev);
            }

            const children = try interner.allocChildren(rev_children.items);
            break :blk try interner.intern(.{ .alternation = .{ .children = children } });
        },

        .loop => |lp| blk: {
            // reverse(R{min,max}) = reverse(R){min,max}
            const rev_child = try reverseNodeCached(interner, lp.child, cache);
            break :blk try interner.intern(.{ .loop = .{
                .child = rev_child,
                .min = lp.min,
                .max = lp.max,
            } });
        },
    };

    try cache.put(interner.allocator, id, result);
    return result;
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;
const parser_mod = @import("parser.zig");
const minterm_mod = @import("minterm.zig");
const nullability_mod = @import("nullability.zig");
const derivative_mod = @import("derivative.zig");

fn setupReverse(pattern: []const u8) !struct { interner: Interner, root_id: NodeId } {
    var interner = try Interner.init(testing.allocator);
    errdefer interner.deinit();

    const expr = try parser_mod.parse(testing.allocator, pattern);
    defer {
        expr.deinit(testing.allocator);
        testing.allocator.destroy(expr);
    }
    const root_id = try interner.lower(expr);
    return .{ .interner = interner, .root_id = root_id };
}

test "reverse of single predicate is itself" {
    var s = try setupReverse("a");
    defer s.interner.deinit();

    const rev = try reverseNode(&s.interner, s.root_id);
    // Single char predicate reversal is the same node
    try testing.expectEqual(s.root_id, rev);
}

test "reverse of concat abc → cba" {
    var s = try setupReverse("abc");
    defer s.interner.deinit();

    const rev = try reverseNode(&s.interner, s.root_id);

    // The reversed pattern should accept "cba" — verify via derivatives
    const table = try minterm_mod.computeMinterms(testing.allocator, &s.interner, rev);

    const mt_a = table.getMintermForChar('a');
    const mt_b = table.getMintermForChar('b');
    const mt_c = table.getMintermForChar('c');

    // Feed "cba" through the reversed automaton
    const d1 = try derivative_mod.derivative(&s.interner, rev, mt_c, false, false);
    try testing.expect(d1 != NOTHING);

    const d2 = try derivative_mod.derivative(&s.interner, d1, mt_b, false, false);
    try testing.expect(d2 != NOTHING);

    const d3 = try derivative_mod.derivative(&s.interner, d2, mt_a, false, false);
    try testing.expectEqual(EPSILON, d3);
}

test "reverse of abc rejects abc" {
    var s = try setupReverse("abc");
    defer s.interner.deinit();

    const rev = try reverseNode(&s.interner, s.root_id);
    const table = try minterm_mod.computeMinterms(testing.allocator, &s.interner, rev);

    // Feed "abc" through the reversed automaton — should fail at first char
    const mt_a = table.getMintermForChar('a');
    const d1 = try derivative_mod.derivative(&s.interner, rev, mt_a, false, false);
    try testing.expectEqual(NOTHING, d1);
}

test "reverse of alternation a|bc → a|cb" {
    var s = try setupReverse("a|bc");
    defer s.interner.deinit();

    const rev = try reverseNode(&s.interner, s.root_id);
    const table = try minterm_mod.computeMinterms(testing.allocator, &s.interner, rev);

    // "a" should still match
    const mt_a = table.getMintermForChar('a');
    const d1 = try derivative_mod.derivative(&s.interner, rev, mt_a, false, false);
    try testing.expect(nullability_mod.isNullable(&s.interner, d1));

    // "cb" should match (reversed "bc")
    const mt_b = table.getMintermForChar('b');
    const mt_c = table.getMintermForChar('c');
    const d2 = try derivative_mod.derivative(&s.interner, rev, mt_c, false, false);
    try testing.expect(d2 != NOTHING);
    const d3 = try derivative_mod.derivative(&s.interner, d2, mt_b, false, false);
    try testing.expect(nullability_mod.isNullable(&s.interner, d3));
}

test "reverse of loop a+ → a+" {
    var s = try setupReverse("a+");
    defer s.interner.deinit();

    const rev = try reverseNode(&s.interner, s.root_id);

    // a+ reversed is still a+ (single-char loop is palindromic)
    // Verify it accepts "aaa"
    const table = try minterm_mod.computeMinterms(testing.allocator, &s.interner, rev);
    const mt_a = table.getMintermForChar('a');

    const d1 = try derivative_mod.derivative(&s.interner, rev, mt_a, false, false);
    try testing.expect(nullability_mod.isNullable(&s.interner, d1));

    const d2 = try derivative_mod.derivative(&s.interner, d1, mt_a, false, false);
    try testing.expect(nullability_mod.isNullable(&s.interner, d2));
}

test "reverse of epsilon is epsilon" {
    var interner = try Interner.init(testing.allocator);
    defer interner.deinit();

    const rev = try reverseNode(&interner, EPSILON);
    try testing.expectEqual(EPSILON, rev);
}

test "reverse of nothing is nothing" {
    var interner = try Interner.init(testing.allocator);
    defer interner.deinit();

    const rev = try reverseNode(&interner, NOTHING);
    try testing.expectEqual(NOTHING, rev);
}

test "reverse swaps anchors" {
    var interner = try Interner.init(testing.allocator);
    defer interner.deinit();

    const start_id = try interner.intern(.anchor_start);
    const end_id = try interner.intern(.anchor_end);

    const rev_start = try reverseNode(&interner, start_id);
    const rev_end = try reverseNode(&interner, end_id);

    // anchor_start → anchor_end
    try testing.expectEqual(end_id, rev_start);
    // anchor_end → anchor_start
    try testing.expectEqual(start_id, rev_end);
}

test "reverse of anchored \\Aabc → cba\\z equivalent" {
    var s = try setupReverse("\\Aabc");
    defer s.interner.deinit();

    const rev = try reverseNode(&s.interner, s.root_id);
    const table = try minterm_mod.computeMinterms(testing.allocator, &s.interner, rev);

    // The reversed pattern is concat(reverse("abc"), anchor_end)
    // = concat(concat(c, concat(b, a)), anchor_end)
    // To test: feed "cba" with at_end=true on last char
    const mt_a = table.getMintermForChar('a');
    const mt_b = table.getMintermForChar('b');
    const mt_c = table.getMintermForChar('c');

    const d1 = try derivative_mod.derivative(&s.interner, rev, mt_c, false, false);
    try testing.expect(d1 != NOTHING);

    const d2 = try derivative_mod.derivative(&s.interner, d1, mt_b, false, false);
    try testing.expect(d2 != NOTHING);

    const d3 = try derivative_mod.derivative(&s.interner, d2, mt_a, false, true);
    try testing.expect(d3 != NOTHING);

    // Should be nullable at end
    try testing.expect(nullability_mod.isNullableAt(&s.interner, d3, false, true));
}
