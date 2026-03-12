# Zig Regex Engine: Hot Path Analysis

## The Inner Loop (maxEnd, lines 241-254 in dfa.zig)

This is what executes for **every character** in the input:

```zig
while (pos < input.len) {
    const mt = self.table.getMintermForChar(input[pos]);           // Line 242
    const new_at_end = (pos + 1 == input.len);
    state = try self.transition(state, mt, at_start, new_at_end);  // Line 244
    
    if (state == NOTHING) break;
    
    pos += 1;
    
    const nullable = try self.cachedNullable(state, at_start, pos == input.len); // Line 250
    if (nullable) {
        best = pos;
    }
}
```

### Step 1: getMintermForChar (line 242)

**Code (minterm.zig:22-24):**
```zig
pub fn getMintermForChar(self: *const MintermTable, c: u8) u8 {
    return self.char_to_minterm[c];
}
```

**Assembly-level equivalent:**
```
mov     al, [r8 + input[pos]]    ; c is already in al
movzx   eax, al                  ; zero-extend to 32-bit
mov     cl, [r9 + rax]           ; Load from char_to_minterm[c]
```

**Cost: 2-3 CPU cycles** (L1 cache hit, single array lookup)

---

### Step 2: transition() (line 244)

**Full code (dfa.zig:178-226):**

```zig
fn transition(self: *DFA, state: NodeId, mt: u8, at_start: bool, at_end: bool) !NodeId {
    self.profile.transition_calls += 1;
    
    // Fast path: at_end=false (99.9% of calls)
    if (at_end) {
        // ... slow path for rare at_end=true case
        return ...;
    }
    
    // Line 200-209: THE HOT PATH
    const state_idx = try self.ensureState(state);
    const ctx: usize = if (at_start) 1 else 0;
    const stride: usize = @intCast(self.stride);
    const offset: usize = @as(usize, state_idx) * stride + @as(usize, mt);
    
    const cached = self.delta[ctx].items[offset];
    if (cached != SENTINEL) {
        self.profile.cache_hits += 1;
        return cached;  // ◄── CACHE HIT: Fast return
    }
    
    // Cache miss branch (very rare)
    self.profile.cache_misses += 1;
    const d_start = Timer.begin();
    const next = try derivative_mod.derivative(&self.interner, state, mt, at_start, false);
    self.profile.derivative_ns += d_start.elapsed_ns();
    
    self.delta[ctx].items[offset] = next;
    if (next != NOTHING) {
        _ = try self.ensureState(next);
    }
    return next;
}
```

**Decomposing the hot path (lines 200-209):**

#### ensureState(state) - Maps NodeId to compact index

```zig
fn ensureState(self: *DFA, node_id: NodeId) !u16 {
    const id: usize = @intCast(node_id);
    
    // Line 120-125: Grow state_map if needed (rare)
    if (id >= self.state_map.items.len) {
        const old_len = self.state_map.items.len;
        const new_len = id + 1;
        try self.state_map.resize(self.allocator, new_len);
        @memset(self.state_map.items[old_len..new_len], UNMAPPED);
    }
    
    // Line 128-129: Lookup existing mapping (common, O(1))
    const existing = self.state_map.items[id];
    if (existing != UNMAPPED) return existing;
    
    // Lines 131-142: Assign new index and grow delta tables (cache miss only)
    const idx = self.state_count;
    self.state_count += 1;
    self.state_map.items[id] = idx;
    
    const stride: usize = @intCast(self.stride);
    for (0..2) |ctx| {
        const old_delta_len = self.delta[ctx].items.len;
        try self.delta[ctx].resize(self.allocator, old_delta_len + stride);
        @memset(self.delta[ctx].items[old_delta_len..], SENTINEL);
    }
    // ... similar for nullable arrays
    
    return idx;
}
```

**Hot path cost of ensureState():**
- **Cache hit case:** 1 array lookup in state_map (2-3 cycles)
- **First reference to a new state:** Grow arrays + assign index (~1000 cycles)
- But this happens **once per unique state**, not per character!

#### Delta table lookup

