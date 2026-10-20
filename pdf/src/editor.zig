//! Editing existing PDF files: count, rotate, remove, reorder and copy
//! pages between documents (merge, split), stamp new content over a page
//! (with the drawing API of `Document`), read and set the document
//! properties, fill form fields, and save.
//!
//! `Editor.load` reads every object of the file (see reader.zig: classic
//! and stream cross-references, object streams, incremental updates,
//! repair of broken files). `save` writes a new, complete file: only the
//! objects still reachable from the document are written, renumbered, with
//! a single flat page tree, so pages that were removed take their content
//! with them.
//!
//! Encrypted files open when their user password is empty (the usual
//! "protected" PDF) or with `loadWith(.{ .password = ... })`, user or owner
//! password; they are saved decrypted. Their permissions are reported by
//! `allows`, for the application to honor.
//!
//! Not supported: public-key encryption, and signing (a save rewrites the
//! file, so it would break an existing signature).

const std = @import("std");
const syntax = @import("syntax.zig");
const reader = @import("reader.zig");
const filters = @import("filters.zig");
const document = @import("document.zig");
const fonts = @import("fonts.zig");

const Object = syntax.Object;
const Dict = syntax.Dict;
const Ref = syntax.Ref;

pub const Error = error{
    /// A page index past the last page.
    NoSuchPage,
    /// A rotation that is not a multiple of 90 degrees.
    InvalidRotation,
    /// No form field with that name.
    NoSuchField,
    /// The field exists but is of another kind (a checkbox set as text...).
    WrongFieldKind,
};

/// The document properties as read from a file, in UTF-8.
pub const Properties = struct {
    title: ?[]const u8 = null,
    author: ?[]const u8 = null,
    subject: ?[]const u8 = null,
    keywords: ?[]const u8 = null,
    creator: ?[]const u8 = null,
    producer: ?[]const u8 = null,
};

pub const LoadOptions = struct {
    /// The user or the owner password; empty opens files that need none.
    password: []const u8 = "",
};

/// What an encrypted file's author allows (its /P flags). A file that is
/// not encrypted allows everything.
pub const Permission = enum(u5) {
    print = 3,
    modify = 4,
    copy = 5,
    annotate = 6,
    fill_forms = 9,
    extract_for_accessibility = 10,
    assemble = 11,
    print_high_quality = 12,
};

pub const FieldKind = enum { text, checkbox, radio, button, choice, signature, unknown };

/// A form field: its full name (`parent.child`), kind and current value
/// (text, or the state name of a checkbox or radio button; null when not
/// set).
pub const Field = struct {
    name: []const u8,
    kind: FieldKind,
    value: ?[]const u8,
    num: u32,
};

const inheritable = [_][]const u8{ "Resources", "MediaBox", "CropBox", "Rotate" };

