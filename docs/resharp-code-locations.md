# RE# Source Code Locations - Quick Reference

## Main Implementation Files

### Core Algorithm & Optimization Logic

| Optimization | File | Lines | Key Classes/Functions |
|-------------|------|-------|----------------------|
| **Start-Set Optimization** | `Optimizations.fs` | 628-761 | `findInitialOptimizations`, `calcPrefixSets`, `applyPrefixSets` |
| **Prefix Acceleration** | `Accelerators.fs` | 1-62 | `trySkipToWeightedSetCharRev` |
| **Derivative Computation** | `Algorithm.fs` | 117-289 | `RegexNode.derivative`, caching via `transitions` dict |
| **Lazy DFA & State Management** | `Regex.fs` | 78-432 | `RegexMatcher<'t>`, `_getOrCreateState` |
| **State Caching & Growth** | `Regex.fs` | 84-216 | `_stateArray`, `replaceWithPooled`, dynamic resizing |
| **Minterm Representation** | `Minterms.fs` | 142-152 | `createLookupUtf16`, `Minterms.compute` |
| **Minterm Lookup** | `Cache.fs` | 225-236 | `CharToMintermId`, `MintermClassifier` |
| **Full DFA Precompilation** | `Optimizations.fs` | 433-532 | `attemptCompileFullDfa` (backward & forward reachability) |
| **Nullability & Flags** | `Types.fs` | 24-80 | `NullKind`, `SkipKind`, `StateFlags` |
| **Potential Start Set** | `Optimizations.fs` | 329-431 | `calcPotentialMatchStart`, recursive state expansion |
| **SearchValues Integration** | `Cache.fs` | 75-143 | `MintermSearchValues<'t>`, commonality scoring |
| **Right-to-Left Matching** | `Regex.fs` | 318-412 | `reverseNode`, `reverseTrueStarredNode`, `utf16Optimizations` |
| **Match Accumulation** | `Regex.fs` | 599-707 | `HandleInputEnd`, `HandleInputStart`, nullable handling |

### Supporting Infrastructure

| Component | File | Lines | Purpose |
|-----------|------|-------|---------|
| **Configuration Options** | `Common.fs` | 14-62 | `ResharpOptions`, HighThroughputDefaults, SingleUseDefaults |
| **State Metadata** | `Cache.fs` | 146-249 | `RegexCache<'t>`, minterm lookup, state creation |
| **Inline IL Optimizations** | `Optimizations.fs` | 43-92 | `Inline` module, direct IL emission (ldelem.u1, shl, clt.un) |
| **Matching Loops** | `Regex.fs` | 717-859 | `end_first`, `end_lazy`, `end_noskip`, hot loop implementations |
| **Transition Table** | `Regex.fs` | 97-103 | `_dfaDelta`, `_revStartStates`, layout: `(stateId << log2(minterms)) | mintermId` |
| **Skip Acceleration** | `Regex.fs` | 863-899 | `TrySkipInitialRevChar`, startset-based skipping |
| **Thread Safety** | `Regex.fs` | 105, 184-196 | `_rwlock: ReaderWriterLockSlim`, double-checked locking |

---

## Benchmark Infrastructure

### Test Definition & Execution

| Component | File | Location |
|-----------|------|----------|
| **Benchmark Harness** | `RebarBench.cs` | src/Resharp.Benchmarks/ |
| **Test Data Loader** | `RebarData.cs` | src/Resharp.Benchmarks/ |
| **Engine Configuration** | `engines.toml` | src/Resharp.Benchmarks/benchmarks/ |
| **Benchmark Definitions** | `*.toml` | src/Resharp.Benchmarks/benchmarks/definitions/{curated,resharp}/ |
| **Benchmark Data** | haystacks/ | src/Resharp.Benchmarks/benchmarks/haystacks/ |
| **Patterns** | regexes/ | src/Resharp.Benchmarks/benchmarks/regexes/ |

### Benchmark Examples

