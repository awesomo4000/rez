/// Minterm partition computation.
/// Walks the expression tree from a root, collects predicates, partitions the
/// character space into equivalence classes (minterms), and updates predicate
/// nodes with bitvectors.
const std = @import("std");
const Allocator = std.mem.Allocator;
const node_mod = @import("node.zig");
const Node = node_mod.Node;
const NodeId = node_mod.NodeId;
const NOTHING = node_mod.NOTHING;
const EPSILON = node_mod.EPSILON;
const interner_mod = @import("interner.zig");
const Interner = interner_mod.Interner;

pub const MintermTable = struct {
    /// Maps each byte value to its minterm index.
    char_to_minterm: [256]u8,
    /// Total number of minterms.
    num_minterms: u8,

    /// Check which minterm a character belongs to.
    pub fn getMintermForChar(self: *const MintermTable, c: u8) u8 {
        return self.char_to_minterm[c];
    }
};

/// Recursively collect predicate node IDs reachable from the given root.
fn collectPredicates(
    interner: *const Interner,
    id: NodeId,
    pred_ids: *std.ArrayList(NodeId),
    visited: *std.AutoHashMapUnmanaged(NodeId, void),
    allocator: Allocator,
) !void {
    if (visited.get(id) != null) return;
    try visited.put(allocator, id, {});

    const n = interner.get(id);
    switch (n) {
        .nothing, .epsilon, .anchor_start, .anchor_end => {},
        .predicate => {
            try pred_ids.append(allocator, id);
        },
        .concat => |cat| {
            try collectPredicates(interner, cat.left, pred_ids, visited, allocator);
            try collectPredicates(interner, cat.right, pred_ids, visited, allocator);
        },
        .alternation => |alt| {
            for (alt.children) |child| {
                try collectPredicates(interner, child, pred_ids, visited, allocator);
            }
        },
        .loop => |lp| {
            try collectPredicates(interner, lp.child, pred_ids, visited, allocator);
        },
    }
}

