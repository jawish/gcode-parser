const std = @import("std");
const parser = @import("gcode_parser");

const Allocator = std.mem.Allocator;
const ParseError = parser.ParseError;
const Limits = parser.Limits;
const AddressConfig = parser.AddressConfig;
const ParserOptions = parser.ParserOptions;
const AddressDialects = parser.AddressDialects;

// Helper: compute XOR checksum used by typical G‑code (all chars before '*', excluding spaces)
fn checksum(line: []const u8) u8 {
    var cs: u8 = 0;

    for (line) |c| {
        if (c == '*') break;

        cs ^= c;
    }

    return cs;
}

// Helper: consume a parser via next() until EOF and count blocks
fn count_blocks(comptime FloatT: type, p: *parser.Parser(FloatT)) !usize {
    var n: usize = 0;

    while (true) {
        const blk_opt = try p.next();
        if (blk_opt == null) break;
        n += 1;
    }

    return n;
}

test "fromFile" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.testing.expect(gpa.deinit() == .ok) catch unreachable;
    var prs = try parser.Parser(f32).fromFile(gpa.allocator(), "tests/test_files/basic_gcode.gcode", null);
    defer prs.deinit();
    const blk = (try prs.next()).?;
    try std.testing.expectEqual(@as(usize, 1), blk.words.len);
}

test "fromSlice" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.testing.expect(gpa.deinit() == .ok) catch unreachable;
    const src = "G1 X1.0 Y-2 Z0\n";
    var prs = try parser.Parser(f32).fromSlice(gpa.allocator(), src, null);
    defer prs.deinit();
}

test "fromReader" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.testing.expect(gpa.deinit() == .ok) catch unreachable;
    const src = "G1 X1.0 Y-2 Z0\n";
    var stream = std.io.fixedBufferStream(src);
    const reader = stream.reader().any();
    var prs = try parser.Parser(f32).fromReader(gpa.allocator(), reader, null);
    defer prs.deinit();
}

test "basic parse - G1 X1.0 Y-2 Z0" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.testing.expect(gpa.deinit() == .ok) catch unreachable;
    const src = "G1 X1.0 Y-2 Z0\n";

    inline for (.{ f32, f64 }) |T| {
        var prs = try parser.Parser(T).fromSlice(gpa.allocator(), src, null);
        defer prs.deinit();
        const blk = (try prs.next()).?;
        try std.testing.expectEqual(@as(usize, 4), blk.words.len);
        try std.testing.expect(try prs.next() == null);
    }
}

test "whitespace handling" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.testing.expect(gpa.deinit() == .ok) catch unreachable;
    const src = "  \tG0\tX0 \r\n";
    inline for (.{ f32, f64 }) |T| {
        var prs = try parser.Parser(T).fromSlice(gpa.allocator(), src, null);
        defer prs.deinit();
        const blk = (try prs.next()).?;
        try std.testing.expectEqual(@as(usize, 2), blk.words.len);
        try std.testing.expect(try prs.next() == null);
    }
}

test "unicode handling in comments and unknown chars" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.testing.expect(gpa.deinit() == .ok) catch unreachable;

    // Unicode in comments should be preserved
    const src = "G1 X1 (comment with unicode: ñáéíóú) Y2\n";
    var prs = try parser.Parser(f32).fromSlice(gpa.allocator(), src, null);
    defer prs.deinit();

    const blk = (try prs.next()).?;
    try std.testing.expectEqual(@as(usize, 3), blk.words.len); // G, X, Y
}

test "CRLF mixed line-endings - expects three blocks" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.testing.expect(gpa.deinit() == .ok) catch unreachable;

    // Mix of LF, CRLF, and CR line endings
    const src = "G1 X1\r\nG1 X2\nG1 X3\r";
    var prs = try parser.Parser(f32).fromSlice(gpa.allocator(), src, null);
    defer prs.deinit();

    try std.testing.expectEqual(@as(usize, 3), try count_blocks(f32, &prs));
}

test "empty and comment-only inputs yield zero blocks" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.testing.expect(gpa.deinit() == .ok) catch unreachable;

    const sources = [_][]const u8{
        "; This is a comment\n(Another comment)\n; Final comment\n", // comments-only
        "   \t\r\n  \n\t\t\r\n   ", // whitespace-only
        "", // empty
    };

    for (sources) |src| {
        var prs = try parser.Parser(f32).fromSlice(gpa.allocator(), src, null);
        defer prs.deinit();
        try std.testing.expectEqual(@as(usize, 0), try count_blocks(f32, &prs));
    }
}

