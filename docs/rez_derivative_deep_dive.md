# Derivative Computation Deep Dive

## The Derivative Algorithm (Brzozowski, 1964)

**Key Idea:** Process one character at a time by computing δ_m(R), the derivative of regex R with respect to minterm m.

**Result:** A new regex that represents "what matches the rest of the input after consuming one minterm."

---

## 1. Predicate Node (Character Class)

### Code (derivative.zig:25-33)

```zig
.predicate => |pred| {
    // Check if this predicate matches the given minterm
    const bit: u64 = @as(u64, 1) << @intCast(minterm);
    if ((pred.bitvec & bit) != 0) {
        return EPSILON;
    } else {
        return NOTHING;
    }
}
```

**Semantics:**
- δ_m([a-z]) when m='a' → EPSILON (matched!)
- δ_m([a-z]) when m='5' → NOTHING (didn't match)

**Example:**
```
Pattern: [a-z]
Input: "abc"

pos=0, char='a', minterm=0:
  δ([a-z], minterm=0) = EPSILON
  EPSILON is nullable → match at pos 0
  But we want to keep matching...

pos=1, char='b', minterm=0:
  δ(EPSILON, minterm=0) = NOTHING
  Dead state, break
```

**Cost: O(1)** - Single bitwise AND operation

---

## 2. Concatenation (Sequence)

### Code (derivative.zig:34-49)

```zig
.concat => |cat| {
    // δ_m(R·S) = δ_m(R)·S | ν(R)·δ_m(S)
    // where ν(R) uses context-aware nullability for anchors
    const dr = try derivative(interner, cat.left, minterm, at_start, at_end);
    const dr_s = try interner.intern(.{ .concat = .{ .left = dr, .right = cat.right } });
    
    if (nullability.isNullableAt(interner, cat.left, at_start, at_end)) {
        const ds = try derivative(interner, cat.right, minterm, at_start, at_end);
        if (dr_s == NOTHING) return ds;
        if (ds == NOTHING) return dr_s;
        const children = try interner.allocChildren(&.{ dr_s, ds });
        return interner.intern(.{ .alternation = .{ .children = children } });
    }
    
    return dr_s;
}
```

### Visual Explanation

**Pattern:** R·S (sequence)

**Rule:** δ(R·S) = δ(R)·S ∪ (if nullable(R) then δ(S) else ∅)

**Example 1: Non-nullable left side**
```
Pattern: ab·c (which is (ab)c)
Regex tree: concat(concat(a,b), c)

Process 'a':
  δ(concat(concat(a,b), c)) = δ(concat(a,b))·c
  = concat(EPSILON, b)·c
  = concat(b, c)     ← via rewrite concat(ε,R)→R

Result after 'a': we need to match "bc"
```

**Example 2: Nullable left side**
```
Pattern: a?·bc (which is (a|ε)bc)
Regex tree: concat(alt(a, ε), concat(b,c))

Process 'b':
  ν(alt(a,ε)) = true (nullable!)
  δ(alt(a,ε)) = δ(a)·rest = ∅·rest = ∅
  δ(b) = EPSILON (matches!)
  
  Result = δ(a)·rest ∪ δ(b)
         = NOTHING ∪ EPSILON
         = EPSILON     ← via rewrite alt removes NOTHING

After 'b': either dead state OR epsilon (can match empty from alt path)
```

**Key insight:** The `nullability` check determines if we "short-circuit" to the right side.

### Cost Analysis

```
For concat(R, S):
  1. Recursive derivative of R: O(height(R))
  2. intern() the new concat: O(height(R)) hash
  3. Check nullability(R): O(height(R)) tree walk
  4. If nullable:
     a. Recursive derivative of S: O(height(S))
     b. intern() the alternation: O(height(R) + height(S)) hash
     
Total: O(height(R) + height(S))
```

---

## 3. Alternation (Choice)

### Code (derivative.zig:50-67)

```zig
.alternation => |alt| {
    // δ_m(R|S) = δ_m(R) | δ_m(S)
    var result_children: std.ArrayList(NodeId) = .empty;
    defer result_children.deinit(interner.allocator);
    
    for (alt.children) |child| {
        const d = try derivative(interner, child, minterm, at_start, at_end);
        if (d != NOTHING) {
            try result_children.append(interner.allocator, d);
        }
    }
    
    if (result_children.items.len == 0) return NOTHING;
    if (result_children.items.len == 1) return result_children.items[0];
    
    const children = try interner.allocChildren(result_children.items);
    return interner.intern(.{ .alternation = .{ .children = children } });
}
```

### Visual Explanation

**Rule:** δ(R|S) = δ(R) | δ(S)

**Example:**
```
Pattern: a|ab (choose between 'a' alone or 'ab')
Regex tree: alt(a, concat(a,b))

Process 'a':
  δ(alt(a, concat(a,b))) = δ(a) | δ(concat(a,b))
                         = EPSILON | concat(EPSILON, b)
                         = EPSILON | b
                         
After 'a': We can match empty (chose 'a') OR continue for 'b' (chose 'ab')
```

### Optimizations in the Code

1. **Skip NOTHING children:** Line 57-59 filters out NOTHING
   - δ(a) | NOTHING = δ(a)
2. **Unwrap single child:** Line 62-63
   - alt(R) = R (automatically handles if one branch dies)
3. **Result may be NOTHING:** Line 62
   - If all branches die: alt() = NOTHING

### Cost Analysis

```
For alternation with N children:
  For each child:
    1. Recursive derivative: O(height(child))
    2. Append if not NOTHING: O(1) amortized
  
  After loop:
    3. intern() the alternation: O(N) hash
    
Total: O(N * max(height(children)))
```

---

## 4. Loop (Quantifier)

### Code (derivative.zig:68-85)

```zig
.loop => |lp| {
    // δ_m(R{min,max}) = δ_m(R) · R{min-1, max-1}
    // (with min-1 clamped to 0, max-1 handled for overflow)
    const dr = try derivative(interner, lp.child, minterm, at_start, at_end);
    if (dr == NOTHING) return NOTHING;
    
    const new_min = if (lp.min > 0) lp.min - 1 else 0;
    const new_max = if (lp.max == Node.UNBOUNDED) Node.UNBOUNDED else lp.max - 1;
    
    const rest = try interner.intern(.{ .loop = .{
        .child = lp.child,
        .min = new_min,
        .max = new_max,
    } });
    
    return interner.intern(.{ .concat = .{ .left = dr, .right = rest } });
}
```

### Visual Explanation

**Rule:** δ(R{m,M}) = δ(R) · R{m-1, M-1}

**Example 1: Kleene star**
```
Pattern: a* (zero or more 'a')
Regex tree: loop(a, min=0, max=∞)

Process 'a':
  δ(a*, min=0, max=∞) = δ(a) · a*
                      = EPSILON · a*
                      = a*  ← via rewrite concat(ε,R)→R
                      
After 'a': Still need zero or more 'a' (structural sharing!)
```

**Example 2: Bounded repeat**
```
Pattern: a{2,5} (2-5 'a's)
Regex tree: loop(a, min=2, max=5)

Process 'a':
  δ(a{2,5}) = δ(a) · a{1,4}
            = EPSILON · a{1,4}
            = a{1,4}  ← via rewrite

After 'a': Need 1-4 more 'a's
After 'aa': a{0,3} (nullable now!)
After 'aaa': a{0,2}
...
```

### Key Insight: Structural Sharing

Notice that when we compute δ(a*) = a*, we get back **the same node ID** (or a deduplicated copy).

The `intern()` system ensures that if we compute the same derivative twice, we get the same NodeId:

```zig
const rest = try interner.intern(.{ .loop = .{
    .child = lp.child,    // Same child
    .min = new_min,       // Same new_min
    .max = new_max,       // Same new_max
} });
```

This might hash to the same value and return the existing ID via dedup.

### Cost Analysis

```
For loop(R, min, max):
  1. Recursive derivative of R: O(height(R))
  2. Create new loop: O(height(R)) hash
  3. Create concat: O(1) hash
  
Total: O(height(R))
```

---

## 5. Nullability During Derivative

### Called from derivative.zig:40

```zig
if (nullability.isNullableAt(interner, cat.left, at_start, at_end)) {
    const ds = try derivative(interner, cat.right, minterm, at_start, at_end);
    // ...
}
```

### Implementation (nullability.zig:21-44)

```zig
pub fn isNullableAt(interner: *const Interner, id: NodeId, 
                    at_start: bool, at_end: bool) bool {
    const n = interner.get(id);
    switch (n) {
        .nothing => return false,
        .epsilon => return true,
        .predicate => return false,
        .anchor_start => return at_start,      // Context-aware!
        .anchor_end => return at_end,
        .concat => |cat| {
            return isNullableAt(interner, cat.left, at_start, at_end) and
                   isNullableAt(interner, cat.right, at_start, at_end);
        },
        .alternation => |alt| {
            for (alt.children) |child| {
                if (isNullableAt(interner, child, at_start, at_end)) return true;
            }
            return false;
        },
        .loop => |lp| {
            if (lp.min == 0) return true;  // Fast path
            return isNullableAt(interner, lp.child, at_start, at_end);
        },
    }
}
```

### Context-Aware Anchors

**This is crucial for patterns like `^abc$`:**

```
Pattern: ^abc$
Regex tree: concat(concat(anchor_start, a), concat(b, c))

At start position pos=0:
  at_start = true
  ν(anchor_start, at_start=true) = true  ← Anchor satisfied!
  
At start position pos=1:
  at_start = false
  ν(anchor_start, at_start=false) = false  ← Anchor not satisfied!
```

**Without context:** We couldn't distinguish positions before and after the start.

### Cost Analysis

```
For isNullableAt():
  - Predicate, Epsilon, Nothing: O(1)
  - Anchor: O(1)
  - Concat: Recurse on both, AND results: O(height(R))
  - Alternation: Recurse until first nullable: O(sum of heights)
  - Loop: Check min=0, recurse once: O(height(child))
  
Worst case: O(height(tree))
```

---

## Complete Example: Pattern `a+` on Input "aaa"

### Setup

```
Pattern: a+ → concat(a, a*)  (via desugaring in interner.zig:388-395)
Root: concat(pred(a), loop(pred(a), min=0, max=∞))
```

### Character 0: 'a' (pos=0)

```
derivative(root, minterm=a, at_start=false, at_end=false):
  root = concat(pred(a), loop(pred(a), 0, ∞))
  
  Case: concat
    1. dr = derivative(pred(a), minterm=a)
           = EPSILON  (predicate matches)
    
    2. dr_s = intern(concat(EPSILON, loop(...)))
             = loop(...)  (via rewrite concat(ε,R)→R)
    
    3. Check nullable(pred(a)) = false
       Skip the alternation path
    
    4. Return dr_s = loop(pred(a), 0, ∞)

Result: loop(a, 0, ∞)  [still need zero or more 'a']
Nullable: Yes (min=0)  ✓ best = 1
```

### Character 1: 'a' (pos=1)

```
derivative(loop(a, 0, ∞), minterm=a):
  Case: loop
    1. dr = derivative(pred(a), minterm=a)
           = EPSILON
    
    2. rest = intern(loop(pred(a), 0, ∞))
             = loop(a, 0, ∞)  [same loop!]
    
    3. intern(concat(EPSILON, loop(...)))
      = loop(a, 0, ∞)  [via rewrite]

Result: loop(a, 0, ∞)  [same state as after char 0!]
Nullable: Yes  ✓ best = 2
```

### Character 2: 'a' (pos=2)

```
derivative(loop(a, 0, ∞), minterm=a):
  Same computation as Character 1
  
Result: loop(a, 0, ∞)
Nullable: Yes  ✓ best = 3
```

### Character 3: (end of input)

```
Loop terminates (pos >= input.len)
Return best = 3  ← Match [0, 3)
```

**Key observation:** After the first 'a', we're in state `loop(a, 0, ∞)` and **stay in that state** for all subsequent 'a's. This demonstrates structural sharing: the derivative computation is memoized in the delta table.

---

## Recursion Depth Analysis

### Worst Case: Deeply Nested Pattern

```
Pattern: (((((a)))))
Regex tree: concat(concat(concat(concat(concat(a)))))
Depth: 5

Process 'a':
  derivative(concat(...)):
    dr = derivative(concat(...)):
      dr = derivative(concat(...)):
        dr = derivative(concat(...)):
          dr = derivative(concat(...)):
            dr = derivative(a)
                = EPSILON
            ...
```

Recursion depth = tree depth = 5

### Typical Patterns

| Pattern | Tree Depth | Notes |
|---------|-----------|-------|
| `abc` | 2 | concat(concat(a,b),c) |
| `a|b\|c` | 2 | alternation with flat children |
| `[a-z]+` | 1 | loop over single predicate |
| `(a\|b)*` | 2 | loop over alternation |
| `(a(b\|c)*)*` | 4 | nested loops and alts |

### Bounded Recursion

The Zig code doesn't use explicit stack limits, but:
1. Patterns are typically shallow (≤10 levels)
2. Hash-consing deduplicates to keep state space small
3. Rewrite rules simplify aggressively

---

## Memory Allocation During Derivative

### Temporary ArrayList (alternation.zig:52-53)

```zig
var result_children: std.ArrayList(NodeId) = .empty;
defer result_children.deinit(interner.allocator);
```

For each alternation during derivative:
- Allocate temporary vector
- Append filtered children
- Intern the result
- Free the temp vector

**Cost:** O(num_children * num_allocations)

### interner.allocChildren (interner.zig:231-236)

```zig
pub fn allocChildren(self: *Interner, children: []const NodeId) ![]const NodeId {
    var list: NodeIdList = .empty;
    try list.appendSlice(self.allocator, children);
    try self.children_arena.append(self.allocator, list);
    return self.children_arena.items[self.children_arena.items.len - 1].items;
}
```

**Cost:** O(num_children) allocations + appends

### interner.intern (interner.zig:199-221)

```zig
fn internNode(self: *Interner, n: Node) !NodeId {
    const h = hashNode(n);
    
    if (self.dedup.getPtr(h)) |bucket| {
        for (bucket.items) |existing_id| {
            if (nodesEqual(self.get(existing_id), n)) {
                return existing_id;  // Reuse! No allocation
            }
        }
        // Hash collision: allocate new node
        const new_id: NodeId = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, n);
        try bucket.append(self.allocator, new_id);
        return new_id;
    } else {
        // New hash: allocate
        const new_id: NodeId = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, n);
        var bucket: NodeIdList = .empty;
        try bucket.append(self.allocator, new_id);
        try self.dedup.put(self.allocator, h, bucket);
        return new_id;
    }
}
```

**Cost:** O(1) if dedup hit, O(hash_bucket_size) if collision checking

---

## Summary: Derivative Complexity

| Operation | Time | Space |
|-----------|------|-------|
| δ(predicate) | O(1) | O(0) |
| δ(concat) | O(height) | O(height) |
| δ(alternation) | O(N·height) | O(N·height) |
| δ(loop) | O(height) | O(height) |
| nullability | O(height) | O(height) |
| intern/dedup | O(1) amortized | O(1) amortized |

**Total for one cache miss:** O(tree_height * branching_factor) with decent constants.

