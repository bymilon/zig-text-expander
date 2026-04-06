const std = @import("std");

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

const MaxTriggerLen: usize = 64;
const MaxExpansionLen: usize = 1024;
const ReloadTimerId: usize = 2;
const ServiceMutexName = "Local\\TextExpanderServiceMutex";
const StopEventName = "Local\\TextExpanderStopEvent";

const SqliteApi = struct {
    handle: c.HMODULE,
    sqlite3_open_v2: *const fn ([*:0]const u8, *?*sqlite3, c_int, ?[*:0]const u8) callconv(.c) c_int,
    sqlite3_close_v2: *const fn (*sqlite3) callconv(.c) c_int,
    sqlite3_exec: *const fn (*sqlite3, [*:0]const u8, ?*const fn (?*anyopaque, c_int, [*]?[*:0]u8, [*]?[*:0]u8) callconv(.c) c_int, ?*anyopaque, ?*?[*:0]u8) callconv(.c) c_int,
    sqlite3_free: *const fn (?*anyopaque) callconv(.c) void,
    sqlite3_busy_timeout: *const fn (*sqlite3, c_int) callconv(.c) c_int,
    sqlite3_prepare_v2: *const fn (*sqlite3, [*:0]const u8, c_int, *?*sqlite3_stmt, ?*?[*:0]const u8) callconv(.c) c_int,
    sqlite3_bind_text: *const fn (*sqlite3_stmt, c_int, [*:0]const u8, c_int, ?*const fn (?*anyopaque) callconv(.c) void) callconv(.c) c_int,
    sqlite3_step: *const fn (*sqlite3_stmt) callconv(.c) c_int,
    sqlite3_finalize: *const fn (*sqlite3_stmt) callconv(.c) c_int,
    sqlite3_column_text: *const fn (*sqlite3_stmt, c_int) callconv(.c) ?[*:0]const u8,
    sqlite3_column_int: *const fn (*sqlite3_stmt, c_int) callconv(.c) c_int,
};

const App = struct {
    allocator: std.mem.Allocator,
    db: *sqlite3,
    hook: c.HHOOK,
    snippets: std.ArrayList(SnippetEntry) = .empty,
    snippet_index: std.StringHashMap([]const u8),
    snippet_version: u64 = 0,
    char_buffer: [MaxTriggerLen]u8 = undefined,
    char_len: usize = 0,
};

const SnippetEntry = struct {
    trigger: []u8,
    expansion: []u8,
};

const Paths = struct {
    app_dir: []u8,
    db_path: []u8,

    fn deinit(self: *Paths, allocator: std.mem.Allocator) void {
        allocator.free(self.app_dir);
        allocator.free(self.db_path);
    }
};

fn pidFilePath(allocator: std.mem.Allocator, paths: *const Paths) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{s}\\service.pid", .{paths.app_dir});
}

fn writePidFile(allocator: std.mem.Allocator, paths: *const Paths, pid: u32) void {
    const path = pidFilePath(allocator, paths) catch return;
    defer allocator.free(path);

    const file = std.fs.cwd().createFile(path, .{ .truncate = true }) catch return;
    defer file.close();

    var buf: [32]u8 = undefined;
    const txt = std.fmt.bufPrint(&buf, "{d}\n", .{pid}) catch return;
    _ = file.writeAll(txt) catch {};
}

fn removePidFile(allocator: std.mem.Allocator, paths: *const Paths) void {
    const path = pidFilePath(allocator, paths) catch return;
    defer allocator.free(path);
    std.fs.cwd().deleteFile(path) catch {};
}

fn readPidFile(allocator: std.mem.Allocator, paths: *const Paths) ?u32 {
    const path = pidFilePath(allocator, paths) catch return null;
    defer allocator.free(path);

    const data = std.fs.cwd().readFileAlloc(allocator, path, 64) catch return null;
    defer allocator.free(data);

    const trimmed = std.mem.trim(u8, data, " \r\n\t");
    return std.fmt.parseInt(u32, trimmed, 10) catch null;
}

fn isPidAlive(pid: u32) bool {
    const h = c.OpenProcess(c.SYNCHRONIZE, 0, pid) orelse return false;
    defer _ = c.CloseHandle(h);
    return c.WaitForSingleObject(h, 0) == c.WAIT_TIMEOUT;
}