/// Compute the minterm partition for the given interner and root expression.
/// After calling this, predicate nodes reachable from root_id will have their
/// bitvec fields updated to reflect minterm membership.
pub fn computeMinterms(allocator: Allocator, interner: *Interner, root_id: NodeId) !MintermTable {
    // Step 1: Collect predicates reachable from the root expression
    var pred_node_ids: std.ArrayList(NodeId) = .empty;
    defer pred_node_ids.deinit(allocator);

    var visited: std.AutoHashMapUnmanaged(NodeId, void) = .empty;
    defer visited.deinit(allocator);

    try collectPredicates(interner, root_id, &pred_node_ids, &visited, allocator);

    if (pred_node_ids.items.len == 0) {
        return MintermTable{
            .char_to_minterm = [_]u8{0} ** 256,
            .num_minterms = 1,
        };
    }

    // Step 2: Build membership arrays for each predicate
    var predicates: std.ArrayList([256]bool) = .empty;
    defer predicates.deinit(allocator);

    for (pred_node_ids.items) |node_id| {
        const pred = interner.get(node_id).predicate;
        var membership: [256]bool = [_]bool{false} ** 256;
        for (pred.ranges) |r| {
            var c: u16 = r.lo;
            while (c <= r.hi) : (c += 1) {
                membership[@intCast(c)] = true;
            }
        }
        try predicates.append(allocator, membership);
    }

    // Step 3: Compute equivalence classes via signatures.
    var signatures: [256]u64 = [_]u64{0} ** 256;
    for (predicates.items, 0..) |membership, pred_idx| {
        if (pred_idx >= 64) break;
        const bit: u64 = @as(u64, 1) << @intCast(pred_idx);
        for (0..256) |c| {
            if (membership[c]) {
                signatures[c] |= bit;
            }
        }
    }

    // Step 4: Map unique signatures to minterm indices.
    var sig_to_minterm: std.AutoHashMapUnmanaged(u64, u8) = .empty;
    defer sig_to_minterm.deinit(allocator);

    var char_to_minterm: [256]u8 = undefined;
    var next_minterm: u8 = 0;

    for (0..256) |c| {
        const sig = signatures[c];
        if (sig_to_minterm.get(sig)) |mt| {
            char_to_minterm[c] = mt;
        } else {
            char_to_minterm[c] = next_minterm;
            try sig_to_minterm.put(allocator, sig, next_minterm);
            next_minterm += 1;
        }
    }

    // Step 5: Compute bitvectors for each predicate node.
    for (pred_node_ids.items, 0..) |node_id, pred_idx| {
        var bitvec: u64 = 0;
        const membership = predicates.items[pred_idx];
        for (0..256) |c| {
            if (membership[c]) {
                const mt = char_to_minterm[c];
                bitvec |= @as(u64, 1) << @intCast(mt);
            }
        }
        interner.nodes.items[node_id] = .{ .predicate = .{
            .bitvec = bitvec,
            .ranges = interner.nodes.items[node_id].predicate.ranges,
        } };
    }

    return MintermTable{
        .char_to_minterm = char_to_minterm,
        .num_minterms = next_minterm,
    };
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;
const parser_mod = @import("parser.zig");

fn setupMinterms(pattern: []const u8) !struct { interner: Interner, root_id: NodeId } {
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

test "single char class [a-z] → 2 minterms" {
    var s = try setupMinterms("[a-z]");
    defer s.interner.deinit();

    const table = try computeMinterms(testing.allocator, &s.interner, s.root_id);
    try testing.expectEqual(@as(u8, 2), table.num_minterms);

    const az_mt = table.char_to_minterm['a'];
    for ('a'..'z' + 1) |c| {
        try testing.expectEqual(az_mt, table.char_to_minterm[c]);
    }
    try testing.expect(table.char_to_minterm['0'] != az_mt);
}

test "[a-z] + [0-9] → 3 minterms" {
    var s = try setupMinterms("[a-z][0-9]");
    defer s.interner.deinit();

    const table = try computeMinterms(testing.allocator, &s.interner, s.root_id);
    try testing.expectEqual(@as(u8, 3), table.num_minterms);
}

test "[a-z] + \\w → 3 minterms" {
    var s = try setupMinterms("[a-z]\\w");
    defer s.interner.deinit();

    const table = try computeMinterms(testing.allocator, &s.interner, s.root_id);
    try testing.expectEqual(@as(u8, 3), table.num_minterms);
}

test ". + _ → 2 minterms" {
    var s = try setupMinterms("._");
    defer s.interner.deinit();

    const table = try computeMinterms(testing.allocator, &s.interner, s.root_id);
    try testing.expectEqual(@as(u8, 2), table.num_minterms);
}

test "every byte maps to exactly one minterm" {
    var s = try setupMinterms("[a-z]+[0-9]*");
    defer s.interner.deinit();

    const table = try computeMinterms(testing.allocator, &s.interner, s.root_id);

    for (0..256) |c| {
        try testing.expect(table.char_to_minterm[c] < table.num_minterms);
    }
}

test "bitvector round-trip" {
    var s = try setupMinterms("[a-z]");
    defer s.interner.deinit();

    const table = try computeMinterms(testing.allocator, &s.interner, s.root_id);

    const pred_node = s.interner.get(s.root_id);
    switch (pred_node) {
        .predicate => |pred| {
            for (0..256) |c| {
                const char_byte: u8 = @intCast(c);
                const mt = table.char_to_minterm[char_byte];
                const bit_set = (pred.bitvec & (@as(u64, 1) << @intCast(mt))) != 0;
                var in_ranges = false;
                for (pred.ranges) |r| {
                    if (char_byte >= r.lo and char_byte <= r.hi) {
                        in_ranges = true;
                        break;
                    }
                }
                try testing.expectEqual(in_ranges, bit_set);
            }
        },
        else => return error.TestUnexpectedResult,
    }
}

test "no predicates → 1 minterm" {
    var interner = try Interner.init(testing.allocator);
    defer interner.deinit();

    // No user expression → just epsilon
    const table = try computeMinterms(testing.allocator, &interner, EPSILON);
    try testing.expectEqual(@as(u8, 1), table.num_minterms);
}