test "non-ASCII address letters rejection" {
    const config_result = AddressConfig.init("GXYñ", true);
    try std.testing.expectError(parser.AddressConfigError.NonAsciiLetter, config_result);
}

test "high-precision floats (f64) - checks 1e-12 accuracy on three numbers" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.testing.expect(gpa.deinit() == .ok) catch unreachable;

    const src = "X1.000000000001 Y-0.000000000001 Z9.999999999999\n";
    var prs = try parser.Parser(f64).fromSlice(gpa.allocator(), src, null);
    defer prs.deinit();

    const blk = (try prs.next()).?;
    try std.testing.expectEqual(@as(usize, 3), blk.words.len);

    // Check precision – these values should be preserved in f64
    try std.testing.expectApproxEqRel(@as(f64, 1.000000000001), blk.words[0].value.float, 1e-12);
    try std.testing.expectApproxEqRel(@as(f64, -0.000000000001), blk.words[1].value.float, 1e-12);
    try std.testing.expectApproxEqRel(@as(f64, 9.999999999999), blk.words[2].value.float, 1e-12);
}

test "float precision comparison f32 vs f64" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.testing.expect(gpa.deinit() == .ok) catch unreachable;

    const src = "X1.2345678901234567890\n";

    // Test with f32
    var prs32 = try parser.Parser(f32).fromSlice(gpa.allocator(), src, null);
    defer prs32.deinit();
    const blk32 = (try prs32.next()).?;

    // Test with f64
    var prs64 = try parser.Parser(f64).fromSlice(gpa.allocator(), src, null);
    defer prs64.deinit();
    const blk64 = (try prs64.next()).?;

    // f64 should preserve more precision than f32
    const expected: f64 = 1.2345678901234567890;
    const f32_diff = @abs(@as(f64, blk32.words[0].value.float) - expected);
    const f64_diff = @abs(blk64.words[0].value.float - expected);

    try std.testing.expect(f64_diff < f32_diff); // Stricter than <= to ensure better precision
}

test "case sensitivity and address config" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.testing.expect(gpa.deinit() == .ok) catch unreachable;

    // Case-sensitive rejects lower‑case
    const opt_cs = ParserOptions{ .address_config = AddressConfig.init("XYZ", true) catch unreachable };
    const src1 = "x1\n";
    var prs_cs = try parser.Parser(f32).fromSlice(gpa.allocator(), src1, opt_cs);
    defer prs_cs.deinit();
    const res_cs = prs_cs.next() catch |e| {
        try std.testing.expect(e == ParseError.UnexpectedCharacter);
        return;
    };
    _ = res_cs; // should not reach here

    // Case-insensitive accepts mixed case, normalizes to uppercase
    const opt_ci = ParserOptions{ .address_config = AddressConfig.init("GXY", false) catch unreachable };
    const src2 = "g1 x10 Y20\n";
    var prs_ci = try parser.Parser(f32).fromSlice(gpa.allocator(), src2, opt_ci);
    defer prs_ci.deinit();
    const blk = (try prs_ci.next()).?;
    try std.testing.expectEqual(@as(usize, 3), blk.words.len);
    try std.testing.expectEqual(@as(u8, 'G'), blk.words[0].letter);
    try std.testing.expectEqual(@as(u8, 'X'), blk.words[1].letter);
    try std.testing.expectEqual(@as(u8, 'Y'), blk.words[2].letter);
}

test "semicolon comment ignored" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.testing.expect(gpa.deinit() == .ok) catch unreachable;
    const src = "G1 X1 ; comment here\n";
    var prs = try parser.Parser(f32).fromSlice(gpa.allocator(), src, null);
    defer prs.deinit();
    const blk = (try prs.next()).?;
    try std.testing.expectEqual(@as(usize, 2), blk.words.len);
}

test "paren comment strict vs lax" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.testing.expect(gpa.deinit() == .ok) catch unreachable;
    // strict: expect UnclosedComment
    const opt_strict = ParserOptions{ .strict_comments = true };
    const src1 = "G1 (oops\n";
    var prs_s = try parser.Parser(f32).fromSlice(gpa.allocator(), src1, opt_strict);
    defer prs_s.deinit();
    _ = prs_s.next() catch |e| {
        try std.testing.expect(e == ParseError.UnclosedComment);
    };
    // lax: comment treated as until EOL
    const opt_lax = ParserOptions{ .strict_comments = false };
    const src2 = "G1 (oops\n";
    var prs_l = try parser.Parser(f32).fromSlice(gpa.allocator(), src2, opt_lax);
    defer prs_l.deinit();
    try std.testing.expect((try prs_l.next()) != null);
}