pub const Editor = struct {
    arena: std.heap.ArenaAllocator,
    objects: std.ArrayList(?Object) = .empty,
    root: u32 = 0,
    info_num: ?u32 = null,
    id: ?Object = null,
    /// The pages, in order, by object number.
    pages: std.ArrayList(u32) = .empty,
    /// Page tree nodes and pages of the loaded files: a reference to one of
    /// these that is not in `pages` is written as null.
    tree: std.AutoHashMap(u32, void),
    /// The file needed repair to be read (its cross-reference data was
    /// wrong or missing).
    repaired: bool = false,
    /// The file was encrypted: it was decrypted on load and saves without
    /// encryption.
    encrypted: bool = false,
    permissions: ?i32 = null,
    stamps: u32 = 0,

    /// Reads a PDF file. `bytes` must outlive the editor: stream data
    /// points into it.
    ///
    /// ```zig
    /// var ed = try pdf.Editor.load(allocator, file_bytes);
    /// defer ed.deinit();
    /// try ed.rotatePage(0, 90);
    /// try ed.removePage(ed.pageCount() - 1);
    /// const out = try ed.save(allocator);
    /// defer allocator.free(out);
    /// ```
    pub fn load(allocator: std.mem.Allocator, bytes: []const u8) !Editor {
        return loadWith(allocator, bytes, .{});
    }

    /// `load` with options: the password of an encrypted file.
    pub fn loadWith(allocator: std.mem.Allocator, bytes: []const u8, options: LoadOptions) !Editor {
        var ed: Editor = .{ .arena = .init(allocator), .tree = undefined };
        errdefer ed.arena.deinit();
        const a = ed.arena.allocator();
        ed.tree = .init(a);
        const file = try reader.load(a, bytes, options.password);
        ed.repaired = file.repaired;
        ed.encrypted = file.encrypted;
        ed.permissions = file.permissions;
        try ed.objects.appendSlice(a, file.objects);
        if (ed.objects.items.len == 0) try ed.objects.append(a, null); // object 0 is never used

        ed.root = try ed.adopt(file.trailer.get("Root") orelse return reader.Error.InvalidPdf);
        if (file.trailer.get("Info")) |info| {
            if (ed.resolve(info) == .dict) ed.info_num = try ed.adopt(info);
        }
        ed.id = file.trailer.get("ID");

        const catalog = ed.resolve(.{ .ref = .{ .num = ed.root } });
        if (catalog != .dict) return reader.Error.InvalidPdf;
        const pages_root = catalog.dict.get("Pages") orelse return reader.Error.InvalidPdf;
        try ed.flatten(pages_root, .{}, 0);
        // No page at all: nothing was readable (a filter nobody decodes
        // hid the page tree, say).
        if (ed.pages.items.len == 0) return reader.Error.InvalidPdf;
        return ed;
    }

    pub fn deinit(self: *Editor) void {
        self.arena.deinit();
    }

    /// Whether the file's author allows `p` (always true for a file that is
    /// not encrypted). Not enforced by the editor: the application decides.
    pub fn allows(self: *const Editor, p: Permission) bool {
        const flags = self.permissions orelse return true;
        return flags & (@as(i32, 1) << (@backingInt(p) - 1)) != 0;
    }

    fn alloc(self: *Editor) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn get(self: *Editor, num: u32) ?Object {
        if (num >= self.objects.items.len) return null;
        return self.objects.items[num];
    }

    fn resolve(self: *Editor, obj: Object) Object {
        var o = obj;
        var hops: usize = 0;
        while (o == .ref and hops < 32) : (hops += 1) o = self.get(o.ref.num) orelse return .null;
        return o;
    }

    fn add(self: *Editor, obj: Object) !u32 {
        try self.objects.append(self.alloc(), obj);
        return @intCast(self.objects.items.len - 1);
    }

    /// The number of the object `obj` refers to, making it an indirect
    /// object first when it is a direct one.
    fn adopt(self: *Editor, obj: Object) !u32 {
        if (obj == .ref) return obj.ref.num;
        return self.add(obj);
    }

    const Inherited = struct { values: [inheritable.len]?Object = @splat(null) };

    /// Collects the pages in order and gives each page the attributes it
    /// inherited from the tree (resources, page box, rotation): the tree
    /// is rebuilt flat on save.
    fn flatten(self: *Editor, node_obj: Object, inherited: Inherited, depth: usize) !void {
        if (depth > 64) return reader.Error.InvalidPdf;
        var num = try self.adopt(node_obj);
        const node = self.resolve(.{ .ref = .{ .num = num } });
        if (node != .dict) return;
        const d = node.dict;
        const is_page = d.get("Kids") == null or d.hasName("Type", "Page");
        if (self.tree.contains(num)) {
            // A node met twice is a loop; a page met twice is listed twice,
            // as readers show it: it gets an object of its own.
            if (!is_page) return;
            num = try self.add(.{ .dict = try d.clone(self.alloc()) });
        }
        try self.tree.put(num, {});

        if (d.get("Kids")) |kids_obj| {
            if (!is_page) {
                var inh = inherited;
                for (inheritable, 0..) |key, i| {
                    if (d.get(key)) |v| inh.values[i] = v;
                }
                const kids = self.resolve(kids_obj);
                if (kids != .array) return;
                for (kids.array) |kid| try self.flatten(kid, inh, depth + 1);
                return;
            }
        }
        var page = try d.clone(self.alloc());
        for (inheritable, 0..) |key, i| {
            if (page.get(key) == null) {
                if (inherited.values[i]) |v| try page.put(self.alloc(), key, v);
            }
        }
        if (page.get("MediaBox") == null) try page.put(self.alloc(), "MediaBox", try numbers(self.alloc(), &.{ 0, 0, 612, 792 }));
        self.objects.items[num] = .{ .dict = page };
        try self.pages.append(self.alloc(), num);
    }

    fn pageDict(self: *Editor, index: usize) !Dict {
        if (index >= self.pages.items.len) return Error.NoSuchPage;
        return self.resolve(.{ .ref = .{ .num = self.pages.items[index] } }).dictionary() orelse reader.Error.InvalidPdf;
    }

    fn setPage(self: *Editor, index: usize, d: Dict) void {
        self.objects.items[self.pages.items[index]] = .{ .dict = d };
    }

    // ── Pages ───────────────────────────────────────────────────────────

    pub fn pageCount(self: *const Editor) usize {
        return self.pages.items.len;
    }

    /// The size of page `index` (its MediaBox), in points.
    pub fn pageSize(self: *Editor, index: usize) !document.Size {
        const box = try self.mediaBox(index);
        return .{ .width = @floatCast(box[2] - box[0]), .height = @floatCast(box[3] - box[1]) };
    }

    fn mediaBox(self: *Editor, index: usize) ![4]f64 {
        const d = try self.pageDict(index);
        const box = self.resolve(d.get("MediaBox") orelse return .{ 0, 0, 612, 792 });
        if (box != .array or box.array.len != 4) return .{ 0, 0, 612, 792 };
        var v: [4]f64 = undefined;
        for (box.array, 0..) |n, i| v[i] = self.resolve(n).number() orelse 0;
        return .{ @min(v[0], v[2]), @min(v[1], v[3]), @max(v[0], v[2]), @max(v[1], v[3]) };
    }

    /// The rotation of page `index` in degrees: 0, 90, 180 or 270.
    pub fn rotation(self: *Editor, index: usize) !i64 {
        const d = try self.pageDict(index);
        const r = self.resolve(d.get("Rotate") orelse return 0);
        return if (r == .integer) @mod(r.integer, 360) else 0;
    }

    /// Turns page `index` clockwise by `degrees` (a multiple of 90; negative
    /// turns it the other way).
    pub fn rotatePage(self: *Editor, index: usize, degrees: i64) !void {
        if (@mod(degrees, 90) != 0) return Error.InvalidRotation;
        const current = try self.rotation(index);
        var d = try (try self.pageDict(index)).clone(self.alloc());
        try d.put(self.alloc(), "Rotate", .{ .integer = @mod(current + degrees, 360) });
        self.setPage(index, d);
    }

    /// Removes page `index`; its content goes too, unless another page
    /// shares it.
    pub fn removePage(self: *Editor, index: usize) !void {
        if (index >= self.pages.items.len) return Error.NoSuchPage;
        _ = self.pages.orderedRemove(index);
    }

    /// Moves page `from` so that it ends up at index `to`.
    pub fn movePage(self: *Editor, from: usize, to: usize) !void {
        if (from >= self.pages.items.len or to >= self.pages.items.len) return Error.NoSuchPage;
        const num = self.pages.orderedRemove(from);
        try self.pages.insert(self.alloc(), to, num);
    }

    /// Appends copies of pages of `src` (by index, in the order given; the
    /// same page may come twice) with everything they use: fonts, images,
    /// annotations. `src` can be freed afterwards. Links that pointed to
    /// pages not copied are dropped; the form fields of `src` are not
    /// merged into this document's form.
    pub fn importPages(self: *Editor, src: *Editor, indices: []const usize) !void {
        for (indices) |i| {
            if (i >= src.pages.items.len) return Error.NoSuchPage;
        }
        var copier: Copier = .{ .dst = self, .src = src, .memo = .init(self.alloc()), .allowed = .init(self.alloc()) };
        for (indices) |i| try copier.allowed.put(src.pages.items[i], {});
        for (indices) |i| {
            const num = (try copier.copyRef(src.pages.items[i])).?;
            if (self.resolve(.{ .ref = .{ .num = num } }) == .dict) {
                var d = self.objects.items[num].?.dict;
                d.remove("Parent");
                self.objects.items[num] = .{ .dict = d };
            }
            try self.pages.append(self.alloc(), num);
            try self.tree.put(num, {});
        }
    }

    // ── Stamping ────────────────────────────────────────────────────────

    /// Draws page `overlay_page` of `overlay` over page `index`, without
    /// touching what is there: a watermark, a "PAID" stamp, a signature
    /// image, page numbers. Make the overlay the size of the page
    /// (`pageSize`) and draw on it as on any document; its fonts and images
    /// come along. The overlay is drawn in the page's unrotated space.
    ///
    /// ```zig
    /// var stamp = try pdf.Document.init(allocator, .{ .size = try ed.pageSize(0) });
    /// defer stamp.deinit();
    /// try stamp.text(400, 60, "PAID", .{ .font = .helvetica_bold, .size = 28, .color = pdf.Color.hex("#16a34a") });
    /// try ed.stamp(0, &stamp, 0);
    /// ```
    pub fn stamp(self: *Editor, index: usize, overlay: *document.Document, overlay_page: usize) !void {
        if (index >= self.pages.items.len) return Error.NoSuchPage;
        if (overlay_page >= overlay.pageCount()) return Error.NoSuchPage;
        const gpa = self.arena.child_allocator;
        const bytes = try overlay.toBytes(gpa);
        defer gpa.free(bytes);
        var ov = try Editor.load(gpa, bytes);
        defer ov.deinit();
        try self.stampPage(index, &ov, overlay_page);
    }

    /// Draws page `src_page` of another loaded PDF over page `index` (a
    /// letterhead under an invoice drawn elsewhere, a page of a scanned
    /// form...), as a form XObject: its content and resources are copied.
    pub fn stampPage(self: *Editor, index: usize, src: *Editor, src_page: usize) !void {
        if (index >= self.pages.items.len) return Error.NoSuchPage;
        const sd = try src.pageDict(src_page);
        const a = self.alloc();
        var copier: Copier = .{ .dst = self, .src = src, .memo = .init(a), .allowed = .init(a) };

        // The source page's content becomes the form's content.
        var form = Dict{};
        try form.put(a, "Type", .{ .name = "XObject" });
        try form.put(a, "Subtype", .{ .name = "Form" });
        const sbox = try src.mediaBox(src_page);
        try form.put(a, "BBox", try numbers(a, &sbox));
        if (sd.get("Resources")) |r| try form.put(a, "Resources", try copier.copyValue(r));
        var data: []const u8 = "";
        const contents = src.resolve(sd.get("Contents") orelse .null);
        switch (contents) {
            .stream => |s| {
                data = try a.dupe(u8, s.data);
                if (s.dict.get("Filter")) |f| try form.put(a, "Filter", try copier.copyValue(f));
                if (s.dict.get("DecodeParms")) |p| try form.put(a, "DecodeParms", try copier.copyValue(p));
            },
            .array => |parts| {
                var joined: std.ArrayList(u8) = .empty;
                for (parts) |part| {
                    const s = src.resolve(part);
                    if (s != .stream) continue;
                    try joined.appendSlice(a, try filters.decode(a, s.stream));
                    try joined.append(a, '\n');
                }
                data = joined.items;
            },
            else => {},
        }
        const form_num = try self.add(.{ .stream = .{ .dict = form, .data = data } });

        // The page gets the form among its XObjects, in resources of its own
        // (they may be shared with other pages).
        var page = try (try self.pageDict(index)).clone(a);
        const res_obj = self.resolve(page.get("Resources") orelse .null);
        var res = if (res_obj == .dict) try res_obj.dict.clone(a) else Dict{};
        const xo_obj = self.resolve(res.get("XObject") orelse .null);
        var xobjects = if (xo_obj == .dict) try xo_obj.dict.clone(a) else Dict{};
        var name: []const u8 = undefined;
        while (true) : (self.stamps += 1) {
            name = try std.fmt.allocPrint(a, "SpiderStamp{d}", .{self.stamps});
            if (xobjects.get(name) == null) break;
        }
        self.stamps += 1;
        try xobjects.put(a, name, .{ .ref = .{ .num = form_num } });
        try res.put(a, "XObject", .{ .dict = xobjects });
        try page.put(a, "Resources", .{ .dict = res });

        // Existing content wrapped in q/Q, so that a graphics state it
        // leaves behind does not move or color the stamp; then the stamp,
        // moved from the source page's origin to this page's.
        const tbox = try self.mediaBox(index);
        var parts: std.ArrayList(Object) = .empty;
        try parts.append(a, .{ .ref = .{ .num = try self.add(.{ .stream = .{ .dict = .{}, .data = "q\n" } }) } });
        const existing = page.get("Contents") orelse .null;
        switch (self.resolve(existing)) {
            .array => |items| for (items) |item| try parts.append(a, .{ .ref = .{ .num = try self.adopt(item) } }),
            .stream => try parts.append(a, .{ .ref = .{ .num = try self.adopt(existing) } }),
            else => {},
        }
        const tail = try std.fmt.allocPrint(a, "Q\nq 1 0 0 1 {d:.4} {d:.4} cm /{s} Do Q\n", .{ tbox[0] - sbox[0], tbox[1] - sbox[1], name });
        try parts.append(a, .{ .ref = .{ .num = try self.add(.{ .stream = .{ .dict = .{}, .data = tail } }) } });
        try page.put(a, "Contents", .{ .array = parts.items });
        self.setPage(index, page);
    }

    // ── Properties ──────────────────────────────────────────────────────

    /// The document properties, decoded to UTF-8.
    pub fn properties(self: *Editor) !Properties {
        const num = self.info_num orelse return .{};
        const d = self.resolve(.{ .ref = .{ .num = num } }).dictionary() orelse return .{};
        var p: Properties = .{};
        inline for (.{ .{ "Title", "title" }, .{ "Author", "author" }, .{ "Subject", "subject" }, .{ "Keywords", "keywords" }, .{ "Creator", "creator" }, .{ "Producer", "producer" } }) |kv| {
            if (d.get(kv[0])) |v| {
                const s = self.resolve(v);
                if (s == .string) @field(p, kv[1]) = try decodeText(self.alloc(), s.string);
            }
        }
        return p;
    }

    /// Sets the properties given (the others keep their values) and marks
    /// the file as produced by Spider PDF.
    pub fn setProperties(self: *Editor, info: document.Info) !void {
        const a = self.alloc();
        var d = if (self.info_num) |n| (self.resolve(.{ .ref = .{ .num = n } }).dictionary() orelse Dict{}) else Dict{};
        d = try d.clone(a);
        inline for (.{ .{ "Title", info.title }, .{ "Author", info.author }, .{ "Subject", info.subject }, .{ "Keywords", info.keywords }, .{ "Creator", info.creator } }) |kv| {
            if (kv[1]) |v| try d.put(a, kv[0], .{ .string = try encodeText(a, v) });
        }
        try d.put(a, "Producer", .{ .string = "Spider PDF" });
        if (self.info_num) |n| {
            self.objects.items[n] = .{ .dict = d };
        } else {
            self.info_num = try self.add(.{ .dict = d });
        }
    }

    // ── Forms ───────────────────────────────────────────────────────────

    /// The fields of the document's form (empty when it has none).
    pub fn fields(self: *Editor) ![]Field {
        var list: std.ArrayList(Field) = .empty;
        const form = self.acroForm() orelse return list.items;
        const top = self.resolve(form.get("Fields") orelse .null);
        if (top != .array) return list.items;
        var seen: std.AutoHashMap(u32, void) = .init(self.alloc());
        for (top.array) |f| try self.collectField(&list, &seen, f, "", null, null, 0);
        return list.items;
    }

    fn acroForm(self: *Editor) ?Dict {
        const catalog = self.resolve(.{ .ref = .{ .num = self.root } });
        if (catalog != .dict) return null;
        return self.resolve(catalog.dict.get("AcroForm") orelse return null).dictionary();
    }

    fn collectField(self: *Editor, list: *std.ArrayList(Field), seen: *std.AutoHashMap(u32, void), obj: Object, parent: []const u8, ft: ?[]const u8, ff: ?i64, depth: usize) !void {
        if (depth > 32 or obj != .ref) return;
        if (try seen.fetchPut(obj.ref.num, {}) != null) return;
        const d = self.resolve(obj).dictionary() orelse return;
        const a = self.alloc();
        var name = parent;
        if (d.get("T")) |tv| {
            const tr = self.resolve(tv);
            if (tr == .string) {
                const part = try decodeText(a, tr.string);
                name = if (parent.len == 0) part else try std.fmt.allocPrint(a, "{s}.{s}", .{ parent, part });
            }
        }
        const my_ft = if (d.get("FT")) |v| (if (self.resolve(v) == .name) self.resolve(v).name else ft) else ft;
        const my_ff = if (d.get("Ff")) |v| (if (self.resolve(v) == .integer) self.resolve(v).integer else ff) else ff;

        // Kids with names are fields of their own; kids without are the
        // widgets (the boxes on the pages) of this field.
        if (d.get("Kids")) |kv| {
            const kids = self.resolve(kv);
            if (kids == .array) {
                var named = false;
                for (kids.array) |k| {
                    const kd = self.resolve(k).dictionary() orelse continue;
                    if (kd.get("T") != null) named = true;
                }
                if (named) {
                    for (kids.array) |k| try self.collectField(list, seen, k, name, my_ft, my_ff, depth + 1);
                    return;
                }
            }
        }
        const flags = my_ff orelse 0;
        const kind: FieldKind = if (my_ft) |f| (if (std.mem.eql(u8, f, "Tx")) .text else if (std.mem.eql(u8, f, "Btn"))
            (if (flags & (1 << 16) != 0) .button else if (flags & (1 << 15) != 0) .radio else .checkbox)
        else if (std.mem.eql(u8, f, "Ch")) .choice else if (std.mem.eql(u8, f, "Sig")) .signature else .unknown) else .unknown;
        var value: ?[]const u8 = null;
        if (d.get("V")) |v| switch (self.resolve(v)) {
            .string => |s| value = try decodeText(a, s),
            .name => |n| value = n,
            else => {},
        };
        try list.append(a, .{ .name = name, .kind = kind, .value = value, .num = obj.ref.num });
    }

    fn findField(self: *Editor, name: []const u8) !Field {
        for (try self.fields()) |f| {
            if (std.mem.eql(u8, f.name, name)) return f;
        }
        return Error.NoSuchField;
    }

    /// Fills the text field `name` (its full name, `parent.child`) and
    /// draws its new appearance in each of its boxes, the way Acrobat does:
    /// with the font, size and color of the field's default appearance
    /// (`/DA`; size 0 fits the box), its alignment (`/Q`), and wrapped
    /// lines in a multiline field. The form also asks readers to redraw
    /// fields (`NeedAppearances`), which helps with characters the field's
    /// font lacks.
    pub fn setText(self: *Editor, name: []const u8, value: []const u8) !void {
        const f = try self.findField(name);
        if (f.kind != .text) return Error.WrongFieldKind;
        const a = self.alloc();
        var d = try (self.resolve(.{ .ref = .{ .num = f.num } }).dictionary() orelse return Error.NoSuchField).clone(a);
        try d.put(a, "V", .{ .string = try encodeText(a, value) });
        self.objects.items[f.num] = .{ .dict = d };

        // The widgets: the field itself when it has a box, or its kids.
        var widgets: std.ArrayList(u32) = .empty;
        if (d.get("Rect") != null) try widgets.append(a, f.num);
        if (d.get("Kids")) |kv| {
            const kids = self.resolve(kv);
            if (kids == .array) for (kids.array) |k| {
                if (k == .ref) try widgets.append(a, k.ref.num);
            };
        }
        for (widgets.items) |wn| {
            var w = try (self.resolve(.{ .ref = .{ .num = wn } }).dictionary() orelse continue).clone(a);
            const ap = try self.textAppearance(f.num, w, value);
            var apd = Dict{};
            try apd.put(a, "N", .{ .ref = .{ .num = ap } });
            try w.put(a, "AP", .{ .dict = apd });
            self.objects.items[wn] = .{ .dict = w };
        }
        try self.needAppearances();
    }

    /// An inherited field attribute: on the widget, its field, the field's
    /// parents, then (for /DA and /Q) the form.
    fn inheritedAttr(self: *Editor, start: Dict, key: []const u8) ?Object {
        var d = start;
        var depth: usize = 0;
        while (depth < 32) : (depth += 1) {
            if (d.get(key)) |v| return self.resolve(v);
            const parent = d.get("Parent") orelse break;
            d = self.resolve(parent).dictionary() orelse break;
        }
        const form = self.acroForm() orelse return null;
        return if (form.get(key)) |v| self.resolve(v) else null;
    }

    /// Draws `value` in a widget's box as a form XObject; returns its
    /// object number.
    fn textAppearance(self: *Editor, field_num: u32, widget: Dict, value: []const u8) !u32 {
        const a = self.alloc();
        const field = self.resolve(.{ .ref = .{ .num = field_num } }).dictionary() orelse Dict{};
        // The box.
        var box: [4]f64 = .{ 0, 0, 100, 20 };
        if (self.resolve(widget.get("Rect") orelse .null) == .array) {
            const r = self.resolve(widget.get("Rect").?).array;
            if (r.len == 4) for (r, 0..) |n, i| {
                box[i] = self.resolve(n).number() orelse 0;
            };
        }
        const w: f32 = @floatCast(@abs(box[2] - box[0]));
        const h: f32 = @floatCast(@abs(box[3] - box[1]));

        // "/Helv 0 Tf 0 g": font name, size, and whatever sets the color.
        const da = if (self.inheritedAttr(widget, "DA")) |v| (if (v == .string) v.string else "") else "";
        const parsed = parseDa(da);
        const font_name = parsed.font orelse "Helv";
        const quadding = if (self.inheritedAttr(widget, "Q")) |v| (if (v == .integer) v.integer else 0) else 0;
        const ff = if (self.inheritedAttr(field, "Ff")) |v| (if (v == .integer) v.integer else 0) else 0;
        const multiline = ff & (1 << 12) != 0;

        // The font: from the form's resources, or Helvetica added there.
        const font_ref = try self.formFont(font_name);
        const font_dict = self.resolve(.{ .ref = .{ .num = font_ref } }).dictionary() orelse Dict{};

        var encoded: std.ArrayList(u8) = .empty;
        try fonts.encode(a, &encoded, value);
        const text = encoded.items;
        const pad: f32 = 2;
        var size: f32 = parsed.size;
        if (size <= 0) {
            size = if (multiline) 12 else @min(12, @max(4, (h - 2 * pad) * 0.7));
            if (!multiline) {
                while (size > 4 and self.widthIn(font_dict, text, size) > w - 2 * pad) size -= 0.5;
            }
        }

        var content: std.ArrayList(u8) = .empty;
        try content.print(a, "/Tx BMC\nq {d:.2} {d:.2} {d:.2} {d:.2} re W n\nBT /{s} {d:.2} Tf {s}\n", .{ pad / 2, pad / 2, w - pad, h - pad, font_name, size, parsed.color });
        var lines: std.ArrayList([]const u8) = .empty;
        if (multiline) {
            try self.wrapIn(font_dict, text, size, w - 2 * pad, &lines);
        } else {
            for (text) |*b| if (b.* == '\n') {
                b.* = ' ';
            };
            try lines.append(a, text);
        }
        const leading = size * 1.15;
        for (lines.items, 0..) |line, i| {
            const tw = self.widthIn(font_dict, line, size);
            const x: f32 = switch (quadding) {
                1 => (w - tw) / 2,
                2 => w - pad - tw,
                else => pad,
            };
            // Single line: centered vertically. Several: from the top.
            const y: f32 = if (multiline) h - pad - size * 0.9 - @as(f32, @floatFromInt(i)) * leading else (h - size) / 2 + size * 0.22;
            try content.print(a, "1 0 0 1 {d:.2} {d:.2} Tm ", .{ x, y });
            try content.append(a, '(');
            for (line) |b| {
                if (b == '(' or b == ')' or b == '\\') try content.append(a, '\\');
                try content.append(a, b);
            }
            try content.appendSlice(a, ") Tj\n");
        }
        try content.appendSlice(a, "ET\nQ\nEMC\n");

        var form = Dict{};
        try form.put(a, "Type", .{ .name = "XObject" });
        try form.put(a, "Subtype", .{ .name = "Form" });
        try form.put(a, "BBox", try numbers(a, &.{ 0, 0, w, h }));
        var font_res = Dict{};
        try font_res.put(a, font_name, .{ .ref = .{ .num = font_ref } });
        var res = Dict{};
        try res.put(a, "Font", .{ .dict = font_res });
        try form.put(a, "Resources", .{ .dict = res });
        return self.add(.{ .stream = .{ .dict = form, .data = content.items } });
    }

    /// The form's font named `name` (`/DR /Font`), or a Helvetica added to
    /// the form's resources under that name.
    fn formFont(self: *Editor, name: []const u8) !u32 {
        const a = self.alloc();
        if (self.acroForm()) |form| {
            if (self.resolve(form.get("DR") orelse .null).dictionary()) |dr| {
                if (self.resolve(dr.get("Font") orelse .null).dictionary()) |fd| {
                    if (fd.get(name)) |f| return self.adopt(f);
                }
            }
        }
        var helv = Dict{};
        try helv.put(a, "Type", .{ .name = "Font" });
        try helv.put(a, "Subtype", .{ .name = "Type1" });
        try helv.put(a, "BaseFont", .{ .name = "Helvetica" });
        try helv.put(a, "Encoding", .{ .name = "WinAnsiEncoding" });
        const num = try self.add(.{ .dict = helv });
        // Recorded in the form's resources, so other fields find it too.
        var catalog = try (self.resolve(.{ .ref = .{ .num = self.root } }).dictionary() orelse return num).clone(a);
        const form_obj = catalog.get("AcroForm") orelse return num;
        var form = try (self.resolve(form_obj).dictionary() orelse return num).clone(a);
        var dr = if (self.resolve(form.get("DR") orelse .null).dictionary()) |x| try x.clone(a) else Dict{};
        var fd = if (self.resolve(dr.get("Font") orelse .null).dictionary()) |x| try x.clone(a) else Dict{};
        try fd.put(a, name, .{ .ref = .{ .num = num } });
        try dr.put(a, "Font", .{ .dict = fd });
        try form.put(a, "DR", .{ .dict = dr });
        if (form_obj == .ref) {
            self.objects.items[form_obj.ref.num] = .{ .dict = form };
        } else {
            try catalog.put(a, "AcroForm", .{ .dict = form });
            self.objects.items[self.root] = .{ .dict = catalog };
        }
        return num;
    }

    /// The width of WinAnsi `text` in a simple font: its /Widths when it has
    /// them, Helvetica's otherwise.
    fn widthIn(self: *Editor, font: Dict, text: []const u8, size: f32) f32 {
        const widths = self.resolve(font.get("Widths") orelse .null);
        const first = if (self.resolve(font.get("FirstChar") orelse .null) == .integer) self.resolve(font.get("FirstChar").?).integer else 0;
        const bold = if (self.resolve(font.get("BaseFont") orelse .null) == .name) std.mem.indexOf(u8, self.resolve(font.get("BaseFont").?).name, "Bold") != null else false;
        var units: f32 = 0;
        for (text) |b| {
            if (widths == .array) {
                const i = @as(i64, b) - first;
                if (i >= 0 and i < widths.array.len) {
                    units += @floatCast(self.resolve(widths.array[@intCast(i)]).number() orelse 500);
                    continue;
                }
            }
            units += @floatFromInt(fonts.charWidth(b, if (bold) .helvetica_bold else .helvetica));
        }
        return units / 1000 * size;
    }

    fn wrapIn(self: *Editor, font: Dict, text: []const u8, size: f32, max: f32, lines: *std.ArrayList([]const u8)) !void {
        const a = self.alloc();
        var paragraphs = std.mem.splitScalar(u8, text, '\n');
        while (paragraphs.next()) |para| {
            var start: usize = 0;
            var last_fit: usize = 0;
            var i: usize = 0;
            while (i <= para.len) : (i += 1) {
                if (i < para.len and para[i] != ' ') continue;
                if (self.widthIn(font, para[start..i], size) <= max or last_fit == start) {
                    last_fit = i;
                } else {
                    try lines.append(a, para[start..last_fit]);
                    start = last_fit + 1;
                    last_fit = i;
                }
            }
            try lines.append(a, para[start..@min(last_fit, para.len)]);
        }
    }

    /// Checks or unchecks the checkbox `name`.
    pub fn setCheckbox(self: *Editor, name: []const u8, checked: bool) !void {
        const f = try self.findField(name);
        if (f.kind != .checkbox) return Error.WrongFieldKind;
        const a = self.alloc();
        var d = try (self.resolve(.{ .ref = .{ .num = f.num } }).dictionary() orelse return Error.NoSuchField).clone(a);

        // The widgets: the field itself, or its kids.
        var widgets: std.ArrayList(u32) = .empty;
        if (d.get("Kids")) |kv| {
            const kids = self.resolve(kv);
            if (kids == .array) for (kids.array) |k| {
                if (k == .ref) try widgets.append(a, k.ref.num);
            };
        }
        // The "on" state is whatever the widget's appearances call the state
        // that is not Off ("Yes", "On", "1"...).
        var on: []const u8 = "Yes";
        const first_ap = if (widgets.items.len > 0) (self.resolve(.{ .ref = .{ .num = widgets.items[0] } }).dictionary() orelse Dict{}).get("AP") else d.get("AP");
        if (first_ap) |ap| {
            if (self.resolve(ap).dictionary()) |apd| {
                if (self.resolve(apd.get("N") orelse .null).dictionary()) |n| {
                    for (n.entries) |e| {
                        if (!std.mem.eql(u8, e.key, "Off")) {
                            on = e.key;
                            break;
                        }
                    }
                }
            }
        }
        const state: Object = .{ .name = if (checked) on else "Off" };
        try d.put(a, "V", state);
        if (widgets.items.len == 0) try d.put(a, "AS", state);
        self.objects.items[f.num] = .{ .dict = d };
        for (widgets.items) |wn| {
            var w = try (self.resolve(.{ .ref = .{ .num = wn } }).dictionary() orelse continue).clone(a);
            try w.put(a, "AS", state);
            self.objects.items[wn] = .{ .dict = w };
        }
    }

    fn needAppearances(self: *Editor) !void {
        const a = self.alloc();
        var catalog = try (self.resolve(.{ .ref = .{ .num = self.root } }).dictionary() orelse return).clone(a);
        const form_obj = catalog.get("AcroForm") orelse return;
        var form = try (self.resolve(form_obj).dictionary() orelse return).clone(a);
        try form.put(a, "NeedAppearances", .{ .boolean = true });
        if (form_obj == .ref) {
            self.objects.items[form_obj.ref.num] = .{ .dict = form };
        } else {
            try catalog.put(a, "AcroForm", .{ .dict = form });
            self.objects.items[self.root] = .{ .dict = catalog };
        }
    }

    // ── Saving ──────────────────────────────────────────────────────────

    /// Writes the document as a complete PDF file, allocated with
    /// `allocator`.
    pub fn save(self: *Editor, allocator: std.mem.Allocator) ![]u8 {
        const a = self.alloc();

        // A flat page tree with the pages in their current order.
        const kids = try a.alloc(Object, self.pages.items.len);
        for (self.pages.items, kids) |num, *k| k.* = .{ .ref = .{ .num = num } };
        var tree = Dict{};
        try tree.put(a, "Type", .{ .name = "Pages" });
        try tree.put(a, "Kids", .{ .array = kids });
        try tree.put(a, "Count", .{ .integer = @intCast(self.pages.items.len) });
        const tree_num = try self.add(.{ .dict = tree });
        for (self.pages.items) |num| {
            var d = try (self.resolve(.{ .ref = .{ .num = num } }).dictionary() orelse Dict{}).clone(a);
            try d.put(a, "Parent", .{ .ref = .{ .num = tree_num } });
            d.remove("Type");
            try d.put(a, "Type", .{ .name = "Page" });
            self.objects.items[num] = .{ .dict = d };
        }
        var catalog = try (self.resolve(.{ .ref = .{ .num = self.root } }).dictionary() orelse return reader.Error.InvalidPdf).clone(a);
        try catalog.put(a, "Pages", .{ .ref = .{ .num = tree_num } });
        self.objects.items[self.root] = .{ .dict = catalog };

        // The objects reachable from the catalog and the properties, numbered
        // in the order they are found.
        var in_pages: std.AutoHashMap(u32, void) = .init(a);
        for (self.pages.items) |num| try in_pages.put(num, {});
        var numbers_map: std.AutoHashMap(u32, u32) = .init(a);
        var order: std.ArrayList(u32) = .empty;
        var stack: std.ArrayList(u32) = .empty;
        try stack.append(a, self.root);
        if (self.info_num) |n| try stack.append(a, n);
        const keep = struct {
            fn ok(ed: *Editor, pages_set: *std.AutoHashMap(u32, void), tree_n: u32, num: u32) bool {
                if (num == tree_n) return true;
                if (ed.get(num) == null) return false;
                // Old tree nodes and removed pages are left out.
                if (ed.tree.contains(num) and !pages_set.contains(num)) return false;
                return true;
            }
        }.ok;
        while (stack.pop()) |num| {
            if (numbers_map.contains(num) or !keep(self, &in_pages, tree_num, num)) continue;
            try numbers_map.put(num, @intCast(order.items.len + 1));
            try order.append(a, num);
            try pushRefs(a, self.get(num).?, &stack);
        }

        const Remap = struct {
            map_: *std.AutoHashMap(u32, u32),
            pub fn map(r: @This(), ref: Ref) ?u32 {
                return r.map_.get(ref.num);
            }
        };
        const remap: Remap = .{ .map_ = &numbers_map };

        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("%PDF-1.7\n%\xe2\xe3\xcf\xd3\n");
        const offsets = try a.alloc(usize, order.items.len);
        for (order.items, 0..) |num, i| {
            offsets[i] = out.written().len;
            try w.print("{d} 0 obj\n", .{i + 1});
            const obj = self.get(num).?;
            if (obj == .stream) {
                var d = try obj.stream.dict.clone(a);
                try d.put(a, "Length", .{ .integer = @intCast(obj.stream.data.len) });
                try syntax.writeDict(w, d, remap);
                try w.writeAll("\nstream\n");
                try w.writeAll(obj.stream.data);
                try w.writeAll("\nendstream");
            } else {
                try syntax.write(w, obj, remap);
            }
            try w.writeAll("\nendobj\n");
        }
        const xref = out.written().len;
        try w.print("xref\n0 {d}\n0000000000 65535 f \n", .{order.items.len + 1});
        for (offsets) |off| try w.print("{d:0>10} 00000 n \n", .{off});
        try w.print("trailer\n<< /Size {d} /Root {d} 0 R", .{ order.items.len + 1, numbers_map.get(self.root).? });
        if (self.info_num) |n| {
            if (numbers_map.get(n)) |m| try w.print(" /Info {d} 0 R", .{m});
        }
        if (self.id) |id| {
            if (id == .array) {
                try w.writeAll(" /ID ");
                try syntax.write(w, id, remap);
            }
        }
        try w.print(" >>\nstartxref\n{d}\n%%EOF\n", .{xref});
        return out.toOwnedSlice();
    }
};

