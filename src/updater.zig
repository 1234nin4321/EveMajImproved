//! The config dialog's in-place updater: check GitHub for a newer release, download and stage its portable zip, then hand off to a PowerShell script that swaps the files once both processes have exited. Bound into config_dialog.zig only.
const std = @import("std");
const webui = @import("webui");
const win32 = @import("win32.zig");
const config_mod = @import("config.zig");
const update = @import("update.zig");
const update_stage = @import("update_stage.zig");
const build_options = @import("build_options");
const log = @import("log.zig");

const slog = log.scoped("updater");

var g_allocator: std.mem.Allocator = undefined;
var g_io: std.Io = undefined;
var g_find_main_app: *const fn () ?win32.HWND = undefined;

/// webui may run handlers on its own threads, so the check/download/install state is shared under this lock.
var g_mutex: std.Io.Mutex = .init;
/// Newest release found by the last successful check (g_allocator-owned).
var g_pending: ?update.UpdateInfo = null;
/// Set once that release's zip is downloaded, verified and unpacked (g_allocator-owned).
var g_staged_dir: ?[]u8 = null;
var g_staged_version: ?[]u8 = null;

pub fn init(allocator: std.mem.Allocator, io: std.Io, find_main_app: *const fn () ?win32.HWND) void {
    g_allocator = allocator;
    g_io = io;
    g_find_main_app = find_main_app;
}

/// %TEMP%\EVE-Maj-Update - holds the downloaded zip, the staged files, the install script and its log.
fn workDir(allocator: std.mem.Allocator) ![]u8 {
    const env = config_mod.environMap();
    const temp = env.get("TEMP") orelse env.get("TMP") orelse return error.NoTempDir;
    return std.fs.path.join(allocator, &[_][]const u8{ temp, "EVE-Maj-Update" });
}

fn clearStagedLocked() void {
    if (g_staged_dir) |d| g_allocator.free(d);
    if (g_staged_version) |v| g_allocator.free(v);
    g_staged_dir = null;
    g_staged_version = null;
}

fn returnJson(e: *webui.Event, arena: std.mem.Allocator, value: anytype) void {
    const json = std.json.Stringify.valueAlloc(arena, value, .{}) catch {
        e.returnString("{\"success\":false,\"error\":\"internal\"}");
        return;
    };
    const json_z = arena.dupeZ(u8, json) catch {
        e.returnString("{\"success\":false,\"error\":\"internal\"}");
        return;
    };
    e.returnString(json_z);
}

fn returnError(e: *webui.Event, code: []const u8) void {
    var buf: [128]u8 = undefined;
    const json = std.fmt.bufPrintZ(&buf, "{{\"success\":false,\"error\":\"{s}\"}}", .{code}) catch "{\"success\":false,\"error\":\"internal\"}";
    e.returnString(json);
}

const CheckResponse = struct {
    success: bool = true,
    available: bool,
    currentVersion: []const u8,
    version: ?[]const u8 = null,
    url: ?[]const u8 = null,
    notes: ?[]const u8 = null,
    assetName: ?[]const u8 = null,
    assetSize: u64 = 0,
    /// Whether GitHub published a SHA-256 the download will be checked against.
    hasDigest: bool = false,
    /// True when this release is already downloaded and ready to install.
    staged: bool = false,
};

