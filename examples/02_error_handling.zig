const std = @import("std");
const gcode_parser = @import("gcode_parser");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("G-code Parser - Error Handling Examples\n", .{});
    std.debug.print("=======================================\n\n", .{});

    // Example 1: Basic error types
    try demonstrateBasicErrors(allocator);

    // Example 2: Graceful error recovery
    try demonstrateErrorRecovery(allocator);

    // Example 3: Resource limit errors
    try demonstrateResourceLimits(allocator);

    // Example 4: Error context and debugging
    try demonstrateErrorContext(allocator);
}

/// Demonstrates the main types of parsing errors
fn demonstrateBasicErrors(allocator: std.mem.Allocator) !void {
    std.debug.print("1. Basic Error Types\n", .{});
    std.debug.print("   Common parsing errors and their causes\n\n", .{});

    const test_cases = [_]struct {
        name: []const u8,
        gcode: []const u8,
        expected_error: ?gcode_parser.ParseError,
    }{
        .{ .name = "Valid G-code", .gcode = "G1 X10 Y20", .expected_error = null },
        .{ .name = "Empty value", .gcode = "G1 X Y20", .expected_error = error.EmptyValue },
        .{ .name = "Invalid number", .gcode = "G1 X1.2.3", .expected_error = error.InvalidNumber },
        .{ .name = "Unclosed comment", .gcode = "G1 X10 (unclosed", .expected_error = error.UnclosedComment },
        .{ .name = "Unexpected character", .gcode = "123 G1 X10", .expected_error = error.UnexpectedCharacter },
    };

    for (test_cases) |test_case| {
        std.debug.print("   Testing: {s}\n", .{test_case.name});

        var parser = gcode_parser.Parser(f32).fromSlice(allocator, test_case.gcode, null) catch |err| {
            std.debug.print("   -> Init error: {}\n", .{err});
            continue;
        };
        defer parser.deinit();

        const maybe_block = parser.next() catch |err| {
            if (test_case.expected_error) |expected| {
                if (err == expected) {
                    std.debug.print("   -> EXPECTED: {}\n", .{err});
                } else {
                    std.debug.print("   -> UNEXPECTED: Got {} but expected {}\n", .{ err, expected });
                }
            } else {
                std.debug.print("   -> UNEXPECTED ERROR: {}\n", .{err});
            }
            continue;
        };

        if (maybe_block) |block| {
            if (test_case.expected_error) |expected| {
                std.debug.print("   -> UNEXPECTED: Expected {} but got success\n", .{expected});
            } else {
                std.debug.print("   -> SUCCESS: Parsed {d} words\n", .{block.words.len});
            }
        } else {
            std.debug.print("   -> No blocks parsed\n", .{});
        }
    }
    std.debug.print("\n", .{});
}

/// Demonstrates error recovery patterns
fn demonstrateErrorRecovery(allocator: std.mem.Allocator) !void {
    std.debug.print("2. Error Recovery Patterns\n", .{});
    std.debug.print("   Techniques for handling mixed valid/invalid G-code\n\n", .{});

    const mixed_gcode =
        \\G1 X10 Y20 ; Valid line
        \\G1 X ; Invalid line (empty value)
        \\G1 X30 Y40 ; Valid line
        \\G1 X1.2.3 ; Invalid line (bad number)
        \\G1 X50 Y60 ; Valid line
    ;

    std.debug.print("   Input G-code with mixed valid/invalid lines:\n", .{});
    std.debug.print("   {s}\n", .{mixed_gcode});

    // Strategy 1: Stop on first error
    std.debug.print("   Strategy 1 - Stop on first error:\n", .{});
    {
        var parser = try gcode_parser.Parser(f32).fromSlice(allocator, mixed_gcode, null);
        defer parser.deinit();

        var valid_blocks: usize = 0;
        while (true) {
            const maybe_block = parser.next() catch |err| {
                std.debug.print("   - Stopped at error: {}\n", .{err});
                std.debug.print("   - Successfully parsed {d} blocks before error\n", .{valid_blocks});
                break;
            };

            if (maybe_block) |block| {
                valid_blocks += 1;
                std.debug.print("   - Block {d}: {d} words\n", .{ valid_blocks, block.words.len });
            } else {
                break;
            }
        }
    }

    // Strategy 2: Parse line by line with individual error handling
    std.debug.print("   Strategy 2 - Handle each line individually:\n", .{});
    {
        var line_iter = std.mem.splitSequence(u8, mixed_gcode, "\n");
        var line_number: usize = 0;
        var successful_lines: usize = 0;

        while (line_iter.next()) |line| {
            line_number += 1;

            // Skip empty lines and comments
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == ';') continue;

            var parser = gcode_parser.Parser(f32).fromSlice(allocator, line, null) catch |err| {
                std.debug.print("   - Line {d}: Init error - {}\n", .{ line_number, err });
                continue;
            };
            defer parser.deinit();

            const maybe_block = parser.next() catch |err| {
                std.debug.print("   - Line {d}: ERROR - {}\n", .{ line_number, err });
                continue;
            };

            if (maybe_block) |block| {
                successful_lines += 1;
                std.debug.print("   - Line {d}: SUCCESS - {d} words\n", .{ line_number, block.words.len });
            } else {
                std.debug.print("   - Line {d}: No blocks parsed\n", .{line_number});
            }
        }
        std.debug.print("   - Total: {d}/{d} lines parsed successfully\n", .{ successful_lines, line_number });
    }
    std.debug.print("\n", .{});
}

