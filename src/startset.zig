/// Startset computation and accelerated scanning.
///
/// Computes the set of bytes that can appear as the first consumed character
/// of a match from the root node. When the set is small, we use SIMD-accelerated
/// scanning (via std.mem.indexOfScalar) to skip positions that can't start a match.
///
/// Strategy (the "80% solution"):
///   - Single-byte startset → std.mem.indexOfScalar (Zig stdlib, already SIMD)
///   - Multi-byte startset (≤128 bytes) → [256]bool bitmap + scalar scan
///   - Full set or nullable root → no skip (every position is a candidate)
const std = @import("std");
const node_mod = @import("node.zig");
const Node = node_mod.Node;
const NodeId = node_mod.NodeId;
const NOTHING = node_mod.NOTHING;
const EPSILON = node_mod.EPSILON;
const nullability_mod = @import("nullability.zig");
const interner_mod = @import("interner.zig");
const Interner = interner_mod.Interner;

/// The result of startset analysis.
pub const StartSet = union(enum) {
    /// Root is nullable or pattern accepts everything — no skipping possible.
    none,
    /// Exactly one byte can start a match — use indexOfScalar (SIMD).
    single: u8,
    /// Multiple bytes can start a match — use bitmap scan.
    bitmap: [256]bool,
};

/// Compute the startset for the given root expression.
/// `at_start` controls whether anchors fire (typically false for general scanning).
pub fn computeStartSet(interner: *const Interner, root_id: NodeId) StartSet {
    // If root is nullable (can match empty string), every position is a candidate.
    // Use context-free nullability (at_start=false, at_end=false) for the general case.
    if (nullability_mod.isNullable(interner, root_id)) {
        return .none;
    }

    var bitmap: [256]bool = [_]bool{false} ** 256;
    if (!collectFirstBytes(interner, root_id, &bitmap)) {
        // Gave up (e.g., too complex or full set)
        return .none;
    }

    // Count how many bytes are in the set
    var count: usize = 0;
    var single_byte: u8 = 0;
    for (0..256) |i| {
        if (bitmap[i]) {
            count += 1;
            single_byte = @intCast(i);
        }
    }

    if (count == 0) {
        // Nothing can start a match — pattern is unmatchable (NOTHING).
        // Still return none to avoid breaking anything.
        return .none;
    }

    if (count == 1) {
        return .{ .single = single_byte };
    }

    // If the set covers > 200 of 256 bytes, bitmap scanning is barely faster
    // than just running the DFA at every position.
    if (count > 200) {
        return .none;
    }

    return .{ .bitmap = bitmap };
}

/// Check if a node is "transparent" for startset purposes — i.e., it consumes
/// no input bytes, so the startset should look through it to the next node.
fn isTransparent(interner: *const Interner, id: NodeId) bool {
    const n = interner.get(id);
    return switch (n) {
        .epsilon => true,
        .anchor_start, .anchor_end => true,
        .nothing => false,
        .predicate => false,
        .concat => |cat| {
            return isTransparent(interner, cat.left) and isTransparent(interner, cat.right);
        },
        .alternation => |alt| {
            for (alt.children) |child| {
                if (isTransparent(interner, child)) return true;
            }
            return false;
        },
        .loop => |lp| {
            if (lp.min == 0) return true;
            return isTransparent(interner, lp.child);
        },
    };
}

/// Recursively collect the set of bytes that could be the first consumed character.
/// Returns false if analysis gives up (too complex or full charset).
fn collectFirstBytes(interner: *const Interner, id: NodeId, bitmap: *[256]bool) bool {
    const n = interner.get(id);
    switch (n) {
        .nothing => {
            // Matches nothing — contributes no bytes.
            return true;
        },
        .epsilon => {
            // Matches empty string — no first byte consumed.
            // But this means the containing expression might look past this.
            // The caller (concat) handles this correctly.
            return true;
        },
        .anchor_start, .anchor_end => {
            // Anchors consume no input bytes.
            return true;
        },
        .predicate => |pred| {
            // A predicate directly consumes a byte from its ranges.
            for (pred.ranges) |r| {
                var c: u16 = r.lo;
                while (c <= r.hi) : (c += 1) {
                    bitmap[@intCast(c)] = true;
                }
            }
            return true;
        },
        .concat => |cat| {
            // For concat(L, R): the first byte comes from L,
            // unless L is transparent (consumes no bytes), in which case
            // it can also come from R.
            if (!collectFirstBytes(interner, cat.left, bitmap)) return false;
            if (isTransparent(interner, cat.left)) {
                if (!collectFirstBytes(interner, cat.right, bitmap)) return false;
            }
            return true;
        },
        .alternation => |alt| {
            // Union of first bytes from all children.
            for (alt.children) |child| {
                if (!collectFirstBytes(interner, child, bitmap)) return false;
            }
            return true;
        },
        .loop => |lp| {
            // First byte of loop is the first byte of its child.
            return collectFirstBytes(interner, lp.child, bitmap);
        },
    }
}

