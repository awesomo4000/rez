/// rez benchmark suite
///
/// Inspired by resharp-dotnet's rebar benchmark infrastructure.
/// Measures compile time, search throughput, and match counts.
/// Includes hot-path profiling: transition cache hit/miss, derivative, nullability timing.
///
/// Run with: zig build bench
///
const std = @import("std");
const rez = @import("rez");
const Regex = rez.Regex;
const Span = rez.Span;
const ProfileCounters = rez.dfa.ProfileCounters;
const Allocator = std.mem.Allocator;

// ── Benchmark infrastructure ────────────────────────────────────────

const BenchResult = struct {
    name: []const u8,
    compile_ns: u64,
    search_ns: u64,
    iterations: u64,
    haystack_len: usize,
    match_count: usize,
    compile_throughput_mbps: f64,
    search_throughput_mbps: f64,
    profile: ProfileCounters,
};

const Timer = struct {
    start: std.time.Instant,

    fn begin() Timer {
        return .{ .start = std.time.Instant.now() catch unreachable };
    }

    fn elapsed_ns(self: Timer) u64 {
        const now = std.time.Instant.now() catch unreachable;
        return now.since(self.start);
    }
};

/// Minimum benchmark duration in nanoseconds (100ms)
const MIN_BENCH_NS: u64 = 100_000_000;

/// Maximum iterations cap
const MAX_ITERS: u64 = 1_000_000;

fn benchCount(
    allocator: Allocator,
    name: []const u8,
    pattern: []const u8,
    haystack: []const u8,
) !BenchResult {
    // -- Measure compile time --
    var compile_iters: u64 = 0;
    var compile_total_ns: u64 = 0;
    while (compile_total_ns < MIN_BENCH_NS and compile_iters < MAX_ITERS) {
        const t = Timer.begin();
        var re = try Regex.compile(allocator, pattern);
        re.deinit();
        compile_total_ns += t.elapsed_ns();
        compile_iters += 1;
    }

    // -- Compile once for search benchmarking --
    var re = try Regex.compile(allocator, pattern);
    defer re.deinit();

    // -- Reset profile counters before search loop --
    re.dfa_state.profile.reset();

    // -- Measure search time --
    var search_iters: u64 = 0;
    var search_total_ns: u64 = 0;
    var match_count: usize = 0;
    while (search_total_ns < MIN_BENCH_NS and search_iters < MAX_ITERS) {
        const t = Timer.begin();
        match_count = try re.count(haystack);
        search_total_ns += t.elapsed_ns();
        search_iters += 1;
    }

    // -- Capture profile data (accumulated across all search iterations) --
    const profile = re.dfa_state.profile;

    const avg_compile_ns = compile_total_ns / compile_iters;
    const avg_search_ns = search_total_ns / search_iters;

    const haystack_mb: f64 = @as(f64, @floatFromInt(haystack.len)) / (1024.0 * 1024.0);
    const compile_secs: f64 = @as(f64, @floatFromInt(avg_compile_ns)) / 1_000_000_000.0;
    const search_secs: f64 = @as(f64, @floatFromInt(avg_search_ns)) / 1_000_000_000.0;

    return .{
        .name = name,
        .compile_ns = avg_compile_ns,
        .search_ns = avg_search_ns,
        .iterations = search_iters,
        .haystack_len = haystack.len,
        .match_count = match_count,
        .compile_throughput_mbps = if (compile_secs > 0) haystack_mb / compile_secs else 0,
        .search_throughput_mbps = if (search_secs > 0) haystack_mb / search_secs else 0,
        .profile = profile,
    };
}

