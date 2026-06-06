set: std.atomic.Value(bool),

pub const init: Cancelation = .{
    .set = .init(false),
};

pub fn cancel(c: *Cancelation) void {
    c.set.store(true, .monotonic);
}

pub fn cancelRequested(c: *const Cancelation) bool {
    return c.set.load(.monotonic);
}

const std = @import("std");
const Cancelation = @This();
