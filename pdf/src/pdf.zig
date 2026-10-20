//! PDF documents for Spider apps (`spider_pdf`): invoices, receipts,
//! reports and tickets drawn in Zig, with no external tool and no
//! dependency beyond `std`.
//!
//! Text in the standard fonts (Helvetica and Courier, with the Latin-1
//! accents) or in embedded TrueType fonts (any script the font has; only
//! the glyphs used are embedded), text wrapped in boxes and paragraphs
//! that flow over pages,
//! tables with repeated headers, lines, rectangles (rounded), ellipses,
//! PNG (with transparency) and JPEG images, links, document properties,
//! and compressed output. Coordinates are points from the top-left corner.
//!
//! Existing PDFs can be edited (`Editor`): rotate, remove, reorder and
//! copy pages between files (merge, split), stamp new content over a page,
//! set the document properties, fill form fields, and save.
//!
//! A Spider module (`spider_module` below) with no tables, routes or
//! settings: import it and use it. `send` answers a request with the
//! document.
//!
//! ```zig
//! const pdf = @import("spider_pdf");
//!
//! fn receipt(c: *spider.Ctx) !spider.Response {
//!     var doc = try pdf.Document.init(c.arena, .{ .info = .{ .title = "Receipt" } });
//!     defer doc.deinit();
//!     try doc.text(40, 60, "Receipt", .{ .font = .helvetica_bold, .size = 20 });
//!     doc.moveDown(40);
//!     try doc.table(&.{
//!         .{ .header = "Item", .width = 380 },
//!         .{ .header = "Amount", .width = 135, .@"align" = .right },
//!     }, &.{&.{ "Monthly plan", "99.90" }}, .{});
//!     return pdf.send(c, &doc, .{ .filename = "receipt.pdf" });
//! }
//! ```

const std = @import("std");
const spider = @import("spider");

const document = @import("document.zig");

pub const Document = document.Document;
pub const Options = document.Options;
pub const Info = document.Info;
pub const Size = document.Size;
pub const Color = document.Color;
pub const Align = document.Align;
pub const Font = document.Font;
pub const TextOptions = document.TextOptions;
pub const LineOptions = document.LineOptions;
pub const ShapeOptions = document.ShapeOptions;
pub const ImageOptions = document.ImageOptions;
pub const Image = document.Image;
pub const Column = document.Column;
pub const TableOptions = document.TableOptions;
pub const Error = document.Error;
pub const TableError = @import("table.zig").Error;
pub const ImageError = @import("image.zig").Error;
pub const FontError = @import("truetype.zig").Error;

const editor = @import("editor.zig");
/// Editing existing PDF files: pages, stamps, properties, forms.
pub const Editor = editor.Editor;
pub const EditError = editor.Error;
pub const ReadError = @import("reader.zig").Error;
pub const Properties = editor.Properties;
pub const Field = editor.Field;
pub const FieldKind = editor.FieldKind;
pub const LoadOptions = editor.LoadOptions;
pub const Permission = editor.Permission;

pub const spider_module = spider.module(.{
    .name = "pdf",
    .version = "0.1.0",
    .spider = ">=0.11.0 <0.12.0",
});

pub const SendOptions = struct {
    /// The name the browser offers to save the file under (made safe by
    /// Spider: it may come from user data).
    filename: []const u8 = "document.pdf",
    /// `.@"inline"` opens the PDF in the browser's viewer; `.attachment`
    /// downloads it.
    disposition: @FieldType(spider.DownloadOptions, "disposition") = .@"inline",
};

/// Answers the request with `doc` as a PDF file. The bytes are written in
/// the request's arena.
pub fn send(c: *spider.Ctx, doc: *Document, opts: SendOptions) !spider.Response {
    const bytes = try doc.toBytes(c.arena);
    return c.download(bytes, .{
        .filename = opts.filename,
        .content_type = spider.content_types.pdf,
        .disposition = opts.disposition,
    });
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("fonts.zig");
    _ = @import("text.zig");
    _ = @import("image.zig");
    _ = @import("document.zig");
    _ = @import("table.zig");
    _ = @import("truetype.zig");
    _ = @import("syntax.zig");
    _ = @import("filters.zig");
    _ = @import("reader.zig");
    _ = @import("editor.zig");
    _ = @import("crypt.zig");
}

test "the module manifest is pdf 0.1.0" {
    try std.testing.expectEqualStrings("pdf", spider_module.manifest.name);
    try std.testing.expectEqualStrings("0.1.0", spider_module.manifest.version);
}

fn testHandler(c: *spider.Ctx) !spider.Response {
    var doc = try Document.init(c.arena, .{});
    defer doc.deinit();
    try doc.text(40, 60, "Hello from a route", .{});
    return send(c, &doc, .{ .filename = "hello.pdf" });
}

fn testServe() !void {
    var server = spider.app(.{});
    defer server.deinit();
    try server
        .mountModules(.{@This()})
        .get("/hello.pdf", testHandler, .{ .public = true })
        .listen(.{});
}

test "send answers a request with the PDF, shown inline" {
    const app = try spider.testing.start(testServe);
    var res = try app.get("/hello.pdf");
    defer res.deinit();
    try res.expectStatus(200);
    try std.testing.expectEqualStrings("application/pdf", res.header("Content-Type").?);
    try std.testing.expect(std.mem.startsWith(u8, res.header("Content-Disposition").?, "inline"));
    try std.testing.expect(std.mem.indexOf(u8, res.header("Content-Disposition").?, "hello.pdf") != null);
    try std.testing.expect(std.mem.startsWith(u8, res.body, "%PDF-1.4"));
    try std.testing.expect(std.mem.endsWith(u8, res.body, "%%EOF\n"));
}