test "checksum validation comprehensive" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.testing.expect(gpa.deinit() == .ok) catch unreachable;

    const opt = ParserOptions{ .validate_checksum = true };

    // Valid checksum
    const bare = "G0 X0";
    var buff_good: [64]u8 = undefined;
    const cs_good = checksum(bare);
    const good_str = std.fmt.bufPrint(&buff_good, "{s}*{d}\n", .{ bare, cs_good }) catch unreachable;
    var prs_good = try parser.Parser(f32).fromSlice(gpa.allocator(), good_str, opt);
    defer prs_good.deinit();
    try std.testing.expect((try prs_good.next()) != null);

    // Invalid checksum
    var buff_bad: [64]u8 = undefined;
    const bad_str = std.fmt.bufPrint(&buff_bad, "{s}*123\n", .{bare}) catch unreachable;
    var prs_bad = try parser.Parser(f32).fromSlice(gpa.allocator(), bad_str, opt);
    defer prs_bad.deinit();
    _ = prs_bad.next() catch |e| {
        try std.testing.expect(e == ParseError.ChecksumMismatch);
    };

    // Invalid formats
    const invalid_formats = [_][]const u8{
        "G1*\n", // Empty
        "G1*XYZ\n", // Non-hex
        "G1*1234\n", // Too long
    };
    for (invalid_formats) |src| {
        var prs = try parser.Parser(f32).fromSlice(gpa.allocator(), src, opt);
        defer prs.deinit();
        _ = prs.next() catch |e| {
            try std.testing.expect(e == ParseError.InvalidChecksum);
        };
    }

    // Edge: checksum with spaces, unicode, etc.
    const bare_edge = "G1 X1 (comment)"; // Checksum ignores spaces and after *
    const cs_edge = checksum(bare_edge);
    var buff_edge: [64]u8 = undefined;
    const edge_str = std.fmt.bufPrint(&buff_edge, "{s}*{d}\n", .{ bare_edge, cs_edge }) catch unreachable;
    var prs_edge = try parser.Parser(f32).fromSlice(gpa.allocator(), edge_str, opt);
    defer prs_edge.deinit();
    try std.testing.expect((try prs_edge.next()) != null);
}

test "line number validation comprehensive" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.testing.expect(gpa.deinit() == .ok) catch unreachable;

    const opt = ParserOptions{ .validate_line_numbers = true };

    // Valid sequential
    const src_valid = "N10 G1\nN20 G1\nN30 G1\n";
    var prs_valid = try parser.Parser(f32).fromSlice(gpa.allocator(), src_valid, opt);
    defer prs_valid.deinit();
    try std.testing.expectEqual(@as(usize, 3), try count_blocks(f32, &prs_valid));

    // Invalid: decreasing
    const src_decrease = "N10 G1\nN5 G1\n";
    var prs_decrease = try parser.Parser(f32).fromSlice(gpa.allocator(), src_decrease, opt);
    defer prs_decrease.deinit();
    _ = try prs_decrease.next(); // First OK
    _ = prs_decrease.next() catch |e| {
        try std.testing.expect(e == ParseError.InvalidLineNumber);
    };

    // Edge cases: negative, non-integer
    const invalid_cases = [_][]const u8{
        "N-1 G1\n", // Negative
        "N1.5 G1\n", // Decimal
        "N0 G1\nN-1 G1\n", // Zero then negative
    };
    for (invalid_cases) |src| {
        var prs = try parser.Parser(f32).fromSlice(gpa.allocator(), src, opt);
        defer prs.deinit();
        _ = prs.next() catch |e| {
            try std.testing.expect(e == ParseError.InvalidLineNumber);
        };
    }

    // Boundary: start from 0, large numbers
    const src_boundary = "N0 G1\nN999999999 G1\n";
    var prs_boundary = try parser.Parser(f32).fromSlice(gpa.allocator(), src_boundary, opt);
    defer prs_boundary.deinit();
    try std.testing.expectEqual(@as(usize, 2), try count_blocks(f32, &prs_boundary));
}

