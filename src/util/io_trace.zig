//! Last missing file path for friendlier top-level CLI errors.
//!
//! Zig `error.FileNotFound` carries no path. Callers that open a known path
//! record it here so `main` can print which file was missing.

// ============================================================================
// IoTrace
// ============================================================================

/// Records the last path that failed with `FileNotFound` during this process.
pub const IoTrace = struct {
    var buf: [4096]u8 = undefined;
    var len: usize = 0;

    /// Copies `path` into internal storage (truncated if longer than the buffer).
    ///
    /// ## Parameters
    /// - `path` - Absolute or relative path that was missing.
    ///
    /// ## Returns
    /// Nothing.
    pub fn recordMissingPath(path: []const u8) void {
        const n = @min(path.len, buf.len);
        if (n == 0) return;
        @memcpy(buf[0..n], path[0..n]);
        len = n;
    }

    /// Returns the last recorded missing path slice and clears the record.
    ///
    /// ## Parameters
    /// - None.
    ///
    /// ## Returns
    /// Slice into internal storage, or `null` if nothing was recorded.
    pub fn takeMissingPath() ?[]const u8 {
        if (len == 0) return null;
        const out = buf[0..len];
        len = 0;
        return out;
    }

    /// Clears any recorded missing path without returning it.
    ///
    /// ## Parameters
    /// - None.
    ///
    /// ## Returns
    /// Nothing.
    pub fn clear() void {
        len = 0;
    }
};
