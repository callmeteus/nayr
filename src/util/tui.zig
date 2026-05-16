//! TUI Primitives
//!
//! Low-level terminal control utilities used by the TUI output writer.
//! Handles ANSI escape codes, cursor movement, and terminal-width detection.
//! All rendering logic lives in output.zig; this module only exposes the
//! raw terminal operations.

// ============================================================================
// ANSI colour codes
// ============================================================================

/// ANSI escape sequences for terminal colours and styles.
/// Empty strings are used when colour is disabled.
pub const Colour = struct {
    pub const reset = "\x1b[0m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";
    pub const red = "\x1b[31m";
    pub const green = "\x1b[32m";
    pub const yellow = "\x1b[33m";
    pub const blue = "\x1b[34m";
    pub const magenta = "\x1b[35m";
    pub const cyan = "\x1b[36m";
    pub const white = "\x1b[37m";
};

// ============================================================================
// Cursor control
// ============================================================================

/// Moves the cursor up by `n` lines (used to overwrite progress bars in place).
pub fn cursorUp(writer: anytype, n: u16) void {
    writer.print("\x1b[{d}A", .{n}) catch {};
}

/// Clears the current line and moves the cursor to column 0.
pub fn clearLine(writer: anytype) void {
    writer.print("\x1b[2K\r", .{}) catch {};
}

// ============================================================================
// Progress bar
// ============================================================================

/// Renders an ASCII progress bar into `buf`.
///
/// Example output (width=24, filled=10, total=20):
///   `████████████░░░░░░░░░░░░`
///
/// ## Parameters
/// - `buf`: Destination buffer. Must be at least `width` bytes long.
/// - `filled`: Number of completed steps.
/// - `total`: Total number of steps.
/// - `width`: Width of the bar in characters.
pub fn renderBar(buf: []u8, filled: u32, total: u32, width: u16) []const u8 {
    const fill_count: usize = if (total == 0)
        0
    else
        @min(@as(usize, width), @as(usize, filled) * @as(usize, width) / @as(usize, total));

    var i: usize = 0;
    while (i < width) : (i += 1) {
        buf[i] = if (i < fill_count) '\xe2' else '\xe2'; // placeholder
    }
    // Use block chars: U+2588 FULL BLOCK (3 bytes UTF-8) for filled,
    // U+2591 LIGHT SHADE for empty. For simplicity use ASCII here.
    i = 0;
    while (i < @as(usize, width)) : (i += 1) {
        buf[i] = if (i < fill_count) '#' else '.';
    }
    return buf[0..width];
}

// ============================================================================
// Spinner
// ============================================================================

/// Spinner frame characters (braille pattern, smooth rotation).
pub const spinner_frames = [_]u8{ '-', '\\', '|', '/' };

/// Returns the spinner character for the given frame index.
pub fn spinnerFrame(frame: u32) u8 {
    return spinner_frames[frame % spinner_frames.len];
}

// ============================================================================
// Table rendering
// ============================================================================

/// Renders a slice of string slices as an aligned table row.
///
/// Each column is padded to the given column widths with spaces.
///
/// ## Parameters
/// - `writer`: Output writer.
/// - `columns`: Slice of column values.
/// - `widths`: Minimum width for each column.
pub fn renderTableRow(writer: anytype, columns: []const []const u8, widths: []const u16) void {
    for (columns, 0..) |col, i| {
        writer.print("{s}", .{col}) catch {};
        if (i < widths.len) {
            const pad = if (col.len < widths[i]) widths[i] - col.len else 0;
            var p: usize = 0;
            while (p < pad) : (p += 1) writer.print(" ", .{}) catch {};
        }
        if (i + 1 < columns.len) writer.print("  ", .{}) catch {};
    }
    writer.print("\n", .{}) catch {};
}
