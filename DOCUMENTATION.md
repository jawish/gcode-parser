# G-Code Parser Module Documentation

## 1. Overview

This document provides detailed documentation for the Zig G-code Parser, a high-performance, robust, and configurable library for parsing G-code files and streams.

The parser is designed with the following principles in mind:

- **Performance:** It uses a zero-allocation iterative parsing model (`next()`) for memory-constrained environments and a fast state-machine-based line parser.
- **Flexibility:** It can ingest G-code from files, in-memory buffers (slices), or any custom `std.io.AnyReader` stream.
- **Safety:** It enforces configurable resource limits to protect against malformed or malicious input.
- **Configurability:** Its behavior can be fine-tuned through a comprehensive set of options to support various G-code dialects, including custom address letters, checksum validation, and more.

The core of the library is a generic `Parser(FloatType)` struct, which can be instantiated with `f32` or `f64` depending on the required floating-point precision.

## 2. Quick Start

This example demonstrates the simplest way to parse a G-code file and print its contents.

```zig
const std = @import("std");
const GCodeParser = @import("gcode_parser.zig").Parser(f32);

pub fn main() !void {
    // Initialize an allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // Create a dummy G-code file for the example
    const file_path = "example.gcode";
    try std.fs.cwd().writeFile(file_path,
        \\(This is a sample G-code file)
        \\G90 G21 ; Use absolute coordinates in mm
        \\G01 X10.5 Y20.0 Z-1.0 F1200
        \\M03 S1500 ; Start spindle
    );
    defer std.fs.cwd().deleteFile(file_path) catch {};

    // 1. Create a parser instance from the file
    var parser = try GCodeParser.fromFile(allocator, file_path, null);
    defer parser.deinit(); // Ensures file handle and memory are released

    // 2. Iterate through each block (line) of G-code
    while (try parser.next()) |block| {
        std.debug.print("Parsed Line {d}:", .{block.line_number});

        // 3. Process the words in the block
        for (block.words) |word| {
            switch (word.value) {
                .float => |f| std.debug.print(" {c}{d}", .{word.letter, f}),
                .string => |s| std.debug.print(" {c}\"{s}\"", .{word.letter, s}),
            }
        }
        std.debug.print("\n", .{});
    }
}
```

### Output

```txt
Parsed Line 2: G90.0 G21.0
Parsed Line 3: G1.0 X10.5 Y20.0 Z-1.0 F1200.0
Parsed Line 4: M3.0 S1500.0
```

## 3. Core Concepts

### Parser Lifecycle

- **Instantiation:** Create a `Parser` instance using one of the three factory methods:
  - `fromFile(allocator, path, ?options)`
  - `fromSlice(allocator, buffer, ?options)`
  - `fromReader(allocator, reader, ?options)`

- **Parsing:** Process the G-code using one of two methods:
  - `next()`: Iterates through the source one block at a time. This is the most memory-efficient method, as it reuses an internal buffer.
  - `collect()`: Parses the entire source at once and returns a `ParseResult` containing all blocks. This is convenient but uses more memory.

- **Deinitialization:** Always call `parser.deinit()` to release allocated memory. If created with `fromFile`, this also closes the file handle.

### Blocks and Words

The parser tokenizes G-code into a hierarchy of `Blocks` and `Words`.

- `Word`: The smallest semantic unit in G-code, consisting of an address `letter` (e.g., 'G') and a `value` (a float or a string).
  - `{ .letter = 'G', .value = .{ .float = 1.0 } }`
- `Block`: Represents a single effective line of G-code. It contains a slice of `words` and the `line_number` from the source.

### Ephemeral vs. Owned Blocks

A key concept when using the `next()` method is that the returned `Block` is ephemeral. Its `words` slice points to an internal buffer that will be overwritten on the next call to `next()`.

If you need to store a block for later use, you must create a deep copy using `block.toOwned(allocator)`.

```zig
// Inside a `while (try parser.next()) |block|` loop:

// This is UNSAFE if you store `block` directly
my_list.append(block); // DANGEROUS: `block.words` will be invalid later

// This is SAFE
const owned_block = try block.toOwned(allocator);
try my_list.append(owned_block);
```

The `collect()` method returns a `ParseResult` where all blocks and words are already owned and stable in memory.

## 4. API Reference

### `Parser(comptime FloatType: type)`

A generic struct that provides the core parsing functionality.

**Generic Parameters**

- `FloatType`: The floating-point type to use for numeric values. Must be `f32` or `f64`.

### Factory Methods

#### `fromFile`

```zig
pub fn fromFile(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    options: ?ParserOptions
) !@This()
```

Creates a parser that reads from a file at the given path. The parser takes ownership of the file handle and will automatically close it when `deinit()` is called.

- **Parameters:**
  - `allocator`: The memory allocator for internal buffers
  - `file_path`: The path to the G-code file
  - `options`: An optional `ParserOptions` struct to configure parsing behavior
- **Returns:** A new `Parser` instance  
- **Errors:** `std.fs.File.OpenError`, `std.mem.Allocator.Error`

#### `fromSlice`

```zig
pub fn fromSlice(
    allocator: std.mem.Allocator,
    gcode_slice: []const u8,
    options: ?ParserOptions
) !@This()
```

Creates a parser that reads from an in-memory byte slice.

- **Parameters:**
  - `allocator`: The memory allocator for internal buffers
  - `gcode_slice`: A slice containing the G-code text
  - `options`: An optional `ParserOptions` struct to configure parsing behavior
