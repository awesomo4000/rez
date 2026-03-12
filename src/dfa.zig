/// Lazy DFA: transition table + MaxEnd matching.
/// Uses flat delta tables for O(1) transition lookup and cached nullability.
/// Provides the public match API.
const std = @import("std");
const Allocator = std.mem.Allocator;
const node_mod = @import("node.zig");
const NodeId = node_mod.NodeId;
const NOTHING = node_mod.NOTHING;
const interner_mod = @import("interner.zig");
const Interner = interner_mod.Interner;
const minterm_mod = @import("minterm.zig");
const MintermTable = minterm_mod.MintermTable;
const derivative_mod = @import("derivative.zig");
const nullability_mod = @import("nullability.zig");
const parser_mod = @import("parser.zig");
const startset_mod = @import("startset.zig");
const StartSet = startset_mod.StartSet;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

// ── Constants ───────────────────────────────────────────────────────────

const UNMAPPED: u16 = std.math.maxInt(u16);
const SENTINEL: NodeId = std.math.maxInt(NodeId);
const UNKNOWN_NULLABLE: u8 = 0;
const NOT_NULLABLE: u8 = 1;
const IS_NULLABLE: u8 = 2;

// ── Profiling infrastructure ────────────────────────────────────────────

const Timer = struct {
    start: std.time.Instant,

    fn begin() Timer {
        return .{ .start = std.time.Instant.now() catch unreachable };
    }

    fn elapsed_ns(self: Timer) u64 {
        const now = std.time.Instant.now() catch unreachable;
        return now.since(self.start);
    }
};

