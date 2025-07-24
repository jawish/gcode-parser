const std = @import("std");

pub fn build(b: *std.Build) void {
    const root_source_file = "src/main.zig";
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Add module
    const gcode_parser_mod = b.addModule(
        "gcode_parser",
        .{
            .root_source_file = b.path(root_source_file),
            .target = target,
            .optimize = optimize,
        },
    );

    // Run tests
    const tests = b.addTest(.{
        .name = "gcode_parser-tests",
        .root_source_file = b.path("tests/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests.root_module.addImport("gcode_parser", gcode_parser_mod);

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_tests.step);

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "gcode_parser",
        .root_module = gcode_parser_mod,
    });
    b.installArtifact(lib);

    // Generate documentation
    const docs = b.addInstallDirectory(.{
        .install_dir = .prefix,
        .install_subdir = "docs",
        .source_dir = lib.getEmittedDocs(),
    });
    const docs_step = b.step("docs", "Emit documentation");
    docs_step.dependOn(&docs.step);

    // Define all examples
    const examples = [_]struct {
        name: []const u8,
        file: []const u8,
        description: []const u8,
    }{
        .{
            .name = "example-01",
            .file = "examples/01_basic_usage.zig",
            .description = "Basic usage patterns and parsing methods",
        },
        .{
            .name = "example-02",
            .file = "examples/02_error_handling.zig",
            .description = "Error handling best practices",
        },
        .{
            .name = "example-03",
            .file = "examples/03_custom_dialects.zig",
            .description = "Address configuration and custom dialects",
        },
        .{
            .name = "example-04",
            .file = "examples/04_streaming_large_files.zig",
            .description = "Streaming functionality for large files",
        },
        .{
            .name = "example-05",
            .file = "examples/05_memory_patterns.zig",
            .description = "Memory management patterns and best practices",
        },
        .{
            .name = "example-06",
            .file = "examples/06_line_number_validation.zig",
            .description = "Line number validation and error handling",
        },
    };

    // Create build targets for each example
    for (examples) |example| {
        const exe = b.addExecutable(.{
            .name = example.name,
            .root_source_file = b.path(example.file),
            .target = target,
            .optimize = optimize,
        });

        exe.root_module.addImport("gcode_parser", gcode_parser_mod);

        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        const run_step = b.step(example.name, example.description);
        run_step.dependOn(&run_cmd.step);
    }

    // Build and run benchmarks
    const benchmarks = b.addExecutable(.{
        .name = "bench",
        .root_source_file = b.path("bench/main.zig"),
        .target = target,
        .optimize = .ReleaseFast, // Always optimize benchmarks
    });
    benchmarks.root_module.addImport("gcode_parser", gcode_parser_mod);
    b.installArtifact(benchmarks);

    const run_benchmarks = b.addRunArtifact(benchmarks);
    const benchmark_step = b.step("bench", "Run performance benchmarks");
    benchmark_step.dependOn(&run_benchmarks.step);
}