var g_app: ?*App = null;

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
        .sqlite3_exec = @ptrCast(try proc(dll, "sqlite3_exec")),
        .sqlite3_free = @ptrCast(try proc(dll, "sqlite3_free")),
        .sqlite3_busy_timeout = @ptrCast(try proc(dll, "sqlite3_busy_timeout")),
        .sqlite3_prepare_v2 = @ptrCast(try proc(dll, "sqlite3_prepare_v2")),
        .sqlite3_bind_text = @ptrCast(try proc(dll, "sqlite3_bind_text")),
        .sqlite3_step = @ptrCast(try proc(dll, "sqlite3_step")),
        .sqlite3_finalize = @ptrCast(try proc(dll, "sqlite3_finalize")),
        .sqlite3_column_text = @ptrCast(try proc(dll, "sqlite3_column_text")),
        .sqlite3_column_int = @ptrCast(try proc(dll, "sqlite3_column_int")),
    };
}

fn log(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt ++ "\n", args);
}

fn executeSql(sql_api: *const SqliteApi, db: *sqlite3, sql: [:0]const u8) !void {
    var errmsg: ?[*:0]u8 = null;
    const rc = sql_api.sqlite3_exec(db, sql.ptr, null, null, &errmsg);
    if (rc != SQLITE_OK) {
        defer if (errmsg) |p| sql_api.sqlite3_free(@ptrCast(p));
        return error.SqlExecFailed;
    }
}

fn ensureSchema(sql_api: *const SqliteApi, db: *sqlite3) !void {
    try executeSql(
        sql_api,
        db,
        \\PRAGMA journal_mode = WAL;
        \\PRAGMA synchronous = NORMAL;
        \\CREATE TABLE IF NOT EXISTS snippets (
        \\  trigger TEXT PRIMARY KEY,
        \\  expansion TEXT NOT NULL,
        \\  enabled INTEGER NOT NULL DEFAULT 1,
        \\  updated_at INTEGER NOT NULL
        \\);
        \\INSERT INTO snippets(trigger, expansion, enabled, updated_at)
        \\VALUES(':bb', 'be right back.', 1, unixepoch())
        \\ON CONFLICT(trigger) DO NOTHING;
    );
}

fn allocSentinelCopy(allocator: std.mem.Allocator, src: []const u8) ![:0]u8 {
    const out = try allocator.allocSentinel(u8, src.len, 0);
    @memcpy(out[0..src.len], src);
    return out;
}

fn validateTrigger(trigger: []const u8) !void {
    if (trigger.len < 2 or trigger.len > MaxTriggerLen) return error.InvalidTrigger;
    if (trigger[0] != ':') return error.InvalidTrigger;
    for (trigger[1..]) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-') return error.InvalidTrigger;
    }
}

fn getPaths(allocator: std.mem.Allocator) !Paths {
    const local_app_data = std.process.getEnvVarOwned(allocator, "LOCALAPPDATA") catch {
        return error.MissingLocalAppData;
    };
    defer allocator.free(local_app_data);

    const app_dir = try std.fmt.allocPrint(allocator, "{s}\\TextExpander", .{local_app_data});
    errdefer allocator.free(app_dir);
    const db_path = try std.fmt.allocPrint(allocator, "{s}\\snippets.db", .{app_dir});
    errdefer allocator.free(db_path);

    return .{
        .app_dir = app_dir,
        .db_path = db_path,
    };
}

fn initDb(allocator: std.mem.Allocator, sql_api: *const SqliteApi, paths: *const Paths) !*sqlite3 {
    try std.fs.cwd().makePath(paths.app_dir);

    const db_path = try allocSentinelCopy(allocator, paths.db_path);
    defer allocator.free(db_path);

    var db_opt: ?*sqlite3 = null;
    const flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX;
    const rc = sql_api.sqlite3_open_v2(db_path, &db_opt, flags, null);
    if (rc != SQLITE_OK or db_opt == null) return error.SqlOpenFailed;
    const db = db_opt.?;

    if (sql_api.sqlite3_busy_timeout(db, 3000) != SQLITE_OK) return error.SqlBusyTimeoutFailed;
    try ensureSchema(sql_api, db);

    return db;
}

fn upsertSnippet(allocator: std.mem.Allocator, sql_api: *const SqliteApi, db: *sqlite3, trigger: []const u8, expansion: []const u8) !void {
    try validateTrigger(trigger);
    if (expansion.len == 0 or expansion.len > MaxExpansionLen) return error.InvalidExpansion;

    const sql =
        "INSERT INTO snippets(trigger, expansion, enabled, updated_at) VALUES(?1, ?2, 1, unixepoch()) " ++
        "ON CONFLICT(trigger) DO UPDATE SET expansion=excluded.expansion, enabled=1, updated_at=unixepoch()";

    var stmt_opt: ?*sqlite3_stmt = null;
    if (sql_api.sqlite3_prepare_v2(db, sql, -1, &stmt_opt, null) != SQLITE_OK or stmt_opt == null) return error.PrepareFailed;
    const stmt = stmt_opt.?;
    defer _ = sql_api.sqlite3_finalize(stmt);

    const z_trigger = try allocSentinelCopy(allocator, trigger);
    defer allocator.free(z_trigger);
    const z_expansion = try allocSentinelCopy(allocator, expansion);
    defer allocator.free(z_expansion);

    if (sql_api.sqlite3_bind_text(stmt, 1, z_trigger.ptr, -1, null) != SQLITE_OK) return error.BindFailed;
    if (sql_api.sqlite3_bind_text(stmt, 2, z_expansion.ptr, -1, null) != SQLITE_OK) return error.BindFailed;
    if (sql_api.sqlite3_step(stmt) != SQLITE_DONE) return error.StepFailed;
}

