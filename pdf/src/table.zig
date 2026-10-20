//! Tables that flow over pages: a header row, then the rows, each as tall
//! as its tallest cell (cell text wraps to the column width). A row that
//! does not fit above the bottom margin starts a new page, where the
//! header is drawn again. Rows are never split between pages.

const std = @import("std");
const doc_mod = @import("document.zig");
const Document = doc_mod.Document;
const Color = doc_mod.Color;
const Align = doc_mod.Align;
const Font = doc_mod.Font;

pub const Column = struct {
    header: []const u8 = "",
    /// Width in points.
    width: f32,
    @"align": Align = .left,
};

pub const TableOptions = struct {
    font: Font = .helvetica,
    header_font: Font = .helvetica_bold,
    size: f32 = 9,
    color: Color = Color.black,
    header_color: Color = Color.black,
    /// Space between a cell's border and its text.
    padding: f32 = 4,
    line_height: f32 = 1.25,
    /// Background of the header row; null for none.
    header_fill: ?Color = .{ .r = 0xf3, .g = 0xf4, .b = 0xf6 },
    /// Background of every other row; null for none.
    stripe: ?Color = null,
    /// Color of the grid lines; null draws none.
    border: ?Color = Color.light_gray,
    /// Draw the header again at the top of each new page.
    repeat_header: bool = true,
};

pub const Error = error{
    /// A row taller than a whole page: it could never be placed.
    RowTooTall,
};

/// Draws the table at the document's cursor, starting at the left margin,
/// and leaves the cursor below its last row. A row with fewer cells than
/// columns leaves the rest empty; extra cells are ignored.
pub fn draw(doc: *Document, columns: []const Column, rows: []const []const []const u8, opts: TableOptions) !void {
    const x = doc.options.margin;
    var headers_buf: [64][]const u8 = undefined;
    const has_header = for (columns) |c| {
        if (c.header.len > 0) break true;
    } else false;
    const header_cells = headers_buf[0..@min(columns.len, headers_buf.len)];
    for (header_cells, columns[0..header_cells.len]) |*h, c| h.* = c.header;

    const header_h = if (has_header) try rowHeight(doc, columns, header_cells, opts, opts.header_font) else 0;
    var first_on_page = true;

    if (has_header) {
        try doc.ensureSpace(header_h);
        try drawRow(doc, x, columns, header_cells, header_h, opts, opts.header_font, opts.header_color, opts.header_fill, true);
        first_on_page = false;
    }

    for (rows, 0..) |row, n| {
        const h = try rowHeight(doc, columns, row, opts, opts.font);
        const room = doc.bottom() - doc.options.margin - (if (has_header and opts.repeat_header) header_h else 0);
        if (h > room) return Error.RowTooTall;
        if (doc.y + h > doc.bottom()) {
            try doc.addPage();
            first_on_page = true;
            if (has_header and opts.repeat_header) {
                try drawRow(doc, x, columns, header_cells, header_h, opts, opts.header_font, opts.header_color, opts.header_fill, true);
                first_on_page = false;
            }
        }
        const fill = if (n % 2 == 1) opts.stripe else null;
        try drawRow(doc, x, columns, row, h, opts, opts.font, opts.color, fill, first_on_page);
        first_on_page = false;
    }
}

fn cell(row: []const []const u8, i: usize) []const u8 {
    return if (i < row.len) row[i] else "";
}

fn textOptions(opts: TableOptions, font: Font, color: Color, a: Align) doc_mod.TextOptions {
    return .{ .font = font, .size = opts.size, .color = color, .@"align" = a, .line_height = opts.line_height };
}

fn rowHeight(doc: *Document, columns: []const Column, row: []const []const u8, opts: TableOptions, font: Font) !f32 {
    var tallest: f32 = opts.size * opts.line_height; // an empty row keeps one line
    for (columns, 0..) |c, i| {
        const h = try doc.measureText(cell(row, i), c.width - 2 * opts.padding, textOptions(opts, font, opts.color, c.@"align"));
        tallest = @max(tallest, h);
    }
    return tallest + 2 * opts.padding;
}

