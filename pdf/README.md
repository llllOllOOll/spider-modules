# spider_pdf

PDF documents for Spider apps: invoices, receipts, statements, reports and
tickets, drawn in Zig. No external tool (no headless browser, no
LibreOffice) and no dependency beyond `std`.

- **Text** in the standard Helvetica and Courier (regular, bold, oblique,
  bold oblique), which every reader has, written as WinAnsi: the Latin-1
  accents, curly quotes, dashes, the bullet and the euro sign. Widths are
  the fonts' own, so right-aligned and centered text lines up.
- **Embedded TrueType fonts** (`addFont`): any .ttf, any script the font
  covers (Cyrillic, Greek, Central European, Vietnamese, emoji...). Only the
  glyphs drawn are embedded (a 600 KB font adds about 25 KB), with a
  Unicode map so text can be copied, searched and extracted.
- **Wrapped text**: `textBox` (in a box, left, centered or right) and
  `paragraph` (between the margins, flowing over pages line by line).
- **Tables** that flow over pages: cells wrap, rows grow to their tallest
  cell, the header repeats on each page, optional stripes and grid.
- **Shapes**: lines (dashed), rectangles (filled, outlined, rounded),
  ellipses and circles.
- **Images**: PNG (gray, RGB, palette, with transparency kept as a soft
  mask) and JPEG (embedded as it is). The same image drawn many times is
  stored once.
- **Links**, **document properties** (title, author... with accents),
  **page sizes** (A4, A5, Letter, Legal, custom, landscape, mixed in one
  document) and **compressed** page contents.

Coordinates are points (1/72 inch) from the **top-left** corner.

## Use

```zig
// build.zig — the module gets the app's own spider
const modules_dep = b.dependency("spider_modules", .{});
const pdf_mod = b.createModule(.{
    .root_source_file = modules_dep.path("pdf/src/pdf.zig"),
    .target = target,
    .imports = &.{.{ .name = "spider", .module = spider_mod }},
});
exe.root_module.addImport("spider_pdf", pdf_mod);
```

```zig
const pdf = @import("spider_pdf");

fn receipt(c: *spider.Ctx) !spider.Response {
    var doc = try pdf.Document.init(c.arena, .{ .info = .{ .title = "Receipt 42" } });
    defer doc.deinit();

    const logo = try doc.addImage(@embedFile("logo.png"));
    try doc.image(logo, 40, 36, .{ .width = 48 });
    try doc.text(100, 64, "Receipt 42", .{ .font = .helvetica_bold, .size = 20 });

    doc.y = 110; // the flowing cursor
    try doc.table(&.{
        .{ .header = "Item", .width = 380 },
        .{ .header = "Amount", .width = 135, .@"align" = .right },
    }, &.{
        &.{ "Monthly plan", "99,90" },
        &.{ "Installation", "150,00" },
    }, .{ .stripe = pdf.Color.hex("#f9fafb") });

    doc.moveDown(12);
    try doc.paragraph("Thank you. Payment received by PIX.", .{ .color = pdf.Color.gray });

    return pdf.send(c, &doc, .{ .filename = "receipt-42.pdf" }); // inline; .attachment downloads
}
```

Any other font, any script:

```zig
const inter = try doc.addFont(@embedFile("fonts/Inter-Regular.ttf"));
try doc.paragraph("Привет, Αθήνα, Zażółć gęślą jaźń", .{ .font = inter, .size = 12 });
const w = doc.textWidth("measured in that font", inter, 12);
```

The font's bytes must outlive the document (`@embedFile`, or freed after
`toBytes`). An `.otf` with PostScript outlines (CFF) is refused with
`error.UnsupportedFont`, a font whose license forbids embedding with
`error.FontNotEmbeddable`.

Page numbers once the page count is known:

```zig
for (0..doc.pageCount()) |i| {
    try doc.setPage(i);
    var buf: [32]u8 = undefined;
    const label = try std.fmt.bufPrint(&buf, "Page {d} of {d}", .{ i + 1, doc.pageCount() });
    try doc.text(doc.width() / 2, doc.height() - 20, label, .{ .size = 8, .@"align" = .center });
}
```

Outside a request, `doc.toBytes(allocator)` returns the file.

The module declares a manifest (`pdf` 0.1.0) but has no tables, routes or
settings: mounting it with `server.mountModules` is optional.

## Limits (for now)

- The standard fonts write WinAnsi characters only (anything else becomes
  `?`); use an embedded font for the rest. A character an embedded font
  lacks is written as its `?`.
- Embedded fonts: TrueType outlines only (no CFF `.otf`, no `.ttc`
  collections); no kerning, ligatures or complex shaping (Arabic, Indic
  scripts need a shaper); text runs left to right.
- PNG with 16 bits per channel and interlaced PNG are refused by name;
  images over 10,000 pixels on a side too.
- It writes PDFs; it does not read or edit existing ones.

## Tests

```sh
zig build test-pdf        # unit tests, including a request through Spider
pdf/scripts/check.sh      # the sample through qpdf, pdftotext and pdffonts (PDF_FONT=x.ttf, or Noto Sans)
zig build pdf-sample      # writes zig-out/pdf-sample.pdf to open in readers
zig build pdf-sample -Dpdf-font=x.ttf   # with a page in an embedded font
```

`pdf/examples/sample.zig` uses every feature; open its output in a few
readers (a browser, Evince/Okular, Acrobat, Preview) after a change.

The design started from the PDF writer of an app in production (bank slips,
telecom invoices, receipts) and was checked against jsPDF and pdf-lib.