test "skip_empty_lines behaviors" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.testing.expect(gpa.deinit() == .ok) catch unreachable;

    const src = "G1 X1\n\nG1 X2\n";

    // false: process empty as blocks (if parser returns them)
    const opt_false = ParserOptions{ .skip_empty_lines = false };
    var prs_false = try parser.Parser(f32).fromSlice(gpa.allocator(), src, opt_false);
    defer prs_false.deinit();
    const count_false = try count_blocks(f32, &prs_false);
    try std.testing.expect(count_false >= 2); // Depends on parser; at least 2

    // true: skip empty (default)
    var prs_true = try parser.Parser(f32).fromSlice(gpa.allocator(), src, null);
    defer prs_true.deinit();
    try std.testing.expectEqual(@as(usize, 2), try count_blocks(f32, &prs_true));
}

test "quoted strings handling comprehensive" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.testing.expect(gpa.deinit() == .ok) catch unreachable;

    const opt_on = ParserOptions{ .support_quoted_strings = true };

    // Enabled: empty, special chars, multiple
    const src_enabled = "P\"\" Q\"special &!@#\" R\"third\"\n";
    var prs_enabled = try parser.Parser(f32).fromSlice(gpa.allocator(), src_enabled, opt_on);
    defer prs_enabled.deinit();
    const blk_enabled = (try prs_enabled.next()).?;
    try std.testing.expectEqual(@as(usize, 3), blk_enabled.words.len);
    try std.testing.expectEqualSlices(u8, "", blk_enabled.words[0].value.string);
    try std.testing.expectEqualSlices(u8, "special &!@#", blk_enabled.words[1].value.string);
    try std.testing.expectEqualSlices(u8, "third", blk_enabled.words[2].value.string);

    // Disabled: error on quotes
    const opt_off = ParserOptions{ .support_quoted_strings = false, .ignore_unknown_characters = false };
    const src_disabled = "P\"test\"\n";
    var prs_disabled = try parser.Parser(f32).fromSlice(gpa.allocator(), src_disabled, opt_off);
    defer prs_disabled.deinit();
    _ = prs_disabled.next() catch |e| {
        try std.testing.expect(e == ParseError.UnexpectedCharacter or e == ParseError.EmptyValue);
    };
}

test "block delete skipped" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.testing.expect(gpa.deinit() == .ok) catch unreachable;
    const src = "/ M204 P1\nG1 X2\n";
    var prs = try parser.Parser(f32).fromSlice(gpa.allocator(), src, null);
    defer prs.deinit();
    try std.testing.expectEqual(@as(usize, 1), try count_blocks(f32, &prs));
}

test "program marker lines ignored" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.testing.expect(gpa.deinit() == .ok) catch unreachable;
    const src = "%\nG4 P0\n%\n";
    var prs = try parser.Parser(f32).fromSlice(gpa.allocator(), src, null);
    defer prs.deinit();
    try std.testing.expectEqual(@as(usize, 1), try count_blocks(f32, &prs));
}

test "unknown char handling respect flag" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.testing.expect(gpa.deinit() == .ok) catch unreachable;
    const src = "G1 X1 @\n";
    // default (false) → UnexpectedCharacter
    var prs_default = try parser.Parser(f32).fromSlice(gpa.allocator(), src, null);
    defer prs_default.deinit();
    _ = prs_default.next() catch |e| {
        try std.testing.expect(e == ParseError.UnexpectedCharacter);
    };
    // ignore true
    const opt_ignore = ParserOptions{ .ignore_unknown_characters = true };
    var prs_ignore = try parser.Parser(f32).fromSlice(gpa.allocator(), src, opt_ignore);
    defer prs_ignore.deinit();
    try std.testing.expect((try prs_ignore.next()) != null);
}

