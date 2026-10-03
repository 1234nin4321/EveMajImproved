const std = @import("std");
const webui = @import("webui");
const config_mod = @import("config.zig");
const http_client = @import("http_client.zig");
const log = @import("log.zig");

const slog = log.scoped("eve_accounts");

var g_allocator: std.mem.Allocator = undefined;
var g_io: std.Io = undefined;

pub fn init(allocator: std.mem.Allocator, io: std.Io) void {
    g_allocator = allocator;
    g_io = io;
}

/// Account Config's own file, separate from global.settings.json since only config.exe reads or writes it.
pub const ACCOUNTS_FILE = "profiles/accounts.json";
const MAX_ACCOUNTS_FILE_SIZE: usize = 1024 * 1024;

const ESI_NAMES_URL = "https://esi.evetech.net/latest/universe/names/?datasource=tranquility";
/// ESI's documented per-request cap for /universe/names/.
const ESI_NAMES_BATCH = 1000;
/// ESI rejects a whole /universe/names/ batch if any one ID is unknown, so a failed batch is retried one ID at a time - capped so a long list of dead IDs can't stall the dialog.
const ESI_MAX_SINGLE_LOOKUPS = 100;

/// EVE writes core_user_<id>.dat and core_char_<id>.dat together when a character logs out, so a user file whose mtime lands this close to a character file's is taken as that character's account. Heuristic only - the UI presents it as a suggestion.
const MATCH_WINDOW_NS: u96 = 10 * std.time.ns_per_s;

/// On-disk shape of accounts.json. `userIds` are EVE's own account IDs (from core_user_<id>.dat), linked so scan suggestions can map onto a user-named account.
pub const AccountsFile = struct {
    version: u32 = 1,
    accounts: []const Account = &.{},
    characters: []const CharacterLink = &.{},

    pub const Account = struct {
        id: []const u8,
        name: []const u8,
        userIds: []const []const u8 = &.{},
    };

    pub const CharacterLink = struct {
        id: []const u8,
        name: ?[]const u8 = null,
        accountId: ?[]const u8 = null,
        lastSeen: ?i64 = null,
    };
};

const ScannedCharacter = struct {
    id: []const u8,
    name: ?[]const u8 = null,
    /// Unix seconds of the newest core_char_<id>.dat across all settings folders.
    lastSeen: i64,
    folders: []const []const u8,
    suggestedUserId: ?[]const u8 = null,
};

const ScannedUser = struct {
    id: []const u8,
    lastSeen: i64,
};

const ScanResponse = struct {
    eveRoot: ?[]const u8 = null,
    characters: []const ScannedCharacter = &.{},
    users: []const ScannedUser = &.{},
};

const SettingsFile = struct {
    id: []const u8,
    mtime: i96,
};

/// Per-character accumulator while walking settings folders; the newest sighting wins the suggestion.
const CharAccum = struct {
    mtime: i96,
    folders: std.ArrayList([]const u8),
    suggested_user: ?[]const u8,
};

/// Returns the numeric ID from `<prefix><digits>.dat`, or null for anything else (including EVE's `core_char__.dat` template file).
fn parseSettingsFileId(name: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    if (!std.mem.endsWith(u8, name, ".dat")) return null;
    const id = name[prefix.len .. name.len - ".dat".len];
    if (id.len == 0) return null;
    for (id) |c| {
        if (!std.ascii.isDigit(c)) return null;
    }
    return id;
}

/// The user file written closest in time to `char_mtime`, if within MATCH_WINDOW_NS.
fn nearestUser(users: []const SettingsFile, char_mtime: i96) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_delta: u96 = MATCH_WINDOW_NS + 1;
    for (users) |u| {
        const delta = @abs(u.mtime - char_mtime);
        if (delta < best_delta) {
            best_delta = delta;
            best = u.id;
        }
    }
    return best;
}