pub const ProfileCounters = struct {
    transition_calls: u64 = 0,
    cache_hits: u64 = 0,
    cache_misses: u64 = 0,
    transition_ns: u64 = 0,
    derivative_ns: u64 = 0,
    nullability_calls: u64 = 0,
    nullability_ns: u64 = 0,

    pub fn reset(self: *ProfileCounters) void {
        self.* = .{};
    }
};

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
    allocator: Allocator,
    profile: ProfileCounters = .{},

    // ── Flat delta table (replaces HashMap cache) ───────────────────
    state_map: ArrayListUnmanaged(u16), // NodeId → compact index
    state_count: u16, // next index to assign
    delta: [2]ArrayListUnmanaged(NodeId), // flat transition tables [at_start], at_end=false
    stride: u16, // = num_minterms

    // ── at_end=true fallback (rare, ~1 per maxEnd call) ─────────────
    end_cache: std.AutoHashMapUnmanaged(TransitionKey, NodeId),

    // ── Nullable cache (replaces recursive tree walk) ───────────────
    nullable: [2]ArrayListUnmanaged(u8), // [at_start], at_end=false
    end_nullable: [2]ArrayListUnmanaged(u8), // [at_start], at_end=true

    pub fn init(allocator: Allocator, interner: Interner, table: MintermTable, root_id: NodeId) DFA {
        return .{
            .interner = interner,
            .table = table,
            .root_id = root_id,
            .allocator = allocator,
            .profile = .{},
            .state_map = .empty,
            .state_count = 0,
            .delta = .{ .empty, .empty },
            .stride = table.num_minterms,
            .end_cache = .empty,
            .nullable = .{ .empty, .empty },
            .end_nullable = .{ .empty, .empty },
        };
    }

    pub fn deinit(self: *DFA) void {
        self.state_map.deinit(self.allocator);
        for (0..2) |i| {
            self.delta[i].deinit(self.allocator);
            self.nullable[i].deinit(self.allocator);
            self.end_nullable[i].deinit(self.allocator);
        }
        self.end_cache.deinit(self.allocator);
        self.interner.deinit();
    }

    /// Map a NodeId to a compact sequential index, growing tables as needed.
    fn ensureState(self: *DFA, node_id: NodeId) !u16 {
        const id: usize = @intCast(node_id);

        // Grow state_map to cover this NodeId if needed
        if (id >= self.state_map.items.len) {
            const old_len = self.state_map.items.len;
            const new_len = id + 1;
            try self.state_map.resize(self.allocator, new_len);
            @memset(self.state_map.items[old_len..new_len], UNMAPPED);
        }

        // If already mapped, return existing index
        const existing = self.state_map.items[id];
        if (existing != UNMAPPED) return existing;

        // Assign new compact index
        const idx = self.state_count;
        self.state_count += 1;
        self.state_map.items[id] = idx;

        // Grow delta tables by one row (stride entries filled with SENTINEL)
        const stride: usize = @intCast(self.stride);
        for (0..2) |ctx| {
            const old_delta_len = self.delta[ctx].items.len;
            try self.delta[ctx].resize(self.allocator, old_delta_len + stride);
            @memset(self.delta[ctx].items[old_delta_len..], SENTINEL);
        }

        // Grow nullable arrays by 1 entry (filled with UNKNOWN)
        for (0..2) |ctx| {
            try self.nullable[ctx].append(self.allocator, UNKNOWN_NULLABLE);
            try self.end_nullable[ctx].append(self.allocator, UNKNOWN_NULLABLE);
        }

        return idx;
    }

    /// Cached nullability check. First call computes recursively and caches;
    /// subsequent calls return the cached result.
    fn cachedNullable(self: *DFA, state: NodeId, at_start: bool, at_end: bool) !bool {
        self.profile.nullability_calls += 1;

        const state_idx = try self.ensureState(state);
        const ctx: usize = if (at_start) 1 else 0;

        const arr = if (at_end) &self.end_nullable[ctx] else &self.nullable[ctx];
        const cached = arr.items[@intCast(state_idx)];

        if (cached != UNKNOWN_NULLABLE) {
            return cached == IS_NULLABLE;
        }

        // Cache miss: compute recursively (only time the rare miss)
        const n_start = Timer.begin();
        const result = nullability_mod.isNullableAt(&self.interner, state, at_start, at_end);
        self.profile.nullability_ns += n_start.elapsed_ns();

        arr.items[@intCast(state_idx)] = if (result) IS_NULLABLE else NOT_NULLABLE;
        return result;
    }

    /// Get the next state for (current_state, minterm, context), computing and caching if needed.
    fn transition(self: *DFA, state: NodeId, mt: u8, at_start: bool, at_end: bool) !NodeId {
        self.profile.transition_calls += 1;

        // ── Slow path: at_end=true (rare, ~1 per maxEnd call) ───────
        if (at_end) {
            const key = TransitionKey{ .state = state, .minterm = mt, .at_start = at_start, .at_end = true };
            if (self.end_cache.get(key)) |cached| {
                self.profile.cache_hits += 1;
                return cached;
            }
            self.profile.cache_misses += 1;
            const d_start = Timer.begin();
            const next = try derivative_mod.derivative(&self.interner, state, mt, at_start, true);
            self.profile.derivative_ns += d_start.elapsed_ns();
            try self.end_cache.put(self.allocator, key, next);
            if (next != NOTHING) {
                _ = try self.ensureState(next);
            }
            return next;
        }

        // ── Fast path: at_end=false (99%+ of calls) ────────────────
        const state_idx = try self.ensureState(state);
        const ctx: usize = if (at_start) 1 else 0;
        const stride: usize = @intCast(self.stride);
        const offset: usize = @as(usize, state_idx) * stride + @as(usize, mt);

        const cached = self.delta[ctx].items[offset];
        if (cached != SENTINEL) {
            self.profile.cache_hits += 1;
            return cached;
        }

        // Cache miss: compute derivative and store (only time the rare miss)
        self.profile.cache_misses += 1;
        const d_start = Timer.begin();
        const next = try derivative_mod.derivative(&self.interner, state, mt, at_start, false);
        const miss_ns = d_start.elapsed_ns();
        self.profile.derivative_ns += miss_ns;
        self.profile.transition_ns += miss_ns;

        // Ensure the result state is mapped (so future lookups work)
        if (next != NOTHING) {
            _ = try self.ensureState(next);
        }

        self.delta[ctx].items[offset] = next;
        return next;
    }

    /// Forward scan: find the end of the longest match starting at `start`.
    /// Returns the exclusive end position, or null if no match.
    pub fn maxEnd(self: *DFA, input: []const u8, start: usize) !?usize {
        var state = self.root_id;

        // Check if the pattern is nullable at start position (empty match possible)
        const at_start = (start == 0);
        const at_end = (start == input.len);

        const initially_nullable = try self.cachedNullable(state, at_start, at_end);
        var best: ?usize = if (initially_nullable) start else null;

        var pos = start;
        while (pos < input.len) {
            const mt = self.table.getMintermForChar(input[pos]);
            const new_at_end = (pos + 1 == input.len);
            state = try self.transition(state, mt, at_start, new_at_end);

            if (state == NOTHING) break;

            pos += 1;

            const nullable = try self.cachedNullable(state, at_start, pos == input.len);
            if (nullable) {
                best = pos;
            }
        }

        return best;
    }
};