- **Returns:** A new `Parser` instance  
- **Errors:** `std.mem.Allocator.Error`

#### `fromReader`

```zig
pub fn fromReader(
    allocator: std.mem.Allocator,
    reader: std.io.AnyReader,
    options: ?ParserOptions
) !@This()
```

Creates a parser from an existing `AnyReader` stream. The caller is responsible for managing the lifetime of the underlying stream.

- **Parameters:**
  - `allocator`: The memory allocator for internal buffers
  - `reader`: The `AnyReader` to read G-code from
  - `options`: An optional `ParserOptions` struct to configure parsing behavior
- **Returns:** A new `Parser` instance  
- **Errors:** `std.mem.Allocator.Error`

### Public Methods

#### `deinit`

```zig
pub fn deinit(self: *@This()) void
```

Releases all resources used by the parser, including internal buffers and any owned file handles. Must be called to prevent memory leaks.

#### `next`

```zig
pub fn next(self: *@This()) ParseError!?Block
```

Parses and returns the next block of G-code from the source.

- **Returns:**
  - `?Block`: An optional `Block`. The block is ephemeral and its data is only valid until the next call to `next()`
  - `null`: When the end of the stream is reached
- **Errors:** `ParseError` if a parsing issue occurs

#### `collect`

```zig
pub fn collect(self: *@This()) !ParseResult
```

Parses the entire remaining G-code stream and returns a `ParseResult` containing all blocks and words in owned memory.

- **Returns:** A `ParseResult` struct. The caller is responsible for calling `result.deinit(allocator)` to free its memory  
- **Errors:** `ParseError`, `std.mem.Allocator.Error`

## 5. Configuration (`ParserOptions`)

The `ParserOptions` struct allows you to customize the parser's behavior. Pass it as the final argument to a factory method.

```zig
const options = GCodeParser.ParserOptions{
    .validate_checksum = true,
    .limits = .{ .max_lines = 500000 },
};

var parser = try GCodeParser.fromFile(allocator, "path.gcode", options);
```

### `ParserOptions` Fields

| Field                      | Type          | Default               | Description |
|----------------------------|---------------|-----------------------|-------------|
| `address_config`           | `AddressConfig` | `AddressDialects.FULL` | Defines the set of accepted command letters (e.g., G, M, X, Y, Z) |
| `limits`                   | `Limits`      | Default limits        | Sets resource limits to prevent memory exhaustion from malicious input |
| `strict_comments`          | `bool`        | `true`                | If true, an unclosed parenthetical comment `(` is a `ParseError` |
| `skip_empty_lines`         | `bool`        | `true`                | If true, blank lines are ignored. If false, they are treated as empty blocks |
| `ignore_unknown_characters`| `bool`        | `true`                | If true, silently skips characters that are not part of valid G-code syntax |
| `support_quoted_strings`   | `bool`        | `true`                | If true, enables parsing of quoted string values, e.g., `P"my_string"` |
| `validate_checksum`        | `bool`        | `true`                | If true, validates line checksums (e.g., `*57`). Mismatches cause a `ParseError` |
| `validate_line_numbers`    | `bool`        | `true`                | If true, ensures N words are positive, sequential integers |

#### `Limits` Struct

| Field               | Type      | Default    | Description |
|---------------------|-----------|------------|-------------|
| `max_input_size`    | `?usize`  | 100 MB     | Maximum total bytes to read from the source |
| `max_blocks`        | `?usize`  | 1,000,000  | Maximum number of blocks to parse |
| `max_words_per_block` | `?usize` | 50         | Maximum number of words allowed in a single block |
| `max_line_length`   | `?usize`  | 16 KB      | Maximum length of a single line in bytes |
| `max_lines`         | `?usize`  | 2,000,000  | Maximum number of lines to read |

## Error Handling

The `next()` method can return a `ParseError` union. Your code should handle these potential errors.

```zig
while (parser.next()) |block| {
    // process block
} catch |err| {
    switch (err) {
        error.UnclosedComment => std.debug.print("Error: Unclosed comment on line {d}\n", .{parser.line_number}),
        error.InvalidNumber => std.debug.print("Error: Malformed number on line {d}\n", .{parser.line_number}),
        error.InputTooLarge => std.debug.print("Error: Input file exceeds size limits.\n", .{}),
        else => std.debug.print("An unexpected parsing error occurred: {any}\n", .{err}),
    }
}
```

### `ParseError` Variants

- **`EmptyValue`**: A command letter was not followed by a value (e.g., `G`)
- **`InvalidNumber`**: A value was not a valid float (e.g., `X10.5.2`)
- **`UnclosedComment`**: A `(` was not closed by a `)`
- **`UnclosedString`**: A `"` was not closed by another `"`
- **`UnexpectedCharacter`**: An invalid character was found (e.g., a digit before a letter)
- **`OutOfMemory`**: An allocation failed
- **`InputTooLarge`**: The input source exceeded `limits.max_input_size`
- **`IoFailure`**: A low-level error occurred while reading from the source
- **`TooManyBlocks`**: Exceeded `limits.max_blocks`
- **`TooManyLines`**: Exceeded `limits.max_lines`
- **`TooLongLine`**: Exceeded `limits.max_line_length`
- **`BlockTooLarge`**: Exceeded `limits.max_words_per_block`
- **`ChecksumMismatch`**: The calculated checksum did not match the provided one
- **`InvalidChecksum`**: The checksum value was not a valid number
- **`InvalidLineNumber`**: An N word was not a positive, sequential integer