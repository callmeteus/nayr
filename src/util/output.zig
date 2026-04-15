//! Output Formatting Engine
//!
//! All nayr output passes through this module. No command writes to stdout
//! directly. This enables three rendering modes selected by --format:
//!
//!   tui  - rich TUI with progress bars, spinners, ANSI colours (default on TTY)
//!   text - plain one-line-per-event (default when stdout is a pipe)
//!   json - NDJSON; one JSON object per line (machine-readable)
//!
//! The auto-detection logic: if stdout is a TTY → tui, otherwise → text.
//! --format always overrides auto-detection.

const std = @import("std");
const platform = @import("platform.zig");
const tui = @import("tui.zig");
const build_options = @import("build_options");

// ============================================================================
// Output format enum
// ============================================================================

/// Selects how nayr renders its output.
pub const Format = enum {
    /// Rich terminal UI with progress bars and colours.
    tui,
    /// Plain text, one line per event. Suitable for logs and pipes.
    text,
    /// NDJSON (newline-delimited JSON). One object per event.
    json,

    /// Parses a format name from a CLI flag value.
    ///
    /// ## Parameters
    /// - `s`: String value of --format flag (e.g. "tui", "text", "json").
    ///
    /// ## Returns
    /// The matching `Format`, or `error.UnknownFormat`.
    pub fn parse(s: []const u8) !Format {
        if (std.mem.eql(u8, s, "tui")) return .tui;
        if (std.mem.eql(u8, s, "text")) return .text;
        if (std.mem.eql(u8, s, "json")) return .json;
        return error.UnknownFormat;
    }

    /// Auto-detects the best format for the current environment.
    /// Returns `tui` when stdout is a TTY, `text` otherwise.
    pub fn autoDetect() Format {
        return if (platform.isStdoutTty()) .tui else .text;
    }
};

// ============================================================================
// Event types
// ============================================================================

/// All events that commands can emit. The active Writer renders each event
/// according to the selected Format.
pub const Event = union(enum) {
    /// Resolution phase progress: N of M packages resolved from registry.
    /// `name` is the package just resolved (empty string = unknown).
    resolve_progress: struct { resolved: u32, total: u32, name: []const u8 = "" },

    /// Fetch phase progress: N tarballs downloaded, at the given byte rate.
    fetch_progress: struct { fetched: u32, total: u32, bytes_per_sec: u64 },

    /// Link phase progress: N packages installed into node_modules.
    link_progress: struct { linked: u32, total: u32 },

    /// A single package was added to the resolution set.
    package_resolved: struct { name: []const u8, version: []const u8 },

    /// A tarball was found in cache (cache hit).
    cache_hit: struct { name: []const u8, version: []const u8 },

    /// A package lifecycle script started.
    script_start: struct { name: []const u8, script: []const u8 },

    /// Captured output from a lifecycle script (shown on failure).
    script_output: struct {
        name: []const u8,
        stdout: []const u8,
        stderr: []const u8,
    },

    /// Informational message shown to the user.
    info: []const u8,

    /// Non-fatal warning.
    warning: []const u8,

    /// Fatal error message (process will exit after this).
    err: []const u8,

    /// A row in a tabular output (nayr why, nayr licenses, nayr audit …).
    table_row: struct { columns: []const []const u8 },

    /// A node in a tree-shaped output (nayr why dependency tree).
    tree_node: struct { depth: u8, label: []const u8 },

    /// Command completed successfully.
    done: struct { elapsed_ms: u64, summary: []const u8 },
};

// ============================================================================
// Writer interface
// ============================================================================

