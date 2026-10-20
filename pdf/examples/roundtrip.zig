//! Loads PDF files and saves them again with spider_pdf's Editor, to try
//! the reader on files made by other tools: `zig build pdf-roundtrip`, then
//! `zig-out/bin/pdf-roundtrip in.pdf out.pdf` (or `in.pdf` alone to only
//! read it). Prints the page count and whether the file needed repair. An
//! encrypted file's password goes in the PDF_PASSWORD variable.

const std = @import("std");
const pdf = @import("spider_pdf");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.debug.print("usage: pdf-roundtrip in.pdf [out.pdf]\n", .{});
        return error.MissingArgument;
    }
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], init.arena.allocator(), .limited(512 << 20));
    const password = init.environ_map.get("PDF_PASSWORD") orelse "";
    var ed = pdf.Editor.loadWith(init.gpa, bytes, .{ .password = password }) catch |err| {
        std.debug.print("{s}: {s}\n", .{ args[1], @errorName(err) });
        return err;
    };
    defer ed.deinit();
    std.debug.print("{s}: {d} pages{s}{s}\n", .{ args[1], ed.pageCount(), if (ed.repaired) " (repaired)" else "", if (ed.encrypted) " (decrypted)" else "" });
    if (args.len >= 3) {
        const out = try ed.save(init.gpa);
        defer init.gpa.free(out);
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[2], .data = out });
    }
}
