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
  Unicode map so text can be copied, searched and extracted, and the
  font's kerning (GPOS or `kern`) applied, in measuring and wrapping too.
- **Wrapped text**: `textBox` (in a box, left, centered or right) and
  `paragraph` (between the margins, flowing over pages line by line).
- **Tables** that flow over pages: cells wrap, rows grow to their tallest
  cell, the header repeats on each page, optional stripes and grid.
- **Shapes**: lines (dashed), rectangles (filled, outlined, rounded),
  ellipses and circles.
- **Paths**: lines, cubic and quadratic Bezier curves, polygons, holes
  (even-odd); **gradients** (linear and radial, any number of color
  stops); **clipping** to any path (a round photo).
- **Bookmarks** (the outline panel, nested) and **links to pages** of the
  document.
- **Form fields**: text boxes (single or multiline), checkboxes, radio
  groups and drop-down lists, drawn already filled, ready for people to
  fill in (and readable by `Editor`).
- **Opacity** on text, shapes, lines and images, and **rotation** of text
  and images: a diagonal translucent watermark is
  `.{ .size = 110, .opacity = 0.08, .rotate = 35, .@"align" = .center }`.
- **Images**: PNG (gray, RGB, palette, every bit depth from 1 to 16, with
  transparency kept as a soft mask) and JPEG (embedded as it is). The same image drawn many times is
  stored once.
- **Links**, **document properties** (title, author... with accents),
  **page sizes** (A4, A5, Letter, Legal, custom, landscape, mixed in one
  document) and **compressed** page contents.

- **Editing existing PDFs** (`Editor`): rotate, remove, reorder and copy
  pages between files (merge, split), stamp new content over a page (a
  watermark, "PAID", a signature image) with the same drawing API, read and
  set the document properties, list and fill form fields (text, with
  their appearance drawn in the field's font, size and alignment; and
  checkboxes), save. Reads classic and stream cross-references, object
  streams and incremental updates, and repairs files whose
  cross-reference data is broken. Opens encrypted files (RC4 and AES-128
  and 256, revisions 2 to 6) that need no password, which is most
  "protected" PDFs, or with the user or owner password; they are saved
  decrypted, and their permissions are reported (`ed.allows(.modify)`).

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

Shapes, gradients and clipping:

```zig
var heart = doc.path();
try heart.moveTo(220, 205);
try heart.curveTo(160, 165, 185, 120, 220, 150);
try heart.curveTo(255, 120, 280, 165, 220, 205);
try heart.close();
try doc.drawPath(&heart, .{ .fill = pdf.Color.hex("#e11d48") });

try doc.rect(40, 40, 515, 60, .{ .radius = 10, .gradient = pdf.Gradient.linear(40, 0, 555, 0, &.{
    .{ .offset = 0, .color = pdf.Color.hex("#1e3a8a") },
    .{ .offset = 1, .color = pdf.Color.hex("#38bdf8") },
}) });

try doc.saveState(); // a round photo
var round = doc.path();
try round.ellipse(455, 170, 38, 38);
try doc.clip(&round, .{});
try doc.image(photo, 400, 120, .{ .height = 100 });
try doc.restoreState();
```

Bookmarks, links inside the document, and a form:

```zig
const ch1 = try doc.addBookmark("1. Contract", .{}); // current page and cursor
_ = try doc.addBookmark("1.1 Parties", .{ .parent = ch1, .page = 0, .y = 300 });
try doc.linkToPage(40, 430, 120, 12, 0, .{}); // a click goes to page 1

try doc.textField("customer.name", 40, 256, 250, 22, .{ .value = "José" });
try doc.dropdown("customer.city", 310, 256, 160, 22, &.{ "Goiânia", "Brasília" }, .{});
try doc.radioGroup("plan", &.{ .{ .value = "basic", .x = 40, .y = 384 }, .{ .value = "pro", .x = 120, .y = 384 } }, 12, .{ .selected = "pro" });
try doc.checkbox("agree", 220, 384, 12, .{ .checked = true });
```

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

### Editing a PDF that already exists

```zig
var ed = try pdf.Editor.load(allocator, uploaded_bytes); // bytes outlive the editor
defer ed.deinit();
// An encrypted file with a password: pdf.Editor.loadWith(allocator, bytes, .{ .password = pw })
if (!ed.allows(.modify)) return error.Forbidden; // the app decides whether to honor it

try ed.rotatePage(0, 90);
try ed.removePage(ed.pageCount() - 1);
try ed.movePage(2, 0);

// Merge: pages of another file (any order, repeats allowed)
var annex = try pdf.Editor.load(allocator, annex_bytes);
defer annex.deinit();
try ed.importPages(&annex, &.{ 0, 1, 2 });

// Stamp: draw on a Document the size of the page, then lay it over the page
var paid = try pdf.Document.init(allocator, .{ .size = try ed.pageSize(0) });
defer paid.deinit();
try paid.text(420, 70, "PAID", .{ .font = .helvetica_bold, .size = 28, .color = pdf.Color.hex("#16a34a") });
try ed.stamp(0, &paid, 0);

// Properties and forms
try ed.setProperties(.{ .title = "Contrato 42" });
for (try ed.fields()) |f| std.debug.print("{s} ({s}) = {?s}\n", .{ f.name, @tagName(f.kind), f.value });
try ed.setText("customer.name", "Maria José");
try ed.setCheckbox("agree", true);

const out = try ed.save(allocator); // a complete new file
defer allocator.free(out);
```

A split is a new file from some pages: load the source, load (or make) a
target, `importPages`, and remove the target's own pages.

The module declares a manifest (`pdf` 0.1.0) but has no tables, routes or
settings: mounting it with `server.mountModules` is optional.

## Limits (for now)

- The standard fonts write WinAnsi characters only (anything else becomes
  `?`); use an embedded font for the rest. A character an embedded font
  lacks is written as its `?`.
- Embedded fonts: TrueType outlines only (no CFF `.otf`, no `.ttc`
  collections); kerning yes, but no ligatures or complex shaping (Arabic,
  Indic scripts need a shaper); text runs left to right. The standard
  fonts are not kerned.
- Interlaced PNG is refused by name; images over 10,000 pixels on a side
  too.
- Editing: an encrypted file that needs a password fails with
  `error.EncryptedPdf` (`error.WrongPassword` for a wrong one); passwords
  are not SASLprep-normalized (a revision 6 password with characters that
  Unicode normalization changes may not open); public-key encryption is
  refused; a save writes a new file, so a digital signature
  the file had no longer validates; a filled text field's appearance is drawn
  with WinAnsi characters only (others become `?`; the form also asks
  readers to redraw, which Acrobat, browsers and Preview do); comb fields
  are drawn as plain text; form fields of imported pages are not merged into the
  form of the target; stamps go in the page's unrotated space.
- It does not render PDFs or extract their text.

## Tests

```sh
zig build test-pdf        # unit tests, including a request through Spider
pdf/scripts/check.sh      # the sample through qpdf, pdftotext and pdffonts (PDF_FONT=x.ttf, or Noto Sans)
zig build pdf-sample      # writes zig-out/pdf-sample.pdf to open in readers
zig build pdf-sample -Dpdf-font=x.ttf   # with a page in an embedded font
zig build pdf-roundtrip   # zig-out/bin/pdf-roundtrip in.pdf out.pdf: load and save a file made elsewhere
```

`pdf/examples/sample.zig` uses every feature; open its output in a few
readers (a browser, Evince/Okular, Acrobat, Preview) after a change.

The design started from the PDF writer of an app in production (bank slips,
telecom invoices, receipts) and was checked against jsPDF and pdf-lib.
