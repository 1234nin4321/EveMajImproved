//! profiles/accounts.json, written by the config dialog's Account Config tab. Shared so the main app can read account membership for Display Regions' account cells without pulling in config.exe's webui code.
const std = @import("std");

pub const ACCOUNTS_FILE = "profiles/accounts.json";
pub const MAX_FILE_SIZE: usize = 1024 * 1024;

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

/// The linked part of accounts.json as embedded in every profile ("accountLinks"), so a profile file that's shared, backed up or moved to another PC carries its accounts and character links with it. accounts.json stays the live source; the config dialog refreshes this copy on each profile save and merges it back through Import Settings.
pub const Snapshot = struct {
    accounts: []const AccountsFile.Account = &.{},
    characters: []const AccountsFile.CharacterLink = &.{},
};

/// A deep copy of a Snapshot that outlives the JSON parse it came from. Everything lives in one heap-allocated arena, so the owner can be moved by value and freed in one step.
pub const OwnedSnapshot = struct {
    arena: ?*std.heap.ArenaAllocator = null,
    value: Snapshot = .{},

    pub fn init(allocator: std.mem.Allocator, source: Snapshot) !OwnedSnapshot {
        if (source.accounts.len == 0 and source.characters.len == 0) return .{};

        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);
        arena.* = .init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const accounts = try a.alloc(AccountsFile.Account, source.accounts.len);
        for (source.accounts, accounts) |src, *dst| {
            const user_ids = try a.alloc([]const u8, src.userIds.len);
            for (src.userIds, user_ids) |id, *copy| copy.* = try a.dupe(u8, id);
            dst.* = .{ .id = try a.dupe(u8, src.id), .name = try a.dupe(u8, src.name), .userIds = user_ids };
        }

        const characters = try a.alloc(AccountsFile.CharacterLink, source.characters.len);
        for (source.characters, characters) |src, *dst| {
            dst.* = .{
                .id = try a.dupe(u8, src.id),
                .name = if (src.name) |name| try a.dupe(u8, name) else null,
                .accountId = if (src.accountId) |account| try a.dupe(u8, account) else null,
                .lastSeen = src.lastSeen,
            };
        }

        return .{ .arena = arena, .value = .{ .accounts = accounts, .characters = characters } };
    }

    pub fn deinit(self: *OwnedSnapshot) void {
        if (self.arena) |arena| {
            const allocator = arena.child_allocator;
            arena.deinit();
            allocator.destroy(arena);
        }
        self.* = .{};
    }
};

/// Lower-cased character name -> account id, for every named, linked character. Keys and values are owned by `allocator`; free with freeMembership.
pub const Membership = std.StringHashMap([]const u8);

pub fn freeMembership(allocator: std.mem.Allocator, map: *Membership) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    map.deinit();
}

pub fn membershipFromFile(allocator: std.mem.Allocator, file: AccountsFile) !Membership {
    var map = Membership.init(allocator);
    errdefer freeMembership(allocator, &map);
    for (file.characters) |c| {
        const name = c.name orelse continue;
        const account = c.accountId orelse continue;
        if (name.len == 0 or account.len == 0) continue;
        const key = try std.ascii.allocLowerString(allocator, name);
        errdefer allocator.free(key);
        const value = try allocator.dupe(u8, account);
        errdefer allocator.free(value);
        const gop = try map.getOrPut(key);
        if (gop.found_existing) {
            allocator.free(key);
            allocator.free(gop.value_ptr.*);
        }
        gop.value_ptr.* = value;
    }
    return map;
}

/// Reads accounts.json from the working directory; an empty map if it's missing or malformed (account cells then just match nobody).
pub fn loadMembership(allocator: std.mem.Allocator, io: std.Io) Membership {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const content = std.Io.Dir.cwd().readFileAlloc(io, ACCOUNTS_FILE, arena.allocator(), .limited(MAX_FILE_SIZE)) catch return Membership.init(allocator);
    const file = std.json.parseFromSliceLeaky(AccountsFile, arena.allocator(), content, .{ .ignore_unknown_fields = true }) catch return Membership.init(allocator);
    return membershipFromFile(allocator, file) catch Membership.init(allocator);
}