fn deleteSnippet(allocator: std.mem.Allocator, sql_api: *const SqliteApi, db: *sqlite3, trigger: []const u8) !void {
    try validateTrigger(trigger);

    const sql = "DELETE FROM snippets WHERE trigger = ?1";
    var stmt_opt: ?*sqlite3_stmt = null;
    if (sql_api.sqlite3_prepare_v2(db, sql, -1, &stmt_opt, null) != SQLITE_OK or stmt_opt == null) return error.PrepareFailed;
    const stmt = stmt_opt.?;
    defer _ = sql_api.sqlite3_finalize(stmt);

    const z_trigger = try allocSentinelCopy(allocator, trigger);
    defer allocator.free(z_trigger);

    if (sql_api.sqlite3_bind_text(stmt, 1, z_trigger.ptr, -1, null) != SQLITE_OK) return error.BindFailed;
    if (sql_api.sqlite3_step(stmt) != SQLITE_DONE) return error.StepFailed;
}

fn listSnippets(sql_api: *const SqliteApi, db: *sqlite3) !void {
    const sql = "SELECT trigger, expansion, enabled, updated_at FROM snippets ORDER BY trigger";

    var stmt_opt: ?*sqlite3_stmt = null;
    if (sql_api.sqlite3_prepare_v2(db, sql, -1, &stmt_opt, null) != SQLITE_OK or stmt_opt == null) return error.PrepareFailed;
    const stmt = stmt_opt.?;
    defer _ = sql_api.sqlite3_finalize(stmt);

    while (true) {
        const rc = sql_api.sqlite3_step(stmt);
        if (rc == SQLITE_DONE) break;
        if (rc != SQLITE_ROW) return error.StepFailed;

        const trigger = std.mem.span(sql_api.sqlite3_column_text(stmt, 0) orelse break);
        const expansion = std.mem.span(sql_api.sqlite3_column_text(stmt, 1) orelse break);
        const enabled = sql_api.sqlite3_column_int(stmt, 2);
        const updated_at = sql_api.sqlite3_column_int(stmt, 3);

        std.debug.print("{s} => {s} (enabled={d}, updated_at={d})\n", .{ trigger, expansion, enabled, updated_at });
    }
}

fn countSnippets(sql_api: *const SqliteApi, db: *sqlite3) !usize {
    const sql = "SELECT COUNT(*) FROM snippets WHERE enabled = 1";

    var stmt_opt: ?*sqlite3_stmt = null;
    if (sql_api.sqlite3_prepare_v2(db, sql, -1, &stmt_opt, null) != SQLITE_OK or stmt_opt == null) return error.PrepareFailed;
    const stmt = stmt_opt.?;
    defer _ = sql_api.sqlite3_finalize(stmt);

    const rc = sql_api.sqlite3_step(stmt);
    if (rc != SQLITE_ROW) return error.StepFailed;
    return @intCast(sql_api.sqlite3_column_int(stmt, 0));
}

fn trimToLowerAscii(byte: u8) u8 {
    if (byte >= 'A' and byte <= 'Z') return byte + 32;
    return byte;
}

fn vkToAscii(vk: c.DWORD) ?u8 {
    const shift_pressed = (@as(u16, @bitCast(c.GetAsyncKeyState(c.VK_SHIFT))) & 0x8000) != 0;
    const caps_on = (c.GetKeyState(c.VK_CAPITAL) & 0x1) != 0;

    if (vk >= 'A' and vk <= 'Z') {
        const ch: u8 = @intCast(vk);
        const upper = shift_pressed != caps_on;
        return if (upper) ch else trimToLowerAscii(ch);
    }
    if (vk >= '0' and vk <= '9') return @intCast(vk);
    if (vk == c.VK_SPACE) return ' ';
    if (vk == c.VK_OEM_1) return if (shift_pressed) ':' else ';';
    if (vk == c.VK_OEM_PERIOD) return if (shift_pressed) '>' else '.';
    if (vk == c.VK_OEM_COMMA) return if (shift_pressed) '<' else ',';
    if (vk == c.VK_OEM_2) return if (shift_pressed) '?' else '/';
    if (vk == c.VK_OEM_MINUS) return if (shift_pressed) '_' else '-';
    return null;
}