/// Compiled regex that can be reused across multiple inputs.
pub const Regex = struct {
    dfa_state: DFA,
    allocator: Allocator,
    startset: StartSet,

    /// Compile a regex pattern into a reusable Regex object.
    pub fn compile(allocator: Allocator, pattern: []const u8) !Regex {
        const expr = try parser_mod.parse(allocator, pattern);
        defer {
            expr.deinit(allocator);
            allocator.destroy(expr);
        }

        var interner = try Interner.init(allocator);
        errdefer interner.deinit();

        const root_id = try interner.lower(expr);
        const startset = startset_mod.computeStartSet(&interner, root_id);
        const table = try minterm_mod.computeMinterms(allocator, &interner, root_id);

        return .{
            .dfa_state = DFA.init(allocator, interner, table, root_id),
            .allocator = allocator,
            .startset = startset,
        };
    }

    pub fn deinit(self: *Regex) void {
        self.dfa_state.deinit();
    }

    /// Find the first (leftmost-longest) match.
    pub fn find(self: *Regex, input: []const u8) !?Span {
        var start: usize = 0;
        while (start <= input.len) {
            // Use startset to skip to next candidate position
            if (startset_mod.findNextCandidate(&self.startset, input, start)) |candidate| {
                start = candidate;
            } else {
                break;
            }
            if (try self.dfa_state.maxEnd(input, start)) |end| {
                return Span{ .start = start, .end = end };
            }
            start += 1;
        }
        return null;
    }

    /// Find all non-overlapping leftmost-longest matches.
    pub fn findAll(self: *Regex, allocator: Allocator, input: []const u8) ![]Span {
        var matches: std.ArrayList(Span) = .empty;
        errdefer matches.deinit(allocator);

        var start: usize = 0;
        while (start <= input.len) {
            // Use startset to skip to next candidate position
            const candidate = startset_mod.findNextCandidate(&self.startset, input, start) orelse break;
            start = candidate;

            if (try self.dfa_state.maxEnd(input, start)) |end| {
                try matches.append(allocator, Span{ .start = start, .end = end });
                // Advance past the match; for empty matches, advance by 1
                if (end == start) {
                    start += 1;
                } else {
                    start = end;
                }
            } else {
                start += 1;
            }
        }

        return matches.toOwnedSlice(allocator);
    }

    /// Count the number of non-overlapping matches (like resharp's Count API).
    pub fn count(self: *Regex, input: []const u8) !usize {
        var n: usize = 0;
        var start: usize = 0;
        while (start <= input.len) {
            // Use startset to skip to next candidate position
            const candidate = startset_mod.findNextCandidate(&self.startset, input, start) orelse break;
            start = candidate;

            if (try self.dfa_state.maxEnd(input, start)) |end| {
                n += 1;
                if (end == start) {
                    start += 1;
                } else {
                    start = end;
                }
            } else {
                start += 1;
            }
        }
        return n;
    }
};

/// Full pipeline: parse → intern → minterms → DFA → scan all positions → leftmost-longest.
pub fn match(allocator: Allocator, pattern: []const u8, input: []const u8) !?Span {
    var regex = try Regex.compile(allocator, pattern);
    defer regex.deinit();
    return regex.find(input);
}

/// Find all non-overlapping leftmost-longest matches.
pub fn findAll(allocator: Allocator, pattern: []const u8, input: []const u8) ![]Span {
    var regex = try Regex.compile(allocator, pattern);
    defer regex.deinit();
    return regex.findAll(allocator, input);
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
