//! The config dialog's Display Config tab: a read-only snapshot of every connected display (resolution, refresh rate, scaling, arrangement, GPU, monitor model) plus an "Identify" overlay. Never changes display settings. Bound into config_dialog.zig only.
const std = @import("std");
const webui = @import("webui");
const win32 = @import("win32.zig");
const log = @import("log.zig");

const slog = log.scoped("displays");

var g_allocator: std.mem.Allocator = undefined;
var g_io: std.Io = undefined;

pub fn init(allocator: std.mem.Allocator, io: std.Io) void {
    g_allocator = allocator;
    g_io = io;
}

const Rect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,

    fn from(r: win32.RECT) Rect {
        return .{ .x = r.left, .y = r.top, .width = r.right - r.left, .height = r.bottom - r.top };
    }
};

pub const Display = struct {
    /// The N in Windows' \\.\DISPLAYN, used as the label here and on the Identify overlay.
    number: u32,
    /// Stable across reboots and re-plugging (the monitor's device path), so later per-display assignments can key on it; falls back to the GDI name.
    id: []const u8,
    gdiName: []const u8,
    /// Monitor model from its EDID (e.g. "DELL U2720Q"), else Windows' generic description.
    name: []const u8,
    gpu: ?[]const u8,
    primary: bool,
    /// Desktop position/size in physical pixels (the dialog is per-monitor DPI aware).
    bounds: Rect,
    /// Bounds minus the taskbar and other app bars.
    workArea: Rect,
    modeWidth: u32,
    modeHeight: u32,
    refreshHz: u32,
    bitsPerPixel: u32,
    /// 0, 90, 180 or 270.
    orientation: u32,
    scalePercent: u32,
    /// Largest mode the display reports (usually its native resolution).
    maxWidth: u32,
    maxHeight: u32,
    /// Highest refresh rate it supports at the current resolution.
    maxRefreshHz: u32,
};

const DisplaysResponse = struct {
    displays: []const Display,
    /// Bounding box of every display, for scaling the arrangement diagram.
    desktop: Rect,
};

/// UTF-16 buffer up to its first NUL, as UTF-8 (arena-owned); empty on bad input.
fn wideToUtf8(arena: std.mem.Allocator, wide: []const u16) []const u8 {
    const len = std.mem.indexOfScalar(u16, wide, 0) orelse wide.len;
    return std.unicode.utf16LeToUtf8Alloc(arena, wide[0..len]) catch "";
}

fn gdiNumber(gdi_name: []const u8) u32 {
    var start = gdi_name.len;
    while (start > 0 and std.ascii.isDigit(gdi_name[start - 1])) start -= 1;
    return std.fmt.parseInt(u32, gdi_name[start..], 10) catch 0;
}

const MonitorList = std.ArrayList(win32.HMONITOR);

const EnumContext = struct {
    arena: std.mem.Allocator,
    monitors: *MonitorList,
};

fn enumMonitorProc(monitor: win32.HMONITOR, _: ?win32.HDC, _: ?*win32.RECT, data: win32.LPARAM) callconv(.c) win32.BOOL {
    const ctx: *EnumContext = @ptrFromInt(@as(usize, @bitCast(data)));
    ctx.monitors.append(ctx.arena, monitor) catch return win32.FALSE;
    return win32.TRUE;
}

const TargetNames = struct {
    friendly: []const u8,
    device_path: []const u8,
};

