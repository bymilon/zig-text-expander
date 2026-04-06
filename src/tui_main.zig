const std = @import("std");
const vaxis = @import("vaxis");

const Snippet = @import("tui/domain/snippet.zig").Snippet;
const snippet_domain = @import("tui/domain/snippet.zig");
const SnippetDb = @import("tui/infra/sqlite_db.zig").SnippetDb;

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};

const App = struct {
    allocator: std.mem.Allocator,
    db: SnippetDb,
    snippets: std.ArrayList(Snippet),
    selected: usize = 0,
    status_buf: [512]u8 = undefined,
    status: []const u8 = "Ready",
    db_version: u64 = 0,
    last_poll_ms: i64 = 0,

    fn init(allocator: std.mem.Allocator) !App {
        var self = App{
            .allocator = allocator,
            .db = try SnippetDb.init(allocator),
            .snippets = .empty,
        };
        try self.reload("Loaded snippets");
        return self;
    }

    fn deinit(self: *App) void {
        snippet_domain.freeOwnedSlice(self.allocator, self.snippets.items);
        self.snippets.deinit(self.allocator);
        self.db.deinit();
    }

    fn setStatus(self: *App, comptime fmt: []const u8, args: anytype) void {
        self.status = std.fmt.bufPrint(&self.status_buf, fmt, args) catch "status update failed";
    }

    fn reload(self: *App, reason: []const u8) !void {
        const previous = self.selected;
        snippet_domain.freeOwnedSlice(self.allocator, self.snippets.items);
        self.snippets.clearRetainingCapacity();
        try self.db.listEnabled(&self.snippets, self.allocator);

        if (self.snippets.items.len == 0) {
            self.selected = 0;
        } else if (previous < self.snippets.items.len) {
            self.selected = previous;
        } else {
            self.selected = self.snippets.items.len - 1;
        }

        self.db_version = try self.db.queryVersion();
        self.setStatus("{s}: {d} snippets", .{ reason, self.snippets.items.len });
    }

    fn autoReloadIfChanged(self: *App) void {
        const now = std.time.milliTimestamp();
        if (now - self.last_poll_ms < 1000) return;
        self.last_poll_ms = now;

        const version = self.db.queryVersion() catch {
            self.setStatus("Auto reload failed", .{});
            return;
        };
        if (version != self.db_version) {
            self.reload("Auto reloaded from db") catch {
                self.setStatus("Auto reload failed", .{});
            };
        }
    }

    fn selectedSnippet(self: *const App) ?Snippet {
        if (self.snippets.items.len == 0) return null;
        if (self.selected >= self.snippets.items.len) return null;
        return self.snippets.items[self.selected];
    }

    fn deleteSelected(self: *App) void {
        if (self.snippets.items.len == 0) {
            self.setStatus("Nothing to delete", .{});
            return;
        }
        const item = self.snippets.items[self.selected];
        self.db.deleteByTrigger(self.allocator, item.trigger) catch {
            self.setStatus("Delete failed", .{});
            return;
        };
        self.reload("Deleted snippet") catch {
            self.setStatus("Reload failed", .{});
        };
    }

    fn clampSelection(self: *App) void {
        if (self.snippets.items.len == 0) {
            self.selected = 0;
        } else if (self.selected >= self.snippets.items.len) {
            self.selected = self.snippets.items.len - 1;
        }
    }
};

fn sanitizeUtf8Alloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    if (std.unicode.utf8ValidateSlice(input)) {
        return allocator.dupe(u8, input);
    }

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    // Fallback path for malformed data: keep printable ASCII only.
    // This guarantees output is valid UTF-8 and avoids any decoder panics.
    for (input) |b| {
        try out.append(allocator, if (b >= 0x20 and b <= 0x7E) b else '?');
    }

    return out.toOwnedSlice(allocator);
}

fn sanitizeAsciiAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    for (input) |b| {
        try out.append(allocator, if (b >= 0x20 and b <= 0x7E) b else ' ');
    }
    return out.toOwnedSlice(allocator);
}

fn drawText(allocator: std.mem.Allocator, win: vaxis.Window, col: u16, row: u16, text: []const u8, style: vaxis.Style) !void {
    const safe = try sanitizeUtf8Alloc(allocator, text);
    const seg: vaxis.Segment = .{ .text = safe, .style = style };
    _ = win.print(&.{seg}, .{ .col_offset = col, .row_offset = row, .wrap = .none });
}

fn drawTextAscii(allocator: std.mem.Allocator, win: vaxis.Window, col: u16, row: u16, text: []const u8, style: vaxis.Style) !void {
    const safe = try sanitizeAsciiAlloc(allocator, text);
    const seg: vaxis.Segment = .{ .text = safe, .style = style };
    _ = win.print(&.{seg}, .{ .col_offset = col, .row_offset = row, .wrap = .none });
}

