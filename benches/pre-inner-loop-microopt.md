# Pre Inner-Loop Micro-Optimization Benchmarks

- **Date**: 03/12/2026
- **Commit**: 3746209 (startset-skip on main)
- **Machine**: Apple M4 Pro, Darwin arm64 (macOS 24.6.0)
- **Build**: `zig build bench` (ReleaseFast)
- **Branch**: inner-loop-microopt (baseline before changes)

## Results

```
rez benchmark suite (with profiling)
====================================

== Literal Search ==

Benchmark                             Matches    Compile     Search       MB/s    Iters
literal-short                            2851    23.4 us   133.3 us   7.3 GB/s      751
literal-long                               49    36.3 us   227.5 us   4.3 GB/s      440
literal-nomatch                             0    22.8 us    15.5 us  62.9 GB/s     6444

== Character Classes & Quantifiers ==

Benchmark                             Matches    Compile     Search       MB/s    Iters
letters-8-13 (1MB)                      13896    15.9 us    16.1 ms  62.1 MB/s        7
digits (100KB)                           6328    17.6 us   162.8 us 599.8 MB/s      615
word-chars (100KB)                      19720    15.9 us   704.6 us 138.6 MB/s      142
dot-star (1KB)                              2    16.5 us    12.1 us  80.5 MB/s     8245
any-star (1KB)                              1    16.4 us    31.9 us  30.7 MB/s     3140

== Alternation ==

Benchmark                             Matches    Compile     Search       MB/s    Iters
alt-2 (1MB)                              5595    33.8 us   600.4 us   1.6 GB/s      167
alt-5 (1MB)                             13760    40.7 us   859.2 us   1.1 GB/s      117
alt-nomatch (1MB)                           0    20.2 us   624.0 us   1.6 GB/s      161

== Bounded Repeats ==

Benchmark                             Matches    Compile     Search       MB/s    Iters
capitals (100KB code)                     122    27.9 us   168.1 us 580.9 MB/s      595
context (100KB code)                      123    51.9 us     2.0 ms  48.3 MB/s       50

== CloudFlare ReDoS ==

Benchmark                             Matches    Compile     Search       MB/s    Iters
redos-simplified-short                      1    16.7 us     476 ns 204.4 MB/s   209694
redos-simplified-long                       1    18.6 us    56.5 us 202.6 MB/s     1771

== Quadratic Test ==

Benchmark                             Matches    Compile     Search       MB/s    Iters
quadratic-1x (100)                        100    29.2 us    23.2 us   4.1 MB/s     4309
quadratic-2x (200)                        200    27.3 us    83.7 us   2.3 MB/s     1195
quadratic-10x (1000)                     1000    28.8 us     1.9 ms 501.7 KB/s       52

== Haystack Scaling ==

Benchmark                             Matches    Compile     Search       MB/s    Iters
word-match (1KB)                          125    16.6 us     5.2 us 186.3 MB/s    19072
word-match (100KB)                      13392    17.5 us   574.4 us 170.0 MB/s      175
word-match (1MB)                       136190    16.4 us     5.8 ms 171.6 MB/s       18
```