fn drawRow(doc: *Document, x: f32, columns: []const Column, row: []const []const u8, h: f32, opts: TableOptions, font: Font, color: Color, fill: ?Color, top_line: bool) !void {
    const y = doc.y;
    var total: f32 = 0;
    for (columns) |c| total += c.width;

    if (fill) |f| try doc.rect(x, y, total, h, .{ .fill = f, .stroke = null, .line_width = 0 });

    var cx = x;
    for (columns, 0..) |c, i| {
        _ = try doc.textBox(cx + opts.padding, y + opts.padding, c.width - 2 * opts.padding, cell(row, i), textOptions(opts, font, color, c.@"align"));
        cx += c.width;
    }

    // Grid lines drawn once each: neighbouring cells share their borders,
    // and a border drawn twice prints thicker.
    if (opts.border) |b| {
        const lo: doc_mod.LineOptions = .{ .color = b, .width = 0.5 };
        if (top_line) try doc.line(x, y, x + total, y, lo);
        try doc.line(x, y + h, x + total, y + h, lo);
        cx = x;
        try doc.line(cx, y, cx, y + h, lo);
        for (columns) |c| {
            cx += c.width;
            try doc.line(cx, y, cx, y + h, lo);
        }
    }
    doc.y = y + h;
}

// ── Tests ───────────────────────────────────────────────────────────────

const t = std.testing;

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

const cols = [_]Column{
    .{ .header = "Item", .width = 120 },
    .{ .header = "Amount", .width = 80, .@"align" = .right },
};

test "a table writes its header and cells and moves the cursor below it" {
    var doc = try Document.init(t.allocator, .{ .compress = false });
    defer doc.deinit();
    const start = doc.y;
    try doc.table(&cols, &.{
        &.{ "Monthly plan", "99.90" },
        &.{ "Installation", "150.00" },
    }, .{});
    const c = doc.pages.items[0].content.items;
    try t.expect(contains(c, "(Item) Tj"));
    try t.expect(contains(c, "(Amount) Tj"));
    try t.expect(contains(c, "(Monthly plan) Tj"));
    try t.expect(contains(c, "(150.00) Tj"));
    // Three rows of one line: 9 * 1.25 + 2 * 4 = 19.25 points each.
    try t.expectApproxEqAbs(start + 3 * 19.25, doc.y, 0.01);
}

test "a long cell wraps and makes its row taller" {
    var doc = try Document.init(t.allocator, .{ .compress = false });
    defer doc.deinit();
    const start = doc.y;
    try doc.table(&cols, &.{&.{ "A description long enough to need three lines here", "1.00" }}, .{ .header_fill = null });
    try t.expect(doc.y - start > 2 * 19.25);
}

test "rows that do not fit go to new pages, under a repeated header" {
    var doc = try Document.init(t.allocator, .{ .compress = false, .size = .{ .width = 300, .height = 200 }, .margin = 20 });
    defer doc.deinit();
    var rows: [20][]const []const u8 = undefined;
    for (&rows) |*r| r.* = &.{ "row", "1" };
    try doc.table(&cols, &rows, .{});
    try t.expect(doc.pageCount() >= 3);
    for (doc.pages.items) |p| try t.expect(contains(p.content.items, "(Item) Tj"));
    try t.expect(doc.y <= doc.bottom());
}

test "the header is drawn once when repeat_header is off" {
    var doc = try Document.init(t.allocator, .{ .compress = false, .size = .{ .width = 300, .height = 200 }, .margin = 20 });
    defer doc.deinit();
    var rows: [20][]const []const u8 = undefined;
    for (&rows) |*r| r.* = &.{ "row", "1" };
    try doc.table(&cols, &rows, .{ .repeat_header = false });
    try t.expect(contains(doc.pages.items[0].content.items, "(Item) Tj"));
    try t.expect(!contains(doc.pages.items[1].content.items, "(Item) Tj"));
}

test "missing cells are empty, extra cells are ignored, and stripes alternate" {
    var doc = try Document.init(t.allocator, .{ .compress = false });
    defer doc.deinit();
    try doc.table(&cols, &.{ &.{"only one"}, &.{ "a", "b", "ignored" } }, .{ .stripe = Color.hex("#fafafa"), .header_fill = null });
    const c = doc.pages.items[0].content.items;
    try t.expect(contains(c, "(only one) Tj"));
    try t.expect(!contains(c, "(ignored)"));
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, c, "0.980 0.980 0.980 rg"));
}

test "a row taller than a page is refused" {
    var doc = try Document.init(t.allocator, .{ .size = .{ .width = 200, .height = 100 }, .margin = 10 });
    defer doc.deinit();
    const narrow = [_]Column{.{ .width = 30 }};
    try t.expectError(Error.RowTooTall, doc.table(&narrow, &.{&.{"many words that will never fit in such a tiny column of a tiny page"}}, .{}));
}
