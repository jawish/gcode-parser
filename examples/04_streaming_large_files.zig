const std = @import("std");
const gcode_parser = @import("gcode_parser");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("G-code Parser - Streaming Large Files\n", .{});
    std.debug.print("=====================================\n\n", .{});

    // Example 1: Basic streaming from file
    try demonstrateBasicStreaming(allocator);

    // Example 2: Processing large files efficiently
    try demonstrateLargeFileProcessing(allocator);

    // Example 3: Streaming with resource limits
    try demonstrateResourceProtection(allocator);

    // Example 4: Real-world streaming patterns
    try demonstrateRealWorldPatterns(allocator);
}

/// Demonstrates basic streaming functionality
fn demonstrateBasicStreaming(allocator: std.mem.Allocator) !void {
    std.debug.print("1. Basic Streaming from File\n", .{});
    std.debug.print("   Memory-efficient processing of G-code files\n\n", .{});

    // Create a sample G-code file
    const sample_gcode =
        \\; Sample 3D print file
        \\G28 ; Home all axes
        \\G90 ; Absolute positioning
        \\G21 ; Set units to millimeters
        \\M104 S200 ; Set extruder temperature
        \\M140 S60 ; Set bed temperature
        \\M190 S60 ; Wait for bed temperature
        \\M109 S200 ; Wait for extruder temperature
        \\G1 F1500 ; Set feed rate
        \\G1 X10 Y10 Z0.2 ; Move to start position
        \\G1 X20 Y10 E5 F300 ; First extrusion
        \\G1 X20 Y20 E5 ; Second extrusion
        \\G1 X10 Y20 E5 ; Third extrusion
        \\G1 X10 Y10 E5 ; Complete square
        \\G1 Z5 ; Lift nozzle
        \\G28 ; Home again
        \\M104 S0 ; Turn off extruder
        \\M140 S0 ; Turn off bed
    ;

    const filename = "sample_print.gcode";

    // Write sample file
    {
        const file = try std.fs.cwd().createFile(filename, .{});
        defer file.close();
        try file.writeAll(sample_gcode);
    }
    defer std.fs.cwd().deleteFile(filename) catch {};

    // Stream from file
    const file = try std.fs.cwd().openFile(filename, .{});
    defer file.close();

    var buffered_reader = std.io.bufferedReader(file.reader());
    var parser = try gcode_parser.Parser(f32).fromReader(allocator, buffered_reader.reader().any(), null);
    defer parser.deinit();

    std.debug.print("   Processing file: {s}\n", .{filename});

    var stats = struct {
        blocks: usize = 0,
        movements: usize = 0,
        temperature_commands: usize = 0,
    }{};

    while (true) {
        const maybe_block = parser.next() catch break;
        if (maybe_block) |block| {
            stats.blocks += 1;

            // Count different types of commands
            for (block.words) |word| {
                switch (word.letter) {
                    'G' => {
                        if (word.value.float == 1 or word.value.float == 0) {
                            stats.movements += 1;
                        }
                    },
                    'M' => {
                        if (word.value.float == 104 or word.value.float == 140 or word.value.float == 109 or word.value.float == 190) {
                            stats.temperature_commands += 1;
                        }
                    },
                    else => {},
                }
            }
        } else {
            break;
        }
    }

    std.debug.print("   Statistics:\n", .{});
    std.debug.print("   - Total blocks: {d}\n", .{stats.blocks});
    std.debug.print("   - Movement commands: {d}\n", .{stats.movements});
    std.debug.print("   - Temperature commands: {d}\n", .{stats.temperature_commands});
    std.debug.print("   - Memory usage: Constant (~1KB buffer)\n\n", .{});
}

/// Demonstrates processing large files efficiently
fn demonstrateLargeFileProcessing(allocator: std.mem.Allocator) !void {
    std.debug.print("2. Large File Processing\n", .{});
    std.debug.print("   Simulating processing of large G-code files\n\n", .{});

    // Create a larger sample file
    const large_filename = "large_sample.gcode";
    const lines_to_generate = 1000;

    {
        const file = try std.fs.cwd().createFile(large_filename, .{});
        defer file.close();
        var writer = file.writer();

        // Generate repetitive G-code
        try writer.print("; Large G-code file with {d} lines\n", .{lines_to_generate});
        var i: usize = 0;
        while (i < lines_to_generate) : (i += 1) {
            try writer.print("G1 X{d} Y{d} Z0.2 F1500\n", .{ i % 100, (i * 2) % 100 });
        }
        try writer.writeAll("M104 S0 ; End of file\n");
    }
    defer std.fs.cwd().deleteFile(large_filename) catch {};

    // Stream process the large file
    const file = try std.fs.cwd().openFile(large_filename, .{});
    defer file.close();

    var buffered_reader = std.io.bufferedReader(file.reader());
    var parser = try gcode_parser.Parser(f32).fromReader(allocator, buffered_reader.reader().any(), null);
    defer parser.deinit();

    std.debug.print("   Processing large file: {s}\n", .{large_filename});

    var timer = try std.time.Timer.start();
    var block_count: usize = 0;
    var total_words: usize = 0;
    var max_x: f32 = 0;
    var max_y: f32 = 0;

    while (true) {
        const maybe_block = parser.next() catch break;
        if (maybe_block) |block| {
            block_count += 1;
            total_words += block.words.len;

            // Track maximum coordinates
            for (block.words) |word| {
                switch (word.letter) {
                    'X' => max_x = @max(max_x, word.value.float),
                    'Y' => max_y = @max(max_y, word.value.float),
                    else => {},
                }
            }

            // Progress indicator for large files
            if (block_count % 100 == 0) {
                std.debug.print("   -> Processed {d} blocks...\n", .{block_count});
            }
        } else {
            break;
        }
    }

    const elapsed = timer.read();
    const elapsed_ms = @as(f64, @floatFromInt(elapsed)) / 1_000_000.0;

    std.debug.print("   Results:\n", .{});
    std.debug.print("   - Total blocks processed: {d}\n", .{block_count});
    std.debug.print("   - Total words processed: {d}\n", .{total_words});
    std.debug.print("   - Processing time: {d:.2}ms\n", .{elapsed_ms});
    std.debug.print("   - Speed: {d:.0} blocks/sec\n", .{@as(f64, @floatFromInt(block_count)) / (elapsed_ms / 1000.0)});
    std.debug.print("   - Max coordinates: X={d:.1}, Y={d:.1}\n", .{ max_x, max_y });
    std.debug.print("\n", .{});
}

