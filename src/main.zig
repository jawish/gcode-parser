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

// Import the gcode_parser module
const gcode_parser = @import("gcode_parser.zig");

// Re-export all public interfaces
pub const AddressConfig = gcode_parser.AddressConfig;
pub const AddressConfigError = gcode_parser.AddressConfigError;
pub const AddressDialects = gcode_parser.AddressDialects;
pub const Block = gcode_parser.Block;
pub const Limits = gcode_parser.Limits;
pub const ParseError = gcode_parser.ParseError;
// pub const ParseResult = gcode_parser.ParseResult;
pub const Parser = gcode_parser.Parser;
pub const ParserOptions = gcode_parser.ParserOptions;
pub const Word = gcode_parser.Word;

test {
    // Include all tests from the gcode_parser module
    @import("std").testing.refAllDecls(@This());
}