/// Walks %LOCALAPPDATA%\CCP\EVE\*\settings*\ for core_char_/core_user_ files. All strings are allocated from `arena`.
fn scanSettings(arena: std.mem.Allocator, io: std.Io, environ_map: *const std.process.Environ.Map) !ScanResponse {
    const local_app_data = environ_map.get("LOCALAPPDATA") orelse {
        slog.warn("LOCALAPPDATA environment variable not found", .{});
        return .{};
    };

    const eve_root = try std.fs.path.join(arena, &[_][]const u8{ local_app_data, "CCP", "EVE" });

    var eve_dir = std.Io.Dir.cwd().openDir(io, eve_root, .{ .iterate = true }) catch |err| {
        slog.info("No EVE settings directory found at '{s}': {}", .{ eve_root, err });
        return .{ .eveRoot = eve_root };
    };
    defer eve_dir.close(io);

    var chars: std.array_hash_map.String(CharAccum) = .empty;
    var users: std.array_hash_map.String(i96) = .empty;

    var install_iter = eve_dir.iterate();
    while (true) {
        const install_entry = install_iter.next(io) catch |err| {
            slog.warn("Failed to enumerate EVE install directory: {}", .{err});
            break;
        } orelse break;
        if (install_entry.kind != .directory) continue;

        const install_name = try arena.dupe(u8, install_entry.name);
        var install_dir = eve_dir.openDir(io, install_name, .{ .iterate = true }) catch |err| {
            slog.warn("Failed to open EVE install directory '{s}': {}", .{ install_name, err });
            continue;
        };
        defer install_dir.close(io);

        var settings_iter = install_dir.iterate();
        while (true) {
            const settings_entry = settings_iter.next(io) catch |err| {
                slog.warn("Failed to enumerate EVE settings directory: {}", .{err});
                break;
            } orelse break;
            if (settings_entry.kind != .directory) continue;
            if (!std.mem.startsWith(u8, settings_entry.name, "settings")) continue;

            const settings_name = try arena.dupe(u8, settings_entry.name);
            var settings_dir = install_dir.openDir(io, settings_name, .{ .iterate = true }) catch |err| {
                slog.warn("Failed to open EVE settings folder '{s}': {}", .{ settings_name, err });
                continue;
            };
            defer settings_dir.close(io);

            const folder_label = try std.fmt.allocPrint(arena, "{s} / {s}", .{ install_name, settings_name });

            var folder_chars = std.ArrayList(SettingsFile).empty;
            var folder_users = std.ArrayList(SettingsFile).empty;

            var file_iter = settings_dir.iterate();
            while (true) {
                const file_entry = file_iter.next(io) catch |err| {
                    slog.warn("Failed to enumerate '{s}': {}", .{ folder_label, err });
                    break;
                } orelse break;
                if (file_entry.kind != .file) continue;

                const is_char = parseSettingsFileId(file_entry.name, "core_char_");
                const is_user = parseSettingsFileId(file_entry.name, "core_user_");
                const id = is_char orelse is_user orelse continue;

                const stat = settings_dir.statFile(io, file_entry.name, .{}) catch |err| {
                    slog.warn("Failed to stat '{s}' in '{s}': {}", .{ file_entry.name, folder_label, err });
                    continue;
                };
                const file: SettingsFile = .{ .id = try arena.dupe(u8, id), .mtime = stat.mtime.nanoseconds };
                if (is_char != null) {
                    try folder_chars.append(arena, file);
                } else {
                    try folder_users.append(arena, file);
                }
            }

            for (folder_users.items) |u| {
                const gop = try users.getOrPut(arena, u.id);
                if (!gop.found_existing or u.mtime > gop.value_ptr.*) gop.value_ptr.* = u.mtime;
            }

            for (folder_chars.items) |c| {
                const suggestion = nearestUser(folder_users.items, c.mtime);
                const gop = try chars.getOrPut(arena, c.id);
                if (!gop.found_existing) {
                    gop.value_ptr.* = .{ .mtime = c.mtime, .folders = .empty, .suggested_user = suggestion };
                } else if (c.mtime > gop.value_ptr.mtime) {
                    gop.value_ptr.mtime = c.mtime;
                    // Newest sighting wins, but don't discard an older folder's match just because the newest one had none.
                    if (suggestion != null) gop.value_ptr.suggested_user = suggestion;
                } else if (gop.value_ptr.suggested_user == null) {
                    gop.value_ptr.suggested_user = suggestion;
                }
                try gop.value_ptr.folders.append(arena, folder_label);
            }
        }
    }

    const out_chars = try arena.alloc(ScannedCharacter, chars.count());
    for (chars.keys(), chars.values(), 0..) |id, accum, i| {
        out_chars[i] = .{
            .id = id,
            .lastSeen = nsToSeconds(accum.mtime),
            .folders = accum.folders.items,
            .suggestedUserId = accum.suggested_user,
        };
    }

    const out_users = try arena.alloc(ScannedUser, users.count());
    for (users.keys(), users.values(), 0..) |id, mtime, i| {
        out_users[i] = .{ .id = id, .lastSeen = nsToSeconds(mtime) };
    }

    return .{ .eveRoot = eve_root, .characters = out_chars, .users = out_users };
}