/// Demonstrates resource protection with streaming
fn demonstrateResourceProtection(allocator: std.mem.Allocator) !void {
    std.debug.print("3. Resource Protection\n", .{});
    std.debug.print("   Protecting against malicious or corrupted files\n\n", .{});

    // Create a file that would exceed limits
    const protected_filename = "protected_test.gcode";
    {
        const file = try std.fs.cwd().createFile(protected_filename, .{});
        defer file.close();
        var writer = file.writer();

        // Create a file with many blocks to test limits
        var i: usize = 0;
        while (i < 10) : (i += 1) {
            try writer.print("G1 X{d} Y{d}\n", .{ i, i });
        }
    }
    defer std.fs.cwd().deleteFile(protected_filename) catch {};

    // Set strict limits
    const limited_options = gcode_parser.ParserOptions{
        .limits = .{
            .max_blocks = 5, // Only allow 5 blocks
            .max_words_per_block = 10,
        },
    };

    const file = try std.fs.cwd().openFile(protected_filename, .{});
    defer file.close();

    var buffered_reader = std.io.bufferedReader(file.reader());
    var parser = try gcode_parser.Parser(f32).fromReader(allocator, buffered_reader.reader().any(), limited_options);
    defer parser.deinit();

    std.debug.print("   Testing with limits: max_blocks=5, max_words_per_block=10\n", .{});

    var processed_blocks: usize = 0;
    while (true) {
        const maybe_block = parser.next() catch |err| switch (err) {
            error.TooManyBlocks => {
                std.debug.print("   -> PROTECTION: Stopped at block limit ({d} blocks processed)\n", .{processed_blocks});
                std.debug.print("   -> This prevents processing of extremely large files\n", .{});
                break;
            },
            else => {
                std.debug.print("   -> Unexpected error: {}\n", .{err});
                break;
            },
        };

        if (maybe_block) |block| {
            processed_blocks += 1;
            std.debug.print("   - Block {d}: {d} words\n", .{ processed_blocks, block.words.len });
        } else {
            break;
        }
    }
    std.debug.print("\n", .{});
}

/// Demonstrates real-world streaming patterns
fn demonstrateRealWorldPatterns(allocator: std.mem.Allocator) !void {
    std.debug.print("4. Real-World Streaming Patterns\n", .{});
    std.debug.print("   Practical examples of streaming usage\n\n", .{});

    // Pattern 1: G-code validation
    std.debug.print("   Pattern 1: G-code File Validation\n", .{});
    try validateGcodeFile(allocator);

    // Pattern 2: Print time estimation
    std.debug.print("   Pattern 2: Print Time Estimation\n", .{});
    try estimatePrintTime(allocator);

    // Pattern 3: Coordinate bounds checking
    std.debug.print("   Pattern 3: Coordinate Bounds Checking\n", .{});
    try checkCoordinateBounds(allocator);
}

