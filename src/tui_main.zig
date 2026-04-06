const std = @import("std");
const tui = @import("tui");
const c = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
});

const sqlite3 = opaque {};
const sqlite3_stmt = opaque {};

const SQLITE_OK: c_int = 0;
const SQLITE_ROW: c_int = 100;
const SQLITE_DONE: c_int = 101;
const SQLITE_OPEN_READWRITE: c_int = 0x00000002;
const SQLITE_OPEN_CREATE: c_int = 0x00000004;
const SQLITE_OPEN_FULLMUTEX: c_int = 0x00010000;

const Snippet = struct {
    trigger: []u8,
    expansion: []u8,
};

const SqliteApi = struct {
    handle: c.HMODULE,
    sqlite3_open_v2: *const fn ([*:0]const u8, *?*sqlite3, c_int, ?[*:0]const u8) callconv(.c) c_int,
    sqlite3_close_v2: *const fn (*sqlite3) callconv(.c) c_int,
    sqlite3_prepare_v2: *const fn (*sqlite3, [*:0]const u8, c_int, *?*sqlite3_stmt, ?*?[*:0]const u8) callconv(.c) c_int,
    sqlite3_bind_text: *const fn (*sqlite3_stmt, c_int, [*:0]const u8, c_int, ?*const fn (?*anyopaque) callconv(.c) void) callconv(.c) c_int,
    sqlite3_step: *const fn (*sqlite3_stmt) callconv(.c) c_int,
    sqlite3_finalize: *const fn (*sqlite3_stmt) callconv(.c) c_int,
    sqlite3_column_text: *const fn (*sqlite3_stmt, c_int) callconv(.c) ?[*:0]const u8,
    sqlite3_busy_timeout: *const fn (*sqlite3, c_int) callconv(.c) c_int,
};

fn proc(dll: c.HMODULE, name: [*:0]const u8) !*anyopaque {
    const p = c.GetProcAddress(dll, name) orelse return error.SqliteSymbolMissing;
    return @ptrCast(@constCast(p));
}

fn loadSqliteApi() !SqliteApi {
    const dll = c.LoadLibraryA("winsqlite3.dll") orelse return error.SqliteDllNotFound;
    errdefer _ = c.FreeLibrary(dll);
    return .{
        .handle = dll,
        .sqlite3_open_v2 = @ptrCast(try proc(dll, "sqlite3_open_v2")),
        .sqlite3_close_v2 = @ptrCast(try proc(dll, "sqlite3_close_v2")),
        .sqlite3_prepare_v2 = @ptrCast(try proc(dll, "sqlite3_prepare_v2")),
        .sqlite3_bind_text = @ptrCast(try proc(dll, "sqlite3_bind_text")),
        .sqlite3_step = @ptrCast(try proc(dll, "sqlite3_step")),
        .sqlite3_finalize = @ptrCast(try proc(dll, "sqlite3_finalize")),
        .sqlite3_column_text = @ptrCast(try proc(dll, "sqlite3_column_text")),
        .sqlite3_busy_timeout = @ptrCast(try proc(dll, "sqlite3_busy_timeout")),
    };
}

fn getDbPath(allocator: std.mem.Allocator) ![]u8 {
    const local_app_data = try std.process.getEnvVarOwned(allocator, "LOCALAPPDATA");
    defer allocator.free(local_app_data);
    const app_dir = try std.fmt.allocPrint(allocator, "{s}\\TextExpander", .{local_app_data});
    defer allocator.free(app_dir);
    try std.fs.cwd().makePath(app_dir);
    return try std.fmt.allocPrint(allocator, "{s}\\snippets.db", .{app_dir});
}

fn openDb(allocator: std.mem.Allocator, sql_api: *const SqliteApi, db_path: []const u8) !*sqlite3 {
    const z = try allocator.allocSentinel(u8, db_path.len, 0);
    defer allocator.free(z);
    @memcpy(z[0..db_path.len], db_path);

    var db_opt: ?*sqlite3 = null;
    const flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX;
    const rc = sql_api.sqlite3_open_v2(z, &db_opt, flags, null);
    if (rc != SQLITE_OK or db_opt == null) return error.SqlOpenFailed;
    if (sql_api.sqlite3_busy_timeout(db_opt.?, 3000) != SQLITE_OK) return error.SqlBusyTimeoutFailed;
    return db_opt.?;
}

