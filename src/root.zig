//! G-code parser library.
//!
//! This library provides a high-performance, memory-safe G-code parser designed
//! for safety, performance, and developer experience. It supports streaming
//! parsing, custom dialects, and comprehensive error handling.
//!
//! ## Key Features
//! - Streaming parser for memory-efficient processing of large files
//! - Configurable address letter sets for different G-code dialects
//! - Comprehensive error handling with detailed error contexts
//! - Resource limits to prevent denial-of-service attacks

const std = @import("std");
const mem = std.mem;
const ascii = std.ascii;
const fs = std.fs;

// G-code character constants defined by ISO 6983-1 and RS274 standards.
// These are the specific characters that have semantic meaning in G-code.
const BLOCK_DELETE_CHAR = '/';
const CARRIAGE_RETURN_CHAR = '\r';
const CHECKSUM_CHAR = '*';
const DECIMAL_POINT_CHAR = '.';
const MINUS_SIGN_CHAR = '-';
const NEWLINE_CHAR = '\n';
const PAREN_COMMENT_CLOSE_CHAR = ')';
const PAREN_COMMENT_OPEN_CHAR = '(';
const PLUS_SIGN_CHAR = '+';
const PROGRAM_MARKER_CHAR = '%';
const QUOTE_CHAR = '"';
const SEMICOLON_COMMENT_CHAR = ';';
const SPACE_CHAR = ' ';
const TAB_CHAR = '\t';

/// Maximum number of G-code blocks to parse.
/// Typical CNC programs have hundreds of thousands of blocks, 10M allows for complex programs
/// while preventing infinite parsing loops from malicious input.
const DEFAULT_MAX_BLOCKS_COUNT = 10_000_000;

/// Maximum input file size in bytes.
/// 100MB accommodates large, complex CNC programs while preventing memory exhaustion
/// from excessively large malicious files.
const DEFAULT_MAX_INPUT_SIZE_BYTES = 100 * 1024 * 1024; // 100MB

/// Maximum line length in bytes.
/// G-code lines are typically short, 256KiB allows for complex parametric expressions
/// while preventing single-line memory exhaustion attacks.
const DEFAULT_MAX_LINE_LENGTH_BYTES = 256 * 1024; // 256 KiB

/// Maximum number of lines to process.
/// Large CNC programs can have many lines, 5M provides generous headroom
/// while preventing infinite line generation loops.
const DEFAULT_MAX_LINES_COUNT = 5_000_000;

/// Maximum number of words (commands) per G-code block.
/// Most G-code blocks have 5-10 words, 50 allows for complex multi-axis moves
/// while preventing block-level memory exhaustion attacks.
const DEFAULT_MAX_WORDS_PER_BLOCK_COUNT = 50;

/// Errors that can occur when initializing an AddressConfig.
pub const AddressConfigError = error{
    /// Empty letter set.
    EmptyLetterSet,
    /// Non-ASCII letter.
    NonAsciiLetter,
};

/// Errors that can occur during G-code parsing.
pub const ParseError = error{
    /// A command letter is not followed by any value.
    EmptyValue,
    /// A command letter is followed by a malformed number.
    InvalidNumber,
    /// A parenthetical comment is not properly closed.
    UnclosedComment,
    /// A quoted string is not properly closed.
    UnclosedString,
    /// An unexpected character was found.
    UnexpectedCharacter,
    /// Memory allocation failed.
    OutOfMemory,
    /// Input size exceeds the configured maximum.
    InputTooLarge,
    /// Generic I/O errors.
    IoFailure,
    /// Number of blocks exceeds the configured maximum.
    TooManyBlocks,
    /// Number of lines exceeds the configured maximum.
    TooManyLines,
    /// Line length exceeds the configured maximum.
    TooLongLine,
    /// Number of words in a single block exceeds the configured maximum.
    BlockTooLarge,
    /// Checksum validation failed (calculated checksum doesn't match provided checksum).
    ChecksumMismatch,
    /// Invalid checksum format (not valid hexadecimal).
    InvalidChecksum,
    /// Line number validation failed (line numbers must be sequential).
    InvalidLineNumber,
};

