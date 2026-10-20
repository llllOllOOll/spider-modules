//! A sample invoice that uses every feature of spider_pdf, written to the
//! path given as the first argument (`zig build pdf-sample`). A TrueType
//! font given as the second argument (`zig build pdf-sample -Dpdf-font=font.ttf`)
//! adds a page of text in it, in scripts WinAnsi lacks. Open the result in
//! a few PDF readers after a change; `pdf/scripts/check.sh` validates it.

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
    const link_w = doc.textWidth("spiderme.org", .helvetica, 10);
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

    // Drawing and a form, on a page of their own.
    try doc.addPage();
    _ = try doc.addBookmark("Drawing and forms", .{ .y = 40 });
    const band = [_]pdf.GradientStop{
        .{ .offset = 0, .color = pdf.Color.hex("#1e3a8a") },
        .{ .offset = 0.6, .color = pdf.Color.hex("#38bdf8") },
        .{ .offset = 1, .color = pdf.Color.hex("#f0f9ff") },
    };
    try doc.rect(40, 40, doc.contentWidth(), 60, .{ .gradient = pdf.Gradient.linear(40, 0, 40 + doc.contentWidth(), 0, &band), .radius = 10 });
    try doc.text(56, 78, "Paths, gradients, clipping and forms", .{ .font = .helvetica_bold, .size = 16, .color = pdf.Color.white });

    // A five-pointed star, a heart of curves, a ring with a hole.
    var star: [10][2]f32 = undefined;
    for (&star, 0..) |*pt, i| {
        const angle = @as(f32, @floatFromInt(i)) * std.math.pi / 5.0 - std.math.pi / 2.0;
        const r: f32 = if (i % 2 == 0) 40 else 16;
        pt.* = .{ 100 + r * @cos(angle), 170 + r * @sin(angle) };
    }
    try doc.polygon(&star, .{ .gradient = pdf.Gradient.radial(100, 170, 40, &.{ .{ .offset = 0, .color = pdf.Color.hex("#fde68a") }, .{ .offset = 1, .color = pdf.Color.hex("#f59e0b") } }), .stroke = pdf.Color.hex("#b45309") });
    var heart = doc.path();
    try heart.moveTo(220, 205);
    try heart.curveTo(160, 165, 185, 120, 220, 150);
    try heart.curveTo(255, 120, 280, 165, 220, 205);
    try heart.close();
    try doc.drawPath(&heart, .{ .fill = pdf.Color.hex("#e11d48") });
    var ring = doc.path();
    try ring.ellipse(330, 170, 38, 38);
    try ring.ellipse(330, 170, 20, 20);
    try doc.drawPath(&ring, .{ .fill = pdf.Color.hex("#16a34a"), .even_odd = true });

    // The photo, clipped to a circle.
    try doc.saveState();
    var round = doc.path();
    try round.ellipse(455, 170, 38, 38);
    try doc.clip(&round, .{});
    try doc.image(photo, 400, 120, .{ .height = 100 });
    try doc.restoreState();
    try doc.circle(455, 170, 38, .{ .stroke = pdf.Color.light_gray, .line_width = 2 });

    // A form, filled already, that people can change.
    _ = try doc.addBookmark("Form", .{ .y = 240 });
    try doc.text(40, 250, "Name", .{ .size = 9, .color = pdf.Color.gray });
    try doc.textField("customer.name", 40, 256, 250, 22, .{ .value = "José da Conceição" });
    try doc.text(310, 250, "City", .{ .size = 9, .color = pdf.Color.gray });
    try doc.dropdown("customer.city", 310, 256, 160, 22, &.{ "Goiânia", "Brasília", "São Paulo" }, .{ .value = "Goiânia" });
    try doc.text(40, 300, "Notes", .{ .size = 9, .color = pdf.Color.gray });
    try doc.textField("notes", 40, 306, 430, 60, .{ .multiline = true, .value = "Multiline fields wrap their text, and a reader lets people type more of it." });
    try doc.radioGroup("plan", &.{ .{ .value = "basic", .x = 40, .y = 384 }, .{ .value = "pro", .x = 120, .y = 384 } }, 12, .{ .selected = "pro" });
    try doc.text(56, 394, "Basic", .{ .size = 10 });
    try doc.text(136, 394, "Pro", .{ .size = 10 });
    try doc.checkbox("agree", 220, 384, 12, .{ .checked = true });
    try doc.text(236, 394, "I agree with the terms", .{ .size = 10 });

    // A link back to the first page, and bookmarks for the others.
    try doc.text(40, 440, "Back to the invoice", .{ .size = 10, .color = accent });
    try doc.linkToPage(40, 430, doc.textWidth("Back to the invoice", .helvetica, 10), 12, 0, .{});
    _ = try doc.addBookmark("Invoice", .{ .page = 0, .y = 40 });

    // An embedded TrueType font, when one is given.
    if (args.len >= 3) {
        const font_bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, args[2], init.arena.allocator(), .limited(32 << 20));
        const font = try doc.addFont(font_bytes);
        try doc.addPage();
        try doc.text(40, 60, "An embedded TrueType font", .{ .font = font, .size = 20, .color = accent });
        doc.y = 80;
        try doc.paragraph("Русский: Съешь же ещё этих мягких французских булок.", .{ .font = font });
        try doc.paragraph("Ελληνικά: Ξεσκεπάζω την ψυχοφθόρα βδελυγμία.", .{ .font = font });
        try doc.paragraph("Polski: Zażółć gęślą jaźń. Türkçe: Pijamalı hasta yağız şoföre çabucak güvendi.", .{ .font = font });
        try doc.paragraph("Português: Não há ação sem coração — “aspas”, € e º.", .{ .font = font });
        try doc.paragraph("Kerning: AVATAR WAVY Toyota Yawn LT P. VA", .{ .font = font, .size = 22 });
        doc.moveDown(10);
        try doc.table(&.{
            .{ .header = "Город", .width = 200 },
            .{ .header = "Πόλη", .width = 200 },
            .{ .header = "Ł", .width = 115, .@"align" = .right },
        }, &.{
            &.{ "Москва", "Αθήνα", "1" },
            &.{ "Санкт-Петербург", "Θεσσαλονίκη", "2" },
        }, .{ .font = font, .header_font = font });
    }

    // A translucent diagonal watermark on the first page, and a turned logo.
    try doc.setPage(0);
    try doc.text(doc.width() / 2, doc.height() / 2 + 60, "SAMPLE", .{ .font = .helvetica_bold, .size = 110, .color = accent, .opacity = 0.08, .rotate = 35, .@"align" = .center });
    try doc.image(logo, doc.width() - 70, 120, .{ .width = 24, .rotate = 30, .opacity = 0.6 });

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
