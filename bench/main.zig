const std = @import("std");
const gcode_parser = @import("gcode_parser");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);

    var arena_state = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var runner = try BenchmarkRunner.init(arena);
    defer runner.deinit();

    // Prepare data sets
    try runner.addDataFromFile("sample", "bench/3dbenchy.gcode");
    try runner.addGenerated("synthetic-1MB", 1 * 1024 * 1024);
    try runner.addGenerated("synthetic-50MB", 50 * 1024 * 1024);

    // Prepare scenarios
    const baseOptions = gcode_parser.ParserOptions{};
    try runner.addScenario(.slice_iter, "Slice-Iter", baseOptions);
    try runner.addScenario(.slice_batch, "Slice-Batch", baseOptions);
    try runner.addScenario(.stream_iter, "Stream-Iter", baseOptions);
    try runner.addScenario(.stream_batch, "Stream-Batch", baseOptions);

    var options = baseOptions;
    options.validate_checksum = true;
    try runner.addScenario(.slice_iter, "Checksum ON", options);
    options.validate_checksum = false;
    try runner.addScenario(.slice_iter, "Checksum OFF", options);

    // Run and report
    try runner.runAll();
}

const Mode = enum { slice_iter, slice_batch, stream_iter, stream_batch };

const BenchmarkRunner = struct {
    arena: std.mem.Allocator,
    data_sets: std.ArrayListUnmanaged(DataSet) = .{},
    scenarios: std.ArrayListUnmanaged(Scenario) = .{},

    /// Initialize the benchmark runner
    pub fn init(arena: std.mem.Allocator) !*BenchmarkRunner {
        const runner = try arena.create(BenchmarkRunner);

        runner.* = .{
            .arena = arena,
            .data_sets = .{},
            .scenarios = .{},
        };

        return runner;
    }

    /// Deinitialize the benchmark runner
    pub fn deinit(self: *BenchmarkRunner) void {
        self.data_sets.deinit(self.arena);
        self.scenarios.deinit(self.arena);
    }

    /// Add a data set from a file
    pub fn addDataFromFile(self: *BenchmarkRunner, name: []const u8, path: []const u8) !void {
        const data = try std.fs.cwd().readFileAlloc(self.arena, path, 100 * 1024 * 1024);

        try self.data_sets.append(
            self.arena,
            .{
                .name = name,
                .buffer = data,
            },
        );
    }

    pub fn addGenerated(self: *BenchmarkRunner, name: []const u8, size: usize) !void {
        const buffer = try self.arena.alloc(u8, size);

        generateSynthetic(buffer);

        try self.data_sets.append(
            self.arena,
            .{
                .name = name,
                .buffer = buffer,
            },
        );
    }

    pub fn addScenario(self: *BenchmarkRunner, mode: Mode, name: []const u8, options: gcode_parser.ParserOptions) !void {
        try self.scenarios.append(
            self.arena,
            .{
                .name = name,
                .mode = mode,
                .options = options,
            },
        );
    }

    pub fn runAll(self: *BenchmarkRunner) !void {
        std.debug.print("\n┌───── G-code Parser Benchmarks ─────┐\n", .{});
        for (self.scenarios.items) |scn| {
            for (self.data_sets.items) |data| {
                const res = try self.runOne(scn, data);
                printResult(res);
            }
        }
        std.debug.print("└────────────────────────────────────┘\n", .{});
    }

    fn runOne(self: *BenchmarkRunner, scn: Scenario, data: DataSet) !BenchmarkResult {
        var counting = CountingAllocator.init(self.arena);
        const alloc = counting.allocator();

        var t = try std.time.Timer.start();
        var blocks: usize = 0;
        var words: usize = 0;

        switch (scn.mode) {
            .slice_iter, .slice_batch => {
                var fbs = std.io.fixedBufferStream(data.buffer);
                var parser = try gcode_parser.Parser(f64).fromReader(alloc, fbs.reader().any(), scn.options);

                if (scn.mode == .stream_iter) {
                    while (try parser.next()) |blk| {
                        blocks += 1;
                        words += blk.words.len;
                    }
                } else {
                    const res = try parser.collect();
                    blocks = res.blocks.len;
                    words = res.word_buffer.len;
                }
            },
            .stream_iter, .stream_batch => {
                var fbs = std.io.fixedBufferStream(data.buffer);
                var parser = try gcode_parser.Parser(f64).fromReader(alloc, fbs.reader().any(), scn.options);

                if (scn.mode == .stream_iter) {
                    while (try parser.next()) |blk| {
                        blocks += 1;
                        words += blk.words.len;
                    }
                } else {
                    const res = try parser.collect();
                    blocks = res.blocks.len;
                    words = res.word_buffer.len;
                }
            },
        }

        const dur = t.read();
        const mb = @as(f64, @floatFromInt(data.buffer.len)) / 1024.0 / 1024.0;
        const thr = mb * 1_000_000_000.0 / @as(f64, @floatFromInt(dur));

        return .{
            .name = scn.name,
            .duration_ns = dur,
            .memory_used = counting.peak,
            .throughput_mb_per_sec = thr,
            .input_size = data.buffer.len,
            .blocks_parsed = blocks,
            .words_parsed = words,
        };
    }
};

