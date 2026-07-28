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
        is_verbose: *const fn (ptr: *anyopaque) bool,
    };

    /// Emits an event, delegating to the concrete implementation.
    pub fn emit(self: Writer, event: Event) void {
        self.vtable.emit(self.ptr, event);
    }

    /// Returns true when `--verbose` was passed on the CLI.
    pub fn isVerbose(self: Writer) bool {
        return self.vtable.is_verbose(self.ptr);
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
            impl.spinner_thread = std.Thread.spawn(
                .{},
                TuiWriter.spinnerThreadFn,
                .{impl},
            ) catch null;
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

/// Width of each progress bar in block characters.
const BAR_WIDTH = 24;

/// Renders a UTF-8 progress bar of BAR_WIDTH characters.
/// Filled positions use █ (U+2588), empty ones use ░ (U+2591).
fn makeBar(done: u32, total: u32) [BAR_WIDTH * 3]u8 {
    var buf: [BAR_WIDTH * 3]u8 = undefined;
    const filled: u32 = if (total == 0) 0 else @min(BAR_WIDTH, done * BAR_WIDTH / total);
    var i: u32 = 0;
    while (i < BAR_WIDTH) : (i += 1) {
        const src: *const [3]u8 = if (i < filled) "█" else "░";
        @memcpy(buf[i * 3 ..][0..3], src);
    }
    return buf;
}

const TuiWriter = struct {
    allocator: std.mem.Allocator,
    verbose: bool,
    stdout: std.fs.File,
    /// Whether ANSI colour codes should be emitted.
    colour: bool,
    /// Current spinner frame (advances on each progress event).
    spinner_frame: u8 = 0,
    /// Number of progress bar lines currently drawn on the terminal (0-2).
    /// Used to move the cursor back up before re-rendering.
    progress_lines: u2 = 0,
    /// Which install phase is active (0 = none, 1-4 = resolve/fetch/link/scripts).
    current_phase: u8 = 0,
    /// Items done in the current phase (used to compute the overall bar).
    phase_done: u32 = 0,
    /// Total items in the current phase.
    phase_total: u32 = 0,
    /// Stored label/colour/suffix for spinner-only redraws from background thread.
    cur_label: [16]u8 = [_]u8{0} ** 16,
    cur_label_len: u8 = 0,
    cur_colour: [16]u8 = [_]u8{0} ** 16,
    cur_colour_len: u8 = 0,
    cur_suffix: [128]u8 = [_]u8{0} ** 128,
    cur_suffix_len: u8 = 0,
    /// Protects all terminal writes; held by both the main thread and the
    /// background spinner thread.
    mutex: std.Thread.Mutex = .{},
    /// Signals the spinner thread to stop.
    spinner_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Background thread that animates the spinner at ~12 fps.
    spinner_thread: ?std.Thread = null,

    const vtable = Writer.VTable{
        .emit = emit,
        .flush = flush,
        .deinit = deinitFn,
        .is_verbose = isVerboseFn,
    };

    fn init(allocator: std.mem.Allocator, verbose: bool) TuiWriter {
        return .{
            .allocator = allocator,
            .verbose = verbose,
            .stdout = std.io.getStdOut(),
            .colour = !hasNoColor(),
        };
    }

    /// Background thread entry point.  Advances the spinner every ~80 ms
    /// regardless of whether a progress event arrives from the main thread.
    fn spinnerThreadFn(self: *TuiWriter) void {
        while (!self.spinner_stop.load(.acquire)) {
            std.time.sleep(80 * std.time.ns_per_ms);
            self.mutex.lock();
            self.redrawSpinnerOnly();
            self.mutex.unlock();
        }
    }

    /// Redraws the progress area advancing only the spinner frame.
    /// Must be called with `mutex` held.
    fn redrawSpinnerOnly(self: *TuiWriter) void {
        if (self.current_phase == 0 or self.progress_lines == 0) return;
        self.drawProgress(
            self.current_phase,
            self.cur_label[0..self.cur_label_len],
            self.cur_colour[0..self.cur_colour_len],
            self.phase_done,
            self.phase_total,
            self.cur_suffix[0..self.cur_suffix_len],
        );
    }

    /// Clears the progress area and moves the cursor to a clean line so that
    /// permanent output (info, done, …) can be printed immediately after.
    ///
    /// **Key invariant**: when `progress_lines >= 2`, line 2 was written
    /// WITHOUT a trailing `\n`, so the cursor is still somewhere on that line.
    /// `\r` brings it to column 0, `\x1b[1A` moves up to line 1, and
    /// `\x1b[0J` erases everything to end-of-screen - all without causing
    /// the terminal to scroll.
    fn clearProgress(self: *TuiWriter) void {
        if (self.progress_lines == 0) return;
        const w = self.stdout.writer();
        if (self.colour) {
            if (self.progress_lines >= 2) {
                // Cursor is on line 2 (no trailing \n). Go to col 0, up 1
                // line, then clear to end-of-screen.
                w.writeAll("\r\x1b[1A\x1b[0J") catch {};
            } else {
                // Single progress line written with \r (no \n).
                w.writeAll("\r\x1b[0K") catch {};
            }
        } else {
            w.writeByte('\n') catch {};
        }
        self.progress_lines = 0;
    }

    /// Renders (or re-renders) the two-line progress display:
    ///
    ///   ⠦  <label>   ████████████░░░░░░░░░░░░  <done>/<total>  [<suffix>]
    ///      overall   ████████░░░░░░░░░░░░░░░░  <pct>%  [<phase>/4]
    ///
    /// **Critical**: line 2 is written WITHOUT a trailing `\n` so the cursor
    /// stays on that line. This prevents the terminal from scrolling, which
    /// would push the lines into scrollback where `CSI A` can't reach them.
    /// Redraws use `\r\x1b[1A\x1b[0J` (col 0 → up 1 → clear-to-end), which
    /// is stable regardless of terminal height or scroll position.
    fn drawProgress(
        self: *TuiWriter,
        phase: u8,
        label: []const u8,
        colour_code: []const u8,
        done: u32,
        total: u32,
        suffix: []const u8,
    ) void {
        self.current_phase = phase;
        self.phase_done = done;
        self.phase_total = total;
        // Keep a copy so the background spinner thread can redraw without
        // needing the original (stack-allocated) strings.
        // Guard against aliasing: when called from redrawSpinnerOnly the
        // source slices point into these same fields - skip the copy then.
        const ll = @min(label.len, self.cur_label.len);
        if (@intFromPtr(label.ptr) != @intFromPtr(&self.cur_label[0])) {
            @memcpy(self.cur_label[0..ll], label[0..ll]);
            self.cur_label_len = @intCast(ll);
        }
        const cl = @min(colour_code.len, self.cur_colour.len);
        if (@intFromPtr(colour_code.ptr) != @intFromPtr(&self.cur_colour[0])) {
            @memcpy(self.cur_colour[0..cl], colour_code[0..cl]);
            self.cur_colour_len = @intCast(cl);
        }
        const sl = @min(suffix.len, self.cur_suffix.len);
        if (@intFromPtr(suffix.ptr) != @intFromPtr(&self.cur_suffix[0])) {
            @memcpy(self.cur_suffix[0..sl], suffix[0..sl]);
            self.cur_suffix_len = @intCast(sl);
        }

        const w = self.stdout.writer();

        if (!self.colour) {
            w.print("\r{s} {d}/{d}", .{ label, done, total }) catch {};
            self.progress_lines = 1;
            return;
        }

        // Return cursor to the start of the progress area without scrolling.
        if (self.progress_lines >= 2) {
            // Cursor is on line 2 (no trailing \n was written there).
            w.writeAll("\r\x1b[1A\x1b[0J") catch {};
        } else if (self.progress_lines == 1) {
            w.writeAll("\r\x1b[0J") catch {};
        }
        // progress_lines == 0: cursor is already at the right position.

        const frame = SPINNER[self.spinner_frame % SPINNER.len];
        self.spinner_frame +%= 1;

        const phase_bar = makeBar(done, total);

        // Overall percentage: each phase contributes 25 points.
        const overall_pct: u32 = blk: {
            if (phase == 0) break :blk 0;
            const within: u32 = if (total == 0) 0 else done * 25 / total;
            break :blk (@as(u32, phase) - 1) * 25 + within;
        };
        const overall_bar = makeBar(overall_pct, 100);

        // ── Line 1: ends with \n to advance to line 2 ────────────────────────
        w.print("{s}{s}\x1b[0m  {s}  {s}  \x1b[1m{d}/{d}\x1b[0m", .{
            colour_code, frame, label, phase_bar[0..], done, total,
        }) catch {};
        if (suffix.len > 0) {
            w.print("  \x1b[2m{s}\x1b[0m", .{suffix}) catch {};
        }
        w.writeByte('\n') catch {};

        // ── Line 2: NO trailing \n - cursor stays here, no scroll ─────────────
        w.print("    overall   {s}  \x1b[2m{d}%  [{d}/4]\x1b[0m", .{
            overall_bar[0..], overall_pct, phase,
        }) catch {};

        self.progress_lines = 2;
    }

    fn emit(ptr: *anyopaque, event: Event) void {
        const self: *TuiWriter = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();
        const w = self.stdout.writer();
        switch (event) {
            .resolve_progress => |p| {
                // Truncate the package name so the full progress line fits within
                // the terminal width without wrapping. Wrapping breaks ANSI cursor
                // control (\x1b[1A only moves up 1 terminal row, not 1 logical
                // line) causing visual corruption on redraw.
                //
                // Fixed-width parts: spinner(1) + "  "(2) + label(9) + "  "(2)
                //   + bar(24) + "  "(2) + count("XXXX/XXXX" max=9) + "  "(2) = 51
                // We cap the suffix at (terminal_width - 53) to leave a 2-char margin.
                const tw = terminalWidth();
                const max_suffix: usize = if (tw > 53) tw - 53 else 0;
                const raw = p.name;
                const name = if (raw.len > max_suffix) raw[0..max_suffix] else raw;
                self.drawProgress(1, "resolving", "\x1b[36m", p.resolved, p.total, name);
            },
            .fetch_progress => |p| {
                var suffix_buf: [24]u8 = undefined;
                const suffix: []const u8 = if (p.bytes_per_sec > 0) blk: {
                    const mbps = @as(f64, @floatFromInt(p.bytes_per_sec)) / (1024.0 * 1024.0);
                    break :blk std.fmt.bufPrint(&suffix_buf, "{d:.1} MB/s", .{mbps}) catch "";
                } else "";
                self.drawProgress(2, "fetching ", "\x1b[32m", p.fetched, p.total, suffix);
            },
            .link_progress => |p| {
                self.drawProgress(3, "linking  ", "\x1b[35m", p.linked, p.total, "");
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
                if (!self.verbose) return;
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
        self.mutex.lock();
        self.clearProgress();
        self.stdout.sync() catch {};
        self.mutex.unlock();
    }

    fn deinitFn(ptr: *anyopaque) void {
        const self: *TuiWriter = @ptrCast(@alignCast(ptr));
        // Signal and join the spinner thread first so it can no longer touch
        // the terminal after we start tearing down.
        self.spinner_stop.store(true, .release);
        if (self.spinner_thread) |t| t.join();
        self.mutex.lock();
        self.clearProgress();
        self.mutex.unlock();
        self.allocator.destroy(self);
    }

    fn isVerboseFn(ptr: *anyopaque) bool {
        const self: *TuiWriter = @ptrCast(@alignCast(ptr));
        return self.verbose;
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
        .is_verbose = isVerboseFn,
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
            .script_start => |s| {
                if (self.verbose) w.print("[script] {s}: {s}\n", .{ s.name, s.script }) catch {};
            },
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

    fn isVerboseFn(ptr: *anyopaque) bool {
        const self: *TextWriter = @ptrCast(@alignCast(ptr));
        return self.verbose;
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
        .is_verbose = isVerboseFn,
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
            .script_start => |s| {
                if (self.verbose) w.print(
                    "{{\"type\":\"script_start\",\"name\":{s},\"script\":{s}}}\n",
                    .{ jsonStr(s.name), jsonStr(s.script) },
                ) catch {};
            },
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

    fn isVerboseFn(ptr: *anyopaque) bool {
        const self: *JsonWriter = @ptrCast(@alignCast(ptr));
        return self.verbose;
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

/// Returns the terminal width in columns, or 80 as a safe fallback.
///
/// Tries TIOCGWINSZ ioctl first (POSIX), then the COLUMNS env var, then 80.
fn terminalWidth() usize {
    if (@import("builtin").os.tag != .windows) {
        // SAFETY: `ioctl(TIOCGWINSZ)` fully initializes `ws` when it returns 0.
        var ws: std.posix.winsize = undefined;
        const rc = std.os.linux.ioctl(std.io.getStdOut().handle, std.os.linux.T.IOCGWINSZ, @intFromPtr(&ws));
        if (rc == 0 and ws.col > 0) return ws.col;
    }
    const cols_str = std.process.getEnvVarOwned(std.heap.page_allocator, "COLUMNS") catch return 80;
    defer std.heap.page_allocator.free(cols_str);
    return std.fmt.parseInt(usize, std.mem.trim(u8, cols_str, " "), 10) catch 80;
}

/// Returns true if the NO_COLOR env var is set (https://no-color.org) or if
/// TERM is "dumb".
fn hasNoColor() bool {
    if (std.process.hasEnvVar(std.heap.page_allocator, "NO_COLOR") catch false) return true;
    const term = std.process.getEnvVarOwned(std.heap.page_allocator, "TERM") catch return false;
    defer std.heap.page_allocator.free(term);
    return std.mem.eql(u8, term, "dumb");
}
