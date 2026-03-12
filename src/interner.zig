/// Hash-consing interner for regex nodes.
/// intern(node) → NodeId with structural sharing.
/// Rewrite rules are applied during interning.
const std = @import("std");
const Allocator = std.mem.Allocator;
const node_mod = @import("node.zig");
const Node = node_mod.Node;
const NodeId = node_mod.NodeId;
const NOTHING = node_mod.NOTHING;
const EPSILON = node_mod.EPSILON;
const DOTSTAR = node_mod.DOTSTAR;
const ANYSTAR = node_mod.ANYSTAR;
const ast_mod = @import("ast.zig");
const Expr = ast_mod.Expr;
const charset_mod = @import("charset.zig");
const CharSet = charset_mod.CharSet;

const NodeIdList = std.ArrayList(NodeId);

pub const Interner = struct {
    allocator: Allocator,
    /// All interned nodes, indexed by NodeId.
    nodes: std.ArrayList(Node),
    /// Map from node hash to list of NodeIds for dedup.
    dedup: std.AutoHashMapUnmanaged(u64, NodeIdList),
    /// Arena for allocated slices (ranges, children arrays).
    range_arena: std.ArrayList(Node.Predicate.Range),
    children_arena: std.ArrayList(NodeIdList),

    pub fn init(allocator: Allocator) !Interner {
        var self = Interner{
            .allocator = allocator,
            .nodes = .empty,
            .dedup = .empty,
            .range_arena = .empty,
            .children_arena = .empty,
        };

        // Pre-intern sentinel nodes at fixed IDs
        // 0: NOTHING
        try self.nodes.append(allocator, .nothing);
        // 1: EPSILON
        try self.nodes.append(allocator, .epsilon);
        // 2: DOTSTAR placeholder
        try self.nodes.append(allocator, .epsilon);
        // 3: ANYSTAR placeholder
        try self.nodes.append(allocator, .epsilon);

        // DOTSTAR = loop(predicate(everything except \n), 0, max)
        const dot_ranges = try self.allocRanges(&.{
            .{ .lo = 0, .hi = '\n' - 1 },
            .{ .lo = '\n' + 1, .hi = 255 },
        });
        const dot_pred_id = try self.internNode(.{ .predicate = .{ .ranges = dot_ranges } });
        self.nodes.items[DOTSTAR] = .{ .loop = .{
            .child = dot_pred_id,
            .min = 0,
            .max = Node.UNBOUNDED,
        } };

        // ANYSTAR = loop(predicate(0-255), 0, max)
        const any_ranges = try self.allocRanges(&.{
            .{ .lo = 0, .hi = 255 },
        });
        const any_pred_id = try self.internNode(.{ .predicate = .{ .ranges = any_ranges } });
        self.nodes.items[ANYSTAR] = .{ .loop = .{
            .child = any_pred_id,
            .min = 0,
            .max = Node.UNBOUNDED,
        } };

        return self;
    }

    pub fn deinit(self: *Interner) void {
        // Free dedup map values
        var it = self.dedup.valueIterator();
        while (it.next()) |list| {
            var l = list.*;
            l.deinit(self.allocator);
        }
        self.dedup.deinit(self.allocator);

        // Free children arena
        for (self.children_arena.items) |*list| {
            list.deinit(self.allocator);
        }
        self.children_arena.deinit(self.allocator);

        self.range_arena.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
    }

    pub fn get(self: *const Interner, id: NodeId) Node {
        return self.nodes.items[id];
    }

    /// Intern a node, applying rewrite rules and deduplication.
    pub fn intern(self: *Interner, n: Node) !NodeId {
        return self.internWithRewrites(n);
    }

    // ── Rewrite rules ───────────────────────────────────────────────

    fn internWithRewrites(self: *Interner, n: Node) !NodeId {
        switch (n) {
            .nothing => return NOTHING,
            .epsilon => return EPSILON,
            .anchor_start, .anchor_end => return self.internNode(n),
            .predicate => return self.internNode(n),
            .concat => |cat| return self.internConcat(cat.left, cat.right),
            .alternation => |alt| return self.internAlternation(alt.children),
            .loop => |lp| return self.internLoop(lp.child, lp.min, lp.max),
        }
    }

    fn internConcat(self: *Interner, left: NodeId, right: NodeId) !NodeId {
        // concat(⊥, R) → ⊥
        if (left == NOTHING) return NOTHING;
        // concat(R, ⊥) → ⊥
        if (right == NOTHING) return NOTHING;
        // concat(ε, R) → R
        if (left == EPSILON) return right;
        // concat(R, ε) → R
        if (right == EPSILON) return left;

        return self.internNode(.{ .concat = .{ .left = left, .right = right } });
    }

    fn internAlternation(self: *Interner, children: []const NodeId) !NodeId {
        // Flatten nested alternations, remove NOTHING, sort, dedup
        var flat: std.ArrayList(NodeId) = .empty;
        defer flat.deinit(self.allocator);

        for (children) |child_id| {
            if (child_id == NOTHING) continue;

            const child_node = self.get(child_id);
            switch (child_node) {
                .alternation => |inner_alt| {
                    for (inner_alt.children) |grandchild| {
                        if (grandchild == NOTHING) continue;
                        try flat.append(self.allocator, grandchild);
                    }
                },
                else => try flat.append(self.allocator, child_id),
            }
        }

        // Check for _* (ANYSTAR absorbs all)
        for (flat.items) |id| {
            if (id == ANYSTAR) return ANYSTAR;
        }

        // Sort
        std.mem.sort(NodeId, flat.items, {}, std.sort.asc(NodeId));

        // Dedup
        var deduped: std.ArrayList(NodeId) = .empty;
        defer deduped.deinit(self.allocator);
        var prev: ?NodeId = null;
        for (flat.items) |id| {
            if (prev == null or prev.? != id) {
                try deduped.append(self.allocator, id);
                prev = id;
            }
        }

        // Empty alt → ⊥
        if (deduped.items.len == 0) return NOTHING;
        // Single child → unwrap
        if (deduped.items.len == 1) return deduped.items[0];

        const children_owned = try self.allocChildren(deduped.items);
        return self.internNode(.{ .alternation = .{ .children = children_owned } });
    }

    fn internLoop(self: *Interner, child: NodeId, min: u32, max: u32) !NodeId {
        // loop(R, 0, 0) → ε
        if (max == 0) return EPSILON;
        // loop(R, 1, 1) → R
        if (min == 1 and max == 1) return child;
        // loop(ε, _, _) → ε
        if (child == EPSILON) return EPSILON;
        // loop(⊥, _, _) → ε when min=0, else ⊥
        if (child == NOTHING) {
            return if (min == 0) EPSILON else NOTHING;
        }

        return self.internNode(.{ .loop = .{
            .child = child,
            .min = min,
            .max = max,
        } });
    }

    // ── Low-level interning (hash + dedup) ──────────────────────────

    fn internNode(self: *Interner, n: Node) !NodeId {
        const h = hashNode(n);

        if (self.dedup.getPtr(h)) |bucket| {
            for (bucket.items) |existing_id| {
                if (nodesEqual(self.get(existing_id), n)) {
                    return existing_id;
                }
            }
            // Hash collision, different node
            const new_id: NodeId = @intCast(self.nodes.items.len);
            try self.nodes.append(self.allocator, n);
            try bucket.append(self.allocator, new_id);
            return new_id;
        } else {
            const new_id: NodeId = @intCast(self.nodes.items.len);
            try self.nodes.append(self.allocator, n);
            var bucket: NodeIdList = .empty;
            try bucket.append(self.allocator, new_id);
            try self.dedup.put(self.allocator, h, bucket);
            return new_id;
        }
    }

    // ── Arena allocators for slices ─────────────────────────────────

    pub fn allocRanges(self: *Interner, ranges: []const Node.Predicate.Range) ![]const Node.Predicate.Range {
        const start = self.range_arena.items.len;
        try self.range_arena.appendSlice(self.allocator, ranges);
        return self.range_arena.items[start..];
    }

    pub fn allocChildren(self: *Interner, children: []const NodeId) ![]const NodeId {
        var list: NodeIdList = .empty;
        try list.appendSlice(self.allocator, children);
        try self.children_arena.append(self.allocator, list);
        return self.children_arena.items[self.children_arena.items.len - 1].items;
    }

    // ── Hashing ─────────────────────────────────────────────────────

    fn hashNode(n: Node) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hashNodeInto(&hasher, n);
        return hasher.final();
    }

    fn hashNodeInto(hasher: *std.hash.Wyhash, n: Node) void {
        const tag: u8 = switch (n) {
            .nothing => 0,
            .epsilon => 1,
            .predicate => 2,
            .concat => 3,
            .alternation => 4,
            .loop => 5,
            .anchor_start => 6,
            .anchor_end => 7,
        };
        hasher.update(&.{tag});

        switch (n) {
            .nothing, .epsilon, .anchor_start, .anchor_end => {},
            .predicate => |pred| {
                for (pred.ranges) |r| {
                    hasher.update(&.{ r.lo, r.hi });
                }
                hasher.update(std.mem.asBytes(&pred.bitvec));
            },
            .concat => |cat| {
                hasher.update(std.mem.asBytes(&cat.left));
                hasher.update(std.mem.asBytes(&cat.right));
            },
            .alternation => |alt| {
                for (alt.children) |child| {
                    hasher.update(std.mem.asBytes(&child));
                }
            },
            .loop => |lp| {
                hasher.update(std.mem.asBytes(&lp.child));
                hasher.update(std.mem.asBytes(&lp.min));
                hasher.update(std.mem.asBytes(&lp.max));
            },
        }
    }

    fn nodesEqual(a: Node, b: Node) bool {
        const tag_a: u8 = switch (a) {
            .nothing => 0,
            .epsilon => 1,
            .predicate => 2,
            .concat => 3,
            .alternation => 4,
            .loop => 5,
            .anchor_start => 6,
            .anchor_end => 7,
        };
        const tag_b: u8 = switch (b) {
            .nothing => 0,
            .epsilon => 1,
            .predicate => 2,
            .concat => 3,
            .alternation => 4,
            .loop => 5,
            .anchor_start => 6,
            .anchor_end => 7,
        };
        if (tag_a != tag_b) return false;

        switch (a) {
            .nothing, .epsilon, .anchor_start, .anchor_end => return true,
            .predicate => |pa| {
                const pb = b.predicate;
                if (pa.bitvec != pb.bitvec) return false;
                if (pa.ranges.len != pb.ranges.len) return false;
                for (pa.ranges, pb.ranges) |ra, rb| {
                    if (ra.lo != rb.lo or ra.hi != rb.hi) return false;
                }
                return true;
            },
            .concat => |ca| {
                const cb = b.concat;
                return ca.left == cb.left and ca.right == cb.right;
            },
            .alternation => |aa| {
                const ab = b.alternation;
                if (aa.children.len != ab.children.len) return false;
                for (aa.children, ab.children) |ca, cb| {
                    if (ca != cb) return false;
                }
                return true;
            },
            .loop => |la| {
                const lb = b.loop;
                return la.child == lb.child and la.min == lb.min and la.max == lb.max;
            },
        }
    }

    // ── AST lowering ────────────────────────────────────────────────

    /// Convert a raw AST expression into an interned node graph.
    pub fn lower(self: *Interner, expr: *const Expr) !NodeId {
        switch (expr.*) {
            .literal => |c| {
                const ranges = try self.allocRanges(&.{.{ .lo = c, .hi = c }});
                return self.intern(.{ .predicate = .{ .ranges = ranges } });
            },
            .dot => {
                const ranges = try self.allocRanges(&.{
                    .{ .lo = 0, .hi = '\n' - 1 },
                    .{ .lo = '\n' + 1, .hi = 255 },
                });
                return self.intern(.{ .predicate = .{ .ranges = ranges } });
            },
            .any_char => {
                const ranges = try self.allocRanges(&.{.{ .lo = 0, .hi = 255 }});
                return self.intern(.{ .predicate = .{ .ranges = ranges } });
            },
            .epsilon => return EPSILON,
            .anchor_start => return self.intern(.anchor_start),
            .anchor_end => return self.intern(.anchor_end),
            .char_class => |cc| {
                var node_ranges: std.ArrayList(Node.Predicate.Range) = .empty;
                defer node_ranges.deinit(self.allocator);
                for (cc.cs.ranges) |r| {
                    try node_ranges.append(self.allocator, .{ .lo = r.lo, .hi = r.hi });
                }
                const ranges = try self.allocRanges(node_ranges.items);
                return self.intern(.{ .predicate = .{ .ranges = ranges } });
            },
            .concat => |cat| {
                const left = try self.lower(cat.left);
                const right = try self.lower(cat.right);
                return self.intern(.{ .concat = .{ .left = left, .right = right } });
            },
            .alternation => |alt| {
                const left = try self.lower(alt.left);
                const right = try self.lower(alt.right);
                const children = try self.allocChildren(&.{ left, right });
                return self.intern(.{ .alternation = .{ .children = children } });
            },
            .star => |s| {
                const child = try self.lower(s.child);
                return self.intern(.{ .loop = .{
                    .child = child,
                    .min = 0,
                    .max = Node.UNBOUNDED,
                } });
            },
            .plus => |p| {
                const child = try self.lower(p.child);
                const loop_id = try self.intern(.{ .loop = .{
                    .child = child,
                    .min = 0,
                    .max = Node.UNBOUNDED,
                } });
                return self.intern(.{ .concat = .{ .left = child, .right = loop_id } });
            },
            .optional => |o| {
                const child = try self.lower(o.child);
                const children = try self.allocChildren(&.{ child, EPSILON });
                return self.intern(.{ .alternation = .{ .children = children } });
            },
            .repeat => |rep| {
                const child = try self.lower(rep.child);
                const max = rep.max orelse Node.UNBOUNDED;
                return self.intern(.{ .loop = .{
                    .child = child,
                    .min = rep.min,
                    .max = max,
                } });
            },
        }
    }
};

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "sentinel IDs are correct" {
    var interner = try Interner.init(testing.allocator);
    defer interner.deinit();

    try testing.expectEqual(@as(NodeId, 0), NOTHING);
    try testing.expectEqual(@as(NodeId, 1), EPSILON);
    try testing.expectEqual(@as(NodeId, 2), DOTSTAR);
    try testing.expectEqual(@as(NodeId, 3), ANYSTAR);

    switch (interner.get(NOTHING)) {
        .nothing => {},
        else => return error.TestUnexpectedResult,
    }
    switch (interner.get(EPSILON)) {
        .epsilon => {},
        else => return error.TestUnexpectedResult,
    }
    switch (interner.get(DOTSTAR)) {
        .loop => |lp| {
            try testing.expectEqual(@as(u32, 0), lp.min);
            try testing.expectEqual(Node.UNBOUNDED, lp.max);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (interner.get(ANYSTAR)) {
        .loop => |lp| {
            try testing.expectEqual(@as(u32, 0), lp.min);
            try testing.expectEqual(Node.UNBOUNDED, lp.max);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "structural sharing - same literal gets same ID" {
    var interner = try Interner.init(testing.allocator);
    defer interner.deinit();

    const ranges1 = try interner.allocRanges(&.{.{ .lo = 'a', .hi = 'a' }});
    const id1 = try interner.intern(.{ .predicate = .{ .ranges = ranges1 } });

    const ranges2 = try interner.allocRanges(&.{.{ .lo = 'a', .hi = 'a' }});
    const id2 = try interner.intern(.{ .predicate = .{ .ranges = ranges2 } });

    try testing.expectEqual(id1, id2);
}

test "different literals get different IDs" {
    var interner = try Interner.init(testing.allocator);
    defer interner.deinit();

    const ranges_a = try interner.allocRanges(&.{.{ .lo = 'a', .hi = 'a' }});
    const id_a = try interner.intern(.{ .predicate = .{ .ranges = ranges_a } });

    const ranges_b = try interner.allocRanges(&.{.{ .lo = 'b', .hi = 'b' }});
    const id_b = try interner.intern(.{ .predicate = .{ .ranges = ranges_b } });

    try testing.expect(id_a != id_b);
}

test "rewrite: concat(NOTHING, R) → NOTHING" {
    var interner = try Interner.init(testing.allocator);
    defer interner.deinit();

    const ranges = try interner.allocRanges(&.{.{ .lo = 'a', .hi = 'a' }});
    const r = try interner.intern(.{ .predicate = .{ .ranges = ranges } });
    const result = try interner.intern(.{ .concat = .{ .left = NOTHING, .right = r } });
    try testing.expectEqual(NOTHING, result);
}

test "rewrite: concat(R, NOTHING) → NOTHING" {
    var interner = try Interner.init(testing.allocator);
    defer interner.deinit();

    const ranges = try interner.allocRanges(&.{.{ .lo = 'a', .hi = 'a' }});
    const r = try interner.intern(.{ .predicate = .{ .ranges = ranges } });
    const result = try interner.intern(.{ .concat = .{ .left = r, .right = NOTHING } });
    try testing.expectEqual(NOTHING, result);
}

test "rewrite: concat(EPSILON, R) → R" {
    var interner = try Interner.init(testing.allocator);
    defer interner.deinit();

    const ranges = try interner.allocRanges(&.{.{ .lo = 'a', .hi = 'a' }});
    const r = try interner.intern(.{ .predicate = .{ .ranges = ranges } });
    const result = try interner.intern(.{ .concat = .{ .left = EPSILON, .right = r } });
    try testing.expectEqual(r, result);
}

test "rewrite: concat(R, EPSILON) → R" {
    var interner = try Interner.init(testing.allocator);
    defer interner.deinit();

    const ranges = try interner.allocRanges(&.{.{ .lo = 'a', .hi = 'a' }});
    const r = try interner.intern(.{ .predicate = .{ .ranges = ranges } });
    const result = try interner.intern(.{ .concat = .{ .left = r, .right = EPSILON } });
    try testing.expectEqual(r, result);
}

test "rewrite: loop(R, 0, 0) → EPSILON" {
    var interner = try Interner.init(testing.allocator);
    defer interner.deinit();

    const ranges = try interner.allocRanges(&.{.{ .lo = 'a', .hi = 'a' }});
    const r = try interner.intern(.{ .predicate = .{ .ranges = ranges } });
    const result = try interner.intern(.{ .loop = .{ .child = r, .min = 0, .max = 0 } });
    try testing.expectEqual(EPSILON, result);
}

test "rewrite: loop(R, 1, 1) → R" {
    var interner = try Interner.init(testing.allocator);
    defer interner.deinit();

    const ranges = try interner.allocRanges(&.{.{ .lo = 'a', .hi = 'a' }});
    const r = try interner.intern(.{ .predicate = .{ .ranges = ranges } });
    const result = try interner.intern(.{ .loop = .{ .child = r, .min = 1, .max = 1 } });
    try testing.expectEqual(r, result);
}

test "rewrite: loop(EPSILON, _, _) → EPSILON" {
    var interner = try Interner.init(testing.allocator);
    defer interner.deinit();

    const result = try interner.intern(.{ .loop = .{ .child = EPSILON, .min = 3, .max = 5 } });
    try testing.expectEqual(EPSILON, result);
}

test "rewrite: loop(NOTHING, 0, _) → EPSILON" {
    var interner = try Interner.init(testing.allocator);
    defer interner.deinit();

    const result = try interner.intern(.{ .loop = .{ .child = NOTHING, .min = 0, .max = 5 } });
    try testing.expectEqual(EPSILON, result);
}

test "rewrite: loop(NOTHING, 1, _) → NOTHING" {
    var interner = try Interner.init(testing.allocator);
    defer interner.deinit();

    const result = try interner.intern(.{ .loop = .{ .child = NOTHING, .min = 1, .max = 5 } });
    try testing.expectEqual(NOTHING, result);
}

test "rewrite: alt removes NOTHING" {
    var interner = try Interner.init(testing.allocator);
    defer interner.deinit();

    const ranges = try interner.allocRanges(&.{.{ .lo = 'a', .hi = 'a' }});
    const r = try interner.intern(.{ .predicate = .{ .ranges = ranges } });
    const children = try interner.allocChildren(&.{ r, NOTHING });
    const result = try interner.intern(.{ .alternation = .{ .children = children } });
    try testing.expectEqual(r, result);
}

test "rewrite: alt with ANYSTAR → ANYSTAR" {
    var interner = try Interner.init(testing.allocator);
    defer interner.deinit();

    const ranges = try interner.allocRanges(&.{.{ .lo = 'a', .hi = 'a' }});
    const r = try interner.intern(.{ .predicate = .{ .ranges = ranges } });
    const children = try interner.allocChildren(&.{ r, ANYSTAR });
    const result = try interner.intern(.{ .alternation = .{ .children = children } });
    try testing.expectEqual(ANYSTAR, result);
}

test "rewrite: empty alt → NOTHING" {
    var interner = try Interner.init(testing.allocator);
    defer interner.deinit();

    const children = try interner.allocChildren(&.{NOTHING});
    const result = try interner.intern(.{ .alternation = .{ .children = children } });
    try testing.expectEqual(NOTHING, result);
}

test "rewrite: single-child alt unwraps" {
    var interner = try Interner.init(testing.allocator);
    defer interner.deinit();

    const ranges = try interner.allocRanges(&.{.{ .lo = 'a', .hi = 'a' }});
    const r = try interner.intern(.{ .predicate = .{ .ranges = ranges } });
    const children = try interner.allocChildren(&.{r});
    const result = try interner.intern(.{ .alternation = .{ .children = children } });
    try testing.expectEqual(r, result);
}

test "alternation sorting and dedup" {
    var interner = try Interner.init(testing.allocator);
    defer interner.deinit();

    const ranges_a = try interner.allocRanges(&.{.{ .lo = 'a', .hi = 'a' }});
    const a = try interner.intern(.{ .predicate = .{ .ranges = ranges_a } });
    const ranges_b = try interner.allocRanges(&.{.{ .lo = 'b', .hi = 'b' }});
    const b = try interner.intern(.{ .predicate = .{ .ranges = ranges_b } });

    const children1 = try interner.allocChildren(&.{ b, a, a });
    const result1 = try interner.intern(.{ .alternation = .{ .children = children1 } });

    const children2 = try interner.allocChildren(&.{ a, b });
    const result2 = try interner.intern(.{ .alternation = .{ .children = children2 } });

    try testing.expectEqual(result1, result2);
}

test "lower: literal AST" {
    var interner = try Interner.init(testing.allocator);
    defer interner.deinit();
    const allocator = testing.allocator;

    const e = try Expr.create(allocator, .{ .literal = 'a' });
    defer {
        e.deinit(allocator);
        allocator.destroy(e);
    }

    const id = try interner.lower(e);
    switch (interner.get(id)) {
        .predicate => |pred| {
            try testing.expectEqual(@as(usize, 1), pred.ranges.len);
            try testing.expectEqual(@as(u8, 'a'), pred.ranges[0].lo);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "lower: plus desugars to concat+loop" {
    var interner = try Interner.init(testing.allocator);
    defer interner.deinit();
    const allocator = testing.allocator;

    const child = try Expr.create(allocator, .{ .literal = 'a' });
    const e = try Expr.create(allocator, .{ .plus = .{ .child = child } });
    defer {
        e.deinit(allocator);
        allocator.destroy(e);
    }

    const id = try interner.lower(e);
    switch (interner.get(id)) {
        .concat => |cat| {
            switch (interner.get(cat.left)) {
                .predicate => {},
                else => return error.TestUnexpectedResult,
            }
            switch (interner.get(cat.right)) {
                .loop => |lp| {
                    try testing.expectEqual(@as(u32, 0), lp.min);
                    try testing.expectEqual(Node.UNBOUNDED, lp.max);
                    try testing.expectEqual(cat.left, lp.child);
                },
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
}

test "lower: optional desugars to alternation" {
    var interner = try Interner.init(testing.allocator);
    defer interner.deinit();
    const allocator = testing.allocator;

    const child = try Expr.create(allocator, .{ .literal = 'a' });
    const e = try Expr.create(allocator, .{ .optional = .{ .child = child } });
    defer {
        e.deinit(allocator);
        allocator.destroy(e);
    }

    const id = try interner.lower(e);
    switch (interner.get(id)) {
        .alternation => |alt| {
            try testing.expectEqual(@as(usize, 2), alt.children.len);
            var has_epsilon = false;
            for (alt.children) |c| {
                if (c == EPSILON) has_epsilon = true;
            }
            try testing.expect(has_epsilon);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "lower: star desugars to loop(0, UNBOUNDED)" {
    var interner = try Interner.init(testing.allocator);
    defer interner.deinit();
    const allocator = testing.allocator;

    const child = try Expr.create(allocator, .{ .literal = 'a' });
    const e = try Expr.create(allocator, .{ .star = .{ .child = child } });
    defer {
        e.deinit(allocator);
        allocator.destroy(e);
    }

    const id = try interner.lower(e);
    switch (interner.get(id)) {
        .loop => |lp| {
            try testing.expectEqual(@as(u32, 0), lp.min);
            try testing.expectEqual(Node.UNBOUNDED, lp.max);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "chained simplifications" {
    var interner = try Interner.init(testing.allocator);
    defer interner.deinit();

    const ranges = try interner.allocRanges(&.{.{ .lo = 'x', .hi = 'x' }});
    const r = try interner.intern(.{ .predicate = .{ .ranges = ranges } });
    const inner = try interner.intern(.{ .concat = .{ .left = EPSILON, .right = r } });
    const outer = try interner.intern(.{ .concat = .{ .left = EPSILON, .right = inner } });
    try testing.expectEqual(r, outer);
}
