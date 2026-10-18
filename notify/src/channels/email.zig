//! The `email` channel: through `spider.mail.Mailer` (Brevo, Resend,
//! Postmark, a log, or a transport of the app). A user's addresses are email
//! addresses in the address book. The mail is plain text: the title as
//! subject, the body, and the link (made absolute with `base_url`).

const std = @import("std");
const spider = @import("spider");
const ch = @import("../channel.zig");
const fanout = @import("fanout.zig");

const mail = spider.mail;

/// The state behind an `email` channel: keep it alive as long as the app.
pub const Email = struct {
    /// The sender. Its `from` is used (the module sets no sender).
    mailer: mail.Mailer,
    /// Put in front of a notification's `url` that starts with `/`, for
    /// the link in the mail: `"https://app.example.com"`. Empty: no link.
    base_url: []const u8 = "",

    /// The channel, named `email`.
    ///
    /// ```zig
    /// var email_state: notify.channels.Email = .{ .mailer = try spider.mail.Mailer.fromEnv(), .base_url = "https://app.example.com" };
    /// // ...
    /// .channels = &.{ email_state.channel(), ... },
    /// ```
    pub fn channel(self: *Email) ch.Channel {
        return .{
            .name = "email",
            .ptr = self,
            .deliver = deliver,
            .max_attempts = 5,
            .backoff = .{ .base_ms = 60_000, .max_ms = 60 * 60 * 1000 },
        };
    }
};

/// The text of the mail (pure, for tests): the body, then the link on its
/// own line when there is one.
pub fn text(arena: std.mem.Allocator, base_url: []const u8, n: anytype) ![]const u8 {
    if (n.url.len == 0 or base_url.len == 0) return if (n.body.len > 0) n.body else n.title;
    const link = if (std.mem.startsWith(u8, n.url, "/"))
        try std.fmt.allocPrint(arena, "{s}{s}", .{ std.mem.trimEnd(u8, base_url, "/"), n.url })
    else
        n.url;
    return std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ if (n.body.len > 0) n.body else n.title, link });
}

fn deliver(ptr: ?*anyopaque, ctx: *const ch.DeliveryContext, job: *const ch.Job) ch.Outcome {
    const self: *Email = @ptrCast(@alignCast(ptr.?));
    return fanout.deliver(Email, self, ctx, job, "email", sendOne);
}

fn sendOne(self: *Email, ctx: *const ch.DeliveryContext, job: *const ch.Job, address: []const u8) fanout.Result {
    const n = job.notification;
    const body = text(ctx.arena, self.base_url, n) catch return .{ .transient = .{ .reason = "out_of_memory" } };
    // A subject is a header: no line breaks.
    const subject = std.mem.replaceOwned(u8, ctx.arena, n.title, "\n", " ") catch return .{ .transient = .{ .reason = "out_of_memory" } };
    _ = self.mailer.sendWith(ctx.arena, ctx.io, .{
        .to = &.{.{ .address = address }},
        .subject = subject,
        .text = body,
    }) catch |err| return switch (err) {
        error.MailInvalidAddress => .gone,
        error.MailMissingFrom, error.MailInvalidHeader, error.MailMissingBody, error.MailRejected, error.MailUnauthorized => .{ .permanent = .{ .reason = @errorName(err) } },
        else => .{ .transient = .{ .reason = @errorName(err) } },
    };
    return .ok;
}

test "text: body and absolute link" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const N = struct { title: []const u8, body: []const u8, url: []const u8 };
    try std.testing.expectEqualStrings("B\n\nhttps://x.com/a", try text(a, "https://x.com/", N{ .title = "T", .body = "B", .url = "/a" }));
    try std.testing.expectEqualStrings("T\n\nhttps://y.com", try text(a, "https://x.com", N{ .title = "T", .body = "", .url = "https://y.com" }));
    try std.testing.expectEqualStrings("B", try text(a, "", N{ .title = "T", .body = "B", .url = "/a" }));
}

test "deliver: through the mailer, to every address" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var outbox = mail.Outbox.init(std.testing.allocator);
    defer outbox.deinit();
    var state: Email = .{ .mailer = .{ .backend = .{ .memory = &outbox }, .from = .{ .address = "app@example.com" } }, .base_url = "https://x.com" };
    const c = state.channel();
    try ch.validate(c);
    const Book = struct {
        fn lookup(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8) anyerror![]const @import("../address_book.zig").Entry {
            return &.{ .{ .value = "a@example.com" }, .{ .value = "b@example.com" } };
        }
    };
    const ctx: ch.DeliveryContext = .{ .arena = a, .io = undefined, .hub = null, .address_book = .{ .lookup = Book.lookup } };
    const job: ch.Job = .{ .delivery_id = "d", .message_id = "m", .attempt = 1, .recipient = .{ .user = "1" }, .notification = .{ .kind = "k", .title = "Hello", .body = "Body", .url = "/p" } };
    try std.testing.expect(c.deliver.?(c.ptr, &ctx, &job) == .sent);
    try std.testing.expectEqual(@as(usize, 2), outbox.count());
}
