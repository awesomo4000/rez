pub const unicode = @import("unicode.zig");
pub const charset = @import("charset.zig");
pub const ast = @import("ast.zig");
pub const parser = @import("parser.zig");
pub const node = @import("node.zig");
pub const interner = @import("interner.zig");
pub const minterm = @import("minterm.zig");
pub const nullability = @import("nullability.zig");
pub const derivative = @import("derivative.zig");
pub const dfa = @import("dfa.zig");
pub const startset = @import("startset.zig");

/// Match a regex pattern against input, returning the leftmost-longest match span.
/// Returns null if no match is found.
pub const match = dfa.match;
pub const findAll = dfa.findAll;
pub const Span = dfa.Span;
pub const Regex = dfa.Regex;

const std = @import("std");

test {
    std.testing.refAllDecls(@This());
}