| Name | File | Patterns | Input | Expected Speedup |
|------|------|----------|-------|------------------|
| Date Dictionary | `01-date-dictionary.toml` | date extraction (12+ patterns) | rust-src (10k lines) | 158x |
| Dictionary Search | `01-date-dictionary.toml` | 12-word dictionary | length-15-sorted.txt | 252x |
| Monster Pattern | `02-monster.toml` | Complex multi-pattern | Large corpus | 10-50x |
| Unicode Sets | `05-sets-and-unicode.toml` | Unicode categories | UTF-8 text | 5-20x |
| Lookarounds | `08-lookarounds-other.toml` | Complex lookarounds | Mixed | 3-10x |

---

## Data Structure Layouts

### Memory-Efficient State Arrays (SoA Pattern)

```
_stateArray[i]       MatchState<'t>           // Node + pending nullables
_flagsArray[i]       StateFlags               // IsAlwaysNullable, CanSkip, etc. (1 byte)
_nullKindArray[i]    NullKind                 // NotNull, CurrentNull, PrevNull, etc. (1 byte)
_skipKindArray[i]    SkipKind                 // SkipInitial, SkipActive, NotSkip (1 byte)
_svArray[i]          MintermSearchValues<'t>  // Startset for vectorized scanning

_dfaDelta            TState[]                 // Delta table
  Index = (stateId << _mintermsLog) | mintermId
  Typical: 1000 states × 16 minterms × 4 bytes = 64 KB

_mtlookup            TMinterm[]               // Char to minterm mapping
  65536 entries (UTF-16) × 1 byte = 64 KB

_revStartStates      TState[]                 // Anchor-dependent transitions
  Index = (stateId << _mintermsLog) | mintermId
```

---

## Key Constants & Defaults

### From `Common.fs` (ResharpOptions)

```fsharp
InitialDfaCapacity = 2048          // Default starting state capacity
MaxDfaCapacity = 100_000            // Hard limit to prevent explosion
MaxPrefixLength = 20                // Max characters to extract as prefix
FindPotentialStartSizeLimit = 200   // Limit expansion of potential start sets
DfaThreshold = 100                  // States before abandoning full DFA compilation
StartsetInferenceLimit = 2000       // Limit startset computation
```

### From `Types.fs` (State Representation)

```fsharp
type NullKind =
    | NotNull = 255uy              // Cannot match empty string
    | CurrentNull = 0uy            // Matches at position 0
    | PrevNull = 1uy               // Matches at position -1 (anchors)
    | Nulls01 = 2uy                // Special case {0,1}
    | PendingNull = 4uy            // Lookaround pending

type SkipKind =
    | NotSkip = 255uy              // Cannot skip with accelerator
    | SkipInitial = 0uy            // Initial state skip logic
    | SkipActive = 1uy             // Active state skip logic

// StateFlags is 8-bit field (all fitted in 1 byte!)
InitialFlag, CanSkipFlag, IsAlwaysNullableFlag, 
IsAnchorNullableFlag, IsEndNullableFlag, IsBeginNullableFlag, etc.
```

---

## Critical Hot Loops

### Right-to-Left Matching (`end_lazy`, `Regex.fs` lines 754-812)

```fsharp
// Hot loop structure:
while currentStateId <> States.DFA_DEAD do
    if StateFlags.canSkipLeftToRight _flagsArray[currentStateId] then
        // SIMD acceleration: IndexOfAny to find next interesting position
        match MintermSearchValues.nextIndexLeftToRight(_svArray[...], input.Slice(...)) with
        | -1 -> reached_end
        | si -> skip ahead by si characters
    else
        // Regular transition
        let nextStateId = I.nextStateId _dfaDelta currentStateId mt_log _mtlookup input l_pos
        // If cache miss, compute derivative on-demand
        if nextStateId = 0 then
            derivative computation
        
        l_pos <- l_pos + 1
```

### Left-to-Right Matching (`end_first`, `Regex.fs` lines 718-751)

Similar structure but without skip optimization (finding match end).

---

## Data Files & Benchmarks

### Benchmark Organization