fn pushRefs(a: std.mem.Allocator, obj: Object, stack: *std.ArrayList(u32)) !void {
    switch (obj) {
        .ref => |r| try stack.append(a, r.num),
        .array => |items| for (items) |i| try pushRefs(a, i, stack),
        .dict => |d| for (d.entries) |e| try pushRefs(a, e.value, stack),
        .stream => |s| for (s.dict.entries) |e| try pushRefs(a, e.value, stack),
        else => {},
    }
}

/// Copies objects from one editor into another: every byte is duplicated
/// into the destination, references are renumbered (once per object, so
/// shared fonts stay shared), and references to pages of the source that
/// are not being copied become null.
const Copier = struct {
    dst: *Editor,
    src: *Editor,
    memo: std.AutoHashMap(u32, u32),
    allowed: std.AutoHashMap(u32, void),

    fn copyRef(self: *Copier, num: u32) !?u32 {
        if (self.memo.get(num)) |n| return n;
        if (self.src.tree.contains(num) and !self.allowed.contains(num)) return null;
        const obj = self.src.get(num) orelse return null;
        const new = try self.dst.add(.null);
        try self.memo.put(num, new);
        self.dst.objects.items[new] = try self.copyValue(obj);
        return new;
    }

    fn copyValue(self: *Copier, obj: Object) error{OutOfMemory}!Object {
        const a = self.dst.alloc();
        return switch (obj) {
            .null, .boolean, .integer, .real => obj,
            .string => |s| .{ .string = try a.dupe(u8, s) },
            .name => |n| .{ .name = try a.dupe(u8, n) },
            .array => |items| blk: {
                const out = try a.alloc(Object, items.len);
                for (items, out) |i, *o| o.* = try self.copyValue(i);
                break :blk .{ .array = out };
            },
            .dict => |d| .{ .dict = try self.copyDict(d) },
            .stream => |s| .{ .stream = .{ .dict = try self.copyDict(s.dict), .data = try a.dupe(u8, s.data) } },
            .ref => |r| if (try self.copyRef(r.num)) |n| .{ .ref = .{ .num = n } } else .null,
        };
    }

    fn copyDict(self: *Copier, d: Dict) !Dict {
        const a = self.dst.alloc();
        const entries = try a.alloc(syntax.Entry, d.entries.len);
        for (d.entries, entries) |e, *o| o.* = .{ .key = try a.dupe(u8, e.key), .value = try self.copyValue(e.value) };
        return .{ .entries = entries };
    }
};

