# RE# vs rez: Head-to-Head Algorithmic Comparison

## TL;DR

Both engines are Brzozowski derivative-based lazy DFAs with minterm optimization. The core
per-character transition logic is essentially the same. The massive performance gap comes from
**how each engine finds candidate match positions** — rez tries every byte, RE# skips to
candidates using SIMD acceleration and a reversed automaton.

---

## 1. The Outer Loop: This Is Where The Money Is

### rez: Naive start-position scan

```
findAll(input):
    start = 0
    while start <= input.len:
        if maxEnd(input, start) returns end:
            record match (start, end)
            start = max(end, start + 1)
        else:
            start += 1           // ← TRY EVERY BYTE
```

**Problem:** For a 1 MB input with a pattern like `hello`, rez calls `maxEnd()` from
positions 0, 1, 2, 3, ..., ~1,000,000. Each call does at minimum:
- 1 minterm lookup
- 1 delta table lookup
- 1 nullable check
- realize it's NOTHING, break

That's ~25 cycles × 1M positions = ~25M cycles just to discover there's nothing at each
position. **This is O(n) work per non-matching position.**

### RE#: Two-phase reverse+forward with SIMD skip

```
llmatch_all(input):
    // PHASE 1: Find match STARTS (right-to-left, ONE pass)
    state = DFA_TR_REV                    // reversed automaton: T* ∘ reverse(pattern)
    pos = input.len
    candidate_starts = []

    while pos > 0:
        if canSkip(state):
            TrySkipInitialRevChar()       // ← SIMD skip, jumps 100s-1000s of bytes
        else:
            pos--
            state = delta[state << mtlog | minterm(input[pos])]
        if isNullable(state):
            candidate_starts.add(pos)     // found a potential match start

    // PHASE 2: Find match ENDS (left-to-right, only from candidates)
    for start in candidate_starts:
        state = DFA_R_NOPR                // forward automaton
        end = end_lazy(input.slice(start..))  // also uses SIMD skip
        record match (start, start + end)
```

**Key differences:**
1. **ONE reverse pass** over the entire input identifies ALL candidate start positions
2. **SIMD acceleration** in the reverse pass skips huge chunks (e.g., `IndexOfAny('h')` for `hello`)
3. Forward pass only runs from **validated candidates**, not every byte
4. Forward pass ALSO uses SIMD skip within states that allow it

### Impact estimate

For pattern `hello` on 1 MB of English text:
- **rez**: ~1M calls to `maxEnd()`, each doing 1-5 transitions → ~5M transitions total
- **RE#**: 1 reverse pass with SIMD skip (scanning for 'h'), finds ~500 candidate starts,
  then 500 short forward scans → maybe ~10K transitions total

**That's a 500x difference** just from the outer loop structure.

---

## 2. The Inner Loop: Mostly Equivalent

### rez hot path (per character, cache hit)
```zig
// ~25 cycles per character
mt = char_to_minterm[input[pos]]                         // 5 cycles
state_idx = state_map[state]                             // 3 cycles
cached = delta[ctx][state_idx * stride + mt]             // 7 cycles
if (cached == SENTINEL) → compute derivative             // rare
nullable = nullable_cache[ctx][state_idx]                // 5 cycles
if (nullable != UNKNOWN) → return cached == IS_NULLABLE  // 5 cycles
```

### RE# hot path (per character, cache hit)
```fsharp
// ~10 instructions per character
mt = mtlookup[input[l_pos]]                             // 1 load
index = (state << mtlog) | mt                            // 2 ops (shift + or)
nextState = dfaDelta[index]                              // 1 load
if (nextState == 0) → compute derivative                 // rare
check nullKind[state]                                    // 1 load + cmp
```

### Differences in the inner loop

| Aspect | rez | RE# | Winner |
|--------|-----|-----|--------|
| Delta index calc | `state_idx * stride + mt` (multiply) | `state << mtlog \| mt` (shift+or) | RE# (shift is 1 cycle vs multiply ~3 cycles) |
| State mapping | Extra `state_map[]` indirection | State ID IS the index | RE# (one fewer load) |
| Nullable check | Separate array lookup per char | `nullKind[]` byte per state, checked inline | Roughly equal |
| SIMD skip in inner loop | None | `canSkipLeftToRight` → `IndexOfAny()` | RE# (huge for some states) |
| Context handling | `delta[ctx]` — two separate arrays | Single delta, anchor-dependent states are separate state IDs | RE# slightly (fewer branches) |

