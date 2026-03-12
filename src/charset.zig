/// CharSet: sorted, non-overlapping byte ranges representing character sets.
/// All mutating operations take an Allocator.
const std = @import("std");
const unicode = @import("unicode.zig");
const Allocator = std.mem.Allocator;

pub const Range = struct {
    lo: u8,
    hi: u8, // inclusive

    pub fn contains(self: Range, c: u8) bool {
        return c >= self.lo and c <= self.hi;
    }

    pub fn eql(a: Range, b: Range) bool {
        return a.lo == b.lo and a.hi == b.hi;
    }
};

pub const CharSet = struct {
    ranges: []Range,
    allocator: Allocator,

    pub fn init(allocator: Allocator, ranges: []const Range) !CharSet {
        if (ranges.len == 0) {
            return CharSet{ .ranges = &.{}, .allocator = allocator };
        }

        // Copy and normalize
        var list: std.ArrayList(Range) = .empty;
        defer list.deinit(allocator);
        try list.appendSlice(allocator, ranges);

        std.mem.sort(Range, list.items, {}, struct {
            fn lessThan(_: void, a: Range, b: Range) bool {
                return a.lo < b.lo or (a.lo == b.lo and a.hi < b.hi);
            }
        }.lessThan);

        // Merge overlapping/adjacent ranges
        var merged: std.ArrayList(Range) = .empty;
        errdefer merged.deinit(allocator);

        var current = list.items[0];
        for (list.items[1..]) |r| {
            if (r.lo <= current.hi or (current.hi < 255 and r.lo == current.hi + 1)) {
                current.hi = @max(current.hi, r.hi);
            } else {
                try merged.append(allocator, current);
                current = r;
            }
        }
        try merged.append(allocator, current);

        return CharSet{
            .ranges = try merged.toOwnedSlice(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CharSet) void {
        if (self.ranges.len > 0) {
            self.allocator.free(self.ranges);
        }
        self.ranges = &.{};
    }

    pub fn contains(self: CharSet, c: u8) bool {
        for (self.ranges) |r| {
            if (c < r.lo) return false;
            if (r.contains(c)) return true;
        }
        return false;
    }

    pub fn isEmpty(self: CharSet) bool {
        return self.ranges.len == 0;
    }

    pub fn isFull(self: CharSet) bool {
        return self.ranges.len == 1 and self.ranges[0].lo == 0 and self.ranges[0].hi == 255;
    }

    pub fn eql(self: CharSet, other: CharSet) bool {
        if (self.ranges.len != other.ranges.len) return false;
        for (self.ranges, other.ranges) |a, b| {
            if (!a.eql(b)) return false;
        }
        return true;
    }

    /// Returns the complement of this set (all bytes NOT in the set).
    pub fn negate(self: CharSet, allocator: Allocator) !CharSet {
        var result: std.ArrayList(Range) = .empty;
        errdefer result.deinit(allocator);

        var next_lo: u16 = 0;
        for (self.ranges) |r| {
            if (next_lo < r.lo) {
                try result.append(allocator, .{ .lo = @intCast(next_lo), .hi = r.lo - 1 });
            }
            next_lo = @as(u16, r.hi) + 1;
        }
        if (next_lo <= 255) {
            try result.append(allocator, .{ .lo = @intCast(next_lo), .hi = 255 });
        }

        if (result.items.len == 0) {
            result.deinit(allocator);
            return CharSet{ .ranges = &.{}, .allocator = allocator };
        }
        return CharSet{
            .ranges = try result.toOwnedSlice(allocator),
            .allocator = allocator,
        };
    }

    /// Returns the union of two sets.
    pub fn unionWith(self: CharSet, other: CharSet, allocator: Allocator) !CharSet {
        var all: std.ArrayList(Range) = .empty;
        defer all.deinit(allocator);
        try all.appendSlice(allocator, self.ranges);
        try all.appendSlice(allocator, other.ranges);
        if (all.items.len == 0) {
            return CharSet{ .ranges = &.{}, .allocator = allocator };
        }
        return CharSet.init(allocator, all.items);
    }

    /// Returns the intersection of two sets.
    pub fn intersectWith(self: CharSet, other: CharSet, allocator: Allocator) !CharSet {
        var result: std.ArrayList(Range) = .empty;
        errdefer result.deinit(allocator);

        var i: usize = 0;
        var j: usize = 0;
        while (i < self.ranges.len and j < other.ranges.len) {
            const a = self.ranges[i];
            const b = other.ranges[j];
            const lo = @max(a.lo, b.lo);
            const hi = @min(a.hi, b.hi);
            if (lo <= hi) {
                try result.append(allocator, .{ .lo = lo, .hi = hi });
            }
            if (a.hi < b.hi) {
                i += 1;
            } else {
                j += 1;
            }
        }

        if (result.items.len == 0) {
            result.deinit(allocator);
            return CharSet{ .ranges = &.{}, .allocator = allocator };
        }
        return CharSet{
            .ranges = try result.toOwnedSlice(allocator),
            .allocator = allocator,
        };
    }

    /// Count total number of characters in the set.
    pub fn count(self: CharSet) usize {
        var total: usize = 0;
        for (self.ranges) |r| {
            total += @as(usize, r.hi) - @as(usize, r.lo) + 1;
        }
        return total;
    }

    // ── Predefined constructors ─────────────────────────────────────────

    /// [0-9]
    pub fn digit(allocator: Allocator) !CharSet {
        return CharSet.init(allocator, &.{.{ .lo = '0', .hi = '9' }});
    }

    /// [a-zA-Z0-9_]
    pub fn word(allocator: Allocator) !CharSet {
        return CharSet.init(allocator, &.{
            .{ .lo = '0', .hi = '9' },
            .{ .lo = 'A', .hi = 'Z' },
            .{ .lo = '_', .hi = '_' },
            .{ .lo = 'a', .hi = 'z' },
        });
    }

    /// [ \t\n\r\f\v]
    pub fn whitespace(allocator: Allocator) !CharSet {
        return CharSet.init(allocator, &.{
            .{ .lo = 0x09, .hi = 0x0D }, // \t \n \v \f \r
            .{ .lo = ' ', .hi = ' ' },
        });
    }

    /// Any byte except \n
    pub fn dot(allocator: Allocator) !CharSet {
        return CharSet.init(allocator, &.{
            .{ .lo = 0, .hi = '\n' - 1 },
            .{ .lo = '\n' + 1, .hi = 255 },
        });
    }

    /// Any byte [0-255]
    pub fn any(allocator: Allocator) !CharSet {
        return CharSet.init(allocator, &.{.{ .lo = 0, .hi = 255 }});
    }
};

// ── Tests ───────────────────────────────────────────────────────────────

test "empty set" {
    const allocator = std.testing.allocator;
    var cs = try CharSet.init(allocator, &.{});
    defer cs.deinit();
    try std.testing.expect(cs.isEmpty());
    try std.testing.expect(!cs.isFull());
    try std.testing.expect(!cs.contains(0));
    try std.testing.expect(!cs.contains('a'));
}

test "full set" {
    const allocator = std.testing.allocator;
    var cs = try CharSet.any(allocator);
    defer cs.deinit();
    try std.testing.expect(!cs.isEmpty());
    try std.testing.expect(cs.isFull());
    try std.testing.expect(cs.contains(0));
    try std.testing.expect(cs.contains(255));
    try std.testing.expectEqual(@as(usize, 256), cs.count());
}

test "merge overlapping ranges" {
    const allocator = std.testing.allocator;
    var cs = try CharSet.init(allocator, &.{
        .{ .lo = 'a', .hi = 'f' },
        .{ .lo = 'd', .hi = 'k' },
        .{ .lo = 'm', .hi = 'z' },
    });
    defer cs.deinit();
    try std.testing.expectEqual(@as(usize, 2), cs.ranges.len);
    try std.testing.expect(cs.ranges[0].eql(.{ .lo = 'a', .hi = 'k' }));
    try std.testing.expect(cs.ranges[1].eql(.{ .lo = 'm', .hi = 'z' }));
}

test "merge adjacent ranges" {
    const allocator = std.testing.allocator;
    var cs = try CharSet.init(allocator, &.{
        .{ .lo = 'a', .hi = 'c' },
        .{ .lo = 'd', .hi = 'f' },
    });
    defer cs.deinit();
    try std.testing.expectEqual(@as(usize, 1), cs.ranges.len);
    try std.testing.expect(cs.ranges[0].eql(.{ .lo = 'a', .hi = 'f' }));
}

test "negate full set gives empty" {
    const allocator = std.testing.allocator;
    var full = try CharSet.any(allocator);
    defer full.deinit();
    var neg = try full.negate(allocator);
    defer neg.deinit();
    try std.testing.expect(neg.isEmpty());
}

test "negate empty set gives full" {
    const allocator = std.testing.allocator;
    var empty = try CharSet.init(allocator, &.{});
    defer empty.deinit();
    var neg = try empty.negate(allocator);
    defer neg.deinit();
    try std.testing.expect(neg.isFull());
}

test "double negate roundtrip" {
    const allocator = std.testing.allocator;
    var orig = try CharSet.init(allocator, &.{
        .{ .lo = 'a', .hi = 'z' },
        .{ .lo = '0', .hi = '9' },
    });
    defer orig.deinit();

    var neg = try orig.negate(allocator);
    defer neg.deinit();

    var double_neg = try neg.negate(allocator);
    defer double_neg.deinit();

    try std.testing.expect(orig.eql(double_neg));
}

test "union of disjoint sets" {
    const allocator = std.testing.allocator;
    var a = try CharSet.init(allocator, &.{.{ .lo = 'a', .hi = 'c' }});
    defer a.deinit();
    var b = try CharSet.init(allocator, &.{.{ .lo = 'x', .hi = 'z' }});
    defer b.deinit();
    var u = try a.unionWith(b, allocator);
    defer u.deinit();
    try std.testing.expectEqual(@as(usize, 2), u.ranges.len);
    try std.testing.expect(u.contains('a'));
    try std.testing.expect(u.contains('z'));
    try std.testing.expect(!u.contains('m'));
}

test "intersection" {
    const allocator = std.testing.allocator;
    var a = try CharSet.init(allocator, &.{.{ .lo = 'a', .hi = 'm' }});
    defer a.deinit();
    var b = try CharSet.init(allocator, &.{.{ .lo = 'h', .hi = 'z' }});
    defer b.deinit();
    var inter = try a.intersectWith(b, allocator);
    defer inter.deinit();
    try std.testing.expectEqual(@as(usize, 1), inter.ranges.len);
    try std.testing.expect(inter.ranges[0].eql(.{ .lo = 'h', .hi = 'm' }));
}

test "intersection of disjoint sets is empty" {
    const allocator = std.testing.allocator;
    var a = try CharSet.init(allocator, &.{.{ .lo = 'a', .hi = 'c' }});
    defer a.deinit();
    var b = try CharSet.init(allocator, &.{.{ .lo = 'x', .hi = 'z' }});
    defer b.deinit();
    var inter = try a.intersectWith(b, allocator);
    defer inter.deinit();
    try std.testing.expect(inter.isEmpty());
}

test "digit set cross-check with unicode.zig" {
    const allocator = std.testing.allocator;
    var cs = try CharSet.digit(allocator);
    defer cs.deinit();
    for (0..256) |i| {
        const c: u8 = @intCast(i);
        try std.testing.expectEqual(unicode.isDigit(c), cs.contains(c));
    }
}

test "word set cross-check with unicode.zig" {
    const allocator = std.testing.allocator;
    var cs = try CharSet.word(allocator);
    defer cs.deinit();
    for (0..256) |i| {
        const c: u8 = @intCast(i);
        try std.testing.expectEqual(unicode.isWord(c), cs.contains(c));
    }
}

test "whitespace set cross-check with unicode.zig" {
    const allocator = std.testing.allocator;
    var cs = try CharSet.whitespace(allocator);
    defer cs.deinit();
    for (0..256) |i| {
        const c: u8 = @intCast(i);
        try std.testing.expectEqual(unicode.isWhitespace(c), cs.contains(c));
    }
}

test "dot set cross-check with unicode.zig" {
    const allocator = std.testing.allocator;
    var cs = try CharSet.dot(allocator);
    defer cs.deinit();
    for (0..256) |i| {
        const c: u8 = @intCast(i);
        try std.testing.expectEqual(unicode.isDot(c), cs.contains(c));
    }
}

test "any set cross-check with unicode.zig" {
    const allocator = std.testing.allocator;
    var cs = try CharSet.any(allocator);
    defer cs.deinit();
    for (0..256) |i| {
        const c: u8 = @intCast(i);
        try std.testing.expectEqual(unicode.isAny(c), cs.contains(c));
    }
}

test "contains on sorted ranges - early exit" {
    const allocator = std.testing.allocator;
    var cs = try CharSet.init(allocator, &.{
        .{ .lo = 'a', .hi = 'c' },
        .{ .lo = 'x', .hi = 'z' },
    });
    defer cs.deinit();
    try std.testing.expect(!cs.contains('d'));
    try std.testing.expect(!cs.contains('w'));
    try std.testing.expect(cs.contains('a'));
    try std.testing.expect(cs.contains('x'));
}

test "eql - same sets are equal" {
    const allocator = std.testing.allocator;
    var a = try CharSet.digit(allocator);
    defer a.deinit();
    var b = try CharSet.digit(allocator);
    defer b.deinit();
    try std.testing.expect(a.eql(b));
}

test "eql - different sets are not equal" {
    const allocator = std.testing.allocator;
    var a = try CharSet.digit(allocator);
    defer a.deinit();
    var b = try CharSet.word(allocator);
    defer b.deinit();
    try std.testing.expect(!a.eql(b));
}
