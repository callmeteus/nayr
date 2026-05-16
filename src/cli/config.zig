//! `nayr config` — Interactive global configuration editor
//!
//! Reads and writes `~/.nayrrc` using a clack-style interactive TUI.
//!
//! Non-interactive subcommands for scripting:
//!   nayr config list
//!   nayr config set  <key> <value>
//!   nayr config add  <key> <value>
//!   nayr config remove <key> <value>
//!   nayr config unset <key>

const std = @import("std");
const platform = @import("../util/platform.zig");
const output = @import("../util/output.zig");
const prompts = @import("../util/prompts.zig");
const config_types = @import("../config/types.zig");
const nayrrc_parser = @import("../config/nayrrc.zig");
const Config = config_types.Config;

// ============================================================================
// Entry point
// ============================================================================

pub fn run(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    _: []const u8,
    _: *const Config,
    _: output.Writer,
) !void {
    const home = platform.getHomeDir(allocator) catch {
        std.io.getStdErr().writer().print("error  cannot determine home directory\n", .{}) catch {};
        return error.HomeNotFound;
    };
    defer allocator.free(home);

    const global_path = try std.fs.path.join(allocator, &.{ home, ".nayrrc" });
    defer allocator.free(global_path);

    // Non-interactive subcommands.
    if (args.len >= 1) {
        if (std.mem.eql(u8, args[0], "list")) {
            var cfg = try loadGlobalConfig(allocator, global_path);
            defer cfg.deinit();
            return printConfig(&cfg, global_path);
        }
        if (std.mem.eql(u8, args[0], "set") and args.len >= 3) {
            return cliSet(allocator, global_path, args[1], args[2]);
        }
        if (std.mem.eql(u8, args[0], "add") and args.len >= 3) {
            return cliAdd(allocator, global_path, args[1], args[2]);
        }
        if ((std.mem.eql(u8, args[0], "remove") or std.mem.eql(u8, args[0], "rm")) and args.len >= 3) {
            return cliRemove(allocator, global_path, args[1], args[2]);
        }
        if (std.mem.eql(u8, args[0], "unset") and args.len >= 2) {
            return cliUnset(allocator, global_path, args[1]);
        }
    }

    try interactiveMenu(allocator, global_path);
}

// ============================================================================
// Interactive TUI
// ============================================================================

fn interactiveMenu(allocator: std.mem.Allocator, global_path: []const u8) !void {
    const w = std.io.getStdOut().writer();
    const colour = platform.isStdoutTty();
    const theme = prompts.Theme{ .colour = colour };

    // Enable raw mode for single-keypress interaction.
    const raw = prompts.enterRawMode() catch {
        // Fall back to line-based mode if not a TTY.
        return interactiveLoopFallback(allocator, global_path);
    };
    defer prompts.leaveRawMode(raw);

    // Header.
    w.print("\n", .{}) catch {};
    theme.intro(w, "nayr config");
    if (colour) {
        w.print("\x1b[2m│\x1b[0m  {s}\n", .{global_path}) catch {};
    } else {
        w.print("│  {s}\n", .{global_path}) catch {};
    }
    theme.spacer(w);

    // Main loop.
    while (true) {
        var cfg = try loadGlobalConfig(allocator, global_path);
        defer cfg.deinit();

        // Top-level section picker.
        var links_label_buf: [64]u8 = undefined;
        const links_label = std.fmt.bufPrint(&links_label_buf, "Links  ({d} pattern{s})", .{ cfg.auto_link_patterns.len, if (cfg.auto_link_patterns.len == 1) "" else "s" }) catch "Links";

        var sec_label_buf: [64]u8 = undefined;
        const sec_label = buildSecurityLabel(&sec_label_buf, &cfg);

        const section_items = [_][]const u8{
            links_label,
            sec_label,
            "Git  (hash pinning)",
            "Registries  (private)",
            "← Exit",
        };

        const result = try prompts.select(w, theme, "What would you like to configure?", section_items, 0);
        switch (result) {
            .cancelled => break,
            .selected => |idx| {
                switch (idx) {
                    0 => try menuLinks(allocator, &cfg, global_path, w, theme),
                    1 => try menuSecurity(allocator, &cfg, global_path, w, theme),
                    2 => try menuGit(allocator, &cfg, global_path, w, theme),
                    3 => try menuRegistries(&cfg, global_path, w, theme),
                    4 => break,
                    else => break,
                }
            },
        }
        theme.spacer(w);
    }

    theme.spacer(w);
    theme.outro(w, "Settings saved to ~/.nayrrc");
    w.print("\n", .{}) catch {};
}

