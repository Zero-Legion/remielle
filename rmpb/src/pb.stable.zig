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

pub const PlayerSave = struct {
    pub const init: @This() = .{};
    pub const pb_desc_name = "PlayerSave";
    basic: ?BasicSave = null,
    avatar: ?AvatarSave = null,
    pub const basic_field_desc: FieldDesc = .{ .number = 1, .xor = 0 };
    pub const avatar_field_desc: FieldDesc = .{ .number = 2, .xor = 0 };
};

pub const BasicSave = struct {
    pub const init: @This() = .{};
    pub const pb_desc_name = "BasicSave";
    level: u32 = 0,
    avatar_id: u32 = 0,
    control_avatar_id: u32 = 0,
    control_guise_avatar_id: u32 = 0,
    pub const level_field_desc: FieldDesc = .{ .number = 1, .xor = 0 };
    pub const avatar_id_field_desc: FieldDesc = .{ .number = 2, .xor = 0 };
    pub const control_avatar_id_field_desc: FieldDesc = .{ .number = 3, .xor = 0 };
    pub const control_guise_avatar_id_field_desc: FieldDesc = .{ .number = 4, .xor = 0 };
};

pub const AvatarSave = struct {
    pub const init: @This() = .{};
    pub const pb_desc_name = "AvatarSave";
    items: std.ArrayList(AvatarItemSave) = .empty,
    pub const items_field_desc: FieldDesc = .{ .number = 1, .xor = 0 };
};

pub const AvatarItemSave = struct {
    pub const init: @This() = .{};
    pub const pb_desc_name = "AvatarItemSave";
    id: u32 = 0,
    level: u32 = 0,
    exp: u32 = 0,
    rank: u32 = 0,
    talents: u32 = 0,
    talent_switch: u32 = 0,
    favorite: bool = false,
    skill_levels: std.ArrayList(u32) = .empty,
    skin_id: u32 = 0,
    weapon_uid: u32 = 0,
    equipment_uids: std.ArrayList(u32) = .empty,
    pub const id_field_desc: FieldDesc = .{ .number = 1, .xor = 0 };
    pub const level_field_desc: FieldDesc = .{ .number = 2, .xor = 0 };
    pub const exp_field_desc: FieldDesc = .{ .number = 3, .xor = 0 };
    pub const rank_field_desc: FieldDesc = .{ .number = 4, .xor = 0 };
    pub const talents_field_desc: FieldDesc = .{ .number = 5, .xor = 0 };
    pub const talent_switch_field_desc: FieldDesc = .{ .number = 6, .xor = 0 };
    pub const favorite_field_desc: FieldDesc = .{ .number = 7, .xor = 0 };
    pub const skill_levels_field_desc: FieldDesc = .{ .number = 8, .xor = 0 };
    pub const skin_id_field_desc: FieldDesc = .{ .number = 9, .xor = 0 };
    pub const weapon_uid_field_desc: FieldDesc = .{ .number = 10, .xor = 0 };
    pub const equipment_uids_field_desc: FieldDesc = .{ .number = 11, .xor = 0 };
};

