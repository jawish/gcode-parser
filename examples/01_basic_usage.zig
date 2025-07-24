const std = @import("std");
const gcode_parser = @import("gcode_parser");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("G-code Parser - Basic Usage Examples\n", .{});
    std.debug.print("====================================\n\n", .{});

    // Sample G-code for demonstrations
    const sample_gcode =
        \\; 3D printer startup sequence
        \\G90 ; Absolute positioning
        \\G21 ; Set units to millimeters
        \\M104 S200 ; Set extruder temperature
        \\M140 S60 ; Set bed temperature
        \\G28 ; Home all axes
        \\G1 X10 Y10 Z0.2 F1500 ; Move to start position
        \\G1 X20 Y10 E5 F300 ; Extrude first line
        \\G1 X20 Y20 E5 ; Second line
        \\M104 S0 ; Turn off extruder
        \\M140 S0 ; Turn off bed
    ;

    // Example 1: Iterator-based parsing (most common)
    try demonstrateIteratorParsing(allocator, sample_gcode);

    // Example 2: Batch parsing (when you need all blocks at once)
    try demonstrateBatchParsing(allocator, sample_gcode);

    // Example 3: Streaming from file
    try demonstrateFileParsing(allocator, sample_gcode);

    // Example 4: Basic configuration
    try demonstrateBasicConfiguration(allocator, sample_gcode);
}

/// Demonstrates iterator-based parsing - the most memory-efficient approach
fn demonstrateIteratorParsing(allocator: std.mem.Allocator, gcode: []const u8) !void {
    std.debug.print("1. Iterator-based Parsing (Recommended)\n", .{});
    std.debug.print("   Memory-efficient, processes one block at a time\n\n", .{});

    // Create parser from slice
    var parser = try gcode_parser.Parser(f32).fromSlice(allocator, gcode, null);
    defer parser.deinit(); // Always call deinit!

    var block_count: usize = 0;
    while (try parser.next()) |block| {
        block_count += 1;
        std.debug.print("   Block {d} (line {d}): ", .{ block_count, block.line_number });

        // Print each word in the block
        for (block.words) |word| {
            std.debug.print("{c}{d:.1} ", .{ word.letter, word.value.float });
        }
        std.debug.print("\n", .{});
    }

    std.debug.print("   Total blocks parsed: {d}\n\n", .{block_count});
}

/// Demonstrates batch parsing - when you need all blocks in memory
fn demonstrateBatchParsing(allocator: std.mem.Allocator, gcode: []const u8) !void {
    std.debug.print("2. Batch Parsing\n", .{});
    std.debug.print("   Loads all blocks into memory for random access\n\n", .{});

    // Create parser and collect all blocks
    var parser = try gcode_parser.Parser(f32).fromSlice(allocator, gcode, null);
    defer parser.deinit();

    const result = try parser.collect();
    defer result.deinit(allocator); // Always call deinit!

    std.debug.print("   Parsed {d} blocks total\n", .{result.blocks.len});

    // Now we can access blocks randomly
    for (result.blocks, 0..) |block, i| {
        std.debug.print("   Block {d}: {d} words ", .{ i + 1, block.words.len });
        // Show only G and M codes for brevity
        for (block.words) |word| {
            if (word.letter == 'G' or word.letter == 'M') {
                std.debug.print("{c}{d:.0} ", .{ word.letter, word.value.float });
            }
        }
        std.debug.print("\n", .{});
    }
    std.debug.print("\n", .{});
}

/// Demonstrates parsing from a file using streaming
fn demonstrateFileParsing(allocator: std.mem.Allocator, gcode: []const u8) !void {
    std.debug.print("3. File-based Parsing\n", .{});
    std.debug.print("   Streaming from file for large G-code files\n\n", .{});

    // Create a temporary file for demonstration
    const temp_file = "temp_sample.gcode";
    {
        const file = try std.fs.cwd().createFile(temp_file, .{});
        defer file.close();
        try file.writeAll(gcode);
    }
    defer std.fs.cwd().deleteFile(temp_file) catch {};

    // Open file and create streaming parser
    const file = try std.fs.cwd().openFile(temp_file, .{});
    defer file.close();

    var buffered_reader = std.io.bufferedReader(file.reader());
    var parser = try gcode_parser.Parser(f32).fromReader(allocator, buffered_reader.reader().any(), null);
    defer parser.deinit();

    var movement_count: usize = 0;
    while (try parser.next()) |block| {
        // Count G1 (linear move) commands
        for (block.words) |word| {
            if (word.letter == 'G' and word.value.float == 1) {
                movement_count += 1;
                break;
            }
        }
    }

    std.debug.print("   Found {d} movement commands (G1) in file\n\n", .{movement_count});
}

/// Demonstrates basic configuration options
fn demonstrateBasicConfiguration(allocator: std.mem.Allocator, gcode: []const u8) !void {
    std.debug.print("4. Basic Configuration\n", .{});
    std.debug.print("   Using parser options for different behaviors\n\n", .{});

    // Configure parser with limits
    const options = gcode_parser.ParserOptions{
        .limits = .{
            .max_blocks = 5, // Only parse first 5 blocks
            .max_words_per_block = 10,
        },
        .skip_empty_lines = true,
    };

    var parser = try gcode_parser.Parser(f32).fromSlice(allocator, gcode, options);
    defer parser.deinit();

    var block_count: usize = 0;
    while (true) {
        const maybe_block = parser.next() catch |err| switch (err) {
            error.TooManyBlocks => {
                std.debug.print("   Stopped at block limit ({d} blocks)\n", .{block_count});
                break;
            },
            else => return err,
        };

        if (maybe_block) |block| {
            block_count += 1;
            std.debug.print("   Block {d}: {d} words\n", .{ block_count, block.words.len });
        } else {
            break;
        }
    }
    std.debug.print("\n", .{});
}