fn buildSecurityLabel(buf: []u8, cfg: *const Config) []const u8 {
    const secs = cfg.minimum_package_age_seconds;
    var age_buf: [16]u8 = undefined;
    const age: []const u8 = blk: {
        if (secs == 0) break :blk "off";

        if (secs % 86400 == 0) {
            break :blk std.fmt.bufPrint(&age_buf, "{d}d", .{secs / 86400}) catch "?";
        }

        if (secs % 3600 == 0) {
            break :blk std.fmt.bufPrint(&age_buf, "{d}h", .{secs / 3600}) catch "?";
        }

        break :blk std.fmt.bufPrint(&age_buf, "{d}s", .{secs}) catch "?";
    };
    const n_reg = if (cfg.allowed_registries) |r| r.len else 0;
    const n_git = if (cfg.allowed_git_hosts) |h| h.len else 0;
    return std.fmt.bufPrint(buf, "Security  (age={s}, reg={d}, git={d})", .{ age, n_reg, n_git }) catch "Security";
}

// ============================================================================
// Sub-menus
// ============================================================================

fn menuLinks(
    allocator: std.mem.Allocator,
    cfg: *Config,
    global_path: []const u8,
    w: anytype,
    theme: prompts.Theme,
) !void {
    while (true) {
        // Build item list: existing patterns + "Adicionar" + "← Voltar".
        var items_list = std.ArrayList([]const u8).init(allocator);
        defer items_list.deinit();
        for (cfg.auto_link_patterns) |p| try items_list.append(p);
        const add_idx = items_list.items.len;
        try items_list.append("＋  Add pattern");
        const back_idx = items_list.items.len;
        try items_list.append("← Back");

        const result = try prompts.select(w, theme, "Links  (auto-link patterns)", items_list.items, 0);
        switch (result) {
            .cancelled => return,
            .selected => |idx| {
                if (idx == back_idx) {
                    return;
                }
                if (idx == add_idx) {
                    const res = try prompts.textInput(allocator, w, theme, "Link pattern (e.g. @myorg/*)", "@");
                    switch (res) {
                        .cancelled => continue,
                        .value => |val| {
                            defer allocator.free(val);
                            // Skip if already present.
                            var found = false;

                            for (cfg.auto_link_patterns) |p| {
                                if (std.mem.eql(u8, p, val)) {
                                    found = true;
                                    break;
                                }
                            }

                            if (!found) {
                                try appendToSlice(allocator, &cfg.auto_link_patterns, val);
                                try writeGlobalNayrrc(allocator, cfg, global_path);
                            }
                            // Reload cfg for next iteration.
                            return menuLinks(allocator, cfg, global_path, w, theme);
                        },
                    }
                } else {
                    // Remove selected pattern.
                    const removed = cfg.auto_link_patterns[idx];
                    const old = cfg.auto_link_patterns;
                    var new_list = try std.ArrayList([]const u8).initCapacity(allocator, old.len - 1);

                    for (old, 0..) |p, i| {
                        if (i != idx) {
                            try new_list.append(p);
                        } else {
                            allocator.free(p);
                        }
                    }

                    allocator.free(old);
                    cfg.auto_link_patterns = try new_list.toOwnedSlice();
                    try writeGlobalNayrrc(allocator, cfg, global_path);
                    _ = removed;
                }
            },
        }
    }
}

