//! A sample invoice that uses every feature of spider_pdf, written to the
//! path given as the first argument (`zig build pdf-sample`). Open it in a
//! few PDF readers after a change; `pdf/scripts/check.sh` validates it.

const std = @import("std");
const pdf = @import("spider_pdf");

const logo_png = @embedFile("assets/logo.png");
const photo_jpg = @embedFile("assets/photo.jpg");

const accent = pdf.Color.hex("#1e3a8a");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) return error.MissingOutputPath;

    var doc = try pdf.Document.init(allocator, .{ .info = .{
        .title = "Invoice 2026-0042",
        .author = "Zivyar Telecom",
        .subject = "Monthly services — October",
        .creator = "spider_pdf sample",
    } });
    defer doc.deinit();

    // Header: logo, title, a link.
    const logo = try doc.addImage(logo_png);
    try doc.image(logo, 40, 36, .{ .width = 48 });
    try doc.text(100, 62, "Invoice 2026-0042", .{ .font = .helvetica_bold, .size = 22, .color = accent });
    try doc.text(100, 80, "Issued on 19/10/2026 · due on 05/11/2026", .{ .size = 10, .color = pdf.Color.gray });
    const right = doc.width() - 40;
    try doc.text(right, 62, "spiderme.org", .{ .size = 10, .color = accent, .@"align" = .right });
    const link_w = pdf.Document.textWidth("spiderme.org", .helvetica, 10);
    try doc.link(right - link_w, 52, link_w, 12, "https://spiderme.org");
    try doc.line(40, 100, right, 100, .{ .color = pdf.Color.light_gray });

    // Customer box with rounded corners.
    try doc.rect(40, 114, doc.contentWidth(), 64, .{ .fill = pdf.Color.hex("#f8fafc"), .stroke = pdf.Color.light_gray, .radius = 6 });
    try doc.text(52, 134, "Bill to", .{ .font = .helvetica_bold, .size = 9, .color = pdf.Color.gray });
    try doc.text(52, 150, "José Antônio da Conceição — Rua São João, 1234, Ação Social, Goiânia", .{ .size = 11 });
    try doc.text(52, 166, "CPF 000.000.000-00 · “quoted” – dashes — and € signs", .{ .size = 9, .color = pdf.Color.gray });

    // Items, enough of them to flow onto a second page under a repeated header.
    doc.y = 196;
    const columns = [_]pdf.Column{
        .{ .header = "Description", .width = 285 },
        .{ .header = "Qty", .width = 50, .@"align" = .right },
        .{ .header = "Unit price", .width = 90, .@"align" = .right },
        .{ .header = "Total", .width = 90, .@"align" = .right },
    };
    var rows: std.ArrayList([]const []const u8) = .empty;
    defer rows.deinit(allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (0..34) |i| {
        const desc = if (i % 5 == 0)
            try std.fmt.allocPrint(a, "Fiber internet 600 Mbps, monthly plan for period {d}, with static IP, Wi-Fi 6 router rental and 24/7 support", .{i + 1})
        else
            try std.fmt.allocPrint(a, "Service item number {d}", .{i + 1});
        const row = try a.dupe([]const u8, &.{ desc, "1", "99,90", "99,90" });
        try rows.append(allocator, row);
    }
    try doc.table(&columns, rows.items, .{ .stripe = pdf.Color.hex("#f9fafb") });

    // Totals and notes, flowing after the table.
    doc.moveDown(12);
    try doc.ensureSpace(60);
    try doc.text(right, doc.y + 12, "Total: R$ 3.396,60", .{ .font = .helvetica_bold, .size = 14, .@"align" = .right });
    doc.moveDown(30);
    try doc.paragraph(
        "Payment by bank slip or PIX until the due date. After it, a 2% fine and 1% interest a month apply. " ++
            "This paragraph flows between the margins and wraps on its own; a long enough text goes on to the next page " ++
            "line by line, never cutting a line in half.",
        .{ .size = 10, .color = pdf.Color.gray },
    );
    doc.moveDown(10);
    try doc.paragraph("Courier for codes: 34191.79001 01043.510047 91020.150008 1 96610000039966", .{ .font = .courier, .size = 9 });

    // A JPEG, a circle and a dashed line.
    doc.moveDown(10);
    try doc.ensureSpace(110);
    const photo = try doc.addImage(photo_jpg);
    try doc.image(photo, 40, doc.y, .{ .height = 100 });
    try doc.circle(260, doc.y + 50, 40, .{ .fill = pdf.Color.hex("#fde68a"), .stroke = pdf.Color.hex("#f59e0b"), .line_width = 2 });
    try doc.line(320, doc.y + 50, right, doc.y + 50, .{ .dash = .{ 4, 3 }, .color = pdf.Color.gray });

    // A landscape page.
    try doc.addPageSized(pdf.Size.a4.landscape());
    try doc.text(40, 60, "A landscape page", .{ .font = .helvetica_bold, .size = 18 });
    _ = try doc.textBox(40, 80, 300, "Centered text in a box of 300 points, wrapped over several lines as needed by its length.", .{ .@"align" = .center });

    // Page numbers, once the page count is known.
    const total = doc.pageCount();
    for (0..total) |i| {
        try doc.setPage(i);
        var buf: [32]u8 = undefined;
        const label = try std.fmt.bufPrint(&buf, "Page {d} of {d}", .{ i + 1, total });
        try doc.text(doc.width() / 2, doc.height() - 20, label, .{ .size = 8, .color = pdf.Color.gray, .@"align" = .center });
    }

    const bytes = try doc.toBytes(allocator);
    defer allocator.free(bytes);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[1], .data = bytes });
}