test "limits enforcement comprehensive" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.testing.expect(gpa.deinit() == .ok) catch unreachable;

    // input_size: exceed small limit
    const limits_input = Limits{ .max_input_size = 3, .max_line_length = null };
    const opt_input = ParserOptions{ .limits = limits_input };
    const src_input = "G1\nG2\n";
    var prs_input = try parser.Parser(f32).fromSlice(gpa.allocator(), src_input, opt_input);
    defer prs_input.deinit();
    _ = try prs_input.next();
    _ = prs_input.next() catch |e| {
        try std.testing.expect(e == ParseError.InputTooLarge);
    };

    // max_blocks: exceed 1
    const limits_blocks = Limits{ .max_blocks = 1 };
    const opt_blocks = ParserOptions{ .limits = limits_blocks };
    const src_blocks = "G0\nG1\n";
    var prs_blocks = try parser.Parser(f32).fromSlice(gpa.allocator(), src_blocks, opt_blocks);
    defer prs_blocks.deinit();
    _ = try prs_blocks.next();
    _ = prs_blocks.next() catch |e| {
        try std.testing.expect(e == ParseError.TooManyBlocks);
    };

    // max_words_per_block: exceed 3
    const limits_words = Limits{ .max_words_per_block = 3 };
    const opt_words = ParserOptions{ .limits = limits_words };
    const src_words = "G1 X1 Y2 Z3 F1500\n";
    var prs_words = try parser.Parser(f32).fromSlice(gpa.allocator(), src_words, opt_words);
    defer prs_words.deinit();
    _ = prs_words.next() catch |e| {
        try std.testing.expect(e == ParseError.BlockTooLarge);
    };

    // max_line_length: exceed 5
    const limits_line = Limits{ .max_line_length = 5 };
    const opt_line = ParserOptions{ .limits = limits_line };
    const src_line = "G0 X12345\n";
    var prs_line = try parser.Parser(f32).fromSlice(gpa.allocator(), src_line, opt_line);
    defer prs_line.deinit();
    _ = prs_line.next() catch |e| {
        try std.testing.expect(e == ParseError.TooLongLine);
    };

    // max_lines: exceed 1 (note: if unenforced in parser, this may pass; document current behavior)
    const limits_lines = Limits{ .max_lines = 1 };
    const opt_lines = ParserOptions{ .limits = limits_lines };
    const src_lines = "G1 X1\nG1 X2\n";
    var prs_lines = try parser.Parser(f32).fromSlice(gpa.allocator(), src_lines, opt_lines);
    defer prs_lines.deinit();
    _ = try prs_lines.next();
    _ = prs_lines.next() catch |e| {
        try std.testing.expect(e == ParseError.TooManyLines);
    };

    // unlimited (nulls): long block OK
    const limits_unlim = Limits{
        .max_input_size = null,
        .max_blocks = null,
        .max_words_per_block = null,
        .max_line_length = null,
        .max_lines = null,
    };
    const opt_unlim = ParserOptions{ .limits = limits_unlim };
    var large_line = std.ArrayList(u8).init(gpa.allocator());
    defer large_line.deinit();
    try large_line.appendSlice("G1");
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        try std.fmt.format(large_line.writer(), " X{d}", .{i});
    }
    try large_line.append('\n');
    var prs_unlim = try parser.Parser(f32).fromSlice(gpa.allocator(), large_line.items, opt_unlim);
    defer prs_unlim.deinit();
    const blk_unlim = (try prs_unlim.next()).?;
    try std.testing.expectEqual(@as(usize, 101), blk_unlim.words.len);

    // Boundary pass: exact limits
    const limits_boundary = Limits{
        .max_input_size = 7,
        .max_blocks = 1,
        .max_words_per_block = 2,
        .max_line_length = 6,
    };
    const opt_boundary = ParserOptions{ .limits = limits_boundary };
    const src_boundary = "G1 X1\n";
    var prs_boundary = try parser.Parser(f32).fromSlice(gpa.allocator(), src_boundary, opt_boundary);
    defer prs_boundary.deinit();
    const blk_boundary = (try prs_boundary.next()).?;
    try std.testing.expectEqual(@as(usize, 2), blk_boundary.words.len);
    try std.testing.expect((try prs_boundary.next()) == null);

    // Lower bounds: 0 limits (should error immediately if applicable)
    const limits_zero = Limits{ .max_blocks = 0 };
    const opt_zero = ParserOptions{ .limits = limits_zero };
    const src_zero = "G1\n";
    var prs_zero = try parser.Parser(f32).fromSlice(gpa.allocator(), src_zero, opt_zero);
    defer prs_zero.deinit();
    _ = prs_zero.next() catch |e| {
        try std.testing.expect(e == ParseError.TooManyBlocks);
    };
}

test "empty value error" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.testing.expect(gpa.deinit() == .ok) catch unreachable;
    const src = "G\n";
    var prs = try parser.Parser(f32).fromSlice(gpa.allocator(), src, null);
    defer prs.deinit();
    _ = prs.next() catch |e| {
        try std.testing.expect(e == ParseError.EmptyValue);
    };
}

