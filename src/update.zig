const std = @import("std");
const win32 = @import("win32.zig");
const http_client = @import("http_client.zig");
const log = @import("log.zig");
const build_options = @import("build_options");
const slog = log.scoped("update");

var g_io: std.Io = undefined;

/// GitHub "owner/name" that update checks and downloads come from.
pub const REPO = "1234nin4321/EveMajImproved";

/// Must be called once before any update-checking function is used.
pub fn setIo(io: std.Io) void {
    g_io = io;
}

/// Mutex-guarded holder for the latest known update result, written by the background check thread and read by the tray menu on the main thread.
pub const UpdateStatus = struct {
    mutex: std.Io.Mutex = .init,
    version: ?[]const u8 = null,
    url: ?[]const u8 = null,
    /// Combined release notes for every release newer than the installed version (each prefixed with its tag name); null if none had notes.
    notes: ?[]const u8 = null,
    allocator: ?std.mem.Allocator = null,

    /// Stores a fresh update result, freeing any previous one first; copies `version`/`url`/`notes` rather than taking ownership of the passed-in slices.
    pub fn set(self: *UpdateStatus, allocator: std.mem.Allocator, version: []const u8, url: []const u8, notes: ?[]const u8) !void {
        const version_copy = try allocator.dupe(u8, version);
        errdefer allocator.free(version_copy);
        const url_copy = try allocator.dupe(u8, url);
        errdefer allocator.free(url_copy);
        const notes_copy = if (notes) |n| try allocator.dupe(u8, n) else null;
        errdefer if (notes_copy) |n| allocator.free(n);

        try self.mutex.lock(g_io);
        defer self.mutex.unlock(g_io);
        self.freeLocked();
        self.version = version_copy;
        self.url = url_copy;
        self.notes = notes_copy;
        self.allocator = allocator;
    }

    fn freeLocked(self: *UpdateStatus) void {
        const allocator = self.allocator orelse return;
        if (self.version) |v| allocator.free(v);
        if (self.url) |u| allocator.free(u);
        if (self.notes) |n| allocator.free(n);
    }

    pub fn deinit(self: *UpdateStatus) void {
        self.mutex.lock(g_io) catch return;
        defer self.mutex.unlock(g_io);
        self.freeLocked();
        self.version = null;
        self.url = null;
        self.notes = null;
    }

    pub fn isAvailable(self: *UpdateStatus) bool {
        self.mutex.lock(g_io) catch |err| {
            slog.warn("Failed to lock update status mutex: {}", .{err});
            return false;
        };
        defer self.mutex.unlock(g_io);
        return self.version != null;
    }

    /// Copies the stored release URL, null-terminated, into `buf`; returns null if no update is available or the URL doesn't fit.
    pub fn copyUrlZ(self: *UpdateStatus, buf: []u8) ?[:0]const u8 {
        self.mutex.lock(g_io) catch |err| {
            slog.warn("Failed to lock update status mutex: {}", .{err});
            return null;
        };
        defer self.mutex.unlock(g_io);
        const url = self.url orelse return null;
        if (url.len >= buf.len) return null;
        @memcpy(buf[0..url.len], url);
        buf[url.len] = 0;
        return buf[0..url.len :0];
    }

    /// Copies the stored latest version, null-terminated, into `buf`; returns null if no update is available or the version doesn't fit.
    pub fn copyVersionZ(self: *UpdateStatus, buf: []u8) ?[:0]const u8 {
        self.mutex.lock(g_io) catch |err| {
            slog.warn("Failed to lock update status mutex: {}", .{err});
            return null;
        };
        defer self.mutex.unlock(g_io);
        const version = self.version orelse return null;
        if (version.len >= buf.len) return null;
        @memcpy(buf[0..version.len], version);
        buf[version.len] = 0;
        return buf[0..version.len :0];
    }

    /// Returns an allocator-owned copy of the stored release notes (caller frees); null if unavailable, since notes are unbounded unlike the other fixed-buffer fields.
    pub fn dupeNotes(self: *UpdateStatus, allocator: std.mem.Allocator) ?[]const u8 {
        self.mutex.lock(g_io) catch |err| {
            slog.warn("Failed to lock update status mutex: {}", .{err});
            return null;
        };
        defer self.mutex.unlock(g_io);
        const notes = self.notes orelse return null;
        return allocator.dupe(u8, notes) catch null;
    }
};

