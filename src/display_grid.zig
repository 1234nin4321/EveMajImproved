//! Display Regions: splits the Thumbnail Space region (normally a full display) into a columns x rows grid of cells, each holding only the thumbnails its rule claims. Platform-neutral (no Win32), so the routing rule and cell maths unit-test anywhere; painter.zig does the actual placement.
const std = @import("std");

/// Largest columns/rows count a custom split allows (8x8 = 64 cells); the dialog's presets stop at 4x4.
pub const MAX_DIM: u8 = 8;
pub const MAX_CELLS: usize = @as(usize, MAX_DIM) * MAX_DIM;

pub const SlotKind = enum {
    /// Holds nothing - unless it has a fillOrder, which makes it take the leftovers (see Slot.fillOrder).
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
    /// .Empty only: a Region Fit direction name (e.g. "RowFirst_LTR_TTB"). When set, the region takes the characters no other region claims - same tier as Everyone Else - and arranges them in this order instead of the global one.
    fillOrder: ?[]const u8 = null,

    /// Whether this slot catches characters nothing more specific claimed.
    pub fn takesLeftovers(self: Slot) bool {
        return self.kind == .EveryoneElse or (self.kind == .Empty and self.fillOrder != null);
    }
};

pub const DisplayGrid = struct {
    /// Square NxN split (0 = off). Superseded by columns/rows when both are set; kept so v1.3.0 profiles still load.
    size: u8 = 0,
    /// Custom columns x rows split; both must be non-zero to take effect.
    columns: u8 = 0,
    rows: u8 = 0,
    /// Stretch thumbnails to fill their cell exactly (a 2x2 grid on 2560x1440 gives 1280x720 thumbnails) instead of keeping the configured thumbnail shape inside it.
    fitToGrid: bool = false,
    /// Row-major, one per cell; missing trailing cells count as Empty.
    slots: []const Slot = &.{},

    pub fn columnCount(self: DisplayGrid) u8 {
        return if (self.columns > 0 and self.rows > 0) self.columns else self.size;
    }

    pub fn rowCount(self: DisplayGrid) u8 {
        return if (self.columns > 0 and self.rows > 0) self.rows else self.size;
    }

    pub fn isActive(self: DisplayGrid) bool {
        const c = self.columnCount();
        const r = self.rowCount();
        return c >= 1 and r >= 1 and c <= MAX_DIM and r <= MAX_DIM;
    }

    pub fn cellCount(self: DisplayGrid) usize {
        return if (self.isActive()) @as(usize, self.columnCount()) * self.rowCount() else 0;
    }

    /// Frees everything clone()/fromJsonValue() allocated; a default (unallocated) grid is a no-op.
    pub fn deinit(self: *DisplayGrid, allocator: std.mem.Allocator) void {
        for (self.slots) |slot| {
            if (slot.account) |a| allocator.free(a);
            if (slot.fillOrder) |f| allocator.free(f);
            for (slot.characters) |c| allocator.free(c);
            if (slot.characters.len > 0) allocator.free(slot.characters);
        }
        if (self.slots.len > 0) allocator.free(self.slots);
        self.* = .{};
    }

    /// Deep copy owned by `allocator` (e.g. out of a JSON parse arena).
    pub fn clone(self: DisplayGrid, allocator: std.mem.Allocator) !DisplayGrid {
        var out: DisplayGrid = .{ .size = self.size, .columns = self.columns, .rows = self.rows, .fitToGrid = self.fitToGrid };
        if (self.slots.len == 0) return out;
        errdefer out.deinit(allocator);

        const slots = try allocator.alloc(Slot, @min(self.slots.len, MAX_CELLS));
        @memset(slots, .{});
        out.slots = slots;
        for (slots, self.slots[0..slots.len]) |*dst, src| {
            dst.kind = src.kind;
            if (src.account) |a| dst.account = try allocator.dupe(u8, a);
            if (src.fillOrder) |f| dst.fillOrder = try allocator.dupe(u8, f);
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
        if (self.size > MAX_DIM) self.size = MAX_DIM;
        if (self.columns > MAX_DIM) self.columns = MAX_DIM;
        if (self.rows > MAX_DIM) self.rows = MAX_DIM;
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
        if (slot.takesLeftovers()) return i;
    }
    return null;
}

pub const Rect = struct { left: i32, top: i32, right: i32, bottom: i32 };

/// Most displays that can each carry their own grid.
pub const MAX_LAYOUTS: usize = 8;

/// One display's grid: the physical-pixel area it splits (the display's bounds or work area, captured when it was set up) plus its cells.
pub const DisplayLayout = struct {
    /// The display's stable id (its monitor device path, see displays.zig), so the dialog can match a layout back to its display.
    displayId: []const u8 = "",
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    /// Whether x/y/width/height came from the work area (taskbar excluded) rather than the full bounds; only the dialog reads this.
    useWorkArea: bool = true,
    grid: DisplayGrid = .{},

    pub fn rect(self: DisplayLayout) Rect {
        return .{ .left = self.x, .top = self.y, .right = self.x + self.width, .bottom = self.y + self.height };
    }

    pub fn isActive(self: DisplayLayout) bool {
        return self.width > 0 and self.height > 0 and self.grid.isActive();
    }
};

pub fn freeLayouts(allocator: std.mem.Allocator, layouts: []const DisplayLayout) void {
    for (layouts) |layout| {
        if (layout.displayId.len > 0) allocator.free(layout.displayId);
        var grid = layout.grid;
        grid.deinit(allocator);
    }
    if (layouts.len > 0) allocator.free(layouts);
}

/// Deep copy owned by `allocator`; at most MAX_LAYOUTS are kept.
pub fn cloneLayouts(allocator: std.mem.Allocator, layouts: []const DisplayLayout) ![]const DisplayLayout {
    if (layouts.len == 0) return &.{};
    const out = try allocator.alloc(DisplayLayout, @min(layouts.len, MAX_LAYOUTS));
    for (out) |*o| o.* = .{};
    errdefer freeLayouts(allocator, out);
    for (out, layouts[0..out.len]) |*dst, src| {
        dst.* = .{ .x = src.x, .y = src.y, .width = src.width, .height = src.height, .useWorkArea = src.useWorkArea };
        if (src.displayId.len > 0) dst.displayId = try allocator.dupe(u8, src.displayId);
        dst.grid = try src.grid.clone(allocator);
    }
    return out;
}

/// Live-preview counterpart of cloneLayouts, from a loose std.json.Value array.
pub fn layoutsFromJsonValue(allocator: std.mem.Allocator, value: std.json.Value) ![]const DisplayLayout {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromValueLeaky([]const DisplayLayout, arena.allocator(), value, .{ .ignore_unknown_fields = true });
    return cloneLayouts(allocator, parsed);
}

/// A grid placed on screen: what the painter routes thumbnails through. Cells of every view share one global index space, in view order.
pub const LayoutView = struct {
    rect: Rect,
    grid: DisplayGrid,
};

pub fn totalCells(views: []const LayoutView) usize {
    var total: usize = 0;
    for (views) |v| total += v.grid.cellCount();
    return total;
}

pub const CellRef = struct { view: usize, local: usize };

/// Which view (and which of its cells) global cell `global` is.
pub fn locate(views: []const LayoutView, global: usize) ?CellRef {
    var base: usize = 0;
    for (views, 0..) |v, i| {
        const count = v.grid.cellCount();
        if (global < base + count) return .{ .view = i, .local = global - base };
        base += count;
    }
    return null;
}

/// assignSlot across every view: one priority pass over all displays' cells (Client, then Custom, then Account, then Everyone Else), returning a global cell index.
pub fn assignSlotMulti(views: []const LayoutView, name: []const u8, account_of: ?[]const u8) ?usize {
    const passes = [_]SlotKind{ .Client, .Custom, .Account, .EveryoneElse };
    for (passes) |kind| {
        var base: usize = 0;
        for (views) |v| {
            const cells = @min(v.grid.cellCount(), v.grid.slots.len);
            for (v.grid.slots[0..cells], 0..) |slot, i| {
                // Leftover-taking Empty regions share Everyone Else's tier, so the first catch-all in grid order wins.
                const in_pass = slot.kind == kind or (kind == .EveryoneElse and slot.kind == .Empty);
                if (!in_pass) continue;
                if (slotClaims(slot, name, account_of)) return base + i;
            }
            base += v.grid.cellCount();
        }
    }
    return null;
}

fn slotClaims(slot: Slot, name: []const u8, account_of: ?[]const u8) bool {
    return switch (slot.kind) {
        .Empty => slot.fillOrder != null,
        .EveryoneElse => true,
        .Client => slot.characters.len > 0 and std.ascii.eqlIgnoreCase(slot.characters[0], name),
        .Custom => for (slot.characters) |c| {
            if (std.ascii.eqlIgnoreCase(c, name)) break true;
        } else false,
        .Account => account_of != null and slot.account != null and std.mem.eql(u8, slot.account.?, account_of.?),
    };
}

/// The fill order a global cell arranges its characters in, when it overrides the global one (leftover-taking Empty regions only).
pub fn slotFillOrder(views: []const LayoutView, global: usize) ?[]const u8 {
    const ref = locate(views, global) orelse return null;
    const grid = views[ref.view].grid;
    if (ref.local >= grid.slots.len) return null;
    const slot = grid.slots[ref.local];
    return if (slot.kind == .Empty) slot.fillOrder else null;
}

/// Screen rect of global cell `global`.
pub fn cellRectMulti(views: []const LayoutView, global: usize, gap: i32) ?Rect {
    const ref = locate(views, global) orelse return null;
    const v = views[ref.view];
    return cellRect(v.rect, v.grid.columnCount(), v.grid.rowCount(), ref.local, gap);
}

/// Cell `index` (row-major) of `region` split `columns` x `rows`, with `gap` px between cells; the last row/column absorbs rounding so cells tile the region exactly.
pub fn cellRect(region: Rect, columns: u8, rows: u8, index: usize, gap: i32) Rect {
    const nc: i32 = @max(columns, 1);
    const nr: i32 = @max(rows, 1);
    const col: i32 = @intCast(index % @as(usize, @intCast(nc)));
    const row: i32 = @intCast(index / @as(usize, @intCast(nc)));
    const width = region.right - region.left;
    const height = region.bottom - region.top;
    const cell_w = @divTrunc(width - gap * (nc - 1), nc);
    const cell_h = @divTrunc(height - gap * (nr - 1), nr);
    const left = region.left + col * (cell_w + gap);
    const top = region.top + row * (cell_h + gap);
    return .{
        .left = left,
        .top = top,
        .right = if (col == nc - 1) region.right else left + cell_w,
        .bottom = if (row == nr - 1) region.bottom else top + cell_h,
    };
}

pub const FillGrid = struct { columns: u32, rows: u32, tile_width: i32, tile_height: i32 };

/// Fit to Grid: tiles `count` thumbnails across `cell` with no leftover space, choosing the columns x rows split whose tile shape is closest to `aspect` (the configured thumbnail width/height). One thumbnail fills the whole cell.
pub fn fillGrid(cell: Rect, count: usize, spacing: i32, aspect: f32) FillGrid {
    const width = cell.right - cell.left;
    const height = cell.bottom - cell.top;
    const n: u32 = @intCast(@max(count, 1));
    var best: FillGrid = .{ .columns = 1, .rows = n, .tile_width = width, .tile_height = height };
    var best_score: f32 = std.math.floatMax(f32);
    var cols: u32 = 1;
    while (cols <= n) : (cols += 1) {
        const rows = (n + cols - 1) / cols;
        // Skip splits that leave a whole empty row.
        if ((rows - 1) * cols >= n) continue;
        const tw = @divTrunc(width - spacing * @as(i32, @intCast(cols - 1)), @as(i32, @intCast(cols)));
        const th = @divTrunc(height - spacing * @as(i32, @intCast(rows - 1)), @as(i32, @intCast(rows)));
        if (tw <= 0 or th <= 0) continue;
        const tile_aspect = @as(f32, @floatFromInt(tw)) / @as(f32, @floatFromInt(th));
        const score = @abs(@log(tile_aspect / @max(aspect, 0.01)));
        if (score < best_score) {
            best_score = score;
            best = .{ .columns = cols, .rows = rows, .tile_width = tw, .tile_height = th };
        }
    }
    return best;
}

test "fillGrid: one thumbnail fills the cell, several split it evenly" {
    const cell: Rect = .{ .left = 0, .top = 0, .right = 1280, .bottom = 720 };
    try std.testing.expectEqual(FillGrid{ .columns = 1, .rows = 1, .tile_width = 1280, .tile_height = 720 }, fillGrid(cell, 1, 0, 16.0 / 9.0));
    // 4 x 16:9 in a 16:9 cell -> 2x2 of 640x360.
    try std.testing.expectEqual(FillGrid{ .columns = 2, .rows = 2, .tile_width = 640, .tile_height = 360 }, fillGrid(cell, 4, 0, 16.0 / 9.0));
    // 2 in a 16:9 cell: side-by-side and stacked are equally far from 16:9, so only check that it uses exactly two tiles.
    const two = fillGrid(cell, 2, 10, 16.0 / 9.0);
    try std.testing.expectEqual(@as(u32, 2), two.columns * two.rows);
    // 3 in a tall portrait cell stack vertically.
    const tall = fillGrid(.{ .left = 0, .top = 0, .right = 1080, .bottom = 1920 }, 3, 0, 16.0 / 9.0);
    try std.testing.expectEqual(@as(u32, 1), tall.columns);
    try std.testing.expectEqual(@as(i32, 640), tall.tile_height);
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
    const a = cellRect(region, 2, 2, 0, 10);
    const d = cellRect(region, 2, 2, 3, 10);
    try std.testing.expectEqual(Rect{ .left = 0, .top = 0, .right = 1275, .bottom = 715 }, a);
    try std.testing.expectEqual(Rect{ .left = 1285, .top = 725, .right = 2560, .bottom = 1440 }, d);
    const whole = cellRect(.{ .left = -1080, .top = -240, .right = 0, .bottom = 1680 }, 1, 1, 0, 10);
    try std.testing.expectEqual(Rect{ .left = -1080, .top = -240, .right = 0, .bottom = 1680 }, whole);
    // 3x3 with a remainder: last column ends exactly on the region edge.
    try std.testing.expectEqual(@as(i32, 1000), cellRect(.{ .left = 0, .top = 0, .right = 1000, .bottom = 999 }, 3, 3, 8, 0).right);
}

test "custom columns x rows overrides size and tiles non-square" {
    const grid: DisplayGrid = .{ .size = 2, .columns = 3, .rows = 2 };
    try std.testing.expectEqual(@as(usize, 6), grid.cellCount());
    try std.testing.expectEqual(@as(u8, 3), grid.columnCount());
    const legacy: DisplayGrid = .{ .size = 4 };
    try std.testing.expectEqual(@as(usize, 16), legacy.cellCount());
    const half: DisplayGrid = .{ .columns = 3 };
    try std.testing.expectEqual(@as(usize, 0), half.cellCount());
    const too_big: DisplayGrid = .{ .columns = 9, .rows = 1 };
    try std.testing.expect(!too_big.isActive());

    // 3 across x 2 down over 3000x1000: index 4 is the middle of the bottom row.
    const region: Rect = .{ .left = 0, .top = 0, .right = 3000, .bottom = 1000 };
    try std.testing.expectEqual(Rect{ .left = 1000, .top = 500, .right = 2000, .bottom = 1000 }, cellRect(region, 3, 2, 4, 0));
    try std.testing.expectEqual(Rect{ .left = 2000, .top = 0, .right = 3000, .bottom = 500 }, cellRect(region, 3, 2, 2, 0));
}

test "multi-display: one priority pass across displays, global cell indices" {
    const d1_slots = [_]Slot{ .{ .kind = .EveryoneElse }, .{ .kind = .Empty }, .{ .kind = .Empty }, .{ .kind = .Custom, .characters = &.{"Miner Three"} } };
    const d2_slots = [_]Slot{ .{ .kind = .Account, .account = "acc_alts" }, .{ .kind = .Client, .characters = &.{"FC Zoetrope"} }, .{ .kind = .Empty } };
    const views = [_]LayoutView{
        .{ .rect = .{ .left = 0, .top = 0, .right = 2560, .bottom = 1440 }, .grid = .{ .size = 2, .slots = &d1_slots } },
        .{ .rect = .{ .left = 2560, .top = 180, .right = 4480, .bottom = 1260 }, .grid = .{ .columns = 3, .rows = 1, .slots = &d2_slots } },
    };
    try std.testing.expectEqual(@as(usize, 7), totalCells(&views));
    // Client on display 2 beats display 1's catch-all.
    try std.testing.expectEqual(@as(?usize, 5), assignSlotMulti(&views, "FC Zoetrope", "acc_main"));
    // Custom on display 1 beats the Account cell on display 2.
    try std.testing.expectEqual(@as(?usize, 3), assignSlotMulti(&views, "Miner Three", "acc_alts"));
    try std.testing.expectEqual(@as(?usize, 4), assignSlotMulti(&views, "Alt Two", "acc_alts"));
    try std.testing.expectEqual(@as(?usize, 0), assignSlotMulti(&views, "Nobody", null));
    try std.testing.expectEqual(CellRef{ .view = 1, .local = 1 }, locate(&views, 5).?);
    try std.testing.expectEqual(Rect{ .left = 3200, .top = 180, .right = 3840, .bottom = 1260 }, cellRectMulti(&views, 5, 0).?);
    try std.testing.expect(locate(&views, 7) == null);
    try std.testing.expectEqual(@as(?usize, null), assignSlotMulti(views[1..], "Nobody", null));
}

test "Empty regions with a fill order take leftovers, in grid order with Everyone Else" {
    const plain_empty = [_]Slot{ .{ .kind = .Empty }, .{ .kind = .Custom, .characters = &.{"A"} } };
    const v1 = [_]LayoutView{.{ .rect = .{ .left = 0, .top = 0, .right = 100, .bottom = 100 }, .grid = .{ .columns = 2, .rows = 1, .slots = &plain_empty } }};
    try std.testing.expectEqual(@as(?usize, null), assignSlotMulti(&v1, "B", null));

    const leftovers_first = [_]Slot{ .{ .kind = .Empty, .fillOrder = "ColumnFirst_TTB_LTR" }, .{ .kind = .EveryoneElse }, .{ .kind = .Custom, .characters = &.{"A"} } };
    const v2 = [_]LayoutView{.{ .rect = .{ .left = 0, .top = 0, .right = 300, .bottom = 100 }, .grid = .{ .columns = 3, .rows = 1, .slots = &leftovers_first } }};
    try std.testing.expectEqual(@as(?usize, 0), assignSlotMulti(&v2, "B", null));
    try std.testing.expectEqual(@as(?usize, 2), assignSlotMulti(&v2, "A", null));
    try std.testing.expectEqualStrings("ColumnFirst_TTB_LTR", slotFillOrder(&v2, 0).?);
    try std.testing.expect(slotFillOrder(&v2, 1) == null);

    const everyone_first = [_]Slot{ .{ .kind = .EveryoneElse }, .{ .kind = .Empty, .fillOrder = "RowFirst_RTL_TTB" } };
    const v3 = [_]LayoutView{.{ .rect = .{ .left = 0, .top = 0, .right = 200, .bottom = 100 }, .grid = .{ .columns = 2, .rows = 1, .slots = &everyone_first } }};
    try std.testing.expectEqual(@as(?usize, 0), assignSlotMulti(&v3, "B", null));
}

test "layouts clone and parse without leaks" {
    const allocator = std.testing.allocator;
    const json =
        \\[{"displayId":"\\\\?\\DISPLAY#DEL","x":0,"y":0,"width":2560,"height":1392,"grid":{"columns":2,"rows":2,"fitToGrid":true,"slots":[{"kind":"EveryoneElse"},{"kind":"Empty","fillOrder":"RowFirst_LTR_BTT"}]}},
        \\ {"displayId":"\\\\.\\DISPLAY3","x":2560,"y":180,"width":1920,"height":1080,"useWorkArea":false,"grid":{"size":1,"slots":[{"kind":"Account","account":"acc_1"}]}}]
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const layouts = try layoutsFromJsonValue(allocator, parsed.value);
    defer freeLayouts(allocator, layouts);
    try std.testing.expectEqual(@as(usize, 2), layouts.len);
    try std.testing.expect(layouts[0].grid.fitToGrid);
    try std.testing.expect(layouts[1].isActive());
    try std.testing.expectEqualStrings("acc_1", layouts[1].grid.slots[0].account.?);
    const copy = try cloneLayouts(allocator, layouts);
    defer freeLayouts(allocator, copy);
    try std.testing.expectEqual(@as(i32, 2560), copy[1].x);
    try std.testing.expectEqualStrings("RowFirst_LTR_BTT", copy[0].grid.slots[1].fillOrder.?);
}

test "clone, fromJsonValue and deinit round-trip without leaks" {
    const allocator = std.testing.allocator;
    const json =
        \\{"size":3,"columns":0,"rows":0,"slots":[{"kind":"Client","characters":["FC Zoetrope"]},{"kind":"Account","account":"acc_1"},{"kind":"EveryoneElse"},{"kind":"Empty","extra":1}]}
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