const Da = struct { font: ?[]const u8 = null, size: f32 = 0, color: []const u8 = "0 g" };

/// Reads a default appearance string ("/Helv 12 Tf 0 0 1 rg"): the font,
/// the size, and the operators that set the color.
fn parseDa(da: []const u8) Da {
    var out: Da = .{};
    // The last few tokens and where each starts in `da`.
    var tokens: [16][]const u8 = undefined;
    var starts: [16]usize = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, da, " \t\r\n");
    while (it.next()) |tok| {
        if (n == tokens.len) {
            std.mem.copyForwards([]const u8, tokens[0 .. n - 1], tokens[1..n]);
            std.mem.copyForwards(usize, starts[0 .. n - 1], starts[1..n]);
            n -= 1;
        }
        tokens[n] = tok;
        starts[n] = it.index - tok.len;
        n += 1;
        if (std.mem.eql(u8, tok, "Tf") and n >= 3 and tokens[n - 3].len > 1 and tokens[n - 3][0] == '/') {
            out.font = tokens[n - 3][1..];
            out.size = std.fmt.parseFloat(f32, tokens[n - 2]) catch 0;
        }
        const want: usize = if (std.mem.eql(u8, tok, "g")) 1 else if (std.mem.eql(u8, tok, "rg")) 3 else if (std.mem.eql(u8, tok, "k")) 4 else 0;
        if (want > 0 and n > want) out.color = da[starts[n - 1 - want] .. starts[n - 1] + tok.len];
    }
    return out;
}