fn isDelimiter(ch: u8, vk: c.DWORD) bool {
    if (vk == c.VK_RETURN or vk == c.VK_TAB) return true;
    return ch == ' ' or ch == '.' or ch == ',' or ch == ';' or ch == '?' or ch == '>';
}

fn sendBackspaces(count: usize) void {
    if (count == 0) return;
    var inputs: [MaxTriggerLen * 2]c.INPUT = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < count and n + 1 < inputs.len) : (i += 1) {
        inputs[n].type = c.INPUT_KEYBOARD;
        inputs[n].unnamed_0.ki = .{ .wVk = c.VK_BACK, .wScan = 0, .dwFlags = 0, .time = 0, .dwExtraInfo = 0 };
        n += 1;
        inputs[n].type = c.INPUT_KEYBOARD;
        inputs[n].unnamed_0.ki = .{ .wVk = c.VK_BACK, .wScan = 0, .dwFlags = c.KEYEVENTF_KEYUP, .time = 0, .dwExtraInfo = 0 };
        n += 1;
    }
    _ = c.SendInput(@intCast(n), &inputs, @sizeOf(c.INPUT));
}

fn sendUnicodeCodeUnit(unit: u16) void {
    var inputs: [2]c.INPUT = undefined;
    inputs[0].type = c.INPUT_KEYBOARD;
    inputs[0].unnamed_0.ki = .{ .wVk = 0, .wScan = @as(c.WORD, @intCast(unit)), .dwFlags = c.KEYEVENTF_UNICODE, .time = 0, .dwExtraInfo = 0 };
    inputs[1].type = c.INPUT_KEYBOARD;
    inputs[1].unnamed_0.ki = .{ .wVk = 0, .wScan = @as(c.WORD, @intCast(unit)), .dwFlags = c.KEYEVENTF_UNICODE | c.KEYEVENTF_KEYUP, .time = 0, .dwExtraInfo = 0 };
    _ = c.SendInput(@intCast(inputs.len), &inputs, @sizeOf(c.INPUT));
}

fn sendEnterKey() void {
    var inputs: [2]c.INPUT = undefined;
    inputs[0].type = c.INPUT_KEYBOARD;
    inputs[0].unnamed_0.ki = .{ .wVk = c.VK_RETURN, .wScan = 0, .dwFlags = 0, .time = 0, .dwExtraInfo = 0 };
    inputs[1].type = c.INPUT_KEYBOARD;
    inputs[1].unnamed_0.ki = .{ .wVk = c.VK_RETURN, .wScan = 0, .dwFlags = c.KEYEVENTF_KEYUP, .time = 0, .dwExtraInfo = 0 };
    _ = c.SendInput(@intCast(inputs.len), &inputs, @sizeOf(c.INPUT));
}

fn sendUtf8Text(text: []const u8) void {
    var view = std.unicode.Utf8View.init(text) catch return;
    var it = view.iterator();
    var prev_was_cr = false;
    while (it.nextCodepoint()) |cp| {
        if (cp == '\r') {
            sendEnterKey();
            prev_was_cr = true;
            continue;
        }
        if (cp == '\n') {
            // Handle LF-only and CRLF consistently as one newline in the target app.
            if (!prev_was_cr) sendEnterKey();
            prev_was_cr = false;
            continue;
        }
        prev_was_cr = false;
        if (cp <= 0xFFFF) {
            sendUnicodeCodeUnit(@intCast(cp));
        } else if (cp <= 0x10FFFF) {
            const value = cp - 0x10000;
            const hi: u16 = @intCast(0xD800 + ((value >> 10) & 0x3FF));
            const lo: u16 = @intCast(0xDC00 + (value & 0x3FF));
            sendUnicodeCodeUnit(hi);
            sendUnicodeCodeUnit(lo);
        }
    }
}

fn appendTokenValue(writer: anytype, token: []const u8) !bool {
    var st: c.SYSTEMTIME = undefined;
    c.GetLocalTime(&st);

    if (std.mem.eql(u8, token, "date")) {
        try writer.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ st.wYear, st.wMonth, st.wDay });
        return true;
    }
    if (std.mem.eql(u8, token, "time")) {
        try writer.print("{d:0>2}:{d:0>2}", .{ st.wHour, st.wMinute });
        return true;
    }
    if (std.mem.eql(u8, token, "datetime")) {
        try writer.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{ st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute });
        return true;
    }
    if (std.mem.eql(u8, token, "iso_datetime")) {
        try writer.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{ st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond });
        return true;
    }
    if (std.mem.eql(u8, token, "year")) {
        try writer.print("{d:0>4}", .{st.wYear});
        return true;
    }
    if (std.mem.eql(u8, token, "month")) {
        try writer.print("{d:0>2}", .{st.wMonth});
        return true;
    }
    if (std.mem.eql(u8, token, "day")) {
        try writer.print("{d:0>2}", .{st.wDay});
        return true;
    }
    return false;
}

