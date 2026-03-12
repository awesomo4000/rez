/// Recursive descent regex parser: pattern string → raw AST.
/// Supports ERE syntax: literals, char classes, alternation, grouping,
/// quantifiers, escapes, and anchors.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const Expr = ast.Expr;
const charset = @import("charset.zig");
const CharSet = charset.CharSet;

pub const ParseError = error{
    UnexpectedEndOfPattern,
    UnbalancedParen,
    UnbalancedBracket,
    InvalidEscape,
    InvalidHexEscape,
    InvalidRepetition,
    EmptyRepetition,
    RepetitionMinExceedsMax,
    NothingToRepeat,
    OutOfMemory,
};

pub const Parser = struct {
    source: []const u8,
    pos: usize,
    allocator: Allocator,

    pub fn init(allocator: Allocator, source: []const u8) Parser {
        return .{
            .source = source,
            .pos = 0,
            .allocator = allocator,
        };
    }

    fn peek(self: *Parser) ?u8 {
        if (self.pos < self.source.len) return self.source[self.pos];
        return null;
    }

    fn advance(self: *Parser) ?u8 {
        if (self.pos < self.source.len) {
            const c = self.source[self.pos];
            self.pos += 1;
            return c;
        }
        return null;
    }

    fn expect(self: *Parser, c: u8) !void {
        if (self.advance()) |got| {
            if (got != c) return ParseError.UnbalancedParen;
        } else {
            return ParseError.UnexpectedEndOfPattern;
        }
    }

    // ── Grammar ─────────────────────────────────────────────────────

    /// Top-level: alternation
    pub fn parse(self: *Parser) ParseError!*Expr {
        const result = try self.parseAlternation();
        if (self.pos < self.source.len) {
            // Unexpected character (e.g., unmatched ')')
            result.deinit(self.allocator);
            self.allocator.destroy(result);
            return ParseError.UnbalancedParen;
        }
        return result;
    }

    fn parseAlternation(self: *Parser) ParseError!*Expr {
        var left = try self.parseConcat();
        while (self.peek() == '|') {
            _ = self.advance();
            const right = self.parseConcat() catch |err| {
                left.deinit(self.allocator);
                self.allocator.destroy(left);
                return err;
            };
            const alt = Expr.create(self.allocator, .{ .alternation = .{ .left = left, .right = right } }) catch |err| {
                left.deinit(self.allocator);
                self.allocator.destroy(left);
                right.deinit(self.allocator);
                self.allocator.destroy(right);
                return err;
            };
            left = alt;
        }
        return left;
    }

    fn parseConcat(self: *Parser) ParseError!*Expr {
        var left: ?*Expr = null;

        while (self.peek()) |c| {
            if (c == '|' or c == ')') break;

            const atom_result = self.parseQuantified();
            const next = atom_result catch |err| {
                if (left) |l| {
                    l.deinit(self.allocator);
                    self.allocator.destroy(l);
                }
                return err;
            };

            if (left) |l| {
                const cat = Expr.create(self.allocator, .{ .concat = .{ .left = l, .right = next } }) catch |err| {
                    l.deinit(self.allocator);
                    self.allocator.destroy(l);
                    next.deinit(self.allocator);
                    self.allocator.destroy(next);
                    return err;
                };
                left = cat;
            } else {
                left = next;
            }
        }

        if (left) |l| return l;

        // Empty pattern → epsilon
        return Expr.create(self.allocator, .epsilon) catch |err| return err;
    }

    fn parseQuantified(self: *Parser) ParseError!*Expr {
        var base = try self.parseAtom();

        while (self.peek()) |c| {
            switch (c) {
                '*' => {
                    _ = self.advance();
                    const new = Expr.create(self.allocator, .{ .star = .{ .child = base } }) catch |err| {
                        base.deinit(self.allocator);
                        self.allocator.destroy(base);
                        return err;
                    };
                    base = new;
                },
                '+' => {
                    _ = self.advance();
                    const new = Expr.create(self.allocator, .{ .plus = .{ .child = base } }) catch |err| {
                        base.deinit(self.allocator);
                        self.allocator.destroy(base);
                        return err;
                    };
                    base = new;
                },
                '?' => {
                    _ = self.advance();
                    const new = Expr.create(self.allocator, .{ .optional = .{ .child = base } }) catch |err| {
                        base.deinit(self.allocator);
                        self.allocator.destroy(base);
                        return err;
                    };
                    base = new;
                },
                '{' => {
                    const save_pos = self.pos;
                    const rep_result = self.parseRepetitionBraces(base);
                    if (rep_result) |new| {
                        base = new;
                    } else |err| {
                        if (err == ParseError.RepetitionMinExceedsMax) {
                            base.deinit(self.allocator);
                            self.allocator.destroy(base);
                            return err;
                        }
                        // Not a valid repetition — treat { as literal
                        self.pos = save_pos;
                        break;
                    }
                },
                else => break,
            }
        }

        return base;
    }

    fn parseRepetitionBraces(self: *Parser, base: *Expr) ParseError!*Expr {
        _ = self.advance(); // consume '{'

        const min = self.parseDecimal() orelse return ParseError.InvalidRepetition;

        var max: ?u32 = min;
        if (self.peek() == ',') {
            _ = self.advance();
            max = self.parseDecimal(); // null means unbounded
        }

        if (self.peek() != '}') return ParseError.InvalidRepetition;
        _ = self.advance();

        if (max) |m| {
            if (min > m) return ParseError.RepetitionMinExceedsMax;
        }

        const new = Expr.create(self.allocator, .{ .repeat = .{ .child = base, .min = min, .max = max } }) catch |err| {
            base.deinit(self.allocator);
            self.allocator.destroy(base);
            return err;
        };
        return new;
    }

    fn parseDecimal(self: *Parser) ?u32 {
        var result: u32 = 0;
        var found = false;
        while (self.peek()) |c| {
            if (c >= '0' and c <= '9') {
                result = result * 10 + (c - '0');
                _ = self.advance();
                found = true;
            } else break;
        }
        return if (found) result else null;
    }

    fn parseAtom(self: *Parser) ParseError!*Expr {
        const c = self.peek() orelse return ParseError.UnexpectedEndOfPattern;
        switch (c) {
            '(' => return self.parseGroup(),
            '[' => return self.parseCharClass(),
            '.' => {
                _ = self.advance();
                return Expr.create(self.allocator, .dot) catch |err| return err;
            },
            '_' => {
                _ = self.advance();
                return Expr.create(self.allocator, .any_char) catch |err| return err;
            },
            '^' => {
                _ = self.advance();
                return Expr.create(self.allocator, .anchor_start) catch |err| return err;
            },
            '$' => {
                _ = self.advance();
                return Expr.create(self.allocator, .anchor_end) catch |err| return err;
            },
            '\\' => return self.parseEscape(),
            '*', '+', '?', '{' => return ParseError.NothingToRepeat,
            ')' => return ParseError.UnbalancedParen,
            else => {
                _ = self.advance();
                return Expr.create(self.allocator, .{ .literal = c }) catch |err| return err;
            },
        }
    }

    fn parseGroup(self: *Parser) ParseError!*Expr {
        _ = self.advance(); // consume '('

        // Handle (?:...) non-capturing group — we treat all groups as non-capturing
        // anyway, so just skip the ?: prefix
        if (self.pos + 1 < self.source.len and self.source[self.pos] == '?' and self.source[self.pos + 1] == ':') {
            self.pos += 2; // skip '?:'
        }

        const inner = try self.parseAlternation();
        if (self.peek() != ')') {
            inner.deinit(self.allocator);
            self.allocator.destroy(inner);
            return ParseError.UnbalancedParen;
        }
        _ = self.advance(); // consume ')'
        return inner;
    }

    fn parseEscape(self: *Parser) ParseError!*Expr {
        _ = self.advance(); // consume '\'
        const c = self.advance() orelse return ParseError.UnexpectedEndOfPattern;
        switch (c) {
            'n' => return Expr.create(self.allocator, .{ .literal = '\n' }) catch |err| return err,
            't' => return Expr.create(self.allocator, .{ .literal = '\t' }) catch |err| return err,
            'r' => return Expr.create(self.allocator, .{ .literal = '\r' }) catch |err| return err,
            'f' => return Expr.create(self.allocator, .{ .literal = 0x0C }) catch |err| return err,
            'v' => return Expr.create(self.allocator, .{ .literal = 0x0B }) catch |err| return err,
            '\\' => return Expr.create(self.allocator, .{ .literal = '\\' }) catch |err| return err,
            '.' => return Expr.create(self.allocator, .{ .literal = '.' }) catch |err| return err,
            '|' => return Expr.create(self.allocator, .{ .literal = '|' }) catch |err| return err,
            '(' => return Expr.create(self.allocator, .{ .literal = '(' }) catch |err| return err,
            ')' => return Expr.create(self.allocator, .{ .literal = ')' }) catch |err| return err,
            '[' => return Expr.create(self.allocator, .{ .literal = '[' }) catch |err| return err,
            ']' => return Expr.create(self.allocator, .{ .literal = ']' }) catch |err| return err,
            '{' => return Expr.create(self.allocator, .{ .literal = '{' }) catch |err| return err,
            '}' => return Expr.create(self.allocator, .{ .literal = '}' }) catch |err| return err,
            '*' => return Expr.create(self.allocator, .{ .literal = '*' }) catch |err| return err,
            '+' => return Expr.create(self.allocator, .{ .literal = '+' }) catch |err| return err,
            '?' => return Expr.create(self.allocator, .{ .literal = '?' }) catch |err| return err,
            '^' => return Expr.create(self.allocator, .{ .literal = '^' }) catch |err| return err,
            '$' => return Expr.create(self.allocator, .{ .literal = '$' }) catch |err| return err,
            '_' => return Expr.create(self.allocator, .{ .literal = '_' }) catch |err| return err,
            'A' => return Expr.create(self.allocator, .anchor_start) catch |err| return err,
            'z' => return Expr.create(self.allocator, .anchor_end) catch |err| return err,
            'd' => return self.makeShorthandClass(CharSet.digit),
            'D' => return self.makeNegatedShorthandClass(CharSet.digit),
            'w' => return self.makeShorthandClass(CharSet.word),
            'W' => return self.makeNegatedShorthandClass(CharSet.word),
            's' => return self.makeShorthandClass(CharSet.whitespace),
            'S' => return self.makeNegatedShorthandClass(CharSet.whitespace),
            'x' => return self.parseHexEscape(),
            else => return ParseError.InvalidEscape,
        }
    }

    fn makeShorthandClass(self: *Parser, constructor: fn (Allocator) Allocator.Error!CharSet) ParseError!*Expr {
        const cs = constructor(self.allocator) catch return ParseError.OutOfMemory;
        return Expr.create(self.allocator, .{ .char_class = .{ .cs = cs, .negated = false } }) catch |err| {
            var cs_copy = cs;
            cs_copy.deinit();
            return err;
        };
    }

    fn makeNegatedShorthandClass(self: *Parser, constructor: fn (Allocator) Allocator.Error!CharSet) ParseError!*Expr {
        var cs = constructor(self.allocator) catch return ParseError.OutOfMemory;
        const neg = cs.negate(self.allocator) catch {
            cs.deinit();
            return ParseError.OutOfMemory;
        };
        cs.deinit();
        var neg_mut = neg;
        return Expr.create(self.allocator, .{ .char_class = .{ .cs = neg, .negated = false } }) catch |err| {
            neg_mut.deinit();
            return err;
        };
    }

    fn parseHexEscape(self: *Parser) ParseError!*Expr {
        if (self.peek() != '{') return ParseError.InvalidHexEscape;
        _ = self.advance();

        var value: u16 = 0;
        var count: u32 = 0;
        while (self.peek()) |c| {
            if (c == '}') break;
            const digit = hexDigit(c) orelse return ParseError.InvalidHexEscape;
            value = value * 16 + digit;
            count += 1;
            if (count > 2) return ParseError.InvalidHexEscape;
            _ = self.advance();
        }

        if (self.peek() != '}' or count == 0) return ParseError.InvalidHexEscape;
        _ = self.advance();

        if (value > 255) return ParseError.InvalidHexEscape;
        return Expr.create(self.allocator, .{ .literal = @intCast(value) }) catch |err| return err;
    }

    fn hexDigit(c: u8) ?u16 {
        return switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => null,
        };
    }

    fn parseCharClass(self: *Parser) ParseError!*Expr {
        _ = self.advance(); // consume '['

        var negated = false;
        if (self.peek() == '^') {
            negated = true;
            _ = self.advance();
        }

        var ranges: std.ArrayList(charset.Range) = .empty;
        defer ranges.deinit(self.allocator);

        // Handle ] as first char in class (literal)
        if (self.peek() == ']') {
            _ = self.advance();
            try ranges.append(self.allocator,.{ .lo = ']', .hi = ']' });
        }

        while (self.peek()) |c| {
            if (c == ']') break;

            if (c == '\\') {
                _ = self.advance();
                const esc = self.advance() orelse return ParseError.UnexpectedEndOfPattern;
                switch (esc) {
                    'd' => try self.appendShorthandRanges(&ranges, CharSet.digit),
                    'D' => try self.appendNegatedShorthandRanges(&ranges, CharSet.digit),
                    'w' => try self.appendShorthandRanges(&ranges, CharSet.word),
                    'W' => try self.appendNegatedShorthandRanges(&ranges, CharSet.word),
                    's' => try self.appendShorthandRanges(&ranges, CharSet.whitespace),
                    'S' => try self.appendNegatedShorthandRanges(&ranges, CharSet.whitespace),
                    'n' => try ranges.append(self.allocator,.{ .lo = '\n', .hi = '\n' }),
                    't' => try ranges.append(self.allocator,.{ .lo = '\t', .hi = '\t' }),
                    'r' => try ranges.append(self.allocator,.{ .lo = '\r', .hi = '\r' }),
                    '\\' => try ranges.append(self.allocator,.{ .lo = '\\', .hi = '\\' }),
                    ']' => try ranges.append(self.allocator,.{ .lo = ']', .hi = ']' }),
                    '[' => try ranges.append(self.allocator,.{ .lo = '[', .hi = '[' }),
                    '^' => try ranges.append(self.allocator,.{ .lo = '^', .hi = '^' }),
                    '-' => try ranges.append(self.allocator,.{ .lo = '-', .hi = '-' }),
                    '.' => try ranges.append(self.allocator,.{ .lo = '.', .hi = '.' }),
                    '(' => try ranges.append(self.allocator,.{ .lo = '(', .hi = '(' }),
                    ')' => try ranges.append(self.allocator,.{ .lo = ')', .hi = ')' }),
                    '{' => try ranges.append(self.allocator,.{ .lo = '{', .hi = '{' }),
                    '}' => try ranges.append(self.allocator,.{ .lo = '}', .hi = '}' }),
                    '*' => try ranges.append(self.allocator,.{ .lo = '*', .hi = '*' }),
                    '+' => try ranges.append(self.allocator,.{ .lo = '+', .hi = '+' }),
                    '?' => try ranges.append(self.allocator,.{ .lo = '?', .hi = '?' }),
                    '|' => try ranges.append(self.allocator,.{ .lo = '|', .hi = '|' }),
                    '_' => try ranges.append(self.allocator,.{ .lo = '_', .hi = '_' }),
                    '$' => try ranges.append(self.allocator,.{ .lo = '$', .hi = '$' }),
                    'x' => {
                        const byte = try self.parseHexByte();
                        try ranges.append(self.allocator,.{ .lo = byte, .hi = byte });
                    },
                    else => return ParseError.InvalidEscape,
                }
            } else {
                const lo = self.advance().?;
                // Check for range: a-z
                if (self.peek() == '-') {
                    if (self.pos + 1 < self.source.len and self.source[self.pos + 1] != ']') {
                        _ = self.advance(); // consume '-'
                        if (self.peek() == '\\') {
                            _ = self.advance();
                            const esc = self.advance() orelse return ParseError.UnexpectedEndOfPattern;
                            const hi = switch (esc) {
                                'n' => @as(u8, '\n'),
                                't' => @as(u8, '\t'),
                                'r' => @as(u8, '\r'),
                                '\\' => @as(u8, '\\'),
                                'x' => try self.parseHexByte(),
                                else => return ParseError.InvalidEscape,
                            };
                            try ranges.append(self.allocator,.{ .lo = lo, .hi = hi });
                        } else {
                            const hi = self.advance() orelse return ParseError.UnexpectedEndOfPattern;
                            try ranges.append(self.allocator,.{ .lo = lo, .hi = hi });
                        }
                    } else {
                        // '-' at end of class or before ']' → literal
                        try ranges.append(self.allocator,.{ .lo = lo, .hi = lo });
                    }
                } else {
                    try ranges.append(self.allocator,.{ .lo = lo, .hi = lo });
                }
            }
        }

        if (self.peek() != ']') return ParseError.UnbalancedBracket;
        _ = self.advance();

        var cs = CharSet.init(self.allocator, ranges.items) catch return ParseError.OutOfMemory;

        if (negated) {
            const neg = cs.negate(self.allocator) catch {
                cs.deinit();
                return ParseError.OutOfMemory;
            };
            cs.deinit();
            cs = neg;
        }

        return Expr.create(self.allocator, .{ .char_class = .{ .cs = cs, .negated = false } }) catch |err| {
            cs.deinit();
            return err;
        };
    }

    fn appendShorthandRanges(self: *Parser, ranges: *std.ArrayList(charset.Range), constructor: fn (Allocator) Allocator.Error!CharSet) ParseError!void {
        var cs = constructor(self.allocator) catch return ParseError.OutOfMemory;
        defer cs.deinit();
        for (cs.ranges) |r| {
            ranges.append(self.allocator, r) catch return ParseError.OutOfMemory;
        }
    }

    fn appendNegatedShorthandRanges(self: *Parser, ranges: *std.ArrayList(charset.Range), constructor: fn (Allocator) Allocator.Error!CharSet) ParseError!void {
        var cs = constructor(self.allocator) catch return ParseError.OutOfMemory;
        const neg = cs.negate(self.allocator) catch {
            cs.deinit();
            return ParseError.OutOfMemory;
        };
        cs.deinit();
        var neg_mut = neg;
        defer neg_mut.deinit();
        for (neg_mut.ranges) |r| {
            ranges.append(self.allocator, r) catch return ParseError.OutOfMemory;
        }
    }

    fn parseHexByte(self: *Parser) ParseError!u8 {
        if (self.peek() != '{') return ParseError.InvalidHexEscape;
        _ = self.advance();

        var value: u16 = 0;
        var count: u32 = 0;
        while (self.peek()) |c| {
            if (c == '}') break;
            const digit = hexDigit(c) orelse return ParseError.InvalidHexEscape;
            value = value * 16 + digit;
            count += 1;
            if (count > 2) return ParseError.InvalidHexEscape;
            _ = self.advance();
        }
        if (self.peek() != '}' or count == 0) return ParseError.InvalidHexEscape;
        _ = self.advance();
        if (value > 255) return ParseError.InvalidHexEscape;
        return @intCast(value);
    }
};