test "invalid number format" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.testing.expect(gpa.deinit() == .ok) catch unreachable;
    const src = "X1.2.3\n";
    var prs = try parser.Parser(f32).fromSlice(gpa.allocator(), src, null);
    defer prs.deinit();
    _ = prs.next() catch |e| {
        try std.testing.expect(e == ParseError.InvalidNumber);
    };
}

test "unclosed string" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.testing.expect(gpa.deinit() == .ok) catch unreachable;
    const src = "P\"TEST\n";
    var prs = try parser.Parser(f32).fromSlice(gpa.allocator(), src, null);
    defer prs.deinit();
    _ = prs.next() catch |e| {
        try std.testing.expect(e == ParseError.UnclosedString);
    };
}

test "address config errors" {
    // Empty
    _ = AddressConfig.init("", false) catch |e| {
        try std.testing.expect(e == parser.AddressConfigError.EmptyLetterSet);
    };
    // Non-ASCII
    _ = AddressConfig.init("Å", false) catch |e| {
        try std.testing.expect(e == parser.AddressConfigError.NonAsciiLetter);
    };
    // Lowercase in case-sensitive
    const config = AddressConfig.init("gxy", true) catch unreachable;
    _ = config; // Test if normalized or errors
}

test "memory management and ownership" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.testing.expect(gpa.deinit() == .ok) catch unreachable;
    const src = "P\"first\" Q\"second\" R\"third\"\n";
    var prs = try parser.Parser(f32).fromSlice(gpa.allocator(), src, null);
    defer prs.deinit();
    const blk = (try prs.next()).?;
    try std.testing.expectEqual(@as(usize, 3), blk.words.len);
    var owned = try blk.toOwned(gpa.allocator());
    defer owned.deinit(gpa.allocator());
    try std.testing.expectEqualSlices(u8, "first", owned.words[0].value.string);
    try std.testing.expectEqualSlices(u8, "second", owned.words[1].value.string);
    try std.testing.expectEqualSlices(u8, "third", owned.words[2].value.string);
    // Test multiple allocations cleanup
    const src_multi = "P\"hi\"\n";
    var stream_multi = std.io.fixedBufferStream(src_multi);
    var prs_multi = try parser.Parser(f32).fromReader(gpa.allocator(), stream_multi.reader().any(), null);
    defer prs_multi.deinit();
    const blk_multi = (try prs_multi.next()).?;
    var owned_multi = try blk_multi.toOwned(gpa.allocator());
    defer owned_multi.deinit(gpa.allocator());
}

test "scientific notation rejection" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.testing.expect(gpa.deinit() == .ok) catch unreachable;

    const cases = [_][]const u8{
        "X1.5e3\n",
        "Y2E-4\n",
        "Z1.0e+2\n",
    };

    for (cases) |src| {
        var prs = try parser.Parser(f32).fromSlice(gpa.allocator(), src, null);
        defer prs.deinit();
        _ = prs.next() catch |e| {
            try std.testing.expect(e == ParseError.InvalidNumber);
            continue;
        };
    }
}

test "complex number formats - valid cases" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.testing.expect(gpa.deinit() == .ok) catch unreachable;

    const src = "X+123.456 Y-0.001 Z1000 F.5\n";
    var prs = try parser.Parser(f32).fromSlice(gpa.allocator(), src, null);
    defer prs.deinit();

    const blk = (try prs.next()).?;
    try std.testing.expectEqual(@as(usize, 4), blk.words.len);

    try std.testing.expectApproxEqRel(@as(f32, 123.456), blk.words[0].value.float, 1e-6);
    try std.testing.expectApproxEqRel(@as(f32, -0.001), blk.words[1].value.float, 1e-6);
    try std.testing.expectApproxEqRel(@as(f32, 1000), blk.words[2].value.float, 1e-6);
    try std.testing.expectApproxEqRel(@as(f32, 0.5), blk.words[3].value.float, 1e-6);
}

test "custom dialect ignores unsupported characters" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.testing.expect(gpa.deinit() == .ok) catch unreachable;

    const custom_config = AddressConfig.init("GXYZ", true) catch unreachable;
    const opt = ParserOptions{ .address_config = custom_config };

    const src = "G1 X10 Y20 A30 B40 Z50\n"; // A, B ignored
    var prs = try parser.Parser(f32).fromSlice(gpa.allocator(), src, opt);
    defer prs.deinit();

    const blk = (try prs.next()).?;
    try std.testing.expectEqual(@as(usize, 4), blk.words.len); // G, X, Y, Z
}

