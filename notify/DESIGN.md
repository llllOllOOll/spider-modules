# spider_notify — design

A multi-channel notification module for Spider apps: one call records a
notification for a set of recipients, and each channel (in-app inbox, SSE,
Web Push, FCM, WhatsApp, email, or one the app writes) delivers it, with
retries, deduplication and a delivery log.

It is a Spider module (RFC 0001): its own package in `spider-modules`
(`notify/`, its own `build.zig`, imports only `std` and `spider`), with a
manifest (`spider_module`), its migrations and a `check`. It was first
written inside the Orbitx app, which is where the module contract was
proven.

## Prior art

The shape follows what established frameworks do:

- **Laravel Notifications** (`Illuminate\Notifications`): a notification is
  one object; `via()` names its channels; each channel formats and sends;
  each (recipient, channel) pair is a queued job; the `database` channel is
  the in-app inbox and `broadcast` the real-time push.
- **Noticed** (Rails): the same split, with delivery methods for FCM, APNs,
  email, SMS and ActionCable bundled in the library.
- **Transactional outbox**: the notification is written in the same
  transaction as the change that caused it, and a worker delivers it after
  commit. Rows are claimed with `FOR UPDATE SKIP LOCKED`.
- **Notification-system design** (the usual system-design references): a
  delivery log, one queue per channel so a provider outage does not hold the
  others back, retries with exponential backoff, idempotency keys, user
  preferences, and at-least-once delivery.

## Concepts

| Name | What it is |
|---|---|
| `Notification` | The content: kind, title, body, url, icon, data, scope, dedup key. One row in `notify_messages`. |
| `Recipient` | A user of the app (`.user = "<id>"`), or a bare address for one channel (`.address = .{ .channel = "whatsapp", .value = "5511…" }`) for people who are not users (an on-call phone). |
| `Channel` | A way to deliver: a name, a mode (`inline` or `queued`), limits, and a `deliver` function. Built-in channels ship with the module; an app can add its own. |
| `Delivery` | One (notification, recipient, channel) triple. One row in `notify_deliveries`, with its state, attempts and last error. |
| `AddressBook` | Where a channel finds a user's addresses (push subscriptions, FCM tokens, phone, email). The module ships a default backed by its own tables; an app with existing tables plugs in its own. |
| `Preferences` | Whether a user wants a kind of notification on a channel. Default: everything allowed. |
| `Worker` | Claims due deliveries, calls the channel, records the outcome. Runs as a Spider job. |

## Guarantees

- **Atomic with the cause.** `send` takes the caller's `pg.Transaction`: if
  the transaction rolls back, nothing is sent. `sendNow` opens its own.
- **At most one notification per dedup key.** `notify_messages.dedup_key`
  is unique. A second `send` with the same key records nothing and returns
  `.duplicate` — no race window, the database decides.
- **At least once per delivery.** A delivery claimed by a worker that dies
  before recording the outcome is claimed again when its lease expires.
  Channels must tolerate the rare repeat (the in-app inbox is written
  inline, once).
- **Channels do not block each other.** The worker claims per channel, with a
  per-channel batch size; a channel that keeps failing backs off on its own
  rows only.
- **Bounded retries.** Exponential backoff with jitter up to a channel's
  `max_attempts`; then the delivery is `failed`. A delivery older than the
  channel's `max_age_ms` is `expired` instead of sent late.
- **Nothing outside the module's tables is read or written by the core.**
  Everything app-specific goes through `Channel`, `AddressBook` and
  `Preferences`.

## Lifecycle of a delivery

```
send ─► pending ─► sending ─► sent
          ▲   │        │
          │   │        ├─► pending   (retry: next_attempt_at = now + backoff)
          │   │        ├─► failed    (permanent error, or attempts exhausted)
          │   │        └─► skipped   (no address, preference off at delivery)
          │   └─────────────► expired (older than max_age_ms when claimed)
          └── lease expired while `sending` (worker died) ──┘
```

Inline channels (the inbox) are delivered inside `send`, in the caller's
transaction, and their delivery row is written as `sent` directly.

## Tables

