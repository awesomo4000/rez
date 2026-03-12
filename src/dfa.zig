/// Lazy DFA: transition table + MaxEnd matching.
/// Caches transitions (NodeId, minterm) → NodeId.
/// Provides the public match API.
const std = @import("std");
const Allocator = std.mem.Allocator;
const node_mod = @import("node.zig");
const Node = node_mod.Node;
const NodeId = node_mod.NodeId;
const NOTHING = node_mod.NOTHING;
const EPSILON = node_mod.EPSILON;
const interner_mod = @import("interner.zig");
const Interner = interner_mod.Interner;
const minterm_mod = @import("minterm.zig");
const MintermTable = minterm_mod.MintermTable;
const derivative_mod = @import("derivative.zig");
const nullability_mod = @import("nullability.zig");
const parser_mod = @import("parser.zig");

pub const Span = struct {
    start: usize,
    end: usize,
};

const TransitionKey = struct {
    state: NodeId,
    minterm: u8,
    at_start: bool,
    at_end: bool,
};

pub const DFA = struct {
    interner: Interner,
    table: MintermTable,
    root_id: NodeId,
    cache: std.AutoHashMapUnmanaged(TransitionKey, NodeId),
    allocator: Allocator,

    pub fn init(allocator: Allocator, interner: Interner, table: MintermTable, root_id: NodeId) DFA {
        return .{
            .interner = interner,
            .table = table,
            .root_id = root_id,
            .cache = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DFA) void {
        self.cache.deinit(self.allocator);
        self.interner.deinit();
    }

    /// Get the next state for (current_state, minterm, context), computing and caching if needed.
    fn transition(self: *DFA, state: NodeId, mt: u8, at_start: bool, at_end: bool) !NodeId {
        const key = TransitionKey{ .state = state, .minterm = mt, .at_start = at_start, .at_end = at_end };
        if (self.cache.get(key)) |cached| {
            return cached;
        }
        const next = try derivative_mod.derivative(&self.interner, state, mt, at_start, at_end);
        try self.cache.put(self.allocator, key, next);
        return next;
    }

    /// Forward scan: find the end of the longest match starting at `start`.
    /// Returns the exclusive end position, or null if no match.
    pub fn maxEnd(self: *DFA, input: []const u8, start: usize) !?usize {
        var state = self.root_id;

        // Check if the pattern is nullable at start position (empty match possible)
        const at_start = (start == 0);
        const at_end = (start == input.len);
        var best: ?usize = if (nullability_mod.isNullableAt(&self.interner, state, at_start, at_end)) start else null;

        var pos = start;
        while (pos < input.len) {
            const mt = self.table.getMintermForChar(input[pos]);
            const new_at_end = (pos + 1 == input.len);
            state = try self.transition(state, mt, at_start, new_at_end);

            if (state == NOTHING) break;

            pos += 1;

            if (nullability_mod.isNullableAt(&self.interner, state, at_start, pos == input.len)) {
                best = pos;
            }
        }

        return best;
    }
};

/// Full pipeline: parse → intern → minterms → DFA → scan all positions → leftmost-longest.
pub fn match(allocator: Allocator, pattern: []const u8, input: []const u8) !?Span {
    // Parse
    const expr = try parser_mod.parse(allocator, pattern);
    defer {
        expr.deinit(allocator);
        allocator.destroy(expr);
    }

    // Intern
    var interner = try Interner.init(allocator);
    errdefer interner.deinit();

    const root_id = try interner.lower(expr);

    // Compute minterms
    const table = try minterm_mod.computeMinterms(allocator, &interner, root_id);

    // Build DFA
    var dfa = DFA.init(allocator, interner, table, root_id);
    defer dfa.deinit();

    // Scan all start positions for leftmost-longest match
    var best_span: ?Span = null;

    var start: usize = 0;
    while (start <= input.len) {
        if (try dfa.maxEnd(input, start)) |end| {
            // Leftmost: first match we find at the earliest start
            // Longest: maxEnd already returns the longest match at this start
            if (best_span == null or start < best_span.?.start or
                (start == best_span.?.start and end > best_span.?.end))
            {
                best_span = Span{ .start = start, .end = end };
            }
            // Once we found a match at this start position, no need to check later starts
            // (leftmost wins)
            if (best_span != null and best_span.?.start == start) break;
        }
        start += 1;
    }

    return best_span;
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

fn expectMatch(pattern: []const u8, input: []const u8, expected_start: usize, expected_end: usize) !void {
    const result = try match(testing.allocator, pattern, input);
    if (result) |span| {
        try testing.expectEqual(expected_start, span.start);
        try testing.expectEqual(expected_end, span.end);
    } else {
        std.debug.print("Expected match [{d}, {d}) but got no match for pattern '{s}' on input '{s}'\n", .{ expected_start, expected_end, pattern, input });
        return error.TestUnexpectedResult;
    }
}

fn expectNoMatch(pattern: []const u8, input: []const u8) !void {
    const result = try match(testing.allocator, pattern, input);
    if (result) |span| {
        std.debug.print("Expected no match but got [{d}, {d}) for pattern '{s}' on input '{s}'\n", .{ span.start, span.end, pattern, input });
        return error.TestUnexpectedResult;
    }
}

// ── Spec §12.1 Phase 1 Test Vectors ─────────────────────────────────

test "abc in xabcy → [1, 4)" {
    try expectMatch("abc", "xabcy", 1, 4);
}

test "a|b in b → [0, 1)" {
    try expectMatch("a|b", "b", 0, 1);
}

test "[a-z]+ in Hello → [1, 5)" {
    try expectMatch("[a-z]+", "Hello", 1, 5);
}

test "a{3,5} in aaaaaa → [0, 5)" {
    try expectMatch("a{3,5}", "aaaaaa", 0, 5);
}

test "a* in empty → [0, 0)" {
    try expectMatch("a*", "", 0, 0);
}

test ".+ in line1\\nline2 → [0, 5)" {
    try expectMatch(".+", "line1\nline2", 0, 5);
}

test "_+ in line1\\nline2 → [0, 11)" {
    try expectMatch("_+", "line1\nline2", 0, 11);
}

test "a+ in aaa → [0, 3)" {
    try expectMatch("a+", "aaa", 0, 3);
}

test "a|ab in ab → [0, 2) (POSIX longest)" {
    try expectMatch("a|ab", "ab", 0, 2);
}

test "\\Aabc in abcdef → [0, 3)" {
    try expectMatch("\\Aabc", "abcdef", 0, 3);
}

test "\\Aabc in xabc → no match" {
    try expectNoMatch("\\Aabc", "xabc");
}

test "abc\\z in xyzabc → [3, 6)" {
    try expectMatch("abc\\z", "xyzabc", 3, 6);
}

// ── Additional tests ────────────────────────────────────────────────

test "empty pattern matches at start" {
    try expectMatch("", "hello", 0, 0);
}

test "no match at all" {
    try expectNoMatch("xyz", "abc");
}

test "match at end of string" {
    try expectMatch("c", "abc", 2, 3);
}

test "char class with quantifier" {
    try expectMatch("[0-9]+", "abc123def", 3, 6);
}

test "alternation with different lengths" {
    try expectMatch("cat|catch", "catch", 0, 5);
}

test "dot star" {
    try expectMatch("a.*b", "aXXXb", 0, 5);
}

test "escaped special chars" {
    try expectMatch("\\.", "a.b", 1, 2);
}

test "character class union" {
    try expectMatch("[a-zA-Z]+", "Hello123World", 0, 5);
}