**Delta table indexing**: RE# uses `state << mtlog | mt` which requires `num_minterms` to be
a power of 2 (padded). rez uses `state_idx * stride + mt` which works with any minterm count
but costs an extra multiply. The shift-or approach is worth adopting — pad minterms to
power-of-2 and use bit shifting.

**State mapping**: rez has an extra indirection — `state_map[node_id] → compact_idx`, then
`delta[compact_idx * stride + mt]`. RE# assigns sequential state IDs directly, so
`delta[state_id << mtlog | mt]` is one step. This saves ~3 cycles per character.

---

## 3. Skip Acceleration: rez Has None

### What RE# does at compile time

1. **Prefix extraction** (`calcPrefixSets`):
   Walk the regex AST following single-derivative paths. If the pattern starts with a
   deterministic sequence (like `hel` in `hello`), extract it.

2. **Startset inference** (`calcPotentialMatchStart`):
   If no deterministic prefix, compute which characters could START a match from any
   reachable state. E.g., for `(cat|dog)`, startset = {c, d}.

3. **Commonality scoring**:
   Don't bother optimizing on common characters (a-z, whitespace). Only accelerate if the
   character set is rare enough to be worth the overhead.

4. **Build accelerator** (`findInitialOptimizations`):
   Choose from: StringPrefix, SearchValuesPrefix (weighted set), SingleSearchValues,
   SearchValuesPotentialStart, or NoAccelerator.

### What RE# does at match time

**Reverse phase skip** (`TrySkipInitialRevChar`):
- For `StringPrefix("hello")`: Use `LastIndexOf("hello")` — native SIMD string search
- For `SearchValuesPrefix`: Use weighted reverse search (find rarest char first via
  `LastIndexOfAny`, then verify other positions)
- For `SingleSearchValues`: Use `LastIndexOfAny(charSet)` — SIMD char scan

**Forward phase skip** (`canSkipLeftToRight` in `end_lazy`):
- Per-state: if a state's startset allows it, use `IndexOfAny(startset)` to jump
  forward to the next character that could continue the match
- E.g., in state "matched 'hel', need 'l'", skip forward to next 'l' via SIMD

### What rez should implement

**Phase 1 (biggest bang for buck):**
- Compute startset at compile time for the initial state
- In `findAll`, use `memchr` / SIMD byte scan to skip to the next candidate byte
- This alone should give 10-100x on patterns with rare starting characters

**Phase 2:**
- Implement the reversed automaton approach (single pass instead of per-position)
- This eliminates the O(n) outer loop entirely

**Phase 3:**
- Per-state skip flags and SearchValues in the forward inner loop
- Weighted reverse prefix search for multi-character prefixes

---

## 4. Feature Comparison

| Feature | rez | RE# | Priority |
|---------|-----|-----|----------|
| Flat delta table | ✅ Yes | ✅ Yes | Done |
| Nullable cache | ✅ Yes | ✅ Yes | Done |
| Minterm equivalence classes | ✅ Yes | ✅ Yes | Done |
| Hash-consing / interning | ✅ Yes | ✅ Yes | Done |
| Rewrite rules during intern | ✅ Yes | ✅ Yes | Done |
| Two contexts (at_start) | ✅ Yes | ✅ Yes | Done |
| Early termination (NOTHING) | ✅ Yes | ✅ Yes (DFA_DEAD) | Done |
| **Startset / prefix acceleration** | ❌ No | ✅ Yes | 🔴 Critical |
| **Reversed automaton** | ❌ No | ✅ Yes | 🔴 Critical |
| **SIMD character scanning** | ❌ No | ✅ Yes (SearchValues) | 🔴 Critical |
| **Per-state skip flags** | ❌ No | ✅ Yes (StateFlags) | 🟡 High |
| **Shift-or delta indexing** | ❌ No (multiply) | ✅ Yes (shift\|or) | 🟡 High |
| Direct state IDs (no state_map) | ❌ No | ✅ Yes | 🟡 High |
| State flags packed in 1 byte | ❌ No | ✅ Yes | 🟢 Medium |
| Full DFA precompilation | ❌ No | ✅ Yes (threshold=100) | 🟢 Medium |
| Weighted reverse prefix search | ❌ No | ✅ Yes | 🟢 Medium |
| Commonality scoring | ❌ No | ✅ Yes | 🟢 Medium |
| Fixed-length match shortcut | ❌ No | ✅ Yes | 🟢 Medium |
| ArrayPool / memory pooling | ❌ No | ✅ Yes | 🟢 Medium |
| Thread safety (rwlock) | ❌ No | ✅ Yes | ⚪ Low (single-threaded for now) |

