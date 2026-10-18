//! How long a delivery waits before its next attempt: exponential backoff
//! with "full jitter" (a random wait between half the step and the whole
//! step), capped. Pure, so the worker's schedule is testable without a clock.

const std = @import("std");

/// The backoff of one channel.
pub const Policy = struct {
    /// The wait after the first failed attempt, before jitter.
    base_ms: u64 = 5_000,
    /// The longest wait between two attempts.
    max_ms: u64 = 30 * 60 * 1000,
};

/// The wait before attempt `attempts + 1`, after `attempts` failed ones
/// (1 or more). `random` is a number in [0, 1) that picks the jitter; the
/// worker passes a random one, tests pass a fixed one. The step doubles with
/// each attempt (base, 2×base, 4×base…) up to `max_ms`; the result lies
/// between half the step and the step.
pub fn delayMs(policy: Policy, attempts: u32, random: f64) u64 {
    const exp: u6 = @intCast(@min(@max(attempts, 1) - 1, 40));
    const step = std.math.mul(u64, policy.base_ms, @as(u64, 1) << exp) catch policy.max_ms;
    const capped = @min(step, policy.max_ms);
    const half = capped / 2;
    const r = std.math.clamp(random, 0.0, 0.999999);
    return half + @as(u64, @intFromFloat(@as(f64, @floatFromInt(capped - half)) * r));
}

test "delayMs: doubles per attempt, within [step/2, step]" {
    const p: Policy = .{ .base_ms = 1000, .max_ms = 60_000 };
    try std.testing.expectEqual(@as(u64, 500), delayMs(p, 1, 0));
    try std.testing.expectEqual(@as(u64, 1000), delayMs(p, 2, 0));
    try std.testing.expectEqual(@as(u64, 2000), delayMs(p, 3, 0));
    try std.testing.expect(delayMs(p, 3, 0.999) <= 4000);
    try std.testing.expect(delayMs(p, 3, 0.999) > 3990);
}

test "delayMs: capped at max_ms, and safe for huge attempt counts" {
    const p: Policy = .{ .base_ms = 1000, .max_ms = 60_000 };
    try std.testing.expect(delayMs(p, 10, 0.999) <= 60_000);
    try std.testing.expectEqual(@as(u64, 30_000), delayMs(p, 1_000_000, 0));
    // attempt 0 is treated as the first.
    try std.testing.expectEqual(delayMs(p, 1, 0.5), delayMs(p, 0, 0.5));
}

test "delayMs: out-of-range random is clamped" {
    const p: Policy = .{ .base_ms = 1000, .max_ms = 60_000 };
    try std.testing.expectEqual(@as(u64, 500), delayMs(p, 1, -3));
    try std.testing.expect(delayMs(p, 1, 7) <= 1000);
}