fn menuSecurity(
    allocator: std.mem.Allocator,
    cfg: *Config,
    global_path: []const u8,
    w: anytype,
    theme: prompts.Theme,
) !void {
    while (true) {
        var age_buf: [32]u8 = undefined;
        const age_str: []const u8 = blk: {
            const s = cfg.minimum_package_age_seconds;
            if (s == 0) break :blk "disabled";
            if (s % 86400 == 0) break :blk std.fmt.bufPrint(&age_buf, "{d}d", .{s / 86400}) catch "?";
            if (s % 3600 == 0) break :blk std.fmt.bufPrint(&age_buf, "{d}h", .{s / 3600}) catch "?";
            if (s % 60 == 0) break :blk std.fmt.bufPrint(&age_buf, "{d}m", .{s / 60}) catch "?";
            break :blk std.fmt.bufPrint(&age_buf, "{d}s", .{s}) catch "?";
        };

        var min_age_label_buf: [48]u8 = undefined;
        const min_age_label = std.fmt.bufPrint(&min_age_label_buf, "Min package age  (current: {s})", .{age_str}) catch "Min package age";

        // allowed-registries items.
        var items = std.ArrayList([]const u8).init(allocator);
        defer items.deinit();
        try items.append(min_age_label);

        const reg_add_label = "＋  Add allowed registry";
        const git_add_label = "＋  Add allowed git host";

        if (cfg.allowed_registries) |regs| {
            for (regs) |r| {
                var buf: [128]u8 = undefined;
                const label = std.fmt.bufPrint(&buf, "✕  registry: {s}", .{r}) catch r;
                try items.append(try allocator.dupe(u8, label));
            }
        } else {
            try items.append("  allowed-registries: (all allowed)");
        }

        const reg_add_item = items.items.len;
        try items.append(reg_add_label);

        if (cfg.allowed_git_hosts) |hosts| {
            for (hosts) |h| {
                var buf: [128]u8 = undefined;
                const label = std.fmt.bufPrint(&buf, "✕  git: {s}", .{h}) catch h;
                try items.append(try allocator.dupe(u8, label));
            }
        } else {
            try items.append("  allowed-git-hosts: (all allowed)");
        }

        const git_add_item = items.items.len;
        try items.append(git_add_label);

        const back_idx = items.items.len;
        try items.append("← Back");

        const result = try prompts.select(w, theme, "Security", items.items, 0);

        // Free dynamically allocated labels.
        defer {
            for (items.items) |item| {
                if (item.ptr != min_age_label.ptr and
                    item.ptr != reg_add_label.ptr and
                    item.ptr != git_add_label.ptr and
                    !std.mem.startsWith(u8, item, "  allowed-") and
                    !std.mem.eql(u8, item, "← Back"))
                {
                    // Only free items we allocated (✕ prefixed ones).
                    if (std.mem.startsWith(u8, item, "✕")) allocator.free(item);
                }
            }
        }

        switch (result) {
            .cancelled => return,
            .selected => |idx| {
                if (idx == back_idx) {
                    return;
                }
                if (idx == 0) {
                    // Edit minimum-package-age.
                    const res = try prompts.textInput(allocator, w, theme, "Min package age (0=off, e.g. 24h, 7d, 30m)", age_str);
                    switch (res) {
                        .cancelled => continue,
                        .value => |val| {
                            defer allocator.free(val);
                            cfg.minimum_package_age_seconds = nayrrc_parser.parseAgeString(val);
                            try writeGlobalNayrrc(allocator, cfg, global_path);
                        },
                    }
                } else {
                    if (idx == reg_add_item) {
                        const res = try prompts.textInput(allocator, w, theme, "Allowed registry pattern (e.g. registry.npmjs.org, npm.arpa*)", "");
                        switch (res) {
                            .cancelled => continue,
                            .value => |val| {
                                defer allocator.free(val);
                                if (val.len > 0) {
                                    try appendToAllowedRegistries(allocator, cfg, val);
                                    try writeGlobalNayrrc(allocator, cfg, global_path);
                                }
                            },
                        }
                    } else {
                        if (idx == git_add_item) {
                            const res = try prompts.textInput(allocator, w, theme, "Allowed git host pattern (e.g. github.com/myorg/*, gitlab.com)", "");
                            switch (res) {
                                .cancelled => continue,
                                .value => |val| {
                                    defer allocator.free(val);
                                    if (val.len > 0) {
                                        try appendToAllowedGitHosts(allocator, cfg, val);
                                        try writeGlobalNayrrc(allocator, cfg, global_path);
                                    }
                                },
                            }
                        } else {
                            // Check if it's a removable registry or git item.
                            const item_text = items.items[idx];
                            if (std.mem.startsWith(u8, item_text, "✕  registry: ")) {
                                const val = item_text["✕  registry: ".len..];
                                if (cfg.allowed_registries) |regs| {
                                    var new_list = try std.ArrayList([]const u8).initCapacity(allocator, regs.len);
                                    for (regs) |r| {
                                        if (!std.mem.eql(u8, r, val)) try new_list.append(r) else allocator.free(r);
                                    }
                                    allocator.free(regs);
                                    const owned = try new_list.toOwnedSlice();
                                    cfg.allowed_registries = if (owned.len > 0) owned else null;
                                    try writeGlobalNayrrc(allocator, cfg, global_path);
                                }
                            } else {
                                if (std.mem.startsWith(u8, item_text, "✕  git: ")) {
                                    const val = item_text["✕  git: ".len..];
                                    if (cfg.allowed_git_hosts) |hosts| {
                                        var new_list = try std.ArrayList([]const u8).initCapacity(allocator, hosts.len);
                                        for (hosts) |h| {
                                            if (!std.mem.eql(u8, h, val)) try new_list.append(h) else allocator.free(h);
                                        }
                                        allocator.free(hosts);
                                        const owned = try new_list.toOwnedSlice();
                                        cfg.allowed_git_hosts = if (owned.len > 0) owned else null;
                                        try writeGlobalNayrrc(allocator, cfg, global_path);
                                    }
                                }
                            }
                        }
                    }
                }
            },
        }
    }
}