fn numbers(a: std.mem.Allocator, values: []const f64) !Object {
    const items = try a.alloc(Object, values.len);
    for (values, items) |v, *i| i.* = if (v == @trunc(v) and @abs(v) < 1e15) .{ .integer = @intFromFloat(v) } else .{ .real = v };
    return .{ .array = items };
}

/// A PDF text string to UTF-8: UTF-16BE with its byte order mark, UTF-8
/// with its mark (PDF 2.0), or PDFDocEncoding (Latin-1 with a few
/// differences, read here as Latin-1).
pub fn decodeText(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (s.len >= 2 and s[0] == 0xFE and s[1] == 0xFF) {
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 2;
        while (i + 1 < s.len) : (i += 2) {
            var cp: u21 = @as(u21, s[i]) << 8 | s[i + 1];
            if (cp >= 0xD800 and cp < 0xDC00 and i + 3 < s.len) {
                const lo = @as(u21, s[i + 2]) << 8 | s[i + 3];
                if (lo >= 0xDC00 and lo < 0xE000) {
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                    i += 2;
                }
            }
            if (cp >= 0xD800 and cp < 0xE000) cp = 0xFFFD;
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &buf) catch continue;
            try out.appendSlice(a, buf[0..n]);
        }
        return out.items;
    }
    if (s.len >= 3 and s[0] == 0xEF and s[1] == 0xBB and s[2] == 0xBF) return a.dupe(u8, s[3..]);
    var out: std.ArrayList(u8) = .empty;
    for (s) |b| {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(b, &buf) catch continue;
        try out.appendSlice(a, buf[0..n]);
    }
    return out.items;
}