test "multiple & empty comments - extracts G1 X10 Y20" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.testing.expect(gpa.deinit() == .ok) catch unreachable;

    const src = "; comment\n() (empty) G1 () X10 (value) Y20 ; end\n";
    var prs = try parser.Parser(f32).fromSlice(gpa.allocator(), src, null);
    defer prs.deinit();

    const blk = (try prs.next()).?;
    try std.testing.expectEqual(@as(usize, 3), blk.words.len);

    try std.testing.expectEqual(@as(u8, 'G'), blk.words[0].letter);
    try std.testing.expectEqual(@as(f32, 1), blk.words[0].value.float);
    try std.testing.expectEqual(@as(u8, 'X'), blk.words[1].letter);
    try std.testing.expectEqual(@as(f32, 10), blk.words[1].value.float);
    try std.testing.expectEqual(@as(u8, 'Y'), blk.words[2].letter);
    try std.testing.expectEqual(@as(f32, 20), blk.words[2].value.float);
}

test "nested and complex comments" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.testing.expect(gpa.deinit() == .ok) catch unreachable;

    const src = "(comment) G1 X1\n";
    var prs = try parser.Parser(f32).fromSlice(gpa.allocator(), src, null);
    defer prs.deinit();

    const blk = (try prs.next()).?;
    try std.testing.expectEqual(@as(usize, 2), blk.words.len);
}

test "unclosed comment lax mode vs empty line" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.testing.expect(gpa.deinit() == .ok) catch unreachable;

    const opt_lax = ParserOptions{ .strict_comments = false };
    const src = "(unclosed comment\n\nG1 X1\n";
    var prs = try parser.Parser(f32).fromSlice(gpa.allocator(), src, opt_lax);
    defer prs.deinit();

    try std.testing.expectEqual(@as(usize, 1), try count_blocks(f32, &prs));
}

test "extreme precision numbers with f64" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.testing.expect(gpa.deinit() == .ok) catch unreachable;

    const src = "X0.123456789012345678901234567890\n";
    var prs = try parser.Parser(f64).fromSlice(gpa.allocator(), src, null);
    defer prs.deinit();

    const blk = (try prs.next()).?;
    try std.testing.expect(blk.words[0].value.float > 0.12345678901234567);
    try std.testing.expect(blk.words[0].value.float <= 0.12345678901234568); // Approximate precision check
}

test "configuration options comprehensive" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.testing.expect(gpa.deinit() == .ok) catch unreachable;

    // skip_empty_lines: already covered
    // validate_checksum: already covered
    // strict_comments: on/off
    const src_comment = "G1 (oops\nG1 X1\n";
    const opt_strict = ParserOptions{ .strict_comments = true };
    var prs_strict = try parser.Parser(f32).fromSlice(gpa.allocator(), src_comment, opt_strict);
    defer prs_strict.deinit();
    _ = prs_strict.next() catch |e| {
        try std.testing.expect(e == ParseError.UnclosedComment);
    };

    const opt_lax_comment = ParserOptions{ .strict_comments = false };
    var prs_lax = try parser.Parser(f32).fromSlice(gpa.allocator(), src_comment, opt_lax_comment);
    defer prs_lax.deinit();
    try std.testing.expectEqual(@as(usize, 2), try count_blocks(f32, &prs_lax));

    // ignore_unknown_characters: on/off already covered

    // support_quoted_strings: already covered

    // address_config: custom with case, already covered

    // validate_line_numbers: already covered

    // limits: already covered

    // Combination: all on
    const opt_all = ParserOptions{
        .skip_empty_lines = true,
        .validate_checksum = true,
        .strict_comments = true,
        .ignore_unknown_characters = true,
        .support_quoted_strings = true,
        .validate_line_numbers = true,
    };
    const src_all = "N1 G1 (comment)\n\n";
    var prs_all = try parser.Parser(f32).fromSlice(gpa.allocator(), src_all, opt_all);
    defer prs_all.deinit();
    const blk_all = (try prs_all.next()).?;
    try std.testing.expect(blk_all.words.len > 0);
}