/// Parse a regex pattern into a raw AST.
pub fn parse(allocator: Allocator, pattern: []const u8) ParseError!*Expr {
    var p = Parser.init(allocator, pattern);
    return p.parse();
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

fn expectLiteral(expr: *const Expr, expected: u8) !void {
    switch (expr.*) {
        .literal => |c| try testing.expectEqual(expected, c),
        else => return error.TestUnexpectedResult,
    }
}

// ── 4a: Literals + concatenation + escapes ──────────────────────────

test "parse single literal" {
    const allocator = testing.allocator;
    const e = try parse(allocator, "a");
    defer {
        e.deinit(allocator);
        allocator.destroy(e);
    }
    try expectLiteral(e, 'a');
}

test "parse concatenation" {
    const allocator = testing.allocator;
    const e = try parse(allocator, "abc");
    defer {
        e.deinit(allocator);
        allocator.destroy(e);
    }
    // Should be concat(concat(a, b), c)
    switch (e.*) {
        .concat => |cat| {
            try expectLiteral(cat.right, 'c');
            switch (cat.left.*) {
                .concat => |inner| {
                    try expectLiteral(inner.left, 'a');
                    try expectLiteral(inner.right, 'b');
                },
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse escape sequences" {
    const allocator = testing.allocator;
    const e = try parse(allocator, "\\n\\t\\\\");
    defer {
        e.deinit(allocator);
        allocator.destroy(e);
    }
    // concat(concat(\n, \t), \\)
    switch (e.*) {
        .concat => |cat| {
            try expectLiteral(cat.right, '\\');
            switch (cat.left.*) {
                .concat => |inner| {
                    try expectLiteral(inner.left, '\n');
                    try expectLiteral(inner.right, '\t');
                },
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse empty pattern" {
    const allocator = testing.allocator;
    const e = try parse(allocator, "");
    defer {
        e.deinit(allocator);
        allocator.destroy(e);
    }
    try testing.expect(e.* == .epsilon);
}

// ── 4b: Character classes ───────────────────────────────────────────

test "parse simple char class [a-z]" {
    const allocator = testing.allocator;
    const e = try parse(allocator, "[a-z]");
    defer {
        e.deinit(allocator);
        allocator.destroy(e);
    }
    switch (e.*) {
        .char_class => |cc| {
            try testing.expect(!cc.negated);
            try testing.expect(cc.cs.contains('a'));
            try testing.expect(cc.cs.contains('z'));
            try testing.expect(!cc.cs.contains('A'));
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse negated char class [^a-z]" {
    const allocator = testing.allocator;
    const e = try parse(allocator, "[^a-z]");
    defer {
        e.deinit(allocator);
        allocator.destroy(e);
    }
    switch (e.*) {
        .char_class => |cc| {
            try testing.expect(!cc.cs.contains('a'));
            try testing.expect(!cc.cs.contains('z'));
            try testing.expect(cc.cs.contains('A'));
            try testing.expect(cc.cs.contains('0'));
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse shorthand \\d" {
    const allocator = testing.allocator;
    const e = try parse(allocator, "\\d");
    defer {
        e.deinit(allocator);
        allocator.destroy(e);
    }
    switch (e.*) {
        .char_class => |cc| {
            try testing.expect(cc.cs.contains('0'));
            try testing.expect(cc.cs.contains('9'));
            try testing.expect(!cc.cs.contains('a'));
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse shorthand \\D (negated digit)" {
    const allocator = testing.allocator;
    const e = try parse(allocator, "\\D");
    defer {
        e.deinit(allocator);
        allocator.destroy(e);
    }
    switch (e.*) {
        .char_class => |cc| {
            try testing.expect(!cc.cs.contains('0'));
            try testing.expect(!cc.cs.contains('9'));
            try testing.expect(cc.cs.contains('a'));
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse shorthand \\w" {
    const allocator = testing.allocator;
    const e = try parse(allocator, "\\w");
    defer {
        e.deinit(allocator);
        allocator.destroy(e);
    }
    switch (e.*) {
        .char_class => |cc| {
            try testing.expect(cc.cs.contains('a'));
            try testing.expect(cc.cs.contains('Z'));
            try testing.expect(cc.cs.contains('_'));
            try testing.expect(cc.cs.contains('5'));
            try testing.expect(!cc.cs.contains(' '));
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse shorthand \\s" {
    const allocator = testing.allocator;
    const e = try parse(allocator, "\\s");
    defer {
        e.deinit(allocator);
        allocator.destroy(e);
    }
    switch (e.*) {
        .char_class => |cc| {
            try testing.expect(cc.cs.contains(' '));
            try testing.expect(cc.cs.contains('\t'));
            try testing.expect(!cc.cs.contains('a'));
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse dot" {
    const allocator = testing.allocator;
    const e = try parse(allocator, ".");
    defer {
        e.deinit(allocator);
        allocator.destroy(e);
    }
    try testing.expect(e.* == .dot);
}

test "parse underscore (any char)" {
    const allocator = testing.allocator;
    const e = try parse(allocator, "_");
    defer {
        e.deinit(allocator);
        allocator.destroy(e);
    }
    try testing.expect(e.* == .any_char);
}

test "parse hex escape \\x{41}" {
    const allocator = testing.allocator;
    const e = try parse(allocator, "\\x{41}");
    defer {
        e.deinit(allocator);
        allocator.destroy(e);
    }
    try expectLiteral(e, 'A');
}

test "parse shorthand in char class [\\d]" {
    const allocator = testing.allocator;
    const e = try parse(allocator, "[\\d]");
    defer {
        e.deinit(allocator);
        allocator.destroy(e);
    }
    switch (e.*) {
        .char_class => |cc| {
            try testing.expect(cc.cs.contains('0'));
            try testing.expect(cc.cs.contains('9'));
        },
        else => return error.TestUnexpectedResult,
    }
}

// ── 4c: Alternation ─────────────────────────────────────────────────

test "parse alternation a|b" {
    const allocator = testing.allocator;
    const e = try parse(allocator, "a|b");
    defer {
        e.deinit(allocator);
        allocator.destroy(e);
    }
    switch (e.*) {
        .alternation => |alt| {
            try expectLiteral(alt.left, 'a');
            try expectLiteral(alt.right, 'b');
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse alternation precedence: ab|cd" {
    const allocator = testing.allocator;
    const e = try parse(allocator, "ab|cd");
    defer {
        e.deinit(allocator);
        allocator.destroy(e);
    }
    // Should be alt(concat(a,b), concat(c,d))
    switch (e.*) {
        .alternation => |alt| {
            switch (alt.left.*) {
                .concat => |cat| {
                    try expectLiteral(cat.left, 'a');
                    try expectLiteral(cat.right, 'b');
                },
                else => return error.TestUnexpectedResult,
            }
            switch (alt.right.*) {
                .concat => |cat| {
                    try expectLiteral(cat.left, 'c');
                    try expectLiteral(cat.right, 'd');
                },
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse triple alternation a|b|c" {
    const allocator = testing.allocator;
    const e = try parse(allocator, "a|b|c");
    defer {
        e.deinit(allocator);
        allocator.destroy(e);
    }
    // Left-associative: alt(alt(a, b), c)
    switch (e.*) {
        .alternation => |alt| {
            try expectLiteral(alt.right, 'c');
            switch (alt.left.*) {
                .alternation => |inner| {
                    try expectLiteral(inner.left, 'a');
                    try expectLiteral(inner.right, 'b');
                },
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
}

// ── 4d: Grouping ────────────────────────────────────────────────────

test "parse grouping (a|b)c" {
    const allocator = testing.allocator;
    const e = try parse(allocator, "(a|b)c");
    defer {
        e.deinit(allocator);
        allocator.destroy(e);
    }
    switch (e.*) {
        .concat => |cat| {
            switch (cat.left.*) {
                .alternation => |alt| {
                    try expectLiteral(alt.left, 'a');
                    try expectLiteral(alt.right, 'b');
                },
                else => return error.TestUnexpectedResult,
            }
            try expectLiteral(cat.right, 'c');
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse nested groups ((a))" {
    const allocator = testing.allocator;
    const e = try parse(allocator, "((a))");
    defer {
        e.deinit(allocator);
        allocator.destroy(e);
    }
    try expectLiteral(e, 'a');
}

// ── 4e: Quantifiers ─────────────────────────────────────────────────

test "parse star" {
    const allocator = testing.allocator;
    const e = try parse(allocator, "a*");
    defer {
        e.deinit(allocator);
        allocator.destroy(e);
    }
    switch (e.*) {
        .star => |s| try expectLiteral(s.child, 'a'),
        else => return error.TestUnexpectedResult,
    }
}

test "parse plus" {
    const allocator = testing.allocator;
    const e = try parse(allocator, "a+");
    defer {
        e.deinit(allocator);
        allocator.destroy(e);
    }
    switch (e.*) {
        .plus => |p| try expectLiteral(p.child, 'a'),
        else => return error.TestUnexpectedResult,
    }
}

test "parse optional" {
    const allocator = testing.allocator;
    const e = try parse(allocator, "a?");
    defer {
        e.deinit(allocator);
        allocator.destroy(e);
    }
    switch (e.*) {
        .optional => |o| try expectLiteral(o.child, 'a'),
        else => return error.TestUnexpectedResult,
    }
}

test "parse exact repetition {3}" {
    const allocator = testing.allocator;
    const e = try parse(allocator, "a{3}");
    defer {
        e.deinit(allocator);
        allocator.destroy(e);
    }
    switch (e.*) {
        .repeat => |r| {
            try expectLiteral(r.child, 'a');
            try testing.expectEqual(@as(u32, 3), r.min);
            try testing.expectEqual(@as(?u32, 3), r.max);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse range repetition {2,5}" {
    const allocator = testing.allocator;
    const e = try parse(allocator, "a{2,5}");
    defer {
        e.deinit(allocator);
        allocator.destroy(e);
    }
    switch (e.*) {
        .repeat => |r| {
            try expectLiteral(r.child, 'a');
            try testing.expectEqual(@as(u32, 2), r.min);
            try testing.expectEqual(@as(?u32, 5), r.max);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse unbounded repetition {2,}" {
    const allocator = testing.allocator;
    const e = try parse(allocator, "a{2,}");
    defer {
        e.deinit(allocator);
        allocator.destroy(e);
    }
    switch (e.*) {
        .repeat => |r| {
            try expectLiteral(r.child, 'a');
            try testing.expectEqual(@as(u32, 2), r.min);
            try testing.expectEqual(@as(?u32, null), r.max);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse quantifier on group (ab)+" {
    const allocator = testing.allocator;
    const e = try parse(allocator, "(ab)+");
    defer {
        e.deinit(allocator);
        allocator.destroy(e);
    }
    switch (e.*) {
        .plus => |p| {
            switch (p.child.*) {
                .concat => |cat| {
                    try expectLiteral(cat.left, 'a');
                    try expectLiteral(cat.right, 'b');
                },
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse multiple quantifiers a*b+" {
    const allocator = testing.allocator;
    const e = try parse(allocator, "a*b+");
    defer {
        e.deinit(allocator);
        allocator.destroy(e);
    }
    switch (e.*) {
        .concat => |cat| {
            switch (cat.left.*) {
                .star => |s| try expectLiteral(s.child, 'a'),
                else => return error.TestUnexpectedResult,
            }
            switch (cat.right.*) {
                .plus => |p| try expectLiteral(p.child, 'b'),
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
}

// ── 4f: Anchors ─────────────────────────────────────────────────────

test "parse anchor \\A" {
    const allocator = testing.allocator;
    const e = try parse(allocator, "\\A");
    defer {
        e.deinit(allocator);
        allocator.destroy(e);
    }
    try testing.expect(e.* == .anchor_start);
}

test "parse anchor \\z" {
    const allocator = testing.allocator;
    const e = try parse(allocator, "\\z");
    defer {
        e.deinit(allocator);
        allocator.destroy(e);
    }
    try testing.expect(e.* == .anchor_end);
}

test "parse ^ anchor" {
    const allocator = testing.allocator;
    const e = try parse(allocator, "^abc");
    defer {
        e.deinit(allocator);
        allocator.destroy(e);
    }
    // Left-associative: concat(concat(concat(^, a), b), c)
    switch (e.*) {
        .concat => |cat| {
            try expectLiteral(cat.right, 'c');
            switch (cat.left.*) {
                .concat => |mid| {
                    try expectLiteral(mid.right, 'b');
                    switch (mid.left.*) {
                        .concat => |inner| {
                            try testing.expect(inner.left.* == .anchor_start);
                            try expectLiteral(inner.right, 'a');
                        },
                        else => return error.TestUnexpectedResult,
                    }
                },
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse $ anchor" {
    const allocator = testing.allocator;
    const e = try parse(allocator, "abc$");
    defer {
        e.deinit(allocator);
        allocator.destroy(e);
    }
    switch (e.*) {
        .concat => |cat| {
            try testing.expect(cat.right.* == .anchor_end);
        },
        else => return error.TestUnexpectedResult,
    }
}

// ── 4g: Error handling ──────────────────────────────────────────────

test "error: unclosed bracket" {
    const allocator = testing.allocator;
    try testing.expectError(ParseError.UnbalancedBracket, parse(allocator, "[abc"));
}

test "error: unbalanced paren (unclosed)" {
    const allocator = testing.allocator;
    try testing.expectError(ParseError.UnbalancedParen, parse(allocator, "(abc"));
}

test "error: unbalanced paren (extra close)" {
    const allocator = testing.allocator;
    try testing.expectError(ParseError.UnbalancedParen, parse(allocator, "abc)"));
}

test "error: invalid escape" {
    const allocator = testing.allocator;
    try testing.expectError(ParseError.InvalidEscape, parse(allocator, "\\q"));
}

test "error: trailing backslash" {
    const allocator = testing.allocator;
    try testing.expectError(ParseError.UnexpectedEndOfPattern, parse(allocator, "abc\\"));
}

test "error: repetition min exceeds max" {
    const allocator = testing.allocator;
    try testing.expectError(ParseError.RepetitionMinExceedsMax, parse(allocator, "a{5,3}"));
}

test "error: nothing to repeat" {
    const allocator = testing.allocator;
    try testing.expectError(ParseError.NothingToRepeat, parse(allocator, "*abc"));
}

test "error: nothing to repeat +" {
    const allocator = testing.allocator;
    try testing.expectError(ParseError.NothingToRepeat, parse(allocator, "+abc"));
}

test "error: invalid hex escape" {
    const allocator = testing.allocator;
    try testing.expectError(ParseError.InvalidHexEscape, parse(allocator, "\\x{GG}"));
}

test "error: unclosed hex escape" {
    const allocator = testing.allocator;
    try testing.expectError(ParseError.InvalidHexEscape, parse(allocator, "\\x{41"));
}

// ── Complex patterns ────────────────────────────────────────────────

test "parse complex: [a-z]+" {
    const allocator = testing.allocator;
    const e = try parse(allocator, "[a-z]+");
    defer {
        e.deinit(allocator);
        allocator.destroy(e);
    }
    switch (e.*) {
        .plus => |p| {
            switch (p.child.*) {
                .char_class => |cc| {
                    try testing.expect(cc.cs.contains('a'));
                    try testing.expect(cc.cs.contains('z'));
                },
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse complex: (a|b)*c" {
    const allocator = testing.allocator;
    const e = try parse(allocator, "(a|b)*c");
    defer {
        e.deinit(allocator);
        allocator.destroy(e);
    }
    switch (e.*) {
        .concat => |cat| {
            switch (cat.left.*) {
                .star => |s| {
                    try testing.expect(s.child.* == .alternation);
                },
                else => return error.TestUnexpectedResult,
            }
            try expectLiteral(cat.right, 'c');
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse escaped special chars in literal context" {
    const allocator = testing.allocator;
    const e = try parse(allocator, "\\(\\)\\[\\]");
    defer {
        e.deinit(allocator);
        allocator.destroy(e);
    }
    // Should be concat chain of literal (, ), [, ]
    switch (e.*) {
        .concat => |cat| {
            try expectLiteral(cat.right, ']');
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse escaped underscore is literal" {
    const allocator = testing.allocator;
    const e = try parse(allocator, "\\_");
    defer {
        e.deinit(allocator);
        allocator.destroy(e);
    }
    try expectLiteral(e, '_');
}

test "parse non-capturing group (?:abc)" {
    const allocator = testing.allocator;
    const e = try parse(allocator, "(?:abc)");
    defer {
        e.deinit(allocator);
        allocator.destroy(e);
    }
    // (?:abc) should parse the same as (abc) — a concat of a, b, c
    switch (e.*) {
        .concat => {}, // expected
        else => return error.TestUnexpectedResult,
    }
}

test "parse non-capturing group with quantifier (?:ab){2,3}" {
    const allocator = testing.allocator;
    const e = try parse(allocator, "(?:ab){2,3}");
    defer {
        e.deinit(allocator);
        allocator.destroy(e);
    }
    switch (e.*) {
        .repeat => |r| {
            try testing.expectEqual(@as(u32, 2), r.min);
            try testing.expectEqual(@as(?u32, 3), r.max);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse nested non-capturing group (?:a|b)+" {
    const allocator = testing.allocator;
    const e = try parse(allocator, "(?:a|b)+");
    defer {
        e.deinit(allocator);
        allocator.destroy(e);
    }
    switch (e.*) {
        .plus => |p| {
            switch (p.child.*) {
                .alternation => {}, // expected
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
}