/// Queries GitHub releases on demand (not just at startup). Response: CheckResponse JSON, or {success:false,error}.
pub fn checkForUpdateNow(e: *webui.Event) void {
    var arena_state = std.heap.ArenaAllocator.init(g_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var checker = update.UpdateChecker.init(g_allocator);
    const maybe_info = checker.checkForUpdates() catch |err| {
        slog.warn("Manual update check failed: {}", .{err});
        returnError(e, "check_failed");
        return;
    };

    const info = maybe_info orelse {
        if (g_mutex.lock(g_io)) |_| {
            defer g_mutex.unlock(g_io);
            if (g_pending) |*p| p.deinit(g_allocator);
            g_pending = null;
        } else |_| {}
        returnJson(e, arena, CheckResponse{ .available = false, .currentVersion = build_options.version });
        return;
    };

    update.g_update_status.set(g_allocator, info.version, info.url, info.notes) catch |err| {
        slog.warn("Failed to store update status: {}", .{err});
    };

    g_mutex.lock(g_io) catch {
        var tmp = info;
        tmp.deinit(g_allocator);
        returnError(e, "internal");
        return;
    };
    defer g_mutex.unlock(g_io);

    if (g_pending) |*p| p.deinit(g_allocator);
    g_pending = info;
    // A previously staged download only counts if it's this same release.
    if (g_staged_version) |v| {
        if (!std.mem.eql(u8, v, info.version)) clearStagedLocked();
    }

    returnJson(e, arena, CheckResponse{
        .available = true,
        .currentVersion = build_options.version,
        .version = info.version,
        .url = info.url,
        .notes = info.notes,
        .assetName = info.asset_name,
        .assetSize = info.asset_size,
        .hasDigest = info.asset_digest != null,
        .staged = g_staged_dir != null,
    });
}

/// Downloads, verifies and unpacks the release found by the last check. Response: {success, version} or {success:false,error}.
pub fn downloadUpdate(e: *webui.Event) void {
    var arena_state = std.heap.ArenaAllocator.init(g_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Copied out so the lock isn't held across the network download.
    var asset: update_stage.Asset = undefined;
    var version: []const u8 = undefined;
    {
        g_mutex.lock(g_io) catch {
            returnError(e, "internal");
            return;
        };
        defer g_mutex.unlock(g_io);
        const pending = g_pending orelse {
            returnError(e, "no_update");
            return;
        };
        const url = pending.asset_url orelse {
            returnError(e, "no_asset");
            return;
        };
        asset = .{
            .url = arena.dupe(u8, url) catch return returnError(e, "internal"),
            .name = arena.dupe(u8, pending.asset_name orelse "update.zip") catch return returnError(e, "internal"),
            .size = pending.asset_size,
            .digest = if (pending.asset_digest) |d| (arena.dupe(u8, d) catch return returnError(e, "internal")) else null,
        };
        version = arena.dupe(u8, pending.version) catch return returnError(e, "internal");
    }

    const work_dir = workDir(arena) catch {
        returnError(e, "no_temp");
        return;
    };

    slog.info("Downloading update {s} from {s}", .{ version, asset.url });
    const staged = update_stage.downloadAndStage(g_allocator, g_io, asset, work_dir) catch |err| {
        slog.warn("Update download/staging failed: {}", .{err});
        returnError(e, switch (err) {
            error.DownloadFailed => "download_failed",
            error.SizeMismatch, error.ChecksumMismatch, error.UnsupportedDigest => "verify_failed",
            error.BadArchive, error.MissingRequiredFile => "bad_archive",
            else => "stage_failed",
        });
        return;
    };

    g_mutex.lock(g_io) catch {
        g_allocator.free(staged);
        returnError(e, "internal");
        return;
    };
    defer g_mutex.unlock(g_io);
    clearStagedLocked();
    g_staged_dir = staged;
    g_staged_version = g_allocator.dupe(u8, version) catch null;

    slog.info("Update {s} staged at {s}", .{ version, staged });
    returnJson(e, arena, .{ .success = true, .version = version });
}

/// Launches the install script for the staged release and asks the main app to exit; the dialog closes itself once this returns success. Response: {success} or {success:false,error}.
pub fn installUpdate(e: *webui.Event) void {
    var arena_state = std.heap.ArenaAllocator.init(g_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const staged_dir = blk: {
        g_mutex.lock(g_io) catch return returnError(e, "internal");
        defer g_mutex.unlock(g_io);
        const d = g_staged_dir orelse return returnError(e, "not_downloaded");
        break :blk arena.dupe(u8, d) catch return returnError(e, "internal");
    };

    const install_dir = std.process.executableDirPathAlloc(g_io, arena) catch |err| {
        slog.err("Failed to resolve install directory: {}", .{err});
        returnError(e, "internal");
        return;
    };

    // Fail here, while the app is still running, rather than leaving the script to discover it (e.g. an install under Program Files).
    if (!isWritable(arena, install_dir)) {
        slog.warn("Install directory is not writable: {s}", .{install_dir});
        returnError(e, "not_writable");
        return;
    }

    const work_dir = workDir(arena) catch return returnError(e, "no_temp");
    const main_hwnd = g_find_main_app();
    var main_pid: win32.DWORD = 0;
    if (main_hwnd) |hwnd| _ = win32.GetWindowThreadProcessId(hwnd, &main_pid);

    const script = update_stage.renderInstallScript(arena, .{
        .staged_dir = staged_dir,
        .install_dir = install_dir,
        .log_path = std.fs.path.join(arena, &[_][]const u8{ work_dir, "install.log" }) catch return returnError(e, "internal"),
        .config_pid = win32.GetCurrentProcessId(),
        .main_pid = main_pid,
    }) catch return returnError(e, "internal");

    const script_path = std.fs.path.join(arena, &[_][]const u8{ work_dir, "install.ps1" }) catch return returnError(e, "internal");
    std.Io.Dir.cwd().writeFile(g_io, .{ .sub_path = script_path, .data = script }) catch |err| {
        slog.err("Failed to write install script: {}", .{err});
        returnError(e, "script_failed");
        return;
    };

    if (!launchScript(arena, script_path)) {
        returnError(e, "launch_failed");
        return;
    }

    slog.info("Install script launched (main app pid {}); closing for update", .{main_pid});
    // Same command as the tray's Exit item, so the main app shuts down through its normal path.
    if (main_hwnd) |hwnd| _ = win32.PostMessageA(hwnd, win32.WM_COMMAND, win32.IDM_EXIT, 0);
    e.returnString("{\"success\":true}");
}

fn isWritable(arena: std.mem.Allocator, dir_path: []const u8) bool {
    const probe = std.fs.path.join(arena, &[_][]const u8{ dir_path, ".update-write-test" }) catch return false;
    std.Io.Dir.cwd().writeFile(g_io, .{ .sub_path = probe, .data = "" }) catch return false;
    std.Io.Dir.cwd().deleteFile(g_io, probe) catch {};
    return true;
}

fn launchScript(arena: std.mem.Allocator, script_path: []const u8) bool {
    const params = std.fmt.allocPrint(arena, "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"{s}\"", .{script_path}) catch return false;
    const params_w = std.unicode.utf8ToUtf16LeAllocZ(arena, params) catch return false;
    const result = win32.ShellExecuteW(
        null,
        std.unicode.utf8ToUtf16LeStringLiteral("open"),
        std.unicode.utf8ToUtf16LeStringLiteral("powershell.exe"),
        params_w,
        null,
        win32.SW_HIDE,
    );
    if (@intFromPtr(result) <= 32) {
        slog.err("Failed to launch install script (ShellExecuteW returned {})", .{@intFromPtr(result)});
        return false;
    }
    return true;
}