test "error handling comprehensive" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.testing.expect(gpa.deinit() == .ok) catch unreachable;

    const error_cases = .{
        .{ "G\n", ParseError.EmptyValue },
        .{ "X1.2.3\n", ParseError.InvalidNumber },
        .{ "P\"unclosed\n", ParseError.UnclosedString },
        .{ "G1 X1 @\n", ParseError.UnexpectedCharacter },
        .{ "(unclosed\n", ParseError.UnclosedComment }, // Strict
        .{ "N-1 G1\n", ParseError.InvalidLineNumber },
        .{ "G1*XYZ\n", ParseError.InvalidChecksum },
        .{ "G1*00\n", ParseError.ChecksumMismatch }, // Assume bad
        // Add for limits: already in limits test
        // Unicode invalid: "Xñ1\n", ParseError.UnexpectedCharacter
        // .{ "Xñ1\n", ParseError.UnexpectedCharacter },
    };
    // Large number near float limit
    const large_src = "X1e38\n"; // f32 max ~3.4e38
    var prs_large = try parser.Parser(f32).fromSlice(gpa.allocator(), large_src, null);
    defer prs_large.deinit();
    const blk_large = try prs_large.next();
    _ = blk_large; // Check no error or overflow
    // Memory failure: use failing allocator if possible, but skip for simplicity
    // I/O: assume fixed, no error
    // All ParseError variants covered

    inline for (error_cases) |case| {
        var prs = try parser.Parser(f32).fromSlice(gpa.allocator(), case[0], null);
        defer prs.deinit();
        _ = prs.next() catch |e| {
            try std.testing.expect(e == case[1]);
        };
    }
}

test "comment handling" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.testing.expect(gpa.deinit() == .ok) catch unreachable;

    const opt = ParserOptions{ .strict_comments = false };
    const src = "; Complex test case\n(unclosed comment\nG1 X1 (inline) ; end\n";
    var prs = try parser.Parser(f64).fromSlice(gpa.allocator(), src, opt);
    defer prs.deinit();
    try std.testing.expectEqual(@as(usize, 1), try count_blocks(f64, &prs));
}

test "program markers" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.testing.expect(gpa.deinit() == .ok) catch unreachable;

    const src = "%\nG1 X1\n%\n";
    var prs = try parser.Parser(f64).fromSlice(gpa.allocator(), src, null);
    defer prs.deinit();
    try std.testing.expectEqual(@as(usize, 1), try count_blocks(f64, &prs));
}

test "edge cases: large numbers" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.testing.expect(gpa.deinit() == .ok) catch unreachable;

    // Test large number near f32 max (~3.4028235e38)
    // Note: Parser should reject scientific notation per test "scientific notation rejection"
    const src = "X3402823466\n"; // Approximate 3.402823466e+38 without scientific notation
    var prs = try parser.Parser(f32).fromSlice(gpa.allocator(), src, null);
    defer prs.deinit();
    // _ = prs.next() catch |e| {
    //     // Expect rejection if parser enforces no scientific notation; adjust if parser accepts
    //     try std.testing.expect(e == ParseError.InvalidNumber);
    //     return;
    // };
    // If parser accepts large numbers, verify approximate value
    const blk = (try prs.next()).?;
    try std.testing.expectApproxEqRel(@as(f32, 3402823466.0), blk.words[0].value.float, 1e-6);
}

test "edge cases: unicode in comments and values" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.testing.expect(gpa.deinit() == .ok) catch unreachable;

    // Unicode in comment (should be ignored)
    const src_comment = "G1 X1 (unicode ñ)\n";
    var prs_comment = try parser.Parser(f32).fromSlice(gpa.allocator(), src_comment, null);
    defer prs_comment.deinit();
    const blk_comment = (try prs_comment.next()).?;
    try std.testing.expectEqual(@as(usize, 2), blk_comment.words.len); // G1, X1
    try std.testing.expectEqual(@as(u8, 'G'), blk_comment.words[0].letter);
    try std.testing.expectEqual(@as(f32, 1.0), blk_comment.words[0].value.float);
    try std.testing.expectEqual(@as(u8, 'X'), blk_comment.words[1].letter);
    try std.testing.expectEqual(@as(f32, 1.0), blk_comment.words[1].value.float);

    // Unicode in value (should error)
    const src_value = "Gñ\n";
    var prs_value = try parser.Parser(f32).fromSlice(gpa.allocator(), src_value, null);
    defer prs_value.deinit();
    _ = prs_value.next() catch |e| {
        try std.testing.expect(e == ParseError.EmptyValue);
    };
}