fn nsToSeconds(ns: i96) i64 {
    return @intCast(@divTrunc(ns, std.time.ns_per_s));
}

/// Fills in `name` for each character: names cached in accounts.json first, then the chatlog-built characterIdMap, then public ESI for whatever's left.
fn resolveNames(arena: std.mem.Allocator, characters: []ScannedCharacter) void {
    var known = std.StringHashMap([]const u8).init(arena);

    if (readAccountsFile(arena)) |file| {
        for (file.characters) |c| {
            if (c.name) |n| known.put(c.id, n) catch {};
        }
    }

    if (config_mod.GlobalSettings.load(arena)) |settings_const| {
        var settings = settings_const;
        defer settings.deinit();
        var it = settings.characterIdMap.iterator();
        while (it.next()) |entry| {
            const id = arena.dupe(u8, entry.value_ptr.*) catch continue;
            const name = arena.dupe(u8, entry.key_ptr.*) catch continue;
            known.put(id, name) catch {};
        }
    } else |err| {
        slog.warn("Failed to load global settings for character names: {}", .{err});
    }

    var missing = std.ArrayList(u64).empty;
    for (characters) |*c| {
        if (known.get(c.id)) |n| {
            c.name = n;
        } else {
            const numeric = std.fmt.parseInt(u64, c.id, 10) catch continue;
            missing.append(arena, numeric) catch continue;
        }
    }
    if (missing.items.len == 0) return;

    var client: std.http.Client = .{ .allocator = arena, .io = g_io };
    defer client.deinit();

    var resolved = std.AutoHashMap(u64, []const u8).init(arena);
    var single_lookups: usize = 0;
    var start: usize = 0;
    while (start < missing.items.len) : (start += ESI_NAMES_BATCH) {
        const batch = missing.items[start..@min(start + ESI_NAMES_BATCH, missing.items.len)];
        if (fetchNames(arena, &client, batch, &resolved)) continue;
        for (batch) |id| {
            if (single_lookups >= ESI_MAX_SINGLE_LOOKUPS) break;
            single_lookups += 1;
            _ = fetchNames(arena, &client, &[_]u64{id}, &resolved);
        }
    }

    for (characters) |*c| {
        if (c.name != null) continue;
        const numeric = std.fmt.parseInt(u64, c.id, 10) catch continue;
        if (resolved.get(numeric)) |n| c.name = n;
    }
}

/// One POST to ESI /universe/names/. Returns false if the request failed, so the caller can retry IDs individually.
fn fetchNames(arena: std.mem.Allocator, client: *std.http.Client, ids: []const u64, out: *std.AutoHashMap(u64, []const u8)) bool {
    const body = std.json.Stringify.valueAlloc(arena, ids, .{}) catch return false;
    const response = http_client.fetch(arena, client, ESI_NAMES_URL, .{
        .content_type = "application/json",
        .payload = body,
    }) orelse return false;

    const Entry = struct { id: u64, name: []const u8, category: []const u8 };
    const parsed = std.json.parseFromSliceLeaky([]const Entry, arena, response, .{ .ignore_unknown_fields = true }) catch |err| {
        slog.warn("Failed to parse ESI universe/names response: {}", .{err});
        return false;
    };
    for (parsed) |entry| {
        if (!std.mem.eql(u8, entry.category, "character")) continue;
        out.put(entry.id, entry.name) catch {};
    }
    return true;
}