/// UTF-8 to a PDF text string: printable ASCII as it is, anything else as
/// UTF-16BE with a byte order mark.
pub fn encodeText(a: std.mem.Allocator, utf8: []const u8) ![]const u8 {
    for (utf8) |b| {
        if (b < 0x20 or b > 0x7E) break;
    } else return a.dupe(u8, utf8);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, &.{ 0xFE, 0xFF });
    var i: usize = 0;
    while (i < utf8.len) {
        const len = std.unicode.utf8ByteSequenceLength(utf8[i]) catch 1;
        const cp: u21 = if (i + len <= utf8.len) std.unicode.utf8Decode(utf8[i .. i + len]) catch 0xFFFD else 0xFFFD;
        i += len;
        var units: [2]u16 = undefined;
        var n: usize = 1;
        if (cp >= 0x10000) {
            units = .{ @intCast(0xD800 + ((cp - 0x10000) >> 10)), @intCast(0xDC00 + ((cp - 0x10000) & 0x3FF)) };
            n = 2;
        } else units[0] = @intCast(cp);
        for (units[0..n]) |u| {
            try out.append(a, @intCast(u >> 8));
            try out.append(a, @truncate(u));
        }
    }
    return out.items;
}

// ── Tests ───────────────────────────────────────────────────────────────

const t = std.testing;

/// A document of `n` pages, each with "Page N" on it.
fn makePdf(allocator: std.mem.Allocator, n: usize, label: []const u8) ![]u8 {
    var doc = try document.Document.init(allocator, .{ .size = .{ .width = 300, .height = 200 }, .info = .{ .title = "Source" } });
    defer doc.deinit();
    for (0..n) |i| {
        if (i > 0) try doc.addPage();
        var buf: [64]u8 = undefined;
        try doc.text(20, 40, try std.fmt.bufPrint(&buf, "{s} {d}", .{ label, i + 1 }), .{});
    }
    return doc.toBytes(allocator);
}

/// The decoded content of page `index`, all its streams joined.
fn pageText(ed: *Editor, index: usize) ![]const u8 {
    const a = ed.alloc();
    const d = try ed.pageDict(index);
    var out: std.ArrayList(u8) = .empty;
    const c = ed.resolve(d.get("Contents") orelse return "");
    const parts: []const Object = if (c == .array) c.array else &.{c};
    for (parts) |p| {
        const s = ed.resolve(p);
        if (s == .stream) try out.appendSlice(a, try filters.decode(a, s.stream));
    }
    return out.items;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

/// Saves, checks the xref of the result, and loads it again.
fn roundTrip(ed: *Editor) !Editor {
    const bytes = try ed.save(ed.alloc());
    // Every xref entry points at its "N 0 obj".
    const sx = std.mem.lastIndexOf(u8, bytes, "startxref\n").?;
    const xref_at = try std.fmt.parseInt(usize, std.mem.trim(u8, bytes[sx + 10 .. bytes.len - 6], "\n"), 10);
    var lines = std.mem.splitScalar(u8, bytes[xref_at..], '\n');
    _ = lines.next();
    const count = try std.fmt.parseInt(usize, lines.next().?[2..], 10);
    _ = lines.next();
    for (1..count) |id| {
        const off = try std.fmt.parseInt(usize, lines.next().?[0..10], 10);
        var buf: [32]u8 = undefined;
        try t.expect(std.mem.startsWith(u8, bytes[off..], try std.fmt.bufPrint(&buf, "{d} 0 obj\n", .{id})));
    }
    const again = try Editor.load(t.allocator, bytes);
    try t.expect(!again.repaired);
    return again;
}

test "load reads the pages, and a save gives the same document back" {
    const bytes = try makePdf(t.allocator, 3, "Page");
    defer t.allocator.free(bytes);
    var ed = try Editor.load(t.allocator, bytes);
    defer ed.deinit();
    try t.expectEqual(@as(usize, 3), ed.pageCount());
    const size = try ed.pageSize(1);
    try t.expectEqual(@as(f32, 300), size.width);
    try t.expect(contains(try pageText(&ed, 2), "(Page 3) Tj"));
    var again = try roundTrip(&ed);
    defer again.deinit();
    try t.expectEqual(@as(usize, 3), again.pageCount());
    try t.expect(contains(try pageText(&again, 0), "(Page 1) Tj"));
}

test "a page listed twice in the tree comes twice, and a loop is cut" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bodies = [_][]const u8{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R 3 0 R 2 0 R] /Count 3 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 10 10] >>",
    };
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "%PDF-1.4\n");
    var offsets: [bodies.len]usize = undefined;
    for (bodies, 0..) |b, i| {
        offsets[i] = out.items.len;
        try out.print(a, "{d} 0 obj\n{s}\nendobj\n", .{ i + 1, b });
    }
    const xref = out.items.len;
    try out.print(a, "xref\n0 4\n0000000000 65535 f \n", .{});
    for (offsets) |o| try out.print(a, "{d:0>10} 00000 n \n", .{o});
    try out.print(a, "trailer\n<< /Size 4 /Root 1 0 R >>\nstartxref\n{d}\n%%EOF\n", .{xref});
    var ed = try Editor.load(t.allocator, out.items);
    defer ed.deinit();
    try t.expectEqual(@as(usize, 2), ed.pageCount());
    try t.expect(ed.pages.items[0] != ed.pages.items[1]);
    var again = try roundTrip(&ed);
    defer again.deinit();
    try t.expectEqual(@as(usize, 2), again.pageCount());
}