`src/sql/0001_init.sql`, the module's first migration: Spider applies it
(`spider migrate`, `server.migrateModules`) and records it as
`notify/0001_init` with its checksum. A change to the schema is a new
migration (`0002_...`), never an edit of a released one.

- `notify_messages` — id, kind, scope, title, body, url, icon, data (jsonb),
  dedup_key (unique), created_at.
- `notify_deliveries` — id, message_id, recipient_user, recipient_address,
  channel, status, attempts, next_attempt_at, lease_until, last_error,
  delivered_at, created_at. Partial index on due rows per channel.
- `notify_inbox` — the default in-app inbox: user_id, message_id, read_at.
- `notify_addresses` — the default address book: user_id, channel, value,
  label, created_at, last_used_at; unique (channel, value).

## Channel interface

```zig
pub const Channel = struct {
    name: []const u8,
    mode: Mode = .queued,          // .inline_write: written inside send()
    batch: u16 = 50,               // rows claimed per tick
    max_attempts: u8 = 6,
    max_age_ms: u64 = 24 * 3600 * 1000,
    ptr: *anyopaque,
    deliverFn: *const fn (ptr, *const DeliveryContext, Job) Outcome,
};

pub const Outcome = union(enum) {
    sent,
    retry: Failure,      // transient: back off and try again
    failed: Failure,     // permanent: stop
    skipped: []const u8, // nothing to do (no address, opted out)
};
```

`DeliveryContext` gives the channel an arena, an `Io`, the SSE hub (when the
worker runs as a Spider job) and the address book. `Job` is the delivery: its
id, attempt number, recipient, and the notification content.

## Built-in channels

| Channel | Mode | Uses | Addresses |
|---|---|---|---|
| `inbox` | inline | `notify_inbox` | — |
| `sse` | queued | `spider.Hub.emitTo("user:<id>")` | — |
| `web_push` | queued | `spider.push.WebPush` | address book, `web_push` |
| `fcm` | queued | FCM HTTP v1 (service account) | address book, `fcm` |
| `email` | queued | `spider.mail.Mailer` | address book, `email` |

WhatsApp is not built in for now: the providers (Meta Cloud API, WAHA) need
sender-number management that Orbitx already has, so Orbitx registers a
`whatsapp` channel of its own that hands the message to its existing queue.
It is the first proof that app channels plug in like built-in ones.

## Running the worker

```zig
// in a feature's mod.zig
pub const jobs = .{spider.every(1000, notify.job)};
```

`notify.job(hub)` runs one tick: expire, reclaim stale leases, then claim and
deliver each channel's due rows. A tick is a few indexed queries when idle.
Latency is up to one tick (1 s); SSE to an open page is the only case where
that is noticeable, and 1 s is within what users read as "live".

## Configuration

```zig
var sse_state: notify.channels.Sse = .{};
var push_state: notify.channels.WebPush = .{ .client = spider.push.WebPush.initFromEnv() };

try notify.init(std.heap.smp_allocator, .{
    .channels = &.{ notify.channels.inbox(), sse_state.channel(), push_state.channel(), my_channel },
    .address_book = notify.DefaultAddressBook.book(),
});
```

`init` validates the configuration (unique channel names, sane limits) and
stores it in a module global, the way `spider.pg` keeps its pool.

## Testing

- Unit tests (no database): backoff, outcome mapping, validation of
  notifications and configuration, payload building of each channel.
- Database tests (`zig build test-notify-db`, a disposable Postgres): send
  inside a rolled-back transaction, dedup under concurrency, claim with two
  workers, retry/backoff/failure, lease expiry, per-channel isolation,
  expiry by age, preferences, inline inbox.

## Gaps in Spider this module works around (proposals for Spider)

1. Jobs get only the hub, boot hooks get no hub: the worker builds its own
   `Io` per tick, like other Orbitx jobs.
2. `spider.pg` does not wrap `LISTEN/NOTIFY`: the worker polls (1 s).
3. ~~A module cannot ship migrations~~: solved by Spider 0.11 modules
   (`spider_module.migrations`, RFC 0001).
4. ~~No shutdown hook~~: `shutdown` runs from `server.deinit()` after the
   jobs stopped. A tick in flight when the process is killed still leaves
   leased rows, which the lease expiry recovers.