```
src/Resharp.Benchmarks/
├── RebarBench.cs                                    # Main benchmark class
├── RebarData.cs                                     # Data loading
├── SourceGenRegexes.g.cs                           # Source-generated regex (optional)
├── benchmarks/
│   ├── engines.toml                                # Engine definitions (30+ engines)
│   ├── definitions/
│   │   ├── curated/                                # Real-world patterns
│   │   │   ├── 08-words.toml
│   │   │   ├── 09-patterns.toml
│   │   │   └── ...
│   │   └── resharp/                                # RE#-specific benchmarks
│   │       ├── 01-date-dictionary.toml             # Date extraction + dictionary
│   │       ├── 02-monster.toml                     # Complex single pattern
│   │       ├── 02-monster-multi.toml               # Multiple complex patterns
│   │       ├── 05-sets-and-unicode.toml            # Unicode handling
│   │       ├── 06-lookbehind-context.toml          # Lookarounds
│   │       ├── 07-long-matches.toml                # Extended matching
│   │       ├── 08-lookarounds-other.toml           # More lookarounds
│   │       └── 09-hidden-passwords.toml            # Password patterns
│   ├── haystacks/                                  # Input test data
│   │   ├── rust-src-tools-3b0d4813.txt             # Real Rust source code
│   │   ├── resharp/length-15-sorted.txt            # Dictionary input
│   │   └── ...
│   └── regexes/                                    # Pattern definitions
│       ├── resharp/
│       │   ├── date-fixed.txt
│       │   ├── dictionary-fixed.txt
│       │   └── ...
│       └── ...
```

### Sample TOML Benchmark Definition

```toml
[[bench]]
model = "count-spans"                                # Match counting model
name = "date"                                        # Benchmark ID
regex = { path = "resharp/date-fixed.txt" }         # Pattern file
case-insensitive = true                             # Options
haystack = { path = "rust-src-tools-3b0d4813.txt",  # Input file
             line-start = 190_000,                  # Extract range
             line-end = 200_000 }
count = [                                           # Expected match counts
  { engine = 'dotnet/compiled|icu|java/hotspot|javascript/v8|resharp', 
    count = 110784 },
  { engine = '.*', count = 110_800 },
]
engines = [                                         # Engines to test
  'dotnet/compiled', 'resharp', 'icu', 'java/hotspot',
  'pcre2', 'pcre2/jit', 'python/re', 'python/regex',
  'regress', 'rust/regex', 'rust/regexold',
]
analysis = '''
Detailed benchmark description and analysis goes here.
'''
```

---

## F# to C# Interface

### Public API (`Regex.Public.fs`)

```fsharp
// Compiler-generated public interface for C# usage
new Resharp.Regex(pattern: string, options: ResharpOptions)

// Matching methods
IsMatch(input: string): bool
Match(input: string): SingleMatchResult
Matches(input: string): MatchResult[]
Count(input: string): int

// Value-based (allocation-free)
ValueMatches(input: ReadOnlySpan<char>): IDisposable<ValueList<ValueMatch>>
llmatch_count(input: ReadOnlySpan<char>): int

// Replace
Replace(input: string, replacement: string): string
Replace(input: string, replacementPattern: Func<string, string>): string
```

---

## Key Insights from Code Structure

1. **F# for symbolic computation**: Core algorithm (Algorithm.fs, Optimizations.fs) is pure functional F#
2. **C# for performance-critical code**: Hot loops and API are C# (Regex.fs)
3. **Memory layout is explicit**: Not relying on GC; using ArrayPool and manual memory management
4. **Separation of concerns**: 
   - Compilation (symbolic): one-time, can be slow
   - Matching (scanning): must be extremely fast
5. **Testability**: TOML-based benchmarks make it easy to add new patterns without code changes

---

## How to Adopt These Techniques

### Minimal viable set:
1. Read `Optimizations.fs` (lines 628-761) for prefix extraction
2. Read `Accelerators.fs` for weighted reverse search
3. Read `Regex.fs` (lines 754-812) for hot loop structure
4. Implement minterm computation (Minterms.fs, lines 136-141)
5. Implement DFA delta table (Regex.fs, line 98)

### Medium effort:
- Add state flags encoding (Types.fs)
- Add SearchValues integration (Cache.fs)
- Add lazy state generation with caching

### Full implementation:
- All of the above
- Thread safety with ReaderWriterLockSlim
- Memory pooling with ArrayPool
- Potential start set fallback
- Full DFA precompilation threshold