fn menuGit(
    allocator: std.mem.Allocator,
    cfg: *Config,
    global_path: []const u8,
    w: anytype,
    theme: prompts.Theme,
) !void {
    var pin_label_buf: [48]u8 = undefined;
    const pin_label = std.fmt.bufPrint(&pin_label_buf, "pin-hash  (current: {s})", .{if (cfg.git_pin_hash) "on" else "off"}) catch "pin-hash";

    var items = std.ArrayList([]const u8).init(allocator);
    defer items.deinit();
    try items.append(pin_label);
    for (cfg.git_no_pin_orgs) |o| {
        var buf: [96]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "✕  no-pin-org: {s}", .{o}) catch o;
        try items.append(try allocator.dupe(u8, label));
    }
    const org_add = items.items.len;
    try items.append("＋  Add no-pin-org");
    for (cfg.git_no_pin_repos) |r| {
        var buf: [96]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "✕  no-pin-repo: {s}", .{r}) catch r;
        try items.append(try allocator.dupe(u8, label));
    }
    const repo_add = items.items.len;
    try items.append("＋  Add no-pin-repo");
    const back_idx = items.items.len;
    try items.append("← Back");

    defer {
        for (items.items) |item| {
            if (std.mem.startsWith(u8, item, "✕")) allocator.free(item);
        }
    }

    const result = try prompts.select(w, theme, "Git  (hash pinning)", items.items, 0);
    switch (result) {
        .cancelled => return,
        .selected => |idx| {
            if (idx == back_idx) {
                return;
            }
            if (idx == 0) {
                // Toggle pin-hash.
                const res = try prompts.confirm(w, theme, "pin-hash", cfg.git_pin_hash);
                switch (res) {
                    .cancelled => return,
                    .value => |v| {
                        cfg.git_pin_hash = v;
                        try writeGlobalNayrrc(allocator, cfg, global_path);
                    },
                }
            } else {
                if (idx == org_add) {
                    const res = try prompts.textInput(allocator, w, theme, "Org to skip pinning (e.g. myorg)", "");
                    switch (res) {
                        .cancelled => return,
                        .value => |val| {
                            defer allocator.free(val);
                            if (val.len > 0) {
                                try appendToSlice(allocator, &cfg.git_no_pin_orgs, val);
                                try writeGlobalNayrrc(allocator, cfg, global_path);
                            }
                        },
                    }
                } else {
                    if (idx == repo_add) {
                        const res = try prompts.textInput(allocator, w, theme, "Repo to skip pinning (e.g. myorg/repo)", "");
                        switch (res) {
                            .cancelled => return,
                            .value => |val| {
                                defer allocator.free(val);
                                if (val.len > 0) {
                                    try appendToSlice(allocator, &cfg.git_no_pin_repos, val);
                                    try writeGlobalNayrrc(allocator, cfg, global_path);
                                }
                            },
                        }
                    } else {
                        // Remove an item.
                        const item_text = items.items[idx];
                        if (std.mem.startsWith(u8, item_text, "✕  no-pin-org: ")) {
                            const val = item_text["✕  no-pin-org: ".len..];
                            try removeFromSliceByValue(allocator, &cfg.git_no_pin_orgs, val);
                            try writeGlobalNayrrc(allocator, cfg, global_path);
                        } else {
                            if (std.mem.startsWith(u8, item_text, "✕  no-pin-repo: ")) {
                                const val = item_text["✕  no-pin-repo: ".len..];
                                try removeFromSliceByValue(allocator, &cfg.git_no_pin_repos, val);
                                try writeGlobalNayrrc(allocator, cfg, global_path);
                            }
                        }
                    }
                }
            }
        },
    }
}