const DataSet = struct {
    name: []const u8,
    buffer: []u8,
};

const Scenario = struct {
    name: []const u8,
    mode: Mode,
    options: gcode_parser.ParserOptions,
    float32: bool = false,
};

const BenchmarkResult = struct {
    name: []const u8,
    duration_ns: u64,
    memory_used: usize,
    throughput_mb_per_sec: f64,
    input_size: usize,
    blocks_parsed: usize,
    words_parsed: usize,
};

/// Generate synthetic data for testing
fn generateSynthetic(buffer: []u8) void {
    var writer = std.io.fixedBufferStream(buffer);
    var w = writer.writer();
    var i: usize = 0;

    while (i < buffer.len) : (i += 1) {
        // Simple but representative: alternating comment / command lines
        _ = w.print("G1 X{d:.2} Y{d:.2}\n", .{ i % 200, i % 400 }) catch {};
    }
}

/// Simple counting allocator for benchmarking memory behaviour.
/// Must out‑live every allocation that is made through it.
pub const CountingAllocator = struct {
    parent: std.mem.Allocator,
    bytes: usize = 0,
    peak: usize = 0,
    allocation_count: usize = 0,

    // ---------- construction ----------
    pub fn init(parent: std.mem.Allocator) CountingAllocator {
        return .{ .parent = parent };
    }

    /// Returns the wrapped `std.mem.Allocator` interface.
    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .free = free,
                .resize = resize,
                .remap = remap,
            },
        };
    }

    // ---------- helper ----------
    inline fn selfFrom(ctx: *anyopaque) *CountingAllocator {
        // `@ptrCast` is single‑argument in 0.14; destination type via `@as`
        return @as(*CountingAllocator, @alignCast(@ptrCast(ctx)));
    }

    // ---------- VTable implementation ----------
    fn alloc(
        ctx: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        ra: usize,
    ) ?[*]u8 {
        const self = selfFrom(ctx);
        const ptr = self.parent.rawAlloc(len, alignment, ra) orelse return null;

        self.bytes += len;
        self.allocation_count += 1;
        self.peak = @max(self.peak, self.bytes);
        return ptr;
    }

    fn free(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ra: usize,
    ) void {
        const self = selfFrom(ctx);
        self.parent.rawFree(memory, alignment, ra);
        self.bytes -= memory.len;
    }

    fn resize(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ra: usize,
    ) bool {
        const self = selfFrom(ctx);
        const old_len = memory.len;

        if (!self.parent.rawResize(memory, alignment, new_len, ra))
            return false;

        const delta = if (new_len > old_len) new_len - old_len else old_len - new_len;
        if (new_len > old_len) {
            self.bytes += delta;
            self.peak = @max(self.peak, self.bytes);
        } else {
            self.bytes -= delta;
        }
        return true;
    }

    fn remap(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ra: usize,
    ) ?[*]u8 {
        const self = selfFrom(ctx);
        const old_len = memory.len;

        const new_ptr = self.parent.rawRemap(memory, alignment, new_len, ra) orelse
            return null;

        const delta = if (new_len > old_len) new_len - old_len else old_len - new_len;
        if (new_len > old_len) {
            self.bytes += delta;
            self.peak = @max(self.peak, self.bytes);
        } else {
            self.bytes -= delta;
        }
        return new_ptr;
    }
};

fn printResult(results: BenchmarkResult) void {
    std.debug.print("{s:14} | {d:7.2} MB/s | {d:>6} µs | {d:>7} KB | {d:>6} blk | {d:>7} words\n", .{ results.name, results.throughput_mb_per_sec, results.duration_ns / 1_000, results.memory_used / 1024, results.blocks_parsed, results.words_parsed });
}
