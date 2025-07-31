
# G-Code Parser

A high-performance, robust, and configurable library for parsing G-code files and streams, written in Zig.

This parser is designed for applications that require fast and memory-efficient processing of G-code, such as CNC controllers, 3D printer firmware, toolpath simulators, and CAM software post-processors.

## Key Features

- **High Performance**: Utilizes a zero-allocation iterative parsing model for minimal memory overhead
- **Flexible API**: Ingest G-code from files, in-memory buffers, or any `std.io.AnyReader` stream with a simple and consistent API
- **Safe and Robust**: Enforces configurable resource limits to protect against malformed or malicious input
- **Highly Configurable**: Easily tune the parser's behavior to support various G-code dialects, including custom command letters, checksum validation, and more
- **Modern Zig**: Built with idiomatic Zig, leveraging the power of comptime for flexibility and performance

## Installation

### Prerequisites

- [Zig](https://ziglang.org/) 0.14.0 or later

### Using `zig fetch`

```sh
zig fetch --save git+https://github.com/jawish/gcode-parser
```

Then in your `build.zig`:

```zig
const gcode_parser = b.dependency("gcode_parser", .{});
exe.root_module.addImport("gcode_parser", gcode_parser.module("gcode_parser"));
```

### Manual

To add this library to your project, add it as a dependency in your `build.zig.zon` file:

```zig
.{
    .dependencies = .{
        .gcode_parser = .{
            .url = "https://github.com/jawish/gcode-parser/archive/main.tar.gz",
        },
    },
}
```

Then, in your `build.zig`, add the dependency to your executable:

```zig
const gcode_parser_dep = b.dependency("gcode_parser", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("gcode_parser", gcode_parser.module("gcode_parser"));
```

## Usage Example

Here is a simple example of how to read a G-code file and print its contents:

```zig
const std = @import("std");
// 1. Import the parser module
const Parser = @import("gcode_parser").Parser;

pub fn main() !void {
    // Use f32 or f64 for precision
    const GCodeParser = Parser(f32);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // 2. Create a parser from a file, slice, or reader
    var parser = try GCodeParser.fromFile(allocator, "path/to/your.gcode", null);
    defer parser.deinit(); // Frees memory and closes the file handle

    // 3. Iterate through each block of G-code
    while (try parser.next()) |block| {
        std.debug.print("Line {d}:", .{block.line_number});
        for (block.words) |word| {
            std.debug.print(" {c}:{any}", .{word.letter, word.value});
        }
        std.debug.print("\n", .{});
    } catch |err| {
        std.debug.print("Error parsing G-code: {any}\n", .{err});
    }
}
```

## API Documentation

For a complete guide to the parser's API, please refer to the [full API Documentation](DOCUMENTATION.md).

## Contributing

Contributions are welcome! Please ensure:

- Code follows Zig style guidelines
- Tests are added for new features
- Documentation is updated for API changes

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.