test "rotate, remove and move pages" {
    const bytes = try makePdf(t.allocator, 4, "Page");
    defer t.allocator.free(bytes);
    var ed = try Editor.load(t.allocator, bytes);
    defer ed.deinit();
    try ed.rotatePage(0, 90);
    try ed.rotatePage(0, 270);
    try ed.rotatePage(1, -90);
    try t.expectError(Error.InvalidRotation, ed.rotatePage(1, 45));
    try ed.removePage(2); // "Page 3"
    try ed.movePage(2, 0); // "Page 4" first
    try t.expectError(Error.NoSuchPage, ed.removePage(9));

    var again = try roundTrip(&ed);
    defer again.deinit();
    try t.expectEqual(@as(usize, 3), again.pageCount());
    try t.expect(contains(try pageText(&again, 0), "(Page 4)"));
    try t.expect(contains(try pageText(&again, 1), "(Page 1)"));
    try t.expect(contains(try pageText(&again, 2), "(Page 2)"));
    try t.expectEqual(@as(i64, 0), try again.rotation(1));
    try t.expectEqual(@as(i64, 270), try again.rotation(2));
}

test "removed pages leave the file with their content" {
    const bytes = try makePdf(t.allocator, 2, "Page");
    defer t.allocator.free(bytes);
    var ed = try Editor.load(t.allocator, bytes);
    defer ed.deinit();
    try ed.removePage(1);
    const out = try ed.save(t.allocator);
    defer t.allocator.free(out);
    // Catalog, info, tree, one page, its content, its font.
    try t.expectEqual(@as(usize, 6), std.mem.count(u8, out, " 0 obj\n"));
}

test "importPages merges documents and splits them" {
    const a_bytes = try makePdf(t.allocator, 2, "A");
    defer t.allocator.free(a_bytes);
    const b_bytes = try makePdf(t.allocator, 3, "B");
    defer t.allocator.free(b_bytes);
    var a = try Editor.load(t.allocator, a_bytes);
    defer a.deinit();
    {
        var b = try Editor.load(t.allocator, b_bytes);
        defer b.deinit();
        try a.importPages(&b, &.{ 2, 0 });
        try t.expectError(Error.NoSuchPage, a.importPages(&b, &.{7}));
    } // b is gone: the copies hold their own bytes
    var merged = try roundTrip(&a);
    defer merged.deinit();
    try t.expectEqual(@as(usize, 4), merged.pageCount());
    try t.expect(contains(try pageText(&merged, 2), "(B 3)"));
    try t.expect(contains(try pageText(&merged, 3), "(B 1)"));

    // A split: a new document from one page of another.
    const one = try makePdf(t.allocator, 0 + 1, "Blank");
    defer t.allocator.free(one);
    var split = try Editor.load(t.allocator, one);
    defer split.deinit();
    try split.importPages(&merged, &.{1});
    try split.removePage(0);
    var only = try roundTrip(&split);
    defer only.deinit();
    try t.expectEqual(@as(usize, 1), only.pageCount());
    try t.expect(contains(try pageText(&only, 0), "(A 2)"));
}

test "stamp draws a Document over a page, keeping what was there" {
    const bytes = try makePdf(t.allocator, 2, "Page");
    defer t.allocator.free(bytes);
    var ed = try Editor.load(t.allocator, bytes);
    defer ed.deinit();
    var overlay = try document.Document.init(t.allocator, .{ .size = try ed.pageSize(0) });
    defer overlay.deinit();
    try overlay.text(150, 100, "PAID", .{ .font = .helvetica_bold, .size = 30 });
    try ed.stamp(0, &overlay, 0);
    try ed.stamp(0, &overlay, 0); // twice: two names
    try t.expectError(Error.NoSuchPage, ed.stamp(5, &overlay, 0));

    var again = try roundTrip(&ed);
    defer again.deinit();
    const text = try pageText(&again, 0);
    try t.expect(contains(text, "q\n"));
    try t.expect(contains(text, "(Page 1) Tj"));
    try t.expect(contains(text, "/SpiderStamp0 Do Q"));
    try t.expect(contains(text, "/SpiderStamp1 Do Q"));
    // The form carries the overlay's drawing and its font.
    const page = try again.pageDict(0);
    const xobj = again.resolve(again.resolve(page.get("Resources").?).dict.get("XObject").?).dict;
    const form = again.resolve(xobj.get("SpiderStamp0").?).stream;
    try t.expect(form.dict.hasName("Subtype", "Form"));
    try t.expect(contains(try filters.decode(again.alloc(), form), "(PAID) Tj"));
    const font = again.resolve(again.resolve(form.dict.get("Resources").?).dict.get("Font").?);
    try t.expect(font == .dict);
    // Page 2 untouched.
    try t.expect(!contains(try pageText(&again, 1), "SpiderStamp"));
}

test "properties: read, set with accents, and keep the others" {
    const bytes = try makePdf(t.allocator, 1, "Page");
    defer t.allocator.free(bytes);
    var ed = try Editor.load(t.allocator, bytes);
    defer ed.deinit();
    try t.expectEqualStrings("Source", (try ed.properties()).title.?);
    try ed.setProperties(.{ .author = "José Ação", .subject = "Contrato 😀" });
    var again = try roundTrip(&ed);
    defer again.deinit();
    const p = try again.properties();
    try t.expectEqualStrings("Source", p.title.?);
    try t.expectEqualStrings("José Ação", p.author.?);
    try t.expectEqualStrings("Contrato 😀", p.subject.?);
    try t.expectEqualStrings("Spider PDF", p.producer.?);
}

/// A one-page PDF with a form: a text field "name" (one widget, the field
/// itself), a group "address" with a text kid "city", and a checkbox
/// "agree" whose widget is a kid with an /On appearance.
fn formPdf(allocator: std.mem.Allocator) ![]u8 {
    const bodies = [_][]const u8{
        "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [4 0 R 5 0 R 7 0 R] >> >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200] >>",
        "<< /Type /Page /Parent 2 0 R /Annots [4 0 R 6 0 R 8 0 R] >>",
        "<< /FT /Tx /T (name) /V (old) /Subtype /Widget /Rect [10 10 100 30] /AP << /N 9 0 R >> >>",
        "<< /T (address) /Kids [6 0 R] >>",
        "<< /FT /Tx /T (city) /Parent 5 0 R /Subtype /Widget /Rect [10 40 100 60] >>",
        "<< /FT /Btn /T (agree) /V /Off /Kids [8 0 R] >>",
        "<< /Parent 7 0 R /Subtype /Widget /Rect [10 70 20 80] /AS /Off /AP << /N << /On 9 0 R /Off 9 0 R >> >> >>",
        "<< /Length 0 >>\nstream\n\nendstream",
    };
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, "%PDF-1.4\n");
    var offsets: [bodies.len]usize = undefined;
    for (bodies, 0..) |b, i| {
        offsets[i] = out.items.len;
        try out.print(allocator, "{d} 0 obj\n{s}\nendobj\n", .{ i + 1, b });
    }
    const xref = out.items.len;
    try out.print(allocator, "xref\n0 {d}\n0000000000 65535 f \n", .{bodies.len + 1});
    for (offsets) |o| try out.print(allocator, "{d:0>10} 00000 n \n", .{o});
    try out.print(allocator, "trailer\n<< /Size {d} /Root 1 0 R >>\nstartxref\n{d}\n%%EOF\n", .{ bodies.len + 1, xref });
    return out.toOwnedSlice(allocator);
}

