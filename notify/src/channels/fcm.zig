//! The `fcm` channel: Firebase Cloud Messaging (HTTP v1) to the app's
//! Android and iOS installs. A user's addresses are FCM registration tokens.
//! A token FCM reports as unregistered (404) is removed from the address
//! book.
//!
//! FCM needs an OAuth access token, obtained with a JWT signed by the
//! service account's RSA key. Zig's standard library has no RSA signing, so
//! the default signer runs `openssl dgst -sha256 -sign` (the `openssl`
//! command must be installed); an app can pass its own signer. The access
//! token is cached for its lifetime (about an hour).

const std = @import("std");
const spider = @import("spider");
const ch = @import("../channel.zig");
const fanout = @import("fanout.zig");

const token_url = "https://oauth2.googleapis.com/token";
const scope = "https://www.googleapis.com/auth/firebase.messaging";

/// Signs `input` with RS256 (RSA PKCS#1 v1.5, SHA-256) using a PEM private
/// key, returning the raw signature in `arena`.
pub const Signer = *const fn (arena: std.mem.Allocator, private_key_pem: []const u8, input: []const u8) anyerror![]const u8;

/// The Firebase project and service account.
pub const Config = struct {
    /// The Firebase project id.
    project_id: []const u8,
    /// The service account's `client_email`.
    client_email: []const u8,
    /// The service account's `private_key`, PEM. A key from a `.env` line
    /// with literal `\n` sequences is accepted (they become line breaks).
    private_key_pem: []const u8,
    /// The iOS sound file name for `apns.payload.aps.sound` (Android takes
    /// its sound from the app's notification channel). Null: system default.
    apns_sound: ?[]const u8 = null,
    /// Signs the OAuth JWT. Default: the `openssl` command.
    signer: Signer = opensslSign,
};

/// The state behind an `fcm` channel: keep it alive as long as the app. Its
/// token cache assumes the channel is delivered by one thread at a time
/// (one worker job for the channel, or `notify.job` alone).
pub const Fcm = struct {
    /// What it was made with.
    config: Config,
    _token: ?[]u8 = null,
    _token_expires_s: i64 = 0,

    /// From `FCM_PROJECT_ID`, `FCM_CLIENT_EMAIL` and `FCM_PRIVATE_KEY`.
    /// Missing variables give an unconfigured channel, whose deliveries are
    /// skipped (`not_configured`): an app can register `fcm` in every
    /// environment.
    pub fn fromEnv() Fcm {
        return .{ .config = .{
            .project_id = spider.env.getOr("FCM_PROJECT_ID", ""),
            .client_email = spider.env.getOr("FCM_CLIENT_EMAIL", ""),
            .private_key_pem = spider.env.getOr("FCM_PRIVATE_KEY", ""),
        } };
    }

    /// True when the project, the account and the key are all set.
    pub fn configured(self: *const Fcm) bool {
        return self.config.project_id.len > 0 and self.config.client_email.len > 0 and self.config.private_key_pem.len > 0;
    }

    /// The channel, named `fcm`.
    ///
    /// ```zig
    /// var fcm_state = notify.channels.Fcm.fromEnv();
    /// fcm_state.config.apns_sound = "notification.wav";
    /// // ...
    /// .channels = &.{ fcm_state.channel(), ... },
    /// ```
    pub fn channel(self: *Fcm) ch.Channel {
        return .{ .name = "fcm", .ptr = self, .deliver = deliver };
    }

    /// Frees the cached access token.
    pub fn deinit(self: *Fcm) void {
        if (self._token) |t| std.heap.smp_allocator.free(t);
        self._token = null;
    }
};

/// The FCM v1 message for one token, as JSON (pure, for tests): a
/// `notification` block (Android shows it with no app code), a `data` block
/// with the same fields plus `url` and `kind` (for the tap), and the iOS
/// sound when configured.
pub fn message(arena: std.mem.Allocator, config: Config, token: []const u8, job: *const ch.Job) ![]const u8 {
    const n = job.notification;
    const notification = .{ .title = n.title, .body = n.body };
    const data = .{ .title = n.title, .body = n.body, .url = n.url, .kind = n.kind, .id = job.message_id };
    if (config.apns_sound) |sound| {
        return std.json.Stringify.valueAlloc(arena, .{ .message = .{
            .token = token,
            .notification = notification,
            .data = data,
            .apns = .{ .payload = .{ .aps = .{ .sound = sound } } },
        } }, .{});
    }
    return std.json.Stringify.valueAlloc(arena, .{ .message = .{
        .token = token,
        .notification = notification,
        .data = data,
    } }, .{});
}

