# spider_notify

Multi-channel notifications for Spider apps. One call records a notification
for a set of recipients, inside the transaction of the change that caused it;
each channel then delivers it:

- **inline** channels (the in-app inbox) write in that same transaction;
- **queued** channels (SSE, Web Push, FCM, email, or one the app writes) are
  delivered by a worker, with retries, exponential backoff, expiry and a
  delivery log.

A dedup key makes repeated sends of the same event record nothing. The design
and its guarantees are in [DESIGN.md](DESIGN.md).

It is a Spider module (Spider 0.11 or newer): `mountModules` checks it at
compile time, its tables come with it, and the server refuses to start while
they are missing or cannot be read.

## Install

1. Add the package (`zig fetch --save <url of spider-modules>`), then the
   module in `build.zig`, passing it your `spider` (built with `.pg = true`):

   ```zig
   const modules_dep = b.dependency("spider_modules", .{});
   const notify_mod = b.createModule(.{
       .root_source_file = modules_dep.path("notify/src/notify.zig"),
       .target = target,
       .imports = &.{.{ .name = "spider", .module = spider_mod }},
   });
   exe.root_module.addImport("spider_notify", notify_mod);
   ```

2. Mount it, before the app's features:

   ```zig
   const notify = @import("spider_notify");
   _ = server.mountModules(.{notify}).mountFeatures(features);
   ```

3. `spider migrate` applies its migrations (`src/sql/`), recorded as
   `notify/0001_init` and so on. `spider check --modules` (or starting the
   app) tells you when they are missing.

An app that copied the old `sql/notify.sql` into its own migrations already
has the tables: `0001_init` only uses `CREATE ... IF NOT EXISTS`, so
`spider migrate` records it without changing them.

## Configure (at boot)

```zig
const notify = @import("spider_notify");

var sse_state: notify.channels.Sse = .{};
var push_state: notify.channels.WebPush = .{ .client = spider.push.WebPush.initFromEnv() };

pub fn boot(_: spider.Boot) !void {
    try notify.init(std.heap.smp_allocator, .{
        .channels = &.{ notify.channels.inbox(), sse_state.channel(), push_state.channel() },
        .address_book = notify.DefaultAddressBook.book(),
    });
}

// The worker: one job for all channels...
pub const jobs = .{spider.every(1000, notify.job)};
// ...or one per channel, so a slow provider does not delay the others:
// pub const jobs = .{ spider.every(1000, notify.jobFor("sse")), spider.every(2000, notify.jobFor("web_push")) };
```

## Send

```zig
var tx = try spider.pg.begin();
defer tx.rollback();
// ... the change ...
const result = try notify.send(&tx, c.arena, .{
    .notification = .{
        .kind = "order.shipped",
        .title = "Your order shipped",
        .body = "Order #42 is on its way.",
        .url = "/orders/42",
        .dedup_key = "order.shipped:42",
    },
    .recipients = &.{.{ .user = user_id }},
    .channels = &.{ "inbox", "sse", "web_push" },
});
try tx.commit();
switch (result) {
    .recorded => |r| std.log.info("queued {d}", .{r.queued}),
    .duplicate => {}, // already notified
}
```

`notify.sendNow` does the same in a transaction of its own (for jobs).

A recipient who is not a user goes by address, to that channel only:
`.{ .address = .{ .channel = "email", .value = "oncall@example.com" } }`.

## Built-in channels

| Channel | Mode | State | Addresses |
|---|---|---|---|
| `inbox` | inline | `notify.channels.inbox()` | — |
| `sse` | queued | `notify.channels.Sse` | — (hub channel `user:<id>`, or a mapping; the event's data can be built by the app) |
| `web_push` | queued | `notify.channels.WebPush` | subscription JSON |
| `fcm` | queued | `notify.channels.Fcm` | FCM registration token |
| `email` | queued | `notify.channels.Email` | email address |

The inbox has `recent`, `unreadCount`, `markRead` and `markAllRead` in
`notify.channels.Inbox` for the app's views.

## Your own channel

```zig
fn deliver(ptr: ?*anyopaque, ctx: *const notify.DeliveryContext, job: *const notify.Job) notify.Outcome {
    const phone = switch (job.recipient) { .address => |a| a.value, .user => return .{ .skipped = "no_phone" } };
    sendSms(ctx.arena, ctx.io, phone, job.notification.title) catch |err|
        return .{ .retry = .{ .reason = @errorName(err) } };
    return .sent;
}

const sms: notify.Channel = .{ .name = "sms", .deliver = deliver, .max_attempts = 4 };
```

Answer `.sent`, `.retry` (transient: the backoff applies), `.failed`
(permanent) or `.skipped` (nothing to do). Reasons go to the delivery log:
never put secrets or message bodies in them.

## Your own address book or preferences

An app that already stores push subscriptions or phones implements
`notify.AddressBook` (`lookup`, optional `forget`) over its tables, and
`notify.Preferences` (`allows`) over its settings, and passes them to `init`.

## Tests

From the root of `spider-modules`, with Spider checked out at `../spider`:

- `zig build test-notify` — unit tests, no database.
- `notify/scripts/test-db.sh` — on a disposable Postgres (Docker), empty:
  Spider applies the module's migrations (`server.migrateModules`), the
  server is checked before and after, then the database tests run on those
  tables.
