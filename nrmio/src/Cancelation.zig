//! A convenience wrapper over atomic boolean.
//! The application that relies on `Cancelation` semantics
//! in order to implement "graceful shutdown" should instantiate
//! this structure globally, and call `cancel` whenever the shutdown is prompted.
//! The functions that want to take cancelation into account,
//! should accept a `*const Cancelation` as an argument, and check
//! `cancelRequested` before every potentially blocking syscall.

set: std.atomic.Value(bool),

pub const init: Cancelation = .{
    .set = .init(false),
};

/// An instance of `Cancelation`, `cancelRequested` of which is never `true`.
/// Use this instance in the following scenarios:
/// * You have to call a function that respects cancelation from the function that doesn't.
///
/// * You have already acknowledged the cancelation, but have to perform additional operations
/// in order to complete it.
///
/// For example: performing I/O inside of shutdown sequence.
pub const uncancelable: *const Cancelation = &.{
    .set = .init(false),
};

/// All subsequent `cancelRequested` calls will return `true`.
pub fn cancel(c: *Cancelation) void {
    c.set.store(true, .monotonic);
}

pub fn cancelRequested(c: *const Cancelation) bool {
    return c.set.load(.monotonic);
}

const std = @import("std");
const Cancelation = @This();
