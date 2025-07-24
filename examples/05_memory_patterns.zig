const std = @import("std");
const gcode_parser = @import("gcode_parser");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("G-code Parser - Memory Management Patterns\n", .{});
    std.debug.print("==========================================\n\n", .{});

    // Example 1: Proper resource cleanup
    try demonstrateResourceCleanup(allocator);

    // Example 2: Ephemeral vs persistent data
    try demonstrateEphemeralVsPersistent(allocator);

    // Example 3: Arena allocator pattern
    try demonstrateArenaPattern(allocator);

    // Example 4: Memory usage comparison
    try demonstrateMemoryUsage(allocator);
}

/// Demonstrates proper resource cleanup patterns
fn demonstrateResourceCleanup(allocator: std.mem.Allocator) !void {
    std.debug.print("1. Proper Resource Cleanup\n", .{});
    std.debug.print("   Critical patterns to prevent memory leaks\n\n", .{});

    const gcode = "G1 X10 Y20\nG1 Z5 F1500\nM104 S200";

    // ✅ CORRECT: Iterator parsing with defer
    std.debug.print("   Iterator parsing (streaming):\n", .{});
    {
        var parser = try gcode_parser.Parser(f32).fromSlice(allocator, gcode, null);
        defer parser.deinit(); // CRITICAL: Always use defer

        var block_count: usize = 0;
        while (try parser.next()) |block| {
            block_count += 1;
            std.debug.print("   - Block {d}: {d} words\n", .{ block_count, block.words.len });
            // Note: block.words is ephemeral - reused on next iteration
        }
    } // Parser automatically cleaned up here

    // ✅ CORRECT: Batch parsing with defer
    std.debug.print("   Batch parsing (all blocks):\n", .{});
    {
        var parser = try gcode_parser.Parser(f32).fromSlice(allocator, gcode, null);
        defer parser.deinit(); // CRITICAL: Always use defer

        const result = try parser.collect();
        defer result.deinit(allocator); // CRITICAL: Always use defer

        std.debug.print("   - Collected {d} blocks\n", .{result.blocks.len});
        // Note: result.blocks is persistent - valid until deinit()
    } // Both parser and result automatically cleaned up here

    // ❌ WRONG: Forgetting to call deinit() will leak memory
    std.debug.print("   Memory leak warning:\n", .{});
    std.debug.print("   - Always call parser.deinit()\n", .{});
    std.debug.print("   - Always call result.deinit(allocator)\n", .{});
    std.debug.print("   - Use defer to ensure cleanup happens\n\n", .{});
}

/// Demonstrates the difference between ephemeral and persistent data
fn demonstrateEphemeralVsPersistent(allocator: std.mem.Allocator) !void {
    std.debug.print("2. Ephemeral vs Persistent Data\n", .{});
    std.debug.print("   Understanding data lifetime in different parsing modes\n\n", .{});

    const gcode = "G1 X10 Y20\nG1 X30 Y40\nG1 X50 Y60";

    // Ephemeral data (iterator parsing)
    std.debug.print("   Ephemeral data (iterator):\n", .{});
    {
        const Parser = gcode_parser.Parser(f32);
        var parser = try Parser.fromSlice(allocator, gcode, null);
        defer parser.deinit();

        var saved_blocks: [3]?Parser.Block = .{ null, null, null };
        var i: usize = 0;

        while (try parser.next()) |block| {
            if (i < saved_blocks.len) {
                saved_blocks[i] = block; // ❌ DANGEROUS: Saving ephemeral data
            }
            i += 1;

            std.debug.print("   - Block {d} at address {*}\n", .{ i, &block });
        }

        // ❌ DANGEROUS: Accessing saved ephemeral data after parsing
        std.debug.print("   - Saved blocks may be invalid now:\n", .{});
        for (saved_blocks, 0..) |saved_block, idx| {
            if (saved_block) |block| {
                std.debug.print("     Block {d}: {d} words (may be corrupted)\n", .{ idx + 1, block.words.len });
            }
        }
    }

    // Persistent data (batch parsing)
    std.debug.print("   Persistent data (batch):\n", .{});
    {
        var parser = try gcode_parser.Parser(f32).fromSlice(allocator, gcode, null);
        defer parser.deinit();

        const result = try parser.collect();
        defer result.deinit(allocator);

        // ✅ SAFE: Data is persistent until result.deinit()
        std.debug.print("   - All blocks remain valid:\n", .{});
        for (result.blocks, 0..) |block, idx| {
            std.debug.print("     Block {d}: {d} words at line {d}\n", .{ idx + 1, block.words.len, block.line_number });
        }

        // ✅ SAFE: Can access blocks multiple times
        std.debug.print("   - Can access blocks multiple times:\n", .{});
        for (result.blocks) |block| {
            var has_movement = false;
            for (block.words) |word| {
                if (word.letter == 'G' and word.value.float == 1) {
                    has_movement = true;
                    break;
                }
            }
            if (has_movement) {
                std.debug.print("     Line {d}: Movement command\n", .{block.line_number});
            }
        }
    }
    std.debug.print("\n", .{});
}