fn formatDuration(buf: []u8, ns: u64) []const u8 {
    if (ns < 1_000) {
        return std.fmt.bufPrint(buf, "{d} ns", .{ns}) catch "???";
    } else if (ns < 1_000_000) {
        const us: f64 = @as(f64, @floatFromInt(ns)) / 1_000.0;
        return std.fmt.bufPrint(buf, "{d:.1} us", .{us}) catch "???";
    } else if (ns < 1_000_000_000) {
        const ms: f64 = @as(f64, @floatFromInt(ns)) / 1_000_000.0;
        return std.fmt.bufPrint(buf, "{d:.1} ms", .{ms}) catch "???";
    } else {
        const s: f64 = @as(f64, @floatFromInt(ns)) / 1_000_000_000.0;
        return std.fmt.bufPrint(buf, "{d:.2} s", .{s}) catch "???";
    }
}

fn formatThroughput(buf: []u8, mbps: f64) []const u8 {
    if (mbps >= 1000.0) {
        return std.fmt.bufPrint(buf, "{d:.1} GB/s", .{mbps / 1024.0}) catch "???";
    } else if (mbps >= 1.0) {
        return std.fmt.bufPrint(buf, "{d:.1} MB/s", .{mbps}) catch "???";
    } else if (mbps >= 0.001) {
        return std.fmt.bufPrint(buf, "{d:.1} KB/s", .{mbps * 1024.0}) catch "???";
    } else {
        return std.fmt.bufPrint(buf, "{d:.3} MB/s", .{mbps}) catch "???";
    }
}

fn formatCount(buf: []u8, n: u64) []const u8 {
    if (n >= 1_000_000_000) {
        const v: f64 = @as(f64, @floatFromInt(n)) / 1_000_000_000.0;
        return std.fmt.bufPrint(buf, "{d:.1}B", .{v}) catch "???";
    } else if (n >= 1_000_000) {
        const v: f64 = @as(f64, @floatFromInt(n)) / 1_000_000.0;
        return std.fmt.bufPrint(buf, "{d:.1}M", .{v}) catch "???";
    } else if (n >= 1_000) {
        const v: f64 = @as(f64, @floatFromInt(n)) / 1_000.0;
        return std.fmt.bufPrint(buf, "{d:.1}K", .{v}) catch "???";
    } else {
        return std.fmt.bufPrint(buf, "{d}", .{n}) catch "???";
    }
}

fn print(w: *std.Io.Writer, comptime fmt: []const u8, args: anytype) void {
    w.print(fmt, args) catch {};
}

fn printHeader(w: *std.Io.Writer) void {
    print(w, "\n", .{});
    printDashes(w, 96);
    print(w, "\n{s:<36} {s:>8} {s:>10} {s:>10} {s:>10} {s:>8}\n", .{
        "Benchmark", "Matches", "Compile", "Search", "MB/s", "Iters",
    });
    printDashes(w, 96);
    print(w, "\n", .{});
}

fn printDashes(w: *std.Io.Writer, count: usize) void {
    for (0..count) |_| {
        w.writeAll("\xe2\x94\x80") catch {}; // UTF-8 for ─
    }
}

fn printResult(w: *std.Io.Writer, r: BenchResult) void {
    var compile_buf: [32]u8 = undefined;
    var search_buf: [32]u8 = undefined;
    var tp_buf: [32]u8 = undefined;

    const compile_str = formatDuration(&compile_buf, r.compile_ns);
    const search_str = formatDuration(&search_buf, r.search_ns);
    const tp_str = formatThroughput(&tp_buf, r.search_throughput_mbps);

    print(w, "{s:<36} {d:>8} {s:>10} {s:>10} {s:>10} {d:>8}\n", .{
        r.name,
        r.match_count,
        compile_str,
        search_str,
        tp_str,
        r.iterations,
    });
}

