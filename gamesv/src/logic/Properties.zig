pub const Avatar = @import("Properties/Avatar.zig");

basic_info: []BasicInfo,
avatar: []Avatar,

pub fn initAlloc(uninit: *Properties, arena: Allocator, slots: usize) Allocator.Error!void {
    uninit.basic_info = try arena.alloc(BasicInfo, slots);
    uninit.avatar = try arena.alloc(Avatar, slots);
}

pub fn setDefaultsAt(props: *Properties, at: Player) void {
    const index = at.toInt();

    props.basic_info[index] = .init;
    props.avatar[index] = .init;

    props.unlockAllAvatars(at);
}

fn unlockAllAvatars(props: *Properties, at: Player) void {
    const avatar = &props.avatar[at.toInt()];

    for (templates.avatar_base.entries) |template| if (template.camp != 0) {
        const i = avatar.indexes.count();
        avatar.indexes.put(template.getId(), @intCast(i));
        avatar.ids[i] = template.getId();

        avatar.metas[i] = .{
            .level = .max,
            .exp = 0,
            .rank = .max,
            .talents = .max,
            .talent_switch = .init,
            .flags = .init,
            .skill_levels = undefined,
            .skin = .none,
        };

        inline for (&avatar.metas[i].skill_levels, 0..) |*level, skill_type|
            level.* = .maxFor(@enumFromInt(skill_type));

        avatar.weapon_uids[i] = .none;
        avatar.equipment_uids[i] = @splat(.none);
    };
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

const Allocator = std.mem.Allocator;

const templates = Assets.templates;

const Assets = @import("../Assets.zig");
const std = @import("std");

const Properties = @This();