/// Configuration for G-code address letters (command letters) and dialect settings.
///
/// Address letters are the alphabetic characters that precede numeric values in G-code
/// commands (e.g., G01 X10.5 Y20.0). Different CNC machines and G-code dialects
/// support different sets of address letters, so this configuration allows the parser
/// to be customized for specific machine types or G-code standards.
///
/// Based on ISO 6983-1 and RS274 standards, typical address letters include:
/// - G/M: Primary command codes (G01, M03, etc.)
/// - X/Y/Z: Coordinate axes
/// - I/J/K: Arc center coordinates
/// - F: Feed rate, S: Spindle speed, T: Tool number
/// - A/B/C: Rotational axes
/// - P/Q/R: Parameters, N: Line numbers
pub const AddressConfig = struct {
    /// Whether address letter matching is case-sensitive.
    ///
    /// Most modern CNC controllers accept both cases (G01 and g01), but some
    /// legacy systems or strict parsers may require specific casing.
    /// Default is case-sensitive for strict compliance.
    case_sensitive: bool = true,

    /// Fast lookup table for address letter validation.
    ///
    /// Uses a 256-element boolean array indexed by ASCII value for O(1) lookups.
    /// This approach is faster than string comparison or hash tables for the
    /// small, fixed set of valid address letters (typically 10-26 characters).
    lookup: [256]bool,

    /// Creates a new address configuration with specified letters and case sensitivity.
    ///
    /// This validation ensures only valid ASCII letters are accepted, preventing
    /// issues with extended character sets or control characters that could
    /// cause parsing errors or security vulnerabilities.
    pub fn init(accepted_letters: []const u8, case_sensitive: bool) AddressConfigError!AddressConfig {
        if (accepted_letters.len == 0) return error.EmptyLetterSet;

        var lookup_table = [_]bool{false} ** 256;

        for (accepted_letters) |letter| {
            // Reject non-ASCII or non-alphabetic characters to ensure predictable parsing.
            // This prevents issues with Unicode, control characters, or numeric digits
            // being mistakenly configured as address letters.
            if (letter > 0x7F or !ascii.isAlphabetic(letter)) {
                return error.NonAsciiLetter;
            }

            lookup_table[letter] = true;

            // When case-insensitive, accept both upper and lower case variants.
            // This doubles the lookup table entries but maintains O(1) performance.
            if (!case_sensitive) {
                const alt_case = if (ascii.isUpper(letter)) ascii.toLower(letter) else ascii.toUpper(letter);
                lookup_table[alt_case] = true;
            }
        }

        return .{
            .case_sensitive = case_sensitive,
            .lookup = lookup_table,
        };
    }
};

/// Common G-code dialect address letter configurations.
/// These represent standard sets of address letters used in different G-code dialects.
pub const AddressDialects = struct {
    /// Maximum compatibility with all standard address letters, case insensitive.
    pub const FULL = AddressConfig.init("ABCDEFGHIJKLMNOPQRSTUVWXYZ", false) catch unreachable;
};

/// Resource limits for parser operations.
pub const Limits = struct {
    /// Maximum input size in bytes.
    max_input_size: ?usize = DEFAULT_MAX_INPUT_SIZE_BYTES,

    /// Maximum number of blocks to parse.
    max_blocks: ?usize = DEFAULT_MAX_BLOCKS_COUNT,

    /// Maximum number of words per block.
    max_words_per_block: ?usize = DEFAULT_MAX_WORDS_PER_BLOCK_COUNT,

    /// Maximum line length in bytes.
    max_line_length: ?usize = DEFAULT_MAX_LINE_LENGTH_BYTES,

    /// Maximum number of lines.
    max_lines: ?usize = DEFAULT_MAX_LINES_COUNT,
};

