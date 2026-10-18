//! The built-in channels (`notify.channels`). Each one is a constructor
//! (`inbox()`) or a state type whose `channel()` gives the `Channel` (the
//! state must outlive the app, since the channel points at it).

/// The in-app inbox (`notify_inbox`), inline. See `inbox.zig`.
pub const inbox = @import("inbox.zig").inbox;
/// Reading and marking a user's inbox, for the app's views.
pub const Inbox = @import("inbox.zig");
/// SSE through Spider's hub.
pub const Sse = @import("sse.zig").Sse;
/// What the `sse` channel takes.
pub const SseOptions = @import("sse.zig").Options;
/// Browser push (VAPID).
pub const WebPush = @import("web_push.zig").WebPush;
/// Firebase Cloud Messaging (Android and iOS apps).
pub const Fcm = @import("fcm.zig").Fcm;
/// What the `fcm` channel takes.
pub const FcmConfig = @import("fcm.zig").Config;
/// Email through `spider.mail`.
pub const Email = @import("email.zig").Email;

test {
    _ = @import("fanout.zig");
    _ = @import("inbox.zig");
    _ = @import("sse.zig");
    _ = @import("web_push.zig");
    _ = @import("fcm.zig");
    _ = @import("email.zig");
}
