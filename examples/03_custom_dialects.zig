const std = @import("std");
const gcode_parser = @import("gcode_parser");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("G-code Parser - Custom Dialects & Address Configuration\n", .{});
    std.debug.print("=======================================================\n\n", .{});

    // Example 1: Understanding address letters
    try explainAddressLetters(allocator);

    // Example 2: Creating custom dialects
    try demonstrateCustomDialects(allocator);

    // Example 3: Case sensitivity
    try demonstrateCaseSensitivity(allocator);
}

/// Explains what address letters are and how they work
fn explainAddressLetters(allocator: std.mem.Allocator) !void {
    std.debug.print("1. Understanding Address Letters\n", .{});
    std.debug.print("   Address letters are the command letters before numeric values\n\n", .{});

    const example_gcode = "G1 X10 Y20 Z0.2 F1500 E5.0 S200 P100";
    std.debug.print("   Example: {s}\n", .{example_gcode});
    std.debug.print("   Address letters: G, X, Y, Z, F, E, S, P\n\n", .{});

    // Parse with default RepRap dialect
    var parser = try gcode_parser.Parser(f32).fromSlice(allocator, example_gcode, null);
    defer parser.deinit();

    const maybe_block = parser.next() catch return;
    if (maybe_block) |block| {
        std.debug.print("   Parsed words:\n", .{});
        for (block.words) |word| {
            const meaning = switch (word.letter) {
                'G' => "G-code command",
                'X' => "X-axis position",
                'Y' => "Y-axis position",
                'Z' => "Z-axis position",
                'F' => "Feed rate",
                'E' => "Extruder position",
                'S' => "Spindle speed/parameter",
                'P' => "Parameter/pause time",
                else => "Other",
            };
            std.debug.print("   - {c}{d:.1} ({s})\n", .{ word.letter, word.value.float, meaning });
        }
    }
    std.debug.print("\n", .{});
}

/// Demonstrates creating custom dialects
fn demonstrateCustomDialects(allocator: std.mem.Allocator) !void {
    std.debug.print("3. Creating Custom Dialects\n", .{});
    std.debug.print("   Tailoring address letters for specific applications\n\n", .{});

    const specialized_gcode = "G1 X10 Y20 Z5 L100 Q50 D25"; // L, Q, D are uncommon
    std.debug.print("   Specialized G-code: {s}\n", .{specialized_gcode});

    // Custom dialect for a specialized machine
    const custom_dialect = try gcode_parser.AddressConfig.init("GMXYZFSTLQD", // Only these letters allowed
        true // Case sensitive
    );

    std.debug.print("   Custom dialect accepts: G,M,X,Y,Z,F,S,T,L,Q,D\n", .{});

    const options = gcode_parser.ParserOptions{
        .address_config = custom_dialect,
    };

    var parser = gcode_parser.Parser(f32).fromSlice(allocator, specialized_gcode, options) catch |err| {
        std.debug.print("   -> Error: {}\n", .{err});
        return;
    };
    defer parser.deinit();

    const maybe_block = parser.next() catch return;
    if (maybe_block) |block| {
        std.debug.print("   -> Successfully parsed {d} words: ", .{block.words.len});
        for (block.words) |word| {
            std.debug.print("{c}{d:.0} ", .{ word.letter, word.value.float });
        }
        std.debug.print("\n", .{});
    } else {
        std.debug.print("   -> No blocks parsed\n", .{});
    }

    // Compare with standard RepRap dialect
    std.debug.print("   Comparison with RepRap dialect:\n", .{});
    var reprap_parser = try gcode_parser.Parser(f32).fromSlice(allocator, specialized_gcode, null);
    defer reprap_parser.deinit();

    if (try reprap_parser.next()) |block| {
        std.debug.print("   -> RepRap parsed {d} words: ", .{block.words.len});
        for (block.words) |word| {
            std.debug.print("{c}{d:.0} ", .{ word.letter, word.value.float });
        }
        std.debug.print("\n", .{});
    } else {
        std.debug.print("   -> No blocks parsed\n", .{});
    }
    std.debug.print("\n", .{});
}

/// Demonstrates case sensitivity options
fn demonstrateCaseSensitivity(allocator: std.mem.Allocator) !void {
    std.debug.print("4. Case Sensitivity\n", .{});
    std.debug.print("   Handling mixed case G-code\n\n", .{});

    const mixed_case_gcode = "g1 x10 Y20 z5 F1500"; // Mixed upper/lower case
    std.debug.print("   Mixed case G-code: {s}\n", .{mixed_case_gcode});

    // Test case-sensitive parsing (default)
    std.debug.print("   Case-sensitive parsing (default):\n", .{});
    {
        var parser = try gcode_parser.Parser(f32).fromSlice(allocator, mixed_case_gcode, null);
        defer parser.deinit();

        const maybe_block = parser.next() catch return;
        if (maybe_block) |block| {
            std.debug.print("   -> Parsed {d} words: ", .{block.words.len});
            for (block.words) |word| {
                std.debug.print("{c}{d:.0} ", .{ word.letter, word.value.float });
            }
            std.debug.print("\n", .{});
        } else {
            std.debug.print("   -> No blocks parsed\n", .{});
        }
    }

    // Test case-insensitive parsing
    std.debug.print("   Case-insensitive parsing:\n", .{});
    {
        const case_insensitive_options = gcode_parser.ParserOptions{
            .address_config = gcode_parser.AddressDialects.FULL,
        };

        var parser = gcode_parser.Parser(f32).fromSlice(allocator, mixed_case_gcode, case_insensitive_options) catch |err| {
            std.debug.print("   -> Error: {}\n", .{err});
            return;
        };
        defer parser.deinit();

        const maybe_block = parser.next() catch return;
        if (maybe_block) |block| {
            std.debug.print("   -> Parsed {d} words: ", .{block.words.len});
            for (block.words) |word| {
                std.debug.print("{c}{d:.0} ", .{ word.letter, word.value.float });
            }
            std.debug.print("\n", .{});
        } else {
            std.debug.print("   -> No blocks parsed\n", .{});
        }
    }

    // Custom case-insensitive dialect
    std.debug.print("   Custom case-insensitive dialect:\n", .{});
    {
        const custom_case_insensitive = try gcode_parser.AddressConfig.init("GMXYZFST", // Uppercase letters
            false // Case insensitive
        );

        const options = gcode_parser.ParserOptions{
            .address_config = custom_case_insensitive,
        };

        var parser = gcode_parser.Parser(f32).fromSlice(allocator, mixed_case_gcode, options) catch |err| {
            std.debug.print("   -> Error: {}\n", .{err});
            return;
        };
        defer parser.deinit();

        const maybe_block = parser.next() catch return;
        if (maybe_block) |block| {
            std.debug.print("   -> Parsed {d} words: ", .{block.words.len});
            for (block.words) |word| {
                std.debug.print("{c}{d:.0} ", .{ word.letter, word.value.float });
            }
            std.debug.print("\n", .{});
        } else {
            std.debug.print("   -> No blocks parsed\n", .{});
        }
    }
    std.debug.print("\n", .{});
}