/// A PEM key from an environment variable, with each run of backslashes
/// followed by `n` turned into a line break (deploy pipelines add escape
/// layers). Pure, for tests.
pub fn normalizeKey(arena: std.mem.Allocator, input: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '\\') {
            var j = i;
            while (j < input.len and input[j] == '\\') j += 1;
            if (j < input.len and input[j] == 'n') {
                try out.append(arena, '\n');
                i = j + 1;
                continue;
            }
        }
        try out.append(arena, input[i]);
        i += 1;
    }
    return out.items;
}

fn base64Url(arena: std.mem.Allocator, data: []const u8) ![]const u8 {
    const E = std.base64.url_safe_no_pad.Encoder;
    const buf = try arena.alloc(u8, E.calcSize(data.len));
    return E.encode(buf, data);
}

/// The default signer: `openssl dgst -sha256 -sign <key>`, with the key and
/// the input in temporary files that are deleted right after.
pub fn opensslSign(arena: std.mem.Allocator, private_key_pem: []const u8, input: []const u8) anyerror![]const u8 {
    // Files and a child process need a blocking Io with a real allocator,
    // whatever Io the worker runs on.
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const nonce = std.Io.Clock.now(.real, io).nanoseconds;
    const key_path = try std.fmt.allocPrint(arena, "/tmp/spider-notify-fcm-key-{d}.pem", .{nonce});
    const input_path = try std.fmt.allocPrint(arena, "/tmp/spider-notify-fcm-input-{d}.bin", .{nonce});
    defer std.Io.Dir.deleteFileAbsolute(io, key_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(io, input_path) catch {};
    {
        var f = try std.Io.Dir.createFileAbsolute(io, key_path, .{ .permissions = .fromMode(0o600) });
        defer f.close(io);
        try f.writeStreamingAll(io, private_key_pem);
    }
    {
        var f = try std.Io.Dir.createFileAbsolute(io, input_path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, input);
    }
    const result = try std.process.run(arena, io, .{ .argv = &.{ "openssl", "dgst", "-sha256", "-sign", key_path, input_path } });
    if (!result.term.success()) return error.FcmSignFailed;
    return result.stdout;
}

fn accessToken(self: *Fcm, arena: std.mem.Allocator, io: std.Io) ![]const u8 {
    const now = std.Io.Clock.now(.real, io).toSeconds();
    if (self._token) |t| if (now < self._token_expires_s - 60) return t;

    const claims = try std.json.Stringify.valueAlloc(arena, .{
        .iss = self.config.client_email,
        .scope = scope,
        .aud = token_url,
        .exp = now + 3600,
        .iat = now,
    }, .{});
    const signing_input = try std.fmt.allocPrint(arena, "{s}.{s}", .{
        try base64Url(arena, "{\"alg\":\"RS256\",\"typ\":\"JWT\"}"),
        try base64Url(arena, claims),
    });
    const key = try normalizeKey(arena, self.config.private_key_pem);
    const signature = try self.config.signer(arena, key, signing_input);
    const jwt = try std.fmt.allocPrint(arena, "{s}.{s}", .{ signing_input, try base64Url(arena, signature) });

    var res = try spider.http_client.post(io, arena, token_url, .{ .body = .{ .form = &.{
        .{ "grant_type", "urn:ietf:params:oauth:grant-type:jwt-bearer" },
        .{ "assertion", jwt },
    } } });
    defer res.deinit();
    if (res.status != .ok) return error.FcmTokenRefused;
    const parsed = try res.json(struct { access_token: []const u8 = "", expires_in: i64 = 0 });
    defer parsed.deinit();
    if (parsed.value.access_token.len == 0) return error.FcmTokenRefused;

    const copy = try std.heap.smp_allocator.dupe(u8, parsed.value.access_token);
    if (self._token) |old| std.heap.smp_allocator.free(old);
    self._token = copy;
    self._token_expires_s = now + parsed.value.expires_in;
    return copy;
}

fn deliver(ptr: ?*anyopaque, ctx: *const ch.DeliveryContext, job: *const ch.Job) ch.Outcome {
    const self: *Fcm = @ptrCast(@alignCast(ptr.?));
    // An app without Firebase: skip instead of retrying.
    if (!self.configured()) return .{ .skipped = "not_configured" };
    return fanout.deliver(Fcm, self, ctx, job, "fcm", sendOne);
}

fn sendOne(self: *Fcm, ctx: *const ch.DeliveryContext, job: *const ch.Job, token: []const u8) fanout.Result {
    const access = accessToken(self, ctx.arena, ctx.io) catch |err| return .{ .transient = .{ .reason = @errorName(err) } };
    const url = std.fmt.allocPrint(ctx.arena, "https://fcm.googleapis.com/v1/projects/{s}/messages:send", .{self.config.project_id}) catch return .{ .transient = .{ .reason = "out_of_memory" } };
    const body = message(ctx.arena, self.config, token, job) catch return .{ .transient = .{ .reason = "out_of_memory" } };
    const auth = std.fmt.allocPrint(ctx.arena, "Bearer {s}", .{access}) catch return .{ .transient = .{ .reason = "out_of_memory" } };
    var res = spider.http_client.post(ctx.io, ctx.arena, url, .{
        .headers = &.{.{ .name = "Authorization", .value = auth }},
        .body = .{ .json = body },
    }) catch |err| return .{ .transient = .{ .reason = @errorName(err) } };
    defer res.deinit();
    return classify(@backingInt(res.status));
}

/// What an FCM HTTP status means for one token (pure, for tests).
pub fn classify(status: u16) fanout.Result {
    return switch (status) {
        200 => .ok,
        404 => .gone, // UNREGISTERED: the app was uninstalled or the token rotated
        400 => .{ .permanent = .{ .reason = "http_400" } }, // a token that never was valid
        401, 403 => .{ .transient = .{ .reason = "http_auth" } }, // credentials: fix and the retries go out
        429 => .{ .transient = .{ .reason = "http_429" } },
        else => .{ .transient = .{ .reason = "http_error" } },
    };
}

test "message: notification, data and the optional iOS sound" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const job: ch.Job = .{ .delivery_id = "d", .message_id = "m1", .attempt = 1, .recipient = .{ .user = "1" }, .notification = .{ .kind = "k", .title = "Ocorrência \"urgente\"", .body = "a\nb", .url = "/t/1" } };
    const cfg: Config = .{ .project_id = "p", .client_email = "e", .private_key_pem = "k", .apns_sound = "notification.wav" };
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, try message(a, cfg, "tok", &job), .{});
    const msg = v.object.get("message").?.object;
    try std.testing.expectEqualStrings("tok", msg.get("token").?.string);
    try std.testing.expectEqualStrings("Ocorrência \"urgente\"", msg.get("notification").?.object.get("title").?.string);
    try std.testing.expectEqualStrings("/t/1", msg.get("data").?.object.get("url").?.string);
    try std.testing.expectEqualStrings("notification.wav", msg.get("apns").?.object.get("payload").?.object.get("aps").?.object.get("sound").?.string);
    var no_sound = cfg;
    no_sound.apns_sound = null;
    const v2 = try std.json.parseFromSliceLeaky(std.json.Value, a, try message(a, no_sound, "tok", &job), .{});
    try std.testing.expect(v2.object.get("message").?.object.get("apns") == null);
}