/// GDI device name (\\.\DISPLAYn) -> monitor model and device path, via the DisplayConfig API. Empty on failure; callers fall back to EnumDisplayDevices.
fn queryTargetNames(arena: std.mem.Allocator) std.StringHashMap(TargetNames) {
    var map = std.StringHashMap(TargetNames).init(arena);

    var path_count: u32 = 0;
    var mode_count: u32 = 0;
    if (win32.GetDisplayConfigBufferSizes(win32.QDC_ONLY_ACTIVE_PATHS, &path_count, &mode_count) != 0) return map;
    const paths = arena.alloc(win32.DISPLAYCONFIG_PATH_INFO, path_count) catch return map;
    const modes = arena.alloc(win32.DISPLAYCONFIG_MODE_INFO, mode_count) catch return map;
    if (win32.QueryDisplayConfig(win32.QDC_ONLY_ACTIVE_PATHS, &path_count, paths.ptr, &mode_count, modes.ptr, null) != 0) {
        slog.warn("QueryDisplayConfig failed; monitor model names unavailable", .{});
        return map;
    }

    for (paths[0..path_count]) |path| {
        var source = std.mem.zeroes(win32.DISPLAYCONFIG_SOURCE_DEVICE_NAME);
        source.header = .{
            .type = win32.DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME,
            .size = @sizeOf(win32.DISPLAYCONFIG_SOURCE_DEVICE_NAME),
            .adapterId = path.sourceInfo.adapterId,
            .id = path.sourceInfo.id,
        };
        if (win32.DisplayConfigGetDeviceInfo(&source.header) != 0) continue;

        var target = std.mem.zeroes(win32.DISPLAYCONFIG_TARGET_DEVICE_NAME);
        target.header = .{
            .type = win32.DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME,
            .size = @sizeOf(win32.DISPLAYCONFIG_TARGET_DEVICE_NAME),
            .adapterId = path.targetInfo.adapterId,
            .id = path.targetInfo.id,
        };
        if (win32.DisplayConfigGetDeviceInfo(&target.header) != 0) continue;

        const gdi = wideToUtf8(arena, &source.viewGdiDeviceName);
        if (gdi.len == 0) continue;
        // Mirrored/cloned displays share a source; the first target wins.
        if (map.contains(gdi)) continue;
        map.put(gdi, .{
            .friendly = wideToUtf8(arena, &target.monitorFriendlyDeviceName),
            .device_path = wideToUtf8(arena, &target.monitorDevicePath),
        }) catch {};
    }
    return map;
}

/// GDI device name -> graphics adapter description (e.g. "NVIDIA GeForce RTX 4070").
fn queryAdapterNames(arena: std.mem.Allocator) std.StringHashMap([]const u8) {
    var map = std.StringHashMap([]const u8).init(arena);
    var i: win32.DWORD = 0;
    while (i < 64) : (i += 1) {
        var dev = std.mem.zeroes(win32.DISPLAY_DEVICEW);
        dev.cb = @sizeOf(win32.DISPLAY_DEVICEW);
        if (win32.EnumDisplayDevicesW(null, i, &dev, 0) == win32.FALSE) break;
        if (dev.StateFlags & win32.DISPLAY_DEVICE_ACTIVE == 0) continue;
        map.put(wideToUtf8(arena, &dev.DeviceName), wideToUtf8(arena, &dev.DeviceString)) catch {};
    }
    return map;
}

/// Windows' own description of the monitor on `gdi_name_w` (often "Generic PnP Monitor"), for when DisplayConfig has no EDID name.
fn genericMonitorName(arena: std.mem.Allocator, gdi_name_w: [*:0]const u16) ?[]const u8 {
    var dev = std.mem.zeroes(win32.DISPLAY_DEVICEW);
    dev.cb = @sizeOf(win32.DISPLAY_DEVICEW);
    if (win32.EnumDisplayDevicesW(gdi_name_w, 0, &dev, 0) == win32.FALSE) return null;
    const name = wideToUtf8(arena, &dev.DeviceString);
    return if (name.len > 0) name else null;
}

fn newDevMode() win32.DEVMODEW {
    var dm = std.mem.zeroes(win32.DEVMODEW);
    dm.dmSize = @sizeOf(win32.DEVMODEW);
    return dm;
}

