/// Interned regex node types. All nodes are identified by NodeId (u32).
/// After interning, pointer equality (ID equality) implies structural equality.
const std = @import("std");

pub const NodeId = u32;

/// Sentinel node IDs, pre-interned.
pub const NOTHING: NodeId = 0; // Matches nothing (empty language)
pub const EPSILON: NodeId = 1; // Matches empty string
pub const DOTSTAR: NodeId = 2; // .* — any string not containing \n
pub const ANYSTAR: NodeId = 3; // _* — any string at all

/// An interned regex node. Stored in the interner arena.
pub const Node = union(enum) {
    nothing, // ⊥
    epsilon, // ε
    predicate: Predicate, // character predicate (charset as bitvec or ranges)
    concat: Concat,
    alternation: Alternation,
    loop: Loop,
    anchor_start, // \A / ^
    anchor_end, // \z / $

    pub const Predicate = struct {
        /// Minterm bitvector — bit i is set if minterm i matches this predicate.
        /// Before minterm computation, this is 0 and ranges are used.
        bitvec: u64 = 0,
        /// Character ranges that define this predicate.
        ranges: []const Range = &.{},

        pub const Range = struct {
            lo: u8,
            hi: u8,
        };
    };

    pub const Concat = struct {
        left: NodeId,
        right: NodeId,
    };

    pub const Alternation = struct {
        /// Sorted, deduplicated children.
        children: []const NodeId,
    };

    pub const Loop = struct {
        child: NodeId,
        min: u32,
        max: u32, // std.math.maxInt(u32) means unbounded
        greedy: bool = true,
    };

    pub const UNBOUNDED: u32 = std.math.maxInt(u32);
};
