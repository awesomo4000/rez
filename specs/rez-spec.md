# rez — Specification

A derivative-based regex engine in Zig with first-class boolean operators, designed for high-performance multi-pattern matching and search.

## 1. Purpose

rez is a library. It compiles individually annotated regex patterns — including intersection (`&`), complement (`~`), and restricted lookarounds — into a single automaton that scans input in one pass, returning precise match spans tagged with pattern identifiers.

### 1.1 Design Goals

- **Single-pass multi-pattern scanning** with boolean composition.
- **Individually annotated patterns** that compile into one automaton but preserve pattern identity for reporting.
- **O(n) matching** with respect to input length, no backtracking, no ReDoS vulnerability.
- **Pure Zig implementation** with no external dependencies. All SIMD acceleration uses Zig's `@Vector` builtins for cross-platform portability.
- **Composability**: patterns describe individual properties of matches and combine with `&` to form precise specifications. Exclusion patterns use `~` to reject false positives without post-processing.

### 1.2 Non-Goals

- Capture groups. Match spans are sufficient. Sub-group extraction is not supported.
- PCRE compatibility. rez uses POSIX leftmost-longest match semantics, not backtracking-greedy semantics.
- Backreferences. These break the regular language model and preclude O(n) matching.
- Streaming partial match (initially). The bidirectional scan requires the full input region. Streaming support may be added later with a forward-only mode.

## 2. Theoretical Foundation

rez implements the algorithms described in:

- **Primary**: "RE#: High Performance Derivative-Based Regex Matching with Intersection, Complement and Restricted Lookarounds" (Varatalu, Veanes, Ernits; POPL 2025). DOI: 10.1145/3704837
- **Predecessor**: "Derivative Based Nonbacktracking Real-World Regex Matching with Backtracking Semantics" (.NET NonBacktracking engine; Moseley et al., 2023). DOI: 10.1145/3591262
- **Original theory**: "Derivatives of Regular Expressions" (Brzozowski, 1964). DOI: 10.1145/321239.321249
- **Derivatives re-examined**: Owens, Reppy, Turon (2009). DOI: 10.1017/S0956796808007090
- **Teddy algorithm**: Qiu, Chang, Hong, Zhu, Wang, Li (ICPP 2021). DOI: 10.1145/3472456.3473512

Reference implementations:

