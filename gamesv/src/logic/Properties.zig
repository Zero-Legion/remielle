pub const Avatar = @import("Properties/Avatar.zig");

basic_info: BasicInfo,
avatar: Avatar,

pub const List = rmmem.RemielleArrayList(
    rmmem.suggestBucketSize(64, Properties),
    Properties,
    u32,
);

pub fn initAlloc(uninit: *Properties, arena: Allocator, slots: usize) Allocator.Error!void {
    uninit.basic_info = try arena.alloc(BasicInfo, slots);
    uninit.avatar = try arena.alloc(Avatar, slots);
}

pub fn setDefaultsAt(list: *List, at: Player) void {
    const index = at.toInt();

    list.getPtr(.basic_info, index).* = .init;
    list.getPtr(.avatar, index).* = .init;

    unlockAllAvatars(list, at);
}

fn unlockAllAvatars(props: *Properties.List, at: Player) void {
    const avatar = props.getPtr(.avatar, at.toInt());

    for (templates.avatar_base.entries) |template| if (template.camp != 0) {
        const i = avatar.indexes.count();
        avatar.indexes.put(template.getId(), @intCast(i));
        avatar.ids[i] = template.getId();

        avatar.meta[i] = .{
            .level = .max,
            .exp = 0,
            .rank = .max,
            .talents = .max,
            .talent_switch = .init,
            .flags = .init,
            .skill_levels = undefined,
            .skin = .none,
        };

        inline for (&avatar.meta[i].skill_levels, 0..) |*level, skill_type|
            level.* = .maxFor(@enumFromInt(skill_type));

        avatar.weapon_uids[i] = .none;
        avatar.equipment_uids[i] = @splat(.none);
    };
}

pub const immutable_subset_marker_name = "logic_properties_subset_marker";

pub const mutable_subset_marker_name = "logic_properties_subset_marker";

pub fn Immutable(comptime types: anytype) type {
    return Subset(types, .immutable);
}

pub fn Mutable(comptime types: anytype) type {
    return Subset(types, .mutable);
}

fn Subset(
    /// A tuple of input types (fields of logic.Properties)
    comptime types: anytype,
    comptime access: enum { immutable, mutable },
) type {
    var field_types: [types.len + 1]type = undefined;
    var field_names: [types.len + 1][]const u8 = undefined;

    const properties_fields = @typeInfo(Properties).@"struct".fields;

    // Add a ZST field as a marker
    field_types[0] = void;
    field_names[0] = switch (access) {
        .immutable => immutable_subset_marker_name,
        .mutable => mutable_subset_marker_name,
    };

    for (types, field_types[1..], field_names[1..]) |P, *field_type, *field_name| {
        search: for (properties_fields) |properties_field| {
            if (properties_field.type == P) {
                field_type.* = switch (access) {
                    .immutable => *const P,
                    .mutable => *P,
                };

                field_name.* = properties_field.name;
                break :search;
            }
        } else @compileError("Invalid property type: " ++ @typeName(P));
    }

    return @Struct(.auto, null, &field_names, &field_types, &@splat(.{}));
}

pub fn extractFor(properties: *Properties.List, comptime Sub: type, index: u32) Sub {
    var subset: Sub = undefined;

    const bucket = properties.buckets.items[index / Properties.List.bucket_capacity];
    const i = index % Properties.List.bucket_capacity;

    inline for (@typeInfo(Sub).@"struct".fields) |field| {
        if (field.type == void) continue;

        @field(subset, field.name) = &@field(bucket, field.name)[i];
    }

    return subset;
}

/// Player index.
pub const Player = enum(u32) {
    _,

    pub fn toInt(player: Player) u32 {
        return @intFromEnum(player);
    }
};

pub const BasicInfo = struct {
    level: Level,
    avatar: HallAvatar,
    control_avatar: HallAvatar,
    control_guise_avatar: HallAvatar.Guise,

    pub const init: BasicInfo = .{
        .level = .max,
        .avatar = .wise,
        .control_avatar = .wise,
        .control_guise_avatar = .fromIdUnchecked(.remielle),
    };
};

pub const Level = enum(u8) {
    init = templates.yorozuya_level.entries[0].level,
    max = templates.yorozuya_level.entries[templates.yorozuya_level.entries.len - 1].level,
    _,

    pub fn toInt(level: Level) u32 {
        return @intFromEnum(level);
    }
};