fn validateGcodeFile(allocator: std.mem.Allocator) !void {
    const validation_gcode =
        \\G28 ; Home
        \\G90 ; Absolute
        \\G1 X10 Y10 F1500
        \\G1 X20 Y20
        \\M104 S0 ; End
    ;

    const validation_file = "validation_test.gcode";
    {
        const file = try std.fs.cwd().createFile(validation_file, .{});
        defer file.close();
        try file.writeAll(validation_gcode);
    }
    defer std.fs.cwd().deleteFile(validation_file) catch {};

    const file = try std.fs.cwd().openFile(validation_file, .{});
    defer file.close();

    var buffered_reader = std.io.bufferedReader(file.reader());
    var parser = try gcode_parser.Parser(f32).fromReader(allocator, buffered_reader.reader().any(), null);
    defer parser.deinit();

    var validation_result = struct {
        valid_blocks: usize = 0,
        has_homing: bool = false,
        has_positioning_mode: bool = false,
        has_movements: bool = false,
    }{};

    while (true) {
        const maybe_block = parser.next() catch break;
        if (maybe_block) |block| {
            validation_result.valid_blocks += 1;

            for (block.words) |word| {
                if (word.letter == 'G') {
                    if (word.value.float == 28) validation_result.has_homing = true;
                    if (word.value.float == 90 or word.value.float == 91) validation_result.has_positioning_mode = true;
                    if (word.value.float == 1 or word.value.float == 0) validation_result.has_movements = true;
                }
            }
        } else {
            break;
        }
    }

    std.debug.print("   - Valid blocks: {d}\n", .{validation_result.valid_blocks});
    std.debug.print("   - Has homing: {}\n", .{validation_result.has_homing});
    std.debug.print("   - Has positioning mode: {}\n", .{validation_result.has_positioning_mode});
    std.debug.print("   - Has movements: {}\n", .{validation_result.has_movements});
}

fn estimatePrintTime(allocator: std.mem.Allocator) !void {
    const time_estimation_gcode =
        \\G1 X10 Y10 F1500 ; 1500 mm/min
        \\G1 X20 Y20 F3000 ; 3000 mm/min
        \\G1 X30 Y30 F600  ; 600 mm/min
    ;

    const time_file = "time_test.gcode";
    {
        const file = try std.fs.cwd().createFile(time_file, .{});
        defer file.close();
        try file.writeAll(time_estimation_gcode);
    }
    defer std.fs.cwd().deleteFile(time_file) catch {};

    const file = try std.fs.cwd().openFile(time_file, .{});
    defer file.close();

    var buffered_reader = std.io.bufferedReader(file.reader());
    var parser = try gcode_parser.Parser(f32).fromReader(allocator, buffered_reader.reader().any(), null);
    defer parser.deinit();

    var current_feed_rate: f32 = 1500; // Default feed rate
    var total_time: f32 = 0; // seconds
    var prev_x: f32 = 0;
    var prev_y: f32 = 0;

    while (true) {
        const maybe_block = parser.next() catch break;
        if (maybe_block) |block| {
            var x: f32 = prev_x;
            var y: f32 = prev_y;

            for (block.words) |word| {
                switch (word.letter) {
                    'F' => current_feed_rate = word.value.float,
                    'X' => x = word.value.float,
                    'Y' => y = word.value.float,
                    else => {},
                }
            }

            // Calculate distance and time
            const distance = @sqrt((x - prev_x) * (x - prev_x) + (y - prev_y) * (y - prev_y));
            const time_for_move = distance / (current_feed_rate / 60.0); // Convert mm/min to mm/sec
            total_time += time_for_move;

            prev_x = x;
            prev_y = y;
        } else {
            break;
        }
    }

    std.debug.print("   - Estimated print time: {d:.2} seconds\n", .{total_time});
}

fn checkCoordinateBounds(allocator: std.mem.Allocator) !void {
    const bounds_gcode =
        \\G1 X0 Y0
        \\G1 X100 Y50
        \\G1 X200 Y150
        \\G1 X-10 Y200
    ;

    const bounds_file = "bounds_test.gcode";
    {
        const file = try std.fs.cwd().createFile(bounds_file, .{});
        defer file.close();
        try file.writeAll(bounds_gcode);
    }
    defer std.fs.cwd().deleteFile(bounds_file) catch {};

    const file = try std.fs.cwd().openFile(bounds_file, .{});
    defer file.close();

    var buffered_reader = std.io.bufferedReader(file.reader());
    var parser = try gcode_parser.Parser(f32).fromReader(allocator, buffered_reader.reader().any(), null);
    defer parser.deinit();

    var bounds = struct {
        min_x: f32 = std.math.inf(f32),
        max_x: f32 = -std.math.inf(f32),
        min_y: f32 = std.math.inf(f32),
        max_y: f32 = -std.math.inf(f32),
    }{};

    while (true) {
        const maybe_block = parser.next() catch break;
        if (maybe_block) |block| {
            for (block.words) |word| {
                switch (word.letter) {
                    'X' => {
                        bounds.min_x = @min(bounds.min_x, word.value.float);
                        bounds.max_x = @max(bounds.max_x, word.value.float);
                    },
                    'Y' => {
                        bounds.min_y = @min(bounds.min_y, word.value.float);
                        bounds.max_y = @max(bounds.max_y, word.value.float);
                    },
                    else => {},
                }
            }
        } else {
            break;
        }
    }

    std.debug.print("   - X bounds: {d:.1} to {d:.1} mm\n", .{ bounds.min_x, bounds.max_x });
    std.debug.print("   - Y bounds: {d:.1} to {d:.1} mm\n", .{ bounds.min_y, bounds.max_y });
    std.debug.print("   - Print area: {d:.1} x {d:.1} mm\n", .{ bounds.max_x - bounds.min_x, bounds.max_y - bounds.min_y });
    std.debug.print("\n", .{});
}