- resharp-dotnet (F# source): `https://github.com/ieviev/resharp-dotnet`
- BurntSushi aho-corasick (Teddy in Rust): `https://github.com/BurntSushi/aho-corasick`

## 3. Architecture

### 3.1 Overview

```
                         COMPILE TIME
                         ══════════════

  Pattern definitions ─────────────────────────────────────────────┐
  (regex + annotation + category)                                  │
       │                                                           │
       ▼                                                           │
  ┌─────────────────────────────────┐                              │
  │ Stage 1: Parse & Normalize      │                              │
  │                                 │                              │
  │ • Parse extended regex syntax   │                              │
  │ • Normalize to LNF:            │                              │
  │   (?<=B)·E·(?=A)               │                              │
  │ • Replace negative lookarounds  │                              │
  │   with positive + complement    │                              │
  └──────────────┬──────────────────┘                              │
                 │                                                 │
                 ▼                                                 │
  ┌─────────────────────────────────┐                              │
  │ Stage 2: Minterm Computation    │                              │
  │                                 │                              │
  │ • Collect all predicates (ψ)    │                              │
  │   from all patterns             │                              │
  │ • Compute minterm partition     │                              │
  │ • Build char→minterm_id table   │                              │
  │ • Represent predicates as       │                              │
  │   bitvectors over minterms      │                              │
  └──────────────┬──────────────────┘                              │
                 │                                                 │
                 ▼                                                 │
  ┌─────────────────────────────────┐   ┌────────────────────────┐ │
  │ Stage 3: Literal Extraction     │   │ Pattern Annotations    │ │
  │                                 │──▶│                        │◀┘
  │ • BFS over derivative graph     │   │ • pattern_id → label   │
  │ • Identify required literal     │   │ • pattern_id → category│
  │   prefixes and interior strings │   │ • pattern_id → bit     │
  │ • Emit literal set for Teddy    │   │   in alive_mask        │
  └──────────┬──────────────────────┘   └────────────────────────┘
             │                                    │
             ▼                                    │
  ┌─────────────────────────────────┐             │
  │ Stage 3b: Teddy Table Build     │             │
  │                                 │             │
  │ • Assign patterns to buckets    │             │
  │ • Build lo/hi nibble tables     │             │
  │   for 1-3 byte fingerprints     │             │
  └──────────┬──────────────────────┘             │
             │                                    │
             ▼                                    │
  ┌─────────────────────────────────┐             │
  │ Compiled Pattern Database       │             │
  │                                 │             │
  │ • Teddy tables (SIMD prefilter) │             │
  │ • Seed regex nodes (for lazy    │             │
  │   DFA construction)             │             │
  │ • Minterm tables                │             │
  │ • Pattern annotations           │◀────────────┘
  └──────────┬──────────────────────┘
             │
             │
                         RUNTIME
                         ═══════

             │
             ▼
  ┌─────────────────────────────────┐
  │ Phase 1: Teddy SIMD Scan        │
  │                                 │
  │ • PSHUFB nibble-table lookups   │
  │ • 16/32/64 bytes per iteration  │
  │ • Emits (position, bucket_mask) │
  │   candidate set                 │
  └──────────┬──────────────────────┘
             │
             ▼
  ┌─────────────────────────────────┐
  │ Phase 2: RE# DFA Validation     │
  │                                 │
  │ • For each candidate:           │
  │   1. Reverse scan (MaxEnd on    │
  │      reversed input/regex) to   │
  │      find leftmost match start  │
  │   2. Forward scan (MaxEnd) to   │
  │      find longest match end     │
  │ • Lazy DFA: states constructed  │
  │   on demand via derivatives     │
  │ • Boolean ops (& ~ |) evaluated │
  │   inline during derivative      │
  │   computation                   │
  │ • Pattern alive bitset tracks   │
  │   which patterns contributed    │
  └──────────┬──────────────────────┘
             │
             ▼
  ┌─────────────────────────────────┐
  │ Match Results                   │
  │                                 │
  │ • span (start, end) in input    │
  │ • pattern_id bitset             │
  │ • annotation metadata           │
  └─────────────────────────────────┘
```

### 3.2 Relationship to Consumers

rez is a library. It has no knowledge of application-specific strategies, file formats, or output structure. It takes compiled patterns and input bytes, returns annotated match spans. Downstream tools consume those results however they see fit.

## 4. Regex Syntax

### 4.1 Supported Constructs

rez supports Extended Regular Expressions (ERE) with boolean operators and restricted lookarounds.

**Character classes (predicates ψ):**

| Syntax | Meaning |
|--------|---------|
| `[a-z]` | Character range |
| `[^a-z]` | Negated character class |
| `.` | Any character except `\n` |
| `_` | Any character including `\n` (equivalent to `[\s\S]`) |
| `\d`, `\w`, `\s` | Digit, word, whitespace classes |
| `\D`, `\W`, `\S` | Negated versions |
| `\n`, `\r`, `\t` | Literal escapes |
| `\x{HH}` | Hex byte |

**Quantifiers:**

| Syntax | Meaning |
|--------|---------|
| `R*` | Zero or more |
| `R+` | One or more (sugar for `R·R*`) |
| `R?` | Zero or one (sugar for `R\|ε`) |
| `R{m}` | Exactly m repetitions |
| `R{m,n}` | Between m and n repetitions |
| `R{m,}` | At least m repetitions |

**Boolean operators:**

| Syntax | Meaning | Precedence |
|--------|---------|------------|
| `R\|S` | Union — matches R or S | Lowest |
| `R&S` | Intersection — matches both R and S | Above union |
| `RS` | Concatenation | Above intersection |
| `~R` | Complement — matches anything R does not | Highest (unary) |

**Derived boolean operators (optional syntactic sugar):**

| Syntax | Equivalent | Meaning |
|--------|-----------|---------|
| `L↛R` | `L&~R` | Difference (L but not R) |
| `L→R` | `~L\|R` | Implication (if L then R) |
| `L⊕R` | `L&~R\|~L&R` | XOR (exactly one) |

**Lookarounds (restricted form):**

| Syntax | Meaning |
|--------|---------|
| `(?<=R)` | Positive lookbehind: preceded by R |
| `(?<!R)` | Negative lookbehind: not preceded by R |
| `(?=R)` | Positive lookahead: followed by R |
| `(?!R)` | Negative lookahead: not followed by R |

**Restriction**: Lookarounds contain only ERE (no nested lookarounds). All patterns normalize to the Lookaround Normal Form `(?<=B)·E·(?=A)` where `A, B, E ∈ ERE`.

**Anchors:**

| Syntax | Meaning |
|--------|---------|
| `\A` | Start of input |
| `\z` | End of input |
| `^` | Start of line (sugar for `(?<=\A\|\n)`) |
| `$` | End of line (sugar for `(?=\z\|\n)`) |
| `\b` | Word boundary (sugar for `(?<!\w)` or `(?!\w)` depending on context) |

**Wildcard:**

`_*` matches any string of any length including across newlines. This is the universal "don't care" wildcard for use in lookbehind/lookahead context and complement expressions.

### 4.2 Pattern Composition Examples

Individual properties are composed with `&` to build precise detectors:

```
# Exact format match with word boundaries
\bsk_live_[a-zA-Z0-9]{24,99}\b

# Keyword in context + character class + length + exclusions
(?<=_*(password|secret|token)_*[=:]_*['"]?)
  & \b[!-~]{16,64}\b
  & ~(_*example_*)
  & ~(_*TODO_*)
  & ~(_*test_fixture_*)

# Match content only from a specific section, not another
(?<=Valid~(_*Invalid_*))
  & .+@.+
  & ~(_*\._*\._*)

# Envelope matching with lookbehind/lookahead
(?<=-----BEGIN_*PRIVATE KEY-----)
  & _*
  & (?=-----END_*PRIVATE KEY-----)

# Cross-line matching constrained to paragraph boundaries
(?<=_*(jdbc|postgresql|mysql|mongodb):)
  & ~(_*\n\n_*)
  & _*://[^\s]{10,200}
```

### 4.3 Match Semantics

rez uses POSIX leftmost-longest semantics:

- Among all matches starting at the leftmost position, the longest is selected.
- Union (`|`) is commutative: `a|b` and `b|a` produce identical results.
- Algebraic identities hold: `R|S ≡ S|R`, `R&S ≡ S&R`, `~~R ≡ R`, De Morgan's laws, distributive laws.

This guarantees that refactoring a pattern using boolean algebra never changes match results.

## 5. Internal Representation

### 5.1 Regex AST

All regex nodes are hash-consed (interned) so that structurally identical nodes share a single allocation and can be compared by pointer/ID equality.

```
RegexNode (tagged union, identified by u32 ID):
    .predicate    → minterm_bitvector: u64
    .epsilon      → (no payload)
    .union        → sorted array of child node IDs
                    (commutative, associative, idempotent)
    .intersection → sorted array of child node IDs
                    (commutative, associative, idempotent)
    .complement   → child node ID
    .concat       → head node ID, tail node ID
    .loop         → child node ID, lower: u32, upper: u32
                    (upper = max_u32 for unbounded)
    .lookahead    → child node ID (ERE only), offset_set: OffsetSet
    .lookbehind   → child node ID (ERE only)
    .anchor_start → (no payload, \A)
    .anchor_end   → (no payload, \z)
    .nothing      → (⊥, the dead/empty-language node)
```

**Sentinel nodes** (pre-interned, known IDs):

- `NOTHING` (⊥): no string matches. `ID = 0`.
- `EPSILON` (ε): only the empty string matches. `ID = 1`.
- `DOTSTAR` (`.*`): any single-line string. `ID = 2`.
- `ANYSTAR` (`_*`): any string whatsoever. `ID = 3`.

### 5.2 Interning Arena

The node arena provides:

- `intern(node) → u32` — returns existing ID if structurally identical node exists, otherwise allocates.
- Structural identity for union/intersection is order-independent (children stored sorted).
- `~~R` is simplified to `R` at construction time. `⊥|R` simplifies to `R`. Etc. (see §6.3).

### 5.3 Effective Boolean Algebra (EBA) over Characters

Characters are represented symbolically through an Effective Boolean Algebra:

```
EBA = (Σ, Ψ, ⟦_⟧, ⊥, ⊤, ∨, ∧, ¬)
```

Where:
- `Σ` = character domain (ASCII `u8` or Unicode `u21`)
- `Ψ` = predicates, represented as bitvectors over minterms
- `⟦ψ⟧` = denotation: set of characters satisfying predicate ψ
- Boolean ops on predicates = bitwise ops on bitvectors

**Minterm computation:**

Given predicates `ψ₁, ψ₂, ... ψₙ` from all patterns, minterms are the minimal satisfiable conjunctions of those predicates and their negations. They partition the character space into equivalence classes where all characters in a class behave identically.

```
Example: predicates [a-z], [0-9], \w

Minterms:
  m₀: [a-z] ∧ ¬[0-9] ∧ \w     → lowercase letters
  m₁: ¬[a-z] ∧ [0-9] ∧ \w     → digits
  m₂: ¬[a-z] ∧ ¬[0-9] ∧ \w    → underscore, uppercase, etc.
  m₃: ¬[a-z] ∧ ¬[0-9] ∧ ¬\w   → everything else
```

Each minterm gets a bit position. Predicates become bitvectors: `[a-z]` = bit 0 set, `\w` = bits 0,1,2 set, etc. All boolean operations on predicates are O(1) bitwise ops.

**Character-to-minterm table:**

A flat array mapping each possible character value to its minterm ID:

```
char_to_minterm: [256]u8   // for ASCII mode
```

Typically K ≤ 64, so minterm IDs fit in `u6` and predicate bitvectors fit in `u64`.

### 5.4 Nullability

Nullability determines whether a regex accepts the empty string at a given location. It is context-dependent due to anchors.

```
Null_x(ψ)     = false
Null_x(ε)     = true
Null_x(⊥)     = false
Null_x(R|S)   = Null_x(R) or Null_x(S)
Null_x(R&S)   = Null_x(R) and Null_x(S)
Null_x(R·S)   = Null_x(R) and Null_x(S)
Null_x(R{m})  = m == 0 or Null_x(R)
Null_x(R*)    = true
Null_x(~R)    = not Null_x(R)
Null_x(\A)    = Initial(x)
Null_x(\z)    = Final(x)
```

Each node caches an `always_nullable: bool` flag computed at construction time (ignoring anchor context). This enables fast-path checks without location dependency.

### 5.5 Lookahead Offset Annotations

Lookaheads carry an offset set `I` tracking how many characters ago the match position was when the lookahead was entered:

```
OffsetSet:
    base_offset: u32
    ranges: []Range        // sorted, non-overlapping

Operations:
    increment(I)     → { base_offset + 1, same ranges }     // O(1)
    union(I, J)      → merged ranges with adjusted base      // O(|ranges|)
    min(I)           → base_offset + ranges[0].start          // O(1)
```

For single-match search, only `min(I)` is needed and the set degenerates to a single integer. For all-matches search, the full set is maintained. Contiguous ranges are merged to keep memory compact — a pending match set of 10000 sequential positions is stored as a single range (8 bytes).

## 6. Algorithms

### 6.1 Derivative Computation

The derivative of regex R with respect to minterm m strips one character from R. This is the core operation driving the lazy DFA.

```
δ_m(\A)      = ⊥
δ_m(\z)      = ⊥
δ_m(ε)       = ⊥

δ_m(ψ)       = ε    if minterm m is in bitvector of ψ
               ⊥    otherwise

δ_m(R|S)    = δ_m(R) | δ_m(S)
δ_m(R&S)    = δ_m(R) & δ_m(S)
δ_m(~R)     = ~δ_m(R)

δ_m(R*)     = δ_m(R) · R*
δ_m(R{n})   = δ_m(R) · R{n-1}

δ_m(R·S)    = δ_m(R)·S | δ_m(S)    if Null(R)
               δ_m(R)·S              otherwise

δ_m((?=A)_I) = ⊥                        if Null(A)
                (?=δ_m(A))_{I+1}         otherwise
```

All derivatives are computed symbolically over minterms, not individual characters. For K minterms, each state has at most K outgoing transitions.

The critical property: intersection and complement distribute over derivatives identically to union. No special machinery is needed — `&` and `~` fall out of the same structural recursion.

### 6.2 Lookaround Normal Form (LNF)

Every pattern R ∈ RE# normalizes to `(?<=B)·E·(?=A)` where `A, B, E ∈ ERE`.

**Normalization rules:**

1. Replace negative lookarounds with positive + complement:
   - `(?!S) ≡ (?=~(S·_*)·\z)`
   - `(?<!S) ≡ (?<=\A·~(_*·S))`

2. Merge adjacent lookaheads:
   - `(?=A₁)·(?=A₂) ≡ (?=(A₁·_*) & (A₂·_*))`

3. Merge adjacent lookbehinds:
   - `(?<=B₁)·(?<=B₂) ≡ (?<=(_*·B₁) & (_*·B₂))`

4. Factor intersections:
   - `(?<=B₁)·E₁·(?=A₁) & (?<=B₂)·E₂·(?=A₂)`
   - `≡ (?<=B₁)·(?<=B₂)·(E₁&E₂)·(?=A₁)·(?=A₂)`

5. Apply rules 2-3 to collapse the result.

LNF construction is linear in pattern size.

### 6.3 Rewrite Rules

Applied during node construction (interning) to keep the state space small. These are mandatory for performance, not optional optimizations.

**Identity and annihilator rules:**

```
⊥·R     → ⊥           R·⊥     → ⊥
ε·R     → R            R·ε     → R
~(_*)   → ⊥            ~⊥      → _*
~~R     → R
_*|R    → _*           _*&R    → R
⊥*      → ε
```

**Subsumption rules (within union/intersection sets):**

```
(R₁&R₂)|R₁             → R₁           (sub1)
R₁ ⋄ R₂ ⋄ R₁          → R₁ ⋄ R₂      (dedup, ⋄ ∈ {|, &})
(R₁&(R₂|R₃))|(R₁&R₂)  → R₁&(R₂|R₃)  (sub2)
```

**Factoring:**

```
R₁·R₂ | R₁·R₃  → R₁·(R₂|R₃)      (left factor)
R₁·R₃ | R₂·R₃  → (R₁|R₂)·R₃      (right factor)
```

**Loop simplification:**

```
R{l,m} | R{k,n} → R{l, max(m,n)}   when l ≤ k ≤ m
ψ{0,m} · ψ*     → ψ*                when ⟦ψ_outer⟧ ⊇ ⟦ψ_inner⟧
```

**Character predicate approximation:**

Each node R carries φ_R ∈ Ψ approximating its relevant characters:

```
φ_ψ      = ψ              φ_~R    = ⊤
φ_{L|R}  = φ_L ∨ φ_R      φ_{L&R} = φ_L ∧ φ_R
φ_{R*}   = φ_R             φ_ε     = ⊥
φ_{L·R}  = φ_L ∨ φ_R
```

Used for fast subsumption checks: `⟦φ⟧ ⊆ ⟦ψ⟧` iff `φ ∨ ψ = ψ` (single bitwise OR + compare).

### 6.4 Lazy DFA

States are interned regex nodes. The transition table is built on demand.

```
DFA:
    states: ArrayList(InternedRegex)
    transitions: HashMap((state_id, minterm_id), state_id)
    match_info: HashMap(state_id, MatchInfo)

MatchInfo:
    is_nullable: bool
    offset_set: ?OffsetSet       // for lookahead annotations
    pattern_alive_mask: u64      // which patterns contributed
```

**Transition computation:**

```
fn getTransition(state: u32, minterm: u8) u32:
    if cached: return cached

    regex = states[state]
    derived = computeDerivative(regex, minterm)
    normalized = applyRewriteRules(derived)
    next_id = intern(normalized)
    cache(state, minterm, next_id)
    return next_id
```

**Optional full DFA compilation**: For small patterns (configurable threshold, default ≤100 states), eagerly explore all reachable states to eliminate the lazy-construction branch from the hot path.

### 6.5 Matching Algorithms

#### 6.5.1 MaxEnd — Latest Match End

Scans forward from a start location, tracking the latest position where a match confirmed.

```
MaxEnd(input, start, regex) → match_end or -1:
    state = regex
    match_end = -1

    for i in start..input.len:
        minterm = char_to_minterm[input[i]]
        state = getTransition(state, minterm)

        if state == NOTHING: break

        if has_epsilon(state):
            offsets = get_offsets(state)
            match_end = max(match_end, i - min(offsets))

    // Final location: check \z nullability
    state_at_end = replace_anchor_end_with_epsilon(state)
    if has_epsilon(state_at_end):
        offsets = get_offsets(state_at_end)
        match_end = max(match_end, input.len - min(offsets))

    return match_end
```

#### 6.5.2 LLMatch — Leftmost-Longest Single Match

Bidirectional scan for POSIX semantics.

```
LLMatch(input, R = (?<=B)·E·(?=A)) → span or null:
    // Phase 1: Reverse scan to find leftmost start
    R_rev = reverse(R)
    k = MaxEnd(reversed_input, 0, R_rev)

    if k == -1: return null

    // Phase 2: Forward scan to find longest end
    start = input.len - k
    end = MaxEnd(input, start, E·(?=A))

    return Span{ .start = start, .end = end }
```

#### 6.5.3 LLMatches — All Non-Overlapping Matches

Generalization using AllEnds which collects the full offset set instead of just the minimum.

```
LLMatches(input, R = (?<=B)·E·(?=A)) → []Span:
    R_rev = reverse(R)

    // Collect all possible start indices via reverse scan
    all_starts = sort(input.len - each(AllEnds(reversed_input, 0, R_rev)))

    results = []
    i = 0
    while i < all_starts.len:
        start = all_starts[i]
        end = MaxEnd(input, start, E·(?=A))
        results.append(Span{ .start = start, .end = end })

        // Skip overlapping starts
        i += 1
        while i < all_starts.len and all_starts[i] < end: i += 1

    return results
```

### 6.6 Reversal

Regex reversal is structural, no input copying:

```
reverse(ψ)      = ψ              reverse(ε)     = ε
reverse(R|S)    = rev(R)|rev(S)  reverse(R&S)   = rev(R)&rev(S)
reverse(~R)     = ~rev(R)        reverse(R*)    = rev(R)*
reverse(R·S)    = rev(S)·rev(R)  reverse(R{m})  = rev(R){m}
reverse((?=R))  = (?<=rev(R))    reverse((?<=R))= (?=rev(R))
reverse((?!R))  = (?<!rev(R))    reverse((?<!R))= (?!rev(R))
```

Reversal is size-preserving and involutive: `reverse(reverse(R)) = R`.

Input is never physically reversed. The reverse scan reads input backwards using index arithmetic, with the reversed regex providing the reversed DFA.

## 7. Literal Extraction and Prefilter

### 7.1 Breadth-First Derivative Exploration

Starting from the initial regex node, compute symbolic derivatives for each minterm. When exactly one minterm leads to a non-dead state, that minterm corresponds to a required character or character class. If that surviving minterm maps to a single character, it is a required literal byte.

```
extractLiterals(regex) → []LiteralString:
    results = []
    queue = [(regex, current_prefix=[])]

    while queue not empty:
        (node, prefix) = queue.pop()

        survivors = []
        for m in 0..num_minterms:
            d = derivative(node, m)
            if d != NOTHING:
                survivors.append((m, d))

        if survivors.len == 1:
            (m, next) = survivors[0]
            if minterm_is_single_char(m):
                queue.push((next, prefix ++ [minterm_char(m)]))
            else:
                if prefix.len > 0: results.append(prefix)
        else:
            if prefix.len > 0: results.append(prefix)
            // Continue exploring for interior literals (bounded depth)
```

Interior literal extraction follows the same principle: look for sequences of single-survivor states anywhere in the derivative graph.

**Interaction with boolean operators:**

- Intersection preserves literals: `P & Q` requires literals from P AND Q.
- Complement destroys literals: `~(_*foo_*)` has no extractable required literal for the match itself, but when used in `P & ~Q`, P's literals still apply.
- Union weakens literals: `P | Q` only requires common prefixes. For multi-string search this doesn't matter — feed all literals to Teddy.

### 7.2 Teddy SIMD Prefilter

Teddy uses PSHUFB-based nibble table lookups for parallel multi-string candidate detection.

**Core idea:** Split each byte into lo nibble (4 bits) and hi nibble (4 bits). Build two 16-entry lookup tables mapping nibble values to pattern bitmasks. PSHUFB performs 16 parallel table lookups in one instruction. AND the lo and hi results to get full-byte candidate matches for 16 input positions simultaneously.

**Table construction:**

```
for each pattern i (bucket bit = 1 << i):
    for each fingerprint byte position p:
        byte = literal[i][p]
        lo_tables[p][byte & 0x0F] |= bucket_bit
        hi_tables[p][byte >> 4]   |= bucket_bit
```

**Scan loop (single-byte fingerprint, 128-bit SIMD):**

```zig
fn teddyScan(input: []const u8, lo: @Vector(16,u8), hi: @Vector(16,u8)) void {
    const mask_0f: @Vector(16, u8) = @splat(0x0F);
    var pos: usize = 0;

    while (pos + 16 <= input.len) {
        const chunk: @Vector(16, u8) = input[pos..][0..16].*;
        const lo_nibbles = chunk & mask_0f;
        const hi_nibbles = (chunk >> @as(@Vector(16, u8), @splat(4))) & mask_0f;

        const lo_result = @shuffle(u8, lo, undefined, lo_nibbles);
        const hi_result = @shuffle(u8, hi, undefined, hi_nibbles);
        const candidates = lo_result & hi_result;

        if (@reduce(.Or, candidates) != 0) {
            emitCandidates(pos, candidates);
        }
        pos += 16;
    }
}
```

For 2-byte and 3-byte fingerprints, compute match masks for each byte position and combine with shift+AND to align.

**Scaling**: One byte bitmask = 8 patterns per bucket. Patterns sharing fingerprint bytes share buckets. With AVX2, process 32 bytes per iteration. With AVX-512, 64 bytes.

### 7.3 Candidate Verification

For each Teddy candidate at position `p` with bucket mask `B`:

1. Determine which patterns in bucket `B` could match (literal prefix memcmp).
2. Determine the DFA verification window around `p` (derived from pattern structure at compile time, bounded by natural boundaries for single-line patterns).
3. Run Phase 2 DFA (bidirectional LLMatch) on the windowed input.
4. Record match span with pattern ID annotation.

## 8. Multi-Pattern Support

### 8.1 Pattern Composition

All user patterns compile into a single top-level regex:

```
ComposedPattern = (P₁ | P₂ | ... | Pₙ) & GlobalExclude₁ & GlobalExclude₂ & ...
```

Global exclusions apply to all patterns uniformly, baked into the automaton.

### 8.2 Pattern Identity Tracking

**Approach A — Structural disambiguation (preferred for most patterns):**

When patterns have structurally unique prefixes, pattern identity is determined post-match by inspecting matched bytes. A trie or switch on the first few bytes maps to pattern ID. No additional DFA state space required.

**Approach B — DFA-level tracking (for ambiguous patterns):**

The DFA state incorporates a pattern-alive bitset:

```
DFA state key = (normalized_regex_id, alive_pattern_mask: u64)
```

This expands state space but ensures each match reports exactly which patterns contributed. Used only for the subset of patterns that are structurally ambiguous.

### 8.3 Annotation Metadata

Each pattern carries user-defined metadata that flows through to match results:

```
PatternDef:
    id: []const u8              // "http_url"
    regex: []const u8            // the RE# pattern string
    category: []const u8         // "network"
    severity: enum { low, medium, high, critical }
    // Additional fields as needed by consumers
```

rez treats this as opaque metadata attached to pattern IDs.

## 9. Cross-Newline Matching

### 9.1 The `_` vs `.` Distinction

- `.` matches any character except `\n` (standard single-line semantics)
- `_` matches any character including `\n`

These are distinct minterms. The DFA handles newline-crossing behavior automatically through the minterm partition.

### 9.2 Strategies by Case

**Line continuations (backslash-newline):** Preprocess input to strip `\\\n` sequences, maintaining a position mapping for span translation.

**Envelope / delimited blocks:** Match envelope markers via lookbehind/lookahead with `_*` crossing newlines. The markers are the Teddy prefilter literals.

**Paragraph-bounded matching:** Use `~(_*\n\n_*)` (does not contain double newline) to constrain matches to within a single paragraph/log entry.

**Multi-line values:** `_*` in lookbehind/lookahead crosses newlines freely. Key-value patterns like `(?<=api.key_*[=:]_*['"]?)` handle the intervening whitespace and line breaks.

### 9.3 Window Sizing

At compile time, the derivative engine determines whether a pattern uses `_` (newline-crossing) or only `.` (single-line). Phase 2 verification window is sized accordingly: bounded by nearest newlines for single-line patterns, wider for cross-line patterns.

## 10. Implementation Plan

### Phase 1: Core Derivative Engine

Implement on plain ERE (no lookarounds, no boolean operators beyond union).

1. Regex parser (character classes, quantifiers, union, concatenation)
2. Node interning arena with hash-consing
3. Minterm computation from collected predicates
4. Nullability check
5. Derivative computation over minterms
6. Basic rewrite rules (identity, annihilator, double negation)
7. Lazy DFA matching loop (forward-only MaxEnd)
8. **Milestone**: single-pattern forward matching, benchmarkable against existing AC and hand-rolled parsers

### Phase 2: Minterm Optimization

1. Full minterm partition algorithm
2. Character-to-minterm lookup table generation
3. Predicate bitvector representation
4. Extended rewrite rules (subsumption, factoring, predicate approximation φ_R)
5. **Milestone**: significant state-space reduction on complex patterns

### Phase 3: Boolean Operators

1. Intersection (`&`) — distributes over derivatives identically to union
2. Complement (`~`) — distributes over derivatives: `δ(~R) = ~δ(R)`
3. Sorted set representation for union/intersection children
4. Commutativity/associativity/idempotence normalization
5. **Milestone**: composed patterns with `&` and `~`, demonstrating single-pass multi-constraint matching

### Phase 4: Lookarounds and Bidirectional Matching

1. LNF normalization
2. Lookahead offset annotations (`(?=A)_I`)
3. Reverse regex construction
4. Bidirectional LLMatch algorithm
5. AllEnds for all-matches search
6. **Milestone**: full POSIX leftmost-longest matching with context-aware patterns

### Phase 5: Teddy Prefilter

1. Literal extraction via BFS derivative exploration
2. Teddy table construction (1/2/3-byte fingerprints)
3. SIMD scan loop using Zig `@Vector`/`@shuffle`
4. Candidate-to-DFA handoff with windowed verification
5. **Milestone**: full two-phase pipeline, benchmarkable end-to-end

### Phase 6: Multi-Pattern and Public API

1. Pattern database format and loading
2. Multi-pattern composition (union + global excludes)
3. Pattern identity tracking (structural + DFA-level)
4. Annotation metadata pass-through
5. Public API surface
6. **Milestone**: usable as a library by downstream tools

## 11. API Surface (Preliminary)

```zig
const rez = @import("rez");

// Compile patterns
const db = try rez.compile(allocator, &.{
    .{ .id = "http_url",
       .pattern = "\\bhttps?://[^\\s]{10,200}\\b",
       .category = "network" },
    .{ .id = "ipv4_addr",
       .pattern = "\\b[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\b",
       .category = "network" },
    .{ .id = "log_error",
       .pattern = "(?<=_*(ERROR|FATAL)_*[:]_*)\\b[!-~]{1,200}\\b",
       .category = "diagnostics" },
}, .{
    .global_excludes = &.{ "~(_*example_*)", "~(_*TODO_*)" },
    .full_dfa_threshold = 100,
});
defer db.deinit();

// Scan input — all non-overlapping matches
var matches = db.findAll(input_bytes);
defer matches.deinit();

while (matches.next()) |match| {
    const span = input_bytes[match.start..match.end];
    const pattern = db.getPattern(match.pattern_id);
    // pattern.id, pattern.category, etc.
}

// Single match — leftmost-longest
if (db.findFirst(input_bytes)) |match| {
    // ...
}

// Boolean check — fastest path, no position tracking
if (db.isMatch(input_bytes)) {
    // ...
}
```

## 12. Testing, Fuzzing, and Safety

A derivative-based engine with complement and intersection has a larger attack surface than a standard regex engine. Complement inverts the state space, intersection multiplies it, and lookarounds encode unbounded context. All three can interact to produce state explosions that look innocuous in the pattern but blow up at runtime. Testing must cover correctness, performance safety, and adversarial resistance.

### 12.1 Correctness Test Vectors

**Per-phase unit tests** — each implementation phase gets its own test suite that runs independently:

**Phase 1 (ERE basics):**

| Pattern | Input | Expected |
|---------|-------|----------|
| `abc` | `"xabcy"` | match `[1,4)` |
| `a\|b` | `"b"` | match `[0,1)` |
| `[a-z]+` | `"Hello"` | match `[1,5)` |
| `a{3,5}` | `"aaaaaa"` | match `[0,5)` (leftmost-longest, capped at 5) |
| `a*` | `""` | match `[0,0)` (empty match) |
| `\bword\b` | `"a word here"` | match `[2,6)` |
| `.+` | `"line1\nline2"` | match `[0,5)` (stops at newline) |
| `_+` | `"line1\nline2"` | match `[0,11)` (crosses newline) |

**Phase 2 (minterms):**

| Predicates | Expected minterms |
|------------|-------------------|
| `[a-z]` alone | 2 minterms: lowercase, everything else |
| `[a-z]`, `[0-9]` | 3 minterms: lowercase, digits, other |
| `[a-z]`, `\w` | 3 minterms: lowercase, other-word-chars, non-word |
| `.`, `_` | 2 minterms: non-newline, newline (`.` = `¬\n`, `_` = `⊤`) |

Verify: every character maps to exactly one minterm. Verify: predicate bitvector ops produce correct set membership.

**Phase 3 (boolean operators):**

| Pattern | Input | Expected |
|---------|-------|----------|
| `_*cat_*&_*dog_*` | `"the cat and dog"` | match (entire string) |
| `_*cat_*&_*dog_*` | `"the cat"` | no match |
| `~(_*bad_*)` | `"all good"` | match |
| `~(_*bad_*)` | `"too bad"` | no match |
| `[a-z]+&~(foo)` | `"foo"` | no match |
| `[a-z]+&~(foo)` | `"bar"` | match `[0,3)` |
| `_*a_*&_*b_*&_{5,10}` | `"ab"` | no match (too short) |
| `_*a_*&_*b_*&_{5,10}` | `"a___b"` | match |

**Algebraic identity tests** — verify that equivalent rewrites produce identical match sets:

```
R|S           ≡ S|R                    (union commutativity)
R&S           ≡ S&R                    (intersection commutativity)
~~R           ≡ R                      (double negation)
~(R|S)        ≡ ~R & ~S               (De Morgan)
~(R&S)        ≡ ~R | ~S               (De Morgan)
(R|S)&T       ≡ (R&T)|(S&T)           (distributivity)
R&~R          ≡ ⊥                      (contradiction)
R|~R          ≡ _*                     (excluded middle on full strings)
```

For each identity, generate random inputs and verify both sides produce the same match spans. This is a property-based test, not a fixed-vector test.

**Phase 4 (lookarounds):**

| Pattern | Input | Expected |
|---------|-------|----------|
| `(?<=a)b` | `"ab"` | match `[1,2)` |
| `(?<=a)b` | `"cb"` | no match |
| `(?<!a)b` | `"cb"` | match `[1,2)` |
| `(?<!a)b` | `"ab"` | no match |
| `a(?=b)` | `"ab"` | match `[0,1)` |
| `a(?!b)` | `"ac"` | match `[0,1)` |
| `(?<=_*key_*[=:])_*[a-z]{8}` | `"key=abcdefgh"` | match `[4,12)` |
| `(?<=Valid~(_*Invalid_*)).+@.+` | (see §4.2 email example) | matches only Valid section |

**Bidirectional match tests:**

| Pattern | Input | Expected |
|---------|-------|----------|
| `(a\|ab)+` | `"aababaabab"` | match `[0,10)` (entire string, POSIX) |
| `a+` | `"aaa"` | match `[0,3)` (longest) |
| `a\|ab` | `"ab"` | match `[0,2)` (longest, not leftmost-first) |

These specifically verify POSIX leftmost-longest, not PCRE leftmost-greedy. The `(a|ab)+` case is the litmus test — PCRE returns 4 matches, POSIX returns 1.

### 12.2 Real-World Pattern Test Suite

Realistic multi-pattern test scenarios using common search patterns, tested against synthetic inputs:

```
Test corpus structure:
  tests/patterns/
    urls/
      patterns.rez          # http/https URLs, mailto:, ftp://, etc.
      true_positives.txt    # valid URLs in realistic contexts
      false_positives.txt   # strings that look similar but are not URLs
      edge_cases.txt        # URLs split across lines, in JSON, quoted, etc.
    structured_data/
      patterns.rez          # IP addresses, dates, phone numbers, emails
      ...
    log_formats/
      patterns.rez          # ERROR/WARN/INFO context patterns
      ...
    combined/
      all_patterns.rez      # full multi-pattern union + global excludes
      mixed_corpus.txt      # input with multiple pattern types interleaved
      expected_matches.json # ground truth spans with pattern IDs
```

Each pattern family gets true-positive, false-positive, and edge-case files. The combined test runs the full multi-pattern pipeline and verifies pattern ID attribution.

### 12.3 ReDoS and Pathological Pattern Safety

The derivative-based architecture is inherently immune to classical ReDoS (no backtracking), but has its own failure modes:

**State explosion tests** — patterns designed to maximize DFA state count:

```
# Exponential state blowup in standard DFA construction
.{0,100}a.{0,100}         # 10000+ states naively, but lazy DFA amortizes
(a|b){1,20}               # 2^20 states if fully expanded
[a-z]{1,15}&[0-9]{1,15}   # intersection of counted ranges
```

For each: measure state count, verify it stays below the configurable threshold. If it exceeds the threshold, verify the engine either falls back gracefully or errors cleanly — never OOMs or hangs.

**Complement blowup tests:**

```
~(a{100})                  # complement of a very specific pattern
~(.*a.*b.*c.*d.*e.*)       # complement of a "contains all of" pattern
~(_*\n\n_*)&.{0,10000}    # paragraph constraint on long input
```

Complement inverts the state space. A pattern with 5 states can produce a complement with exponentially more reachable derivative states. Test that the rewrite rules (§6.3) keep this manageable, and that the state count limit catches the rest.

**Lookahead context explosion:**

```
a(?=.{0,10000}b)           # lookahead with long context window
(?<=.{0,10000}a)b          # lookbehind with long context window
a(?=.*b)(?=.*c)(?=.*d)     # multiple intersected lookaheads
```

The offset set in lookahead annotations can grow large if the context window is unbounded. Verify that the range-merging representation (§5.5) keeps memory bounded — 10000 sequential offsets should be one range, not 10000 integers.

**Mandatory safety limits (configurable, with sensible defaults):**

| Parameter | Default | Purpose |
|-----------|---------|---------|
| `max_dfa_states` | 10,000 | Hard cap on lazy DFA state count |
| `max_pattern_size` | 10,000 nodes | Reject patterns that parse to huge ASTs |
| `max_minterm_count` | 64 | Keep predicate bitvectors in u64 |
| `max_lookahead_context` | 10,000 | Bound offset set growth |
| `compile_timeout_ms` | 5,000 | Abort compilation if derivative exploration takes too long |

When any limit is hit, rez returns a compile error with a diagnostic explaining which limit was exceeded and by which pattern. Never silently degrade.

### 12.4 Performance Regression Benchmarks

A fixed benchmark suite that runs in CI on every change, tracking throughput (bytes/sec) and state count:

**Microbenchmarks (per-component):**

| Benchmark | What it measures |
|-----------|-----------------|
| `bench_minterm_lookup` | char→minterm table lookup throughput |
| `bench_derivative_simple` | derivative computation on `[a-z]+` |
| `bench_derivative_boolean` | derivative computation on `P&Q&~R` |
| `bench_dfa_transition` | cached DFA transition lookup |
| `bench_dfa_construction` | lazy state construction per new state |
| `bench_teddy_scan_sparse` | Teddy on input with rare matches |
| `bench_teddy_scan_dense` | Teddy on input with frequent matches |
| `bench_rewrite_rules` | normalization throughput |

**End-to-end benchmarks (realistic workloads):**

| Benchmark | Pattern | Input | What it stresses |
|-----------|---------|-------|------------------|
| `bench_url_extract` | HTTP URL pattern | 10MB of mixed log data with ~100 URLs | Teddy prefilter effectiveness |
| `bench_short_prefix` | 4-char prefix pattern | 10MB of config files | Short prefix, many false Teddy hits |
| `bench_context_match` | context-dependent pattern | 10MB of source code | Lookbehind + intersection |
| `bench_multi_800` | 800 patterns unioned | 10MB mixed corpus | Full pipeline, pattern disambiguation |
| `bench_envelope` | envelope lookbehind/lookahead | 10MB of structured data | Cross-newline matching |
| `bench_exclusion_heavy` | Patterns with 10 `~(_*X_*)` clauses | 10MB of test output | Complement impact on state space |
| `bench_quadratic` | Known quadratic-behavior patterns | Scaling input sizes | Verify near-linear scaling |
| `bench_all_matches_dense` | `\w+` on English text | 1MB | Many overlapping match starts |

**Scaling benchmarks** — same pattern, increasing input size (1KB, 10KB, 100KB, 1MB, 10MB, 100MB). Plot throughput vs size. Any sub-linear throughput trend indicates a problem. The quadratic benchmark specifically tracks the all-matches case which the paper acknowledges can be O(n²) in the worst case.

**Comparison benchmarks** — run the same patterns against other regex implementations to verify rez is competitive. Not a gate (rez may be slower on pure-literal patterns), but a tracking metric.

### 12.5 Fuzzing

Yes, fuzzing is essential. The derivative engine is a compiler — it transforms arbitrary user-supplied patterns into state machines. Any compiler that accepts untrusted input needs fuzzing.

**Fuzz target 1: Pattern compilation (most critical)**

Feed random byte sequences as regex pattern strings. Verify:
- No crashes, no OOM, no infinite loops
- Either a valid compiled database is returned, or a clean parse/compile error
- State count stays within configured limits
- Compilation completes within timeout

This is the highest-priority fuzz target because patterns come from user-authored config files. A malformed or adversarial pattern must never bring down the engine.

**Fuzz target 2: Matching (compiled pattern + random input)**

Take a set of known-good compiled patterns and feed random byte sequences as input. Verify:
- No crashes
- Every returned span is within input bounds
- Match spans are non-overlapping and left-to-right ordered
- `isMatch` agrees with `findFirst` (if one returns true/non-null, so does the other)
- `findAll` results are a superset of `findFirst` result

**Fuzz target 3: Algebraic identity oracle**

Generate random pattern pairs that are algebraically equivalent (using De Morgan's laws, double negation, distribution, etc.). Run both on the same random input. Verify identical match results. This catches bugs in rewrite rules and normalization.

```
Strategy:
1. Generate random ERE pattern R
2. Apply random algebraic transformation to get R' (known equivalent)
3. Compile both
4. Run both on random input
5. Assert identical match spans
```

Transformations to apply randomly:
- `R → ~~R`
- `R|S → S|R`
- `R&S → S&R`
- `~(R|S) → ~R & ~S`
- `~(R&S) → ~R | ~S`
- `(R|S)&T → (R&T)|(S&T)`
- `R&R → R`
- `R|R → R`

**Fuzz target 4: Reversal oracle**

For random pattern R and random input s, verify that `LLMatch(s, R)` produces a span at position `[i,j)` if and only if `LLMatch(reverse(s), reverse(R))` produces a span at the corresponding reversed position. This validates the reversal implementation and the bidirectional matching.

**Fuzz target 5: Teddy prefilter consistency**

For random input and patterns, verify that every match found by the full DFA (without prefilter) is also found when Teddy is enabled. Teddy must never cause a miss — it can produce false candidates (verified and rejected by DFA) but never false negatives.

**Fuzz infrastructure:**

Use Zig's built-in fuzz testing (`std.testing.fuzz`). Define fuzz entry points as standard test functions that accept `[]const u8` input. Zig's fuzzer provides coverage-guided mutation out of the box.

For the algebraic identity oracle, a custom mutator generates structured pattern pairs rather than raw bytes — random byte mutation is unlikely to produce syntactically valid patterns paired with their algebraic equivalents.

Fuzz targets 1 and 2 run in CI continuously. Targets 3-5 run in longer nightly fuzzing sessions.

### 12.6 Lean Cross-Validation (Optional)

The RE# paper includes a Lean proof assistant formalization of ERE≤ semantics that is executable (Zhuchko et al. 2024). For high-confidence correctness on a curated test suite, export rez's match results and compare against the Lean reference implementation. This is expensive (Lean evaluation is slow) and only practical for small inputs, but provides a mathematically verified oracle that no amount of fuzzing can replicate.

This is optional and deferred — useful once the core engine is stable, not during initial development.

## 13. References

1. Varatalu, I.E., Veanes, M., Ernits, J-P. "RE#: High Performance Derivative-Based Regex Matching with Intersection, Complement and Restricted Lookarounds." POPL 2025. arXiv:2407.20479. https://arxiv.org/abs/2407.20479
2. Varatalu, I.E. "RE#: how we built the world's fastest regex engine in F#." Blog post, Feb 2026. https://iev.ee/blog/resharp-how-we-built-the-fastest-regex-in-fsharp/
3. Moseley, E. et al. "Derivative Based Nonbacktracking Real-World Regex Matching with Backtracking Semantics." PLDI 2023.
4. Brzozowski, J.A. "Derivatives of Regular Expressions." JACM 1964.
5. Owens, S., Reppy, J.H., Turon, A. "Regular-expression Derivatives Re-examined." JFP 2009.
6. Qiu, K. et al. "Teddy: An Efficient SIMD-based Literal Matching Engine for Scalable Deep Packet Inspection." ICPP 2021.
7. BurntSushi. aho-corasick Teddy implementation. https://github.com/BurntSushi/aho-corasick/blob/master/src/packed/teddy/README.md
8. ieviev. resharp-dotnet source. https://github.com/ieviev/resharp-dotnet
