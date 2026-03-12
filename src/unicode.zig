/// Character classification functions for regex matching.
/// All operate on single bytes (u8). No allocator needed.
const std = @import("std");

/// Returns true if the byte is an ASCII digit: [0-9]
pub fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// Returns true if the byte is a word character: [a-zA-Z0-9_]
pub fn isWord(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '_';
}

/// Returns true if the byte is ASCII whitespace: [ \t\n\r\f\v]
pub fn isWhitespace(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\n', '\r', 0x0C, 0x0B => true,
        else => false,
    };
}

/// Returns true if the byte matches `.` — any byte except newline.
pub fn isDot(c: u8) bool {
    return c != '\n';
}

/// Returns true for any byte. Matches `_` wildcard in rez.
pub fn isAny(_: u8) bool {
    return true;
}

// ── Tests ───────────────────────────────────────────────────────────────

test "isDigit boundary values" {
    try std.testing.expect(!isDigit('0' - 1));
    try std.testing.expect(isDigit('0'));
    try std.testing.expect(isDigit('5'));
    try std.testing.expect(isDigit('9'));
    try std.testing.expect(!isDigit('9' + 1));
    try std.testing.expect(!isDigit('a'));
    try std.testing.expect(!isDigit('Z'));
}

test "isWord boundary values" {
    try std.testing.expect(isWord('a'));
    try std.testing.expect(isWord('z'));
    try std.testing.expect(isWord('A'));
    try std.testing.expect(isWord('Z'));
    try std.testing.expect(isWord('0'));
    try std.testing.expect(isWord('9'));
    try std.testing.expect(isWord('_'));
    try std.testing.expect(!isWord(' '));
    try std.testing.expect(!isWord('-'));
    try std.testing.expect(!isWord('@'));
    try std.testing.expect(!isWord('['));
    try std.testing.expect(!isWord(0));
}

test "isWhitespace boundary values" {
    try std.testing.expect(isWhitespace(' '));
    try std.testing.expect(isWhitespace('\t'));
    try std.testing.expect(isWhitespace('\n'));
    try std.testing.expect(isWhitespace('\r'));
    try std.testing.expect(isWhitespace(0x0C)); // form feed
    try std.testing.expect(isWhitespace(0x0B)); // vertical tab
    try std.testing.expect(!isWhitespace('a'));
    try std.testing.expect(!isWhitespace('0'));
    try std.testing.expect(!isWhitespace(0));
}

test "isDot matches everything except newline" {
    try std.testing.expect(isDot('a'));
    try std.testing.expect(isDot(' '));
    try std.testing.expect(isDot(0));
    try std.testing.expect(isDot(255));
    try std.testing.expect(!isDot('\n'));
}

test "isAny matches everything" {
    try std.testing.expect(isAny(0));
    try std.testing.expect(isAny('\n'));
    try std.testing.expect(isAny(255));
}

test "exhaustive digit check" {
    var count: usize = 0;
    for (0..256) |i| {
        const c: u8 = @intCast(i);
        if (isDigit(c)) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 10), count);
}

test "exhaustive word check" {
    var count: usize = 0;
    for (0..256) |i| {
        const c: u8 = @intCast(i);
        if (isWord(c)) count += 1;
    }
    // 26 lowercase + 26 uppercase + 10 digits + 1 underscore = 63
    try std.testing.expectEqual(@as(usize, 63), count);
}

test "exhaustive whitespace check" {
    var count: usize = 0;
    for (0..256) |i| {
        const c: u8 = @intCast(i);
        if (isWhitespace(c)) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 6), count);
}

test "exhaustive dot check" {
    var count: usize = 0;
    for (0..256) |i| {
        const c: u8 = @intCast(i);
        if (isDot(c)) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 255), count);
}

test "exhaustive any check" {
    var count: usize = 0;
    for (0..256) |i| {
        const c: u8 = @intCast(i);
        if (isAny(c)) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 256), count);
}

test "digit-word subset relationship" {
    // every digit should be a word character
    for (0..256) |i| {
        const c: u8 = @intCast(i);
        if (isDigit(c)) {
            try std.testing.expect(isWord(c));
        }
    }
}

test "dot-any subset relationship" {
    // everything matching dot should also match any
    for (0..256) |i| {
        const c: u8 = @intCast(i);
        if (isDot(c)) {
            try std.testing.expect(isAny(c));
        }
    }
}