/// Every connected, active display, ordered by display number. All strings are arena-owned.
pub fn enumerate(arena: std.mem.Allocator) ![]Display {
    var monitors: MonitorList = .empty;
    var ctx: EnumContext = .{ .arena = arena, .monitors = &monitors };
    _ = win32.EnumDisplayMonitors(null, null, enumMonitorProc, @bitCast(@intFromPtr(&ctx)));

    var targets = queryTargetNames(arena);
    var adapters = queryAdapterNames(arena);

    var out: std.ArrayList(Display) = .empty;
    for (monitors.items) |monitor| {
        var info = std.mem.zeroes(win32.MONITORINFOEXW);
        info.cbSize = @sizeOf(win32.MONITORINFOEXW);
        if (win32.GetMonitorInfoW(monitor, &info) == win32.FALSE) continue;

        const gdi_len = std.mem.indexOfScalar(u16, &info.szDevice, 0) orelse info.szDevice.len - 1;
        info.szDevice[gdi_len] = 0;
        const gdi_w: [*:0]const u16 = info.szDevice[0..gdi_len :0];
        const gdi_name = wideToUtf8(arena, &info.szDevice);

        var current = newDevMode();
        const have_mode = win32.EnumDisplaySettingsW(gdi_w, win32.ENUM_CURRENT_SETTINGS, &current) != win32.FALSE;
        const bounds = Rect.from(info.rcMonitor);
        const mode_w: u32 = if (have_mode) current.dmPelsWidth else @intCast(@max(bounds.width, 0));
        const mode_h: u32 = if (have_mode) current.dmPelsHeight else @intCast(@max(bounds.height, 0));

        var max_w: u32 = mode_w;
        var max_h: u32 = mode_h;
        var max_hz: u32 = if (have_mode) current.dmDisplayFrequency else 0;
        const portrait = mode_h > mode_w;
        var mode_index: win32.DWORD = 0;
        while (mode_index < 4096) : (mode_index += 1) {
            var dm = newDevMode();
            if (win32.EnumDisplaySettingsW(gdi_w, mode_index, &dm) == win32.FALSE) break;
            // The mode list may be reported in the panel's native orientation, so turn each mode to match the current one before comparing.
            const w = if (portrait == (dm.dmPelsHeight > dm.dmPelsWidth)) dm.dmPelsWidth else dm.dmPelsHeight;
            const h = if (portrait == (dm.dmPelsHeight > dm.dmPelsWidth)) dm.dmPelsHeight else dm.dmPelsWidth;
            if (@as(u64, w) * h > @as(u64, max_w) * max_h) {
                max_w = w;
                max_h = h;
            }
            if (w == mode_w and h == mode_h and dm.dmDisplayFrequency > max_hz) {
                max_hz = dm.dmDisplayFrequency;
            }
        }

        const target = targets.get(gdi_name);
        const friendly = if (target) |t| (if (t.friendly.len > 0) t.friendly else null) else null;
        const number = gdiNumber(gdi_name);

        try out.append(arena, .{
            .number = number,
            .id = if (target) |t| (if (t.device_path.len > 0) t.device_path else gdi_name) else gdi_name,
            .gdiName = gdi_name,
            .name = friendly orelse genericMonitorName(arena, gdi_w) orelse try std.fmt.allocPrint(arena, "Display {d}", .{number}),
            .gpu = adapters.get(gdi_name),
            .primary = info.dwFlags & win32.MONITORINFOF_PRIMARY != 0,
            .bounds = bounds,
            .workArea = Rect.from(info.rcWork),
            .modeWidth = mode_w,
            .modeHeight = mode_h,
            .refreshHz = if (have_mode) current.dmDisplayFrequency else 0,
            .bitsPerPixel = if (have_mode) current.dmBitsPerPel else 0,
            .orientation = if (have_mode) @as(u32, @min(current.dmDisplayOrientation, 3)) * 90 else 0,
            .scalePercent = win32.monitorDpi(monitor) * 100 / 96,
            .maxWidth = max_w,
            .maxHeight = max_h,
            .maxRefreshHz = max_hz,
        });
    }

    std.mem.sort(Display, out.items, {}, struct {
        fn lessThan(_: void, a: Display, b: Display) bool {
            return a.number < b.number;
        }
    }.lessThan);
    return out.items;
}

fn desktopBounds(displays: []const Display) Rect {
    if (displays.len == 0) return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    var left: i32 = std.math.maxInt(i32);
    var top: i32 = std.math.maxInt(i32);
    var right: i32 = std.math.minInt(i32);
    var bottom: i32 = std.math.minInt(i32);
    for (displays) |d| {
        left = @min(left, d.bounds.x);
        top = @min(top, d.bounds.y);
        right = @max(right, d.bounds.x + d.bounds.width);
        bottom = @max(bottom, d.bounds.y + d.bounds.height);
    }
    return .{ .x = left, .y = top, .width = right - left, .height = bottom - top };
}

