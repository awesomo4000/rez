# Baseline Benchmarks

- **Date**: 03/12/2026
- **Commit**: be154c1
- **Machine**: Apple M4 Pro, Darwin arm64 (macOS 24.6.0)
- **Build**: `zig build bench` (ReleaseFast)

## Results

```
rez benchmark suite
===================

== Literal Search ==

────────────────────────────────────────────────────────────────────────────────────────────────
Benchmark                             Matches    Compile     Search       MB/s    Iters
────────────────────────────────────────────────────────────────────────────────────────────────
literal-short                            2851    28.4 us    10.0 ms 100.5 MB/s       11
literal-long                               49    48.4 us    23.4 ms  42.8 MB/s        5
literal-nomatch                             0    30.0 us    15.4 ms  64.9 MB/s        7

== Character Classes & Quantifiers ==

────────────────────────────────────────────────────────────────────────────────────────────────
Benchmark                             Matches    Compile     Search       MB/s    Iters
────────────────────────────────────────────────────────────────────────────────────────────────
letters-8-13 (1MB)                      13896    20.7 us    19.8 ms  50.5 MB/s        6
digits (100KB)                           6328    22.5 us   625.7 us 156.1 MB/s      160
word-chars (100KB)                      19720    21.1 us   949.7 us 102.8 MB/s      106
dot-star (1KB)                              2    22.1 us    25.0 us  39.1 MB/s     3999
any-star (1KB)                              1    21.6 us    56.2 us  17.4 MB/s     1781

== Alternation ==

────────────────────────────────────────────────────────────────────────────────────────────────
Benchmark                             Matches    Compile     Search       MB/s    Iters
────────────────────────────────────────────────────────────────────────────────────────────────
alt-2 (1MB)                              5595    44.5 us    21.3 ms  47.0 MB/s        5
alt-5 (1MB)                             13760    51.6 us    41.0 ms  24.4 MB/s        3
alt-nomatch (1MB)                           0    26.1 us    25.7 ms  39.0 MB/s        5

== Bounded Repeats ==

────────────────────────────────────────────────────────────────────────────────────────────────
Benchmark                             Matches    Compile     Search       MB/s    Iters
────────────────────────────────────────────────────────────────────────────────────────────────
capitals (100KB code)                     122    34.5 us   964.2 us 101.3 MB/s      104
context (100KB code)                      123    65.7 us     7.1 ms  13.8 MB/s       15

== CloudFlare ReDoS (automata engine should not blow up) ==

────────────────────────────────────────────────────────────────────────────────────────────────
Benchmark                             Matches    Compile     Search       MB/s    Iters
────────────────────────────────────────────────────────────────────────────────────────────────
redos-simplified-short                      1    25.1 us     762 ns 127.7 MB/s   131081
redos-simplified-long                       1    22.4 us    87.6 us 130.6 MB/s     1142

== Quadratic Test (throughput should scale linearly) ==

────────────────────────────────────────────────────────────────────────────────────────────────
Benchmark                             Matches    Compile     Search       MB/s    Iters
────────────────────────────────────────────────────────────────────────────────────────────────
quadratic-1x (100)                        100    35.5 us    33.3 us   2.9 MB/s     3008
quadratic-2x (200)                        200    36.8 us   122.7 us   1.6 MB/s      816
quadratic-10x (1000)                     1000    37.9 us     2.8 ms 354.6 KB/s       37

== Compile Time ==

────────────────────────────────────────────────────────────────────────────────────────────────
Pattern                                         Compile    Pattern Len
────────────────────────────────────────────────────────────────────────────────────────────────
simple-literal                                  22.1 us              3
char-class                                      21.4 us             12
alternation-small                               30.0 us             11
alternation-medium                              64.3 us             56
bounded-repeat                                  20.9 us             14
complex-bounded                                 37.5 us             26
nested-groups                                   22.5 us             13
aws-keys-quick                                  41.0 us             39
email-like                                      44.3 us             48
ip-address                                      36.4 us             46

== Haystack Scaling (same pattern, increasing input) ==

────────────────────────────────────────────────────────────────────────────────────────────────
Benchmark                             Matches    Compile     Search       MB/s    Iters
────────────────────────────────────────────────────────────────────────────────────────────────
word-match (1KB)                          125    21.4 us     8.3 us 117.1 MB/s    11994
word-match (100KB)                      13392    21.5 us   893.4 us 109.3 MB/s      112
word-match (1MB)                       136190    21.4 us     9.1 ms 109.7 MB/s       11

────────────────────────────────────────────────────────────────────────────────────────────────
Done.
```
