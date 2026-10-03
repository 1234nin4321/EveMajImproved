//! Display Regions: splits the Thumbnail Space region (normally a full display) into an NxN grid of cells, each holding only the thumbnails its rule claims. Platform-neutral (no Win32), so the routing rule and cell maths unit-test anywhere; painter.zig does the actual placement.
const std = @import("std");

/// Largest grid offered (4x4 = 16 cells).
pub const MAX_SIZE: u8 = 4;
pub const MAX_CELLS: usize = @as(usize, MAX_SIZE) * MAX_SIZE;

pub const SlotKind = enum {
    /// Holds nothing.
    Empty,
    /// Every thumbnail no other cell claims.
    EveryoneElse,
    /// The characters listed in `characters`.
    Custom,
    /// A single character (`characters[0]`) filling the whole cell.
    Client,
    /// Every character linked to Account Config account `account`.
    Account,
};

pub const Slot = struct {
    kind: SlotKind = .Empty,
    /// Account Config account id, for .Account.
    account: ?[]const u8 = null,
    /// Character names, for .Custom (any number) and .Client (the first is used).
    characters: []const []const u8 = &.{},
};

pub const DisplayGrid = struct {
    /// 0 = off; 1..MAX_SIZE = an NxN split of the Thumbnail Space region.
    size: u8 = 0,
    /// Row-major, one per cell; missing trailing cells count as Empty.
    slots: []const Slot = &.{},

    pub fn isActive(self: DisplayGrid) bool {
        return self.size >= 1 and self.size <= MAX_SIZE;
    }

    pub fn cellCount(self: DisplayGrid) usize {
        return if (self.isActive()) @as(usize, self.size) * self.size else 0;
    }

    /// Frees everything clone()/fromJsonValue() allocated; a default (unallocated) grid is a no-op.
    pub fn deinit(self: *DisplayGrid, allocator: std.mem.Allocator) void {
        for (self.slots) |slot| {
            if (slot.account) |a| allocator.free(a);
            for (slot.characters) |c| allocator.free(c);
            if (slot.characters.len > 0) allocator.free(slot.characters);
        }
        if (self.slots.len > 0) allocator.free(self.slots);
        self.* = .{};
    }

    /// Deep copy owned by `allocator` (e.g. out of a JSON parse arena).
    pub fn clone(self: DisplayGrid, allocator: std.mem.Allocator) !DisplayGrid {
        var out: DisplayGrid = .{ .size = self.size };
        if (self.slots.len == 0) return out;
        errdefer out.deinit(allocator);

        const slots = try allocator.alloc(Slot, @min(self.slots.len, MAX_CELLS));
        @memset(slots, .{});
        out.slots = slots;
        for (slots, self.slots[0..slots.len]) |*dst, src| {
            dst.kind = src.kind;
            if (src.account) |a| dst.account = try allocator.dupe(u8, a);
            if (src.characters.len > 0) {
                const names = try allocator.alloc([]const u8, src.characters.len);
                @memset(names, "");
                dst.characters = names;
                for (names, src.characters) |*n, c| n.* = try allocator.dupe(u8, c);
            }
        }
        return out;
    }

    /// For the config dialog's live-preview patch, which arrives as a loose std.json.Value rather than through Config.Wire.
    pub fn fromJsonValue(allocator: std.mem.Allocator, value: std.json.Value) !DisplayGrid {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const parsed = try std.json.parseFromValueLeaky(DisplayGrid, arena.allocator(), value, .{ .ignore_unknown_fields = true });
        return parsed.clone(allocator);
    }

    pub fn validate(self: *DisplayGrid) void {
        if (self.size > MAX_SIZE) self.size = MAX_SIZE;
    }
};

/// Which cell claims `name`, or null if none does (it then keeps its normal saved/spawn position). Priority: Client, then Custom, then Account, then Everyone Else, so a character listed explicitly always wins over an account-wide rule. `account_of` is the character's Account Config account id, if linked.
pub fn assignSlot(grid: DisplayGrid, name: []const u8, account_of: ?[]const u8) ?usize {
    const cells = @min(grid.cellCount(), grid.slots.len);
    const slots = grid.slots[0..cells];

    for (slots, 0..) |slot, i| {
        if (slot.kind == .Client and slot.characters.len > 0 and std.ascii.eqlIgnoreCase(slot.characters[0], name)) return i;
    }
    for (slots, 0..) |slot, i| {
        if (slot.kind != .Custom) continue;
        for (slot.characters) |c| {
            if (std.ascii.eqlIgnoreCase(c, name)) return i;
        }
    }
    if (account_of) |acct| {
        for (slots, 0..) |slot, i| {
            if (slot.kind == .Account and slot.account != null and std.mem.eql(u8, slot.account.?, acct)) return i;
        }
    }
    for (slots, 0..) |slot, i| {
        if (slot.kind == .EveryoneElse) return i;
    }
    return null;
}