pub fn accountOf(map: *const Membership, name: []const u8) ?[]const u8 {
    var buf: [128]u8 = undefined;
    if (name.len > buf.len) return null;
    return map.get(std.ascii.lowerString(&buf, name));
}

test "membership maps names case-insensitively and skips unlinked characters" {
    const allocator = std.testing.allocator;
    const file: AccountsFile = .{ .characters = &.{
        .{ .id = "1", .name = "FC Zoetrope", .accountId = "acc_1" },
        .{ .id = "2", .name = "Alt Two", .accountId = null },
        .{ .id = "3", .name = null, .accountId = "acc_1" },
    } };
    var map = try membershipFromFile(allocator, file);
    defer freeMembership(allocator, &map);
    try std.testing.expectEqualStrings("acc_1", accountOf(&map, "fc zoetrope").?);
    try std.testing.expect(accountOf(&map, "Alt Two") == null);
    try std.testing.expectEqual(@as(u32, 1), map.count());
}

test "owned snapshot deep-copies its source and frees cleanly" {
    const allocator = std.testing.allocator;
    var name_buf = "Main Account".*;
    var user_buf = "90000001".*;
    const user_ids = [_][]const u8{&user_buf};
    const source: Snapshot = .{
        .accounts = &.{.{ .id = "acc_1", .name = &name_buf, .userIds = &user_ids }},
        .characters = &.{
            .{ .id = "1", .name = "FC Zoetrope", .accountId = "acc_1", .lastSeen = 42 },
            .{ .id = "2" },
        },
    };
    var owned = try OwnedSnapshot.init(allocator, source);
    defer owned.deinit();

    // Scribbling over the source must not reach the copy.
    @memset(&name_buf, 'x');
    @memset(&user_buf, 'x');
    try std.testing.expectEqualStrings("Main Account", owned.value.accounts[0].name);
    try std.testing.expectEqualStrings("90000001", owned.value.accounts[0].userIds[0]);
    try std.testing.expectEqualStrings("acc_1", owned.value.characters[0].accountId.?);
    try std.testing.expectEqual(@as(?i64, 42), owned.value.characters[0].lastSeen);
    try std.testing.expect(owned.value.characters[1].name == null);

    var empty = try OwnedSnapshot.init(allocator, .{});
    defer empty.deinit();
    try std.testing.expect(empty.arena == null);
}

test "snapshot survives the profile's JSON round-trip" {
    const allocator = std.testing.allocator;
    const Profile = struct { accountLinks: Snapshot = .{} };
    const json =
        \\{"accountLinks":{"accounts":[{"id":"acc_1","name":"Main","userIds":["111"]}],
        \\  "characters":[{"id":"9","name":"Pilot","accountId":"acc_1"}],"unknown":true}}
    ;
    const parsed = try std.json.parseFromSlice(Profile, allocator, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    var owned = try OwnedSnapshot.init(allocator, parsed.value.accountLinks);
    defer owned.deinit();

    const out = try std.json.Stringify.valueAlloc(allocator, Profile{ .accountLinks = owned.value }, .{});
    defer allocator.free(out);
    const again = try std.json.parseFromSlice(Profile, allocator, out, .{});
    defer again.deinit();
    try std.testing.expectEqualStrings("Main", again.value.accountLinks.accounts[0].name);
    try std.testing.expectEqualStrings("111", again.value.accountLinks.accounts[0].userIds[0]);
    try std.testing.expectEqualStrings("acc_1", again.value.accountLinks.characters[0].accountId.?);

    // A profile written before this field existed loads as an empty snapshot.
    const old = try std.json.parseFromSlice(Profile, allocator, "{}", .{});
    defer old.deinit();
    try std.testing.expectEqual(@as(usize, 0), old.value.accountLinks.accounts.len);
}