pub const HallAvatar = enum(u32) {
    none = 0,
    wise = @intFromEnum(templates.avatar_base.Id.wise),
    belle = @intFromEnum(templates.avatar_base.Id.belle),

    /// Doesn't allow zero.
    pub fn fromInt(int: u32) ?HallAvatar {
        const avatar = std.enums.fromInt(HallAvatar, int) orelse
            return null;

        return switch (avatar) {
            .wise, .belle => |a| a,
            .none => null,
        };
    }

    pub fn toInt(avatar: HallAvatar) u32 {
        return @intFromEnum(avatar);
    }

    pub const Guise = enum(u32) {
        none = 0,
        wise = @intFromEnum(HallAvatar.wise),
        belle = @intFromEnum(HallAvatar.belle),
        _,

        pub const FromRawIdError = error{
            InvalidAvatarId,
            AvatarNotUnlocked,
        };

        pub fn fromRawId(player_avatar_prop: *const Avatar, raw_id: u32) !Guise {
            if (raw_id == 0) return .none;

            const id = std.enums.fromInt(templates.avatar_base.Id, raw_id) orelse
                return error.InvalidAvatarId;

            return switch (id) {
                .wise, .belle => .fromIdUnchecked(id),
                else => if (player_avatar_prop.indexes.contains(id))
                    .fromIdUnchecked(id)
                else
                    error.AvatarNotUnlocked,
            };
        }

        pub fn fromIdUnchecked(id: templates.avatar_base.Id) Guise {
            return @enumFromInt(@intFromEnum(id));
        }

        pub fn toInt(guise: Guise) u32 {
            return @intFromEnum(guise);
        }
    };
};

pub fn toPlayerSave(props: *Properties.List, arena: Allocator, player: Player) Allocator.Error!pb.PlayerSave {
    const index = @intFromEnum(player);

    const basic_info = props.getPtr(.basic_info, index);
    const basic_save: pb.BasicSave = .{
        .level = basic_info.level.toInt(),
        .avatar_id = basic_info.avatar.toInt(),
        .control_avatar_id = basic_info.control_avatar.toInt(),
        .control_guise_avatar_id = basic_info.control_guise_avatar.toInt(),
    };

    const avatar = props.getPtr(.avatar, index);
    const avatar_count = avatar.indexes.count();

    var avatar_save: pb.AvatarSave = .init;
    try avatar_save.items.ensureTotalCapacity(arena, avatar_count);

    for (
        avatar.ids[0..avatar_count],
        avatar.meta[0..avatar_count],
        avatar.weapon_uids[0..avatar_count],
        avatar.equipment_uids[0..avatar_count],
    ) |id, *meta, weapon_uid, *equipment_uids| {
        var skill_levels: std.ArrayList(u32) = try .initCapacity(arena, Avatar.Skill.count);

        for (meta.skill_levels) |level|
            skill_levels.appendAssumeCapacity(level.toInt());

        avatar_save.items.appendAssumeCapacity(.{
            .id = @intFromEnum(id),
            .level = meta.level.toInt(),
            .exp = meta.exp,
            .rank = meta.rank.toInt(),
            .talents = meta.talents.toInt(),
            .talent_switch = @intFromEnum(meta.talent_switch),
            .favorite = meta.flags.favorite,
            .skill_levels = skill_levels,
            .skin_id = meta.skin.toInt(),
            .weapon_uid = @intFromEnum(weapon_uid),
            .equipment_uids = .fromOwnedSlice(try arena.dupe(u32, @ptrCast(equipment_uids))),
        });
    }

    return .{
        .basic = basic_save,
        .avatar = avatar_save,
    };
}

pub fn fromPlayerSave(
    props: *Properties.List,
    gpa: Allocator,
    player: Player,
    save: *const pb.PlayerSave,
) !void {
    _ = gpa;

    const index = @intFromEnum(player);
    props.getPtr(.basic_info, index).* = if (save.basic) |basic| .{
        .level = @enumFromInt(basic.level),
        .avatar = @enumFromInt(basic.avatar_id),
        .control_avatar = @enumFromInt(basic.control_avatar_id),
        .control_guise_avatar = @enumFromInt(basic.control_guise_avatar_id),
    } else .init;

    if (save.avatar) |avatar_save| {
        const avatar = props.getPtr(.avatar, index);
        avatar.* = .init;

        for (avatar_save.items.items, 0..) |*item, i| {
            avatar.indexes.put(@enumFromInt(item.id), @intCast(i));
            avatar.ids[i] = @enumFromInt(item.id);

            avatar.meta[i] = .{
                .level = @enumFromInt(item.level),
                .exp = item.exp,
                .rank = @enumFromInt(item.rank),
                .talents = @enumFromInt(item.talents),
                .talent_switch = @enumFromInt(item.talent_switch),
                .flags = .{
                    .favorite = item.favorite,
                },
                .skill_levels = undefined,
                .skin = @enumFromInt(item.skin_id),
            };

            inline for (&avatar.meta[i].skill_levels, 0..) |*level, skill_i|
                level.* = if (item.skill_levels.items.len > skill_i)
                    @enumFromInt(item.skill_levels.items[skill_i])
                else
                    .maxFor(@enumFromInt(skill_i));

            avatar.weapon_uids[i] = @enumFromInt(item.weapon_uid);

            for (&avatar.equipment_uids[i], 0..) |*equipment_uid, slot_i|
                equipment_uid.* = if (item.equipment_uids.items.len > slot_i)
                    @enumFromInt(item.equipment_uids.items[slot_i])
                else
                    .none;
        }
    } else {
        props.getPtr(.avatar, index).* = .init;
        unlockAllAvatars(props, player);
    }
}

const Allocator = std.mem.Allocator;

const templates = Assets.templates;

const Assets = @import("../Assets.zig");

const pb = @import("rmpb").stable;
const rmmem = @import("rmmem");
const std = @import("std");

const Properties = @This();
