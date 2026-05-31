pub const handlers = @import("messaging/handlers.zig");
pub const Xorpad = @import("messaging/Xorpad.zig");

pub const Header = struct {
    pub const magic: [4]u8 = .{ 0x01, 0x23, 0x45, 0x67 };
    pub const size: usize = 12;

    cmd_id: u16,
    head_len: u16,
    body_len: u32,

    pub const DecodeError = error{InvalidMagic};

    pub fn decode(bytes: *const [size]u8) DecodeError!Header {
        if (!std.mem.eql(u8, bytes[0..4], &magic))
            return error.InvalidMagic;

        errdefer comptime unreachable;

        return .{
            .cmd_id = readInt(u16, bytes[4..6], .big),
            .head_len = readInt(u16, bytes[6..8], .big),
            .body_len = readInt(u32, bytes[8..12], .big),
        };
    }

    pub fn takeBody(header: *const Header, bytes: []u8) []u8 {
        return bytes[size + header.head_len ..][0..header.body_len];
    }
};

pub fn encodingLength(head: rmpb.stable.PacketHead, body: anytype) usize {
    return rmpb.encodingLength(.stable, head) + rmpb.encodingLength(.main, body) + 16;
}

pub fn decodePacketHead(bytes: []const u8) ?rmpb.stable.PacketHead {
    var reader: Io.Reader = .fixed(bytes);
    return rmpb.decode(.stable, rmpb.stable.PacketHead, .failing, &reader) catch null;
}

pub fn encode(
    writer: *Io.Writer,
    xorpad: *const Xorpad,
    cmd_id: u16,
    head: rmpb.stable.PacketHead,
    body: anytype,
) Io.Writer.Error!void {
    try writer.writeAll(&Header.magic);
    try writer.writeInt(u16, cmd_id, .big);
    try writer.writeInt(u16, @intCast(rmpb.encodingLength(.stable, head)), .big);
    try writer.writeInt(u32, @intCast(rmpb.encodingLength(.main, body)), .big);
    try rmpb.encode(.stable, writer, head);

    var xw = xorpad.wrapWriter(writer);
    try rmpb.encode(.main, &xw.interface, body);
    xw.deinit();

    try writer.writeInt(u32, 0x89ABCDEF, .big);
}

const readInt = std.mem.readInt;

const Io = std.Io;

const rmcrypt = @import("rmcrypt");
const rmpb = @import("rmpb");
const std = @import("std");