/// Global update state (see UpdateStatus doc comment).
pub var g_update_status: UpdateStatus = .{};

pub const UpdateChecker = struct {
    allocator: std.mem.Allocator,
    current_version: []const u8,

    pub fn init(allocator: std.mem.Allocator) UpdateChecker {
        return UpdateChecker{
            .allocator = allocator,
            .current_version = build_options.version,
        };
    }

    pub fn deinit(self: *UpdateChecker) void {
        _ = self;
        g_update_status.deinit();
    }

    /// Strips a leading "v" (GitHub tag convention) and parses the rest as semver.
    fn parseTagVersion(tag: []const u8) ?std.SemanticVersion {
        const normalized = if (std.mem.startsWith(u8, tag, "v")) tag[1..] else tag;
        return std.SemanticVersion.parse(normalized) catch null;
    }

    pub fn checkForUpdates(self: *UpdateChecker) !?UpdateInfo {
        slog.info("Checking for updates (current: {s})", .{self.current_version});

        var client: std.http.Client = .{ .allocator = self.allocator, .io = g_io };
        defer client.deinit();

        // per_page=100 covers skipping many releases at once; unauthenticated requests only ever see published (non-draft) releases anyway.
        const body = http_client.fetch(self.allocator, &client, "https://api.github.com/repos/" ++ REPO ++ "/releases?per_page=100", .{
            .extra_headers = &.{.{ .name = "Accept", .value = "application/vnd.github+json" }},
        }) orelse return error.FetchFailed;
        defer self.allocator.free(body);

        slog.debug("GitHub API response: {s}", .{body});

        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            body,
            .{},
        );
        defer parsed.deinit();

        // Check for GitHub API errors (e.g., private repo, rate limit, 404) - the list endpoint returns an error object instead of an array in that case.
        if (parsed.value == .object) {
            if (parsed.value.object.get("message")) |message| {
                if (message == .string) {
                    slog.debug("GitHub API returned error: {s} (this is normal for private repos)", .{message.string});
                }
            }
            return null;
        }

        if (parsed.value != .array) {
            slog.debug("GitHub API response is not a JSON array", .{});
            return null;
        }
        const releases = parsed.value.array.items;

        const current_semver = parseTagVersion(self.current_version) orelse {
            slog.warn("Failed to parse current version: {s}", .{self.current_version});
            return null;
        };

        var latest_version: ?[]const u8 = null;
        var latest_url: ?[]const u8 = null;
        var latest_asset: ?ReleaseAsset = null;

        var notes_buf: std.ArrayList(u8) = .empty;
        defer notes_buf.deinit(self.allocator);

        // GitHub lists releases newest-first, so this walks down from latest until it reaches (or passes) the installed version.
        for (releases) |release_value| {
            if (release_value != .object) continue;
            const release = release_value.object;

            if (release.get("draft")) |d| if (d == .bool and d.bool) continue;
            if (release.get("prerelease")) |p| if (p == .bool and p.bool) continue;

            const tag_name = release.get("tag_name") orelse continue;
            const html_url = release.get("html_url") orelse continue;
            if (tag_name != .string or html_url != .string) continue;

            const release_semver = parseTagVersion(tag_name.string) orelse {
                slog.warn("Skipping release with unparsable tag: {s}", .{tag_name.string});
                continue;
            };

            if (release_semver.order(current_semver) != .gt) continue;

            if (latest_version == null) {
                latest_version = tag_name.string;
                latest_url = html_url.string;
                latest_asset = findPortableZip(release);
            }

            const release_notes = if (release.get("body")) |body_value|
                (if (body_value == .string) body_value.string else null)
            else
                null;

            if (release_notes) |n| {
                const entry = try std.fmt.allocPrint(self.allocator, "{s}\n\n{s}", .{ tag_name.string, n });
                defer self.allocator.free(entry);
                if (notes_buf.items.len > 0) try notes_buf.appendSlice(self.allocator, "\n\n");
                try notes_buf.appendSlice(self.allocator, entry);
            }
        }

        if (latest_version == null) {
            slog.info("Already on latest version: {s}", .{self.current_version});
            return null;
        }

        slog.info("Update available: {s} -> {s}", .{ self.current_version, latest_version.? });
        var info = UpdateInfo{
            .version = try self.allocator.dupe(u8, latest_version.?),
            .url = try self.allocator.dupe(u8, latest_url.?),
            .notes = null,
        };
        errdefer info.deinit(self.allocator);
        if (notes_buf.items.len > 0) info.notes = try self.allocator.dupe(u8, notes_buf.items);
        if (latest_asset) |a| {
            info.asset_url = try self.allocator.dupe(u8, a.url);
            info.asset_name = try self.allocator.dupe(u8, a.name);
            info.asset_size = a.size;
            if (a.digest) |d| info.asset_digest = try self.allocator.dupe(u8, d);
        }
        return info;
    }

    const ReleaseAsset = struct {
        url: []const u8,
        name: []const u8,
        size: u64,
        digest: ?[]const u8,
    };

    /// The release's "-portable.zip" asset (what the in-dialog updater installs), falling back to any .zip; null if it has none.
    fn findPortableZip(release: std.json.ObjectMap) ?ReleaseAsset {
        const assets = release.get("assets") orelse return null;
        if (assets != .array) return null;
        var fallback: ?ReleaseAsset = null;
        for (assets.array.items) |asset_value| {
            if (asset_value != .object) continue;
            const asset = asset_value.object;
            const name = asset.get("name") orelse continue;
            const url = asset.get("browser_download_url") orelse continue;
            if (name != .string or url != .string) continue;
            if (!std.ascii.endsWithIgnoreCase(name.string, ".zip")) continue;
            const size: u64 = if (asset.get("size")) |sz| (if (sz == .integer and sz.integer > 0) @intCast(sz.integer) else 0) else 0;
            const digest: ?[]const u8 = if (asset.get("digest")) |d| (if (d == .string) d.string else null) else null;
            const found: ReleaseAsset = .{ .url = url.string, .name = name.string, .size = size, .digest = digest };
            if (std.ascii.endsWithIgnoreCase(name.string, "-portable.zip")) return found;
            if (fallback == null) fallback = found;
        }
        return fallback;
    }

    pub fn checkForUpdatesBackground(allocator: std.mem.Allocator) void {
        var checker = UpdateChecker.init(allocator);

        const update_info = checker.checkForUpdates() catch |err| {
            slog.warn("Update check failed: {}", .{err});
            return;
        };

        if (update_info) |info_const| {
            var info = info_const;
            defer info.deinit(allocator);

            g_update_status.set(allocator, info.version, info.url, info.notes) catch |err| {
                slog.warn("Failed to store update status: {}", .{err});
                return;
            };
            slog.info("Update available stored: {s}", .{info.version});
        }
    }
};

pub const UpdateInfo = struct {
    version: []const u8,
    url: []const u8,
    notes: ?[]const u8,
    /// The newest release's portable zip, for the config dialog's in-place updater; null if that release has no zip attached.
    asset_url: ?[]const u8 = null,
    asset_name: ?[]const u8 = null,
    asset_size: u64 = 0,
    /// GitHub's "sha256:<hex>" asset digest, when the release has one.
    asset_digest: ?[]const u8 = null,

    pub fn deinit(self: *UpdateInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.version);
        allocator.free(self.url);
        if (self.notes) |n| allocator.free(n);
        if (self.asset_url) |u| allocator.free(u);
        if (self.asset_name) |n| allocator.free(n);
        if (self.asset_digest) |d| allocator.free(d);
    }
};

pub fn openReleasesPage() void {
    var url_buffer: [512]u8 = undefined;
    const url = g_update_status.copyUrlZ(&url_buffer) orelse "https://github.com/" ++ REPO ++ "/releases";

    slog.info("Opening releases page: {s}", .{url});

    if (!win32.shellOpen(url.ptr, null)) {
        slog.err("Failed to open URL in browser", .{});
    }
}