/// Demonstrates arena allocator pattern for temporary processing
fn demonstrateArenaPattern(allocator: std.mem.Allocator) !void {
    std.debug.print("3. Arena Allocator Pattern\n", .{});
    std.debug.print("   Efficient pattern for temporary processing\n\n", .{});

    const gcode = "G1 X10 Y20\nG1 X30 Y40\nG1 X50 Y60\nG1 X70 Y80";

    // Arena allocator for temporary processing
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit(); // Automatically frees all arena allocations

    const arena_allocator = arena.allocator();

    std.debug.print("   Using arena allocator for batch processing:\n", .{});
    {
        var parser = try gcode_parser.Parser(f32).fromSlice(arena_allocator, gcode, null);
        defer parser.deinit(); // Will be freed by arena anyway

        const result = try parser.collect();
        // Note: No need to call result.deinit() - arena handles it

        std.debug.print("   - Processed {d} blocks\n", .{result.blocks.len});

        // Process data and extract what we need
        var coordinates = std.ArrayList(struct { x: f32, y: f32 }).init(allocator);
        defer coordinates.deinit();

        for (result.blocks) |block| {
            var x: f32 = 0;
            var y: f32 = 0;
            var has_coords = false;

            for (block.words) |word| {
                switch (word.letter) {
                    'X' => {
                        x = word.value.float;
                        has_coords = true;
                    },
                    'Y' => {
                        y = word.value.float;
                        has_coords = true;
                    },
                    else => {},
                }
            }

            if (has_coords) {
                try coordinates.append(.{ .x = x, .y = y });
            }
        }

        std.debug.print("   - Extracted {d} coordinate pairs\n", .{coordinates.items.len});
        for (coordinates.items, 0..) |coord, idx| {
            std.debug.print("     {d}: ({d:.1}, {d:.1})\n", .{ idx + 1, coord.x, coord.y });
        }
    }
    // Arena automatically frees all temporary allocations here
    std.debug.print("   - Arena automatically freed all temporary data\n\n", .{});
}

/// Demonstrates memory usage comparison between different parsing methods
fn demonstrateMemoryUsage(allocator: std.mem.Allocator) !void {
    std.debug.print("4. Memory Usage Comparison\n", .{});
    std.debug.print("   Understanding memory characteristics of different approaches\n\n", .{});

    // Create test data
    const base_gcode = "G1 X10 Y20 Z0.2 F1500 E5\n";
    const repetitions = 100;

    var test_gcode = std.ArrayList(u8).init(allocator);
    defer test_gcode.deinit();

    var i: usize = 0;
    while (i < repetitions) : (i += 1) {
        try test_gcode.appendSlice(base_gcode);
    }

    std.debug.print("   Test data: {d} bytes, {d} lines\n", .{ test_gcode.items.len, repetitions });

    // Method 1: Iterator parsing (constant memory)
    std.debug.print("   Method 1 - Iterator parsing:\n", .{});
    {
        var parser = try gcode_parser.Parser(f32).fromSlice(allocator, test_gcode.items, null);
        defer parser.deinit();

        var block_count: usize = 0;
        while (try parser.next()) |_| {
            block_count += 1;
        }

        std.debug.print("   - Processed {d} blocks\n", .{block_count});
        std.debug.print("   - Memory usage: Constant (~1KB internal buffer)\n", .{});
        std.debug.print("   - Best for: Large files, streaming processing\n", .{});
    }

    // Method 2: Batch parsing (memory scales with input)
    std.debug.print("   Method 2 - Batch parsing:\n", .{});
    {
        const Parser = gcode_parser.Parser(f32);
        var parser = try Parser.fromSlice(allocator, test_gcode.items, null);
        defer parser.deinit();

        const result = try parser.collect();
        defer result.deinit(allocator);

        const estimated_memory = result.blocks.len * @sizeOf(Parser.Block) +
            result.word_buffer.len * @sizeOf(Parser.Word);

        std.debug.print("   - Processed {d} blocks\n", .{result.blocks.len});
        std.debug.print("   - Words stored: {d}\n", .{result.word_buffer.len});
        std.debug.print("   - Estimated memory: ~{d} bytes\n", .{estimated_memory});
        std.debug.print("   - Best for: Random access, multiple passes\n", .{});
    }

    // Method 3: Streaming from "file" (constant memory)
    std.debug.print("   Method 3 - Streaming from reader:\n", .{});
    {
        var stream = std.io.fixedBufferStream(test_gcode.items);
        var parser = try gcode_parser.Parser(f32).fromReader(allocator, stream.reader().any(), null);
        defer parser.deinit();

        var block_count: usize = 0;
        while (try parser.next()) |_| {
            block_count += 1;
        }

        std.debug.print("   - Processed {d} blocks\n", .{block_count});
        std.debug.print("   - Memory usage: Constant (~1KB internal buffer)\n", .{});
        std.debug.print("   - Best for: Large files, network streams\n", .{});
    }

    std.debug.print("   Summary:\n", .{});
    std.debug.print("   - Iterator/Streaming: O(1) memory, single pass\n", .{});
    std.debug.print("   - Batch: O(n) memory, random access\n", .{});
    std.debug.print("   - Choose based on your specific needs\n\n", .{});
}