fn menuRegistries(
    cfg: *const Config,
    global_path: []const u8,
    w: anytype,
    theme: prompts.Theme,
) !void {
    if (cfg.private_registries.count() == 0) {
        theme.note(w, "No private registries configured.");
        theme.note(w, "Edit ~/.nayrrc directly to add one:");
        theme.note(w, "");
        theme.note(w, "  [registry.myreg]");
        theme.note(w, "  url = \"http://npm.arpa\"");
        theme.note(w, "  type = \"verdaccio\"");
        theme.note(w, "  scopes = [\"@myorg\"]");
    } else {
        var it = cfg.private_registries.iterator();
        while (it.next()) |kv| {
            const reg = kv.value_ptr.*;
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "[{s}]  {s}  ({s})", .{
                kv.key_ptr.*,                                                reg.url,
                if (reg.registry_type == .verdaccio) "verdaccio" else "npm",
            }) catch kv.key_ptr.*;
            theme.note(w, msg);
        }
        theme.note(w, "");
        theme.note(w, "Edit ~/.nayrrc to modify registries.");
    }
    _ = global_path;
    theme.spacer(w);
    _ = try prompts.select(w, theme, "Back?", &[_][]const u8{"← Back"}, 0);
}

// ============================================================================
// Fallback for non-TTY (line-based)
// ============================================================================

fn interactiveLoopFallback(allocator: std.mem.Allocator, global_path: []const u8) !void {
    var cfg = try loadGlobalConfig(allocator, global_path);
    defer cfg.deinit();
    printConfig(&cfg, global_path);
    std.io.getStdOut().writer().print("\nUse subcommands to edit:\n" ++
        "  nayr config set security.minimum-package-age <value>\n" ++
        "  nayr config add links <pattern>\n" ++
        "  nayr config add security.allowed-git-hosts <pattern>\n" ++
        "  nayr config list\n", .{}) catch {};
}

// ============================================================================
// CLI subcommands (non-interactive)
// ============================================================================

