//! Internal: the configuration `notify.init` stores (channels, address book,
//! preferences), kept in a module global the way `spider.pg` keeps its pool.
//! `init` runs once at boot, before the worker's jobs start; afterwards the
//! registry is only read, so readers need no lock.

const std = @import("std");
const channel_mod = @import("channel.zig");
const address_book = @import("address_book.zig");
const preferences = @import("preferences.zig");

const Channel = channel_mod.Channel;

pub const Config = struct {
    channels: []const Channel,
    address_book: address_book.AddressBook = address_book.empty,
    preferences: preferences.Preferences = preferences.allow_all,
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    channels: []Channel,
    address_book: address_book.AddressBook,
    preferences: preferences.Preferences,

    pub fn find(self: *const Registry, name: []const u8) ?*const Channel {
        for (self.channels) |*c| if (std.mem.eql(u8, c.name, name)) return c;
        return null;
    }
};

var current: ?Registry = null;

pub const InitError = channel_mod.ConfigError || std.mem.Allocator.Error || error{ NoChannels, AlreadyInitialized };

pub fn init(allocator: std.mem.Allocator, config: Config) InitError!void {
    if (current != null) return error.AlreadyInitialized;
    if (config.channels.len == 0) return error.NoChannels;
    for (config.channels, 0..) |c, i| {
        try channel_mod.validate(c);
        for (config.channels[0..i]) |prev| if (std.mem.eql(u8, prev.name, c.name)) return error.DuplicateChannel;
    }
    const channels = try allocator.dupe(Channel, config.channels);
    errdefer allocator.free(channels);
    for (channels) |*c| c.name = try allocator.dupe(u8, c.name);
    current = .{
        .allocator = allocator,
        .channels = channels,
        .address_book = config.address_book,
        .preferences = config.preferences,
    };
}

pub fn deinit() void {
    const r = current orelse return;
    for (r.channels) |c| r.allocator.free(c.name);
    r.allocator.free(r.channels);
    current = null;
}

pub fn get() ?*const Registry {
    return if (current) |*r| r else null;
}

fn deliverNothing(_: ?*anyopaque, _: *const channel_mod.DeliveryContext, _: *const channel_mod.Job) channel_mod.Outcome {
    return .sent;
}

test "init: validates, copies the names, refuses duplicates and a second init" {
    defer deinit();
    var name_buf = "sse".*;
    try init(std.testing.allocator, .{ .channels = &.{.{ .name = &name_buf, .deliver = deliverNothing }} });
    name_buf[0] = 'x'; // the registry kept its own copy
    try std.testing.expect(get().?.find("sse") != null);
    try std.testing.expect(get().?.find("xse") == null);
    try std.testing.expectError(error.AlreadyInitialized, init(std.testing.allocator, .{ .channels = &.{.{ .name = "a", .deliver = deliverNothing }} }));
}

test "init: refuses no channels and duplicate names" {
    try std.testing.expectError(error.NoChannels, init(std.testing.allocator, .{ .channels = &.{} }));
    try std.testing.expectError(error.DuplicateChannel, init(std.testing.allocator, .{ .channels = &.{
        .{ .name = "sse", .deliver = deliverNothing },
        .{ .name = "sse", .deliver = deliverNothing },
    } }));
    try std.testing.expect(get() == null);
}
