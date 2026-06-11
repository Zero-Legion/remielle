basic_info: []BasicInfo,

pub fn initAlloc(uninit: *Properties, arena: Allocator, slots: usize) Allocator.Error!void {
    uninit.basic_info = try arena.alloc(BasicInfo, slots);
}

pub fn setDefaultsAt(props: *Properties, at: Player) void {
    const index = at.toInt();

    props.basic_info[index] = .init;
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
        .control_guise_avatar = .fromId(.velina),
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

    pub const FromIntError = error{InvalidHallAvatar};

    /// Doesn't allow zero.
    pub fn fromInt(int: u32) FromIntError!HallAvatar {
        const avatar = std.enums.fromInt(HallAvatar, int) orelse
            return error.HallAvatar;

        return switch (avatar) {
            .wise, .belle => |a| a,
            .none => error.InvalidHallAvatar,
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

        pub fn fromId(id: templates.avatar_base.Id) Guise {
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