fn printProfile(w: *std.Io.Writer, p: ProfileCounters, iters: u64) void {
    const total_calls = p.transition_calls;
    if (total_calls == 0) {
        print(w, "  Profile: no transitions\n", .{});
        return;
    }

    // Per-iteration averages
    const avg_transitions = total_calls / iters;
    const avg_nullability = p.nullability_calls / iters;

    // Cache hit rate
    const hit_rate: f64 = if (total_calls > 0)
        @as(f64, @floatFromInt(p.cache_hits)) / @as(f64, @floatFromInt(total_calls)) * 100.0
    else
        0.0;

    // Time breakdown as percentages of total measured time
    // Note: transition_ns includes cache lookup + derivative time
    // derivative_ns is the subset of transition_ns spent in derivative() on cache miss
    // nullability_ns is measured separately (not inside transition)
    const total_profiled_ns = p.transition_ns + p.nullability_ns;

    var trans_buf: [32]u8 = undefined;
    var null_buf: [32]u8 = undefined;

    if (total_profiled_ns > 0) {
        const cache_lookup_ns = p.transition_ns - p.derivative_ns;
        const cache_pct: f64 = @as(f64, @floatFromInt(cache_lookup_ns)) / @as(f64, @floatFromInt(total_profiled_ns)) * 100.0;
        const deriv_pct: f64 = @as(f64, @floatFromInt(p.derivative_ns)) / @as(f64, @floatFromInt(total_profiled_ns)) * 100.0;
        const null_pct: f64 = @as(f64, @floatFromInt(p.nullability_ns)) / @as(f64, @floatFromInt(total_profiled_ns)) * 100.0;

        const trans_str = formatCount(&trans_buf, avg_transitions);
        const null_str = formatCount(&null_buf, avg_nullability);

        print(w, "  Profile: {s} trans/iter ({d:.1}% hit), {s} null/iter | cache={d:.0}% deriv={d:.0}% null={d:.0}%\n", .{
            trans_str,
            hit_rate,
            null_str,
            cache_pct,
            deriv_pct,
            null_pct,
        });
    } else {
        const trans_str = formatCount(&trans_buf, avg_transitions);
        const null_str = formatCount(&null_buf, avg_nullability);
        print(w, "  Profile: {s} trans/iter ({d:.1}% hit), {s} null/iter\n", .{
            trans_str,
            hit_rate,
            null_str,
        });
    }
}

// ── Haystack generators ─────────────────────────────────────────────

fn generateRepeated(allocator: Allocator, content: []const u8, count: usize) ![]u8 {
    const buf = try allocator.alloc(u8, content.len * count);
    for (0..count) |i| {
        @memcpy(buf[i * content.len ..][0..content.len], content);
    }
    return buf;
}

/// Generate a pseudo-random English-like text
fn generateText(allocator: Allocator, target_len: usize) ![]u8 {
    const words = [_][]const u8{
        "the",     "quick",    "brown",    "fox",       "jumps",
        "over",    "lazy",     "dog",      "and",       "cat",
        "sat",     "on",       "mat",      "with",      "hat",
        "Sherlock", "Holmes",  "Watson",   "London",    "Baker",
        "Street",  "mystery", "evidence", "detective", "crime",
        "morning", "evening", "afternoon", "night",    "day",
        "result",  "error",   "success",  "failure",  "return",
        "function", "module", "import",   "export",   "const",
        "2024-01-15", "2023-12-25", "1999-09-09", "2010-03-14",
        "test@example.com", "user@mail.org", "admin@host.net",
        "192.168.1.1", "10.0.0.1", "255.255.255.0",
    };

    var buf = try allocator.alloc(u8, target_len);
    var pos: usize = 0;
    var rng_state: u32 = 0xDEADBEEF;

    while (pos < target_len) {
        // Simple xorshift PRNG
        rng_state ^= rng_state << 13;
        rng_state ^= rng_state >> 17;
        rng_state ^= rng_state << 5;
        const idx = rng_state % words.len;
        const word = words[idx];

        if (pos + word.len + 1 >= target_len) {
            // Fill remaining with spaces
            @memset(buf[pos..], ' ');
            break;
        }

        @memcpy(buf[pos..][0..word.len], word);
        pos += word.len;

        // Add separator: space, newline, or comma
        const sep_choice = (rng_state >> 8) % 10;
        if (sep_choice == 0) {
            buf[pos] = '\n';
        } else if (sep_choice == 1) {
            buf[pos] = ',';
        } else {
            buf[pos] = ' ';
        }
        pos += 1;
    }

    return buf;
}