```zig
const stride: usize = @intCast(self.stride);           // num_minterms
const offset: usize = @as(usize, state_idx) * stride + @as(usize, mt);
const cached = self.delta[ctx].items[offset];
if (cached != SENTINEL) {
    self.profile.cache_hits += 1;
    return cached;
}
```

**Memory layout visualization:**
```
delta[at_start] = [ s0m0, s0m1, s0m2, | s1m0, s1m1, s1m2, | s2m0, s2m1, s2m2 ]
                   └─ stride=3 ─┘   └─ stride=3 ─┘
                   
offset = state_idx * 3 + minterm
```

For a pattern with 5 minterms and 10 reachable states:
- delta[0] = 50 entries total
- delta[1] = 50 entries total (at_start=true variant)
- Typical L1 cache: 32KB → easily fits hundreds of states

**Hot path cost:**
- 1 multiplication: state_idx * stride (2 cycles)
- 1 addition: + minterm (1 cycle)
- 1 array access: delta[ctx].items[offset] (2-3 cycles)
- 1 comparison: != SENTINEL (1 cycle)
- 1 conditional branch: if (cached != SENTINEL) (1 cycle latency, but predicted)

**Total: 7-10 CPU cycles on cache hit** (with good branch prediction ~5 cycles)

---

### Step 3: cachedNullable (line 250)

**Code (dfa.zig:155-175):**

```zig
fn cachedNullable(self: *DFA, state: NodeId, at_start: bool, at_end: bool) !bool {
    self.profile.nullability_calls += 1;
    
    const state_idx = try self.ensureState(state);      // O(1) cached lookup
    const ctx: usize = if (at_start) 1 else 0;
    
    const arr = if (at_end) &self.end_nullable[ctx] else &self.nullable[ctx];
    const cached = arr.items[@intCast(state_idx)];
    
    if (cached != UNKNOWN_NULLABLE) {
        return cached == IS_NULLABLE;  // ◄── CACHE HIT
    }
    
    // Cache miss: compute recursively (rare, once per unique state)
    const n_start = Timer.begin();
    const result = nullability_mod.isNullableAt(&self.interner, state, at_start, at_end);
    self.profile.nullability_ns += n_start.elapsed_ns();
    
    arr.items[@intCast(state_idx)] = if (result) IS_NULLABLE else NOT_NULLABLE;
    return result;
}
```

**Hot path (cache hit):**
- Line 158: `ensureState(state)` - O(1) array lookup
- Line 161: Array access into nullable array
- Line 162: Compare with UNKNOWN_NULLABLE (1 cycle)
- Line 163-164: Return early if cached (1 cycle)

**Cost: 5-7 cycles on cache hit**

---

## Combined Inner Loop Cycle Count

For **one character** with all caches hot:

```
┌─ getMintermForChar ───────────────────────────┐
│ mov al, [r8 + input[pos]]                 2   │ Load char
│ movzx eax, al                             1   │ Extend
│ mov cl, [r9 + rax]                        2   │ Array lookup
└───────────────────────────────────────────────┘ Total: ~5 cycles

┌─ transition (delta table lookup) ─────────────┐
│ ensureState (cached):                         │
│   mov r10, [state_map + state_idx]        2   │
│                                               │
│ Calculate offset:                             │
│   imul rax, r10, stride                   2   │
│   add rax, minterm                        1   │
│                                               │
│ Lookup result:                                │
│   mov r11, [delta[ctx] + offset]          2   │
│   cmp r11, SENTINEL                       1   │
│   jne short (cache hit)                   1   │
└───────────────────────────────────────────────┘ Total: ~9 cycles

┌─ Check state != NOTHING ──────────────────────┐
│ cmp r11, NOTHING                          1   │
│ je short (end loop)                       1   │
└───────────────────────────────────────────────┘ Total: ~2 cycles

┌─ cachedNullable (cached) ──────────────────────┐
│ ensureState (cached):                         │
│   mov r10, [state_map + state_idx]        2   │
│                                               │
│ Array lookup:                                 │
│   mov r12, [nullable[ctx] + r10]          2   │
│   cmp r12, UNKNOWN_NULLABLE               1   │
│   je short (cache miss - rare)            1   │
│                                               │
│ Return cached value:                          │
│   cmp r12, IS_NULLABLE                    1   │
│   setne al                                1   │
│   ret                                     1   │
└───────────────────────────────────────────────┘ Total: ~9 cycles

TOTAL PER CHARACTER: ~25-30 cycles (with L1 cache hits and good branch prediction)
```