const SnippetManagerTui = struct {
    allocator: std.mem.Allocator,
    sql_api: SqliteApi,
    db: *sqlite3,
    db_path: []u8,
    snippets: std.ArrayList(Snippet),
    selected: usize = 0,
    status: []const u8 = "Ready",

    pub fn init(allocator: std.mem.Allocator) !SnippetManagerTui {
        const db_path = try getDbPath(allocator);
        var sql_api = try loadSqliteApi();
        const db = try openDb(allocator, &sql_api, db_path);

        var self = SnippetManagerTui{
            .allocator = allocator,
            .sql_api = sql_api,
            .db = db,
            .db_path = db_path,
            .snippets = .empty,
        };
        try self.reload();
        return self;
    }

    pub fn deinit(self: *SnippetManagerTui) void {
        self.clearSnippets();
        self.snippets.deinit(self.allocator);
        _ = self.sql_api.sqlite3_close_v2(self.db);
        _ = c.FreeLibrary(self.sql_api.handle);
        self.allocator.free(self.db_path);
    }

    fn clearSnippets(self: *SnippetManagerTui) void {
        for (self.snippets.items) |it| {
            self.allocator.free(it.trigger);
            self.allocator.free(it.expansion);
        }
        self.snippets.clearRetainingCapacity();
    }

    fn reload(self: *SnippetManagerTui) !void {
        self.clearSnippets();
        const sql = "SELECT trigger, expansion FROM snippets WHERE enabled = 1 ORDER BY trigger";
        var stmt_opt: ?*sqlite3_stmt = null;
        if (self.sql_api.sqlite3_prepare_v2(self.db, sql, -1, &stmt_opt, null) != SQLITE_OK or stmt_opt == null) {
            return error.PrepareFailed;
        }
        const stmt = stmt_opt.?;
        defer _ = self.sql_api.sqlite3_finalize(stmt);

        while (true) {
            const rc = self.sql_api.sqlite3_step(stmt);
            if (rc == SQLITE_DONE) break;
            if (rc != SQLITE_ROW) return error.StepFailed;

            const trigger_raw = self.sql_api.sqlite3_column_text(stmt, 0) orelse continue;
            const expansion_raw = self.sql_api.sqlite3_column_text(stmt, 1) orelse continue;
            try self.snippets.append(self.allocator, .{
                .trigger = try self.allocator.dupe(u8, std.mem.span(trigger_raw)),
                .expansion = try self.allocator.dupe(u8, std.mem.span(expansion_raw)),
            });
        }
        if (self.selected >= self.snippets.items.len and self.snippets.items.len > 0) {
            self.selected = self.snippets.items.len - 1;
        } else if (self.snippets.items.len == 0) {
            self.selected = 0;
        }
        self.status = "Reloaded";
    }

    fn deleteSelected(self: *SnippetManagerTui) !void {
        if (self.snippets.items.len == 0) return;
        const item = self.snippets.items[self.selected];

        var trigger_z = try self.allocator.allocSentinel(u8, item.trigger.len, 0);
        defer self.allocator.free(trigger_z);
        @memcpy(trigger_z[0..item.trigger.len], item.trigger);

        const sql = "DELETE FROM snippets WHERE trigger = ?1";
        var stmt_opt: ?*sqlite3_stmt = null;
        if (self.sql_api.sqlite3_prepare_v2(self.db, sql, -1, &stmt_opt, null) != SQLITE_OK or stmt_opt == null) {
            return error.PrepareFailed;
        }
        const stmt = stmt_opt.?;
        defer _ = self.sql_api.sqlite3_finalize(stmt);

        if (self.sql_api.sqlite3_bind_text(stmt, 1, trigger_z.ptr, -1, null) != SQLITE_OK) return error.BindFailed;
        if (self.sql_api.sqlite3_step(stmt) != SQLITE_DONE) return error.StepFailed;

        try self.reload();
        self.status = "Deleted selected snippet";
    }

    pub fn render(self: *SnippetManagerTui, ctx: *tui.RenderContext) void {
        var screen = ctx.getSubScreen();
        const w = screen.width;
        const h = screen.height;
        if (w < 40 or h < 12) return;

        const left_w = @min(36, w / 3);
        const right_x: u16 = @intCast(left_w + 3);

        screen.setStyle(tui.Style.default.setFg(tui.Color.white).setBg(tui.Color.fromRGB(15, 23, 42)));
        var y: usize = 0;
        while (y < h) : (y += 1) {
            screen.moveCursor(0, @intCast(y));
            screen.putString(" ");
        }

        screen.setStyle(tui.Style.default.bold().setFg(tui.Color.fromRGB(148, 163, 184)));
        screen.moveCursor(2, 1);
        screen.putString("TEXT EXPANDER");
        screen.setStyle(tui.Style.default.setFg(tui.Color.fromRGB(94, 234, 212)));
        screen.moveCursor(2, 2);
        screen.putString("Snippet Manager");

        screen.setStyle(tui.Style.default.setFg(tui.Color.fromRGB(100, 116, 139)));
        var line: usize = 4;
        for (self.snippets.items, 0..) |item, i| {
            if (line >= h - 4) break;
            if (i == self.selected) {
                screen.setStyle(tui.Style.default.bold().setFg(tui.Color.fromRGB(226, 232, 240)).setBg(tui.Color.fromRGB(30, 41, 59)));
            } else {
                screen.setStyle(tui.Style.default.setFg(tui.Color.fromRGB(148, 163, 184)));
            }
            screen.moveCursor(2, @intCast(line));
            var row_buf: [64]u8 = undefined;
            const label = std.fmt.bufPrint(&row_buf, "{s}", .{item.trigger}) catch item.trigger;
            screen.putString(label);
            line += 1;
        }

        screen.setStyle(tui.Style.default.bold().setFg(tui.Color.fromRGB(148, 163, 184)));
        screen.moveCursor(right_x, 1);
        screen.putString("Preview");

        screen.setStyle(tui.Style.default.setFg(tui.Color.fromRGB(226, 232, 240)));
        if (self.snippets.items.len > 0) {
            const item = self.snippets.items[self.selected];
            screen.moveCursor(right_x, 3);
            screen.putString("Trigger:");
            screen.moveCursor(right_x + 10, 3);
            screen.putString(item.trigger);

            screen.moveCursor(right_x, 5);
            screen.putString("Expansion:");
            screen.moveCursor(right_x, 6);
            screen.putString(item.expansion);
        } else {
            screen.moveCursor(right_x, 3);
            screen.putString("No snippets");
        }

        screen.setStyle(tui.Style.default.setFg(tui.Color.fromRGB(100, 116, 139)));
        screen.moveCursor(2, @intCast(h - 2));
        screen.putString("up/down select  d delete  r reload  q quit");
        screen.moveCursor(2, @intCast(h - 1));
        var foot_buf: [512]u8 = undefined;
        const footer = std.fmt.bufPrint(&foot_buf, "status: {s}   db: {s}", .{ self.status, self.db_path }) catch "status";
        screen.putString(footer);
    }

    pub fn handleEvent(self: *SnippetManagerTui, event: tui.Event) tui.EventResult {
        if (event == .key) {
            switch (event.key.key) {
                .up => {
                    if (self.selected > 0) self.selected -= 1;
                    return .needs_redraw;
                },
                .down => {
                    if (self.selected + 1 < self.snippets.items.len) self.selected += 1;
                    return .needs_redraw;
                },
                .char => |cp| {
                    if (cp == 'q') std.process.exit(0);
                    if (cp == 'r') {
                        self.reload() catch {
                            self.status = "Reload failed";
                        };
                        return .needs_redraw;
                    }
                    if (cp == 'd') {
                        self.deleteSelected() catch {
                            self.status = "Delete failed";
                        };
                        return .needs_redraw;
                    }
                },
                else => {},
            }
        }
        return .ignored;
    }
};

pub fn main() !void {
    var app = try tui.App.init(.{});
    defer app.deinit();

    var root = try SnippetManagerTui.init(std.heap.page_allocator);
    defer root.deinit();

    try app.setRoot(&root);
    try app.run();
}
