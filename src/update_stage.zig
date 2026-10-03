//! Platform-neutral half of the config dialog's in-place updater: download a release zip, verify it, unpack it to a staging folder, and render the PowerShell script that swaps the files in. updater.zig owns the Windows/webui side.
const std = @import("std");
const http_client = @import("http_client.zig");
const log = @import("log.zig");

const slog = log.scoped("update_stage");

/// Release zips are ~5 MB; anything wildly larger is not one of ours.
const MAX_DOWNLOAD_BYTES: usize = 64 * 1024 * 1024;

/// Files a release zip must contain to be accepted - guards against installing an unrelated zip attached to a release.
pub const REQUIRED_FILES = [_][]const u8{ "eve-maj-preview.exe", "config.exe" };

pub const Asset = struct {
    url: []const u8,
    name: []const u8,
    /// 0 when GitHub didn't report one.
    size: u64,
    /// GitHub's "sha256:<hex>" digest, if the release has one.
    digest: ?[]const u8,
};

pub const StageError = error{
    DownloadFailed,
    SizeMismatch,
    ChecksumMismatch,
    UnsupportedDigest,
    MissingRequiredFile,
    BadArchive,
};

/// Downloads `asset` into `work_dir`, verifies it, and extracts it to `<work_dir>/staged` (replacing any previous staging). Returns the staged directory path (caller frees).
pub fn downloadAndStage(allocator: std.mem.Allocator, io: std.Io, asset: Asset, work_dir: []const u8) ![]u8 {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    const body = http_client.fetch(allocator, &client, asset.url, .{}) orelse return StageError.DownloadFailed;
    defer allocator.free(body);
    if (body.len > MAX_DOWNLOAD_BYTES) return StageError.DownloadFailed;

    try verifyDownload(body, asset);
    return try stageZip(allocator, io, body, std.fs.path.basename(asset.name), work_dir);
}

/// Size and SHA-256 checks against what the GitHub release reported. A missing digest is allowed (older releases predate GitHub publishing them); a present one must match.
pub fn verifyDownload(body: []const u8, asset: Asset) StageError!void {
    if (asset.size != 0 and body.len != asset.size) {
        slog.warn("Update download size mismatch: got {}, expected {}", .{ body.len, asset.size });
        return StageError.SizeMismatch;
    }
    const digest = asset.digest orelse {
        slog.warn("Release asset has no published digest; skipping checksum verification", .{});
        return;
    };
    const prefix = "sha256:";
    if (!std.ascii.startsWithIgnoreCase(digest, prefix)) return StageError.UnsupportedDigest;
    const expected_hex = digest[prefix.len..];
    if (expected_hex.len != 64) return StageError.UnsupportedDigest;

    var actual: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(body, &actual, .{});
    const actual_hex = std.fmt.bytesToHex(actual, .lower);
    if (!std.ascii.eqlIgnoreCase(&actual_hex, expected_hex)) {
        slog.warn("Update checksum mismatch: got {s}, expected {s}", .{ &actual_hex, expected_hex });
        return StageError.ChecksumMismatch;
    }
}

/// Writes the zip to `work_dir`, wipes and re-extracts `<work_dir>/staged`, and checks REQUIRED_FILES landed. Returns the staged path (caller frees).
pub fn stageZip(allocator: std.mem.Allocator, io: std.Io, zip_bytes: []const u8, zip_name: []const u8, work_dir: []const u8) ![]u8 {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, work_dir);
    var work = try cwd.openDir(io, work_dir, .{});
    defer work.close(io);

    try work.writeFile(io, .{ .sub_path = zip_name, .data = zip_bytes });

    try work.deleteTree(io, "staged");
    var staged = try work.createDirPathOpen(io, "staged", .{});
    defer staged.close(io);

    {
        var zip_file = try work.openFile(io, zip_name, .{});
        defer zip_file.close(io);
        var read_buf: [16 * 1024]u8 = undefined;
        var reader = zip_file.reader(io, &read_buf);
        // std.zip rejects absolute paths and ".." components, so a hostile archive can't write outside staged/.
        std.zip.extract(staged, &reader, .{ .allow_backslashes = true }) catch |err| {
            slog.warn("Failed to extract update zip: {}", .{err});
            return StageError.BadArchive;
        };
    }

    for (REQUIRED_FILES) |name| {
        staged.access(io, name, .{}) catch {
            slog.warn("Update zip is missing required file '{s}'", .{name});
            return StageError.MissingRequiredFile;
        };
    }

    return try std.fs.path.join(allocator, &[_][]const u8{ work_dir, "staged" });
}

pub const ScriptParams = struct {
    staged_dir: []const u8,
    install_dir: []const u8,
    log_path: []const u8,
    config_pid: u32,
    /// 0 when the main app isn't running (then it isn't restarted either).
    main_pid: u32,
};

/// PowerShell that waits for both processes to exit, backs up then overwrites the install folder's files from staging (restoring the backup on failure), and relaunches. Values are spliced in as single-quoted literals, so only `'` needs escaping.
pub fn renderInstallScript(allocator: std.mem.Allocator, p: ScriptParams) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;

    // UTF-8 BOM: Windows PowerShell 5.1 reads a BOM-less script as the ANSI code page, which would mangle non-ASCII paths.
    try w.writeAll("\xEF\xBB\xBF");
    try w.writeAll("$Staged = ");
    try writePsLiteral(w, p.staged_dir);
    try w.writeAll("\r\n$InstallDir = ");
    try writePsLiteral(w, p.install_dir);
    try w.writeAll("\r\n$Log = ");
    try writePsLiteral(w, p.log_path);
    try w.print("\r\n$ConfigPid = {d}\r\n$MainPid = {d}\r\n", .{ p.config_pid, p.main_pid });
    try w.writeAll(install_script_body);
    return try out.toOwnedSlice();
}

