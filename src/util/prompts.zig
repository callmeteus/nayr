//! Clack-style interactive prompts for the terminal.
//!
//! Visual style inspired by @clack/prompts:
//!
//!   ┌  Title
//!   │
//!   ◆  What would you like to do?
//!   │  ● Option A
//!   │  ○ Option B
//!   │
//!   ◇  Completed step
//!   └  Done!
//!
//! All prompts operate in raw terminal mode for single-keypress interaction.

const std = @import("std");
const builtin = @import("builtin");

// ============================================================================
// Raw terminal mode
// ============================================================================

/// Saved terminal state — returned by `enterRawMode`, passed to `leaveRawMode`.
pub const RawMode = struct {
    orig: std.posix.termios,
    fd: std.posix.fd_t,
};

/// Switches stdin to raw mode (no echo, no line buffering).
/// Call `leaveRawMode` to restore the original settings.
pub fn enterRawMode() !RawMode {
    const fd = std.io.getStdIn().handle;
    const orig = try std.posix.tcgetattr(fd);
    var raw = orig;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    raw.cc[@intFromEnum(std.os.linux.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.os.linux.V.TIME)] = 0;
    try std.posix.tcsetattr(fd, .NOW, raw);
    return .{ .orig = orig, .fd = fd };
}

pub fn leaveRawMode(rm: RawMode) void {
    std.posix.tcsetattr(rm.fd, .NOW, rm.orig) catch {};
}

// ============================================================================
// Key events
// ============================================================================

pub const Key = union(enum) {
    up,
    down,
    left,
    right,
    enter,
    backspace,
    delete,
    escape,
    ctrl_c,
    char: u8,
};

pub fn readKey(reader: anytype) !Key {
    const b = try reader.readByte();
    return switch (b) {
        '\r', '\n' => .enter,
        3 => .ctrl_c,   // Ctrl+C
        127, 8 => .backspace,
        27 => blk: {    // ESC sequence
            const b2 = reader.readByte() catch return .escape;
            if (b2 != '[') break :blk .escape;
            const b3 = reader.readByte() catch return .escape;
            break :blk switch (b3) {
                'A' => .up,
                'B' => .down,
                'C' => .right,
                'D' => .left,
                '3' => del: {
                    _ = reader.readByte() catch {};
                    break :del .delete;
                },
                else => .escape,
            };
        },
        else => .{ .char = b },
    };
}

// ============================================================================
// Colour helpers
// ============================================================================

const C = struct {
    const reset   = "\x1b[0m";
    const dim     = "\x1b[2m";
    const bold    = "\x1b[1m";
    const green   = "\x1b[32m";
    const cyan    = "\x1b[36m";
    const yellow  = "\x1b[33m";
    const red     = "\x1b[31m";
    const magenta = "\x1b[35m";
};

fn c(colour: bool, code: []const u8) []const u8 {
    return if (colour) code else "";
}

// ============================================================================
// Block primitives
// ============================================================================

pub const Theme = struct {
    colour: bool = true,

    /// Print the opening "┌  Title" bar.
    pub fn intro(self: Theme, writer: anytype, title: []const u8) void {
        if (self.colour) {
            writer.print("{s}┌{s}  {s}{s}{s}\n", .{
                C.dim, C.reset, C.bold, title, C.reset,
            }) catch {};
        } else {
            writer.print("┌  {s}\n", .{title}) catch {};
        }
    }

    /// Print the closing "└  text" bar.
    pub fn outro(self: Theme, writer: anytype, text: []const u8) void {
        if (self.colour) {
            writer.print("{s}└{s}  {s}\n", .{ C.dim, C.reset, text }) catch {};
        } else {
            writer.print("└  {s}\n", .{text}) catch {};
        }
    }

    /// Print a "│" spacer line.
    pub fn spacer(self: Theme, writer: anytype) void {
        writer.print("{s}│{s}\n", .{ c(self.colour, C.dim), c(self.colour, C.reset) }) catch {};
    }

    /// Print "│  text" info line.
    pub fn note(self: Theme, writer: anytype, text: []const u8) void {
        writer.print("{s}│{s}  {s}\n", .{ c(self.colour, C.dim), c(self.colour, C.reset), text }) catch {};
    }

    /// Print a completed step: "◇  label  value".
    pub fn done_step(self: Theme, writer: anytype, label: []const u8, value: []const u8) void {
        if (self.colour) {
            writer.print("{s}◇{s}  {s}{s}{s}  {s}{s}{s}\n", .{
                C.dim, C.reset, C.dim, label, C.reset, C.green, value, C.reset,
            }) catch {};
        } else {
            writer.print("◇  {s}  {s}\n", .{ label, value }) catch {};
        }
    }
};