fn cliSet(allocator: std.mem.Allocator, global_path: []const u8, key: []const u8, value: []const u8) !void {
    var cfg = try loadGlobalConfig(allocator, global_path);
    defer cfg.deinit();
    if (std.mem.eql(u8, key, "security.minimum-package-age")) {
        cfg.minimum_package_age_seconds = nayrrc_parser.parseAgeString(value);
    } else if (std.mem.eql(u8, key, "git.pin-hash")) {
        cfg.git_pin_hash = std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "on");
    } else {
        std.io.getStdErr().writer().print("error  unknown key: {s}\n", .{key}) catch {};
        return error.UnknownConfigKey;
    }
    try writeGlobalNayrrc(allocator, &cfg, global_path);
    std.io.getStdOut().writer().print("set {s} = {s}\n", .{ key, value }) catch {};
}

fn cliAdd(allocator: std.mem.Allocator, global_path: []const u8, key: []const u8, value: []const u8) !void {
    var cfg = try loadGlobalConfig(allocator, global_path);
    defer cfg.deinit();
    if (std.mem.eql(u8, key, "links") or std.mem.startsWith(u8, key, "links.")) {
        try appendToSlice(allocator, &cfg.auto_link_patterns, value);
    } else if (std.mem.eql(u8, key, "security.allowed-registries")) {
        try appendToAllowedRegistries(allocator, &cfg, value);
    } else if (std.mem.eql(u8, key, "security.allowed-git-hosts")) {
        try appendToAllowedGitHosts(allocator, &cfg, value);
    } else if (std.mem.eql(u8, key, "git.no-pin-orgs")) {
        try appendToSlice(allocator, &cfg.git_no_pin_orgs, value);
    } else if (std.mem.eql(u8, key, "git.no-pin-repos")) {
        try appendToSlice(allocator, &cfg.git_no_pin_repos, value);
    } else {
        std.io.getStdErr().writer().print("error  unknown key: {s}\n", .{key}) catch {};
        return error.UnknownConfigKey;
    }
    try writeGlobalNayrrc(allocator, &cfg, global_path);
    std.io.getStdOut().writer().print("added {s} to {s}\n", .{ value, key }) catch {};
}

fn cliRemove(allocator: std.mem.Allocator, global_path: []const u8, key: []const u8, value: []const u8) !void {
    var cfg = try loadGlobalConfig(allocator, global_path);
    defer cfg.deinit();
    if (std.mem.eql(u8, key, "links") or std.mem.startsWith(u8, key, "links.")) {
        try removeFromSliceByValue(allocator, &cfg.auto_link_patterns, value);
    } else if (std.mem.eql(u8, key, "security.allowed-registries")) {
        if (cfg.allowed_registries) |regs| {
            var list = try std.ArrayList([]const u8).initCapacity(allocator, regs.len);
            for (regs) |r| {
                if (!std.mem.eql(u8, r, value)) try list.append(r) else allocator.free(r);
            }
            allocator.free(regs);
            const owned = try list.toOwnedSlice();
            cfg.allowed_registries = if (owned.len > 0) owned else null;
        }
    } else if (std.mem.eql(u8, key, "security.allowed-git-hosts")) {
        if (cfg.allowed_git_hosts) |hosts| {
            var list = try std.ArrayList([]const u8).initCapacity(allocator, hosts.len);
            for (hosts) |h| {
                if (!std.mem.eql(u8, h, value)) try list.append(h) else allocator.free(h);
            }
            allocator.free(hosts);
            const owned = try list.toOwnedSlice();
            cfg.allowed_git_hosts = if (owned.len > 0) owned else null;
        }
    } else {
        std.io.getStdErr().writer().print("error  unknown key: {s}\n", .{key}) catch {};
        return error.UnknownConfigKey;
    }
    try writeGlobalNayrrc(allocator, &cfg, global_path);
    std.io.getStdOut().writer().print("removed {s} from {s}\n", .{ value, key }) catch {};
}