/// Find the next position at or after `pos` where a match could start.
/// Returns null if no candidate position exists.
pub inline fn findNextCandidate(startset: *const StartSet, input: []const u8, pos: usize) ?usize {
    switch (startset.*) {
        .none => return pos,
        .single => |byte| {
            // std.mem.indexOfScalar is SIMD-optimized in Zig stdlib.
            if (pos >= input.len) return null;
            const result = std.mem.indexOfScalar(u8, input[pos..], byte);
            if (result) |offset| {
                return pos + offset;
            }
            return null;
        },
        .bitmap => |bitmap| {
            var i = pos;
            while (i < input.len) : (i += 1) {
                if (bitmap[input[i]]) return i;
            }
            return null;
        },
    }
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;
const parser_mod = @import("parser.zig");
const minterm_mod = @import("minterm.zig");

fn setupStartSet(pattern: []const u8) !struct { interner: Interner, root_id: NodeId } {
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

test "literal abc → single byte 'a'" {
    var s = try setupStartSet("abc");
    defer s.interner.deinit();

    const ss = computeStartSet(&s.interner, s.root_id);
    switch (ss) {
        .single => |byte| try testing.expectEqual(@as(u8, 'a'), byte),
        else => return error.TestUnexpectedResult,
    }
}

test "alternation cat|dog → bitmap with c,d" {
    var s = try setupStartSet("cat|dog");
    defer s.interner.deinit();

    const ss = computeStartSet(&s.interner, s.root_id);
    switch (ss) {
        .bitmap => |bitmap| {
            try testing.expect(bitmap['c']);
            try testing.expect(bitmap['d']);
            try testing.expect(!bitmap['a']);
            try testing.expect(!bitmap['x']);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "star pattern a* → none (nullable)" {
    var s = try setupStartSet("a*");
    defer s.interner.deinit();

    const ss = computeStartSet(&s.interner, s.root_id);
    switch (ss) {
        .none => {},
        else => return error.TestUnexpectedResult,
    }
}

test "plus pattern a+ → single byte 'a'" {
    var s = try setupStartSet("a+");
    defer s.interner.deinit();

    const ss = computeStartSet(&s.interner, s.root_id);
    switch (ss) {
        .single => |byte| try testing.expectEqual(@as(u8, 'a'), byte),
        else => return error.TestUnexpectedResult,
    }
}

test "char class [0-9]+ → bitmap with digits" {
    var s = try setupStartSet("[0-9]+");
    defer s.interner.deinit();

    const ss = computeStartSet(&s.interner, s.root_id);
    switch (ss) {
        .bitmap => |bitmap| {
            for ('0'..'9' + 1) |c| {
                try testing.expect(bitmap[c]);
            }
            try testing.expect(!bitmap['a']);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "empty pattern → none (nullable)" {
    var interner = try Interner.init(testing.allocator);
    defer interner.deinit();

    const ss = computeStartSet(&interner, EPSILON);
    switch (ss) {
        .none => {},
        else => return error.TestUnexpectedResult,
    }
}

test "alternation Sherlock|Watson → bitmap with S,W" {
    var s = try setupStartSet("Sherlock|Watson");
    defer s.interner.deinit();

    const ss = computeStartSet(&s.interner, s.root_id);
    switch (ss) {
        .bitmap => |bitmap| {
            try testing.expect(bitmap['S']);
            try testing.expect(bitmap['W']);
            try testing.expect(!bitmap['a']);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "findNextCandidate single byte" {
    const ss = StartSet{ .single = 'x' };
    const input = "abcxdef";

    try testing.expectEqual(@as(?usize, 3), findNextCandidate(&ss, input, 0));
    try testing.expectEqual(@as(?usize, 3), findNextCandidate(&ss, input, 3));
    try testing.expectEqual(@as(?usize, null), findNextCandidate(&ss, input, 4));
}

test "findNextCandidate bitmap" {
    var bitmap: [256]bool = [_]bool{false} ** 256;
    bitmap['a'] = true;
    bitmap['z'] = true;
    const ss = StartSet{ .bitmap = bitmap };
    const input = "xxaxzxx";

    try testing.expectEqual(@as(?usize, 2), findNextCandidate(&ss, input, 0));
    try testing.expectEqual(@as(?usize, 2), findNextCandidate(&ss, input, 2));
    try testing.expectEqual(@as(?usize, 4), findNextCandidate(&ss, input, 3));
}

test "findNextCandidate none always returns pos" {
    const ss = StartSet{ .none = {} };
    const input = "anything";

    try testing.expectEqual(@as(?usize, 0), findNextCandidate(&ss, input, 0));
    try testing.expectEqual(@as(?usize, 5), findNextCandidate(&ss, input, 5));
}

test "anchor pattern \\Aabc → single byte 'a'" {
    var s = try setupStartSet("\\Aabc");
    defer s.interner.deinit();

    const ss = computeStartSet(&s.interner, s.root_id);
    // Anchor is zero-width, so first byte is from 'a'
    switch (ss) {
        .single => |byte| try testing.expectEqual(@as(u8, 'a'), byte),
        else => return error.TestUnexpectedResult,
    }
}

test "optional prefix a?bc → bitmap with a,b" {
    var s = try setupStartSet("a?bc");
    defer s.interner.deinit();

    const ss = computeStartSet(&s.interner, s.root_id);
    switch (ss) {
        .bitmap => |bitmap| {
            try testing.expect(bitmap['a']);
            try testing.expect(bitmap['b']);
            try testing.expect(!bitmap['c']);
        },
        else => return error.TestUnexpectedResult,
    }
}