---

## 5. Optimization Roadmap (Prioritized)

### Phase 1: Startset Acceleration (est. 10-100x on literal-heavy patterns)

**What:** At compile time, compute which bytes can start a match. Use `memchr` or
Zig's `std.mem.indexOfAny` to skip to the next candidate position in `findAll`.

**Why first:** This is the single biggest win. The naive "try every byte" outer loop
is where most time is spent for patterns with distinctive starting characters.

**Zig equivalent of SearchValues:**
```zig
// At compile time, build a 256-bit (32-byte) bitmap of starting bytes
var start_bytes: [256]bool = .{false} ** 256;
for (each minterm mt that has a non-NOTHING derivative from root) {
    for (byte 0..255) {
        if (char_to_minterm[byte] == mt) start_bytes[byte] = true;
    }
}

// At match time, use the bitmap to skip
fn findNextCandidate(input: []const u8, pos: usize) usize {
    // Use std.simd or manual NEON/SSE to scan 16-32 bytes at a time
    while (pos < input.len) : (pos += 1) {
        if (start_bytes[input[pos]]) return pos;
    }
    return input.len;
}
```

On ARM (M4 Pro), Zig's `@Vector(16, u8)` gives access to NEON SIMD.

### Phase 2: Reversed Automaton (est. 2-5x additional on top of Phase 1)

**What:** Build `reverse(pattern)` and `T* ∘ reverse(pattern)`. Run a single
right-to-left pass to find all candidate match starts. Then run forward passes only
from those candidates.

**Why:** Eliminates the O(n) outer loop entirely. Combined with Phase 1 skip
acceleration in the reverse pass, this means:
- 1 reverse pass (with SIMD skip) finds ~K candidates
- K forward passes (with SIMD skip) find match ends
- Total work: O(n/skip_factor + K × avg_match_len) instead of O(n × avg_scan_len)

**Implementation notes:**
- Need `reverseNode()` function that reverses regex structure
- Concat(A, B) → Concat(reverse(B), reverse(A))
- Loop/Alt/Pred stay the same
- Build separate DFA instance for the reversed automaton
- The reversed automaton shares the same interner (nodes are just reversed)

### Phase 3: Delta Table Micro-Optimization (est. 15-30% on inner loop)

**What:**
1. Pad `num_minterms` to next power-of-2
2. Use `state_id << mtlog | mt` instead of `state_idx * stride + mt`
3. Eliminate `state_map` indirection — assign state IDs as sequential integers directly

**Why:** Saves ~5 cycles per character in the inner loop. On cache-hit-dominated
workloads where Phase 1+2 have already eliminated most non-candidate positions,
the remaining positions need to be processed as fast as possible.

### Phase 4: Per-State Skip in Forward Loop (est. 2-10x on specific patterns)

**What:** For each DFA state, compute which characters can lead to non-NOTHING
transitions. If only a small set of characters are "interesting", set a canSkip
flag and store the byte set. In the forward matching loop, when a state has
canSkip=true, use SIMD to jump to the next interesting byte.

**Why:** E.g., after matching `hel` in `hello`, only `l` is interesting. Instead
of feeding `x`, `y`, `z`, ... through the DFA one at a time, jump directly to the
next `l`.

### Phase 5: Compile-Time Pattern Specialization (est. variable)