fn drawUi(vx: *vaxis.Vaxis, app: *App, tty_writer: anytype) !void {
    var frame_arena = std.heap.ArenaAllocator.init(app.allocator);
    defer frame_arena.deinit();
    const frame_alloc = frame_arena.allocator();

    app.autoReloadIfChanged();
    app.clampSelection();

    const root = vx.window();
    root.clear();

    if (root.width < 60 or root.height < 14) {
        try drawText(frame_alloc, root, 1, 1, "Terminal too small. Need at least 60x14.", .{ .fg = .{ .rgb = .{ 245, 158, 11 } } });
        try vx.render(tty_writer);
        return;
    }

    const bg: vaxis.Color = .{ .rgb = .{ 11, 16, 32 } };
    const fg: vaxis.Color = .{ .rgb = .{ 229, 231, 235 } };
    const muted: vaxis.Color = .{ .rgb = .{ 148, 163, 184 } };
    const border: vaxis.Color = .{ .rgb = .{ 51, 65, 85 } };
    const selected_bg: vaxis.Color = .{ .rgb = .{ 30, 41, 59 } };

    try drawText(frame_alloc, root, 1, 0, "Text Expander", .{ .fg = fg, .bg = bg, .bold = true });

    var subtitle_buf: [1024]u8 = undefined;
    const subtitle = std.fmt.bufPrint(&subtitle_buf, "SQLite: {s}  |  q quit  r reload  d delete", .{app.db.path()}) catch "SQLite path unavailable";
    try drawText(frame_alloc, root, 1, 1, subtitle, .{ .fg = muted, .bg = bg });

    const content_y: u16 = 3;
    const content_h: u16 = root.height -| 5;
    const left_w: u16 = @max(24, @as(u16, @intCast((@as(u32, root.width) * 35) / 100)));
    const right_x: u16 = left_w + 1;
    const right_w: u16 = root.width -| right_x;

    try drawText(frame_alloc, root, 2, content_y, "Snippets", .{ .fg = muted, .bg = bg, .bold = true });
    try drawText(frame_alloc, root, right_x + 2, content_y, "Preview", .{ .fg = muted, .bg = bg, .bold = true });

    const left_inner = root.child(.{
        .x_off = 0,
        .y_off = content_y,
        .width = left_w,
        .height = content_h,
        .border = .{
            .where = .all,
            .glyphs = .{ .custom = .{ "+", "-", "+", "|", "+", "+" } },
            .style = .{ .fg = border, .bg = bg },
        },
    });

    const right_inner = root.child(.{
        .x_off = right_x,
        .y_off = content_y,
        .width = right_w,
        .height = content_h,
        .border = .{
            .where = .all,
            .glyphs = .{ .custom = .{ "+", "-", "+", "|", "+", "+" } },
            .style = .{ .fg = border, .bg = bg },
        },
    });

    const max_rows: usize = left_inner.height;
    const start_idx: usize = if (app.selected >= max_rows and max_rows > 0) app.selected - max_rows + 1 else 0;
    var row: usize = 0;
    var i: usize = start_idx;
    while (i < app.snippets.items.len and row < max_rows) : (i += 1) {
        const is_sel = i == app.selected;
        const style: vaxis.Style = if (is_sel)
            .{ .fg = .{ .rgb = .{ 226, 232, 240 } }, .bg = selected_bg, .bold = true }
        else
            .{ .fg = muted, .bg = bg };
        try drawText(frame_alloc, left_inner, 0, @intCast(row), app.snippets.items[i].trigger, style);
        row += 1;
    }

    if (app.selectedSnippet()) |snip| {
        var iter = std.mem.splitScalar(u8, snip.expansion, '\n');
        var y: u16 = 0;
        while (iter.next()) |line| {
            if (y >= right_inner.height) break;
            try drawTextAscii(frame_alloc, right_inner, 0, y, line, .{ .fg = fg, .bg = bg });
            y += 1;
        }
    } else {
        try drawText(frame_alloc, right_inner, 0, 0, "No snippets found.", .{ .fg = muted, .bg = bg });
    }

    const status_bar = root.child(.{ .x_off = 0, .y_off = root.height - 1, .width = root.width, .height = 1 });
    status_bar.fill(.{ .char = .{ .grapheme = " " }, .style = .{ .bg = .{ .rgb = .{ 15, 23, 42 } }, .fg = .{ .rgb = .{ 203, 213, 225 } } } });
    try vx.render(tty_writer);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var tty_buf: [1024]u8 = undefined;
    var tty = try vaxis.Tty.init(&tty_buf);
    defer tty.deinit();

    var vx = try vaxis.init(alloc, .{});
    defer vx.deinit(alloc, tty.writer());

    var loop: vaxis.Loop(Event) = .{ .tty = &tty, .vaxis = &vx };
    try loop.init();
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminal(tty.writer(), 250 * std.time.ns_per_ms);

    var app = try App.init(alloc);
    defer app.deinit();

    while (true) {
        const event = loop.nextEvent();
        switch (event) {
            .winsize => |ws| try vx.resize(alloc, tty.writer(), ws),
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true }) or key.matches('q', .{})) break;
                if (key.matches('r', .{})) {
                    app.reload("Manual reload") catch app.setStatus("Manual reload failed", .{});
                } else if (key.matches('d', .{})) {
                    app.deleteSelected();
                } else if (key.matchesAny(&.{ vaxis.Key.down, 'j' }, .{})) {
                    if (app.selected + 1 < app.snippets.items.len) app.selected += 1;
                } else if (key.matchesAny(&.{ vaxis.Key.up, 'k' }, .{})) {
                    if (app.selected > 0) app.selected -= 1;
                } else if (key.matches(vaxis.Key.home, .{})) {
                    app.selected = 0;
                } else if (key.matches(vaxis.Key.end, .{})) {
                    if (app.snippets.items.len > 0) app.selected = app.snippets.items.len - 1;
                }
            },
        }

        try drawUi(&vx, &app, tty.writer());
    }
}
