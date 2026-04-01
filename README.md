# rez

A regex engine built on [Brzozowski derivatives](https://en.wikipedia.org/wiki/Brzozowski_derivative), written in Zig. No backtracking, no ReDoS — O(n) matching guaranteed.

## Features

**Supported syntax** (ERE):
- Literals, `.` (any except newline), `_` (any byte)
- Character classes: `[abc]`, `[^a-z]`, `\d`, `\w`, `\s` (and negations)
- Quantifiers: `*`, `+`, `?`, `{n}`, `{n,}`, `{n,m}`
- Alternation `|`, grouping `()`
- Anchors: `^` / `\A` (start), `$` / `\z` (end)
- Escapes: `\n`, `\t`, `\x{FF}`

**Not yet supported:** word boundaries (`\b`), lookahead/behind, captures, backreferences.

**Engine internals:**
- Lazy DFA construction — states built on demand
- Minterm partitioning — collapses 256 byte values into equivalence classes
- Hash-consed AST nodes for structural sharing
- SIMD-accelerated startset skip for literal prefixes
- Two-phase matching: reverse DFA finds match starts, forward DFA finds ends
- Leftmost-longest match semantics

## Build

Requires Zig 0.15.2+. No external dependencies.

```
zig build test          # run all tests
zig build test-compat   # run resharp-dotnet compatibility tests only
zig build bench         # run benchmarks (always ReleaseFast)
zig build run           # run CLI
```

## Usage

### One-shot matching

```zig
const rez = @import("rez");

const span = try rez.match(allocator, "[0-9]+", "abc 42 def");
// span.? == .{ .start = 4, .end = 6 }
```

### Compiled regex (reuse across inputs)

```zig
var regex = try rez.Regex.compile(allocator, "[a-z]+");
defer regex.deinit();

const first = try regex.find("hello world");
// first.? == .{ .start = 0, .end = 5 }

const all = try regex.findAll(allocator, "foo bar baz");
defer allocator.free(all);
// all == [.{0,3}, .{4,7}, .{8,11}]
```

### As a Zig module dependency

In your `build.zig.zon`, add rez as a dependency. Then in `build.zig`:

```zig
const rez_mod = b.dependency("rez", .{}).module("rez");
my_module.addImport("rez", rez_mod);
```

## Project structure

```
src/
  parser.zig       # recursive descent ERE parser → AST
  ast.zig          # expression tree types
  interner.zig     # hash-consing node store
  node.zig         # interned node representation
  charset.zig      # 256-bit character sets
  minterm.zig      # minterm equivalence class partitioning
  derivative.zig   # Brzozowski derivative computation
  nullability.zig  # nullability checking (does this node match ε?)
  dfa.zig          # lazy DFA + Regex API + match/findAll
  startset.zig     # SIMD-accelerated match position skip
  reverse.zig      # regex reversal for two-phase matching
  unicode.zig      # unicode category tables
  compat_test.zig  # 600+ tests from resharp-dotnet vectors
  bench.zig        # benchmarks with cache statistics
  root.zig         # public module interface
  main.zig         # CLI entry point
```

## Performance

Throughput on Apple M4 Pro (ReleaseFast):

| Pattern type | Throughput |
|---|---|
| Literal skip (SIMD) | 5–7 GB/s |
| Alternation | 1–2 GB/s |
| Character classes | 100–600 MB/s |

The hot path runs ~25 cycles per character via flat delta table lookups. No pattern causes super-linear behavior.