fn writePsLiteral(w: *std.Io.Writer, value: []const u8) !void {
    try w.writeByte('\'');
    for (value) |c| {
        if (c == '\'') try w.writeByte('\'');
        try w.writeByte(c);
    }
    try w.writeByte('\'');
}

const install_script_body =
    \\$ErrorActionPreference = 'Stop'
    \\function Write-Log([string]$m) {
    \\    try { Add-Content -LiteralPath $Log -Value ("{0:u} {1}" -f (Get-Date), $m) -Encoding UTF8 } catch {}
    \\}
    \\function Wait-Exit([int]$procId, [int]$seconds) {
    \\    if ($procId -le 0) { return $true }
    \\    $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
    \\    if (-not $p) { return $true }
    \\    return $p.WaitForExit($seconds * 1000)
    \\}
    \\function Copy-WithRetry([string]$src, [string]$dest) {
    \\    $parent = Split-Path -Parent $dest
    \\    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    \\    for ($i = 0; ; $i++) {
    \\        try { Copy-Item -LiteralPath $src -Destination $dest -Force; return }
    \\        catch { if ($i -ge 20) { throw }; Start-Sleep -Milliseconds 500 }
    \\    }
    \\}
    \\
    \\Write-Log "Update started: '$Staged' -> '$InstallDir'"
    \\if (-not (Wait-Exit $ConfigPid 120)) {
    \\    Write-Log 'Configuration window did not close; update aborted, nothing changed.'
    \\    exit 1
    \\}
    \\if (-not (Wait-Exit $MainPid 30)) {
    \\    Write-Log 'Main app did not exit in time; stopping it.'
    \\    Stop-Process -Id $MainPid -Force -ErrorAction SilentlyContinue
    \\    Start-Sleep -Seconds 1
    \\}
    \\
    \\$StagedFull = (Get-Item -LiteralPath $Staged).FullName.TrimEnd('\')
    \\$Backup = Join-Path $InstallDir 'update-backup'
    \\$files = @(Get-ChildItem -LiteralPath $StagedFull -Recurse -File)
    \\$ok = $false
    \\try {
    \\    if (Test-Path -LiteralPath $Backup) { Remove-Item -LiteralPath $Backup -Recurse -Force }
    \\    New-Item -ItemType Directory -Force -Path $Backup | Out-Null
    \\    foreach ($f in $files) {
    \\        $rel = $f.FullName.Substring($StagedFull.Length).TrimStart('\')
    \\        $dest = Join-Path $InstallDir $rel
    \\        if (Test-Path -LiteralPath $dest) { Copy-WithRetry $dest (Join-Path $Backup $rel) }
    \\    }
    \\    foreach ($f in $files) {
    \\        $rel = $f.FullName.Substring($StagedFull.Length).TrimStart('\')
    \\        Copy-WithRetry $f.FullName (Join-Path $InstallDir $rel)
    \\    }
    \\    $ok = $true
    \\    Write-Log "Installed $($files.Count) files. Previous files kept in '$Backup'."
    \\} catch {
    \\    Write-Log "Install failed: $_ - restoring previous files."
    \\    try {
    \\        $BackupFull = (Get-Item -LiteralPath $Backup).FullName.TrimEnd('\')
    \\        foreach ($b in @(Get-ChildItem -LiteralPath $BackupFull -Recurse -File)) {
    \\            $rel = $b.FullName.Substring($BackupFull.Length).TrimStart('\')
    \\            Copy-WithRetry $b.FullName (Join-Path $InstallDir $rel)
    \\        }
    \\        Write-Log 'Previous files restored.'
    \\    } catch { Write-Log "Restore failed: $_" }
    \\}
    \\
    \\try {
    \\    if ($MainPid -gt 0) {
    \\        Start-Process -FilePath (Join-Path $InstallDir 'eve-maj-preview.exe') -WorkingDirectory $InstallDir
    \\    }
    \\    Start-Process -FilePath (Join-Path $InstallDir 'config.exe') -WorkingDirectory $InstallDir
    \\} catch { Write-Log "Relaunch failed: $_" }
    \\if ($ok) { exit 0 } else { exit 1 }
    \\
;

test "verifyDownload checks size and sha256" {
    const body = "hello";
    // sha256("hello")
    const good = "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824";
    try verifyDownload(body, .{ .url = "", .name = "", .size = 5, .digest = good });
    try verifyDownload(body, .{ .url = "", .name = "", .size = 0, .digest = null });
    try std.testing.expectError(StageError.SizeMismatch, verifyDownload(body, .{ .url = "", .name = "", .size = 6, .digest = good }));
    try std.testing.expectError(StageError.ChecksumMismatch, verifyDownload(body, .{ .url = "", .name = "", .size = 5, .digest = "sha256:" ++ "0" ** 64 }));
    try std.testing.expectError(StageError.UnsupportedDigest, verifyDownload(body, .{ .url = "", .name = "", .size = 5, .digest = "md5:abc" }));
}

test "renderInstallScript escapes single quotes" {
    const script = try renderInstallScript(std.testing.allocator, .{
        .staged_dir = "C:\\Users\\O'Neil\\staged",
        .install_dir = "C:\\EVE",
        .log_path = "C:\\log.txt",
        .config_pid = 12,
        .main_pid = 0,
    });
    defer std.testing.allocator.free(script);
    try std.testing.expect(std.mem.indexOf(u8, script, "$Staged = 'C:\\Users\\O''Neil\\staged'") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "$ConfigPid = 12") != null);
}