/// A type-erased output writer. Constructed once per invocation and passed
/// down to every command so they all share the same rendering pipeline.
pub const Writer = struct {
    /// Opaque pointer to the concrete implementation.
    ptr: *anyopaque,
    /// Vtable - set at construction time depending on the selected format.
    vtable: *const VTable,

    pub const VTable = struct {
        emit: *const fn (ptr: *anyopaque, event: Event) void,
        flush: *const fn (ptr: *anyopaque) void,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    /// Emits an event, delegating to the concrete implementation.
    pub fn emit(self: Writer, event: Event) void {
        self.vtable.emit(self.ptr, event);
    }

    /// Flushes any buffered output.
    pub fn flush(self: Writer) void {
        self.vtable.flush(self.ptr);
    }

    /// Releases resources held by the writer.
    pub fn deinit(self: Writer) void {
        self.vtable.deinit(self.ptr);
    }
};

// ============================================================================
// Factory
// ============================================================================

/// Creates a Writer for the given format, allocating any required state.
///
/// ## Parameters
/// - `allocator`: Arena or GPA - writer state lives for the CLI invocation.
/// - `format`: The rendering format to use.
/// - `verbose`: Whether to emit verbose (debug-level) events.
pub fn createWriter(allocator: std.mem.Allocator, format: Format, verbose: bool) !Writer {
    switch (format) {
        .tui => {
            const impl = try allocator.create(TuiWriter);
            impl.* = TuiWriter.init(allocator, verbose);
            return Writer{
                .ptr = impl,
                .vtable = &TuiWriter.vtable,
            };
        },
        .text => {
            const impl = try allocator.create(TextWriter);
            impl.* = TextWriter.init(allocator, verbose);
            return Writer{
                .ptr = impl,
                .vtable = &TextWriter.vtable,
            };
        },
        .json => {
            const impl = try allocator.create(JsonWriter);
            impl.* = JsonWriter.init(allocator, verbose);
            return Writer{
                .ptr = impl,
                .vtable = &JsonWriter.vtable,
            };
        },
    }
}

// ============================================================================
// TUI writer
// ============================================================================

/// Braille spinner frames (10-frame cycle).
const SPINNER = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

const TuiWriter = struct {
    allocator: std.mem.Allocator,
    verbose: bool,
    stdout: std.fs.File,
    /// Whether ANSI colour codes should be emitted.
    colour: bool,
    /// Current spinner frame (advances on each progress event).
    spinner_frame: u8 = 0,
    /// True when the last line written was a \r progress line that may need
    /// to be cleared before writing a regular (newline-terminated) event.
    on_progress_line: bool = false,

    const vtable = Writer.VTable{
        .emit = emit,
        .flush = flush,
        .deinit = deinitFn,
    };

    fn init(allocator: std.mem.Allocator, verbose: bool) TuiWriter {
        return .{
            .allocator = allocator,
            .verbose = verbose,
            .stdout = std.io.getStdOut(),
            // Disable colour when the terminal says NO_COLOR or TERM=dumb.
            .colour = !hasNoColor(),
        };
    }

    /// Clears the current progress line before printing regular output.
    /// No-op when not on a progress line.
    fn clearProgress(self: *TuiWriter) void {
        if (!self.on_progress_line) return;
        const w = self.stdout.writer();
        if (self.colour) {
            // ANSI: erase entire line, then carriage-return.
            w.writeAll("\x1b[2K\r") catch {};
        } else {
            w.writeByte('\n') catch {};
        }
        self.on_progress_line = false;
    }

    fn emit(ptr: *anyopaque, event: Event) void {
        const self: *TuiWriter = @ptrCast(@alignCast(ptr));
        const w = self.stdout.writer();
        switch (event) {
            .resolve_progress => |p| {
                const frame = SPINNER[self.spinner_frame % SPINNER.len];
                self.spinner_frame +%= 1;

                if (self.colour) {
                    if (p.name.len > 0) {
                        // Trim long names to keep the line short.
                        const max_name = 35;
                        const display_name = if (p.name.len > max_name) p.name[0..max_name] else p.name;
                        w.print("\x1b[2K\r\x1b[36m {s}\x1b[0m  resolving  \x1b[1m{d}\x1b[0m packages  \x1b[2m{s}\x1b[0m", .{
                            frame, p.resolved, display_name,
                        }) catch {};
                    } else {
                        w.print("\x1b[2K\r\x1b[36m {s}\x1b[0m  resolving  \x1b[1m{d}\x1b[0m packages", .{
                            frame, p.resolved,
                        }) catch {};
                    }
                } else {
                    w.print("\rresolving {d} packages", .{p.resolved}) catch {};
                }
                self.on_progress_line = true;
            },
            .fetch_progress => |p| {
                const frame = SPINNER[self.spinner_frame % SPINNER.len];
                self.spinner_frame +%= 1;
                if (self.colour) {
                    if (p.bytes_per_sec > 0) {
                        const mbps = @as(f64, @floatFromInt(p.bytes_per_sec)) / (1024.0 * 1024.0);
                        w.print("\x1b[2K\r\x1b[32m {s}\x1b[0m  fetching   \x1b[1m{d}/{d}\x1b[0m  \x1b[2m{d:.1} MB/s\x1b[0m", .{
                            frame, p.fetched, p.total, mbps,
                        }) catch {};
                    } else {
                        w.print("\x1b[2K\r\x1b[32m {s}\x1b[0m  fetching   \x1b[1m{d}/{d}\x1b[0m", .{
                            frame, p.fetched, p.total,
                        }) catch {};
                    }
                } else {
                    w.print("\rfetching {d}/{d}", .{ p.fetched, p.total }) catch {};
                }
                self.on_progress_line = true;
            },
            .link_progress => |p| {
                const frame = SPINNER[self.spinner_frame % SPINNER.len];
                self.spinner_frame +%= 1;
                if (self.colour) {
                    w.print("\x1b[2K\r\x1b[35m {s}\x1b[0m  linking    \x1b[1m{d}/{d}\x1b[0m", .{
                        frame, p.linked, p.total,
                    }) catch {};
                } else {
                    w.print("\rlinking {d}/{d}", .{ p.linked, p.total }) catch {};
                }
                self.on_progress_line = true;
            },
            .info => |msg| {
                self.clearProgress();
                w.print("{s}  info{s}  {s}\n", .{
                    if (self.colour) "\x1b[2m" else "",
                    if (self.colour) "\x1b[0m" else "",
                    msg,
                }) catch {};
            },
            .warning => |msg| {
                self.clearProgress();
                w.print("{s}  warn{s}  {s}\n", .{
                    if (self.colour) "\x1b[33m" else "",
                    if (self.colour) "\x1b[0m" else "",
                    msg,
                }) catch {};
            },
            .err => |msg| {
                self.clearProgress();
                const stderr = std.io.getStdErr().writer();
                stderr.print("{s}  error{s} {s}\n", .{
                    if (self.colour) "\x1b[1;31m" else "",
                    if (self.colour) "\x1b[0m" else "",
                    msg,
                }) catch {};
            },
            .done => |d| {
                self.clearProgress();
                const secs = @as(f64, @floatFromInt(d.elapsed_ms)) / 1000.0;
                if (self.colour) {
                    w.print("\x1b[32m  ✔\x1b[0m  {s}  \x1b[2m({d:.2}s)\x1b[0m\n", .{
                        d.summary, secs,
                    }) catch {};
                } else {
                    w.print("  done  {s} ({d:.2}s)\n", .{ d.summary, secs }) catch {};
                }
            },
            .table_row => |row| {
                self.clearProgress();
                for (row.columns, 0..) |col, i| {
                    if (i > 0) w.print("  ", .{}) catch {};
                    w.print("{s}", .{col}) catch {};
                }
                w.print("\n", .{}) catch {};
            },
            .tree_node => |node| {
                self.clearProgress();
                var i: u8 = 0;
                while (i < node.depth) : (i += 1) w.print("  ", .{}) catch {};
                w.print("└─ {s}\n", .{node.label}) catch {};
            },
            .package_resolved => |p| {
                if (self.verbose) {
                    self.clearProgress();
                    w.print("  resolved {s}@{s}\n", .{ p.name, p.version }) catch {};
                }
            },
            .cache_hit => |p| {
                if (self.verbose) {
                    self.clearProgress();
                    w.print("  cache hit {s}@{s}\n", .{ p.name, p.version }) catch {};
                }
            },
            .script_start => |s| {
                self.clearProgress();
                w.print("  $ {s} [{s}]\n", .{ s.script, s.name }) catch {};
            },
            .script_output => |s| {
                self.clearProgress();
                const prefix = if (self.colour) "\x1b[2m" else "";
                const reset = if (self.colour) "\x1b[0m" else "";
                if (s.stdout.len > 0) {
                    var lines = std.mem.splitScalar(u8, std.mem.trimRight(u8, s.stdout, "\n"), '\n');
                    while (lines.next()) |line| {
                        w.print("{s}  │ {s}{s}\n", .{ prefix, line, reset }) catch {};
                    }
                }
                if (s.stderr.len > 0) {
                    var lines = std.mem.splitScalar(u8, std.mem.trimRight(u8, s.stderr, "\n"), '\n');
                    while (lines.next()) |line| {
                        w.print("{s}  │ {s}{s}\n", .{ prefix, line, reset }) catch {};
                    }
                }
            },
        }
    }

    fn flush(ptr: *anyopaque) void {
        const self: *TuiWriter = @ptrCast(@alignCast(ptr));
        self.clearProgress();
        self.stdout.sync() catch {};
    }

    fn deinitFn(ptr: *anyopaque) void {
        const self: *TuiWriter = @ptrCast(@alignCast(ptr));
        self.clearProgress();
        self.allocator.destroy(self);
    }
};

// ============================================================================
// Text writer
// ============================================================================

const TextWriter = struct {
    allocator: std.mem.Allocator,
    verbose: bool,
    stdout: std.fs.File,

    const vtable = Writer.VTable{
        .emit = emit,
        .flush = flush,
        .deinit = deinitFn,
    };

    fn init(allocator: std.mem.Allocator, verbose: bool) TextWriter {
        return .{ .allocator = allocator, .verbose = verbose, .stdout = std.io.getStdOut() };
    }

    fn emit(ptr: *anyopaque, event: Event) void {
        const self: *TextWriter = @ptrCast(@alignCast(ptr));
        const w = self.stdout.writer();
        switch (event) {
            // Progress events are only shown in verbose mode for the text
            // writer; the TUI writer handles them with a live spinner line.
            .resolve_progress => |p| {
                if (self.verbose) w.print("[resolve] {d}/{d} packages\n", .{ p.resolved, p.total }) catch {};
            },
            .fetch_progress => |p| {
                if (self.verbose) {
                    const mbps = @as(f64, @floatFromInt(p.bytes_per_sec)) / (1024.0 * 1024.0);
                    w.print("[fetch] {d}/{d} packages ({d:.1} MB/s)\n", .{ p.fetched, p.total, mbps }) catch {};
                }
            },
            .link_progress => |p| {
                if (self.verbose) w.print("[link] {d}/{d} packages\n", .{ p.linked, p.total }) catch {};
            },
            .info => |msg| w.print("[info] {s}\n", .{msg}) catch {},
            .warning => |msg| w.print("[warn] {s}\n", .{msg}) catch {},
            .err => |msg| std.io.getStdErr().writer().print("[error] {s}\n", .{msg}) catch {},
            .done => |d| {
                const secs = @as(f64, @floatFromInt(d.elapsed_ms)) / 1000.0;
                w.print("[done] {s} ({d:.2}s)\n", .{ d.summary, secs }) catch {};
            },
            .table_row => |row| {
                for (row.columns, 0..) |col, i| {
                    if (i > 0) w.print("\t", .{}) catch {};
                    w.print("{s}", .{col}) catch {};
                }
                w.print("\n", .{}) catch {};
            },
            .tree_node => |node| {
                var i: u8 = 0;
                while (i < node.depth) : (i += 1) w.print("  ", .{}) catch {};
                w.print("{s}\n", .{node.label}) catch {};
            },
            .package_resolved => |p| {
                if (self.verbose) w.print("[resolved] {s}@{s}\n", .{ p.name, p.version }) catch {};
            },
            .cache_hit => |p| {
                if (self.verbose) w.print("[cache] hit {s}@{s}\n", .{ p.name, p.version }) catch {};
            },
            .script_start => |s| w.print("[script] {s}: {s}\n", .{ s.name, s.script }) catch {},
            .script_output => |s| {
                if (s.stdout.len > 0) w.print("{s}", .{s.stdout}) catch {};
                if (s.stderr.len > 0) w.print("{s}", .{s.stderr}) catch {};
            },
        }
    }

    fn flush(ptr: *anyopaque) void {
        const self: *TextWriter = @ptrCast(@alignCast(ptr));
        self.stdout.sync() catch {};
    }

    fn deinitFn(ptr: *anyopaque) void {
        const self: *TextWriter = @ptrCast(@alignCast(ptr));
        self.allocator.destroy(self);
    }
};

// ============================================================================
// JSON writer
// ============================================================================

const JsonWriter = struct {
    allocator: std.mem.Allocator,
    verbose: bool,
    stdout: std.fs.File,

    const vtable = Writer.VTable{
        .emit = emit,
        .flush = flush,
        .deinit = deinitFn,
    };

    fn init(allocator: std.mem.Allocator, verbose: bool) JsonWriter {
        return .{ .allocator = allocator, .verbose = verbose, .stdout = std.io.getStdOut() };
    }

    fn emit(ptr: *anyopaque, event: Event) void {
        const self: *JsonWriter = @ptrCast(@alignCast(ptr));
        const w = self.stdout.writer();
        switch (event) {
            .resolve_progress => |p| w.print(
                "{{\"type\":\"resolve_progress\",\"resolved\":{d},\"total\":{d}}}\n",
                .{ p.resolved, p.total },
            ) catch {},
            .fetch_progress => |p| w.print(
                "{{\"type\":\"fetch_progress\",\"fetched\":{d},\"total\":{d},\"bytes_per_sec\":{d}}}\n",
                .{ p.fetched, p.total, p.bytes_per_sec },
            ) catch {},
            .link_progress => |p| w.print(
                "{{\"type\":\"link_progress\",\"linked\":{d},\"total\":{d}}}\n",
                .{ p.linked, p.total },
            ) catch {},
            .info => |msg| w.print("{{\"type\":\"info\",\"message\":{s}}}\n", .{jsonStr(msg)}) catch {},
            .warning => |msg| w.print("{{\"type\":\"warning\",\"message\":{s}}}\n", .{jsonStr(msg)}) catch {},
            .err => |msg| std.io.getStdErr().writer().print(
                "{{\"type\":\"error\",\"message\":{s}}}\n",
                .{jsonStr(msg)},
            ) catch {},
            .done => |d| w.print(
                "{{\"type\":\"done\",\"elapsed_ms\":{d},\"summary\":{s}}}\n",
                .{ d.elapsed_ms, jsonStr(d.summary) },
            ) catch {},
            .table_row => |row| {
                w.print("{{\"type\":\"table_row\",\"columns\":[", .{}) catch {};
                for (row.columns, 0..) |col, i| {
                    if (i > 0) w.print(",", .{}) catch {};
                    w.print("{s}", .{jsonStr(col)}) catch {};
                }
                w.print("]}}\n", .{}) catch {};
            },
            .tree_node => |node| w.print(
                "{{\"type\":\"tree_node\",\"depth\":{d},\"label\":{s}}}\n",
                .{ node.depth, jsonStr(node.label) },
            ) catch {},
            .package_resolved => |p| {
                if (self.verbose) w.print(
                    "{{\"type\":\"package_resolved\",\"name\":{s},\"version\":{s}}}\n",
                    .{ jsonStr(p.name), jsonStr(p.version) },
                ) catch {};
            },
            .cache_hit => |p| {
                if (self.verbose) w.print(
                    "{{\"type\":\"cache_hit\",\"name\":{s},\"version\":{s}}}\n",
                    .{ jsonStr(p.name), jsonStr(p.version) },
                ) catch {};
            },
            .script_start => |s| w.print(
                "{{\"type\":\"script_start\",\"name\":{s},\"script\":{s}}}\n",
                .{ jsonStr(s.name), jsonStr(s.script) },
            ) catch {},
            .script_output => |s| w.print(
                "{{\"type\":\"script_output\",\"name\":{s},\"stdout\":{s},\"stderr\":{s}}}\n",
                .{ jsonStr(s.name), jsonStr(s.stdout), jsonStr(s.stderr) },
            ) catch {},
        }
    }

    fn flush(ptr: *anyopaque) void {
        const self: *JsonWriter = @ptrCast(@alignCast(ptr));
        self.stdout.sync() catch {};
    }

    fn deinitFn(ptr: *anyopaque) void {
        const self: *JsonWriter = @ptrCast(@alignCast(ptr));
        self.allocator.destroy(self);
    }

    /// Wraps a string in JSON double-quotes. Does NOT escape interior chars -
    /// a full implementation would escape \", \\, and control characters.
    inline fn jsonStr(s: []const u8) []const u8 {
        // TODO: return properly escaped JSON string literal.
        // For now, callers must ensure `s` contains no special chars.
        return s;
    }
};

// ============================================================================
// Banner
// ============================================================================

/// Prints the `nayr vX.Y.Z` header to stdout.
///
/// Only printed when:
///   - `format` is `.tui` (i.e. the output is an interactive terminal), AND
///   - `silent` is false.
///
/// The line is intentionally short - no taglines or ASCII art - so it stays
/// clean inside monorepo build output.
pub fn printBanner(format: Format, silent: bool) void {
    if (silent or format != .tui) return;
    const colour = !hasNoColor();
    const w = std.io.getStdErr().writer();
    if (colour) {
        // Bright white "nayr" + dim cyan version
        w.print("\x1b[1mnayr\x1b[0m \x1b[2mv{s}\x1b[0m\n", .{build_options.version}) catch {};
    } else {
        w.print("nayr v{s}\n", .{build_options.version}) catch {};
    }
}

// ============================================================================
// Helpers
// ============================================================================

/// Returns true when stderr is a TTY and colours are not suppressed.
/// Useful for error messages that bypass the Writer pipeline.
pub fn hasTtyStderr() bool {
    if (hasNoColor()) return false;
    return std.posix.isatty(std.io.getStdErr().handle);
}

/// Returns true if the NO_COLOR env var is set (https://no-color.org) or if
/// TERM is "dumb".
fn hasNoColor() bool {
    if (std.process.hasEnvVar(std.heap.page_allocator, "NO_COLOR") catch false) return true;
    const term = std.process.getEnvVarOwned(std.heap.page_allocator, "TERM") catch return false;
    defer std.heap.page_allocator.free(term);
    return std.mem.eql(u8, term, "dumb");
}
