const std = @import("std");
fn MapEntry(comptime K: type, comptime V: type) type {
    return struct {
        pub const map_entry: void = {};
        pub const init: @This() = .{
            .key = switch (@typeInfo(K)) {
                .int => 0,
                .bool => false,
                else => if (K == []const u8) "" else .init,
            },
            .value = switch (@typeInfo(V)) {
                .int => 0,
                .bool => false,
                else => if (V == []const u8) "" else .init,
            },
        };
        pub const key_field_number: u32 = 1;
        pub const value_field_number: u32 = 2;

        key: K,
        value: V,
    };
}

pub const FieldDesc = struct {
    number: u32,
    xor: u32,
};
pub const PacketHead = struct {
    pub const init: @This() = .{};
    pub const pb_desc_name = "PacketHead";
    packet_id: u32 = 0,
    ack_packet_id: u32 = 0,
    pub const packet_id_field_desc: FieldDesc = .{ .number = 1, .xor = 0 };
    pub const ack_packet_id_field_desc: FieldDesc = .{ .number = 11, .xor = 0 };
};

