pub fn getAvatarData(txn: handlers.Transaction(.GetAvatarDataCsReq)) !void {
    var avatars_buffer: [1]pb.AvatarInfo = undefined;
    var avatars: std.ArrayList(pb.AvatarInfo) = .initBuffer(&avatars_buffer);

    var talent_switch = @as([3]bool, @splat(false)) ++ @as([3]bool, @splat(true));

    const skill_types = comptime std.enums.values(SkillType);
    var avatar_skills_buffer: [skill_types.len]pb.AvatarSkillLevel = undefined;
    var avatar_skills: std.ArrayList(pb.AvatarSkillLevel) = .initBuffer(&avatar_skills_buffer);

    for (skill_types) |skill_type| avatar_skills.appendAssumeCapacity(.{
        .skill_type = @intFromEnum(skill_type),
        .level = switch (skill_type) {
            .core_skill => 7,
            else => 12,
        },
    });

    avatars.appendAssumeCapacity(.{
        .id = 1571,
        .level = 60,
        .rank = 6,
        .unlocked_talent_num = 6,
        .talent_switch_list = .{ .items = &talent_switch, .capacity = talent_switch.len },
        .skill_type_level = avatar_skills,
        .is_favorite = true,
    });

    try txn.respond(.{ .avatar_list = avatars });
}

const SkillType = enum(u32) {
    common_attack = 0,
    special_attack = 1,
    evade = 2,
    cooperate_skill = 3,
    unique_skill = 4,
    core_skill = 5,
    assist_skill = 6,
};

const handlers = @import("../handlers.zig");

const pb = @import("nrmpb").main;
const std = @import("std");
