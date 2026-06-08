const log = std.log.scoped(.@"hollowell-gamesv::messaging");

pub const auth = @import("messaging/auth.zig");
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
};

pub fn encodingLength(head: nrmpb.stable.PacketHead, body: anytype) usize {
    return nrmpb.encodingLength(.stable, head) + nrmpb.encodingLength(.main, body) + 16;
}

pub fn decodePacketHead(bytes: []const u8) ?nrmpb.stable.PacketHead {
    var reader: Io.Reader = .fixed(bytes);
    return nrmpb.decode(.stable, nrmpb.stable.PacketHead, .failing, &reader) catch null;
}

pub fn encode(
    writer: *Io.Writer,
    xorpad: *const Xorpad,
    cmd_id: u16,
    head: nrmpb.stable.PacketHead,
    body: anytype,
) Io.Writer.Error!void {
    try writer.writeAll(&Header.magic);
    try writer.writeInt(u16, cmd_id, .big);
    try writer.writeInt(u16, @intCast(nrmpb.encodingLength(.stable, head)), .big);
    try writer.writeInt(u32, @intCast(nrmpb.encodingLength(.main, body)), .big);
    try nrmpb.encode(.stable, writer, head);

    var xw = xorpad.wrapWriter(writer);
    try nrmpb.encode(.main, &xw.interface, body);
    xw.deinit();

    try writer.writeInt(u32, 0x89ABCDEF, .big);
}

pub fn expectFirstPacket(
    /// Used for copying strings for PlayerGetTokenCsReq decoding
    /// ideally, we should introduce an option to protobuf decoder
    /// for not copying strings which would be applicable in this case.
    string_buffer: []u8,
    /// Packet contents, *not* including kcp header
    data: []u8,
) !nrmpb.main.PlayerGetTokenCsReq {
    if (data.len < Header.size)
        return error.SizeMismatch;

    const header = try Header.decode(data[0..Header.size]);
    if (header.head_len + header.body_len > data.len - Header.size)
        return error.SizeMismatch;

    if (header.cmd_id != nrmpb.main_desc.PlayerGetTokenCsReq.cmd_id) {
        log.debug("received unexpected first cmd_id: {d}", .{header.cmd_id});
        return error.UnexpectedCmdId;
    }

    const body = data[Header.size + header.head_len ..][0..header.body_len];
    Xorpad.initial.xor(.beginning, body);

    var fba: heap.FixedBufferAllocator = .init(string_buffer);
    var br: Io.Reader = .fixed(body);

    return nrmpb.decode(.main, nrmpb.main.PlayerGetTokenCsReq, fba.allocator(), &br) catch
        return error.MalformedPayload;
}

pub const SendMessageError = error{MessageOversize};

pub fn sendMessage(
    multi_conversation: *kcp.MultiConversation,
    xorpad: *const Xorpad,
    client: u32,
    head: nrmpb.stable.PacketHead,
    cmd_id: u16,
    message: anytype,
) SendMessageError!void {
    const length = encodingLength(head, message);
    var writer = try multi_conversation.writer(client, length);

    encode(
        &writer.interface,
        xorpad,
        cmd_id,
        head,
        message,
    ) catch unreachable;
}

const readInt = std.mem.readInt;

const Io = std.Io;

const heap = std.heap;

const kcp = @import("kcp.zig");

const nrmcrypt = @import("nrmcrypt");
const nrmpb = @import("nrmpb");
const std = @import("std");