fn renderTemplate(input: []const u8, out_buf: []u8) ![]const u8 {
    var stream = std.io.fixedBufferStream(out_buf);
    const writer = stream.writer();

    var i: usize = 0;
    while (i < input.len) {
        if (i + 1 < input.len and input[i] == '{' and input[i + 1] == '{') {
            var j = i + 2;
            while (j + 1 < input.len and !(input[j] == '}' and input[j + 1] == '}')) : (j += 1) {}
            if (j + 1 < input.len) {
                const raw_token = std.mem.trim(u8, input[i + 2 .. j], " \t\r\n");
                const handled = try appendTokenValue(writer, raw_token);
                if (!handled) {
                    try writer.writeAll(input[i .. j + 2]);
                }
                i = j + 2;
                continue;
            }
        }
        try writer.writeByte(input[i]);
        i += 1;
    }

    return stream.getWritten();
}

fn clearSnippetCache(app: *App) void {
    app.snippet_index.clearRetainingCapacity();
    for (app.snippets.items) |entry| {
        app.allocator.free(entry.trigger);
        app.allocator.free(entry.expansion);
    }
    app.snippets.clearRetainingCapacity();
}

fn querySnippetVersion(sql_api: *const SqliteApi, db: *sqlite3) !u64 {
    const sql = "SELECT IFNULL(MAX(updated_at), 0), COUNT(*) FROM snippets WHERE enabled = 1";
    var stmt_opt: ?*sqlite3_stmt = null;
    if (sql_api.sqlite3_prepare_v2(db, sql, -1, &stmt_opt, null) != SQLITE_OK or stmt_opt == null) return error.PrepareFailed;
    const stmt = stmt_opt.?;
    defer _ = sql_api.sqlite3_finalize(stmt);

    const rc = sql_api.sqlite3_step(stmt);
    if (rc != SQLITE_ROW) return error.StepFailed;
    const max_updated: u32 = @intCast(sql_api.sqlite3_column_int(stmt, 0));
    const count: u32 = @intCast(sql_api.sqlite3_column_int(stmt, 1));
    return (@as(u64, max_updated) << 32) | @as(u64, count);
}

fn reloadSnippetCache(sql_api: *const SqliteApi, app: *App) !void {
    clearSnippetCache(app);

    const sql = "SELECT trigger, expansion FROM snippets WHERE enabled = 1 ORDER BY trigger";

    var stmt_opt: ?*sqlite3_stmt = null;
    if (sql_api.sqlite3_prepare_v2(app.db, sql, -1, &stmt_opt, null) != SQLITE_OK or stmt_opt == null) return error.PrepareFailed;
    const stmt = stmt_opt.?;
    defer _ = sql_api.sqlite3_finalize(stmt);

    while (true) {
        const rc = sql_api.sqlite3_step(stmt);
        if (rc == SQLITE_DONE) break;
        if (rc != SQLITE_ROW) return error.StepFailed;

        const trig_raw = sql_api.sqlite3_column_text(stmt, 0) orelse continue;
        const exp_raw = sql_api.sqlite3_column_text(stmt, 1) orelse continue;
        const trig = std.mem.span(trig_raw);
        const exp = std.mem.span(exp_raw);

        try app.snippets.append(app.allocator, .{
            .trigger = try app.allocator.dupe(u8, trig),
            .expansion = try app.allocator.dupe(u8, exp),
        });
        const last = app.snippets.items[app.snippets.items.len - 1];
        try app.snippet_index.put(last.trigger, last.expansion);
    }
    app.snippet_version = try querySnippetVersion(sql_api, app.db);
}

fn lookupExpansionInCache(app: *App, trigger: []const u8) ?[]const u8 {
    return app.snippet_index.get(trigger);
}

fn applyIfMatch(app: *App, delimiter: u8) bool {
    if (app.char_len == 0) return false;

    const trigger = app.char_buffer[0..app.char_len];
    if (trigger[0] != ':') return false;

    if (lookupExpansionInCache(app, trigger)) |expansion| {
        var rendered_buf: [MaxExpansionLen * 4]u8 = undefined;
        const rendered = renderTemplate(expansion, &rendered_buf) catch expansion;
        sendBackspaces(trigger.len);
        sendUtf8Text(rendered);
        sendUnicodeCodeUnit(delimiter);
        return true;
    }

    return false;
}