fn cliUnset(allocator: std.mem.Allocator, global_path: []const u8, key: []const u8) !void {
    var cfg = try loadGlobalConfig(allocator, global_path);
    defer cfg.deinit();
    if (std.mem.eql(u8, key, "security.allowed-registries")) {
        if (cfg.allowed_registries) |ar| {
            for (ar) |s| allocator.free(s);
            allocator.free(ar);
        }
        cfg.allowed_registries = null;
    } else if (std.mem.eql(u8, key, "security.allowed-git-hosts")) {
        if (cfg.allowed_git_hosts) |ag| {
            for (ag) |s| allocator.free(s);
            allocator.free(ag);
        }
        cfg.allowed_git_hosts = null;
    } else if (std.mem.eql(u8, key, "security.minimum-package-age")) {
        cfg.minimum_package_age_seconds = 86400;
    } else {
        std.io.getStdErr().writer().print("error  unknown key: {s}\n", .{key}) catch {};
        return error.UnknownConfigKey;
    }
    try writeGlobalNayrrc(allocator, &cfg, global_path);
    std.io.getStdOut().writer().print("unset: {s}\n", .{key}) catch {};
}

fn printConfig(cfg: *const Config, global_path: []const u8) void {
    const w = std.io.getStdOut().writer();
    w.print("# {s}\n\n[links]\n", .{global_path}) catch {};
    for (cfg.auto_link_patterns) |p| w.print("{s} = true\n", .{p}) catch {};
    w.print("\n[security]\n", .{}) catch {};
    const secs = cfg.minimum_package_age_seconds;
    if (secs % 86400 == 0) w.print("minimum-package-age = \"{d}d\"\n", .{secs / 86400}) catch {} else if (secs % 3600 == 0) w.print("minimum-package-age = \"{d}h\"\n", .{secs / 3600}) catch {} else w.print("minimum-package-age = \"{d}\"\n", .{secs}) catch {};
    if (cfg.allowed_registries) |regs| {
        w.print("allowed-registries = [", .{}) catch {};
        for (regs, 0..) |r, i| {
            if (i > 0) w.print(", ", .{}) catch {};
            w.print("\"{s}\"", .{r}) catch {};
        }
        w.print("]\n", .{}) catch {};
    }
    if (cfg.allowed_git_hosts) |hosts| {
        w.print("allowed-git-hosts = [", .{}) catch {};
        for (hosts, 0..) |h, i| {
            if (i > 0) w.print(", ", .{}) catch {};
            w.print("\"{s}\"", .{h}) catch {};
        }
        w.print("]\n", .{}) catch {};
    }
    w.print("\n[git]\npin-hash = {s}\n", .{if (cfg.git_pin_hash) "true" else "false"}) catch {};
}

// ============================================================================
// .nayrrc serializer
// ============================================================================

fn writeGlobalNayrrc(allocator: std.mem.Allocator, cfg: *const Config, path: []const u8) !void {
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    const w = buf.writer();

    if (cfg.auto_link_patterns.len > 0) {
        try w.print("[links]\n", .{});
        for (cfg.auto_link_patterns) |p| try w.print("{s} = true\n", .{p});
        try w.print("\n", .{});
    }

    try w.print("[security]\n", .{});
    const secs = cfg.minimum_package_age_seconds;
    if (secs == 0) try w.print("minimum-package-age = \"0\"\n", .{}) else if (secs % 86400 == 0) try w.print("minimum-package-age = \"{d}d\"\n", .{secs / 86400}) else if (secs % 3600 == 0) try w.print("minimum-package-age = \"{d}h\"\n", .{secs / 3600}) else if (secs % 60 == 0) try w.print("minimum-package-age = \"{d}m\"\n", .{secs / 60}) else try w.print("minimum-package-age = \"{d}\"\n", .{secs});
    if (cfg.allowed_registries) |regs| {
        try w.print("allowed-registries = [", .{});
        for (regs, 0..) |r, i| {
            if (i > 0) try w.print(", ", .{});
            try w.print("\"{s}\"", .{r});
        }
        try w.print("]\n", .{});
    }
    if (cfg.allowed_git_hosts) |hosts| {
        try w.print("allowed-git-hosts = [", .{});
        for (hosts, 0..) |h, i| {
            if (i > 0) try w.print(", ", .{});
            try w.print("\"{s}\"", .{h});
        }
        try w.print("]\n", .{});
    }
    try w.print("\n", .{});

    if (!cfg.git_pin_hash or cfg.git_no_pin_orgs.len > 0 or cfg.git_no_pin_repos.len > 0) {
        try w.print("[git]\npin-hash = {s}\n", .{if (cfg.git_pin_hash) "true" else "false"});
        if (cfg.git_no_pin_orgs.len > 0) {
            try w.print("no-pin-orgs = [", .{});
            for (cfg.git_no_pin_orgs, 0..) |o, i| {
                if (i > 0) try w.print(", ", .{});
                try w.print("\"{s}\"", .{o});
            }
            try w.print("]\n", .{});
        }
        if (cfg.git_no_pin_repos.len > 0) {
            try w.print("no-pin-repos = [", .{});
            for (cfg.git_no_pin_repos, 0..) |r, i| {
                if (i > 0) try w.print(", ", .{});
                try w.print("\"{s}\"", .{r});
            }
            try w.print("]\n", .{});
        }
        try w.print("\n", .{});
    }

    appendExistingRegistrySections(allocator, path, &buf) catch {};

    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(buf.items);
}