// ============================================================================
// select() — arrow-key option picker
// ============================================================================

pub const SelectResult = union(enum) {
    selected: usize,
    cancelled,
};

/// Renders an interactive selection prompt.
/// Returns the chosen index, or `.cancelled` on Esc/Ctrl-C.
pub fn select(
    writer: anytype,
    theme: Theme,
    prompt: []const u8,
    items: []const []const u8,
    initial: usize,
) !SelectResult {
    const stdin = std.io.getStdIn().reader();
    var cursor: usize = @min(initial, if (items.len > 0) items.len - 1 else 0);

    var lines_drawn: usize = 0;

    while (true) {
        // Clear previously drawn lines.
        if (lines_drawn > 0) {
            writer.print("\x1b[{d}A\x1b[0J", .{lines_drawn}) catch {};
        }

        // Draw prompt line.
        if (theme.colour) {
            writer.print("{s}◆{s}  {s}{s}{s}\n", .{
                C.green, C.reset, C.bold, prompt, C.reset,
            }) catch {};
        } else {
            writer.print("◆  {s}\n", .{prompt}) catch {};
        }
        lines_drawn = 1;

        // Draw options.
        for (items, 0..) |item, i| {
            const is_selected = (i == cursor);
            if (theme.colour) {
                if (is_selected) {
                    writer.print("{s}│{s}  {s}●{s}  {s}\n", .{
                        C.dim, C.reset, C.green, C.reset, item,
                    }) catch {};
                } else {
                    writer.print("{s}│  ○  {s}{s}{s}\n", .{
                        C.dim, C.reset, C.dim, C.reset,
                    }) catch {};
                    // Reprint with item after dim reset
                    writer.print("\x1b[1A\x1b[0K{s}│{s}  {s}○{s}  {s}{s}{s}\n", .{
                        C.dim, C.reset, C.dim, C.reset, C.dim, item, C.reset,
                    }) catch {};
                }
            } else {
                writer.print("│  {s}  {s}\n", .{
                    if (is_selected) @as([]const u8, "●") else "○",
                    item,
                }) catch {};
            }
            lines_drawn += 1;
        }

        const key = readKey(stdin) catch return .cancelled;
        switch (key) {
            .up => if (cursor > 0) { cursor -= 1; },
            .down => if (cursor < items.len - 1) { cursor += 1; },
            .enter => {
                // Replace prompt with completed style.
                writer.print("\x1b[{d}A\x1b[0J", .{lines_drawn}) catch {};
                if (theme.colour) {
                    writer.print("{s}◇{s}  {s}{s}{s}  {s}{s}{s}\n", .{
                        C.dim, C.reset, C.dim, prompt, C.reset, C.green, items[cursor], C.reset,
                    }) catch {};
                } else {
                    writer.print("◇  {s}  {s}\n", .{ prompt, items[cursor] }) catch {};
                }
                return .{ .selected = cursor };
            },
            .ctrl_c, .escape => {
                writer.print("\x1b[{d}A\x1b[0J", .{lines_drawn}) catch {};
                if (theme.colour) {
                    writer.print("{s}◇{s}  {s}{s}{s}  {s}cancelled{s}\n", .{
                        C.dim, C.reset, C.dim, prompt, C.reset, C.dim, C.reset,
                    }) catch {};
                }
                return .cancelled;
            },
            else => {},
        }
    }
}

// ============================================================================
// textInput() — single-line text entry
// ============================================================================

pub const TextResult = union(enum) {
    value: []u8,   // Caller owns memory
    cancelled,
};

