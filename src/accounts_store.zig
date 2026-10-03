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