/// Configuration options for the G-code parser.
///
/// These options control parser behavior and validation strictness. The defaults
/// provide a balance between compatibility and safety, accepting most valid G-code
/// while rejecting clearly malformed input.
pub const ParserOptions = struct {
    /// Address letter configuration specifying which letters are accepted.
    ///
    /// Defaults to full compatibility with all standard G-code address letters.
    /// Customize for specific machine dialects or to restrict supported commands.
    address_config: AddressConfig = AddressDialects.FULL,

    /// Resource limits for parser operations.
    ///
    /// These limits prevent denial-of-service attacks and memory exhaustion
    /// from malicious or corrupted G-code files.
    limits: Limits = Limits{},

    /// Whether to enforce strict comment parsing (unclosed comments cause errors).
    ///
    /// When true, parenthetical comments must be properly closed or parsing fails.
    /// When false, unclosed comments at end-of-line are silently accepted.
    /// Strict parsing catches more formatting errors but may reject valid legacy files.
    strict_comments: bool = true,

    /// Whether to skip empty lines during parsing.
    ///
    /// When true, empty lines and whitespace-only lines are ignored.
    /// When false, empty lines are treated as empty blocks.
    /// Most G-code programs contain empty lines for readability.
    skip_empty_lines: bool = true,

    /// Whether to ignore unknown characters (if false, unknown characters cause errors).
    ///
    /// When true, unrecognized characters are silently skipped.
    /// When false, any unexpected character causes parsing to fail.
    /// False provides stricter validation but may reject files with minor formatting issues.
    ignore_unknown_characters: bool = true,

    /// Whether to support quoted string parameters (e.g., P"filename").
    ///
    /// Some G-code dialects support quoted strings for filenames, comments, or parameters.
    /// When false, quote characters are treated as unknown characters.
    /// This feature is an extension beyond basic ISO 6983-1.
    support_quoted_strings: bool = true,

    /// Whether to validate G-code checksums (format: *XX where XX is hex checksum).
    ///
    /// When true, lines ending with *XX have their checksum validated against
    /// the XOR of all preceding characters on the line.
    /// Checksum validation catches transmission errors but is rarely used in modern systems.
    validate_checksum: bool = true,

    /// Whether to validate line numbers (N words) for sequential ordering.
    ///
    /// When true, N words must be positive integers in ascending order.
    /// When false, N words are parsed as regular numeric values without validation.
    /// Sequential validation catches missing or reordered lines but may reject
    /// programs with intentional non-sequential numbering.
    validate_line_numbers: bool = true,
};