export fn keyboardProc(nCode: c_int, wParam: c.WPARAM, lParam: c.LPARAM) callconv(.winapi) c.LRESULT {
    if (nCode < c.HC_ACTION or g_app == null) return c.CallNextHookEx(null, nCode, wParam, lParam);
    if (wParam != c.WM_KEYDOWN and wParam != c.WM_SYSKEYDOWN) return c.CallNextHookEx(null, nCode, wParam, lParam);

    const info: *const c.KBDLLHOOKSTRUCT = @ptrFromInt(@as(usize, @intCast(lParam)));
    if ((info.flags & c.LLKHF_INJECTED) != 0) return c.CallNextHookEx(null, nCode, wParam, lParam);

    // Reliable quit fallback if WM_HOTKEY registration fails in this environment.
    if (info.vkCode == 'Q') {
        const ctrl_down = (@as(u16, @bitCast(c.GetAsyncKeyState(c.VK_CONTROL))) & 0x8000) != 0;
        const shift_down = (@as(u16, @bitCast(c.GetAsyncKeyState(c.VK_SHIFT))) & 0x8000) != 0;
        if (ctrl_down and shift_down) {
            if (g_stop_event) |ev| _ = c.SetEvent(ev);
            return 1;
        }
    }

    var app = g_app.?;

    if (info.vkCode == c.VK_BACK) {
        if (app.char_len > 0) app.char_len -= 1;
        return c.CallNextHookEx(null, nCode, wParam, lParam);
    }
    if (info.vkCode == c.VK_ESCAPE) {
        app.char_len = 0;
        return c.CallNextHookEx(null, nCode, wParam, lParam);
    }

    const ch_opt = vkToAscii(info.vkCode);
    if (ch_opt == null) {
        if (info.vkCode == c.VK_RETURN or info.vkCode == c.VK_TAB) {
            const delim: u8 = if (info.vkCode == c.VK_RETURN) '\r' else '\t';
            const consumed = applyIfMatch(app, delim);
            app.char_len = 0;
            if (consumed) return 1;
        }
        return c.CallNextHookEx(null, nCode, wParam, lParam);
    }

    const ch = ch_opt.?;
    if (isDelimiter(ch, info.vkCode)) {
        const consumed = applyIfMatch(app, ch);
        app.char_len = 0;
        if (consumed) return 1;
        return c.CallNextHookEx(null, nCode, wParam, lParam);
    }

    if (app.char_len < app.char_buffer.len) {
        app.char_buffer[app.char_len] = trimToLowerAscii(ch);
        app.char_len += 1;
    } else {
        std.mem.copyForwards(u8, app.char_buffer[0 .. app.char_buffer.len - 1], app.char_buffer[1..]);
        app.char_buffer[app.char_buffer.len - 1] = trimToLowerAscii(ch);
    }

    return c.CallNextHookEx(null, nCode, wParam, lParam);
}

var g_stop_event: ?c.HANDLE = null;

fn openExistingServiceMutex() ?c.HANDLE {
    return c.OpenMutexA(c.SYNCHRONIZE, 0, ServiceMutexName);
}

fn isServiceRunning(allocator: std.mem.Allocator, paths: *const Paths) bool {
    if (readPidFile(allocator, paths)) |pid| {
        if (isPidAlive(pid)) return true;
        removePidFile(allocator, paths);
    }
    return false;
}

fn signalStop() bool {
    const ev = c.OpenEventA(c.EVENT_MODIFY_STATE, 0, StopEventName) orelse return false;
    defer _ = c.CloseHandle(ev);
    _ = c.SetEvent(ev);
    return true;
}

fn waitForServiceStop(allocator: std.mem.Allocator, paths: *const Paths, timeout_ms: u64) bool {
    const start = std.time.milliTimestamp();
    while (true) {
        if (!isServiceRunning(allocator, paths)) return true;
        const now = std.time.milliTimestamp();
        if (@as(u64, @intCast(now - start)) >= timeout_ms) return false;
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }
}

