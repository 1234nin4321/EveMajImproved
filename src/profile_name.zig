//! Which strings are acceptable profile names. Names arrive from the evemajpreview:// protocol (any web page can trigger it), window-message IPC, global.settings.json and the config dialog, and get joined onto the profiles directory, so anything that could address a different file is rejected here. Platform-neutral so it unit-tests anywhere.
const std = @import("std");

pub const MAX_LEN: usize = 64;

/// Files that share the profiles directory but aren't profiles.
const RESERVED = [_][]const u8{ "global.settings.json", "accounts.json" };

/// Windows device names, which resolve to devices instead of files even with an extension.
const DEVICES = [_][]const u8{ "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9" };

/// A plain "<name>.json" file name: no directory parts, drive or stream colons, characters Windows forbids in file names, leading/trailing dots or spaces, device names, or the app's own files.
pub fn isSafe(name: []const u8) bool {
    if (name.len == 0 or name.len > MAX_LEN) return false;
    if (!std.ascii.endsWithIgnoreCase(name, ".json") or name.len == ".json".len) return false;
    for (name) |c| {
        if (c < 0x20 or c == 0x7F) return false;
        switch (c) {
            '/', '\\', ':', '*', '?', '"', '<', '>', '|' => return false,
            else => {},
        }
    }
    if (name[0] == '.' or name[0] == ' ' or name[name.len - 1] == ' ') return false;
    for (RESERVED) |r| {
        if (std.ascii.eqlIgnoreCase(name, r)) return false;
    }
    const stem_end = std.mem.indexOfScalar(u8, name, '.') orelse name.len;
    for (DEVICES) |d| {
        if (std.ascii.eqlIgnoreCase(name[0..stem_end], d)) return false;
    }
    return true;
}

test "accepts ordinary profile names" {
    try std.testing.expect(isSafe("default.json"));
    try std.testing.expect(isSafe("pvp fleet.json"));
    try std.testing.expect(isSafe("Mining-2.JSON"));
    try std.testing.expect(isSafe("a..b.json"));
}

test "rejects anything that could address another file" {
    const bad = [_][]const u8{
        "",                       "..\\..\\x.json",       "../x.json",           "C:\\x.json",
        "C:x.json",               "\\\\host\\share.json", "x.json:stream",       "global.settings.json",
        "ACCOUNTS.json",          "CON.json",             "nul.json",            "com1.cfg.json",
        "..json",                 ".json",                ".hidden.json",        "x.txt",
        "x.json ",                " x.json",              "x\x00.json",          "x\n.json",
        "a" ** 61 ++ ".json",
    };
    for (bad) |name| {
        if (isSafe(name)) {
            std.debug.print("accepted: {s}\n", .{name});
            return error.TestUnexpectedResult;
        }
    }
}