/// Core parser containing shared parsing logic using a state machine.
pub fn Parser(comptime FloatType: type) type {
    if (FloatType != f32 and FloatType != f64) {
        @compileError("FloatType must be a floating-point type (e.g., f32 or f64)");
    }

    return struct {
        allocator: mem.Allocator,
        options: ParserOptions,

        /// Manages the lifetime of the input source if it's owned by the parser.
        source_context: SourceContext,
        /// The buffered reader used for all parsing operations.
        reader: std.io.BufferedReader(4096, std.io.AnyReader),

        // Running counters
        blocks_parsed: usize = 0,
        bytes_read: usize = 0,
        last_line_number: ?u32 = null,
        line_number: usize = 0,

        // Scratch buffers
        line_buffer: std.ArrayList(u8),
        string_buffer: std.ArrayList(u8),
        word_buffer: std.ArrayList(Word),

        /// Defines the source of the G-code data, enabling automatic resource management.
        const SourceContext = union(enum) {
            /// The parser does not own the reader (provided externally by the user).
            unmanaged,
            /// The parser owns the file handle and will close it on deinit.
            file: fs.File,
            /// The parser owns the stream over a slice.
            slice: std.io.FixedBufferStream([]const u8),
        };

        /// Represents a single G-code word, which is a letter followed by a value.
        /// Value can be float or string for compliance with dialects using quoted params.
        /// For optimal performance, use f32 unless you need f64's extra precision.
        pub const Word = struct {
            letter: u8,
            value: Value,

            pub const Value = union(enum) {
                float: FloatType,
                string: []u8,
            };
        };

        /// Represents a block of G-code, which is typically a single line.
        /// The `words` slice may be ephemeral, depending on the parsing method used.
        pub const Block = struct {
            words: []const Word,
            line_number: usize,

            /// Deallocates any owned strings in the words and the words slice itself.
            pub fn deinit(self: @This(), allocator: mem.Allocator) void {
                for (self.words) |w| {
                    if (w.value == .string) {
                        allocator.free(w.value.string);
                    }
                }
                allocator.free(self.words);
            }

            pub fn toOwned(self: @This(), allocator: mem.Allocator) !@This() {
                const words = try allocator.dupe(Word, self.words);

                // Clone string data for each word that contains a string
                for (words) |*w| {
                    if (w.value == .string) {
                        w.value.string = try allocator.dupe(u8, w.value.string);
                    }
                }

                return .{
                    .words = words,
                    .line_number = self.line_number,
                };
            }
        };

        /// Result of parsing G-code with proper memory management.
        /// Contains both the parsed blocks and the word buffer for safe deallocation.
        pub const ParseResult = struct {
            blocks: []Block,
            word_buffer: []Word,

            /// Properly deallocates both the blocks and word buffer, including any owned strings.
            pub fn deinit(self: @This(), allocator: mem.Allocator) void {
                for (self.word_buffer) |w| {
                    if (w.value == .string) {
                        allocator.free(w.value.string);
                    }
                }
                allocator.free(self.word_buffer);
                allocator.free(self.blocks);
            }
        };

        /// Private common initializer for the parser.
        fn init(allocator: mem.Allocator, options: ParserOptions, source_context: SourceContext, any_reader: std.io.AnyReader) !@This() {
            return @This(){
                .allocator = allocator,
                .options = options,
                .source_context = source_context,
                .reader = std.io.bufferedReader(any_reader),
                .line_buffer = std.ArrayList(u8).init(allocator),
                .string_buffer = std.ArrayList(u8).init(allocator),
                .word_buffer = std.ArrayList(Word).init(allocator),
            };
        }

        /// Creates a new parser from a file path.
        /// The file will be opened and automatically closed when `deinit` is called.
        pub fn fromFile(allocator: mem.Allocator, file_path: []const u8, options: ?ParserOptions) !@This() {
            const file = try fs.cwd().openFile(file_path, .{});
            // If init fails, ensure the file is closed.
            errdefer file.close();

            return try init(allocator, options orelse .{}, .{ .file = file }, file.reader().any());
        }

        /// Creates a new parser from an in-memory byte slice.
        pub fn fromSlice(allocator: mem.Allocator, gcode_slice: []const u8, options: ?ParserOptions) !@This() {
            // The FixedBufferStream is stored in the SourceContext to manage its lifetime.
            var slice_stream = std.io.fixedBufferStream(gcode_slice);
            return try init(allocator, options orelse .{}, .{ .slice = slice_stream }, slice_stream.reader().any());
        }

        /// Creates a new parser from an existing `AnyReader`.
        /// The caller is responsible for the lifetime of the underlying stream.
        pub fn fromReader(allocator: mem.Allocator, reader: std.io.AnyReader, options: ?ParserOptions) !@This() {
            return try init(allocator, options orelse .{}, .unmanaged, reader);
        }

        /// Releases memory used by the parser, including any owned strings and file handles.
        pub fn deinit(self: *@This()) void {
            // Deallocate internal buffers
            for (self.word_buffer.items) |w| {
                if (w.value == .string) {
                    self.allocator.free(w.value.string);
                }
            }
            self.word_buffer.deinit();
            self.line_buffer.deinit();
            self.string_buffer.deinit();

            // Clean up the source context if we own it.
            switch (self.source_context) {
                .file => |f| f.close(),
                .unmanaged, .slice => {}, // Nothing to do for these cases
            }
        }

        /// Checks if a character is an accepted G-code address letter.
        inline fn isAcceptedAddressLetter(self: *const @This(), char: u8) bool {
            return self.options.address_config.lookup[char];
        }

        /// Parses and returns the next block of G-code from the reader.
        /// Returns `null` when there are no more blocks to parse.
        ///
        /// IMPORTANT: The `Block` returned by this function is ephemeral. Its `words`
        /// slice points to an internal buffer that is reused on the next call to `next()`.
        /// If you need to store the block, you must copy its contents using `toOwned`.
        pub fn next(self: *@This()) ParseError!?Block {
            while (true) {
                // Reset the buffers
                for (self.word_buffer.items) |w| {
                    if (w.value == .string) {
                        self.allocator.free(w.value.string);
                    }
                }
                self.word_buffer.clearRetainingCapacity();
                self.line_buffer.clearRetainingCapacity();

                // Calculate remaining input size that is allowed to be read
                const bytes_remaining: ?usize = if (self.options.limits.max_input_size) |max_size| blk: {
                    if (self.bytes_read >= max_size) return error.InputTooLarge;
                    break :blk max_size - self.bytes_read;
                } else null;

                // Determine the maximum bytes the next read may consume.
                const line_cap = self.options.limits.max_line_length orelse std.math.maxInt(usize);
                const max_read = if (bytes_remaining) |r| @min(r, line_cap) else line_cap;

                // Read up to newline or remaining bytes, whichever comes first
                var delimiter_found: bool = true;
                self.reader.reader().streamUntilDelimiter(
                    self.line_buffer.writer(),
                    NEWLINE_CHAR,
                    max_read,
                ) catch |err| switch (err) {
                    error.EndOfStream => {
                        delimiter_found = false;

                        // If we have content in the buffer, process it as the last line
                        if (self.line_buffer.items.len == 0) {
                            return null;
                        }
                    },
                    error.StreamTooLong => return error.TooLongLine,
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.IoFailure,
                };

                // Track how many bytes we accepted
                self.bytes_read += self.line_buffer.items.len + (if (delimiter_found) @as(usize, 1) else @as(usize, 0));

                // Increment line number if we found a delimiter
                if (delimiter_found) {
                    self.line_number += 1;

                    if (self.options.limits.max_lines) |max_lines| {
                        if (self.line_number > max_lines) {
                            return error.TooManyLines;
                        }
                    }
                }

                // Parse the line and return the block if it was successful
                if (try self.parseLine(self.line_buffer.items, &self.word_buffer)) {
                    // Increment block count
                    self.blocks_parsed += 1;

                    // Ensure block count limit is not exceeded.
                    if (self.options.limits.max_blocks) |max_blocks| {
                        if (self.blocks_parsed > max_blocks) {
                            return error.TooManyBlocks;
                        }
                    }

                    // Return the block
                    return Block{
                        .words = self.word_buffer.items,
                        .line_number = self.line_number,
                    };
                }
            }
        }

        /// Collects all remaining blocks into a ParseResult.
        pub fn collect(self: *@This()) !ParseResult {
            // Pre-estimate capacity based on limits to reduce reallocations
            const estimated_total_blocks = if (self.options.limits.max_blocks) |max| @min(max, 1000) else 100;
            const estimated_words_per_block = if (self.options.limits.max_words_per_block) |max| max else 10;
            const estimated_total_words = estimated_total_blocks * estimated_words_per_block;

            var blocks = try std.ArrayList(Block).initCapacity(self.allocator, estimated_total_blocks);
            var words = try std.ArrayList(Word).initCapacity(self.allocator, estimated_total_words);

            errdefer {
                blocks.deinit();

                for (words.items) |w| {
                    if (w.value == .string) {
                        self.allocator.free(w.value.string);
                    }
                }
                words.deinit();
            }

            // Parse and append
            while (try self.next()) |blk| {
                const start = words.items.len;
                try words.appendSlice(blk.words);
                try blocks.append(.{
                    .words = words.items[start..],
                    .line_number = blk.line_number,
                });
            }

            // Convert to owned slices
            const word_buffer = try words.toOwnedSlice();
            const block_buffer = try blocks.toOwnedSlice();

            // Fix internal slice pointers
            var idx: usize = 0;
            for (block_buffer) |*b| {
                b.words = word_buffer[idx .. idx + b.words.len];
                idx += b.words.len;
            }

            return .{
                .blocks = block_buffer,
                .word_buffer = word_buffer,
            };
        }

        /// Parses a single line of G-code into words using a finite state machine.
        fn parseLine(self: *@This(), line: []const u8, word_list: *std.ArrayList(Word)) ParseError!bool {
            const initial_word_count = word_list.items.len;

            // State machine for G-code parsing
            const State = enum {
                idle,
                after_letter,
                reading_number,
                reading_string,
                in_semicolon_comment,
                in_paren_comment,
                skipping_block_delete,
                program_marker_skip,
                skipping_unknown,
            };

            var state: State = .idle;
            var char_index: usize = 0;
            var current_letter: u8 = undefined;
            var value_start_index: usize = undefined;

            var effective_line = line;

            if (self.options.validate_checksum) {
                if (mem.lastIndexOfScalar(u8, line, CHECKSUM_CHAR)) |star_pos| {
                    var calc_checksum: u8 = 0;
                    for (line[0..star_pos]) |c| {
                        calc_checksum ^= c;
                    }

                    const checksum_start = star_pos + 1;
                    var checksum_end = checksum_start;
                    while (checksum_end < line.len and ascii.isDigit(line[checksum_end])) : (checksum_end += 1) {}

                    const checksum_str = line[checksum_start..checksum_end];
                    if (checksum_str.len == 0 or checksum_str.len > 3) return error.InvalidChecksum;

                    const provided_checksum = std.fmt.parseInt(u8, checksum_str, 10) catch return error.InvalidChecksum;
                    if (provided_checksum != calc_checksum) return error.ChecksumMismatch;

                    effective_line = line[0..star_pos];
                }
            }

            while (char_index < effective_line.len) {
                const char = effective_line[char_index];

                switch (state) {
                    .idle => {
                        if (ascii.isWhitespace(char) or char == CARRIAGE_RETURN_CHAR) {
                            char_index += 1;
                            continue;
                        }
                        if (char == SEMICOLON_COMMENT_CHAR) {
                            state = .in_semicolon_comment;
                            char_index += 1;
                            continue;
                        }
                        if (char == PAREN_COMMENT_OPEN_CHAR) {
                            state = .in_paren_comment;
                            char_index += 1;
                            continue;
                        }
                        if (char == BLOCK_DELETE_CHAR and char_index == 0) {
                            state = .skipping_block_delete;
                            char_index += 1;
                            continue;
                        }
                        if (char == PROGRAM_MARKER_CHAR) {
                            state = .program_marker_skip;
                            char_index += 1;
                            continue;
                        }
                        if (ascii.isDigit(char)) {
                            return error.UnexpectedCharacter;
                        }
                        if (self.isAcceptedAddressLetter(char)) {
                            current_letter = if (self.options.address_config.case_sensitive) char else ascii.toUpper(char);
                            state = .after_letter;
                            char_index += 1;
                            continue;
                        }
                        if (ascii.isAlphabetic(char)) {
                            state = .skipping_unknown;
                            char_index += 1;
                            continue;
                        }
                        if (self.options.ignore_unknown_characters) {
                            char_index += 1;
                            continue;
                        }
                        return error.UnexpectedCharacter;
                    },
                    .after_letter => {
                        if (self.options.support_quoted_strings and char == QUOTE_CHAR) {
                            self.string_buffer.clearRetainingCapacity();
                            state = .reading_string;
                            char_index += 1;
                            continue;
                        } else {
                            state = .reading_number;
                            value_start_index = char_index;
                            continue;
                        }
                    },
                    .reading_number => {
                        if (ascii.isDigit(char) or char == DECIMAL_POINT_CHAR or char == MINUS_SIGN_CHAR or char == PLUS_SIGN_CHAR) {
                            char_index += 1;
                            continue;
                        }
                        const value_str = effective_line[value_start_index..char_index];
                        if (value_str.len == 0) return error.EmptyValue;
                        if (mem.indexOfScalar(u8, value_str, 'e') != null or mem.indexOfScalar(u8, value_str, 'E') != null) {
                            return error.InvalidNumber;
                        }
                        const value = std.fmt.parseFloat(FloatType, value_str) catch return error.InvalidNumber;

                        if (self.options.validate_line_numbers and (current_letter == 'N' or current_letter == 'n')) {
                            if (value < 0 or value != @floor(value)) {
                                return error.InvalidLineNumber;
                            }
                            const current_line_num = @as(u32, @intFromFloat(value));
                            if (self.last_line_number) |last| {
                                if (current_line_num <= last) {
                                    return error.InvalidLineNumber;
                                }
                            }
                            self.last_line_number = current_line_num;
                        }

                        if (self.options.limits.max_words_per_block) |max_words| {
                            if ((word_list.items.len - initial_word_count) >= max_words) {
                                return error.BlockTooLarge;
                            }
                        }

                        try word_list.append(.{ .letter = current_letter, .value = .{ .float = value } });
                        state = .idle;
                        continue;
                    },
                    .reading_string => {
                        if (char == QUOTE_CHAR) {
                            char_index += 1;
                            const next_index = char_index;

                            if (next_index < effective_line.len and effective_line[next_index] == QUOTE_CHAR) {
                                try self.string_buffer.append(QUOTE_CHAR);
                                char_index += 1;
                            } else {
                                const value_str = try self.string_buffer.toOwnedSlice();

                                if (self.options.limits.max_words_per_block) |max_words| {
                                    if ((word_list.items.len - initial_word_count) >= max_words) {
                                        self.allocator.free(value_str);
                                        return error.BlockTooLarge;
                                    }
                                }

                                try word_list.append(.{ .letter = current_letter, .value = .{ .string = value_str } });
                                state = .idle;
                                continue;
                            }
                        } else {
                            try self.string_buffer.append(char);
                            char_index += 1;
                        }
                    },
                    .in_semicolon_comment, .skipping_block_delete, .program_marker_skip => {
                        break;
                    },
                    .in_paren_comment => {
                        char_index += 1;
                        if (char == PAREN_COMMENT_CLOSE_CHAR) {
                            state = .idle;
                        }
                        continue;
                    },
                    .skipping_unknown => {
                        if (ascii.isDigit(char) or char == DECIMAL_POINT_CHAR or char == MINUS_SIGN_CHAR or char == PLUS_SIGN_CHAR or ascii.isAlphabetic(char)) {
                            char_index += 1;
                            continue;
                        }
                        state = .idle;
                        continue;
                    },
                }
            }

            // Handle end-of-line states
            switch (state) {
                .reading_number => {
                    const value_str = effective_line[value_start_index..];
                    if (value_str.len == 0) return error.EmptyValue;
                    if (mem.indexOfScalar(u8, value_str, 'e') != null or mem.indexOfScalar(u8, value_str, 'E') != null) {
                        return error.InvalidNumber;
                    }
                    const value = std.fmt.parseFloat(FloatType, value_str) catch return error.InvalidNumber;

                    if (self.options.limits.max_words_per_block) |max_words| {
                        if ((word_list.items.len - initial_word_count) >= max_words) {
                            return error.BlockTooLarge;
                        }
                    }

                    try word_list.append(.{ .letter = current_letter, .value = .{ .float = value } });
                },
                .in_paren_comment => if (self.options.strict_comments) return error.UnclosedComment,
                .reading_string => return error.UnclosedString,
                else => {},
            }

            return word_list.items.len > initial_word_count;
        }
    };
}

test {
    // Include all tests from the gcode_parser module
    @import("std").testing.refAllDecls(@This());
}