/// Demonstrates resource limit error handling
fn demonstrateResourceLimits(allocator: std.mem.Allocator) !void {
    std.debug.print("3. Resource Limit Handling\n", .{});
    std.debug.print("   Protecting against malicious or malformed input\n\n", .{});

    // Create G-code that will exceed limits
    const large_gcode = "G1 X1 Y1 Z1 E1 F1 S1 P1 T1 I1 J1 K1 R1 Q1 D1 H1 L1 A1 B1 C1 U1 V1 W1"; // 22 words

    const strict_options = gcode_parser.ParserOptions{
        .limits = .{
            .max_words_per_block = 5, // Only 5 words per block
            .max_blocks = 3,
        },
    };

    std.debug.print("   Testing with strict limits (max 5 words per block):\n", .{});
    std.debug.print("   Input: {s}\n", .{large_gcode});

    var parser = gcode_parser.Parser(f32).fromSlice(allocator, large_gcode, strict_options) catch |err| {
        std.debug.print("   -> Init error: {}\n", .{err});
        return;
    };
    defer parser.deinit();

    const maybe_block = parser.next() catch |err| switch (err) {
        error.BlockTooLarge => {
            std.debug.print("   -> EXPECTED: Block too large error\n", .{});
            std.debug.print("   -> This protects against malformed input\n", .{});
            return;
        },
        else => {
            std.debug.print("   -> UNEXPECTED: {}\n", .{err});
            return;
        },
    };

    if (maybe_block) |block| {
        std.debug.print("   -> UNEXPECTED: Should have failed but got {d} words\n", .{block.words.len});
    } else {
        std.debug.print("   -> No blocks parsed\n", .{});
    }
    std.debug.print("\n", .{});
}

/// Demonstrates error context and debugging techniques
fn demonstrateErrorContext(allocator: std.mem.Allocator) !void {
    std.debug.print("4. Error Context and Debugging\n", .{});
    std.debug.print("   Techniques for debugging parsing issues\n\n", .{});

    const problematic_gcode =
        \\G1 X10 Y20 ; Line 1 - OK
        \\G1 X1.2.3 Y30 ; Line 2 - Bad number
        \\G1 X40 Y50 ; Line 3 - OK
    ;

    std.debug.print("   Debugging parsing issues:\n", .{});
    std.debug.print("   Input: {s}\n", .{problematic_gcode});

    // Parse with error location tracking
    var parser = try gcode_parser.Parser(f32).fromSlice(allocator, problematic_gcode, null);
    defer parser.deinit();

    var blocks_parsed: usize = 0;
    while (true) {
        const maybe_block = parser.next() catch |err| {
            std.debug.print("   - ERROR after {d} successful blocks: {}\n", .{ blocks_parsed, err });

            // Provide helpful error context
            switch (err) {
                error.InvalidNumber => {
                    std.debug.print("   - HELP: Check for malformed numbers like '1.2.3', '1..2', or '+.'\n", .{});
                    std.debug.print("   - HELP: Ensure all numbers follow standard decimal format\n", .{});
                },
                error.EmptyValue => {
                    std.debug.print("   - HELP: Check for letters without values like 'G' or 'X'\n", .{});
                    std.debug.print("   - HELP: Ensure all command letters have numeric values\n", .{});
                },
                error.UnclosedComment => {
                    std.debug.print("   - HELP: Check for unclosed parenthetical comments '(...)'\n", .{});
                    std.debug.print("   - HELP: Ensure all '(' have matching ')' on the same line\n", .{});
                },
                else => {},
            }
            break;
        };

        if (maybe_block) |block| {
            blocks_parsed += 1;
            std.debug.print("   - Line {d}: SUCCESS - ", .{block.line_number});
            for (block.words) |word| {
                std.debug.print("{c}{d:.1} ", .{ word.letter, word.value.float });
            }
            std.debug.print("\n", .{});
        } else {
            break;
        }
    }
    std.debug.print("\n", .{});
}
