# Post Delta Table + Nullable Cache Benchmarks

- **Date**: 03/12/2026
- **Commit**: (post flat delta table optimization)
- **Machine**: Apple M4 Pro, Darwin arm64 (macOS 24.6.0)
- **Build**: `zig build bench` (ReleaseFast)

## Changes

Replaced HashMap transition cache with flat delta tables indexed by `state_idx * stride + minterm`.
Added nullable result caching (tri-state arrays) to eliminate recursive tree walks on cache hits.
Removed per-call Timer overhead from hot path (only timing cache misses now).

## Results

```
rez benchmark suite (with profiling)
====================================

== Literal Search ==

────────────────────────────────────────────────────────────────────────────────────────────────
Benchmark                             Matches    Compile     Search       MB/s    Iters
────────────────────────────────────────────────────────────────────────────────────────────────
literal-short                            2851    29.0 us     5.0 ms 199.4 MB/s       20
literal-long                               49    46.1 us     6.1 ms 164.9 MB/s       17
literal-nomatch                             0    31.1 us     4.9 ms 203.8 MB/s       21

== Character Classes & Quantifiers ==

────────────────────────────────────────────────────────────────────────────────────────────────
Benchmark                             Matches    Compile     Search       MB/s    Iters
────────────────────────────────────────────────────────────────────────────────────────────────
letters-8-13 (1MB)                      13896    21.8 us    15.6 ms  64.1 MB/s        7
digits (100KB)                           6328    20.9 us   542.5 us 180.0 MB/s      185
word-chars (100KB)                      19720    21.2 us   742.7 us 131.5 MB/s      135
dot-star (1KB)                              2    22.4 us    17.1 us  57.2 MB/s     5859
any-star (1KB)                              1    22.5 us    37.1 us  26.3 MB/s     2693

== Alternation ==

────────────────────────────────────────────────────────────────────────────────────────────────
Benchmark                             Matches    Compile     Search       MB/s    Iters
────────────────────────────────────────────────────────────────────────────────────────────────
alt-2 (1MB)                              5595    43.8 us     5.1 ms 197.7 MB/s       20
alt-5 (1MB)                             13760    50.2 us     5.2 ms 192.9 MB/s       20
alt-nomatch (1MB)                           0    26.7 us     5.5 ms 181.6 MB/s       19

== Bounded Repeats ==

────────────────────────────────────────────────────────────────────────────────────────────────
Benchmark                             Matches    Compile     Search       MB/s    Iters
────────────────────────────────────────────────────────────────────────────────────────────────
capitals (100KB code)                     122    38.1 us   590.9 us 165.3 MB/s      170
context (100KB code)                      123    65.8 us     2.0 ms  49.0 MB/s       51

== CloudFlare ReDoS (automata engine should not blow up) ==

────────────────────────────────────────────────────────────────────────────────────────────────
Benchmark                             Matches    Compile     Search       MB/s    Iters
────────────────────────────────────────────────────────────────────────────────────────────────
redos-simplified-short                      1    22.0 us     515 ns 188.9 MB/s   194024
redos-simplified-long                       1    22.0 us    62.1 us 184.3 MB/s     1611

== Quadratic Test (throughput should scale linearly) ==

────────────────────────────────────────────────────────────────────────────────────────────────
Benchmark                             Matches    Compile     Search       MB/s    Iters
────────────────────────────────────────────────────────────────────────────────────────────────
quadratic-1x (100)                        100    36.3 us    24.4 us   3.9 MB/s     4094
quadratic-2x (200)                        200    38.2 us    91.4 us   2.1 MB/s     1095
quadratic-10x (1000)                     1000    36.7 us     2.1 ms 462.3 KB/s       48

== Compile Time ==

────────────────────────────────────────────────────────────────────────
Pattern                                         Compile    Pattern Len
────────────────────────────────────────────────────────────────────────
simple-literal                                  22.2 us              3
char-class                                      21.9 us             12
alternation-small                               31.3 us             11
alternation-medium                              63.8 us             56
bounded-repeat                                  20.8 us             14
complex-bounded                                 37.1 us             26
nested-groups                                   22.4 us             13
aws-keys-quick                                  40.7 us             39
email-like                                      44.6 us             48
ip-address                                      37.1 us             46

== Haystack Scaling (same pattern, increasing input) ==

────────────────────────────────────────────────────────────────────────────────────────────────
Benchmark                             Matches    Compile     Search       MB/s    Iters
────────────────────────────────────────────────────────────────────────────────────────────────
word-match (1KB)                          125    22.9 us     6.7 us 145.3 MB/s    14882
word-match (100KB)                      13392    21.6 us   680.5 us 143.5 MB/s      147
word-match (1MB)                       136190    21.7 us     7.0 ms 142.9 MB/s       15

────────────────────────────────────────────────────────────────────────────────────────────────
Done.
```

## Comparison vs Baseline

| Benchmark | Baseline MB/s | New MB/s | Speedup |
|---|---|---|---|
| literal-short | 100.5 | 199.4 | **2.0x** |
| literal-long | 42.8 | 164.9 | **3.9x** |
| literal-nomatch | 64.9 | 203.8 | **3.1x** |
| letters-8-13 (1MB) | 50.5 | 64.1 | **1.3x** |
| digits (100KB) | 156.1 | 180.0 | **1.2x** |
| word-chars (100KB) | 102.8 | 131.5 | **1.3x** |
| dot-star (1KB) | 39.1 | 57.2 | **1.5x** |
| any-star (1KB) | 17.4 | 26.3 | **1.5x** |
| alt-2 (1MB) | 47.0 | 197.7 | **4.2x** |
| alt-5 (1MB) | 24.4 | 192.9 | **7.9x** |
| alt-nomatch (1MB) | 39.0 | 181.6 | **4.7x** |
| capitals (100KB) | 101.3 | 165.3 | **1.6x** |
| context (100KB) | 13.8 | 49.0 | **3.6x** |
| redos-short | 127.7 | 188.9 | **1.5x** |
| redos-long | 130.6 | 184.3 | **1.4x** |
| quadratic-1x | 2.9 | 3.9 | **1.3x** |
| quadratic-2x | 1.6 | 2.1 | **1.3x** |
| quadratic-10x | 354.6 KB/s | 462.3 KB/s | **1.3x** |
| word-match (1KB) | 117.1 | 145.3 | **1.2x** |
| word-match (100KB) | 109.3 | 143.5 | **1.3x** |
| word-match (1MB) | 109.7 | 142.9 | **1.3x** |

**Summary**: 1.2x-7.9x speedup across all benchmarks. Largest gains on alternation patterns (4-8x) and literal search (2-4x) due to elimination of HashMap hash+probe overhead. All match counts identical to baseline (correctness verified).