/// Null when the file is missing or unparseable - callers fall back to an empty AccountsFile, never delete it, so a hand-edit typo can't wipe the user's accounts.
fn readAccountsFile(arena: std.mem.Allocator) ?AccountsFile {
    const content = std.Io.Dir.cwd().readFileAlloc(g_io, ACCOUNTS_FILE, arena, .limited(MAX_ACCOUNTS_FILE_SIZE)) catch |err| {
        if (err != error.FileNotFound) slog.warn("Failed to read {s}: {}", .{ ACCOUNTS_FILE, err });
        return null;
    };
    return std.json.parseFromSliceLeaky(AccountsFile, arena, content, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| {
        slog.warn("Failed to parse {s}: {}", .{ ACCOUNTS_FILE, err });
        return null;
    };
}

fn returnJson(e: *webui.Event, arena: std.mem.Allocator, value: anytype, fallback: [:0]const u8) void {
    const json = std.json.Stringify.valueAlloc(arena, value, .{}) catch |err| {
        slog.warn("Failed to serialize response: {}", .{err});
        e.returnString(fallback);
        return;
    };
    const json_z = arena.dupeZ(u8, json) catch {
        e.returnString(fallback);
        return;
    };
    e.returnString(json_z);
}

/// Scans EVE's settings folders for every character/account that has logged in on this machine. Response: ScanResponse as JSON.
pub fn scanEveAccounts(e: *webui.Event) void {
    var arena_state = std.heap.ArenaAllocator.init(g_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = scanSettings(arena, g_io, config_mod.environMap()) catch |err| {
        slog.warn("Failed to scan EVE settings for characters: {}", .{err});
        e.returnString("{\"characters\":[],\"users\":[]}");
        return;
    };
    // characters is arena-owned and only const by type; names are filled in place.
    resolveNames(arena, @constCast(result.characters));

    slog.info("Account scan found {} characters, {} accounts", .{ result.characters.len, result.users.len });
    returnJson(e, arena, result, "{\"characters\":[],\"users\":[]}");
}

/// Returns accounts.json, normalized through AccountsFile, or an empty one if it's missing or unreadable.
pub fn loadAccounts(e: *webui.Event) void {
    var arena_state = std.heap.ArenaAllocator.init(g_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const file = readAccountsFile(arena) orelse AccountsFile{};
    returnJson(e, arena, file, "{\"version\":1,\"accounts\":[],\"characters\":[]}");
}

/// Request body: AccountsFile JSON. Round-trips it through the struct so only the known shape ever reaches disk.
pub fn saveAccounts(e: *webui.Event) void {
    var arena_state = std.heap.ArenaAllocator.init(g_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = std.json.parseFromSliceLeaky(AccountsFile, arena, e.getString(), .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| {
        slog.warn("Failed to parse saveAccounts request: {}", .{err});
        e.returnString("{\"success\":false,\"error\":\"Invalid request\"}");
        return;
    };

    const json = std.json.Stringify.valueAlloc(arena, parsed, .{ .whitespace = .indent_2 }) catch {
        e.returnString("{\"success\":false,\"error\":\"Failed to serialize\"}");
        return;
    };

    std.Io.Dir.cwd().createDir(g_io, config_mod.PROFILES_DIR, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => slog.warn("Failed to create profiles directory: {}", .{err}),
    };

    config_mod.Config.atomicWriteFile(arena, g_io, ACCOUNTS_FILE, json) catch |err| {
        slog.err("Failed to write {s}: {}", .{ ACCOUNTS_FILE, err });
        e.returnString("{\"success\":false,\"error\":\"Failed to write accounts.json\"}");
        return;
    };

    e.returnString("{\"success\":true}");
}

test "parseSettingsFileId accepts only numeric ids" {
    try std.testing.expectEqualStrings("12345", parseSettingsFileId("core_char_12345.dat", "core_char_").?);
    try std.testing.expect(parseSettingsFileId("core_char__.dat", "core_char_") == null);
    try std.testing.expect(parseSettingsFileId("core_char_abc.dat", "core_char_") == null);
    try std.testing.expect(parseSettingsFileId("core_user_1.dat", "core_char_") == null);
    try std.testing.expect(parseSettingsFileId("core_char_1.dat.bak", "core_char_") == null);
}

test "nearestUser picks closest within window" {
    const s = std.time.ns_per_s;
    const users = [_]SettingsFile{
        .{ .id = "a", .mtime = 100 * s },
        .{ .id = "b", .mtime = 203 * s },
    };
    try std.testing.expectEqualStrings("b", nearestUser(&users, 200 * s).?);
    try std.testing.expectEqualStrings("a", nearestUser(&users, 95 * s).?);
    try std.testing.expect(nearestUser(&users, 150 * s) == null);
}