/// Renders a text input prompt.  Returns the entered string (owned by caller)
/// or `.cancelled` on Esc/Ctrl-C.
pub fn textInput(
    allocator: std.mem.Allocator,
    writer: anytype,
    theme: Theme,
    prompt: []const u8,
    placeholder: []const u8,
) !TextResult {
    const stdin = std.io.getStdIn().reader();

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    // Draw initial prompt.
    if (theme.colour) {
        writer.print("{s}◆{s}  {s}{s}{s}\n{s}│{s}  ", .{
            C.green, C.reset, C.bold, prompt, C.reset,
            C.dim, C.reset,
        }) catch {};
        if (placeholder.len > 0) {
            writer.print("{s}{s}{s}", .{ C.dim, placeholder, C.reset }) catch {};
            // Move cursor back to start of placeholder.
            writer.print("\x1b[{d}D", .{placeholder.len}) catch {};
        }
    } else {
        writer.print("◆  {s}\n│  ", .{prompt}) catch {};
    }

    var had_placeholder = placeholder.len > 0;

    while (true) {
        const key = readKey(stdin) catch {
            return .cancelled;
        };
        switch (key) {
            .enter => {
                const val = if (buf.items.len == 0 and placeholder.len > 0)
                    try allocator.dupe(u8, placeholder)
                else
                    try buf.toOwnedSlice();
                // Replace with completed style.
                writer.print("\r\x1b[1A\x1b[0J", .{}) catch {};
                if (theme.colour) {
                    writer.print("{s}◇{s}  {s}{s}{s}  {s}{s}{s}\n", .{
                        C.dim, C.reset, C.dim, prompt, C.reset, C.green, val, C.reset,
                    }) catch {};
                } else {
                    writer.print("◇  {s}  {s}\n", .{ prompt, val }) catch {};
                }
                return .{ .value = val };
            },
            .backspace => {
                if (had_placeholder) {
                    // Clear placeholder.
                    if (placeholder.len > 0) {
                        writer.print("\x1b[{d}C\x1b[{d}D{s}", .{
                            placeholder.len, placeholder.len,
                            " " ** 64,  // overwrite
                        }) catch {};
                        writer.print("\x1b[{d}D", .{placeholder.len}) catch {};
                    }
                    had_placeholder = false;
                } else if (buf.items.len > 0) {
                    _ = buf.pop();
                    writer.print("\x1b[1D \x1b[1D", .{}) catch {};
                }
            },
            .ctrl_c, .escape => {
                writer.print("\r\x1b[1A\x1b[0J", .{}) catch {};
                if (theme.colour) {
                    writer.print("{s}◇{s}  {s}{s}{s}  {s}cancelled{s}\n", .{
                        C.dim, C.reset, C.dim, prompt, C.reset, C.dim, C.reset,
                    }) catch {};
                }
                return .cancelled;
            },
            .char => |ch| {
                if (had_placeholder) {
                    // Overwrite placeholder.
                    writer.print("\x1b[{d}D\x1b[0K", .{placeholder.len}) catch {};
                    had_placeholder = false;
                }
                try buf.append(ch);
                writer.print("{c}", .{ch}) catch {};
            },
            else => {},
        }
    }
}

// ============================================================================
// confirm() — yes/no toggle
// ============================================================================

pub const ConfirmResult = union(enum) {
    value: bool,
    cancelled,
};

/// Renders a yes/no confirmation prompt with arrow-key toggle.
pub fn confirm(
    writer: anytype,
    theme: Theme,
    prompt: []const u8,
    default: bool,
) !ConfirmResult {
    const stdin = std.io.getStdIn().reader();
    var val = default;
    var lines_drawn: usize = 0;

    while (true) {
        if (lines_drawn > 0) writer.print("\x1b[{d}A\x1b[0J", .{lines_drawn}) catch {};

        if (theme.colour) {
            writer.print("{s}◆{s}  {s}{s}{s}\n{s}│{s}  ", .{
                C.green, C.reset, C.bold, prompt, C.reset, C.dim, C.reset,
            }) catch {};
            if (val) {
                writer.print("{s}● Yes{s}  {s}○ No{s}\n", .{ C.green, C.reset, C.dim, C.reset }) catch {};
            } else {
                writer.print("{s}○ Yes{s}  {s}● No{s}\n", .{ C.dim, C.reset, C.green, C.reset }) catch {};
            }
        } else {
            writer.print("◆  {s}\n│  {s} Yes  {s} No\n", .{
                prompt,
                if (val) @as([]const u8, "●") else "○",
                if (!val) @as([]const u8, "●") else "○",
            }) catch {};
        }
        lines_drawn = 2;

        const key = readKey(stdin) catch return .cancelled;
        switch (key) {
            .left, .right, .up, .down => val = !val,
            .enter => {
                writer.print("\x1b[{d}A\x1b[0J", .{lines_drawn}) catch {};
                if (theme.colour) {
                    writer.print("{s}◇{s}  {s}{s}{s}  {s}{s}{s}\n", .{
                        C.dim, C.reset, C.dim, prompt, C.reset,
                        C.green, if (val) @as([]const u8, "Yes") else "No", C.reset,
                    }) catch {};
                } else {
                    writer.print("◇  {s}  {s}\n", .{ prompt, if (val) "Yes" else "No" }) catch {};
                }
                return .{ .value = val };
            },
            .ctrl_c, .escape => {
                writer.print("\x1b[{d}A\x1b[0J", .{lines_drawn}) catch {};
                return .cancelled;
            },
            else => {},
        }
    }
}