/// Generate Rust-like source code text
fn generateCode(allocator: Allocator, target_len: usize) ![]u8 {
    const lines = [_][]const u8{
        "fn main() {\n",
        "    let result = compute();\n",
        "    println!(\"Hello, world!\");\n",
        "    let x: Result<i32, Error> = Ok(42);\n",
        "    match x {\n",
        "        Ok(v) => println!(\"{}\", v),\n",
        "        Err(e) => eprintln!(\"Error: {}\", e),\n",
        "    }\n",
        "}\n",
        "\n",
        "pub struct Configuration {\n",
        "    pub name: String,\n",
        "    pub value: i64,\n",
        "    pub description: String,\n",
        "}\n",
        "\n",
        "impl Configuration {\n",
        "    pub fn new(name: &str) -> Result<Self, Error> {\n",
        "        Ok(Configuration {\n",
        "            name: name.to_string(),\n",
        "            value: 0,\n",
        "            description: String::new(),\n",
        "        })\n",
        "    }\n",
        "}\n",
        "\n",
        "// This is a comment about Performance optimization\n",
        "// Another comment: Configuration Management System\n",
        "fn process_data(input: &[u8]) -> Result<Vec<u8>, std::io::Error> {\n",
        "    let mut output = Vec::with_capacity(input.len());\n",
        "    for byte in input {\n",
        "        output.push(*byte);\n",
        "    }\n",
        "    Ok(output)\n",
        "}\n",
        "\n",
    };

    var buf = try allocator.alloc(u8, target_len);
    var pos: usize = 0;
    var line_idx: usize = 0;

    while (pos < target_len) {
        const line = lines[line_idx % lines.len];
        line_idx += 1;

        if (pos + line.len >= target_len) {
            const remaining = target_len - pos;
            @memcpy(buf[pos..][0..remaining], line[0..remaining]);
            pos = target_len;
            break;
        }

        @memcpy(buf[pos..][0..line.len], line);
        pos += line.len;
    }

    return buf;
}