**On modern CPUs (with out-of-order execution and prefetching):**
- The multiplications and memory accesses can overlap
- Branch prediction: 99% of branches are predicted correctly (not SENTINEL, state != NOTHING)
- Effective throughput: 1 character per 15-20 cycles on a 4 GHz CPU ≈ 200-270 MB/s per core

---

## Cache Miss Scenario (0.1% of transitions)

When `delta[ctx].items[offset] == SENTINEL`:

```zig
const next = try derivative_mod.derivative(&self.interner, state, mt, at_start, false);
```

This triggers the derivative computation (derivative.zig:17-86):

**Cost: O(tree_height) tree walk**

For pattern `abc`:
- Tree: concat(concat(a, b), c) - depth ~3
- Derivative walk: ~6-10 node accesses

For pattern `(a|b|c|d|e|f|g|h)*`:
- Alternation with 8 children, loop
- Derivative walk: ~20-30 node accesses
- Plus nullable checks on the alternation

Then intern() is called (interner.zig:199-221):
- Hash computation: O(tree_height)
- Hash table lookup: O(1) amortized
- Possible node creation: ~1000 cycles for memory allocation

**Total cache miss: 1-10 milliseconds** (vs 0.1 microseconds for cache hit)

---

## Three-Level Cache Hierarchy

### L1: Delta Table (Flat Array)
```
Data: [2][num_states * num_minterms] array of NodeId
Lookup: offset = state_idx * stride + minterm
Hit rate: 99%+ per character
Hit latency: 7-10 cycles
Miss latency: 1-10 milliseconds
```

### L2: Nullable Cache (Parallel Arrays)
```
Data: [4][num_states] array of u8 (2 for at_start, 2 for at_end)
Lookup: cached_nullable[ctx].items[state_idx]
Hit rate: 95%+ per state
Hit latency: 5-7 cycles
Miss latency: 100-10000 cycles (depends on tree depth)
```

### L3: Derivative + Interner
```
Data: HashMap<u64, Vec<NodeId>> for dedup
Lookup: hash node → check for existing
Hit rate: 50-90% (depends on regex complexity)
Hit latency: 100-1000 cycles
Miss latency: 1-10 milliseconds (tree walk + allocation)
```

---

## Hot Path Optimizations Already in Place

1. **Flat delta table:** O(1) lookup vs hashmap O(1) with ~10x better constants
2. **Cached nullability:** Avoid recursive tree walks per character
3. **at_end fast path:** Rare at_end=true cases go to hashmap, not flat table
4. **State index mapping:** Compact indices for dense arrays (state_map)
5. **Rewrite rules:** Simplify derivatives during interning (e.g., concat(ε, R) → R)
6. **Early termination:** NOTHING state breaks inner loop immediately
7. **Two contexts:** Separate delta tables for at_start vs non-start (better cache locality)

---

## Example Measurements from Profile Counters

From dfa.zig lines 41-52:

```zig
pub const ProfileCounters = struct {
    transition_calls: u64 = 0,      // Should be ~input_length * num_start_positions
    cache_hits: u64 = 0,            // Should be ~99% of transition_calls
    cache_misses: u64 = 0,          // Should be ~0.1% of transition_calls
    transition_ns: u64 = 0,         // Time in transition() - mostly cache misses
    derivative_ns: u64 = 0,         // Time in derivative() - only on miss
    nullability_calls: u64 = 0,     // Should be ~input_length
    nullability_ns: u64 = 0,        // Time in nullability checks
};
```

**Expected ratios for pattern `abc` on input "xabcyabcz":**

```
Input length: 9
Num start positions: 10 (0-9)
Total chars scanned: ~45 (varies by backtracking)

transition_calls: ~45
cache_hits: ~44 (97.8%)
cache_misses: ~1 (2.2%)

transition_ns: ~0 (mostly hits, minimal time)
derivative_ns: ~1000-5000 (one miss walk)

nullability_calls: ~45
nullability_ns: ~0 (all cached)
```

