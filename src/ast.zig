/// Raw AST types produced by the parser, before interning.
/// Tree nodes are heap-allocated. `deinit` recursively frees.
const std = @import("std");
const Allocator = std.mem.Allocator;
const charset = @import("charset.zig");

pub const RepeatRange = struct {
    min: u32,
    max: ?u32, // null means unbounded
};

pub const Expr = union(enum) {
    literal: u8,
    dot, // . — any except newline
    any_char, // _ — any byte
    epsilon,
    anchor_start, // \A or ^
    anchor_end, // \z or $

    char_class: CharClass,
    concat: Binary,
    alternation: Binary,
    star: Unary,
    plus: Unary,
    optional: Unary,
    repeat: Repeat,

    pub const CharClass = struct {
        cs: charset.CharSet,
        negated: bool,
    };

    pub const Binary = struct {
        left: *Expr,
        right: *Expr,
    };

    pub const Unary = struct {
        child: *Expr,
    };

    pub const Repeat = struct {
        child: *Expr,
        min: u32,
        max: ?u32,
    };

    /// Recursively free this expression and all children.
    pub fn deinit(self: *Expr, allocator: Allocator) void {
        switch (self.*) {
            .literal, .dot, .any_char, .epsilon, .anchor_start, .anchor_end => {},
            .char_class => |*cc| cc.cs.deinit(),
            .concat, .alternation => |bin| {
                bin.left.deinit(allocator);
                allocator.destroy(bin.left);
                bin.right.deinit(allocator);
                allocator.destroy(bin.right);
            },
            .star, .plus, .optional => |un| {
                un.child.deinit(allocator);
                allocator.destroy(un.child);
            },
            .repeat => |rep| {
                rep.child.deinit(allocator);
                allocator.destroy(rep.child);
            },
        }
    }

    // ── Convenience constructors ─────────────────────────────────────

    pub fn create(allocator: Allocator, value: Expr) !*Expr {
        const ptr = try allocator.create(Expr);
        ptr.* = value;
        return ptr;
    }
};

// ── Tests ───────────────────────────────────────────────────────────────

test "construct and free literal" {
    const allocator = std.testing.allocator;
    const e = try Expr.create(allocator, .{ .literal = 'a' });
    e.deinit(allocator);
    allocator.destroy(e);
}

test "construct and free concat" {
    const allocator = std.testing.allocator;
    const left = try Expr.create(allocator, .{ .literal = 'a' });
    const right = try Expr.create(allocator, .{ .literal = 'b' });
    const cat = try Expr.create(allocator, .{ .concat = .{ .left = left, .right = right } });
    cat.deinit(allocator);
    allocator.destroy(cat);
}

test "construct and free nested expression" {
    const allocator = std.testing.allocator;
    const a = try Expr.create(allocator, .{ .literal = 'a' });
    const star_a = try Expr.create(allocator, .{ .star = .{ .child = a } });
    const b = try Expr.create(allocator, .{ .literal = 'b' });
    const cat = try Expr.create(allocator, .{ .concat = .{ .left = star_a, .right = b } });
    cat.deinit(allocator);
    allocator.destroy(cat);
}

test "construct and free char class" {
    const allocator = std.testing.allocator;
    var cs = try charset.CharSet.digit(allocator);
    const e = try Expr.create(allocator, .{ .char_class = .{ .cs = cs, .negated = false } });
    e.deinit(allocator);
    allocator.destroy(e);
    // CharSet is freed via deinit chain — no leak
    _ = &cs;
}

test "construct and free alternation" {
    const allocator = std.testing.allocator;
    const left = try Expr.create(allocator, .{ .literal = 'a' });
    const right = try Expr.create(allocator, .{ .literal = 'b' });
    const alt = try Expr.create(allocator, .{ .alternation = .{ .left = left, .right = right } });
    alt.deinit(allocator);
    allocator.destroy(alt);
}

test "construct and free repeat" {
    const allocator = std.testing.allocator;
    const child = try Expr.create(allocator, .{ .literal = 'a' });
    const rep = try Expr.create(allocator, .{ .repeat = .{ .child = child, .min = 2, .max = 5 } });
    rep.deinit(allocator);
    allocator.destroy(rep);
}

test "construct and free optional and plus" {
    const allocator = std.testing.allocator;
    const a = try Expr.create(allocator, .{ .literal = 'a' });
    const opt = try Expr.create(allocator, .{ .optional = .{ .child = a } });
    opt.deinit(allocator);
    allocator.destroy(opt);

    const b = try Expr.create(allocator, .{ .literal = 'b' });
    const p = try Expr.create(allocator, .{ .plus = .{ .child = b } });
    p.deinit(allocator);
    allocator.destroy(p);
}