// ── Benchmark definitions ───────────────────────────────────────────

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const w = &stdout_writer.interface;

    print(w, "rez benchmark suite (with profiling)\n", .{});
    print(w, "====================================\n", .{});

    // ── Generate haystacks ──────────────────────────────────────

    // Small text (~1 KB)
    const text_1k = try generateText(allocator, 1024);
    defer allocator.free(text_1k);

    // Medium text (~100 KB)
    const text_100k = try generateText(allocator, 100 * 1024);
    defer allocator.free(text_100k);

    // Large text (~1 MB)
    const text_1m = try generateText(allocator, 1024 * 1024);
    defer allocator.free(text_1m);

    // Rust-like code (~100 KB)
    const code_100k = try generateCode(allocator, 100 * 1024);
    defer allocator.free(code_100k);

    // Quadratic-case haystacks (from resharp curated/14-quadratic)
    const a_100 = try generateRepeated(allocator, "A", 100);
    defer allocator.free(a_100);
    const a_200 = try generateRepeated(allocator, "A", 200);
    defer allocator.free(a_200);
    const a_1000 = try generateRepeated(allocator, "A", 1000);
    defer allocator.free(a_1000);

    // CloudFlare ReDoS haystack (from resharp curated/06)
    const redos_short = "x=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";
    const redos_long = try generateRepeated(allocator, "x=xxxxxxxxxx", 1000);
    defer allocator.free(redos_long);

    // ── Group 1: Literal search ─────────────────────────────────
    // (inspired by curated/01-literal)
    print(w, "\n== Literal Search ==\n", .{});
    try w.flush();
    printHeader(w);

    const literal_benches = [_]struct { name: []const u8, pattern: []const u8 }{
        .{ .name = "literal-short", .pattern = "Holmes" },
        .{ .name = "literal-long", .pattern = "Sherlock Holmes" },
        .{ .name = "literal-nomatch", .pattern = "Zxywvutsrq" },
    };

    for (literal_benches) |b| {
        const r = try benchCount(allocator, b.name, b.pattern, text_1m);
        printResult(w, r);
        printProfile(w, r.profile, r.iterations);
        try w.flush();
    }

    // ── Group 2: Character classes + quantifiers ────────────────
    // (inspired by curated/10-bounded-repeat)
    print(w, "\n== Character Classes & Quantifiers ==\n", .{});
    try w.flush();
    printHeader(w);

    const class_benches = [_]struct { name: []const u8, pattern: []const u8, haystack: []const u8 }{
        .{ .name = "letters-8-13 (1MB)", .pattern = "[A-Za-z]{8,13}", .haystack = text_1m },
        .{ .name = "digits (100KB)", .pattern = "[0-9]+", .haystack = text_100k },
        .{ .name = "word-chars (100KB)", .pattern = "\\w+", .haystack = text_100k },
        .{ .name = "dot-star (1KB)", .pattern = "a.*z", .haystack = text_1k },
        .{ .name = "any-star (1KB)", .pattern = "a_*z", .haystack = text_1k },
    };

    for (class_benches) |b| {
        const r = try benchCount(allocator, b.name, b.pattern, b.haystack);
        printResult(w, r);
        printProfile(w, r.profile, r.iterations);
        try w.flush();
    }

    // ── Group 3: Alternation ────────────────────────────────────
    print(w, "\n== Alternation ==\n", .{});
    try w.flush();
    printHeader(w);

    const alt_benches = [_]struct { name: []const u8, pattern: []const u8, haystack: []const u8 }{
        .{ .name = "alt-2 (1MB)", .pattern = "Sherlock|Watson", .haystack = text_1m },
        .{ .name = "alt-5 (1MB)", .pattern = "Sherlock|Watson|London|Baker|Street", .haystack = text_1m },
        .{ .name = "alt-nomatch (1MB)", .pattern = "zzzzz|yyyyy|xxxxx", .haystack = text_1m },
    };

    for (alt_benches) |b| {
        const r = try benchCount(allocator, b.name, b.pattern, b.haystack);
        printResult(w, r);
        printProfile(w, r.profile, r.iterations);
        try w.flush();
    }

    // ── Group 4: Bounded repeats ────────────────────────────────
    // (inspired by curated/10-bounded-repeat)
    print(w, "\n== Bounded Repeats ==\n", .{});
    try w.flush();
    printHeader(w);

    const repeat_benches = [_]struct { name: []const u8, pattern: []const u8, haystack: []const u8 }{
        .{ .name = "capitals (100KB code)", .pattern = "(?:[A-Z][a-z]+\\s*){3,10}", .haystack = code_100k },
        .{ .name = "context (100KB code)", .pattern = "[A-Za-z]{10}\\s+[\\s\\S]{0,100}Result[\\s\\S]{0,100}\\s+[A-Za-z]{10}", .haystack = code_100k },
    };

    for (repeat_benches) |b| {
        const r = try benchCount(allocator, b.name, b.pattern, b.haystack);
        printResult(w, r);
        printProfile(w, r.profile, r.iterations);
        try w.flush();
    }

    // ── Group 5: CloudFlare ReDoS ───────────────────────────────
    // (from curated/06-cloud-flare-redos)
    print(w, "\n== CloudFlare ReDoS (automata engine should not blow up) ==\n", .{});
    try w.flush();
    printHeader(w);

    {
        const r = try benchCount(allocator, "redos-simplified-short", ".*.*=.*", redos_short);
        printResult(w, r);
        printProfile(w, r.profile, r.iterations);
        try w.flush();
    }
    {
        const r = try benchCount(allocator, "redos-simplified-long", ".*.*=.*", redos_long);
        printResult(w, r);
        printProfile(w, r.profile, r.iterations);
        try w.flush();
    }

    // ── Group 6: Quadratic behavior ─────────────────────────────
    // (from curated/14-quadratic)
    print(w, "\n== Quadratic Test (throughput should scale linearly) ==\n", .{});
    try w.flush();
    printHeader(w);

    const quad_benches = [_]struct { name: []const u8, haystack: []const u8 }{
        .{ .name = "quadratic-1x (100)", .haystack = a_100 },
        .{ .name = "quadratic-2x (200)", .haystack = a_200 },
        .{ .name = "quadratic-10x (1000)", .haystack = a_1000 },
    };

    for (quad_benches) |b| {
        const r = try benchCount(allocator, b.name, ".*[^A-Z]|[A-Z]", b.haystack);
        printResult(w, r);
        printProfile(w, r.profile, r.iterations);
        try w.flush();
    }

    // ── Group 7: Compile time ───────────────────────────────────
    print(w, "\n== Compile Time ==\n\n", .{});
    printDashes(w, 72);
    print(w, "\n{s:<40} {s:>14} {s:>14}\n", .{ "Pattern", "Compile", "Pattern Len" });
    printDashes(w, 72);
    print(w, "\n", .{});
    try w.flush();

    const compile_benches = [_]struct { name: []const u8, pattern: []const u8 }{
        .{ .name = "simple-literal", .pattern = "abc" },
        .{ .name = "char-class", .pattern = "[a-zA-Z0-9]+" },
        .{ .name = "alternation-small", .pattern = "abc|def|ghi" },
        .{ .name = "alternation-medium", .pattern = "alpha|beta|gamma|delta|epsilon|zeta|eta|theta|iota|kappa" },
        .{ .name = "bounded-repeat", .pattern = "[A-Za-z]{8,13}" },
        .{ .name = "complex-bounded", .pattern = "(?:[A-Z][a-z]+\\s*){10,100}" },
        .{ .name = "nested-groups", .pattern = "((a|b)(c|d))*" },
        .{ .name = "aws-keys-quick", .pattern = "((?:ASIA|AKIA|AROA|AIDA)([A-Z0-7]{16}))" },
        .{ .name = "email-like", .pattern = "[a-zA-Z0-9._%+\\-]+@[a-zA-Z0-9.\\-]+\\.[a-zA-Z]{2,}" },
        .{ .name = "ip-address", .pattern = "[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}" },
    };

    for (compile_benches) |b| {
        // Measure compile time
        var iters: u64 = 0;
        var total_ns: u64 = 0;
        while (total_ns < MIN_BENCH_NS and iters < MAX_ITERS) {
            const t = Timer.begin();
            var re = try Regex.compile(allocator, b.pattern);
            re.deinit();
            total_ns += t.elapsed_ns();
            iters += 1;
        }
        const avg_ns = total_ns / iters;

        var compile_buf: [32]u8 = undefined;
        const compile_str = formatDuration(&compile_buf, avg_ns);
        print(w, "{s:<40} {s:>14} {d:>14}\n", .{ b.name, compile_str, b.pattern.len });
        try w.flush();
    }

    // ── Group 8: Scaling test ───────────────────────────────────
    print(w, "\n== Haystack Scaling (same pattern, increasing input) ==\n", .{});
    try w.flush();
    printHeader(w);

    const scaling_pattern = "[A-Za-z]+";
    {
        const r = try benchCount(allocator, "word-match (1KB)", scaling_pattern, text_1k);
        printResult(w, r);
        printProfile(w, r.profile, r.iterations);
        try w.flush();
    }
    {
        const r = try benchCount(allocator, "word-match (100KB)", scaling_pattern, text_100k);
        printResult(w, r);
        printProfile(w, r.profile, r.iterations);
        try w.flush();
    }
    {
        const r = try benchCount(allocator, "word-match (1MB)", scaling_pattern, text_1m);
        printResult(w, r);
        printProfile(w, r.profile, r.iterations);
        try w.flush();
    }

    print(w, "\n", .{});
    printDashes(w, 96);
    print(w, "\nDone.\n", .{});
    try w.flush();
}