fn startBackgroundSelf() !void {
    var exe_buf: [c.MAX_PATH]u8 = undefined;
    const n = c.GetModuleFileNameA(null, &exe_buf, exe_buf.len);
    if (n == 0 or n >= exe_buf.len) return error.GetModulePathFailed;
    const exe_path = exe_buf[0..n];

    var cmdline_buf: [1024]u8 = undefined;
    const cmdline = try std.fmt.bufPrintZ(&cmdline_buf, "\"{s}\" run --background", .{exe_path});

    var si: c.STARTUPINFOA = std.mem.zeroes(c.STARTUPINFOA);
    si.cb = @sizeOf(c.STARTUPINFOA);
    var pi: c.PROCESS_INFORMATION = std.mem.zeroes(c.PROCESS_INFORMATION);

    const flags: c.DWORD = c.CREATE_NEW_PROCESS_GROUP | c.DETACHED_PROCESS | c.CREATE_NO_WINDOW;
    const ok = c.CreateProcessA(
        null,
        @ptrCast(cmdline.ptr),
        null,
        null,
        0,
        flags,
        null,
        null,
        &si,
        &pi,
    );
    if (ok == 0) return error.StartBackgroundFailed;

    _ = c.CloseHandle(pi.hThread);
    _ = c.CloseHandle(pi.hProcess);
}

fn runService(allocator: std.mem.Allocator, paths: *const Paths, sql_api: *const SqliteApi, db: *sqlite3, background: bool) !void {
    const mutex = c.CreateMutexA(null, 0, ServiceMutexName) orelse return error.MutexCreateFailed;
    defer _ = c.CloseHandle(mutex);
    if (c.GetLastError() == c.ERROR_ALREADY_EXISTS) return error.ServiceAlreadyRunning;

    const stop_event = c.CreateEventA(null, 1, 0, StopEventName) orelse return error.StopEventCreateFailed;
    defer _ = c.CloseHandle(stop_event);
    g_stop_event = stop_event;
    defer g_stop_event = null;
    writePidFile(allocator, paths, c.GetCurrentProcessId());
    defer removePidFile(allocator, paths);

    var app = App{
        .allocator = allocator,
        .db = db,
        .hook = null,
        .snippets = .empty,
        .snippet_index = std.StringHashMap([]const u8).init(allocator),
        .snippet_version = 0,
        .char_buffer = undefined,
        .char_len = 0,
    };
    defer clearSnippetCache(&app);
    defer app.snippet_index.deinit();
    try reloadSnippetCache(sql_api, &app);
    g_app = &app;

    const module = c.GetModuleHandleW(null);
    app.hook = c.SetWindowsHookExW(c.WH_KEYBOARD_LL, keyboardProc, module, 0);
    if (app.hook == null) return error.HookInstallFailed;
    defer _ = c.UnhookWindowsHookEx(app.hook);

    if (c.RegisterHotKey(null, 1, c.MOD_CONTROL | c.MOD_SHIFT, 'Q') == 0) {
        log("warning: failed to register Ctrl+Shift+Q quit hotkey", .{});
    } else {
        defer _ = c.UnregisterHotKey(null, 1);
    }

    if (!background) {
        log("text-expander running. type ':bb' + delimiter.", .{});
        log("quit with Ctrl+Shift+Q", .{});
    }

    const timer_id = c.SetTimer(null, ReloadTimerId, 1000, null);
    if (timer_id != 0) {
        defer _ = c.KillTimer(null, ReloadTimerId);
    }

    var msg: c.MSG = undefined;
    var wait_handles: [1]c.HANDLE = .{stop_event};
    var should_quit = false;
    while (true) {
        const wait_result = c.MsgWaitForMultipleObjects(1, &wait_handles, 0, c.INFINITE, c.QS_ALLINPUT);
        if (wait_result == c.WAIT_OBJECT_0) break;
        if (wait_result == c.WAIT_FAILED) return error.WaitFailed;

        while (c.PeekMessageW(&msg, null, 0, 0, c.PM_REMOVE) != 0) {
            if (msg.message == c.WM_HOTKEY and msg.wParam == 1) {
                should_quit = true;
                break;
            }
            if (msg.message == c.WM_TIMER and msg.wParam == ReloadTimerId) {
                const current_version = querySnippetVersion(sql_api, app.db) catch app.snippet_version;
                if (current_version != app.snippet_version) {
                    reloadSnippetCache(sql_api, &app) catch {};
                }
                continue;
            }
            _ = c.TranslateMessage(&msg);
            _ = c.DispatchMessageW(&msg);
        }
        if (should_quit) break;
    }
}

fn printUsage() void {
    std.debug.print(
        \\Usage:
        \\  text-expander                 # start background service
        \\  text-expander start           # start background service
        \\  text-expander run             # run in foreground (blocking)
        \\  text-expander stop            # stop running service
        \\  text-expander status          # show running status + db path
        \\  text-expander add :bb "be right back."
        \\  text-expander addm :sig       # read multiline expansion from stdin
        \\  text-expander remove :bb
        \\  text-expander list
        \\  text-expander doctor
        \\  text-expander tui             # open snippet manager TUI (if built)
        \\  text-expander help
        \\
    , .{});
}