fn appendExistingRegistrySections(allocator: std.mem.Allocator, path: []const u8, out: *std.ArrayList(u8)) !void {
    const file = std.fs.openFileAbsolute(path, .{}) catch return;
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 128 * 1024);
    defer allocator.free(content);
    var lines = std.mem.splitScalar(u8, content, '\n');
    var in_registry = false;
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len > 0 and t[0] == '[') in_registry = std.mem.startsWith(u8, t[1..], "registry.");
        if (in_registry) {
            try out.appendSlice(line);
            try out.append('\n');
        }
    }
}

// ============================================================================
// Helpers
// ============================================================================

fn loadGlobalConfig(allocator: std.mem.Allocator, global_path: []const u8) !Config {
    var cfg = Config.init(allocator);
    try nayrrc_parser.parseFile(&cfg, global_path, true);
    return cfg;
}

fn appendToSlice(allocator: std.mem.Allocator, slice: *[]const []const u8, val: []const u8) !void {
    const old = slice.*;
    const new_slice = try allocator.alloc([]const u8, old.len + 1);
    @memcpy(new_slice[0..old.len], old);
    new_slice[old.len] = try allocator.dupe(u8, val);
    if (old.len > 0) allocator.free(old);
    slice.* = new_slice;
}

fn removeFromSliceByValue(allocator: std.mem.Allocator, slice: *[]const []const u8, val: []const u8) !void {
    const old = slice.*;
    var list = try std.ArrayList([]const u8).initCapacity(allocator, old.len);
    for (old) |s| {
        if (!std.mem.eql(u8, s, val)) try list.append(s) else allocator.free(s);
    }
    if (old.len > 0) allocator.free(old);
    slice.* = try list.toOwnedSlice();
}

fn appendToAllowedRegistries(allocator: std.mem.Allocator, cfg: *Config, val: []const u8) !void {
    const old = cfg.allowed_registries orelse &.{};
    const new_slice = try allocator.alloc([]const u8, old.len + 1);
    @memcpy(new_slice[0..old.len], old);
    new_slice[old.len] = try allocator.dupe(u8, val);
    if (cfg.allowed_registries != null) allocator.free(old);
    cfg.allowed_registries = new_slice;
}

fn appendToAllowedGitHosts(allocator: std.mem.Allocator, cfg: *Config, val: []const u8) !void {
    const old = cfg.allowed_git_hosts orelse &.{};
    const new_slice = try allocator.alloc([]const u8, old.len + 1);
    @memcpy(new_slice[0..old.len], old);
    new_slice[old.len] = try allocator.dupe(u8, val);
    if (cfg.allowed_git_hosts != null) allocator.free(old);
    cfg.allowed_git_hosts = new_slice;
}
