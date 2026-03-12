# Profile Baseline Benchmarks

- **Date**: 03/12/2026
- **Commit**: be154c1 (with profiling counters added)
- **Machine**: Apple M4 Pro, Darwin arm64 (macOS 24.6.0)
- **Build**: `zig build bench` (ReleaseFast, profiling counters active)

## Key Findings

1. **100% cache hit rate** across all benchmarks after first iteration warm-up
2. **0% derivative computation time** - cache is fully populated; per-character cost is entirely lookup
3. **Cache lookup (HashMap.get) takes ~50-60%** of profiled hot-path time
4. **Nullability checks take ~40-50%** of profiled hot-path time
5. **Profiling overhead is ~5-7x** (timers add ~20ns per call, called 2x per character)

## Analysis

The HashMap bottleneck theory is **confirmed**: since cache hit rate is 100%, every character
pays the full cost of `AutoHashMap.get()` (hash + probe + compare) even though the result
is always found. A flat array lookup `table[state * stride + minterm]` would replace this
with a single multiply + array index.

The nullability check is the **second bottleneck**: it recursively walks the regex tree on
every character position. This could be memoized per-state or replaced with a per-state
nullable bit.

## Results

```
rez benchmark suite (with profiling)
====================================

== Literal Search ==

────────────────────────────────────────────────────────────────────────────────────────────────
Benchmark                             Matches    Compile     Search       MB/s    Iters
────────────────────────────────────────────────────────────────────────────────────────────────
literal-short                            2851    28.0 us    63.9 ms  15.6 MB/s        2
  Profile: 1.1M trans/iter (100.0% hit), 1.1M null/iter | cache=52% deriv=0% null=48%
literal-long                               49    41.9 us    70.6 ms  14.2 MB/s        2
  Profile: 1.1M trans/iter (100.0% hit), 1.1M null/iter | cache=46% deriv=0% null=54%
literal-nomatch                             0    28.7 us    66.1 ms  15.1 MB/s        2
  Profile: 1.0M trans/iter (100.0% hit), 1.0M null/iter | cache=49% deriv=0% null=51%

== Character Classes & Quantifiers ==

────────────────────────────────────────────────────────────────────────────────────────────────
Benchmark                             Matches    Compile     Search       MB/s    Iters
────────────────────────────────────────────────────────────────────────────────────────────────
letters-8-13 (1MB)                      13896    19.6 us   170.4 ms   5.9 MB/s        1
  Profile: 2.8M trans/iter (100.0% hit), 2.8M null/iter | cache=60% deriv=0% null=40%
digits (100KB)                           6328    19.9 us     6.4 ms  15.2 MB/s       16
  Profile: 108.7K trans/iter (100.0% hit), 108.7K null/iter | cache=57% deriv=0% null=43%
word-chars (100KB)                      19720    19.8 us     7.5 ms  13.1 MB/s       14
  Profile: 122.1K trans/iter (100.0% hit), 122.1K null/iter | cache=61% deriv=0% null=39%
dot-star (1KB)                              2    21.0 us   214.2 us   4.6 MB/s      467
  Profile: 3.6K trans/iter (100.0% hit), 3.6K null/iter | cache=56% deriv=0% null=44%
any-star (1KB)                              1    21.0 us   502.0 us   1.9 MB/s      200
  Profile: 8.5K trans/iter (100.0% hit), 8.5K null/iter | cache=57% deriv=0% null=43%

== Alternation ==

────────────────────────────────────────────────────────────────────────────────────────────────
Benchmark                             Matches    Compile     Search       MB/s    Iters
────────────────────────────────────────────────────────────────────────────────────────────────
alt-2 (1MB)                              5595    40.8 us    70.0 ms  14.3 MB/s        2
  Profile: 1.1M trans/iter (100.0% hit), 1.1M null/iter | cache=47% deriv=0% null=53%
alt-5 (1MB)                             13760    47.0 us    86.3 ms  11.6 MB/s        2
  Profile: 1.1M trans/iter (100.0% hit), 1.1M null/iter | cache=34% deriv=0% null=66%
alt-nomatch (1MB)                           0    24.6 us    72.9 ms  13.7 MB/s        2
  Profile: 1.1M trans/iter (100.0% hit), 1.1M null/iter | cache=47% deriv=0% null=53%

== Bounded Repeats ==

────────────────────────────────────────────────────────────────────────────────────────────────
Benchmark                             Matches    Compile     Search       MB/s    Iters
────────────────────────────────────────────────────────────────────────────────────────────────
capitals (100KB code)                     122    35.2 us     7.2 ms  13.6 MB/s       14
  Profile: 120.8K trans/iter (100.0% hit), 120.8K null/iter | cache=55% deriv=0% null=45%
context (100KB code)                      123    61.8 us    24.8 ms   3.9 MB/s        5
  Profile: 366.1K trans/iter (100.0% hit), 366.1K null/iter | cache=52% deriv=0% null=47%

== CloudFlare ReDoS (automata engine should not blow up) ==

────────────────────────────────────────────────────────────────────────────────────────────────
Benchmark                             Matches    Compile     Search       MB/s    Iters
────────────────────────────────────────────────────────────────────────────────────────────────
redos-simplified-short                      1    21.8 us     6.1 us  15.9 MB/s    16366
  Profile: 102 trans/iter (100.0% hit), 104 null/iter | cache=57% deriv=0% null=43%
redos-simplified-long                       1    20.7 us   701.8 us  16.3 MB/s      143
  Profile: 12.0K trans/iter (100.0% hit), 12.0K null/iter | cache=58% deriv=0% null=42%

== Quadratic Test (throughput should scale linearly) ==

────────────────────────────────────────────────────────────────────────────────────────────────
Benchmark                             Matches    Compile     Search       MB/s    Iters
────────────────────────────────────────────────────────────────────────────────────────────────
quadratic-1x (100)                        100    34.7 us   298.6 us 327.0 KB/s      335
  Profile: 5.1K trans/iter (100.0% hit), 5.2K null/iter | cache=56% deriv=0% null=44%
quadratic-2x (200)                        200    38.8 us     1.2 ms 168.4 KB/s       87
  Profile: 20.1K trans/iter (100.0% hit), 20.3K null/iter | cache=56% deriv=0% null=44%
quadratic-10x (1000)                     1000    37.2 us    29.1 ms  33.6 KB/s        4
  Profile: 500.5K trans/iter (100.0% hit), 501.5K null/iter | cache=56% deriv=0% null=44%

== Compile Time ==

────────────────────────────────────────────────────────────────────────────────────────────────
Pattern                                         Compile    Pattern Len
────────────────────────────────────────────────────────────────────────────────────────────────
simple-literal                                  20.9 us              3
char-class                                      19.7 us             12
alternation-small                               29.2 us             11
alternation-medium                              61.0 us             56
bounded-repeat                                  19.7 us             14
complex-bounded                                 36.2 us             26
nested-groups                                   22.9 us             13
aws-keys-quick                                  36.5 us             39
email-like                                      40.2 us             48
ip-address                                      33.9 us             46

== Haystack Scaling (same pattern, increasing input) ==

────────────────────────────────────────────────────────────────────────────────────────────────
Benchmark                             Matches    Compile     Search       MB/s    Iters
────────────────────────────────────────────────────────────────────────────────────────────────
word-match (1KB)                          125    20.5 us    68.8 us  14.2 MB/s     1454
  Profile: 1.1K trans/iter (100.0% hit), 1.2K null/iter | cache=59% deriv=0% null=41%
word-match (100KB)                      13392    20.3 us     7.0 ms  14.0 MB/s       15
  Profile: 115.8K trans/iter (100.0% hit), 115.8K null/iter | cache=59% deriv=0% null=41%
word-match (1MB)                       136190    20.3 us    72.5 ms  13.8 MB/s        2
  Profile: 1.2M trans/iter (100.0% hit), 1.2M null/iter | cache=59% deriv=0% null=41%

────────────────────────────────────────────────────────────────────────────────────────────────
Done.
```
