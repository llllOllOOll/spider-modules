//! Multi-channel notifications (`spider_notify`): one `send` records a
//! notification for a set of recipients in the caller's transaction, and
//! each channel (in-app inbox, SSE, Web Push, FCM, email, or one the app
//! writes) delivers it: inline channels right away, queued ones through a
//! worker with retries, backoff, expiry and a delivery log. A dedup key
//! makes repeated sends of the same event record nothing.
//!
//! A Spider module (`spider_module` below): mounted with
//! `server.mountModules(.{notify, ...})`, its tables come with it
//! (`src/sql/`, applied by `spider migrate`), and the server refuses to
//! start when they are missing or cannot be read. Needs `spider.pg`.
//! Design and guarantees: `DESIGN.md`.
//!
//! ```zig
//! // main.zig: the module first, then the app's features
//! _ = server.mountModules(.{notify}).mountFeatures(features);
//!
//! // at boot (the channel states live as long as the app)
//! var sse_state: notify.channels.Sse = .{};
//! try notify.init(std.heap.smp_allocator, .{
//!     .channels = &.{ notify.channels.inbox(), sse_state.channel() },
//!     .address_book = notify.DefaultAddressBook.book(),
//! });
//!
//! // in a feature's mod.zig: the worker
//! pub const jobs = .{spider.every(1000, notify.job)};
//!
//! // anywhere, inside the transaction that caused it
//! _ = try notify.send(&tx, c.arena, .{
//!     .notification = .{ .kind = "order.shipped", .title = "Your order shipped", .url = "/orders/42" },
//!     .recipients = &.{.{ .user = user_id }},
//!     .channels = &.{ "inbox", "sse" },
//! });
//! ```

const std = @import("std");
const spider = @import("spider");

const notification = @import("notification.zig");
const channel_mod = @import("channel.zig");
const address_book_mod = @import("address_book.zig");
const preferences_mod = @import("preferences.zig");
const registry = @import("registry.zig");
const sender = @import("sender.zig");
const worker = @import("worker.zig");

/// The module's manifest: its name, version, the Spider versions it is
/// tested with, and its migrations (recorded as `notify/<name>`).
pub const spider_module = spider.module(.{
    .name = "notify",
    .version = "0.2.0",
    .spider = ">=0.11.0-dev.1 <0.12.0",
    .migrations = .{
        .{ .name = "0001_init", .sql = @embedFile("sql/0001_init.sql") },
    },
});

/// Run by the server before it starts (after Spider checked that the
/// migrations are applied): the app's database user can read every table
/// of the module, so the first send cannot fail on permissions.
pub fn check(c: *spider.Check) !void {
    _ = spider.pg.query(void, c.arena,
        \\SELECT 1 FROM notify_messages, notify_deliveries, notify_inbox, notify_addresses LIMIT 0
    , .{}) catch |err| {
        c.fail("cannot read its tables (notify_messages, notify_deliveries, notify_inbox, notify_addresses): error.{s}", .{@errorName(err)});
    };
}

/// Run by `server.deinit()`, after the jobs stopped: forgets the
/// configuration `init` stored.
pub fn shutdown(_: spider.Boot) void {
    registry.deinit();
}

/// The content of a notification. See `notification.zig`.
pub const Notification = notification.Notification;
/// Who receives a notification: a user of the app or a bare address.
pub const Recipient = notification.Recipient;
/// A bare address of one channel.
pub const Address = notification.Address;
/// Why a notification or a recipient was refused.
pub const Invalid = notification.Invalid;

/// A way of delivering. See `channel.zig`.
pub const Channel = channel_mod.Channel;
/// When a channel delivers: inline (in `send`) or queued (by the worker).
pub const Mode = channel_mod.Mode;
/// One delivery handed to a channel.
pub const Job = channel_mod.Job;
/// What a queued channel gets to work with.
pub const DeliveryContext = channel_mod.DeliveryContext;
/// A channel's answer for one delivery.
pub const Outcome = channel_mod.Outcome;
/// Why a delivery did not go out.
pub const Failure = channel_mod.Failure;
/// The wait between attempts of a channel.
pub const Backoff = @import("backoff.zig").Policy;

/// Where channels find a user's addresses.
pub const AddressBook = address_book_mod.AddressBook;
/// One address of a user.
pub const AddressEntry = address_book_mod.Entry;
/// The module's own address book, in `notify_addresses`.
pub const DefaultAddressBook = address_book_mod.Default;
/// Whether a user wants a kind of notification on a channel.
pub const Preferences = preferences_mod.Preferences;

/// The built-in channels.
pub const channels = @import("channels/channels.zig");

