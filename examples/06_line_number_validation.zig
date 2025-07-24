const std = @import("std");
const gcode = @import("gcode_parser");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Example G-code with line numbers
    const valid_gcode =
        \\N10 G01 X10 Y20
        \\N20 G01 X30 Y40
        \\N30 M03 S1000
    ;

    const invalid_gcode =
        \\N10 G01 X10 Y20
        \\N05 G01 X30 Y40
        \\N30 M03 S1000
    ;

    const duplicate_gcode =
        \\N10 G01 X10 Y20
        \\N20 G01 X30 Y40
        \\N20 M03 S1000
    ;

    // Create parser options with line number validation enabled
    var options = gcode.ParserOptions{
        .validate_line_numbers = true,
    };

    std.debug.print("=== Testing Valid Line Numbers ===\n", .{});
    {
        var parser = try gcode.Parser(f32).fromSlice(allocator, valid_gcode, options);
        defer parser.deinit();

        var block_count: usize = 0;
        while (try parser.next()) |block| {
            block_count += 1;
            std.debug.print("Block {}: {} words\n", .{ block.line_number, block.words.len });

            // Find and print line number if present
            for (block.words) |word| {
                if (word.letter == 'N') {
                    std.debug.print("  Line number: {d}\n", .{word.value.float});
                    break;
                }
            }
        }
        std.debug.print("Parsed {} blocks successfully!\n\n", .{block_count});
    }

    std.debug.print("=== Testing Invalid Line Numbers (Backwards) ===\n", .{});
    {
        var parser = try gcode.Parser(f32).fromSlice(allocator, invalid_gcode, options);
        defer parser.deinit();

        while (true) {
            if (parser.next()) |maybe_block| {
                if (maybe_block) |block| {
                    std.debug.print("Block {}: {} words\n", .{ block.line_number, block.words.len });
                } else {
                    break;
                }
            } else |err| {
                std.debug.print("Expected error caught: {}\n\n", .{err});
                break;
            }
        }
    }

    std.debug.print("=== Testing Duplicate Line Numbers ===\n", .{});
    {
        var parser = try gcode.Parser(f32).fromSlice(allocator, duplicate_gcode, options);
        defer parser.deinit();

        while (true) {
            if (parser.next()) |maybe_block| {
                if (maybe_block) |block| {
                    std.debug.print("Block {}: {} words\n", .{ block.line_number, block.words.len });
                } else {
                    break;
                }
            } else |err| {
                std.debug.print("Expected error caught: {}\n\n", .{err});
                break;
            }
        }
    }

    std.debug.print("=== Testing Without Validation ===\n", .{});
    {
        options.validate_line_numbers = false;
        var parser = try gcode.Parser(f32).fromSlice(allocator, invalid_gcode, options);
        defer parser.deinit();

        var block_count: usize = 0;
        while (try parser.next()) |block| {
            block_count += 1;
            std.debug.print("Block {}: {} words (validation disabled)\n", .{ block.line_number, block.words.len });
        }
        std.debug.print("Parsed {} blocks without validation!\n", .{block_count});
    }
}