test "form fields: listed with full names, filled, checked, and saved" {
    const bytes = try formPdf(t.allocator);
    defer t.allocator.free(bytes);
    var ed = try Editor.load(t.allocator, bytes);
    defer ed.deinit();
    // MediaBox inherited from the page tree.
    try t.expectEqual(@as(f32, 200), (try ed.pageSize(0)).width);

    const list = try ed.fields();
    try t.expectEqual(@as(usize, 3), list.len);
    try t.expectEqualStrings("name", list[0].name);
    try t.expectEqual(FieldKind.text, list[0].kind);
    try t.expectEqualStrings("old", list[0].value.?);
    try t.expectEqualStrings("address.city", list[1].name);
    try t.expectEqual(FieldKind.checkbox, list[2].kind);

    try ed.setText("name", "Maria José");
    try ed.setText("address.city", "Goiânia");
    try ed.setCheckbox("agree", true);
    try t.expectError(Error.NoSuchField, ed.setText("nope", "x"));
    try t.expectError(Error.WrongFieldKind, ed.setCheckbox("name", true));
    try t.expectError(Error.WrongFieldKind, ed.setText("agree", "x"));

    var again = try roundTrip(&ed);
    defer again.deinit();
    const after = try again.fields();
    try t.expectEqualStrings("Maria José", after[0].value.?);
    try t.expectEqualStrings("Goiânia", after[1].value.?);
    try t.expectEqualStrings("On", after[2].value.?);
    // The filled field has a new appearance with its value; the form asks
    // readers to redraw too.
    const name_field = again.resolve(.{ .ref = .{ .num = after[0].num } }).dict;
    const ap = again.resolve(again.resolve(name_field.get("AP").?).dict.get("N").?).stream;
    try t.expect(ap.dict.hasName("Subtype", "Form"));
    try t.expect(contains(ap.data, "(Maria Jos\xe9) Tj"));
    try t.expect(contains(ap.data, "/Helv "));
    const catalog = again.resolve(.{ .ref = .{ .num = again.root } }).dict;
    try t.expect(again.resolve(catalog.get("AcroForm").?).dict.get("NeedAppearances").?.boolean);
    // The checkbox widget shows the on state.
    const page = try again.pageDict(0);
    const annots = again.resolve(page.get("Annots").?).array;
    try t.expect(again.resolve(annots[2]).dict.get("AS").?.isName("On"));
}

test "encrypted files: every revision opens, decrypted, and saves in the clear" {
    const fixtures = .{ "r2-rc4-40", "r3-rc4-128", "r4-rc4-128", "r4-aes-128", "r5-aes-256", "r6-aes-256" };
    inline for (fixtures) |name| {
        const bytes = @embedFile("testdata/" ++ name ++ ".pdf");
        var ed = Editor.load(t.allocator, bytes) catch |err| {
            std.debug.print("{s}: {s}\n", .{ name, @errorName(err) });
            return err;
        };
        defer ed.deinit();
        try t.expect(ed.encrypted);
        try t.expectEqualStrings("Secret plan", (try ed.properties()).title.?);
        try t.expectEqualStrings("José", (try ed.properties()).author.?);
        try t.expect(contains(try pageText(&ed, 0), "(Encrypted hello) Tj"));
        var again = try roundTrip(&ed);
        defer again.deinit();
        try t.expect(!again.encrypted);
        try t.expect(contains(try pageText(&again, 0), "(Encrypted hello) Tj"));
    }
}

test "encrypted files with a user password: user, owner, missing and wrong" {
    inline for (.{ "r4-aes-128-sesame", "r6-aes-256-sesame" }) |name| {
        const bytes = @embedFile("testdata/" ++ name ++ ".pdf");
        try t.expectError(error.EncryptedPdf, Editor.load(t.allocator, bytes));
        try t.expectError(error.WrongPassword, Editor.loadWith(t.allocator, bytes, .{ .password = "guess" }));
        inline for (.{ "sesame", "owner" }) |pw| {
            var ed = try Editor.loadWith(t.allocator, bytes, .{ .password = pw });
            defer ed.deinit();
            try t.expect(contains(try pageText(&ed, 0), "(Encrypted hello) Tj"));
        }
    }
}

test "permissions are reported" {
    var ed = try Editor.load(t.allocator, @embedFile("testdata/r6-no-modify.pdf"));
    defer ed.deinit();
    try t.expect(!ed.allows(.modify));
    try t.expect(!ed.allows(.print));
    try t.expect(ed.allows(.copy));
    var plain = try Editor.load(t.allocator, @embedFile("testdata/plain.pdf"));
    defer plain.deinit();
    try t.expect(!plain.encrypted);
    try t.expect(plain.allows(.modify));
}

test "parseDa reads the font, the size and the color operators" {
    const d = parseDa("/Helv 12 Tf 0 0 1 rg");
    try t.expectEqualStrings("Helv", d.font.?);
    try t.expectEqual(@as(f32, 12), d.size);
    try t.expectEqualStrings("0 0 1 rg", d.color);
    const auto = parseDa("0.5 g /TiRo 0 Tf");
    try t.expectEqualStrings("TiRo", auto.font.?);
    try t.expectEqual(@as(f32, 0), auto.size);
    try t.expectEqualStrings("0.5 g", auto.color);
    try t.expectEqualStrings("0 g", parseDa("").color);
    // The same number as size and color: the color is the one before "g".
    const same = parseDa("/Helv 0 Tf 0 g");
    try t.expectEqualStrings("0 g", same.color);
    try t.expectEqual(@as(f32, 0), same.size);
}

test "text appearances: auto size fits the box, alignment, multiline, the form's font" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bodies = [_][]const u8{
        "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [4 0 R 5 0 R] /DA (/Helv 0 Tf 0 g) /DR << /Font << /Helv 6 0 R >> >> >> >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 300 300] >>",
        "<< /Type /Page /Parent 2 0 R /Annots [4 0 R 5 0 R] >>",
        "<< /FT /Tx /T (short) /Q 2 /Subtype /Widget /Rect [10 10 60 30] >>",
        "<< /FT /Tx /T (notes) /Ff 4096 /DA (/Cour 9 Tf 1 0 0 rg) /Subtype /Widget /Rect [10 40 110 100] >>",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
    };
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "%PDF-1.4\n");
    var offsets: [bodies.len]usize = undefined;
    for (bodies, 0..) |b, i| {
        offsets[i] = out.items.len;
        try out.print(a, "{d} 0 obj\n{s}\nendobj\n", .{ i + 1, b });
    }
    const xref = out.items.len;
    try out.print(a, "xref\n0 {d}\n0000000000 65535 f \n", .{bodies.len + 1});
    for (offsets) |o| try out.print(a, "{d:0>10} 00000 n \n", .{o});
    try out.print(a, "trailer\n<< /Size {d} /Root 1 0 R >>\nstartxref\n{d}\n%%EOF\n", .{ bodies.len + 1, xref });

    var ed = try Editor.load(t.allocator, out.items);
    defer ed.deinit();
    try ed.setText("short", "A longer value");
    try ed.setText("notes", "First line that wraps inside the box\nSecond");
    const short_ap = ed.resolve(ed.resolve(ed.resolve(.{ .ref = .{ .num = 4 } }).dict.get("AP").?).dict.get("N").?).stream;
    // Auto size shrank until the text fits 50 - 4 points.
    const tf = std.mem.indexOf(u8, short_ap.data, "/Helv ").?;
    const size = try std.fmt.parseFloat(f32, std.mem.sliceTo(short_ap.data[tf + 6 ..], ' '));
    try t.expect(size < 12);
    try t.expect(ed.widthIn(ed.resolve(.{ .ref = .{ .num = 6 } }).dict, "A longer value", size) <= 46);
    try t.expect(contains(short_ap.data, "re W n"));
    // Right-aligned (/Q 2): the line ends 2 points from the right edge.
    const tm = std.mem.indexOf(u8, short_ap.data, "1 0 0 1 ").? + 8;
    const x = try std.fmt.parseFloat(f32, std.mem.sliceTo(short_ap.data[tm..], ' '));
    try t.expectApproxEqAbs(@as(f32, 50 - 2) - ed.widthIn(ed.resolve(.{ .ref = .{ .num = 6 } }).dict, "A longer value", size), x, 0.01);
    // Multiline: Courier added to the form's resources, red, several lines.
    const notes_ap = ed.resolve(ed.resolve(ed.resolve(.{ .ref = .{ .num = 5 } }).dict.get("AP").?).dict.get("N").?).stream;
    try t.expect(contains(notes_ap.data, "/Cour 9.00 Tf 1 0 0 rg"));
    try t.expect(std.mem.count(u8, notes_ap.data, " Tj") >= 3);
    try t.expect(contains(notes_ap.data, "(Second) Tj"));
    const form = ed.acroForm().?;
    try t.expect(ed.resolve(ed.resolve(form.get("DR").?).dict.get("Font").?).dict.get("Cour") != null);
    var again = try roundTrip(&ed);
    defer again.deinit();
}

test "text strings: UTF-16 with surrogates, PDFDocEncoding, and back" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("Plain", try decodeText(a, "Plain"));
    try t.expectEqualStrings("Jos\u{e9}", try decodeText(a, "Jos\xe9"));
    try t.expectEqualStrings("a😀", try decodeText(a, try encodeText(a, "a😀")));
    try t.expectEqualSlices(u8, &.{ 0xFE, 0xFF, 0, 'a', 0xD8, 0x3D, 0xDE, 0x00 }, try encodeText(a, "a😀"));
    try t.expectEqualStrings("Plain", try encodeText(a, "Plain"));
}