- Fixed-length patterns: skip the forward DFA entirely, just add offset
- Literal string patterns: use `std.mem.indexOf` directly
- Single-character patterns: use `std.mem.indexOfScalar`
- Alternation of literals: Aho-Corasick or multi-pattern SIMD

---

## 6. Quick Wins (Can Do Today)

1. **Startset bitmap for findAll outer loop** — even without SIMD, a simple
   `if (!start_bytes[input[pos]]) continue;` in the outer loop will skip ~90%
   of positions for most patterns.

2. **Shift-or delta indexing** — pad minterms to power-of-2, replace multiply with
   shift. Easy mechanical change to `dfa.zig`.

3. **Remove state_map indirection** — use NodeId directly as delta table index
   (may need to handle sparse IDs, but for most patterns state count is small).

4. **Profile counter removal** — the `profile.transition_calls += 1` etc. in the
   hot path adds unnecessary work for production builds. Gate behind `@import("builtin").mode`.

---

## 7. Why RE# Gets 252x Over .NET Compiled

The 252x speedup on dictionary patterns comes from a perfect storm:

1. **.NET Compiled regex backtracks** — for `word1|word2|...|word12`, it tries each
   alternative sequentially, backtracking on failure. O(n × k × avg_word_len).

2. **RE# uses prefix acceleration** — extracts the first-character set from all 12
   alternatives, builds SIMD scanner, skips directly to candidates.

3. **RE# uses startset skip in reverse pass** — finds candidate positions in bulk
   via SIMD, only runs forward DFA on ~0.1% of positions.

4. **The DFA itself is tiny** — 12 literal words create maybe 50-100 states,
   fitting entirely in L1 cache.

rez already has #4. Adding #2 and #3 is where the 10-100x lives.

---

## 8. Zig-Specific SIMD Notes

### NEON on Apple Silicon (M4 Pro)

Zig exposes SIMD via `@Vector`:
```zig
const V16 = @Vector(16, u8);

fn simdContains(haystack: []const u8, needle_set: [256]bool) ?usize {
    // Build NEON lookup table (TBL instruction)
    // Process 16 bytes at a time
    // Return index of first match
}
```

For byte-level scanning, the key NEON instructions are:
- `TBL` / `TBX` — table lookup (perfect for minterm mapping of 16 bytes at once)
- `CMEQ` — compare equal (check against target byte)
- `UMAXV` — horizontal max (check if any lane matched)

### Alternative: Use libc memchr

For single-byte startset, `@cImport` and use `memchr()` which is already
SIMD-optimized on all platforms:
```zig
const c = @cImport(@cInclude("string.h"));
const ptr = c.memchr(input.ptr + pos, target_byte, input.len - pos);
```

### Alternative: Zig std.mem

`std.mem.indexOfScalar(u8, ...)` already uses SIMD on supported platforms.
For multi-byte sets, `std.mem.indexOfAny(u8, ...)` may work.

---

## 9. Benchmark Targets

Based on the baseline benchmarks, here's where each optimization should show impact:

| Benchmark | Current MB/s | Bottleneck | Expected After Phase 1 | After Phase 2 |
|-----------|-------------|------------|----------------------|---------------|
| literal-short | 100.5 | Outer loop (every byte) | 500-1000 | 1000+ |
| literal-long | 42.8 | Outer loop + long scans | 200-500 | 500+ |
| literal-nomatch | 64.9 | Outer loop (every byte, all fail) | 2000+ | 2000+ |
| letters-8-13 | 50.5 | Dense matches, hard to skip | 60-80 | 100+ |
| digits | 156.1 | Already decent (10% are digits) | 200-300 | 300+ |
| alt-2 | 47.0 | Outer loop | 200-500 | 500+ |
| alt-5 | 24.4 | Outer loop + more states | 100-300 | 300+ |
| alt-nomatch | 39.0 | Outer loop (all fail) | 2000+ | 2000+ |
| quadratic-10x | 354 KB/s | O(n²) from outer loop | 1-5 MB/s | 5-50 MB/s |

The `literal-nomatch` and `alt-nomatch` benchmarks should see the most dramatic improvement
because currently 100% of `maxEnd()` calls are wasted.