fn readAllStdin(allocator: std.mem.Allocator, max_bytes: usize) ![]u8 {
    const stdin = std.fs.File.stdin();
    return try stdin.readToEndAlloc(allocator, max_bytes);
}

pub fn main() !void {
    if (@import("builtin").os.tag != .windows) {
        log("This build supports Windows only.", .{});
        return;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var paths = try getPaths(allocator);
    defer paths.deinit(allocator);

    var sql_api = try loadSqliteApi();
    defer _ = c.FreeLibrary(sql_api.handle);

    const db = try initDb(allocator, &sql_api, &paths);
    defer _ = sql_api.sqlite3_close_v2(db);

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len <= 1 or std.mem.eql(u8, args[1], "start")) {
        if (isServiceRunning(allocator, &paths)) {
            std.debug.print("status: already running\n", .{});
            std.debug.print("db: {s}\n", .{paths.db_path});
            return;
        }
        try startBackgroundSelf();
        std.debug.print("status: started in background\n", .{});
        std.debug.print("db: {s}\n", .{paths.db_path});
        return;
    }

    if (std.mem.eql(u8, args[1], "run")) {
        const background = args.len > 2 and std.mem.eql(u8, args[2], "--background");
        try runService(allocator, &paths, &sql_api, db, background);
        return;
    }

    if (std.mem.eql(u8, args[1], "stop")) {
        if (signalStop()) {
            if (waitForServiceStop(allocator, &paths, 5000)) {
                std.debug.print("status: stopped\n", .{});
            } else {
                std.debug.print("status: stop signal sent (shutdown pending)\n", .{});
            }
        } else {
            std.debug.print("status: not running\n", .{});
        }
        std.debug.print("db: {s}\n", .{paths.db_path});
        return;
    }

    if (std.mem.eql(u8, args[1], "status")) {
        const running = isServiceRunning(allocator, &paths);
        std.debug.print("status: {s}\n", .{if (running) "running" else "stopped"});
        if (readPidFile(allocator, &paths)) |pid| {
            if (isPidAlive(pid)) std.debug.print("pid: {d}\n", .{pid});
        }
        std.debug.print("db: {s}\n", .{paths.db_path});
        return;
    }

    if (std.mem.eql(u8, args[1], "help")) {
        printUsage();
        std.debug.print("db: {s}\n", .{paths.db_path});
        return;
    }

    if (std.mem.eql(u8, args[1], "tui")) {
        std.debug.print("launch: .\\dist\\text-expander-tui.exe\n", .{});
        std.debug.print("db: {s}\n", .{paths.db_path});
        return;
    }

    if (std.mem.eql(u8, args[1], "add")) {
        if (args.len < 4) return error.InvalidArguments;
        try upsertSnippet(allocator, &sql_api, db, args[2], args[3]);
        std.debug.print("saved: {s} => {s}\n", .{ args[2], args[3] });
        std.debug.print("db: {s}\n", .{paths.db_path});
        return;
    }

    if (std.mem.eql(u8, args[1], "addm")) {
        if (args.len < 3) return error.InvalidArguments;
        const raw = try readAllStdin(allocator, MaxExpansionLen);
        defer allocator.free(raw);
        const trimmed = std.mem.trimRight(u8, raw, "\r\n");
        if (trimmed.len == 0) return error.InvalidExpansion;
        try upsertSnippet(allocator, &sql_api, db, args[2], trimmed);
        std.debug.print("saved multiline: {s} ({d} bytes)\n", .{ args[2], trimmed.len });
        std.debug.print("db: {s}\n", .{paths.db_path});
        return;
    }

    if (std.mem.eql(u8, args[1], "remove")) {
        if (args.len < 3) return error.InvalidArguments;
        try deleteSnippet(allocator, &sql_api, db, args[2]);
        std.debug.print("removed: {s}\n", .{args[2]});
        std.debug.print("db: {s}\n", .{paths.db_path});
        return;
    }

    if (std.mem.eql(u8, args[1], "list")) {
        try listSnippets(&sql_api, db);
        std.debug.print("db: {s}\n", .{paths.db_path});
        return;
    }

    if (std.mem.eql(u8, args[1], "doctor")) {
        const count = try countSnippets(&sql_api, db);
        std.debug.print("doctor: db open ok, active snippets={d}\n", .{count});
        const running = isServiceRunning(allocator, &paths);
        std.debug.print("status: {s}\n", .{if (running) "running" else "stopped"});
        if (readPidFile(allocator, &paths)) |pid| {
            if (isPidAlive(pid)) std.debug.print("pid: {d}\n", .{pid});
        }
        std.debug.print("db: {s}\n", .{paths.db_path});
        return;
    }

    printUsage();
    return error.InvalidArguments;
}
