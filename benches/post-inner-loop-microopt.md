# Post Inner-Loop Micro-Optimization Benchmarks

- **Date**: 03/12/2026
- **Commit**: inner-loop-microopt branch
- **Machine**: Apple M4 Pro, Darwin arm64 (macOS 24.6.0)
- **Build**: `zig build bench` (ReleaseFast)

## Changes

1. **Gate profiling behind comptime flag**: `enable_profiling` is false in ReleaseFast/ReleaseSmall, true in Debug/ReleaseSafe. All counter increments and Timer calls are dead-code-eliminated at compile time. Zero runtime cost.

2. **Shift-or delta indexing**: Pad `num_minterms` to next power-of-2. Replace `state_idx * stride + mt` with `state_idx << mt_shift | mt`. Eliminates a multiply instruction per transition in the hot path.

## Results

```
rez benchmark suite (with profiling)
====================================

== Literal Search ==

Benchmark                             Matches    Compile     Search       MB/s    Iters
literal-short                            2851    22.6 us   129.1 us   7.6 GB/s      775
literal-long                               49    36.8 us   211.1 us   4.6 GB/s      474
literal-nomatch                             0    24.6 us    15.4 us  63.6 GB/s     6513

== Character Classes & Quantifiers ==

Benchmark                             Matches    Compile     Search       MB/s    Iters
letters-8-13 (1MB)                      13896    16.5 us    15.7 ms  63.7 MB/s        7
digits (100KB)                           6328    16.4 us   152.6 us 639.8 MB/s      656
word-chars (100KB)                      19720    17.7 us   630.1 us 155.0 MB/s      159
dot-star (1KB)                              2    17.9 us    10.6 us  92.4 MB/s     9467
any-star (1KB)                              1    18.9 us    25.3 us  38.7 MB/s     3960

== Alternation ==

Benchmark                             Matches    Compile     Search       MB/s    Iters
alt-2 (1MB)                              5595    34.7 us   574.5 us   1.7 GB/s      175
alt-5 (1MB)                             13760    39.8 us   835.4 us   1.2 GB/s      120
alt-nomatch (1MB)                           0    21.5 us   606.8 us   1.6 GB/s      165

== Bounded Repeats ==

Benchmark                             Matches    Compile     Search       MB/s    Iters
capitals (100KB code)                     122    29.3 us   161.1 us 606.2 MB/s      621
context (100KB code)                      123    53.5 us     1.8 ms  55.2 MB/s       57

== CloudFlare ReDoS ==

Benchmark                             Matches    Compile     Search       MB/s    Iters
redos-simplified-short                      1    18.3 us     417 ns 233.3 MB/s   239330
redos-simplified-long                       1    17.6 us    49.5 us 231.1 MB/s     2020

== Quadratic Test ==

Benchmark                             Matches    Compile     Search       MB/s    Iters
quadratic-1x (100)                        100    30.0 us    21.1 us   4.5 MB/s     4741
quadratic-2x (200)                        200    30.4 us    73.1 us   2.6 MB/s     1369
quadratic-10x (1000)                     1000    29.0 us     1.6 ms 605.2 KB/s       62

== Haystack Scaling ==

Benchmark                             Matches    Compile     Search       MB/s    Iters
word-match (1KB)                          125    20.3 us     4.9 us 200.0 MB/s    20474
word-match (100KB)                      13392    19.6 us   524.3 us 186.3 MB/s      191
word-match (1MB)                       136190    18.5 us     5.3 ms 189.8 MB/s       19
```

## Comparison vs Pre-Optimization Baseline

| Benchmark | Before MB/s | After MB/s | Speedup |
|---|---|---|---|
| literal-short | 7,475.2 (7.3 GB/s) | 7,782.4 (7.6 GB/s) | **1.04x** |
| literal-long | 4,403.2 (4.3 GB/s) | 4,710.4 (4.6 GB/s) | **1.07x** |
| literal-nomatch | 64,409.6 (62.9 GB/s) | 65,126.4 (63.6 GB/s) | ~1.0x |
| letters-8-13 (1MB) | 62.1 | 63.7 | **1.03x** |
| digits (100KB) | 599.8 | 639.8 | **1.07x** |
| word-chars (100KB) | 138.6 | 155.0 | **1.12x** |
| dot-star (1KB) | 80.5 | 92.4 | **1.15x** |
| any-star (1KB) | 30.7 | 38.7 | **1.26x** |
| alt-2 (1MB) | 1,638.4 (1.6 GB/s) | 1,740.8 (1.7 GB/s) | **1.06x** |
| alt-5 (1MB) | 1,126.4 (1.1 GB/s) | 1,228.8 (1.2 GB/s) | **1.09x** |
| alt-nomatch (1MB) | 1,638.4 (1.6 GB/s) | 1,638.4 (1.6 GB/s) | ~1.0x |
| capitals (100KB) | 580.9 | 606.2 | **1.04x** |
| context (100KB) | 48.3 | 55.2 | **1.14x** |
| redos-simplified-short | 204.4 | 233.3 | **1.14x** |
| redos-simplified-long | 202.6 | 231.1 | **1.14x** |
| quadratic-1x | 4.1 | 4.5 | **1.10x** |
| quadratic-2x | 2.3 | 2.6 | **1.13x** |
| quadratic-10x | 501.7 KB/s | 605.2 KB/s | **1.21x** |
| word-match (1KB) | 186.3 | 200.0 | **1.07x** |
| word-match (100KB) | 170.0 | 186.3 | **1.10x** |
| word-match (1MB) | 171.6 | 189.8 | **1.11x** |

**Summary**: 3-26% improvement across the board. Largest gains on transition-heavy benchmarks:
- `any-star`: **+26%** (most transitions per byte, most benefit from removing profiling overhead)
- `quadratic-10x`: **+21%** (500K transitions per iter, every cycle counts)
- `dot-star`: **+15%**
- `context`: **+14%**
- `redos`: **+14%**
- `word-chars`: **+12%**
- `word-match`: **+10-11%**

Startset-dominated benchmarks (literals, nomatch) see minimal change as expected — they spend almost no time in the inner loop.

All match counts identical to baseline — correctness preserved.