pub const Rect = struct { left: i32, top: i32, right: i32, bottom: i32 };

/// Cell `index` (row-major) of `region` split `size` x `size`, with `gap` px between cells; the last row/column absorbs rounding so cells tile the region exactly.
pub fn cellRect(region: Rect, size: u8, index: usize, gap: i32) Rect {
    const n: i32 = @max(size, 1);
    const col: i32 = @intCast(index % @as(usize, @intCast(n)));
    const row: i32 = @intCast(index / @as(usize, @intCast(n)));
    const width = region.right - region.left;
    const height = region.bottom - region.top;
    const cell_w = @divTrunc(width - gap * (n - 1), n);
    const cell_h = @divTrunc(height - gap * (n - 1), n);
    const left = region.left + col * (cell_w + gap);
    const top = region.top + row * (cell_h + gap);
    return .{
        .left = left,
        .top = top,
        .right = if (col == n - 1) region.right else left + cell_w,
        .bottom = if (row == n - 1) region.bottom else top + cell_h,
    };
}

test "assignSlot priority: client > custom > account > everyone else" {
    const slots = [_]Slot{
        .{ .kind = .EveryoneElse },
        .{ .kind = .Account, .account = "acc_main" },
        .{ .kind = .Custom, .characters = &.{ "Alt Two", "Miner Three" } },
        .{ .kind = .Client, .characters = &.{"FC Zoetrope"} },
    };
    const grid: DisplayGrid = .{ .size = 2, .slots = &slots };
    try std.testing.expectEqual(@as(?usize, 3), assignSlot(grid, "fc zoetrope", "acc_main"));
    try std.testing.expectEqual(@as(?usize, 2), assignSlot(grid, "Miner Three", "acc_main"));
    try std.testing.expectEqual(@as(?usize, 1), assignSlot(grid, "Someone", "acc_main"));
    try std.testing.expectEqual(@as(?usize, 0), assignSlot(grid, "Someone", null));
    try std.testing.expectEqual(@as(?usize, 0), assignSlot(grid, "Someone", "acc_other"));
}

test "assignSlot ignores slots beyond the grid and returns null with no catch-all" {
    const slots = [_]Slot{ .{ .kind = .Custom, .characters = &.{"A"} }, .{ .kind = .EveryoneElse } };
    const grid: DisplayGrid = .{ .size = 1, .slots = &slots };
    try std.testing.expectEqual(@as(?usize, 0), assignSlot(grid, "A", null));
    try std.testing.expectEqual(@as(?usize, null), assignSlot(grid, "B", null));
    try std.testing.expectEqual(@as(?usize, null), assignSlot(.{}, "A", null));
}

test "cellRect tiles the region exactly" {
    const region: Rect = .{ .left = 0, .top = 0, .right = 2560, .bottom = 1440 };
    const a = cellRect(region, 2, 0, 10);
    const d = cellRect(region, 2, 3, 10);
    try std.testing.expectEqual(Rect{ .left = 0, .top = 0, .right = 1275, .bottom = 715 }, a);
    try std.testing.expectEqual(Rect{ .left = 1285, .top = 725, .right = 2560, .bottom = 1440 }, d);
    const whole = cellRect(.{ .left = -1080, .top = -240, .right = 0, .bottom = 1680 }, 1, 0, 10);
    try std.testing.expectEqual(Rect{ .left = -1080, .top = -240, .right = 0, .bottom = 1680 }, whole);
    // 3x3 with a remainder: last column ends exactly on the region edge.
    try std.testing.expectEqual(@as(i32, 1000), cellRect(.{ .left = 0, .top = 0, .right = 1000, .bottom = 999 }, 3, 8, 0).right);
}

test "clone, fromJsonValue and deinit round-trip without leaks" {
    const allocator = std.testing.allocator;
    const json =
        \\{"size":3,"slots":[{"kind":"Client","characters":["FC Zoetrope"]},{"kind":"Account","account":"acc_1"},{"kind":"EveryoneElse"},{"kind":"Empty","extra":1}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    var grid = try DisplayGrid.fromJsonValue(allocator, parsed.value);
    defer grid.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 3), grid.size);
    try std.testing.expectEqual(@as(usize, 4), grid.slots.len);
    try std.testing.expectEqualStrings("FC Zoetrope", grid.slots[0].characters[0]);
    try std.testing.expectEqualStrings("acc_1", grid.slots[1].account.?);

    var copy = try grid.clone(allocator);
    defer copy.deinit(allocator);
    try std.testing.expectEqual(SlotKind.EveryoneElse, copy.slots[2].kind);

    const out = try std.json.Stringify.valueAlloc(allocator, grid, .{});
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"kind\":\"Client\"") != null);
}