/// Response: DisplaysResponse JSON.
pub fn getDisplays(e: *webui.Event) void {
    var arena_state = std.heap.ArenaAllocator.init(g_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const displays = enumerate(arena) catch |err| {
        slog.warn("Failed to enumerate displays: {}", .{err});
        e.returnString("{\"displays\":[],\"desktop\":{\"x\":0,\"y\":0,\"width\":0,\"height\":0}}");
        return;
    };
    const json = std.json.Stringify.valueAlloc(arena, DisplaysResponse{ .displays = displays, .desktop = desktopBounds(displays) }, .{}) catch {
        e.returnString("{\"displays\":[],\"desktop\":{\"x\":0,\"y\":0,\"width\":0,\"height\":0}}");
        return;
    };
    const json_z = arena.dupeZ(u8, json) catch {
        e.returnString("{\"displays\":[],\"desktop\":{\"x\":0,\"y\":0,\"width\":0,\"height\":0}}");
        return;
    };
    e.returnString(json_z);
}

// ---- Identify overlay: a big number in the corner of each display for a few seconds ----

const IDENTIFY_CLASS = "EVEMajIdentifyDisplay";
const IDENTIFY_SIZE = 200;
const IDENTIFY_MARGIN = 48;
const IDENTIFY_DURATION_MS = 3000;
const IDENTIFY_TIMER_ID = 1;
/// The dialog's accent (#d9a441) and background (#0b0c0d) as COLORREF (0x00BBGGRR).
const IDENTIFY_TEXT_COLOR: win32.DWORD = 0x0041A4D9;
const IDENTIFY_BG_COLOR: win32.DWORD = 0x000D0C0B;

const IdentifyTarget = struct { number: u32, x: i32, y: i32 };

/// Only one overlay set at a time; a second click while it's up is ignored.
var g_identify_running = std.atomic.Value(bool).init(false);
/// Windows still open on the identify thread; owned by that thread only.
var g_identify_open: u32 = 0;

/// Shows the overlay without blocking the caller. Response: {success}.
pub fn identifyDisplays(e: *webui.Event) void {
    if (g_identify_running.swap(true, .acq_rel)) {
        e.returnString("{\"success\":true}");
        return;
    }

    var arena_state = std.heap.ArenaAllocator.init(g_allocator);
    defer arena_state.deinit();
    const displays = enumerate(arena_state.allocator()) catch &.{};

    const targets = g_allocator.alloc(IdentifyTarget, displays.len) catch {
        g_identify_running.store(false, .release);
        e.returnString("{\"success\":false}");
        return;
    };
    for (displays, 0..) |d, i| {
        targets[i] = .{ .number = d.number, .x = d.bounds.x + IDENTIFY_MARGIN, .y = d.bounds.y + IDENTIFY_MARGIN };
    }

    const thread = std.Thread.spawn(.{}, identifyThread, .{targets}) catch |err| {
        slog.warn("Failed to start identify thread: {}", .{err});
        g_allocator.free(targets);
        g_identify_running.store(false, .release);
        e.returnString("{\"success\":false}");
        return;
    };
    thread.detach();
    e.returnString("{\"success\":true}");
}

var g_identify_class_registered = false;

/// Owns its windows and message loop, so it never touches webui's thread.
fn identifyThread(targets: []IdentifyTarget) void {
    defer g_allocator.free(targets);
    defer g_identify_running.store(false, .release);

    const instance = win32.GetModuleHandleA(null) orelse return;
    if (!g_identify_class_registered) {
        const wc = win32.WNDCLASSEXA{
            .cbSize = @sizeOf(win32.WNDCLASSEXA),
            .style = 0,
            .lpfnWndProc = identifyWndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = instance,
            .hIcon = null,
            .hCursor = null,
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = IDENTIFY_CLASS,
            .hIconSm = null,
        };
        if (win32.RegisterClassExA(&wc) == 0) {
            slog.warn("Failed to register identify window class", .{});
            return;
        }
        g_identify_class_registered = true;
    }

    g_identify_open = 0;
    for (targets) |t| {
        const hwnd = win32.CreateWindowExA(
            win32.WS_EX_TOPMOST | win32.WS_EX_TOOLWINDOW | win32.WS_EX_NOACTIVATE,
            IDENTIFY_CLASS,
            "",
            win32.WS_POPUP,
            t.x,
            t.y,
            IDENTIFY_SIZE,
            IDENTIFY_SIZE,
            null,
            null,
            instance,
            null,
        ) orelse continue;
        _ = win32.SetWindowLongPtrA(hwnd, win32.GWLP_USERDATA, @intCast(t.number));
        _ = win32.ShowWindow(hwnd, win32.SW_SHOWNOACTIVATE);
        _ = win32.SetTimer(hwnd, IDENTIFY_TIMER_ID, IDENTIFY_DURATION_MS, null);
        g_identify_open += 1;
    }
    if (g_identify_open == 0) return;

    var msg: win32.MSG = undefined;
    while (win32.GetMessageA(&msg, null, 0, 0) > 0) {
        _ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessageA(&msg);
    }
}

fn identifyWndProc(hwnd: win32.HWND, msg: win32.UINT, wparam: win32.WPARAM, lparam: win32.LPARAM) callconv(.c) win32.LRESULT {
    switch (msg) {
        win32.WM_PAINT => {
            var ps: win32.PAINTSTRUCT = undefined;
            const hdc = win32.BeginPaint(hwnd, &ps) orelse return 0;
            defer _ = win32.EndPaint(hwnd, &ps);

            var rect: win32.RECT = undefined;
            _ = win32.GetClientRect(hwnd, &rect);
            if (win32.CreateSolidBrush(IDENTIFY_BG_COLOR)) |bg| {
                _ = win32.FillRect(hdc, &rect, bg);
                _ = win32.DeleteObject(bg);
            }
            if (win32.CreateSolidBrush(IDENTIFY_TEXT_COLOR)) |accent| {
                // 4px accent frame, drawn as four strips.
                const t = 4;
                const strips = [_]win32.RECT{
                    .{ .left = 0, .top = 0, .right = rect.right, .bottom = t },
                    .{ .left = 0, .top = rect.bottom - t, .right = rect.right, .bottom = rect.bottom },
                    .{ .left = 0, .top = 0, .right = t, .bottom = rect.bottom },
                    .{ .left = rect.right - t, .top = 0, .right = rect.right, .bottom = rect.bottom },
                };
                for (&strips) |*s| _ = win32.FillRect(hdc, s, accent);
                _ = win32.DeleteObject(accent);
            }

            const number: u32 = @intCast(win32.GetWindowLongPtrA(hwnd, win32.GWLP_USERDATA));
            var text_buf: [12]u8 = undefined;
            const text = std.fmt.bufPrint(&text_buf, "{d}", .{number}) catch "?";
            var wide: [12]u16 = undefined;
            const wide_len = std.unicode.utf8ToUtf16Le(&wide, text) catch 0;

            const font = win32.CreateFontA(150, 0, 0, 0, win32.FW_BOLD, 0, 0, 0, win32.DEFAULT_CHARSET, 0, 0, win32.ANTIALIASED_QUALITY, 0, "Segoe UI");
            const old_font = if (font) |f| win32.SelectObject(hdc, f) else null;
            _ = win32.SetBkMode(hdc, win32.TRANSPARENT);
            _ = win32.SetTextColor(hdc, IDENTIFY_TEXT_COLOR);
            _ = win32.DrawTextW(hdc, &wide, @intCast(wide_len), &rect, win32.DT_CENTER | win32.DT_VCENTER | win32.DT_SINGLELINE);
            if (old_font) |o| _ = win32.SelectObject(hdc, o);
            if (font) |f| _ = win32.DeleteObject(f);
            return 0;
        },
        win32.WM_TIMER => {
            _ = win32.KillTimer(hwnd, IDENTIFY_TIMER_ID);
            _ = win32.DestroyWindow(hwnd);
            return 0;
        },
        win32.WM_DESTROY => {
            if (g_identify_open > 0) g_identify_open -= 1;
            if (g_identify_open == 0) win32.PostQuitMessage(0);
            return 0;
        },
        else => return win32.DefWindowProcA(hwnd, msg, wparam, lparam),
    }
}

test "gdiNumber parses the trailing display number" {
    try std.testing.expectEqual(@as(u32, 1), gdiNumber("\\\\.\\DISPLAY1"));
    try std.testing.expectEqual(@as(u32, 12), gdiNumber("\\\\.\\DISPLAY12"));
    try std.testing.expectEqual(@as(u32, 0), gdiNumber("weird"));
}