/// What `init` takes: the channels, and optionally where the addresses are
/// and what the users prefer (default: no addresses, everything allowed).
pub const Config = registry.Config;

/// Why `init` failed: a channel is invalid (`channel.ConfigError`), two
/// share a name, none was given, or `init` already ran.
pub const InitError = registry.InitError;

/// Stores the configuration. Call once at boot, before the worker's jobs
/// start. The channel list is copied into `allocator`; the address book and
/// preferences must stay valid for the life of the app. Fails with
/// `error.AlreadyInitialized` on a second call.
pub fn init(allocator: std.mem.Allocator, config: Config) InitError!void {
    return registry.init(allocator, config);
}

/// Forgets the configuration (for tests and tools). The worker must not be
/// running.
pub fn deinit() void {
    registry.deinit();
}

/// What `send` takes: the notification, its recipients, and the channels
/// that deliver to the users among them (an address recipient always goes
/// to its own channel only). Repeated recipients and channels count once.
pub const Request = sender.Request;

/// What `send` recorded: the notification's id, and how many deliveries
/// were queued, written inline, or skipped by a preference.
pub const Recorded = sender.Recorded;

/// The result of `send`: `.recorded`, or `.duplicate` when a notification
/// with the same dedup key already exists (nothing was written).
pub const Sent = sender.Sent;

/// The most recipients one `send` takes (10 000).
pub const max_recipients = sender.max_recipients;

/// Why `send` refused a request before writing: invalid content, an
/// unregistered channel, no or too many recipients, or no `init`.
pub const SendError = sender.SendError;

/// Records a notification in `tx`, the transaction of the change that
/// caused it: it is sent only if `tx` commits. Inline channels (the inbox)
/// write in `tx` now; queued channels get a pending delivery for the worker.
/// Returns `.duplicate`, writing nothing, when the dedup key was used before.
/// Fails with a `SendError` before writing anything, or with the database's
/// error (then `tx` is aborted: roll it back).
///
/// ```zig
/// var tx = try spider.pg.begin();
/// defer tx.rollback();
/// // ... the change ...
/// _ = try notify.send(&tx, c.arena, .{
///     .notification = .{ .kind = "ai.quota_95", .title = "AI quota at 95%", .dedup_key = key },
///     .recipients = admins,
///     .channels = &.{ "inbox", "sse", "web_push" },
/// });
/// try tx.commit();
/// ```
pub fn send(tx: *spider.pg.Transaction, arena: std.mem.Allocator, req: Request) !Sent {
    return sender.send(tx, arena, req);
}

/// `send` in a transaction of its own, committed before it returns: for a
/// notification that is not tied to a change (a job's alert).
pub fn sendNow(arena: std.mem.Allocator, req: Request) !Sent {
    return sender.sendNow(arena, req);
}

/// What one worker tick did, by count.
pub const TickStats = worker.Stats;

/// One worker pass over every queued channel, or only `only`: expires old
/// deliveries, takes back those whose worker died, claims due ones and
/// records each channel's outcome. `hub` reaches the `sse` channel (null:
/// SSE deliveries are skipped). Fails with `error.NotInitialized` before
/// `init`, `error.UnknownChannel` for an unregistered `only`, or a database
/// error. Most apps use `job` instead.
pub fn tick(arena: std.mem.Allocator, io: std.Io, hub: ?*spider.Hub, only: ?[]const u8) !TickStats {
    return worker.tick(arena, io, hub, only);
}

/// The worker as a Spider job, over every queued channel. Errors are logged
/// at warn level, never returned.
///
/// ```zig
/// pub const jobs = .{spider.every(1000, notify.job)};
/// ```
pub fn job(hub: *spider.Hub) void {
    worker.runTick(hub, null);
}

/// The worker of one channel as a Spider job: each job runs on its own
/// thread, so a slow provider (a push service timing out) does not delay
/// the other channels.
///
/// ```zig
/// pub const jobs = .{
///     spider.every(1000, notify.jobFor("sse")),
///     spider.every(2000, notify.jobFor("web_push")),
/// };
/// ```
pub fn jobFor(comptime channel_name: []const u8) *const fn (*spider.Hub) void {
    comptime if (!notification.validChannelName(channel_name)) @compileError("notify.jobFor: invalid channel name \"" ++ channel_name ++ "\"");
    return struct {
        fn run(hub: *spider.Hub) void {
            worker.runTick(hub, channel_name);
        }
    }.run;
}

test {
    _ = notification;
    _ = channel_mod;
    _ = address_book_mod;
    _ = preferences_mod;
    _ = registry;
    _ = sender;
    _ = worker;
    _ = @import("backoff.zig");
    _ = channels;
}