test "normalizeKey: single and doubled escapes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("a\nb", try normalizeKey(a, "a\\nb"));
    try std.testing.expectEqualStrings("a\nb", try normalizeKey(a, "a\\\\nb"));
    try std.testing.expectEqualStrings("a\\b", try normalizeKey(a, "a\\b"));
}

test "deliver: an unconfigured channel skips" {
    var state: Fcm = .{ .config = .{ .project_id = "", .client_email = "", .private_key_pem = "" } };
    const c = state.channel();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ctx: ch.DeliveryContext = .{ .arena = arena_state.allocator(), .io = undefined, .hub = null, .address_book = @import("../address_book.zig").empty };
    const job: ch.Job = .{ .delivery_id = "d", .message_id = "m", .attempt = 1, .recipient = .{ .user = "1" }, .notification = .{ .kind = "k", .title = "t" } };
    try std.testing.expectEqualStrings("not_configured", c.deliver.?(c.ptr, &ctx, &job).skipped);
}

test "classify: statuses" {
    try std.testing.expect(classify(200) == .ok);
    try std.testing.expect(classify(404) == .gone);
    try std.testing.expect(classify(400) == .permanent);
    try std.testing.expect(classify(503) == .transient);
    try std.testing.expect(classify(401) == .transient);
}
